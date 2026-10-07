import 'dart:convert';
import 'dart:math' as math;

import '../models/api_usage.dart';
import '../models/stored_exchange.dart';
import 'openai_exception.dart';
import 'openai_service.dart';

/// What a chart counts, per bucket.
enum ChartMeasure {
  messages('messages', 'messages sent'),
  words('words', 'words written'),
  avgWords('avg_words', 'average words per message'),
  replyMinutes('reply_minutes', 'median minutes to answer the other side'),
  started('started', 'conversations started (after 6+ hours of quiet)'),
  laughs('laughs', 'messages that laugh (haha, lol, 😂, חחח)'),
  emoji('emoji', 'emoji used'),
  questions('questions', 'messages asking a question'),
  contains('contains', 'messages containing any of "terms"');

  const ChartMeasure(this.id, this.meaning);

  final String id;
  final String meaning;

  static ChartMeasure? parse(Object? raw) {
    for (final m in values) {
      if (m.id == raw) return m;
    }
    return null;
  }
}

/// What the bars or points along the bottom are.
enum ChartAxis {
  month('month'),
  week('week'),
  day('day'),
  weekday('weekday'),
  hour('hour'),
  total('total');

  const ChartAxis(this.id);

  final String id;

  static ChartAxis parse(Object? raw) =>
      values.firstWhere((a) => a.id == raw, orElse: () => ChartAxis.month);
}

enum ChartKind { bar, line }

/// Whose messages a series counts.
enum ChartWho { me, them, both }

class ChartSeries {
  const ChartSeries({
    required this.label,
    required this.who,
    required this.measure,
    this.terms = const [],
  });

  final String label;
  final ChartWho who;
  final ChartMeasure measure;

  /// For [ChartMeasure.contains]: words or phrases, any of which counts.
  final List<String> terms;

  Map<String, Object?> toJson() => {
    'label': label,
    'who': who.name,
    'measure': measure.id,
    if (terms.isNotEmpty) 'terms': terms,
  };
}

/// A chart, as described: what to count, along what, drawn how. Holds no
/// data, so it can be counted again for another chat.
class ChartSpec {
  const ChartSpec({
    required this.title,
    required this.kind,
    required this.axis,
    required this.series,
    this.lastMonths,
    this.note,
  });

  final String title;
  final ChartKind kind;
  final ChartAxis axis;
  final List<ChartSeries> series;

  /// Only the most recent this many months, when set.
  final int? lastMonths;

  /// Something the reader should know, such as a part of the request that
  /// couldn't be drawn.
  final String? note;

  /// The most series on one chart; more would need more colours than can be
  /// told apart.
  static const int maxSeries = 3;

  /// Reads the model's answer. Series measuring something other than the
  /// first series are dropped, so the chart keeps a single axis.
  static ChartSpec parse(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    Object? json;
    if (start >= 0 && end > start) {
      try {
        json = jsonDecode(raw.substring(start, end + 1));
      } on FormatException {
        json = null;
      }
    }
    if (json is! Map) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        "Couldn't turn that into a chart. Try describing it differently.",
      );
    }
    final error = json['error'];
    if (error is String && error.trim().isNotEmpty) {
      throw OpenAiException(OpenAiErrorKind.badRequest, error.trim());
    }
    final series = <ChartSeries>[];
    final rawSeries = json['series'];
    if (rawSeries is List) {
      for (final s in rawSeries.whereType<Map<String, Object?>>()) {
        final measure = ChartMeasure.parse(s['measure']);
        if (measure == null) continue;
        final who = ChartWho.values.firstWhere(
          (w) => w.name == s['who'],
          orElse: () => ChartWho.both,
        );
        final terms = s['terms'];
        series.add(
          ChartSeries(
            label: s['label'] is String ? (s['label'] as String).trim() : '',
            who: who,
            measure: measure,
            terms: [
              if (terms is List)
                for (final t in terms)
                  if (t is String && t.trim().isNotEmpty) t.trim(),
              if (terms is String && terms.trim().isNotEmpty) terms.trim(),
            ],
          ),
        );
      }
    }
    if (series.isEmpty) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        "Couldn't tell what to count. Try naming it: messages, words, reply "
        'times, laughs, a word you use…',
      );
    }
    var note = json['note'] is String ? (json['note'] as String).trim() : '';
    final measure = series.first.measure;
    final kept = series.where((s) => s.measure == measure).toList();
    if (kept.length < series.length) {
      note =
          '${note.isEmpty ? "" : "$note "}Only one kind of number fits one '
          'chart; ask for the rest separately.';
    }
    if (kept.length > maxSeries) kept.removeRange(maxSeries, kept.length);
    final months = json['last_months'];
    final kind = json['kind'] == 'line' ? ChartKind.line : ChartKind.bar;
    final title = json['title'];
    return ChartSpec(
      title: title is String && title.trim().isNotEmpty
          ? title.trim()
          : 'Your chart',
      kind: kind,
      axis: ChartAxis.parse(json['x']),
      series: kept,
      lastMonths: months is num && months > 0 ? months.toInt() : null,
      note: note.isEmpty ? null : note,
    );
  }
}

