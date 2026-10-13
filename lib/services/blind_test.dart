import 'dart:convert';
import 'dart:math' as math;

import '../models/app_settings.dart';
import '../models/blind_test.dart';
import '../models/chat_turn.dart';
import '../models/stored_exchange.dart';
import 'openai_exception.dart';
import 'chat_search.dart';
import 'openai_service.dart';
import 'vector_math.dart';
import 'reply_generator.dart';
import 'style_memory_service.dart';

/// Measures how often replies written in your place pass for your own.
///
/// Real moments are taken from a chat with your reply hidden; a reply is
/// written for each, exactly as the app would write one, with that moment
/// and the hours around it kept out of what the writer can see. A judge
/// model is then shown both messages and asked which one you really sent.
/// When it can't tell, about half of its picks land on the generated one;
/// when it always can, none do.
///
/// The same moments are used for every prompt in a run, and for every run
/// until new ones are asked for, so prompts can be compared fairly.
class BlindTest {
  const BlindTest._();

  /// Moments per run.
  static const int momentCount = 20;

  /// Your real replies the judge is shown to know how you text.
  static const int judgeSampleCount = 15;

  /// Exchanges this close to a held-out moment are kept from the writer:
  /// the ones just after it have your real reply in their own lead-up.
  static const Duration window = Duration(hours: 12);

  /// Without timestamps, rows this many ids either side are kept out.
  static const int idWindow = 10;

  /// Up to [count] moments from [all] to test with, the same ones for the
  /// same [seed]. Only exported replies of 2–160 characters, written in
  /// answer to someone else, are fair moments.
  static List<StoredExchange> pickMoments(
    List<StoredExchange> all, {
    required String me,
    required int seed,
    int count = momentCount,
  }) {
    final fair = [
      for (final e in all)
        if (e.source == ExchangeSource.export &&
            e.context.isNotEmpty &&
            e.context.last.sender != me &&
            e.replyText.trim().length >= 2 &&
            e.replyText.trim().length <= 160)
          e,
    ]..sort((a, b) => a.id.compareTo(b.id));
    fair.shuffle(math.Random(seed));
    return fair.take(count).toList();
  }

  /// What to keep from the writer while [held] is being tested: it, and
  /// everything from its chat within [window] of it.
  static bool Function(StoredExchange) excluding(StoredExchange held) {
    final at = held.timestamp;
    return (e) {
      if (e.chatId != held.chatId) return false;
      final other = e.timestamp;
      if (at != null && other != null) {
        return other.difference(at).abs() <= window;
      }
      return (e.id - held.id).abs() <= idWindow;
    };
  }

  // ------------------------------------------------------------- openers

  /// How long a chat has to have been quiet for your next message to count
  /// as starting it up again.
  static const Duration minQuiet = Duration(hours: 12);

  /// How long it had been quiet before [e]'s reply, or `null` when unknown.
  static Duration? quietBefore(StoredExchange e) {
    final sent = e.timestamp;
    final last = e.context.isEmpty
        ? null
        : e.context.last.lastTimestamp ?? e.context.last.firstTimestamp;
    if (sent == null || last == null) return null;
    return sent.difference(last);
  }

  /// Up to [count] times you started [all]'s chat up again after at least
  /// [minQuiet] of quiet, the same ones for the same [seed]. Only exported
  /// messages of 2–300 characters count.
  static List<StoredExchange> pickOpeners(
    List<StoredExchange> all, {
    required int seed,
    int count = momentCount,
  }) {
    final fair = [
      for (final e in all)
        if (e.source == ExchangeSource.export &&
            e.context.isNotEmpty &&
            (quietBefore(e) ?? Duration.zero) >= minQuiet &&
            e.replyText.trim().length >= 2 &&
            e.replyText.trim().length <= 300)
          e,
    ]..sort((a, b) => a.id.compareTo(b.id));
    fair.shuffle(math.Random(seed));
    return fair.take(count).toList();
  }

  /// [excluding], and also any moment that quotes the held-out opener in
  /// its lead-up, however long after it came.
  static bool Function(StoredExchange) excludingOpener(StoredExchange held) {
    final near = excluding(held);
    final text = held.replyText.trim();
    return (e) => near(e) || e.context.any((t) => t.text.trim() == text);
  }

  /// Instructions for turning a real opener into the "what happened in
  /// your day" note the writer gets: what it brings up, none of its words.
  static String topicSystem(String me) =>
      'You are given a message $me sent to start a chat up again. In one '
      'short line of plain English, in the third person, say what $me brings '
      'up: the facts only, like a note to self. Use none of its words, '
      'phrases, slang, emoji or tone, and do not quote it. If it is only a '
      'greeting or a check-in, answer "just saying hi".';

