import 'package:flutter_test/flutter_test.dart';
import 'package:replylikeme/models/blind_test.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/services/blind_test.dart';
import 'package:replylikeme/services/vector_math.dart';

import 'explore_features_test.dart' show turn;

StoredExchange moment({
  required int id,
  String last = 'Maya',
  String reply = 'ok then',
  int chatId = 1,
  DateTime? at,
  ExchangeSource source = ExchangeSource.export,
  bool noContext = false,
}) => StoredExchange(
  id: id,
  chatId: chatId,
  context: noContext ? const [] : [turn('Robin', 'hey'), turn(last, 'hi $id')],
  contextText: '',
  replyText: reply,
  vector: VectorMath.normalise([1, 0]),
  timestamp: at,
  source: source,
);

BlindPair pair({
  bool realIsA = true,
  String? judge,
  String? user,
  String real = 'real one',
  String generated = 'fake one',
}) => BlindPair(
  context: [turn('Maya', 'pub?')],
  real: real,
  generated: generated,
  realIsA: realIsA,
  judgePick: judge,
  why: 'too keen',
  userPick: user,
);

void main() {
  group('pickMoments', () {
    final all = [for (var i = 1; i <= 40; i++) moment(id: i)];

    test('the same seed picks the same moments', () {
      final a = BlindTest.pickMoments(all, me: 'Robin', seed: 7);
      final b = BlindTest.pickMoments(
        all.reversed.toList(),
        me: 'Robin',
        seed: 7,
      );
      expect(a, hasLength(BlindTest.momentCount));
      expect(a.map((m) => m.id), b.map((m) => m.id));
      final c = BlindTest.pickMoments(all, me: 'Robin', seed: 8);
      expect(c.map((m) => m.id), isNot(a.map((m) => m.id)));
    });

    test('only moments that make a fair test', () {
      final picked = BlindTest.pickMoments(
        [
          moment(id: 1),
          moment(id: 2, source: ExchangeSource.saved),
          moment(id: 3, reply: 'k'),
          moment(id: 4, reply: 'x' * 161),
          moment(id: 5, last: 'Robin'),
          moment(id: 6, noContext: true),
          moment(id: 7, reply: 'x' * 160),
        ],
        me: 'Robin',
        seed: 1,
      );
      expect(picked.map((m) => m.id).toSet(), {1, 7});
    });
  });

  group('excluding', () {
    final noon = DateTime(2026, 5, 1, 12);

    test('the same chat within 12 hours, by time', () {
      final out = BlindTest.excluding(moment(id: 50, at: noon));
      expect(
        out(moment(id: 99, at: noon.add(const Duration(hours: 11)))),
        isTrue,
      );
      expect(
        out(moment(id: 51, at: noon.add(const Duration(hours: 13)))),
        isFalse,
      );
      expect(
        out(moment(id: 51, at: noon.subtract(const Duration(hours: 11)))),
        isTrue,
      );
      expect(out(moment(id: 50, chatId: 2, at: noon)), isFalse);
    });

    test('by row id when there are no times', () {
      final out = BlindTest.excluding(moment(id: 50));
      expect(out(moment(id: 50)), isTrue);
      expect(out(moment(id: 60)), isTrue);
      expect(out(moment(id: 39)), isFalse);
      expect(out(moment(id: 61)), isFalse);
    });
  });

  group('the judge', () {
    test('is shown the real replies, the moment and both messages', () {
      final system = BlindTest.judgeSystem(
        me: 'Robin',
        them: 'Maya',
        realReplies: const ['haha ok', 'omw\nnow'],
      );
      expect(system, contains('which one Robin really sent'));
      expect(system, contains('- haha ok'));
      expect(system, contains('- omw / now'));
      expect(system, contains('"pick"'));
      final user = BlindTest.judgeUser(
        context: [turn('Robin', 'hey'), turn('Maya', 'pub?')],
        a: 'go on',
        b: 'yes\nwhen',
      );
      expect(user, 'Robin: hey\nMaya: pub?\n\nA: go on\nB: yes / when');
    });

    test('answers are read leniently', () {
      expect(BlindTest.parseJudge('{"pick":"B","why":"too keen"}'), (
        'B',
        'too keen',
      ));
      expect(
        BlindTest.parseJudge('Sure!\n```json\n{"pick": "a", "why": "x"}\n```'),
        ('A', 'x'),
      );
      expect(BlindTest.parseJudge('B'), ('B', ''));
      expect(BlindTest.parseJudge('no idea'), (null, ''));
      expect(BlindTest.parseJudge('{"pick": "C"}'), (null, ''));
    });
  });

  group('scores', () {
    test('a fool is the generated one being picked', () {
      expect(pair(realIsA: true, judge: 'B').judgeFooled, isTrue);
      expect(pair(realIsA: true, judge: 'A').judgeFooled, isFalse);
      expect(pair(realIsA: false, judge: 'A').judgeFooled, isTrue);
      // An unreadable answer counts as spotted.
      expect(pair(judge: null).judgeFooled, isFalse);
    });

    test('rates per prompt; yours only once every pair is played', () {
      final result = BlindPromptResult(
        prompt: const BlindPrompt(label: 'Built-in', text: 'p'),
        pairs: [
          pair(judge: 'B', user: 'A'),
          pair(judge: 'A', user: 'A'),
          pair(judge: null, user: 'B'),
        ],
      );
      expect(result.judgeFoolRate, closeTo(1 / 3, 1e-9));
      expect(result.userFoolRate, closeTo(1 / 3, 1e-9));
      final half = BlindPromptResult(
        prompt: result.prompt,
        pairs: [
          pair(judge: 'B', user: 'A'),
          pair(judge: 'A'),
        ],
      );
      expect(half.userFoolRate, isNull);
    });

    test('two prompts are clearly different only with a real gap', () {
      expect(BlindTest.clearlyDifferent(20, 0.10, 0.45), isTrue);
      expect(BlindTest.clearlyDifferent(20, 0.30, 0.40), isFalse);
      expect(BlindTest.clearlyDifferent(20, 0, 0), isFalse);
      expect(BlindTest.clearlyDifferent(0, 0, 1), isFalse);
    });

    test(
      'calls: one fingerprint per moment, a reply and a judge per prompt',
      () {
        expect(BlindTest.calls(moments: 20, prompts: 3), 140);
      },
    );
  });

  group('the report', () {
    final run = BlindRun(
      at: DateTime(2026, 10, 12),
      replyModel: 'gpt-5.6-terra',
      promptVersion: 2,
      results: [
        BlindPromptResult(
          prompt: const BlindPrompt(label: 'Built-in', text: 'BUILT IN TEXT'),
          pairs: [
            pair(judge: 'A', real: 'my real reply', generated: 'a fake'),
            pair(judge: 'B'),
          ],
        ),
        BlindPromptResult(
          prompt: const BlindPrompt(label: 'Try this', text: 'TRY THIS TEXT'),
          pairs: [
            pair(judge: 'B'),
            pair(judge: 'B'),
          ],
        ),
      ],
    );

    test('in full: scores, prompts and the misses', () {
      final text = BlindTest.report(run, them: 'Maya');
      expect(text, contains('Built-in'));
      expect(text, contains('Try this'));
      expect(text, contains('1 of 2 (50%)'));
      expect(text, contains('2 of 2 (100%)'));
      expect(text, contains('TRY THIS TEXT'));
      expect(text, contains('You: my real reply'));
      expect(text, contains('Generated: a fake'));
      expect(text, contains('Judge: too keen'));
    });

    test('scores only leaves every chat line and prompt out', () {
      final text = BlindTest.report(run, them: 'Maya', scoresOnly: true);
      expect(text, contains('1 of 2 (50%)'));
      expect(text, isNot(contains('TRY THIS TEXT')));
      expect(text, isNot(contains('my real reply')));
      expect(text, isNot(contains('pub?')));
    });
  });

  test('state survives being stored', () {
    final state = BlindTestState(
      seed: 42,
      tryThis: 'be terse',
      runs: [
        BlindRun(
          at: DateTime(2026, 10, 12, 9),
          replyModel: 'm',
          promptVersion: 2,
          results: [
            BlindPromptResult(
              prompt: const BlindPrompt(label: 'Built-in', text: 'p'),
              pairs: [pair(judge: 'B', user: 'A')],
            ),
          ],
        ),
      ],
    );
    final back = BlindTestState.fromJson(state.toJson())!;
    expect(back.seed, 42);
    expect(back.tryThis, 'be terse');
    final p = back.runs.single.results.single.pairs.single;
    expect(p.context.single.text, 'pub?');
    expect(p.judgeFooled, isTrue);
    expect(p.userPick, 'A');
    expect(back.runs.single.at, DateTime(2026, 10, 12, 9));
    expect(BlindTestState.fromJson('nonsense'), isNull);
  });
}
