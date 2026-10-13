import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replylikeme/models/app_settings.dart';
import 'package:replylikeme/models/blind_test.dart';
import 'package:replylikeme/models/chat_turn.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/services/blind_test.dart';
import 'package:replylikeme/services/blind_test_store.dart';
import 'package:replylikeme/services/memory_exchange_store.dart';
import 'package:replylikeme/services/openai_exception.dart';
import 'package:replylikeme/services/reply_generator.dart';
import 'package:replylikeme/services/style_memory_service.dart';
import 'package:replylikeme/services/vector_math.dart';
import 'package:replylikeme/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'explore_features_test.dart' show chat, fake, turn;

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

/// A moment where Robin writes [quiet] after Maya's last message, at
/// [at] plus [quiet].
StoredExchange opener({
  required int id,
  required DateTime at,
  required Duration quiet,
  String reply = 'opener',
  String lead = 'night',
}) => StoredExchange(
  id: id,
  chatId: 1,
  context: [
    ChatTurn(
      sender: 'Maya',
      text: lead,
      messageCount: 1,
      firstTimestamp: at,
      lastTimestamp: at,
    ),
  ],
  contextText: 'Maya: $lead',
  replyText: reply,
  vector: VectorMath.normalise([1, 0]),
  timestamp: at.add(quiet),
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
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('openers', () {
    final start = DateTime(2026, 1, 1, 9);

    test('only times you started the chat again after a long quiet', () {
      final all = [
        for (var i = 1; i <= 30; i++)
          opener(
            id: i,
            at: start.add(Duration(days: i)),
            quiet: Duration(hours: i.isEven ? 20 : 2),
          ),
      ];
      final picked = BlindTest.pickOpeners(all, seed: 5);
      expect(picked, hasLength(15));
      expect(picked.every((e) => e.id.isEven), isTrue);
      expect(
        BlindTest.pickOpeners(all, seed: 5).map((e) => e.id),
        picked.map((e) => e.id),
      );
    });

    test('a later moment quoting the opener is kept from the writer', () {
      final held = opener(id: 1, at: start, quiet: const Duration(days: 2));
      final later = opener(
        id: 40,
        at: start.add(const Duration(days: 9)),
        quiet: Duration.zero,
        lead: 'opener',
      );
      final other = opener(
        id: 41,
        at: start.add(const Duration(days: 9)),
        quiet: Duration.zero,
      );
      final exclude = BlindTest.excludingOpener(held);
      expect(exclude(later), isTrue);
      expect(exclude(other), isFalse);
    });

    test('the judge knows the writer was told what you brought up', () {
      final system = BlindTest.judgeSystem(
        me: 'Robin',
        them: 'Maya',
        realReplies: const [],
        kind: BlindKind.openers,
      );
      expect(system, contains('starting the chat up again'));
      expect(system, contains('told the same'));
      final user = BlindTest.judgeUser(
        context: [turn('Maya', 'night')],
        a: 'x',
        b: 'y',
        setup: BlindTest.openerSetup(
          quiet: const Duration(days: 3),
          topic: 'got a dog',
        ),
      );
      expect(
        user,
        'Maya: night\n(quiet for 3 days · brought up: got a dog)\n\nA: x\nB: y',
      );
      expect(
        BlindTest.calls(moments: 20, prompts: 1, kind: BlindKind.openers),
        80,
      );
    });

    test('a run writes openers without ever seeing the real ones', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final rows = [
        for (var i = 1; i <= 25; i++)
          opener(
            id: i,
            at: start.add(Duration(days: 2 * i)),
            quiet: const Duration(days: 1),
            reply: 'real opener $i',
          ),
      ];
      final sent = <Map<String, Object?>>[];
      final openai = fake(
        sent: sent,
        embed: (_) => [1, 0],
        answer: (body) {
          if (body.containsKey('response_format')) {
            return '{"pick": "B", "why": "too tidy"}';
          }
          final system =
              ((body['messages']! as List).first as Map)['content'] as String;
          return system.startsWith('You are given a message')
              ? 'he mentions a topic'
              : 'generated opener';
        },
      );
      final run =
          await BlindTester(
            memory: StyleMemoryService(
              openai: openai,
              store: MemoryExchangeStore(chats: [chat()], rows: rows),
            ),
            generator: ReplyGenerator(openai: openai),
            openai: openai,
          ).runOpeners(
            chat: chat(),
            settings: const AppSettings(
              myName: 'Robin',
              theirName: 'Maya',
              embeddingDimensions: 2,
            ),
            prompts: const [
              BlindPrompt(label: BlindPrompt.builtIn, text: 'PROMPT {me}'),
            ],
            seed: 2,
          );
      expect(run.kind, BlindKind.openers);
      final pairs = run.results.single.pairs;
      expect(pairs, hasLength(20));
      for (final p in pairs) {
        expect(p.generated, 'generated opener');
        expect(p.setup, '(quiet for 1 day · brought up: he mentions a topic)');
        expect(p.judgePick, 'B');
        expect(p.why, 'too tidy');
      }
      final writes = [
        for (final b in sent)
          if (b.containsKey('messages') &&
              !b.containsKey('response_format') &&
              (((b['messages']! as List).first as Map)['content'] as String)
                  .startsWith('PROMPT Robin'))
            b,
      ];
      expect(writes, hasLength(20));
      for (final (i, p) in pairs.indexed) {
        final held = RegExp('${RegExp.escape(p.real)}(?!\\d)');
        final mine = writes[i];
        expect(
          held.hasMatch(jsonEncode(mine['messages'])),
          isFalse,
          reason: 'opener $i',
        );
        expect(jsonEncode(mine['messages']), contains('he mentions a topic'));
      }
    });

    test('runs of each kind are kept apart', () {
      var state = const BlindTestState(seed: 1);
      for (var i = 0; i < 12; i++) {
        state = state.adding(
          BlindRun(
            at: DateTime(2026, 1, i + 1),
            replyModel: 'm',
            promptVersion: 2,
            results: const [],
            kind: i.isEven ? BlindKind.openers : BlindKind.replies,
          ),
        );
      }
      expect(state.runsOf(BlindKind.openers), hasLength(6));
      final back = BlindTestState.fromJson(state.toJson())!;
      expect(back.runsOf(BlindKind.replies), hasLength(6));
      expect(back.runs.first.kind, BlindKind.replies);
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

  group('a run', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    final start = DateTime(2026, 1, 1, 12);
    // 25 moments a day apart, each reply unique so a leak would show.
    final rows = [
      for (var i = 1; i <= 25; i++)
        StoredExchange(
          id: i,
          chatId: 1,
          context: [turn('Maya', 'question $i')],
          contextText: 'Maya: question $i',
          replyText: 'real answer $i',
          vector: VectorMath.normalise([1, 0]),
          timestamp: start.add(Duration(days: i)),
        ),
    ];
    const settings = AppSettings(
      myName: 'Robin',
      theirName: 'Maya',
      embeddingDimensions: 2,
    );

    BlindTester tester(List<Map<String, Object?>> sent, {int rowCount = 25}) {
      final openai = fake(
        sent: sent,
        embed: (_) => [1, 0],
        answer: (body) => body.containsKey('response_format')
            ? '{"pick": "A", "why": "too keen"}'
            : 'generated',
      );
      return BlindTester(
        memory: StyleMemoryService(
          openai: openai,
          store: MemoryExchangeStore(
            chats: [chat()],
            rows: rows.take(rowCount).toList(),
          ),
        ),
        generator: ReplyGenerator(openai: openai),
        openai: openai,
      );
    }

    test('writes and judges every moment for every prompt', () async {
      final sent = <Map<String, Object?>>[];
      final progress = <double>[];
      final run = await tester(sent).run(
        chat: chat(),
        settings: settings,
        prompts: const [
          BlindPrompt(label: BlindPrompt.builtIn, text: 'PROMPT ONE {me}'),
          BlindPrompt(label: BlindPrompt.tryThis, text: 'PROMPT TWO {me}'),
        ],
        seed: 3,
        onProgress: (done, of) => progress.add(done / of),
      );
      expect(run.results, hasLength(2));
      expect(run.promptVersion, ReplyGenerator.promptVersion);
      for (final r in run.results) {
        expect(r.pairs, hasLength(BlindTest.momentCount));
        for (final p in r.pairs) {
          expect(p.generated, 'generated');
          expect(p.real, startsWith('real answer'));
          expect(p.judgePick, 'A');
          expect(p.why, 'too keen');
        }
      }
      expect(progress.last, 1.0);

      final generations = [
        for (final b in sent)
          if (b.containsKey('messages') && !b.containsKey('response_format')) b,
      ];
      expect(generations, hasLength(40));
      String system(Map<String, Object?> b) =>
          ((b['messages']! as List).first as Map)['content'] as String;
      expect(
        generations.where((b) => system(b).startsWith('PROMPT ONE Robin')),
        hasLength(20),
      );
      expect(
        generations.where((b) => system(b).startsWith('PROMPT TWO Robin')),
        hasLength(20),
      );

      // The writer never sees the reply it is being tested on.
      for (final r in run.results) {
        for (final (i, p) in r.pairs.indexed) {
          final asked = generations.where(
            (b) =>
                ((b['messages']! as List).last as Map)['content'] ==
                p.context.last.text,
          );
          // "real answer 1" must not match "real answer 12".
          final held = RegExp(
            '${RegExp.escape(p.real)}'
            r'(?!\d)',
          );
          expect(asked, isNotEmpty);
          for (final b in asked) {
            expect(
              held.hasMatch(jsonEncode(b['messages'])),
              isFalse,
              reason: 'pair $i',
            );
          }
        }
      }
    });

    test('needs a few of your replies to be worth running', () async {
      expect(
        tester([], rowCount: 3).run(
          chat: chat(),
          settings: settings,
          prompts: const [BlindPrompt(label: BlindPrompt.builtIn, text: 'p')],
          seed: 1,
        ),
        throwsA(isA<OpenAiException>()),
      );
    });
  });

  group('the store', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('keeps each chat apart, and forgets on request', () async {
      const store = BlindTestStore();
      expect(await store.forChat(1), isNull);
      await store.save(1, const BlindTestState(seed: 1, tryThis: 'a'));
      await store.save(2, const BlindTestState(seed: 2));
      expect((await store.forChat(1))!.tryThis, 'a');
      expect((await store.forChat(2))!.seed, 2);
      await store.remove(1);
      expect(await store.forChat(1), isNull);
      expect(await store.forChat(2), isNotNull);
      await store.clear();
      expect(await store.forChat(2), isNull);
    });

    test('goes with its chat', () async {
      const store = BlindTestStore();
      await store.save(1, const BlindTestState(seed: 1));
      await store.save(2, const BlindTestState(seed: 2));
      final container = ProviderContainer(
        overrides: [
          exchangeStoreProvider.overrideWithValue(
            MemoryExchangeStore(chats: [chat(), chat(id: 2)]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(chatsProvider.future);
      await container.read(chatsProvider.notifier).delete(1);
      expect(await store.forChat(1), isNull);
      expect(await store.forChat(2), isNotNull);
    });
  });
}