  /// What the writer and the judge are told about an opener moment.
  static String openerSetup({required Duration quiet, required String topic}) {
    final q = ReplyGenerator.quietFor(quiet);
    return '(quiet for ${q.isEmpty ? "half a day" : q} · brought up: $topic)';
  }

  static String _flat(String text) => text.trim().replaceAll('\n', ' / ');

  /// The judge's instructions, with [realReplies] to know you by. For
  /// [BlindKind.openers], the two messages each start a quiet chat up again,
  /// and the judge knows both writers knew what you brought up.
  static String judgeSystem({
    required String me,
    required String them,
    required List<String> realReplies,
    BlindKind kind = BlindKind.replies,
  }) {
    final out = StringBuffer(
      kind == BlindKind.openers
          ? 'You are shown how a chat between $me and $them ended, how long '
                'it then stayed quiet and what $me brought up next, and two '
                'messages, A and B, each starting the chat up again. One is '
                'what $me really sent; the other was written by someone '
                'imitating $me who was told the same. Decide which one $me '
                'really sent.'
          : 'You are shown a moment from a chat between $me and $them, and '
                'two messages, A and B. One is what $me really sent next; the '
                'other was written by someone imitating $me. Decide which one '
                '$me really sent.',
    );
    if (realReplies.isNotEmpty) {
      out
        ..writeln()
        ..writeln()
        ..writeln(
          'Real messages $me has sent $them at other times, to know how $me '
          'texts:',
        )
        ..write(realReplies.map((r) => '- ${_flat(r)}').join('\n'));
    }
    out
      ..writeln()
      ..writeln()
      ..write(
        'Answer only with JSON: {"pick": "A" or "B", "why": "<one short '
        'line: what gave the other one away>"}',
      );
    return out.toString();
  }

  /// The moment and the two messages, as the judge sees them.
  static String judgeUser({
    required List<ChatTurn> context,
    required String a,
    required String b,
    String setup = '',
  }) =>
      '${context.map((t) => '${t.sender}: ${_flat(t.text)}').join('\n')}'
      '${setup.isEmpty ? "" : "\n$setup"}'
      '\n\nA: ${_flat(a)}\nB: ${_flat(b)}';

  /// The judge's pick, "A" or "B" (`null` when it can't be read), and its
  /// reason.
  static (String?, String) parseJudge(String raw) {
    String? pick(Object? value) {
      if (value is! String) return null;
      final p = value.trim().toUpperCase();
      return p == 'A' || p == 'B' ? p : null;
    }

    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final json = jsonDecode(raw.substring(start, end + 1));
        if (json is Map) {
          final why = json['why'];
          final p = pick(json['pick']);
          return (p, p != null && why is String ? why.trim() : '');
        }
      } on FormatException {
        // Fall through to a bare answer.
      }
    }
    return (pick(raw), '');
  }

  /// Whether fool rates [a] and [b], each over [n] moments, differ by more
  /// than luck would explain (a two-proportion test at p < 0.1).
  static bool clearlyDifferent(int n, double a, double b) {
    if (n < 1) return false;
    final pooled = (a + b) / 2;
    if (pooled <= 0 || pooled >= 1) return false;
    final se = math.sqrt(pooled * (1 - pooled) * 2 / n);
    return (a - b).abs() / se > 1.645;
  }

  /// API calls a run makes: one fingerprint per moment, then a reply and a
  /// judgement per moment for each prompt.
  ///
  /// Openers take one more per moment: what the real one brought up.
  static int calls({
    required int moments,
    required int prompts,
    BlindKind kind = BlindKind.replies,
  }) => moments * ((kind == BlindKind.openers ? 2 : 1) + 2 * prompts);

  static String _rate(int fooled, int of) =>
      '$fooled of $of (${of == 0 ? 0 : (fooled * 100 / of).round()}%)';

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// How [result] compares with the built-in prompt in [run], in words.
  static String versusBuiltIn(BlindRun run, BlindPromptResult result) {
    final base = run.builtIn;
    if (base == null || identical(base, result)) return '';
    final n = math.min(base.pairs.length, result.pairs.length);
    if (!clearlyDifferent(n, result.judgeFoolRate, base.judgeFoolRate)) {
      return 'Too close to call against Built-in — try New moments';
    }
    return result.judgeFoolRate > base.judgeFoolRate
        ? 'Clearly better than Built-in'
        : 'Clearly worse than Built-in';
  }

  /// [run] as plain text to share. With [scoresOnly], nothing from the
  /// chat and no prompt text is included.
  static String report(
    BlindRun run, {
    required String them,
    bool scoresOnly = false,
  }) {
    final at = run.at;
    final out = StringBuffer(
      'Ditto blind test${run.kind == BlindKind.openers ? " (openers)" : ""} '
      '· $them · ${at.day} ${_months[at.month - 1]} '
      '${at.year} · prompt v${run.promptVersion} · ${run.replyModel}\n',
    );
    for (final r in run.results) {
      out.write(
        '\n${r.prompt.label}: passed as you ${_rate(r.judgeFooled, r.pairs.length)} '
        'with the judge',
      );
      if (r.played) {
        out.write(', ${_rate(r.userFooled, r.pairs.length)} with you');
      }
      final versus = versusBuiltIn(run, r);
      if (versus.isNotEmpty) out.write('. $versus');
      out.writeln();
    }
    if (scoresOnly) return out.toString().trimRight();

    for (final r in run.results) {
      out
        ..writeln()
        ..writeln('== ${r.prompt.label} ==')
        ..writeln('Prompt:')
        ..writeln(r.prompt.text.trim())
        ..writeln()
        ..writeln('Spotted (${r.misses.length}):');
      for (final p in r.misses) {
        out
          ..writeln()
          ..writeln(
            p.context.map((t) => '${t.sender}: ${_flat(t.text)}').join('\n'),
          )
          ..write(p.setup.isEmpty ? '' : '${p.setup}\n')
          ..writeln('You: ${_flat(p.real)}')
          ..writeln('Generated: ${_flat(p.generated)}')
          ..writeln('Judge: ${p.why.isEmpty ? '(no reason)' : p.why}');
      }
    }
    return out.toString().trimRight();
  }
}

