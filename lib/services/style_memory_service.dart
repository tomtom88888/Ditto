import 'dart:math' as math;
import 'dart:typed_data';

import '../models/chat_app.dart';
import '../models/chat_stats.dart';
import '../models/chat_turn.dart';
import '../models/exchange.dart';
import '../models/parsed_chat.dart';
import '../models/stored_exchange.dart';
import '../models/style_profile.dart';
import 'exchange_store.dart';
import 'openai_exception.dart';
import 'openai_service.dart';
import 'pricing.dart';
import 'retrieval.dart';
import 'vector_math.dart';
import 'whatsapp_parser.dart';

/// Progress of a style-memory build, for the training screen.
class StyleMemoryProgress {
  const StyleMemoryProgress({
    required this.embedded,
    required this.total,
    required this.stage,
  });

  final int embedded;
  final int total;
  final String stage;

  double get fraction => total == 0 ? 0 : embedded / total;
}

/// What a build would cost and how much data it would use.
class StyleMemoryEstimate {
  const StyleMemoryEstimate({
    required this.exchangeCount,
    required this.estimatedTokens,
    required this.estimatedUsd,
  });

  final int exchangeCount;
  final int estimatedTokens;
  final double estimatedUsd;
}

/// What importing an export into the memory would do, worked out before
/// anything is sent.
class ImportPlan {
  const ImportPlan({
    required this.existing,
    required this.toEmbed,
    required this.alreadyKnown,
    required this.replacesExisting,
    required this.estimate,
  });

  /// The chat this export adds to, or `null` if it starts a new one.
  final ChatMemory? existing;

  /// Exchanges not yet in the memory, deduplicated.
  final List<Exchange> toEmbed;

  /// Exchanges in the export that are already stored and won't be re-sent.
  final int alreadyKnown;

  /// True when the existing chat was embedded with a different model, so it
  /// has to be rebuilt from scratch.
  final bool replacesExisting;

  /// The cost of embedding [toEmbed] — only the new part.
  final StyleMemoryEstimate estimate;

  bool get isNewChat => existing == null;
}

/// The examples retrieved for one generation.
class RetrievedExamples {
  const RetrievedExamples({required this.examples, this.skipped = const []});

  final List<ScoredExchange> examples;

  /// Switched-on chats that could not be searched because they were built
  /// with a different embedding model or size. Retraining them fixes it.
  final List<ChatMemory> skipped;
}

/// Mode A: builds and queries the local style memory.
///
/// Each imported export becomes (or adds to) one chat. Building embeds every
/// `their turn(s) -> my reply` exchange that isn't already stored and keeps
/// the vectors on the device. Querying embeds the current conversation and
/// returns close — and varied — past exchanges from the chats that are
/// switched on. Nothing but the text being embedded leaves the phone.
class StyleMemoryService {
  StyleMemoryService({
    required this.openai,
    required this.store,
    this.retrieval = const Retrieval(),
  });

  final OpenAiService openai;
  final ExchangeStore store;
  final Retrieval retrieval;

  /// Exchanges per embeddings request. Each sends two texts (the context,
  /// and the moment for search), so this keeps a request inside Gemini's
  /// 100-text limit as well as the size limit.
  static const int embedBatchSize = 48;

  /// OpenAI's retrieval quality falls off with very short contexts and the
  /// embedding cost is dominated by long ones, so contexts are capped.
  static const int maxContextCharacters = 4000;

  StyleMemoryEstimate estimate(List<Exchange> exchanges) {
    final tokens = Pricing.estimateTokensForAll(
      exchanges.map((e) => _embedText(e.contextText)),
    );
    return StyleMemoryEstimate(
      exchangeCount: exchanges.length,
      estimatedTokens: tokens,
      estimatedUsd: Pricing.usd(tokens, Pricing.embeddingUsdPerMillionTokens),
    );
  }

  /// Turns a parsed export into training exchanges.
  List<Exchange> exchangesFrom(
    ParsedChat chat, {
    required String myName,
    required int contextTurns,
  }) => WhatsAppParser.buildExchanges(
    chat.turns,
    me: myName,
    maxContextTurns: contextTurns,
  );

  /// The stored chat an export between [myName] and [theirName] belongs to.
  Future<ChatMemory?> findChat({
    required String myName,
    required String theirName,
  }) async {
    for (final chat in await store.chats()) {
      if (chat.myName == myName && chat.theirName == theirName) return chat;
    }
    return null;
  }

