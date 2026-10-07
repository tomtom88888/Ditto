import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:replylikeme/models/chat_turn.dart';
import 'package:replylikeme/models/exchange.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/services/memory_exchange_store.dart';
import 'package:replylikeme/services/openai_exception.dart';
import 'package:replylikeme/services/openai_service.dart';
import 'package:replylikeme/services/style_memory_service.dart';
import 'package:replylikeme/services/vector_math.dart';
import 'package:replylikeme/services/whatsapp_parser.dart';

/// The in-memory store, counting writes so tests can check nothing was saved.
typedef FakeStore = MemoryExchangeStore;

ChatTurn turn(String sender, String text) =>
    ChatTurn(sender: sender, text: text, messageCount: 1);

Exchange exchange(String theirText, String myReply, {String them = 'Sam'}) =>
    Exchange(context: [turn(them, theirText)], reply: turn('Robin', myReply));

ChatMemory samChat({
  int id = 1,
  String them = 'Sam',
  String model = 'text-embedding-3-small',
  int dimensions = 2,
  bool enabled = true,
}) => ChatMemory(
  id: id,
  myName: 'Robin',
  theirName: them,
  embeddingModel: model,
  dimensions: dimensions,
  builtAt: DateTime(2026, 9, 1),
  enabled: enabled,
);

