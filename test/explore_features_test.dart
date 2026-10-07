import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:replylikeme/models/ai_provider.dart';
import 'package:replylikeme/models/app_settings.dart';
import 'package:replylikeme/models/chat_turn.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/screens/facts_screen.dart';
import 'package:replylikeme/screens/search_screen.dart';
import 'package:replylikeme/services/chat_facts.dart';
import 'package:replylikeme/services/chat_groupings.dart';
import 'package:replylikeme/services/chat_search.dart';
import 'package:replylikeme/services/memory_exchange_store.dart';
import 'package:replylikeme/services/openai_service.dart';
import 'package:replylikeme/services/reply_generator.dart';
import 'package:replylikeme/services/topic_timeline.dart';
import 'package:replylikeme/services/vector_math.dart';
import 'package:replylikeme/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatTurn turn(String who, String text, [DateTime? at]) => ChatTurn(
  sender: who,
  text: text,
  messageCount: 1,
  firstTimestamp: at,
  lastTimestamp: at,
);

StoredExchange exchange({
  int id = -1,
  int chatId = 1,
  List<ChatTurn> context = const [],
  String reply = 'ok',
  List<double> vector = const [1, 0],
  DateTime? at,
}) => StoredExchange(
  id: id,
  chatId: chatId,
  context: context,
  contextText: context.map((t) => '${t.sender}: ${t.text}').join('\n'),
  replyText: reply,
  vector: VectorMath.normalise(vector),
  timestamp: at,
);

http.Response json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// A fake OpenAI: embeddings from [embed], chat answers from [answer].
OpenAiService fake({
  List<double> Function(String input)? embed,
  String Function(Map<String, Object?> body)? answer,
  List<Map<String, Object?>>? sent,
}) => OpenAiService(
  apiKey: 'sk-test-0123456789abcdefghij',
  maxRetries: 0,
  client: MockClient((request) async {
    final body = jsonDecode(request.body) as Map<String, Object?>;
    sent?.add(body);
    if (request.url.path.endsWith('/embeddings')) {
      final inputs = body['input']! as List;
      return json({
        'data': [
          for (var i = 0; i < inputs.length; i++)
            {'index': i, 'embedding': embed!(inputs[i] as String)},
        ],
      });
    }
    return json({
      'choices': [
        {
          'message': {'content': answer!(body)},
        },
      ],
    });
  }),
);

class _Key extends ApiKeysNotifier {
  @override
  Future<ApiKeys> build() async => const ApiKeys().withKey(
    AiProvider.openai,
    'sk-test-0123456789abcdefghij',
  );
}

