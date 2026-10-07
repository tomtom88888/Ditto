import 'dart:typed_data';

import '../models/stored_exchange.dart';
import '../models/suggestion_feedback.dart';
import 'exchange_store.dart';

/// An [ExchangeStore] held entirely in memory.
///
/// Behaves like the sqflite store — ids, counts, per-chat hashes — so tests
/// and previews can run the real services without a device database.
class MemoryExchangeStore implements ExchangeStore {
  MemoryExchangeStore({
    List<ChatMemory> chats = const [],
    List<StoredExchange> rows = const [],
  }) {
    for (final chat in chats) {
      final id = chat.id < 0 ? _nextChatId : chat.id;
      _nextChatId = id >= _nextChatId ? id + 1 : _nextChatId;
      _chats[id] = chat.copyWith(id: id);
    }
    for (final row in rows) {
      final id = row.id < 0 ? _nextRowId : row.id;
      _nextRowId = id >= _nextRowId ? id + 1 : _nextRowId;
      this.rows.add(row.copyWith(id: id));
    }
  }

  final Map<int, ChatMemory> _chats = {};
  final List<StoredExchange> rows = [];
  final List<SuggestionFeedback> feedbackLog = [];
  int _nextChatId = 1;
  int _nextRowId = 1;

  /// How many times [saveChat] ran, for tests that check nothing was written.
  int saveCalls = 0;

  ChatMemory _withCounts(ChatMemory chat) {
    final mine = rows.where((r) => r.chatId == chat.id).toList();
    return ChatMemory(
      id: chat.id,
      myName: chat.myName,
      theirName: chat.theirName,
      embeddingModel: chat.embeddingModel,
      dimensions: chat.dimensions,
      builtAt: chat.builtAt,
      exchangeCount: mine.where(chat.covers).length,
      savedCount: mine.where((r) => r.source == ExchangeSource.saved).length,
      enabled: chat.enabled,
      profile: chat.profile,
      stats: chat.stats,
      isGroup: chat.isGroup,
      app: chat.app,
      from: chat.from,
      until: chat.until,
      allCount: mine.length,
    );
  }

  @override
  Future<List<ChatMemory>> chats() async => (_chats.keys.toList()..sort())
      .map((id) => _withCounts(_chats[id]!))
      .toList();

  @override
  Future<ChatMemory> saveChat(
    ChatMemory chat, {
    List<StoredExchange> added = const [],
    bool replaceExisting = false,
  }) async {
    saveCalls++;
    final id = chat.id < 0 ? _nextChatId++ : chat.id;
    _chats[id] = chat.copyWith(id: id);
    if (replaceExisting) rows.removeWhere((r) => r.chatId == id);
    for (final exchange in added) {
      rows.add(exchange.copyWith(id: _nextRowId++, chatId: id));
    }
    return _withCounts(_chats[id]!);
  }

  @override
  Future<Set<String>> hashesFor(int chatId) async => {
    for (final row in rows)
      if (row.chatId == chatId) row.hash,
  };

  @override
  Future<void> setChatEnabled(int chatId, {required bool enabled}) async {
    final chat = _chats[chatId];
    if (chat != null) _chats[chatId] = chat.copyWith(enabled: enabled);
  }

  @override
  Future<void> deleteChat(int chatId) async {
    _chats.remove(chatId);
    rows.removeWhere((r) => r.chatId == chatId);
  }

  @override
  Future<int> count({Set<int>? chatIds}) async =>
      (await all(chatIds: chatIds)).length;

  @override
  Future<void> saveFocus(Map<int, Float32List> focus) async {
    for (var i = 0; i < rows.length; i++) {
      final f = focus[rows[i].id];
      if (f != null) rows[i] = rows[i].copyWith(focus: f);
    }
  }

  @override
  Future<List<StoredExchange>> all({Set<int>? chatIds}) async => [
    for (final row in rows)
      if ((chatIds == null || chatIds.contains(row.chatId)) &&
          (_chats[row.chatId]?.covers(row) ?? true))
        row,
  ];

  @override
  Future<void> setChatDates(
    int chatId, {
    DateTime? from,
    DateTime? until,
  }) async {
    final chat = _chats[chatId];
    if (chat != null) _chats[chatId] = chat.withDates(from, until);
  }

  @override
  Future<(DateTime?, DateTime?)> dateSpan(int chatId) async {
    DateTime? first;
    DateTime? last;
    for (final r in rows) {
      final at = r.timestamp;
      if (r.chatId != chatId || at == null) continue;
      if (r.source == ExchangeSource.saved) continue;
      if (first == null || at.isBefore(first)) first = at;
      if (last == null || at.isAfter(last)) last = at;
    }
    return (first, last);
  }

  @override
  Future<void> recordFeedback(SuggestionFeedback feedback) async =>
      feedbackLog.add(feedback);

  @override
  Future<List<SuggestionFeedback>> feedback() async =>
      feedbackLog.reversed.toList();

  @override
  Future<void> deleteEverything() async {
    _chats.clear();
    rows.clear();
    feedbackLog.clear();
  }
}
