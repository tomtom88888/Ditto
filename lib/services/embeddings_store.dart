import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/chat_app.dart';
import '../models/chat_stats.dart';
import '../models/chat_turn.dart';
import '../models/stored_exchange.dart';
import '../models/style_profile.dart';
import '../models/suggestion_feedback.dart';
import 'exchange_store.dart';
import 'vector_math.dart';

/// The on-device style memory, backed by sqflite.
///
/// Vectors are stored as little-endian float32 blobs and kept unit-length, so
/// similarity search is a dot product. Each chat's rows are cached in memory
/// after the first read, and only the chats a query asks for are read at all:
/// switched-off chats cost nothing.
class SqfliteExchangeStore implements ExchangeStore {
  SqfliteExchangeStore({
    this.databaseName = 'replylikeme_style_memory.db',
    DatabaseFactory? factory,
    this.inMemory = false,
  }) : _factory = factory; // ignore: prefer_initializing_formals

  final String databaseName;

  /// Tests open the database in memory through sqflite_common_ffi.
  final bool inMemory;
  final DatabaseFactory? _factory;

  /// v1: one chat, described by a JSON row in `meta`.
  /// v2: a `chats` table, per-exchange chat ids and content hashes, and the
  ///     feedback log.
  /// v3: each chat's numbers for the chat data screen.
  /// v4: whether a chat is a group chat.
  static const int schemaVersion = 8;

  Database? _database;
  final Map<int, List<StoredExchange>> _cache = {};

  DatabaseFactory get _db => _factory ?? databaseFactory;

  Future<String> _path() async => inMemory
      ? inMemoryDatabasePath
      : p.join(await _db.getDatabasesPath(), databaseName);