/// Runs the blind test on one chat, with the same retrieval and reply
/// writing the app uses for real.
class BlindTester {
  const BlindTester({
    required this.memory,
    required this.generator,
    required this.openai,
  });

  final StyleMemoryService memory;
  final ReplyGenerator generator;
  final OpenAiService openai;

  /// Fewer fair moments than this and a score would mean nothing.
  static const int minMoments = 5;

  /// Tests each of [prompts] on the same moments from [chat], picked by
  /// [seed]. [settings] must carry the chat's names. [onProgress] is told
  /// after each moment; throwing from it stops the run.
  Future<BlindRun> run({
    required ChatMemory chat,
    required AppSettings settings,
    required List<BlindPrompt> prompts,
    required int seed,
    void Function(int done, int of)? onProgress,
  }) async {
    final rows = await memory.store.all(chatIds: {chat.id});
    final moments = BlindTest.pickMoments(
      rows,
      me: settings.myName,
      seed: seed,
    );
    if (moments.length < minMoments) {
      throw OpenAiException(
        OpenAiErrorKind.badRequest,
        "There aren't enough of your replies to ${settings.theirName} to "
        'test with: it needs at least $minMoments.',
      );
    }

    final pairs = [for (final _ in prompts) <BlindPair>[]];
    onProgress?.call(0, moments.length);
    for (final (i, moment) in moments.indexed) {
      final exclude = BlindTest.excluding(moment);
      final retrieved = await memory.retrieve(
        context: moment.context,
        embeddingModel: settings.embeddingModel,
        dimensions: settings.embeddingDimensions,
        limit: settings.retrievedExampleCount,
        chatIds: {chat.id},
        preferChatId: chat.id,
        queryTurns: settings.contextTurns,
        exclude: exclude,
      );
      final voice = await memory.voiceSample(
        chatIds: {chat.id},
        preferChatId: chat.id,
        exclude: exclude,
      );
      final realIsA = math.Random(seed + i).nextBool();
      for (final (j, prompt) in prompts.indexed) {
        final replies = await generator.generate(
          conversation: moment.context,
          examples: retrieved.examples,
          settings: settings.copyWith(
            systemPrompt: prompt.text,
            variantCount: 1,
          ),
          profile: chat.profile,
          voiceSample: voice,
          group: chat.isGroup,
        );
        pairs[j].add(
          await _judge(
            settings: settings,
            context: moment.context,
            real: moment.replyText,
            generated: replies.isEmpty ? '' : replies.first.text,
            realIsA: realIsA,
            voice: voice,
          ),
        );
      }
      onProgress?.call(i + 1, moments.length);
    }
    return BlindRun(
      at: DateTime.now(),
      replyModel: settings.generationModel,
      promptVersion: ReplyGenerator.promptVersion,
      results: [
        for (final (j, prompt) in prompts.indexed)
          BlindPromptResult(prompt: prompt, pairs: pairs[j]),
      ],
    );
  }

