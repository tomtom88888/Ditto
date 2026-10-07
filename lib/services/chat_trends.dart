import 'dart:math' as math;

import '../models/stored_exchange.dart';

/// One month of a chat, each side's numbers.
class MonthTrend {
  MonthTrend(this.month);

  /// The first day of the month.
  final DateTime month;

  int mine = 0;
  int theirs = 0;
  int myWords = 0;
  int theirWords = 0;
  int myTurns = 0;
  int theirTurns = 0;
  int iStarted = 0;
  int theyStarted = 0;
  int myLaughs = 0;
  int theirLaughs = 0;
  final List<int> myReplyMinutes = [];
  final List<int> theirReplyMinutes = [];

  int get total => mine + theirs;

  double get myAverageWords => myTurns == 0 ? 0 : myWords / myTurns;
  double get theirAverageWords => theirTurns == 0 ? 0 : theirWords / theirTurns;

  /// Median minutes before an answer, or `null` with none counted.
  int? get myReply => _median(myReplyMinutes);
  int? get theirReply => _median(theirReplyMinutes);

  /// Their share of the conversations started, or `null` with none.
  double? get theirStartShare {
    final all = iStarted + theyStarted;
    return all == 0 ? null : theyStarted / all;
  }

  double get theirLaughShare => theirTurns == 0 ? 0 : theirLaughs / theirTurns;

  static int? _median(List<int> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }
}

/// Which way a chat is heading, judged from the last two months against the
/// three before.
enum TrendDirection { warming, steady, cooling, unknown }

/// How a chat has changed month by month: how much each of you writes, how
/// fast the other person answers, who starts conversations, how much they
/// laugh. Counted on the phone from the stored messages; no API calls.
///
/// The app keeps your replies and the messages leading up to each, not the
/// whole export, so their side is rebuilt from those lead-ups. In practice
/// that is nearly every message, since most messages lead up to a reply.
class ChatTrends {
  const ChatTrends({
    required this.months,
    required this.direction,
    required this.notes,
    this.lastMessageAt,
  });

  final List<MonthTrend> months;
  final TrendDirection direction;

  /// What changed, in plain sentences, most telling first.
  final List<String> notes;
  final DateTime? lastMessageAt;

  bool get isEmpty => months.isEmpty;

  /// A gap this long starts a new conversation.
  static const Duration newConversation = Duration(hours: 6);

  /// Answers slower than this aren't counted as reply times.
  static const Duration slowestReply = Duration(hours: 12);

  static final RegExp _space = RegExp(r'\s+');
  static final RegExp _laugh = RegExp(
    r'(?:\b(?:a?ha(?:ha)+|he(?:he)+|lo+l|lmf?ao|rofl|xd)\b|😂|🤣|😆|ח{3,}|ההה+)',
    caseSensitive: false,
    unicode: true,
  );

  static ChatTrends of(
    List<StoredExchange> exchanges, {
    required String myName,
    String them = 'They',
  }) {
    final turns = _timeline(exchanges, myName);
    if (turns.isEmpty) {
      return const ChatTrends(
        months: [],
        direction: TrendDirection.unknown,
        notes: [],
      );
    }
    final byMonth = <DateTime, MonthTrend>{};
    MonthTrend monthOf(DateTime at) {
      final key = DateTime(at.year, at.month);
      return byMonth.putIfAbsent(key, () => MonthTrend(key));
    }

    _Turn? previous;
    for (final t in turns) {
      final m = monthOf(t.at);
      final words = t.text.trim().split(_space).where((w) => w.isNotEmpty);
      final laughs = _laugh.hasMatch(t.text);
      if (t.mine) {
        m
          ..mine += t.count
          ..myTurns += 1
          ..myWords += words.length
          ..myLaughs += laughs ? 1 : 0;
      } else {
        m
          ..theirs += t.count
          ..theirTurns += 1
          ..theirWords += words.length
          ..theirLaughs += laughs ? 1 : 0;
      }
      final gap = previous == null ? null : t.at.difference(previous.end);
      if (gap == null || gap > newConversation) {
        t.mine ? m.iStarted++ : m.theyStarted++;
      } else if (previous!.mine != t.mine && gap <= slowestReply) {
        final minutes = math.max(0, gap.inMinutes);
        (t.mine ? m.myReplyMinutes : m.theirReplyMinutes).add(minutes);
      }
      previous = t;
    }

    // Every month from the first to the last, quiet ones included.
    final first = turns.first.at;
    final last = turns.last.at;
    final months = <MonthTrend>[];
    for (
      var at = DateTime(first.year, first.month);
      !at.isAfter(DateTime(last.year, last.month));
      at = DateTime(at.year, at.month + 1)
    ) {
      months.add(byMonth[at] ?? MonthTrend(at));
    }
    final (direction, notes) = _judge(months, them);
    return ChatTrends(
      months: months,
      direction: direction,
      notes: notes,
      lastMessageAt: last,
    );
  }