  /// Works out what importing [exchanges] would embed and cost.
  Future<ImportPlan> plan({
    required List<Exchange> exchanges,
    required String myName,
    required String theirName,
    required String embeddingModel,
    required int dimensions,
  }) async {
    final existing = await findChat(myName: myName, theirName: theirName);
    final replaces =
        existing != null && !existing.matches(embeddingModel, dimensions);
    final known = existing == null || replaces
        ? <String>{}
        : await store.hashesFor(existing.id);

    final seen = <String>{};
    final fresh = <Exchange>[];
    var alreadyKnown = 0;
    for (final exchange in exchanges) {
      final hash = StoredExchange.hashOf(exchange);
      if (known.contains(hash)) {
        alreadyKnown++;
        continue;
      }
      // The same exchange twice in one export would only weight it double.
      if (seen.add(hash)) fresh.add(exchange);
    }
    return ImportPlan(
      existing: existing,
      toEmbed: fresh,
      alreadyKnown: alreadyKnown,
      replacesExisting: replaces,
      estimate: estimate(fresh),
    );
  }

  /// Embeds the new exchanges in an export and adds them to that chat's
  /// memory, creating the chat if it is new.
  ///
  /// Reports progress after each batch. If [isCancelled] starts returning true
  /// the build stops and the stored memory is left untouched, because nothing
  /// is written until everything is embedded.
  Future<ChatMemory> build({
    required List<Exchange> exchanges,
    required String myName,
    required String theirName,
    required String embeddingModel,
    required int dimensions,
    StyleProfile profile = StyleProfile.empty,
    ChatStats stats = ChatStats.empty,
    bool isGroup = false,
    ChatApp app = ChatApp.whatsapp,
    ImportPlan? importPlan,
    void Function(StyleMemoryProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (exchanges.isEmpty) {
      throw const OpenAiException(
        OpenAiErrorKind.badRequest,
        'There are no replies of yours to learn from. Check that you picked '
        'the right name for yourself, and that the export is a chat you '
        'actually replied in.',
      );
    }

    final planned =
        importPlan ??
        await plan(
          exchanges: exchanges,
          myName: myName,
          theirName: theirName,
          embeddingModel: embeddingModel,
          dimensions: dimensions,
        );
    final todo = planned.toEmbed;

    final stored = <StoredExchange>[];
    final stage = todo.isEmpty
        ? 'Nothing new to embed'
        : 'Embedding ${todo.length} new exchanges';
    onProgress?.call(
      StyleMemoryProgress(embedded: 0, total: todo.length, stage: stage),
    );

    for (var start = 0; start < todo.length; start += embedBatchSize) {
      if (isCancelled?.call() ?? false) {
        throw const StyleMemoryCancelled();
      }
      final end = (start + embedBatchSize).clamp(0, todo.length);
      final batch = todo.sublist(start, end);
      // The context for writing replies, then the moment itself for search.
      final vectors = await openai.embed(
        [
          for (final e in batch) _embedText(e.contextText),
          for (final e in batch)
            _embedText(StoredExchange.focusTextOf(e.context, e.replyText)),
        ],
        model: embeddingModel,
        dimensions: dimensions,
      );

      for (var i = 0; i < batch.length; i++) {
        final exchange = batch[i];
        stored.add(
          StoredExchange(
            id: -1,
            context: exchange.context,
            contextText: exchange.contextText,
            replyText: exchange.replyText,
            vector: _unit(vectors[i]),
            focus: _unit(vectors[batch.length + i]),
            timestamp: exchange.timestamp,
            hash: StoredExchange.hashOf(exchange),
          ),
        );
      }
      onProgress?.call(
        StyleMemoryProgress(
          embedded: stored.length,
          total: todo.length,
          stage: stage,
        ),
      );
    }
    if (isCancelled?.call() ?? false) throw const StyleMemoryCancelled();

    onProgress?.call(
      StyleMemoryProgress(
        embedded: stored.length,
        total: todo.length,
        stage: 'Saving to this device',
      ),
    );
    final base = planned.existing;
    final chat =
        (base ??
                ChatMemory(
                  myName: myName,
                  theirName: theirName,
                  embeddingModel: embeddingModel,
                  dimensions: dimensions,
                  builtAt: DateTime.now(),
                ))
            .copyWith(
              embeddingModel: embeddingModel,
              dimensions: dimensions,
              builtAt: DateTime.now(),
              // Re-importing a chat you had switched off is a strong hint you
              // want it back.
              enabled: true,
              profile: profile.isEmpty ? base?.profile : profile,
              stats: stats.isEmpty ? base?.stats : stats,
              isGroup: isGroup,
              app: app,
            );
    return store.saveChat(
      chat,
      added: stored,
      replaceExisting: planned.replacesExisting,
    );
  }

  /// Up to [limit] past exchanges like the conversation so far, drawn from
  /// [chatIds] (every chat when omitted), leaning towards
  /// [preferChatId]. Only the last [queryTurns] turns are searched with.
  Future<RetrievedExamples> retrieve({
    required List<ChatTurn> context,
    required String embeddingModel,
    required int dimensions,
    required int limit,
    Set<int>? chatIds,
    int? preferChatId,
    int? queryTurns,
  }) async {
    final chats = await store.chats();
    final wanted = chats.where(
      (c) => chatIds == null || chatIds.contains(c.id),
    );
    final usable = <int>{};
    final skipped = <ChatMemory>[];
    for (final chat in wanted) {
      if (chat.isEmpty) continue;
      if (chat.matches(embeddingModel, dimensions)) {
        usable.add(chat.id);
      } else {
        skipped.add(chat);
      }
    }
    if (usable.isEmpty) {
      return RetrievedExamples(examples: const [], skipped: skipped);
    }

    // Search with the same window the stored exchanges were fingerprinted
    // with, so like is compared with like; a longer conversation would blur
    // the search across everything said in it.
    final recent = queryTurns != null && context.length > queryTurns
        ? context.sublist(context.length - queryTurns)
        : context;
    final queryText = _embedText(Exchange.renderContext(recent));
    if (queryText.trim().isEmpty) {
      return RetrievedExamples(examples: const [], skipped: skipped);
    }

    final candidates = await store.all(chatIds: usable);
    if (candidates.isEmpty) {
      return RetrievedExamples(examples: const [], skipped: skipped);
    }
    final vectors = await openai.embed(
      [queryText],
      model: embeddingModel,
      dimensions: dimensions,
    );
    final Float32List query = _unit(vectors.first);
    return RetrievedExamples(
      examples: retrieval.select(
        query,
        candidates,
        limit: limit,
        preferChatId: preferChatId,
      ),
      skipped: skipped,
    );
  }

  /// Up to [count] of your real replies, for the model to hear your voice
  /// in — short ones, most recent first, no two alike.
  ///
  /// Two thirds come from [preferChatId] when given (the chat being replied
  /// in), the rest from the other ticked chats. Long replies are skipped:
  /// they are rare, and the retrieved examples already show those.
  Future<List<String>> voiceSample({
    required Set<int> chatIds,
    int? preferChatId,
    int count = 25,
  }) async {
    if (chatIds.isEmpty || count < 1) return const [];
    final rows = await store.all(chatIds: chatIds);
    final ordered = [...rows]
      ..sort((a, b) {
        final at = a.timestamp;
        final bt = b.timestamp;
        if (at == null || bt == null) return b.id.compareTo(a.id);
        return bt.compareTo(at);
      });

    final seen = <String>{};
    final preferred = <String>[];
    final others = <String>[];
    for (final row in ordered) {
      final reply = row.replyText.trim();
      if (reply.isEmpty || reply.length > 160) continue;
      if (!seen.add(reply.toLowerCase())) continue;
      (row.chatId == preferChatId ? preferred : others).add(reply);
    }
    final fromPreferred = preferChatId == null ? 0 : (count * 2) ~/ 3;
    final picked = [
      ...preferred.take(fromPreferred),
      ...others.take(count - preferred.take(fromPreferred).length),
    ];
    // Top up from the preferred chat if the others ran short.
    if (picked.length < count) {
      picked.addAll(preferred.skip(fromPreferred).take(count - picked.length));
    }
    return picked;
  }

  /// Stores a suggestion you actually sent as a new example in [chat], so the
  /// memory keeps learning between exports.
  Future<ChatMemory> saveReply({
    required ChatMemory chat,
    required List<ChatTurn> conversation,
    required String reply,
    required int contextTurns,
  }) async {
    final text = reply.trim();
    if (text.isEmpty || conversation.isEmpty) {
      throw const OpenAiException(
        OpenAiErrorKind.badRequest,
        'There is nothing to save yet.',
      );
    }
    final context = conversation.length > contextTurns
        ? conversation.sublist(conversation.length - contextTurns)
        : conversation;
    final contextText = Exchange.renderContext(context);
    final hash = StoredExchange.contentHash(contextText, text);
    if ((await store.hashesFor(chat.id)).contains(hash)) return chat;

    final vectors = await openai.embed(
      [
        _embedText(contextText),
        _embedText(StoredExchange.focusTextOf(context, text)),
      ],
      model: chat.embeddingModel,
      dimensions: chat.dimensions,
    );
    return store.saveChat(
      chat,
      added: [
        StoredExchange(
          id: -1,
          context: context,
          contextText: contextText,
          replyText: text,
          vector: _unit(vectors.first),
          focus: _unit(vectors.last),
          timestamp: DateTime.now(),
          hash: hash,
          source: ExchangeSource.saved,
        ),
      ],
    );
  }

  /// How [chat] ended the last time you talked: the lead-up to your latest
  /// reply, then that reply.
  Future<List<ChatTurn>> latestTurns(ChatMemory chat) async {
    final rows = await store.all(chatIds: {chat.id});
    StoredExchange? latest;
    for (final r in rows) {
      final at = r.timestamp;
      if (at == null) continue;
      final best = latest?.timestamp;
      if (best == null || at.isAfter(best)) latest = r;
    }
    latest ??= rows.isEmpty ? null : rows.last;
    if (latest == null) return const [];
    return [
      ...latest.context,
      ChatTurn(
        sender: chat.myName,
        text: latest.replyText,
        messageCount: '\n'.allMatches(latest.replyText.trim()).length + 1,
        firstTimestamp: latest.timestamp,
        lastTimestamp: latest.timestamp,
      ),
    ];
  }

  static Float32List _unit(List<double> values) => VectorMath.normalise(values);

  /// How many of [chatIds]' exchanges, built with [embeddingModel] at
  /// [dimensions], have no search fingerprint yet.
  Future<int> missingFocus({
    required Set<int> chatIds,
    required String embeddingModel,
    required int dimensions,
  }) async => (await _withoutFocus(chatIds, embeddingModel, dimensions)).length;

  Future<List<StoredExchange>> _withoutFocus(
    Set<int> chatIds,
    String embeddingModel,
    int dimensions,
  ) async {
    final usable = {
      for (final c in await store.chats())
        if (chatIds.contains(c.id) && c.matches(embeddingModel, dimensions))
          c.id,
    };
    if (usable.isEmpty) return const [];
    return [
      for (final e in await store.all(chatIds: usable))
        if (e.focus == null) e,
    ];
  }

  /// Makes the search fingerprints that chats imported before they existed
  /// are missing. One cheap embedding call per [embedBatchSize] × 2.
  Future<int> addFocus({
    required Set<int> chatIds,
    required String embeddingModel,
    required int dimensions,
    void Function(int done, int of)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final todo = await _withoutFocus(chatIds, embeddingModel, dimensions);
    final batchSize = embedBatchSize * 2;
    onProgress?.call(0, todo.length);
    for (var start = 0; start < todo.length; start += batchSize) {
      if (isCancelled?.call() ?? false) throw const StyleMemoryCancelled();
      final batch = todo.sublist(
        start,
        math.min(start + batchSize, todo.length),
      );
      final vectors = await openai.embed(
        [for (final e in batch) _embedText(e.focusText)],
        model: embeddingModel,
        dimensions: dimensions,
      );
      await store.saveFocus({
        for (var i = 0; i < batch.length; i++) batch[i].id: _unit(vectors[i]),
      });
      onProgress?.call(start + batch.length, todo.length);
    }
    return todo.length;
  }

  /// Keeps the tail of a long context: the most recent turns are what a reply
  /// actually responds to.
  static String _embedText(String contextText) {
    if (contextText.length <= maxContextCharacters) return contextText;
    return contextText.substring(contextText.length - maxContextCharacters);
  }
}

/// Thrown when the user cancels a build.
class StyleMemoryCancelled implements Exception {
  const StyleMemoryCancelled();

  @override
  String toString() => 'Training cancelled.';
}