  /// The same for openers: real times you started the chat up again after
  /// it went quiet. To make it fair, the writer gets what you would give the
  /// app — how the chat ended, how long it was quiet, and what you brought
  /// up (in a plain line with none of your words, standing in for "what
  /// happened in your day") — plus the past moments that line finds, with
  /// the hours around the opener kept out. The judge is told the writer
  /// knew what you brought up, so it judges how it was said.
  Future<BlindRun> runOpeners({
    required ChatMemory chat,
    required AppSettings settings,
    required List<BlindPrompt> prompts,
    required int seed,
    void Function(int done, int of)? onProgress,
  }) async {
    final rows = await memory.store.all(chatIds: {chat.id});
    final moments = BlindTest.pickOpeners(rows, seed: seed);
    if (moments.length < minMoments) {
      throw OpenAiException(
        OpenAiErrorKind.badRequest,
        "There aren't enough times you started the chat with "
        '${settings.theirName} again after it went quiet: it needs at least '
        '$minMoments, each after ${BlindTest.minQuiet.inHours} hours or more '
        'of quiet.',
      );
    }

    final pairs = [for (final _ in prompts) <BlindPair>[]];
    onProgress?.call(0, moments.length);
    for (final (i, moment) in moments.indexed) {
      final exclude = BlindTest.excludingOpener(moment);
      final kept = [
        for (final r in rows)
          if (!exclude(r)) r,
      ];
      final topic = (await openai.chat(
        model: settings.generationModel,
        messages: [
          {'role': 'system', 'content': BlindTest.topicSystem(settings.myName)},
          {'role': 'user', 'content': moment.replyText},
        ],
        temperature: 0,
      )).trim();
      final vectors = await openai.embed(
        [topic],
        model: settings.embeddingModel,
        dimensions: settings.embeddingDimensions,
      );
      final related = [
        for (final m in ChatSearch.score(
          VectorMath.normalise(vectors.first),
          topic,
          kept,
        )..sort((a, b) => b.total.compareTo(a.total)))
          m.exchange,
      ].take(ReplyGenerator.relatedCount).toList();
      final voice = await memory.voiceSample(
        chatIds: {chat.id},
        preferChatId: chat.id,
        exclude: exclude,
      );
      final quiet = BlindTest.quietBefore(moment) ?? BlindTest.minQuiet;
      final setup = BlindTest.openerSetup(quiet: quiet, topic: topic);
      final realIsA = math.Random(seed + i).nextBool();
      for (final (j, prompt) in prompts.indexed) {
        final written = await generator.openers(
          settings: settings.copyWith(systemPrompt: prompt.text),
          recent: moment.context,
          profile: chat.profile,
          voiceSample: voice,
          quietFor: ReplyGenerator.quietFor(quiet),
          group: chat.isGroup,
          count: 1,
          day: topic,
          related: related,
        );
        pairs[j].add(
          await _judge(
            settings: settings,
            context: moment.context,
            real: moment.replyText,
            generated: written.isEmpty ? '' : written.first,
            realIsA: realIsA,
            voice: voice,
            kind: BlindKind.openers,
            setup: setup,
          ),
        );
      }
      onProgress?.call(i + 1, moments.length);
    }
    return BlindRun(
      at: DateTime.now(),
      kind: BlindKind.openers,
      replyModel: settings.generationModel,
      promptVersion: ReplyGenerator.promptVersion,
      results: [
        for (final (j, prompt) in prompts.indexed)
          BlindPromptResult(prompt: prompt, pairs: pairs[j]),
      ],
    );
  }

  /// Has the judge pick which of [real] and [generated] you sent.
  Future<BlindPair> _judge({
    required AppSettings settings,
    required List<ChatTurn> context,
    required String real,
    required String generated,
    required bool realIsA,
    required List<String> voice,
    BlindKind kind = BlindKind.replies,
    String setup = '',
  }) async {
    final raw = await openai.chat(
      model: settings.generationModel,
      messages: [
        {
          'role': 'system',
          'content': BlindTest.judgeSystem(
            me: settings.myName,
            them: settings.theirName,
            realReplies: voice.take(BlindTest.judgeSampleCount).toList(),
            kind: kind,
          ),
        },
        {
          'role': 'user',
          'content': BlindTest.judgeUser(
            context: context,
            a: realIsA ? real : generated,
            b: realIsA ? generated : real,
            setup: setup,
          ),
        },
      ],
      jsonMode: true,
      temperature: 0,
    );
    final (pick, why) = BlindTest.parseJudge(raw);
    return BlindPair(
      context: context,
      real: real,
      generated: generated,
      realIsA: realIsA,
      judgePick: pick,
      why: why,
      setup: setup,
    );
  }
}
