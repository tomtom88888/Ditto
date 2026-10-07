import 'dart:convert';
import 'dart:typed_data';

import 'chat_app.dart';
import 'chat_stats.dart';
import 'chat_turn.dart';
import 'exchange.dart';
import 'style_profile.dart';

/// Where a stored exchange came from.
enum ExchangeSource {
  /// Parsed out of a WhatsApp export.
  export,

  /// A suggestion you starred as one you actually sent.
  saved,
}

/// An [Exchange] as it lives in the local database, with its embedding.
class StoredExchange {
  const StoredExchange({
    required this.id,
    required this.context,
    required this.contextText,
    required this.replyText,
    required this.vector,
    this.focus,
    this.timestamp,
    this.chatId = -1,
    this.hash = '',
    this.source = ExchangeSource.export,
  });

  /// Row id; -1 before insertion.
  final int id;

  /// The chat this belongs to; -1 before insertion.
  final int chatId;

  /// The turns leading up to the reply, oldest first.
  final List<ChatTurn> context;

  /// Exactly the text that was embedded.
  final String contextText;

  final String replyText;

  /// Unit-length embedding, so cosine similarity is a plain dot product.
  final Float32List vector;

  /// A tighter fingerprint of just the moment itself — the last messages
  /// before the reply, and the reply — for search. `null` until made.
  final Float32List? focus;

  /// The turns before the reply that [focusText] covers.
  static const int focusTurns = 2;

  /// What [focus] fingerprints.
  String get focusText => focusTextOf(context, replyText);

  static String focusTextOf(List<ChatTurn> context, String replyText) {
    final recent = context.length > focusTurns
        ? context.sublist(context.length - focusTurns)
        : context;
    return [
      for (final t in recent) '${t.sender}: ${t.text}',
      'Me: $replyText',
    ].join('\n');
  }

  final DateTime? timestamp;

  /// Identifies the exchange's content, so re-importing an export only embeds
  /// what is new. See [contentHash].
  final String hash;

  final ExchangeSource source;

  StoredExchange copyWith({int? id, int? chatId, Float32List? focus}) =>
      StoredExchange(
        id: id ?? this.id,
        chatId: chatId ?? this.chatId,
        context: context,
        contextText: contextText,
        replyText: replyText,
        vector: vector,
        focus: focus ?? this.focus,
        timestamp: timestamp,
        hash: hash,
        source: source,
      );

  /// A stable fingerprint of an exchange's text: 64-bit FNV-1a over the
  /// context, a separator, and the reply.
  ///
  /// Not cryptographic, and it doesn't need to be: it only has to tell apart
  /// exchanges within one person's chat, where a collision costs one skipped
  /// example.
  static String contentHash(String contextText, String replyText) {
    // FNV-1a 64-bit, split into two 32-bit halves so it behaves the same on
    // every platform Dart runs on.
    var hi = 0xcbf29ce4;
    var lo = 0x84222325;
    for (final byte in utf8.encode('$contextText\u0000$replyText')) {
      lo ^= byte;
      // Multiply the 64-bit value (hi:lo) by the FNV prime 0x100000001b3.
      final loTimes = lo * 0x1b3;
      final carry = loTimes ~/ 0x100000000;
      final newLo = loTimes & 0xffffffff;
      final newHi = (hi * 0x1b3 + (lo << 8) + carry) & 0xffffffff;
      hi = newHi;
      lo = newLo;
    }
    return hi.toRadixString(16).padLeft(8, '0') +
        lo.toRadixString(16).padLeft(8, '0');
  }

  static String hashOf(Exchange exchange) =>
      contentHash(exchange.contextText, exchange.replyText);
}

/// A [StoredExchange] together with how similar it was to the query.
class ScoredExchange {
  const ScoredExchange({required this.exchange, required this.similarity});

  final StoredExchange exchange;

  /// Cosine similarity in [-1, 1].
  final double similarity;
}

/// One learned conversation: whose chat it is, what it was built with, and
/// whether generation draws on it.
///
/// Shown as a checkable row on the home screen, so you can choose which of
/// your voices a reply is written in — how you text a partner is not how you
/// text your manager.
class ChatMemory {
  const ChatMemory({
    this.id = -1,
    required this.myName,
    required this.theirName,
    required this.embeddingModel,
    required this.dimensions,
    required this.builtAt,
    this.exchangeCount = 0,
    this.savedCount = 0,
    this.enabled = true,
    this.profile = StyleProfile.empty,
    this.stats = ChatStats.empty,
    this.isGroup = false,
    this.app = ChatApp.whatsapp,
    this.from,
    this.until,
    this.allCount,
  });