/// A chart counted: a label per bucket and a value per series per bucket.
class ChartData {
  const ChartData({
    required this.spec,
    required this.labels,
    required this.values,
  });

  final ChartSpec spec;

  /// One per bucket, along the bottom.
  final List<String> labels;

  /// values[series][bucket]; `null` where there was nothing to measure.
  final List<List<double?>> values;

  bool get isEmpty =>
      labels.isEmpty ||
      values.every((s) => s.every((v) => v == null || v == 0));

  double get peak => values
      .expand((s) => s)
      .whereType<double>()
      .fold(0.0, (a, b) => math.max(a, b));
}

/// Turns a description into a chart: one small request that writes a
/// [ChartSpec] (no chat text is sent, only the description and names), then
/// [count] works the numbers out on the phone.
class ChartMaker {
  const ChartMaker({required this.openai});

  final OpenAiService openai;

  Future<ChartSpec> design(
    String description, {
    required String model,
    required String me,
    required String them,
  }) async {
    final raw = await openai.chat(
      model: model,
      messages: [
        {'role': 'system', 'content': prompt(me: me, them: them)},
        {'role': 'user', 'content': description.trim()},
      ],
      jsonMode: true,
      temperature: 0,
      usageKind: UsageKind.generation,
    );
    return ChartSpec.parse(raw);
  }

  static String prompt({required String me, required String them}) =>
      'You turn a request for a chart about a chat between $me ("me") and '
      '$them ("them") into a chart spec. The chart is counted from the '
      'messages on the phone; you never see them.\n\n'
      'Measures (per bucket): '
      '${ChartMeasure.values.map((m) => '"${m.id}" = ${m.meaning}').join('; ')}.\n'
      'x: "month", "week", "day", "weekday" (Mon to Sun), "hour" (0 to 23), '
      'or "total" (one value per series, for comparisons).\n'
      'who: "me", "them" or "both".\n'
      'kind: "line" for change over time, "bar" otherwise.\n\n'
      'Answer only with JSON: {"title": "<short, plain>", "kind": ..., '
      '"x": ..., "series": [{"label": "<e.g. You, $them>", "who": ..., '
      '"measure": ..., "terms": ["only for contains: the words, as they '
      'would be written in the chat, with likely variants and spellings"]}], '
      '"last_months": <a number, only if the request limits the time>, '
      '"note": "<only if part of the request can\'t be drawn>"}.\n'
      'At most ${ChartSpec.maxSeries} series, all with the same measure '
      '(one chart has one axis). Comparing me and them means one series '
      'each. If nothing in the request can be counted with these measures, '
      'answer {"error": "<one short sentence on what can be charted>"}.';

  // ----------------------------------------------------------------- counting