  /// Every message in the stored exchanges once, oldest first.
  static List<_Turn> _timeline(List<StoredExchange> exchanges, String myName) {
    final seen = <String>{};
    final out = <_Turn>[];
    void add(String sender, DateTime? at, DateTime? end, String text, int n) {
      if (at == null || text.trim().isEmpty) return;
      if (!seen.add('$sender\u0000${at.millisecondsSinceEpoch}\u0000$text')) {
        return;
      }
      out.add(
        _Turn(
          mine: sender == myName,
          at: at,
          end: end ?? at,
          text: text,
          count: math.max(1, n),
        ),
      );
    }

    for (final e in exchanges) {
      for (final t in e.context) {
        add(
          t.sender,
          t.firstTimestamp ?? t.lastTimestamp,
          t.lastTimestamp,
          t.text,
          t.messageCount,
        );
      }
      add(
        myName,
        e.timestamp,
        e.timestamp,
        e.replyText,
        '\n'.allMatches(e.replyText.trim()).length + 1,
      );
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  /// The last two months with messages against the three before them.
  static (TrendDirection, List<String>) _judge(
    List<MonthTrend> months,
    String them,
  ) {
    final active = [
      for (final m in months)
        if (m.total > 0) m,
    ];
    if (active.length < 3) return (TrendDirection.unknown, const []);
    final recent = active.sublist(active.length - 2);
    final before = active.sublist(
      math.max(0, active.length - 5),
      active.length - 2,
    );

    double avg(List<MonthTrend> ms, double Function(MonthTrend) f) =>
        ms.map(f).reduce((a, b) => a + b) / ms.length;
    int? medianOf(List<MonthTrend> ms, List<int> Function(MonthTrend) f) =>
        MonthTrend._median([for (final m in ms) ...f(m)]);

    var points = 0;
    final notes = <String>[];

    final volumeNow = avg(recent, (m) => m.total.toDouble());
    final volumeThen = avg(before, (m) => m.total.toDouble());
    if (volumeThen > 0) {
      final ratio = volumeNow / volumeThen;
      if (ratio >= 1.25) {
        points++;
        notes.add(
          ratio >= 1.9
              ? 'You talk ${ratio.toStringAsFixed(1)}× as much as a few '
                    'months ago.'
              : 'You talk ${((ratio - 1) * 100).round()}% more than a few '
                    'months ago.',
        );
      } else if (ratio <= 0.75) {
        points--;
        notes.add(
          'You talk ${((1 - ratio) * 100).round()}% less than a few months '
          'ago.',
        );
      }
    }

    final replyNow = medianOf(recent, (m) => m.theirReplyMinutes);
    final replyThen = medianOf(before, (m) => m.theirReplyMinutes);
    if (replyNow != null && replyThen != null && replyThen > 0) {
      if (replyNow <= replyThen * 0.75 && replyThen - replyNow >= 2) {
        points++;
        notes.add(
          '$them answers faster: ${minutesLabel(replyNow)}, down from '
          '${minutesLabel(replyThen)}.',
        );
      } else if (replyNow >= replyThen * 1.33 && replyNow - replyThen >= 2) {
        points--;
        notes.add(
          '$them takes longer to answer: ${minutesLabel(replyNow)}, up from '
          '${minutesLabel(replyThen)}.',
        );
      }
    }

    double? startShare(List<MonthTrend> ms) {
      final mine = ms.fold(0, (s, m) => s + m.iStarted);
      final theirs = ms.fold(0, (s, m) => s + m.theyStarted);
      return mine + theirs == 0 ? null : theirs / (mine + theirs);
    }

    final startNow = startShare(recent);
    final startThen = startShare(before);
    if (startNow != null && startThen != null) {
      if (startNow >= startThen + 0.15) {
        points++;
        notes.add(
          '$them starts more of your conversations: '
          '${(startNow * 100).round()}%, up from ${(startThen * 100).round()}%.',
        );
      } else if (startNow <= startThen - 0.15) {
        points--;
        notes.add(
          '$them starts fewer of your conversations: '
          '${(startNow * 100).round()}%, down from '
          '${(startThen * 100).round()}%.',
        );
      }
    }

    final wordsNow = avg(recent, (m) => m.theirAverageWords);
    final wordsThen = avg(before, (m) => m.theirAverageWords);
    if (wordsThen > 0) {
      if (wordsNow >= wordsThen * 1.2) {
        points++;
        notes.add('$them writes longer messages than before.');
      } else if (wordsNow <= wordsThen * 0.8) {
        points--;
        notes.add('$them writes shorter messages than before.');
      }
    }

    final laughNow = avg(recent, (m) => m.theirLaughShare);
    final laughThen = avg(before, (m) => m.theirLaughShare);
    if (laughNow >= laughThen + 0.08) {
      points++;
      notes.add('$them laughs more than before.');
    } else if (laughNow <= laughThen - 0.08) {
      points--;
      notes.add('$them laughs less than before.');
    }

    final direction = points >= 2
        ? TrendDirection.warming
        : points <= -2
        ? TrendDirection.cooling
        : TrendDirection.steady;
    return (direction, notes);
  }

  /// "4 min", "1 h 20", "3 h".
  static String minutesLabel(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h h' : '$h h ${m.toString().padLeft(2, '0')}';
  }
}

class _Turn {
  _Turn({
    required this.mine,
    required this.at,
    required this.end,
    required this.text,
    required this.count,
  });

  final bool mine;
  final DateTime at;
  final DateTime end;
  final String text;
  final int count;
}