  /// Row id; -1 before insertion.
  final int id;

  final String myName;
  final String theirName;
  final String embeddingModel;
  final int dimensions;

  /// When an export was last imported into it.
  final DateTime builtAt;

  /// Exchanges stored, including [savedCount].
  final int exchangeCount;

  /// Exchanges added by starring a suggestion rather than from an export.
  final int savedCount;

  /// Whether generation retrieves from this chat.
  final bool enabled;

  /// How you write in this chat, measured from the export. Used in the
  /// prompt.
  final StyleProfile profile;

  /// The chat's numbers — message counts, reply times, when you talk — for
  /// the chat data screen. Empty for a chat last imported before these were
  /// counted.
  final ChatStats stats;

  /// A group chat: [theirName] is the group's name, and the other side is
  /// several people, each named in what they say.
  final bool isGroup;

  /// The app the export came from.
  final ChatApp app;

  /// The first day of the chat that is used, when cut down; `null` from the
  /// start.
  final DateTime? from;

  /// The last day used, when cut down; `null` to the end.
  final DateTime? until;

  /// Every stored exchange, in the dates or not. [exchangeCount] counts only
  /// those in them.
  final int? allCount;

  /// Whether the chat is cut down to some of its dates.
  bool get isCut => from != null || until != null;

  /// Whether [e] falls in the dates used. Starred replies, and moments with
  /// no date, always do.
  bool covers(StoredExchange e) {
    if (e.source == ExchangeSource.saved) return true;
    final at = e.timestamp;
    if (at == null) return true;
    if (from != null && at.isBefore(from!)) return false;
    if (until != null && !at.isBefore(untilExclusive!)) return false;
    return true;
  }

  /// The start of the day after [until].
  DateTime? get untilExclusive => until == null
      ? null
      : DateTime(until!.year, until!.month, until!.day + 1);

  bool get isEmpty => exchangeCount == 0;

  /// When the newest message in the imported export was sent, if known.
  DateTime? get lastMessageAt => stats.isEmpty ? null : stats.lastAt;

  /// How old an export can get before a newer one should be imported.
  static const Duration freshFor = Duration(days: 30);

  /// Whether the export ends more than [freshFor] before [now]: the chat has
  /// likely moved on since, and replies won't know about it.
  bool isOutOfDate([DateTime? now]) {
    final last = lastMessageAt;
    return last != null && (now ?? DateTime.now()).difference(last) > freshFor;
  }

  /// Whether this chat's vectors can be compared with a query embedded using
  /// [model] at [dims].
  bool matches(String model, int dims) =>
      embeddingModel == model && dimensions == dims;

  ChatMemory copyWith({
    int? id,
    String? myName,
    String? theirName,
    String? embeddingModel,
    int? dimensions,
    DateTime? builtAt,
    int? exchangeCount,
    int? savedCount,
    bool? enabled,
    StyleProfile? profile,
    ChatStats? stats,
    bool? isGroup,
    ChatApp? app,
  }) => ChatMemory(
    id: id ?? this.id,
    myName: myName ?? this.myName,
    theirName: theirName ?? this.theirName,
    embeddingModel: embeddingModel ?? this.embeddingModel,
    dimensions: dimensions ?? this.dimensions,
    builtAt: builtAt ?? this.builtAt,
    exchangeCount: exchangeCount ?? this.exchangeCount,
    savedCount: savedCount ?? this.savedCount,
    enabled: enabled ?? this.enabled,
    profile: profile ?? this.profile,
    stats: stats ?? this.stats,
    isGroup: isGroup ?? this.isGroup,
    app: app ?? this.app,
    from: from,
    until: until,
    allCount: allCount,
  );

  /// This chat cut down to [from]–[until]; both `null` for the whole chat.
  ChatMemory withDates(DateTime? from, DateTime? until) => ChatMemory(
    id: id,
    myName: myName,
    theirName: theirName,
    embeddingModel: embeddingModel,
    dimensions: dimensions,
    builtAt: builtAt,
    exchangeCount: exchangeCount,
    savedCount: savedCount,
    enabled: enabled,
    profile: profile,
    stats: stats,
    isGroup: isGroup,
    app: app,
    from: from,
    until: until,
    allCount: allCount,
  );

  @override
  String toString() =>
      'ChatMemory($id: $myName -> $theirName, '
      '$exchangeCount exchanges${enabled ? "" : ", off"})';
}