  static final RegExp _space = RegExp(r'\s+');
  static final RegExp _laugh = RegExp(
    r'(?:\b(?:a?ha(?:ha)+|he(?:he)+|lo+l|lmf?ao|rofl|xd)\b|😂|🤣|😆|ח{3,}|ההה+)',
    caseSensitive: false,
    unicode: true,
  );
  static final RegExp _emoji = RegExp(
    r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]',
    unicode: true,
  );

  /// A gap this long starts a new conversation.
  static const Duration newConversation = Duration(hours: 6);

  /// Answers slower than this aren't counted as reply times.
  static const Duration slowestReply = Duration(hours: 12);

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static const List<String> _weekdays = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  /// Most buckets drawn along time; older ones are left out.
  static const Map<ChartAxis, int> maxBuckets = {
    ChartAxis.month: 24,
    ChartAxis.week: 26,
    ChartAxis.day: 45,
  };

  /// Counts [spec] over [exchanges], the chat's stored moments.
  static ChartData count(
    ChartSpec spec,
    List<StoredExchange> exchanges, {
    required String myName,
  }) {
    var turns = timeline(exchanges, myName);
    if (spec.lastMonths != null && turns.isNotEmpty) {
      final last = turns.last.at;
      final from = DateTime(last.year, last.month - spec.lastMonths! + 1);
      turns = [
        for (final t in turns)
          if (!t.at.isBefore(from)) t,
      ];
    }
    if (turns.isEmpty) {
      return ChartData(spec: spec, labels: const [], values: const []);
    }

    // Each bucket's key, in order.
    final keys = _keys(spec.axis, turns.first.at, turns.last.at);
    final index = {for (final (i, k) in keys.indexed) k: i};
    final perSeries = [
      for (final _ in spec.series) [for (final _ in keys) _Bucket()],
    ];

    ChartTurn? previous;
    for (final t in turns) {
      final b = index[_keyOf(spec.axis, t.at)];
      final gap = previous == null ? null : t.at.difference(previous.end);
      final starts = gap == null || gap > newConversation;
      final reply = !starts && previous!.mine != t.mine && gap <= slowestReply
          ? math.max(0, gap.inMinutes)
          : null;
      previous = t;
      if (b == null) continue;
      for (final (si, s) in spec.series.indexed) {
        final counts = switch (s.who) {
          ChartWho.me => t.mine,
          ChartWho.them => !t.mine,
          ChartWho.both => true,
        };
        if (!counts) continue;
        perSeries[si][b].add(t, s, starts: starts, reply: reply);
      }
    }

    return ChartData(
      spec: spec,
      labels: [for (final k in keys) _label(spec.axis, k)],
      values: [
        for (final (si, s) in spec.series.indexed)
          [for (final b in perSeries[si]) b.value(s.measure)],
      ],
    );
  }

  /// Every message in the stored moments once, oldest first: the lead-up
  /// to each of your replies, and the reply.
  static List<ChartTurn> timeline(
    List<StoredExchange> exchanges,
    String myName,
  ) {
    final seen = <String>{};
    final out = <ChartTurn>[];
    void add(String sender, DateTime? at, DateTime? end, String text, int n) {
      if (at == null || text.trim().isEmpty) return;
      if (!seen.add('$sender\u0000${at.millisecondsSinceEpoch}\u0000$text')) {
        return;
      }
      out.add(
        ChartTurn(
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

  static List<Object> _keys(ChartAxis axis, DateTime first, DateTime last) {
    switch (axis) {
      case ChartAxis.total:
        return const ['total'];
      case ChartAxis.weekday:
        return [for (var d = 1; d <= 7; d++) d];
      case ChartAxis.hour:
        return [for (var h = 0; h < 24; h++) h];
      case ChartAxis.month:
      case ChartAxis.week:
      case ChartAxis.day:
        final keys = <Object>[];
        var at = _start(axis, first);
        final end = _start(axis, last);
        while (!at.isAfter(end)) {
          keys.add(at);
          at = switch (axis) {
            ChartAxis.month => DateTime(at.year, at.month + 1),
            ChartAxis.week => DateTime(at.year, at.month, at.day + 7),
            _ => DateTime(at.year, at.month, at.day + 1),
          };
        }
        final most = maxBuckets[axis]!;
        return keys.length > most ? keys.sublist(keys.length - most) : keys;
    }
  }

  static DateTime _start(ChartAxis axis, DateTime at) => switch (axis) {
    ChartAxis.month => DateTime(at.year, at.month),
    ChartAxis.week => DateTime(at.year, at.month, at.day - (at.weekday - 1)),
    _ => DateTime(at.year, at.month, at.day),
  };

  static Object _keyOf(ChartAxis axis, DateTime at) => switch (axis) {
    ChartAxis.total => 'total',
    ChartAxis.weekday => at.weekday,
    ChartAxis.hour => at.hour,
    _ => _start(axis, at),
  };

  static String _label(ChartAxis axis, Object key) => switch (axis) {
    ChartAxis.total => '',
    ChartAxis.weekday => _weekdays[(key as int) - 1],
    ChartAxis.hour => '${key as int}',
    ChartAxis.month =>
      '${_months[(key as DateTime).month - 1]} '
          '${key.year.toString().substring(2)}',
    _ => '${(key as DateTime).day} ${_months[key.month - 1]}',
  };

  static int words(String text) =>
      text.trim().split(_space).where((w) => w.isNotEmpty).length;
}

/// One message (or run of messages) from one side.
class ChartTurn {
  const ChartTurn({
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

class _Bucket {
  int messages = 0;
  int turns = 0;
  int words = 0;
  int started = 0;
  int laughs = 0;
  int emoji = 0;
  int questions = 0;
  int contains = 0;
  final List<int> replies = [];

  void add(
    ChartTurn t,
    ChartSeries s, {
    required bool starts,
    required int? reply,
  }) {
    messages += t.count;
    turns++;
    words += ChartMaker.words(t.text);
    if (starts) started++;
    if (reply != null) replies.add(reply);
    if (ChartMaker._laugh.hasMatch(t.text)) laughs++;
    emoji += ChartMaker._emoji.allMatches(t.text).length;
    if (t.text.contains('?')) questions++;
    if (s.terms.isNotEmpty) {
      final lower = t.text.toLowerCase();
      if (s.terms.any((term) => lower.contains(term.toLowerCase()))) {
        contains++;
      }
    }
  }

  double? value(ChartMeasure m) => switch (m) {
    ChartMeasure.messages => messages.toDouble(),
    ChartMeasure.words => words.toDouble(),
    ChartMeasure.avgWords => turns == 0 ? null : words / turns,
    ChartMeasure.replyMinutes =>
      replies.isEmpty
          ? null
          : (([...replies]..sort())[replies.length ~/ 2]).toDouble(),
    ChartMeasure.started => started.toDouble(),
    ChartMeasure.laughs => laughs.toDouble(),
    ChartMeasure.emoji => emoji.toDouble(),
    ChartMeasure.questions => questions.toDouble(),
    ChartMeasure.contains => contains.toDouble(),
  };
}