  Future<Database> _open() async {
    final existing = _database;
    if (existing != null) return existing;
    final database = await _db.openDatabase(
      await _path(),
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (db, version) => createSchema(db, version: version),
        onUpgrade: (db, from, to) async {
          if (from < 2) await _upgradeToV2(db);
          if (from < 3) await _upgradeToV3(db);
          if (from < 4) await _upgradeToV4(db);
          if (from < 5) await _upgradeToV5(db);
          if (from < 6) await _upgradeToV6(db);
          if (from < 7) await _upgradeToV7(db);
          if (from < 8) await _upgradeToV8(db);
        },
      ),
    );
    _database = database;
    return database;
  }

  /// Creates the tables for [version]. Public so a test can build a v1
  /// database and check the upgrade.
  static Future<void> createSchema(Database db, {required int version}) async {
    await db.execute('''
      CREATE TABLE meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    if (version == 1) {
      await db.execute('''
        CREATE TABLE exchanges (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          context_json  TEXT    NOT NULL,
          context_text  TEXT    NOT NULL,
          reply         TEXT    NOT NULL,
          ts            INTEGER,
          vector        BLOB    NOT NULL
        )
      ''');
      return;
    }
    await db.execute('''
      CREATE TABLE exchanges (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id       INTEGER NOT NULL,
        hash          TEXT    NOT NULL,
        source        TEXT    NOT NULL DEFAULT 'export',
        context_json  TEXT    NOT NULL,
        context_text  TEXT    NOT NULL,
        reply         TEXT    NOT NULL,
        ts            INTEGER,
        vector        BLOB    NOT NULL
      )
    ''');
    await _createV2Tables(db);
    if (version >= 3) await _upgradeToV3(db);
    if (version >= 4) await _upgradeToV4(db);
    if (version >= 5) await _upgradeToV5(db);
    if (version >= 7) await _upgradeToV7(db);
    if (version >= 8) await _upgradeToV8(db);
  }

  /// Room for the dates each chat is cut down to.
  static Future<void> _upgradeToV8(DatabaseExecutor db) async {
    await db.execute('ALTER TABLE chats ADD COLUMN range_from INTEGER');
    await db.execute('ALTER TABLE chats ADD COLUMN range_until INTEGER');
  }

  /// Room for each exchange's search fingerprint, filled in by the next
  /// import or the first search.
  static Future<void> _upgradeToV7(DatabaseExecutor db) =>
      db.execute('ALTER TABLE exchanges ADD COLUMN focus BLOB');

  /// Finds the Instagram chats imported before the app was recorded.
  /// Instagram stamps messages to the millisecond; a WhatsApp export never
  /// has more than whole seconds.
  static Future<void> _upgradeToV6(DatabaseExecutor db) => db.execute(
    "UPDATE chats SET app = 'instagram' WHERE app = 'whatsapp' AND id IN "
    "(SELECT chat_id FROM exchanges WHERE source = 'export' AND ts IS NOT "
    'NULL AND ts % 1000 != 0)',
  );

  /// Records which app each chat came from. Every chat learned before this
  /// came from WhatsApp.
  static Future<void> _upgradeToV5(DatabaseExecutor db) => db.execute(
    "ALTER TABLE chats ADD COLUMN app TEXT NOT NULL DEFAULT 'whatsapp'",
  );

  /// Marks group chats. Every chat learned before this is one-to-one.
  static Future<void> _upgradeToV4(DatabaseExecutor db) => db.execute(
    'ALTER TABLE chats ADD COLUMN is_group INTEGER NOT NULL DEFAULT 0',
  );

  /// Adds the column for each chat's numbers. Chats imported before it read
  /// as having none until their export is imported again.
  static Future<void> _upgradeToV3(DatabaseExecutor db) => db.execute(
    "ALTER TABLE chats ADD COLUMN stats_json TEXT NOT NULL DEFAULT '{}'",
  );

  static Future<void> _createV2Tables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE chats (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        my_name          TEXT    NOT NULL,
        their_name       TEXT    NOT NULL,
        embedding_model  TEXT    NOT NULL,
        dimensions       INTEGER NOT NULL,
        built_at         INTEGER NOT NULL,
        enabled          INTEGER NOT NULL DEFAULT 1,
        profile_json     TEXT    NOT NULL DEFAULT '{}'
      )
    ''');
    await db.execute(
      'CREATE INDEX exchanges_by_chat ON exchanges (chat_id, hash)',
    );
    await db.execute('''
      CREATE TABLE feedback (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        at            INTEGER NOT NULL,
        chat_id       INTEGER,
        picked_index  INTEGER,
        picked_text   TEXT,
        saved         INTEGER NOT NULL DEFAULT 0,
        extra_json    TEXT    NOT NULL DEFAULT '{}'
      )
    ''');
  }

  /// Moves a single-chat v1 memory into the multi-chat layout without
  /// re-embedding anything: the old stats row becomes the first chat, and
  /// every exchange is given that chat's id and a content hash.
  static Future<void> _upgradeToV2(Database db) async {
    await db.transaction((txn) async {
      await txn.execute('ALTER TABLE exchanges ADD COLUMN chat_id INTEGER');
      await txn.execute('ALTER TABLE exchanges ADD COLUMN hash TEXT');
      await txn.execute(
        "ALTER TABLE exchanges ADD COLUMN source TEXT NOT NULL DEFAULT 'export'",
      );
      await _createV2Tables(txn);

      final rows = await txn.query(
        'exchanges',
        columns: ['id', 'context_text', 'reply', 'vector'],
      );
      final metaRows = await txn.query(
        'meta',
        where: 'key = ?',
        whereArgs: ['stats'],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.delete('meta', where: 'key = ?', whereArgs: ['stats']);
        return;
      }

      Map<Object?, Object?> stats = const {};
      if (metaRows.isNotEmpty) {
        final decoded = jsonDecode(metaRows.first['value']! as String);
        if (decoded is Map) stats = decoded;
      }
      final firstVector = rows.first['vector']! as Uint8List;
      final chatId = await txn.insert('chats', {
        'my_name': stats['myName'] as String? ?? '',
        'their_name': stats['theirName'] as String? ?? '',
        'embedding_model': stats['embeddingModel'] as String? ?? '',
        'dimensions':
            (stats['dimensions'] as num?)?.toInt() ?? firstVector.length ~/ 4,
        'built_at':
            (DateTime.tryParse(stats['builtAt'] as String? ?? '') ??
                    DateTime.now())
                .millisecondsSinceEpoch,
        'enabled': 1,
        'profile_json': jsonEncode(
          StyleProfile.measureTexts(
            rows.map((r) => r['reply']! as String),
          ).toJson(),
        ),
      });

      final batch = txn.batch();
      for (final row in rows) {
        batch.update(
          'exchanges',
          {
            'chat_id': chatId,
            'hash': StoredExchange.contentHash(
              row['context_text']! as String,
              row['reply']! as String,
            ),
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
      await batch.commit(noResult: true);
      await txn.delete('meta', where: 'key = ?', whereArgs: ['stats']);
    });
  }

  // --------------------------------------------------------------------- chats

  @override
  Future<List<ChatMemory>> chats() async {
    final db = await _open();
    final rows = await db.rawQuery('''
      SELECT c.*,
             COUNT(e.id) AS total,
             SUM(CASE WHEN e.id IS NOT NULL AND (
                   e.source = 'saved' OR e.ts IS NULL OR (
                     (c.range_from IS NULL OR e.ts >= c.range_from) AND
                     (c.range_until IS NULL OR e.ts < c.range_until)))
                 THEN 1 ELSE 0 END) AS n,
             SUM(CASE WHEN e.source = 'saved' THEN 1 ELSE 0 END) AS saved
      FROM chats c
      LEFT JOIN exchanges e ON e.chat_id = c.id
      GROUP BY c.id
      ORDER BY c.id ASC
    ''');
    return rows.map(_chatFromRow).toList(growable: false);
  }

  static ChatMemory _chatFromRow(Map<String, Object?> row) {
    Object? decode(String column) {
      try {
        return jsonDecode(row[column] as String? ?? '{}');
      } on FormatException {
        return null;
      }
    }

    return ChatMemory(
      id: (row['id']! as num).toInt(),
      myName: row['my_name'] as String? ?? '',
      theirName: row['their_name'] as String? ?? '',
      embeddingModel: row['embedding_model'] as String? ?? '',
      dimensions: (row['dimensions'] as num?)?.toInt() ?? 0,
      builtAt: DateTime.fromMillisecondsSinceEpoch(
        (row['built_at'] as num?)?.toInt() ?? 0,
      ),
      enabled: (row['enabled'] as num?)?.toInt() != 0,
      exchangeCount: (row['n'] as num?)?.toInt() ?? 0,
      savedCount: (row['saved'] as num?)?.toInt() ?? 0,
      profile: StyleProfile.fromJson(decode('profile_json')),
      stats: ChatStats.fromJson(decode('stats_json')),
      isGroup: (row['is_group'] as num?)?.toInt() == 1,
      app: ChatApp.parse(row['app']),
      from: _date(row['range_from']),
      // Stored as the start of the next day; shown as the last day used.
      until: switch (_date(row['range_until'])) {
        final DateTime next => DateTime(next.year, next.month, next.day - 1),
        null => null,
      },
      allCount: (row['total'] as num?)?.toInt(),
    );
  }

  static DateTime? _date(Object? ms) =>
      ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;

  @override
  Future<void> setChatDates(
    int chatId, {
    DateTime? from,
    DateTime? until,
  }) async {
    final db = await _open();
    await db.update(
      'chats',
      {
        'range_from': from == null
            ? null
            : DateTime(from.year, from.month, from.day).millisecondsSinceEpoch,
        'range_until': until == null
            ? null
            : DateTime(
                until.year,
                until.month,
                until.day + 1,
              ).millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  @override
  Future<(DateTime?, DateTime?)> dateSpan(int chatId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT MIN(ts) AS first, MAX(ts) AS last FROM exchanges '
      "WHERE chat_id = ? AND source = 'export'",
      [chatId],
    );
    return (_date(rows.first['first']), _date(rows.first['last']));
  }

  @override
  Future<ChatMemory> saveChat(
    ChatMemory chat, {
    List<StoredExchange> added = const [],
    bool replaceExisting = false,
  }) async {
    final db = await _open();
    late int chatId;
    await db.transaction((txn) async {
      final values = {
        'my_name': chat.myName,
        'their_name': chat.theirName,
        'embedding_model': chat.embeddingModel,
        'dimensions': chat.dimensions,
        'built_at': chat.builtAt.millisecondsSinceEpoch,
        'enabled': chat.enabled ? 1 : 0,
        'profile_json': jsonEncode(chat.profile.toJson()),
        'stats_json': jsonEncode(chat.stats.toJson()),
        'is_group': chat.isGroup ? 1 : 0,
        'app': chat.app.name,
      };
      if (chat.id < 0) {
        chatId = await txn.insert('chats', values);
      } else {
        chatId = chat.id;
        await txn.update('chats', values, where: 'id = ?', whereArgs: [chatId]);
      }
      if (replaceExisting) {
        await txn.delete(
          'exchanges',
          where: 'chat_id = ?',
          whereArgs: [chatId],
        );
      }
      final batch = txn.batch();
      for (final exchange in added) {
        batch.insert('exchanges', {
          'chat_id': chatId,
          'hash': exchange.hash,
          'source': exchange.source.name,
          'context_json': jsonEncode(
            exchange.context.map((t) => t.toJson()).toList(),
          ),
          'context_text': exchange.contextText,
          'reply': exchange.replyText,
          'ts': exchange.timestamp?.millisecondsSinceEpoch,
          'vector': VectorMath.encode(exchange.vector),
          'focus': exchange.focus == null
              ? null
              : VectorMath.encode(exchange.focus!),
        });
      }
      await batch.commit(noResult: true);
    });
    _cache.remove(chatId);
    final saved = (await chats()).where((c) => c.id == chatId);
    return saved.isEmpty ? chat.copyWith(id: chatId) : saved.first;
  }

  @override
  Future<Set<String>> hashesFor(int chatId) async {
    final db = await _open();
    final rows = await db.query(
      'exchanges',
      columns: ['hash'],
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
    return {for (final row in rows) row['hash']! as String};
  }

  @override
  Future<void> setChatEnabled(int chatId, {required bool enabled}) async {
    final db = await _open();
    await db.update(
      'chats',
      {'enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  @override
  Future<void> deleteChat(int chatId) async {
    final db = await _open();
    await db.transaction((txn) async {
      await txn.delete('exchanges', where: 'chat_id = ?', whereArgs: [chatId]);
      await txn.delete('chats', where: 'id = ?', whereArgs: [chatId]);
    });
    _cache.remove(chatId);
  }

  // ----------------------------------------------------------------- exchanges

  @override
  Future<int> count({Set<int>? chatIds}) async {
    if (chatIds != null && chatIds.isEmpty) return 0;
    final db = await _open();
    final where = _inClause(chatIds);
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM exchanges${where == null ? "" : " WHERE $where"}',
      chatIds?.toList(),
    );
    return (result.first['n'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<StoredExchange>> all({Set<int>? chatIds}) async {
    if (chatIds != null && chatIds.isEmpty) return const [];
    final db = await _open();
    final wanted =
        chatIds ??
        {
          for (final row in await db.query('chats', columns: ['id']))
            (row['id']! as num).toInt(),
        };
    final missing = wanted.where((id) => !_cache.containsKey(id)).toSet();
    if (missing.isNotEmpty) {
      final rows = await db.query(
        'exchanges',
        where: _inClause(missing),
        whereArgs: missing.toList(),
        orderBy: 'id ASC',
      );
      for (final id in missing) {
        _cache[id] = <StoredExchange>[];
      }
      for (final row in rows) {
        final exchange = _fromRow(row);
        _cache[exchange.chatId]!.add(exchange);
      }
    }
    // Each chat's moments outside the dates it is cut down to stay stored,
    // but aren't used.
    final ranges = {
      for (final c in await chats())
        if (wanted.contains(c.id) && c.isCut) c.id: c,
    };
    final out = <StoredExchange>[
      for (final id in wanted)
        for (final e in _cache[id] ?? const <StoredExchange>[])
          if (ranges[id]?.covers(e) ?? true) e,
    ]..sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  @override
  Future<void> saveFocus(Map<int, Float32List> focus) async {
    if (focus.isEmpty) return;
    final db = await _open();
    final batch = db.batch();
    for (final e in focus.entries) {
      batch.update(
        'exchanges',
        {'focus': VectorMath.encode(e.value)},
        where: 'id = ?',
        whereArgs: [e.key],
      );
    }
    await batch.commit(noResult: true);
    for (final rows in _cache.values) {
      for (var i = 0; i < rows.length; i++) {
        final f = focus[rows[i].id];
        if (f != null) rows[i] = rows[i].copyWith(focus: f);
      }
    }
  }

  static String? _inClause(Set<int>? ids) => ids == null
      ? null
      : 'chat_id IN (${List.filled(ids.length, '?').join(', ')})';

  // ------------------------------------------------------------------ feedback

  @override
  Future<void> recordFeedback(SuggestionFeedback feedback) async {
    final db = await _open();
    await db.insert('feedback', {
      'at': feedback.at.millisecondsSinceEpoch,
      'chat_id': feedback.chatId,
      'picked_index': feedback.pickedIndex,
      'picked_text': feedback.pickedText,
      'saved': feedback.saved ? 1 : 0,
      'extra_json': jsonEncode(feedback.toJson()),
    });
  }

  @override
  Future<List<SuggestionFeedback>> feedback() async {
    final db = await _open();
    final rows = await db.query('feedback', orderBy: 'id DESC');
    return [
      for (final row in rows)
        () {
          Object? extra;
          try {
            extra = jsonDecode(row['extra_json'] as String? ?? '{}');
          } on FormatException {
            extra = null;
          }
          final map = extra is Map ? extra : const {};
          return SuggestionFeedback(
            id: (row['id']! as num).toInt(),
            at: DateTime.fromMillisecondsSinceEpoch(
              (row['at'] as num?)?.toInt() ?? 0,
            ),
            chatId: (row['chat_id'] as num?)?.toInt(),
            pickedIndex: (row['picked_index'] as num?)?.toInt(),
            pickedText: row['picked_text'] as String?,
            saved: (row['saved'] as num?)?.toInt() == 1,
            shownKinds: SuggestionFeedback.kindsFromJson(map['shownKinds']),
            refinements: [
              ...?(map['refinements'] as List?)?.whereType<String>(),
            ],
            hadNote: map['hadNote'] == true,
          );
        }(),
    ];
  }

  // ------------------------------------------------------------------- wiping

  @override
  Future<void> deleteEverything() async {
    final db = await _open();
    await db.transaction((txn) async {
      await txn.delete('exchanges');
      await txn.delete('chats');
      await txn.delete('feedback');
      await txn.delete('meta');
    });
    _cache.clear();
    await db.close();
    _database = null;
    // Drop the file too, so "delete all my data" leaves nothing behind.
    if (!inMemory) await _db.deleteDatabase(await _path());
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
    _cache.clear();
  }

  static StoredExchange _fromRow(Map<String, Object?> row) {
    final contextJson = jsonDecode(row['context_json']! as String);
    final context = contextJson is List
        ? contextJson
              .whereType<Map<String, Object?>>()
              .map(ChatTurn.fromJson)
              .toList(growable: false)
        : const <ChatTurn>[];
    final ts = row['ts'];
    return StoredExchange(
      id: (row['id'] as num?)?.toInt() ?? -1,
      chatId: (row['chat_id'] as num?)?.toInt() ?? -1,
      hash: row['hash'] as String? ?? '',
      source: row['source'] == 'saved'
          ? ExchangeSource.saved
          : ExchangeSource.export,
      context: context,
      contextText: row['context_text']! as String,
      replyText: row['reply']! as String,
      vector: VectorMath.decode(row['vector']! as Uint8List),
      focus: row['focus'] is Uint8List
          ? VectorMath.decode(row['focus']! as Uint8List)
          : null,
      timestamp: ts is num
          ? DateTime.fromMillisecondsSinceEpoch(ts.toInt())
          : null,
    );
  }
}
