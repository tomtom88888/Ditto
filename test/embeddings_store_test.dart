import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:replylikeme/models/chat_app.dart';
import 'package:replylikeme/models/chat_stats.dart';
import 'package:replylikeme/models/chat_turn.dart';
import 'package:replylikeme/models/reply_suggestion.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/models/suggestion_feedback.dart';
import 'package:replylikeme/services/embeddings_store.dart';
import 'package:replylikeme/services/vector_math.dart';
import 'package:replylikeme/services/whatsapp_parser.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

StoredExchange row(
  String their,
  String reply, {
  List<double> v = const [1, 0],
}) => StoredExchange(
  id: -1,
  context: [ChatTurn(sender: 'Sam', text: their, messageCount: 1)],
  contextText: 'Sam: $their',
  replyText: reply,
  vector: VectorMath.normalise(v),
  hash: StoredExchange.contentHash('Sam: $their', reply),
  timestamp: DateTime(2026, 3, 1),
);

ChatMemory chat(String them, {int dims = 2}) => ChatMemory(
  myName: 'Robin',
  theirName: them,
  embeddingModel: 'text-embedding-3-small',
  dimensions: dims,
  builtAt: DateTime(2026, 9, 1),
);

void main() {
  sqfliteFfiInit();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('replylikeme_store');
    await databaseFactoryFfi.setDatabasesPath(dir.path);
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  SqfliteExchangeStore open() =>
      SqfliteExchangeStore(factory: databaseFactoryFfi);

  group('chats', () {
    test('are created, added to, and counted', () async {
      final store = open();
      final sam = await store.saveChat(
        chat('Sam'),
        added: [row('pub?', 'go on'), row('when', '8')],
      );
      expect(sam.id, greaterThan(0));
      expect(sam.exchangeCount, 2);
      expect(sam.enabled, isTrue);

      final again = await store.saveChat(sam, added: [row('where', 'usual')]);
      expect(again.id, sam.id);
      expect(again.exchangeCount, 3);
      expect(
        await store.hashesFor(sam.id),
        contains(StoredExchange.contentHash('Sam: where', 'usual')),
      );
      await store.close();
    });

    test('replacing drops the old exchanges in the same step', () async {
      final store = open();
      final sam = await store.saveChat(chat('Sam'), added: [row('a', 'b')]);
      final rebuilt = await store.saveChat(
        sam.copyWith(dimensions: 3),
        added: [
          row('c', 'd', v: [1, 0, 0]),
        ],
        replaceExisting: true,
      );
      expect(rebuilt.exchangeCount, 1);
      expect(rebuilt.dimensions, 3);
      expect((await store.all()).single.replyText, 'd');
      await store.close();
    });

    test('only the asked-for chats are read, and toggling persists', () async {
      final store = open();
      final sam = await store.saveChat(chat('Sam'), added: [row('a', 'sam')]);
      final mum = await store.saveChat(chat('Mum'), added: [row('b', 'mum')]);

      expect((await store.all(chatIds: {mum.id})).single.replyText, 'mum');
      expect(await store.count(chatIds: {sam.id}), 1);
      expect(await store.count(chatIds: {}), 0);
      expect(await store.count(), 2);

      await store.setChatEnabled(sam.id, enabled: false);
      await store.close();

      final reopened = open();
      final chats = await reopened.chats();
      expect(chats.map((c) => (c.theirName, c.enabled)), [
        ('Sam', false),
        ('Mum', true),
      ]);
      await reopened.close();
    });

    test('saved replies are counted separately', () async {
      final store = open();
      final saved = StoredExchange(
        id: -1,
        context: const [],
        contextText: 'Sam: x',
        replyText: 'y',
        vector: VectorMath.normalise([0, 1]),
        hash: 'h',
        source: ExchangeSource.saved,
      );
      final sam = await store.saveChat(
        chat('Sam'),
        added: [row('a', 'b'), saved],
      );
      expect(sam.savedCount, 1);
      final all = await store.all();
      expect(all.last.source, ExchangeSource.saved);
      await store.close();
    });

    test('deleting one chat leaves the others', () async {
      final store = open();
      final sam = await store.saveChat(chat('Sam'), added: [row('a', 'b')]);
      await store.saveChat(chat('Mum'), added: [row('c', 'd')]);
      await store.deleteChat(sam.id);
      expect((await store.chats()).single.theirName, 'Mum');
      expect((await store.all()).single.replyText, 'd');
      await store.close();
    });
  });

  test('feedback round-trips', () async {
    final store = open();
    await store.recordFeedback(
      SuggestionFeedback(
        at: DateTime(2026, 9, 24, 10),
        chatId: 3,
        shownKinds: const [SuggestionKind.reply, SuggestionKind.newTopic],
        pickedIndex: 1,
        pickedText: 'anyway, weekend?',
        refinements: const ['shorter'],
        saved: true,
        hadNote: true,
      ),
    );
    await store.recordFeedback(
      SuggestionFeedback(
        at: DateTime(2026, 9, 24, 11),
        shownKinds: const [SuggestionKind.reply],
      ),
    );
    final back = await store.feedback();
    expect(back, hasLength(2));
    expect(back.first.picked, isFalse, reason: 'newest first');
    final picked = back.last;
    expect(picked.chatId, 3);
    expect(picked.pickedKind, SuggestionKind.newTopic);
    expect(picked.refinements, ['shorter']);
    expect(picked.saved, isTrue);
    expect(picked.hadNote, isTrue);
    await store.close();
  });

  test('deleting everything empties every table and the file', () async {
    final store = open();
    await store.saveChat(chat('Sam'), added: [row('a', 'b')]);
    await store.recordFeedback(
      SuggestionFeedback(at: DateTime(2026), shownKinds: const []),
    );
    await store.deleteEverything();
    expect(File(p.join(dir.path, store.databaseName)).existsSync(), isFalse);
    expect(await store.chats(), isEmpty);
    expect(await store.feedback(), isEmpty);
    await store.close();
  });

  test("a chat's numbers are stored with it", () async {
    final stats = ChatStats.from(
      WhatsAppParser.parse(
        '02/03/2026, 09:00 - Sam: pub?\n02/03/2026, 09:04 - Robin: yes',
      ),
      myName: 'Robin',
    );
    final store = open();
    await store.saveChat(chat('Sam').copyWith(stats: stats));
    await store.close();
    final reopened = open();
    final back = (await reopened.chats()).single.stats;
    expect(back.totalMessages, 2);
    expect(back.me.medianReplySeconds, 240);
    await reopened.close();
  });

  test('a group chat stays one after reopening', () async {
    final store = open();
    await store.saveChat(chat('Friday crew').copyWith(isGroup: true));
    await store.saveChat(chat('Sam'));
    await store.close();
    final reopened = open();
    final chats = await reopened.chats();
    expect(chats.map((c) => (c.theirName, c.isGroup)), [
      ('Friday crew', true),
      ('Sam', false),
    ]);
    await reopened.close();
  });

  test('a v2 memory gains the numbers column and keeps its chats', () async {
    final path = p.join(dir.path, 'replylikeme_style_memory.db');
    final v2 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, v) => SqfliteExchangeStore.createSchema(db, version: 2),
      ),
    );
    await v2.insert('chats', {
      'my_name': 'Robin',
      'their_name': 'Sam',
      'embedding_model': 'text-embedding-3-small',
      'dimensions': 2,
      'built_at': DateTime(2026, 9, 1).millisecondsSinceEpoch,
    });
    await v2.close();

    final store = open();
    final chats = await store.chats();
    expect(chats.single.theirName, 'Sam');
    expect(chats.single.stats.isEmpty, isTrue);
    expect(chats.single.isGroup, isFalse, reason: 'every older chat is 1:1');
    expect(chats.single.app, ChatApp.whatsapp, reason: 'and from WhatsApp');
    await store.close();
  });

  test(
    'an Instagram chat from before v5 is recognised by its timestamps',
    () async {
      final path = p.join(dir.path, 'replylikeme_style_memory.db');
      final v4 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, v) =>
              SqfliteExchangeStore.createSchema(db, version: 4),
        ),
      );
      Future<int> addChat(String them) => v4.insert('chats', {
        'my_name': 'Robin',
        'their_name': them,
        'embedding_model': 'text-embedding-3-small',
        'dimensions': 2,
        'built_at': 0,
      });
      Future<void> addRow(int chatId, int ts) => v4.insert('exchanges', {
        'chat_id': chatId,
        'hash': '$chatId-$ts',
        'context_json': '[]',
        'context_text': '',
        'reply': 'x',
        'ts': ts,
        'vector': Uint8List(8),
      });
      final wa = await addChat('Sam');
      final ig = await addChat('Maya');
      await addRow(wa, 1700000040000);
      await addRow(ig, 1700000040123);
      await v4.close();

      final store = open();
      final chats = {for (final c in await store.chats()) c.theirName: c.app};
      expect(chats, {'Sam': ChatApp.whatsapp, 'Maya': ChatApp.instagram});
      await store.close();
    },
  );

  StoredExchange dated(String reply, DateTime at) => StoredExchange(
    id: -1,
    context: const [ChatTurn(sender: 'Sam', text: 'x', messageCount: 1)],
    contextText: 'Sam: x',
    replyText: reply,
    vector: VectorMath.normalise([1, 0]),
    hash: StoredExchange.contentHash('Sam: x', reply),
    timestamp: at,
  );

  test(
    'a chat cut down to some dates only uses those, and keeps the rest',
    () async {
      final store = open();
      final sam = await store.saveChat(
        chat('Sam'),
        added: [
          dated('jan', DateTime(2026, 1, 10, 20)),
          dated('feb', DateTime(2026, 2, 10, 20)),
          dated('mar', DateTime(2026, 3, 31, 23, 59)),
          dated('apr', DateTime(2026, 4, 1, 9)),
        ],
      );
      expect(await store.dateSpan(sam.id), (
        DateTime(2026, 1, 10, 20),
        DateTime(2026, 4, 1, 9),
      ));

      await store.setChatDates(
        sam.id,
        from: DateTime(2026, 2, 1),
        until: DateTime(2026, 3, 31),
      );
      expect((await store.all()).map((e) => e.replyText), ['feb', 'mar']);
      final cut = (await store.chats()).single;
      expect(cut.isCut, isTrue);
      expect(cut.from, DateTime(2026, 2, 1));
      expect(cut.until, DateTime(2026, 3, 31));
      expect(cut.exchangeCount, 2);
      expect(cut.allCount, 4);
      await store.close();

      // Kept after reopening; and the whole chat comes back on asking.
      final reopened = open();
      expect((await reopened.all()).map((e) => e.replyText), ['feb', 'mar']);
      await reopened.setChatDates(sam.id);
      expect(await reopened.all(), hasLength(4));
      expect((await reopened.chats()).single.isCut, isFalse);
      await reopened.close();
    },
  );

  test('remembers which app a chat came from', () async {
    final store = open();
    await store.saveChat(
      chat('Maya').copyWith(app: ChatApp.instagram),
      added: [row('a', 'b')],
    );
    await store.close();
    final reopened = open();
    expect((await reopened.chats()).single.app, ChatApp.instagram);
    await reopened.close();
  });

  group('upgrading a single-chat memory', () {
    Future<void> makeV1(List<(String, String)> exchanges) async {
      final db = await databaseFactoryFfi.openDatabase(
        p.join(dir.path, 'replylikeme_style_memory.db'),
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, v) =>
              SqfliteExchangeStore.createSchema(db, version: 1),
        ),
      );
      for (final (their, reply) in exchanges) {
        await db.insert('exchanges', {
          'context_json': jsonEncode([
            {'sender': 'Sam', 'text': their, 'messageCount': 1},
          ]),
          'context_text': 'Sam: $their',
          'reply': reply,
          'ts': DateTime(2025, 1, 1).millisecondsSinceEpoch,
          'vector': VectorMath.encode(VectorMath.normalise([1, 0])),
        });
      }
      await db.insert('meta', {
        'key': 'stats',
        'value': jsonEncode({
          'exchangeCount': exchanges.length,
          'embeddingModel': 'text-embedding-3-small',
          'dimensions': 2,
          'myName': 'Robin',
          'theirName': 'Sam',
          'builtAt': '2026-09-19T14:30:00.000',
        }),
      });
      await db.close();
    }

    test(
      'keeps every exchange, under one chat named from the old stats',
      () async {
        await makeV1([('pub?', 'go on then'), ('when', 'haha\nhalf 8')]);

        final store = open();
        final chats = await store.chats();
        expect(chats, hasLength(1));
        final sam = chats.single;
        expect(sam.myName, 'Robin');
        expect(sam.theirName, 'Sam');
        expect(sam.embeddingModel, 'text-embedding-3-small');
        expect(sam.dimensions, 2);
        expect(sam.exchangeCount, 2);
        expect(sam.enabled, isTrue);
        expect(sam.builtAt, DateTime(2026, 9, 19, 14, 30));
        // The profile is measured from the stored replies, bubbles by line.
        expect(sam.profile.turns, 2);
        expect(sam.profile.multiBubbleTurns, 1);

        final rows = await store.all();
        expect(rows.map((r) => r.replyText), ['go on then', 'haha\nhalf 8']);
        expect(rows.every((r) => r.chatId == sam.id), isTrue);
        expect(rows.first.vector, hasLength(2));

        // Hashes are filled in, so re-importing the same export adds nothing.
        expect(await store.hashesFor(sam.id), {
          StoredExchange.contentHash('Sam: pub?', 'go on then'),
          StoredExchange.contentHash('Sam: when', 'haha\nhalf 8'),
        });
        await store.close();
      },
    );

    test('an empty old memory upgrades to no chats', () async {
      await makeV1(const []);
      final store = open();
      expect(await store.chats(), isEmpty);
      expect(await store.all(), isEmpty);
      await store.close();
    });
  });

  test('vectors survive storage exactly', () async {
    final store = open();
    final v = Float32List.fromList([0.6, 0.8]);
    await store.saveChat(
      chat('Sam'),
      added: [
        StoredExchange(
          id: -1,
          context: const [],
          contextText: 'c',
          replyText: 'r',
          vector: v,
          hash: 'h',
        ),
      ],
    );
    await store.close();
    final reopened = open();
    expect((await reopened.all()).single.vector, v);
    await reopened.close();
  });
}