ChatMemory chat({int id = 1, String them = 'Maya', bool group = false}) =>
    ChatMemory(
      id: id,
      myName: 'Robin',
      theirName: them,
      embeddingModel: AppSettings.defaultEmbeddingModel,
      dimensions: 2,
      builtAt: DateTime(2026, 9, 1),
      isGroup: group,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  // ------------------------------------------------------------------ facts
  group('ChatFacts', () {
    test('rebuilds their side from the lead-ups, once each, in order', () {
      final a = DateTime(2026, 3, 1, 9);
      final b = DateTime(2026, 3, 1, 10);
      final lines = ChatFacts.theirLines([
        exchange(context: [turn('Maya', 'my dog Biscuit\nis ill', a)]),
        exchange(
          context: [
            turn('Maya', 'my dog Biscuit\nis ill', a),
            turn('Robin', 'oh no', a),
            turn('Maya', 'vet at 5', b),
          ],
        ),
      ], myName: 'Robin');
      expect(lines, [
        '[2026-03-01] Maya: my dog Biscuit / is ill',
        '[2026-03-01] Maya: vet at 5',
      ]);
    });

    test('reads a long chat in parts spread over all of it', () {
      final lines = [
        for (var i = 0; i < 4000; i++) 'Maya: line $i ${'x' * 40}',
      ];
      final parts = ChatFacts.chunks(lines);
      expect(parts, hasLength(ChatFacts.maxChunks));
      // The very start and the very end are both read...
      expect(parts.first, contains('line 0 '));
      expect(parts.last, contains('line 3999'));
      // ...and so is the middle, not just the latest stretch.
      int firstLine(String part) =>
          int.parse(RegExp(r'line (\d+) ').firstMatch(part)!.group(1)!);
      expect(
        parts.map(firstLine).where((n) => n > 1300 && n < 2700),
        isNotEmpty,
      );
      // Spread out: no two parts are neighbours.
      final starts = parts.map(firstLine).toList();
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i] - starts[i - 1], greaterThan(300));
      }
      for (final p in parts) {
        expect(p.length, lessThanOrEqualTo(ChatFacts.chunkCharacters + 100));
      }
    });

    test('one part is one call; several are merged by one more', () async {
      final sent = <Map<String, Object?>>[];
      final finder = ChatFacts(
        openai: fake(
          sent: sent,
          answer: (body) {
            final system =
                ((body['messages']! as List).first as Map)['content'] as String;
            return system.contains('Merge them')
                ? '{"facts": [{"text": "Has a dog called Biscuit", '
                      '"category": "People & pets"}]}'
                : '{"facts": [{"text": "Has a dog called Biscuit", '
                      '"category": "People & pets"}, {"text": "Hates '
                      'coriander", "category": "Dislikes"}, {"text": ""}]}';
          },
        ),
      );
      final short = await finder.find(
        [
          exchange(context: [turn('Maya', 'my dog Biscuit is ill')]),
        ],
        myName: 'Robin',
        them: 'Maya',
        model: 'gpt-test',
      );
      expect(sent, hasLength(1));
      expect(short.map((f) => f.text), [
        'Has a dog called Biscuit',
        'Hates coriander',
      ]);
      expect(short.last.category, 'Dislikes');
      final system =
          ((sent.single['messages']! as List).first as Map)['content']
              as String;
      expect(system, contains('Maya, the other person in a private chat'));
      expect(sent.single['response_format'], {'type': 'json_object'});

      sent.clear();
      final progress = <(int, int)>[];
      final long = await finder.find(
        [
          for (var i = 0; i < 400; i++)
            exchange(context: [turn('Maya', 'message $i ${'y' * 60}')]),
        ],
        myName: 'Robin',
        them: 'Maya',
        model: 'gpt-test',
        onProgress: (done, of) => progress.add((done, of)),
      );
      expect(sent.length, greaterThan(2));
      expect(progress.last.$1, progress.last.$2);
      expect(long.single.text, 'Has a dog called Biscuit');
    });

    test('an unknown category becomes Other; junk is no facts', () {
      expect(
        ChatFacts.parse(
          '{"facts": [{"text": "Likes jazz", "category": "music"}]}',
        ).single.category,
        'Other',
      );
      expect(ChatFacts.parse('nope'), isEmpty);
    });

    test('the store keeps each chat, forgets one, and survives junk', () async {
      const store = FactsStore();
      final facts = SavedFacts(
        at: DateTime(2026, 9, 1),
        facts: const [ChatFact(text: 'Likes jazz', category: 'Likes')],
      );
      await store.save(1, facts);
      await store.save(2, facts);
      expect((await store.forChat(1))!.facts.single.text, 'Likes jazz');
      await store.remove(1);
      expect(await store.forChat(1), isNull);
      expect(await store.forChat(2), isNotNull);
      expect(FactsStore.decode('garbage'), isEmpty);
    });
  });

  test('the reply writer is told the facts, as callbacks only', () {
    final system = ReplyGenerator.buildSystemPrompt(
      const AppSettings(myName: 'Robin', theirName: 'Maya'),
      facts: const ['Has a dog called Biscuit'],
    );
    expect(system, contains('Things Robin knows about Maya'));
    expect(system, contains('- Has a dog called Biscuit'));
    expect(system, contains('never force one'));
    expect(
      ReplyGenerator.buildSystemPrompt(const AppSettings()),
      isNot(contains('Things')),
    );
  });

  // ----------------------------------------------------------------- search
  group('ChatSearch', () {
    test('ranks by meaning, lifts exact words, drops the unrelated', () {
      final query = VectorMath.normalise([1, 0.2]);
      final hits = ChatSearch.rank(query, 'ramen place', [
        exchange(id: 1, vector: [1, 0.25], reply: 'yes please'),
        exchange(
          id: 2,
          vector: [0.8, 0.6],
          context: [turn('Maya', 'that ramen place was unreal')],
        ),
        exchange(id: 3, vector: [-1, 0.1], reply: 'nope'),
        StoredExchange(
          id: 4,
          context: const [],
          contextText: '',
          replyText: '',
          vector: Float32List(3),
        ),
      ]);
      expect(hits.map((h) => h.exchange.id), [2, 1]);
      expect(hits.first.wordMatch, isTrue);
      expect(hits.last.wordMatch, isFalse);
    });

    // Twenty moments that all sit at much the same distance from the query,
    // the way chat text does, around one that is clearly closer.
    List<StoredExchange> crowd() => [
      for (var i = 0; i < 20; i++)
        exchange(id: 100 + i, vector: [0.3 + (i % 5) * 0.01, 1], reply: 'ok'),
    ];

    test('only moments that stand out from the rest are shown', () {
      final query = VectorMath.normalise([1, 0]);
      final hits = ChatSearch.rank(query, 'anything', [
        ...crowd(),
        exchange(id: 1, vector: [1, 0.15], reply: 'that one'),
      ]);
      expect(hits.map((h) => h.exchange.id), [1]);
      expect(hits.single.weak, isFalse);
    });

    test('when nothing stands out, the closest three come back as weak', () {
      final query = VectorMath.normalise([1, 0]);
      final hits = ChatSearch.rank(query, 'anything', crowd());
      expect(hits, hasLength(3));
      expect(hits.every((h) => h.weak), isTrue);
    });

    test('the tight moment fingerprint is matched before the wide one', () {
      final query = VectorMath.normalise([1, 0]);
      final hits = ChatSearch.rank(query, 'anything', [
        ...crowd(),
        // Its ten-turn fingerprint looks like the crowd; the moment itself
        // is what was asked for.
        exchange(
          id: 1,
          vector: [0.3, 1],
        ).copyWith(focus: VectorMath.normalise([1, 0.1])),
      ]);
      expect(hits.map((h) => h.exchange.id), [1]);
    });

    test('a rare word matches on its own; a common one does not', () {
      final query = VectorMath.normalise([0, 1]);
      final rows = [
        for (var i = 0; i < 20; i++)
          exchange(
            id: 100 + i,
            vector: [1, 0.3 + (i % 5) * 0.01],
            context: [turn('Maya', 'see you later then')],
          ),
        exchange(
          id: 1,
          vector: [1, 0.3],
          context: [turn('Maya', 'the ramen in Osaka, see you there')],
        ),
      ];
      expect(ChatSearch.rank(query, 'osaka', rows).map((h) => h.exchange.id), [
        1,
      ]);
      // "see" is everywhere: no moment stands out by it.
      expect(ChatSearch.rank(query, 'see', rows).first.weak, isTrue);
    });

    test('Bm25 weighs rare words more and matches word starts', () {
      final scores = Bm25([
        ['plans', 'for', 'friday'],
        ['friday', 'friday'],
        ['nothing'],
      ]).scores(['plan', 'friday']);
      expect(scores[0], greaterThan(scores[1]));
      expect(scores[2], 0);
    });

    test('one embedding call per search', () async {
      final sent = <Map<String, Object?>>[];
      final store = MemoryExchangeStore(
        chats: [chat()],
        rows: [
          exchange(vector: [1, 0]),
        ],
      );
      final search = ChatSearch(
        openai: fake(sent: sent, embed: (_) => [1, 0]),
        store: store,
      );
      final hits = await search.search(
        'anything',
        chatIds: {1},
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
      );
      expect(hits, hasLength(1));
      expect(sent, hasLength(1));
      expect(
        await search.search(
          '  ',
          chatIds: {1},
          embeddingModel: 'm',
          dimensions: 2,
        ),
        isEmpty,
      );
    });
  });

  // --------------------------------------------------------------- timeline
  group('TopicTimeline', () {
    ChatGroup g(List<DateTime?> dates) => ChatGroup(
      name: 'g',
      about: '',
      members: [for (final d in dates) exchange(at: d)],
    );

    test('months, with empty months kept as gaps', () {
      final t = TopicTimeline.of([
        g([DateTime(2026, 1, 5), DateTime(2026, 1, 20), DateTime(2026, 6, 1)]),
        g([DateTime(2026, 6, 2), null]),
      ]);
      expect(t.step, TimelineStep.month);
      expect(t.buckets.map((b) => b.start.month), [1, 2, 3, 4, 5, 6]);
      expect(t.buckets.first.counts, [2, 0]);
      expect(t.buckets.last.counts, [1, 1]);
      expect(t.buckets[2].total, 0);
      expect(t.undated, 1);
    });

    test('weeks for a short chat, quarters for a long one', () {
      final short = TopicTimeline.of([
        g([DateTime(2026, 3, 4), DateTime(2026, 3, 20)]),
      ]);
      expect(short.step, TimelineStep.week);
      expect(short.buckets.first.start, DateTime(2026, 3, 2), reason: 'Monday');
      expect(short.buckets, hasLength(3));

      final long = TopicTimeline.of([
        g([DateTime(2020, 2, 1), DateTime(2025, 11, 1)]),
      ]);
      expect(long.step, TimelineStep.quarter);
      expect(long.buckets.first.start, DateTime(2020, 1));
      expect(long.buckets.last.start, DateTime(2025, 10));
    });

    test('nothing dated is an empty timeline', () {
      expect(
        TopicTimeline.of([
          g([null]),
        ]).isEmpty,
        isTrue,
      );
    });
  });

  // ---------------------------------------------------------------- screens
  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    required MemoryExchangeStore store,
    required OpenAiService openai,
  }) async {
    tester.view.physicalSize = const Size(1200, 9000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiKeysProvider.overrideWith(_Key.new),
          exchangeStoreProvider.overrideWithValue(store),
          openAiServiceProvider.overrideWithValue(openai),
          settingsProvider.overrideWith(_Settings.new),
        ],
        child: MaterialApp(home: screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('search finds a moment and shows where it came from', (
    tester,
  ) async {
    final store = MemoryExchangeStore(
      chats: [
        chat(),
        chat(id: 2, them: 'Sam'),
      ],
      rows: [
        exchange(
          vector: [1, 0],
          context: [turn('Maya', 'that ramen place was unreal')],
          reply: 'we have to go back',
          at: DateTime(2026, 2, 14),
        ),
        exchange(chatId: 2, vector: [-1, 0], reply: 'football?'),
      ],
    );
    await pump(
      tester,
      const SearchScreen(),
      store: store,
      // The one-time search fingerprints are made on opening, from the text.
      openai: fake(
        embed: (input) => input.contains('football') ? [-1, 0] : [1, 0],
      ),
    );
    // The box grows with what is typed, a line at a time.
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('search-field')),
    );
    expect((field.minLines, field.maxLines), (1, 6));
    expect(find.text('Moments to show'), findsOneWidget);
    expect(find.text('25'), findsOneWidget, reason: 'the default');

    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'the ramen place',
    );
    await tester.tap(find.byKey(const ValueKey('search-go')));
    await tester.pumpAndSettle();

    expect(find.text('1 moment, best match first'), findsOneWidget);
    expect(find.text('that ramen place was unreal'), findsOneWidget);
    expect(find.text('we have to go back'), findsOneWidget);
    expect(find.textContaining('14 Feb 2026'), findsOneWidget);
    expect(find.text('football?'), findsNothing);
  });

  testWidgets('remember finds facts, keeps them, and forgets one', (
    tester,
  ) async {
    final store = MemoryExchangeStore(
      chats: [chat()],
      rows: [
        exchange(context: [turn('Maya', 'my dog Biscuit is ill')]),
      ],
    );
    final sent = <Map<String, Object?>>[];
    final openai = fake(
      sent: sent,
      answer: (_) =>
          '{"facts": [{"text": "Has a dog called Biscuit", "category": '
          '"People & pets"}, {"text": "Loves jazz", "category": "Likes"}]}',
    );
    await pump(tester, const FactsScreen(), store: store, openai: openai);
    await tester.tap(find.text('Find things to remember'));
    await tester.pumpAndSettle();

    expect(find.text('Has a dog called Biscuit'), findsOneWidget);
    expect(find.text('People & pets'), findsOneWidget);
    expect(find.text('Loves jazz'), findsOneWidget);
    expect(sent, hasLength(1));

    // Likes comes before People & pets, so the first × is jazz.
    await tester.tap(find.byTooltip('Forget this').first);
    await tester.pumpAndSettle();
    expect(find.text('Loves jazz'), findsNothing);

    final saved = await const FactsStore().forChat(1);
    expect(saved!.facts.map((f) => f.text), ['Has a dog called Biscuit']);

    // Coming back shows them without asking again.
    await pump(tester, const FactsScreen(), store: store, openai: openai);
    expect(find.text('Has a dog called Biscuit'), findsOneWidget);
    expect(find.text('Look through the chat again'), findsOneWidget);
    expect(sent, hasLength(1));
  });

  testWidgets('remember opens on the chat it last read, not the first', (
    tester,
  ) async {
    final store = MemoryExchangeStore(
      chats: [
        chat(),
        chat(id: 2, them: 'Noa'),
      ],
      rows: [
        exchange(context: [turn('Maya', 'hi')]),
        exchange(
          chatId: 2,
          context: [turn('Noa', 'I start at the bank monday')],
        ),
      ],
    );
    await const FactsStore().save(
      2,
      SavedFacts(
        at: DateTime(2026, 9, 20),
        facts: const [
          ChatFact(text: 'Starts a bank job', category: 'Work & study'),
        ],
      ),
    );
    final openai = fake(sent: [], answer: (_) => '{"facts": []}');
    await pump(tester, const FactsScreen(), store: store, openai: openai);
    expect(find.text('Starts a bank job'), findsOneWidget);
  });
}

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async =>
      const AppSettings(embeddingDimensions: 2);
}
