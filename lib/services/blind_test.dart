import 'dart:convert';
import 'dart:math' as math;

import '../models/blind_test.dart';
import '../models/chat_turn.dart';
import '../models/stored_exchange.dart';

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

  static String _flat(String text) => text.trim().replaceAll('\n', ' / ');

  /// The judge's instructions, with [realReplies] to know you by.
  static String judgeSystem({
    required String me,
    required String them,
    required List<String> realReplies,
  }) {
    final out = StringBuffer(
      'You are shown a moment from a chat between $me and $them, and two '
      'messages, A and B. One is what $me really sent next; the other was '
      'written by someone imitating $me. Decide which one $me really sent.',
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
  }) =>
      '${context.map((t) => '${t.sender}: ${_flat(t.text)}').join('\n')}'
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
  static int calls({required int moments, required int prompts}) =>
      moments * (1 + 2 * prompts);

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
      'Ditto blind test · $them · ${at.day} ${_months[at.month - 1]} '
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
          ..writeln('You: ${_flat(p.real)}')
          ..writeln('Generated: ${_flat(p.generated)}')
          ..writeln('Judge: ${p.why.isEmpty ? '(no reason)' : p.why}');
      }
    }
    return out.toString().trimRight();
  }
}