void main() {
  /// Returns a deterministic vector per input so retrieval is checkable.
  OpenAiService embedderThat(
    List<double> Function(String input) vectorFor, {
    void Function(int batchSize)? onBatch,
  }) => OpenAiService(
    apiKey: 'sk-test-0123456789abcdefghij',
    maxRetries: 0,
    client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final inputs = (body['input']! as List).cast<String>();
      onBatch?.call(inputs.length);
      return http.Response(
        jsonEncode({
          'data': [
            for (var i = 0; i < inputs.length; i++)
              {'index': i, 'embedding': vectorFor(inputs[i])},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  group('build', () {
    test('embeds every exchange and stores unit vectors', () async {
      final store = FakeStore();
      final service = StyleMemoryService(
        openai: embedderThat((input) => [input.length.toDouble(), 1]),
        store: store,
      );

      final chat = await service.build(
        exchanges: [exchange('pub?', 'go on then'), exchange('when', 'half 8')],
        myName: 'Robin',
        theirName: 'Sam',
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
      );

      expect(store.rows, hasLength(2));
      expect(chat.exchangeCount, 2);
      expect(chat.dimensions, 2);
      expect(chat.myName, 'Robin');
      expect(chat.theirName, 'Sam');
      expect(chat.enabled, isTrue);
      for (final row in store.rows) {
        expect(VectorMath.dot(row.vector, row.vector), closeTo(1.0, 1e-6));
      }
      expect(store.rows.first.replyText, 'go on then');
      expect(store.rows.first.contextText, 'Sam: pub?');
    });

    test('batches large imports and reports progress', () async {
      final store = FakeStore();
      final batchSizes = <int>[];
      final service = StyleMemoryService(
        openai: embedderThat((input) => [1, 0], onBatch: batchSizes.add),
        store: store,
      );

      final progress = <StyleMemoryProgress>[];
      await service.build(
        exchanges: [for (var i = 0; i < 200; i++) exchange('q$i', 'a$i')],
        myName: 'Robin',
        theirName: 'Sam',
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
        onProgress: progress.add,
      );

      // 48 exchanges a request, each sending its context and its moment.
      expect(batchSizes, [96, 96, 96, 96, 16]);
      expect(store.rows, hasLength(200));
      expect(progress.first.embedded, 0);
      expect(progress.map((p) => p.embedded), contains(48));
      expect(store.rows.every((r) => r.focus != null), isTrue);
      expect(progress.last.embedded, 200);
      expect(progress.last.fraction, 1.0);
    });

    test('explains an export with none of my replies in it', () async {
      final store = FakeStore();
      final service = StyleMemoryService(
        openai: embedderThat((input) => [1, 0]),
        store: store,
      );
      await expectLater(
        service.build(
          exchanges: const [],
          myName: 'Robin',
          theirName: 'Sam',
          embeddingModel: 'text-embedding-3-small',
          dimensions: 2,
        ),
        throwsA(
          isA<OpenAiException>().having(
            (e) => e.message,
            'message',
            contains('right name for yourself'),
          ),
        ),
      );
      expect(store.saveCalls, 0);
    });

    test('cancelling leaves the existing memory untouched', () async {
      final store = FakeStore(
        chats: [samChat()],
        rows: [
          StoredExchange(
            id: 1,
            chatId: 1,
            context: [turn('Sam', 'old')],
            contextText: 'Sam: old',
            replyText: 'old reply',
            vector: VectorMath.normalise([1, 0]),
          ),
        ],
      );
      var batches = 0;
      final service = StyleMemoryService(
        openai: embedderThat((input) => [1, 0], onBatch: (_) => batches++),
        store: store,
      );

      await expectLater(
        service.build(
          exchanges: [for (var i = 0; i < 200; i++) exchange('q$i', 'a$i')],
          myName: 'Robin',
          theirName: 'Sam',
          embeddingModel: 'text-embedding-3-small',
          dimensions: 2,
          isCancelled: () => batches >= 1,
        ),
        throwsA(isA<StyleMemoryCancelled>()),
      );
      expect(store.saveCalls, 0);
      expect(store.rows.single.replyText, 'old reply');
    });
  });

  group('retrieve', () {
    test('returns the closest stored exchanges, best first', () async {
      final store = FakeStore();
      // Embed on the first word, so "pub" queries match the "pub" exchange.
      List<double> vectorFor(String input) =>
          input.contains('pub') ? [1, 0] : [0, 1];

      final service = StyleMemoryService(
        openai: embedderThat(vectorFor),
        store: store,
      );
      await service.build(
        exchanges: [
          exchange('pub tonight?', 'go on then'),
          exchange('cinema?', 'nah'),
        ],
        myName: 'Robin',
        theirName: 'Sam',
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
      );

      final hits = (await service.retrieve(
        context: [turn('Sam', 'pub later')],
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
        limit: 2,
      )).examples;

      expect(hits.single.exchange.replyText, 'go on then');
      expect(hits.single.similarity, closeTo(1.0, 1e-6));
      // "cinema?" has nothing in common with "pub later", so it is left out
      // rather than used to make up the number.
    });

    test('searches with the last turns only, leaning to one chat', () async {
      final store = FakeStore();
      final embedded = <String>[];
      final service = StyleMemoryService(
        openai: embedderThat((input) {
          embedded.add(input);
          return input.contains('pub') ? [1, 0] : [0, 1];
        }),
        store: store,
      );
      for (final them in ['Sam', 'Alex']) {
        await service.build(
          exchanges: [exchange('pub tonight?', 'go on then, $them')],
          myName: 'Robin',
          theirName: them,
          embeddingModel: 'text-embedding-3-small',
          dimensions: 2,
        );
      }
      final alex = (await store.chats()).firstWhere(
        (c) => c.theirName == 'Alex',
      );
      embedded.clear();

      final hits = (await service.retrieve(
        context: [
          turn('Sam', 'cinema first?'),
          turn('Robin', 'maybe'),
          turn('Sam', 'pub later'),
        ],
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
        limit: 1,
        queryTurns: 1,
        preferChatId: alex.id,
      )).examples;

      expect(embedded.single, 'Sam: pub later');
      expect(hits.single.exchange.replyText, 'go on then, Alex');
    });

    test('returns nothing, without calling out, on an empty memory', () async {
      var calls = 0;
      final service = StyleMemoryService(
        openai: embedderThat((input) {
          calls++;
          return [1, 0];
        }),
        store: FakeStore(),
      );
      final hits = await service.retrieve(
        context: [turn('Sam', 'anything')],
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
        limit: 8,
      );
      expect(hits.examples, isEmpty);
      expect(calls, 0);
    });
  });

  group('incremental import', () {
    test('re-importing only embeds exchanges not already stored', () async {
      final store = FakeStore();
      final embedded = <String>[];
      final service = StyleMemoryService(
        openai: embedderThat((input) {
          embedded.add(input);
          return [1, 0];
        }),
        store: store,
      );
      Future<ChatMemory> import(List<Exchange> exchanges) => service.build(
        exchanges: exchanges,
        myName: 'Robin',
        theirName: 'Sam',
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
      );

      final first = await import([
        exchange('pub?', 'yes'),
        exchange('when', '8'),
      ]);
      embedded.clear();
      final second = await import([
        exchange('pub?', 'yes'),
        exchange('when', '8'),
        exchange('where', 'the usual'),
      ]);

      expect(embedded, ['Sam: where', 'Sam: where\nMe: the usual']);
      expect(second.id, first.id, reason: 'same chat, not a new one');
      expect(second.exchangeCount, 3);
      expect(await store.chats(), hasLength(1));
    });

    test('the plan counts what is new and prices only that', () async {
      final store = FakeStore();
      final service = StyleMemoryService(
        openai: embedderThat((input) => [1, 0]),
        store: store,
      );
      await service.build(
        exchanges: [exchange('pub?', 'yes')],
        myName: 'Robin',
        theirName: 'Sam',
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
      );
      final plan = await service.plan(
        exchanges: [
          exchange('pub?', 'yes'),
          exchange('new one', 'ok'),
          exchange('new one', 'ok'),
        ],
        myName: 'Robin',
        theirName: 'Sam',
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
      );
      expect(plan.isNewChat, isFalse);
      expect(plan.alreadyKnown, 1);
      expect(plan.toEmbed, hasLength(1), reason: 'duplicates collapse');
      expect(plan.estimate.exchangeCount, 1);
    });

    test(
      'a different embedding model rebuilds the chat from scratch',
      () async {
        final store = FakeStore();
        final service = StyleMemoryService(
          openai: embedderThat((input) => [1, 0, 0]),
          store: store,
        );
        store.rows.add(
          StoredExchange(
            id: 1,
            chatId: (await store.saveChat(samChat(dimensions: 2))).id,
            context: [turn('Sam', 'pub?')],
            contextText: 'Sam: pub?',
            replyText: 'yes',
            vector: VectorMath.normalise([1, 0]),
            hash: StoredExchange.contentHash('Sam: pub?', 'yes'),
          ),
        );

        final plan = await service.plan(
          exchanges: [exchange('pub?', 'yes')],
          myName: 'Robin',
          theirName: 'Sam',
          embeddingModel: 'text-embedding-3-small',
          dimensions: 3,
        );
        expect(plan.replacesExisting, isTrue);
        expect(plan.toEmbed, hasLength(1));

        final chat = await service.build(
          exchanges: [exchange('pub?', 'yes')],
          myName: 'Robin',
          theirName: 'Sam',
          embeddingModel: 'text-embedding-3-small',
          dimensions: 3,
        );
        expect(chat.dimensions, 3);
        expect(store.rows.single.vector, hasLength(3));
      },
    );

    test('another person starts a separate chat', () async {
      final store = FakeStore();
      final service = StyleMemoryService(
        openai: embedderThat((input) => [1, 0]),
        store: store,
      );
      for (final them in ['Sam', 'Mum']) {
        await service.build(
          exchanges: [exchange('hi', 'hey', them: them)],
          myName: 'Robin',
          theirName: them,
          embeddingModel: 'text-embedding-3-small',
          dimensions: 2,
        );
      }
      final chats = await store.chats();
      expect(chats.map((c) => c.theirName), ['Sam', 'Mum']);
      expect(chats.every((c) => c.exchangeCount == 1), isTrue);
    });
  });

  group('retrieving across chats', () {
    Future<(StyleMemoryService, FakeStore)> twoChats() async {
      final store = FakeStore();
      final service = StyleMemoryService(
        openai: embedderThat((input) => [1, 0]),
        store: store,
      );
      await service.build(
        exchanges: [exchange('hi', 'hey babe', them: 'Alex')],
        myName: 'Robin',
        theirName: 'Alex',
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
      );
      await service.build(
        exchanges: [exchange('hi', 'Good morning.', them: 'Boss')],
        myName: 'Robin',
        theirName: 'Boss',
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
      );
      return (service, store);
    }

    test('every chat is searched when none are named', () async {
      final (service, _) = await twoChats();
      final hits = await service.retrieve(
        context: [turn('Alex', 'hi')],
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
        limit: 8,
      );
      expect(hits.examples, hasLength(2));
    });

    test('named chat ids limit the search', () async {
      final (service, store) = await twoChats();
      final boss = (await store.chats()).last;
      final hits = await service.retrieve(
        context: [turn('Boss', 'hi')],
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
        limit: 8,
        chatIds: {boss.id},
      );
      expect(hits.examples.single.exchange.replyText, 'Good morning.');
    });

    test('a chat built with another model is skipped and reported', () async {
      final store = FakeStore(chats: [samChat(dimensions: 3)]);
      store.rows.add(
        StoredExchange(
          id: 1,
          chatId: 1,
          context: [turn('Sam', 'hi')],
          contextText: 'Sam: hi',
          replyText: 'yo',
          vector: VectorMath.normalise([1, 0, 0]),
        ),
      );
      var calls = 0;
      final service = StyleMemoryService(
        openai: embedderThat((input) {
          calls++;
          return [1, 0];
        }),
        store: store,
      );
      final hits = await service.retrieve(
        context: [turn('Sam', 'hi')],
        embeddingModel: 'text-embedding-3-small',
        dimensions: 2,
        limit: 8,
      );
      expect(hits.examples, isEmpty);
      expect(hits.skipped.single.theirName, 'Sam');
      expect(calls, 0, reason: 'nothing searchable, so nothing embedded');
    });
  });

  group('saveReply', () {
    test('stores a starred suggestion as a saved exchange, once', () async {
      final store = FakeStore(chats: [samChat()]);
      var calls = 0;
      final service = StyleMemoryService(
        openai: embedderThat((input) {
          calls++;
          return [0, 1];
        }),
        store: store,
      );
      final chat = (await store.chats()).single;
      final conversation = [
        for (var i = 0; i < 12; i++) turn(i.isEven ? 'Sam' : 'Robin', 'm$i'),
      ];

      final saved = await service.saveReply(
        chat: chat,
        conversation: conversation,
        reply: 'see you there',
        contextTurns: 4,
      );
      await service.saveReply(
        chat: saved,
        conversation: conversation,
        reply: 'see you there',
        contextTurns: 4,
      );

      // One save embeds the context and the moment; the second is ignored.
      expect(calls, 2, reason: 'the same save twice is ignored');
      final row = store.rows.single;
      expect(row.source, ExchangeSource.saved);
      expect(row.context, hasLength(4));
      expect(row.replyText, 'see you there');
      expect(saved.savedCount, 1);
    });
  });

  group('voiceSample', () {
    StoredExchange reply(int chatId, String text, int day) => StoredExchange(
      id: -1,
      chatId: chatId,
      context: const [],
      contextText: '',
      replyText: text,
      vector: VectorMath.normalise([1, 0]),
      timestamp: DateTime(2026, 1, day),
    );

    test('recent first, no repeats, mostly from the chat replied in', () async {
      final store = FakeStore(
        chats: [
          samChat(),
          samChat(id: 2, them: 'Mum'),
        ],
        rows: [
          reply(1, 'old sam', 1),
          reply(1, 'omw', 5),
          reply(1, 'OMW', 6),
          reply(1, 'x' * 200, 7),
          reply(1, 'newest sam', 9),
          reply(2, 'love you x', 8),
          reply(2, 'ok mum', 2),
        ],
      );
      final service = StyleMemoryService(
        openai: embedderThat((input) => [1, 0]),
        store: store,
      );
      final sample = await service.voiceSample(
        chatIds: {1, 2},
        preferChatId: 1,
        count: 3,
      );
      // Two from Sam's chat (newest first, "omw" once, the 200-character
      // reply skipped), one from the other ticked chat.
      expect(sample, ['newest sam', 'OMW', 'love you x']);
    });

    test('nothing ticked, nothing sampled', () async {
      final service = StyleMemoryService(
        openai: embedderThat((input) => [1, 0]),
        store: FakeStore(),
      );
      expect(await service.voiceSample(chatIds: {}), isEmpty);
    });
  });

  group('estimate', () {
    test('scales with the amount of text to embed', () async {
      final service = StyleMemoryService(
        openai: embedderThat((input) => [1, 0]),
        store: FakeStore(),
      );
      final small = service.estimate([exchange('hi', 'yo')]);
      final large = service.estimate([
        for (var i = 0; i < 100; i++)
          exchange('a much longer question $i', 'a$i'),
      ]);
      expect(small.exchangeCount, 1);
      expect(large.exchangeCount, 100);
      expect(large.estimatedTokens, greaterThan(small.estimatedTokens));
      expect(large.estimatedUsd, greaterThan(0));
    });
  });

  group('exchangesFrom', () {
    test('reads a real export end to end', () async {
      final chat = WhatsAppParser.parse(
        File('test/fixtures/android_export.txt').readAsStringSync(),
      );
      final service = StyleMemoryService(
        openai: embedderThat((input) => [1, 0]),
        store: FakeStore(),
      );
      final exchanges = service.exchangesFrom(
        chat,
        myName: 'Robin',
        contextTurns: 10,
      );
      expect(exchanges, hasLength(4));
      expect(exchanges.every((e) => e.reply.sender == 'Robin'), isTrue);
    });
  });
}
