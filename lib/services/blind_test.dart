import 'dart:convert';
import 'dart:math' as math;

import '../models/app_settings.dart';
import '../models/blind_test.dart';
import '../models/chat_turn.dart';
import '../models/stored_exchange.dart';
import 'openai_exception.dart';
import 'openai_service.dart';
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
        final generated = replies.isEmpty ? '' : replies.first.text;
        final real = moment.replyText;
        final raw = await openai.chat(
          model: settings.generationModel,
          messages: [
            {
              'role': 'system',
              'content': BlindTest.judgeSystem(
                me: settings.myName,
                them: settings.theirName,
                realReplies: voice.take(BlindTest.judgeSampleCount).toList(),
              ),
            },
            {
              'role': 'user',
              'content': BlindTest.judgeUser(
                context: moment.context,
                a: realIsA ? real : generated,
                b: realIsA ? generated : real,
              ),
            },
          ],
          jsonMode: true,
          temperature: 0,
        );
        final (pick, why) = BlindTest.parseJudge(raw);
        pairs[j].add(
          BlindPair(
            context: moment.context,
            real: real,
            generated: generated,
            realIsA: realIsA,
            judgePick: pick,
            why: why,
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
}
