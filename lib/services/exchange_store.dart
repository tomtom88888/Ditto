import 'dart:typed_data';

import '../models/stored_exchange.dart';
import '../models/suggestion_feedback.dart';

/// The local style memory: one or more learned chats, their exchanges, and
/// the record of which suggestions you took.
///
/// An interface rather than a concrete class so the services above it can be
/// unit-tested without a device database.
abstract interface class ExchangeStore {
  /// Every learned chat, oldest first.
  Future<List<ChatMemory>> chats();

  /// Creates or updates [chat] and adds [added] to it, in one transaction.
  ///
  /// With [replaceExisting] the chat's current exchanges are dropped first —
  /// used when they were embedded with a different model and can no longer be
  /// compared. Training is all-or-nothing: a half-embedded import would
  /// silently skew every retrieval. Returns the chat as stored, with its id
  /// and counts filled in.
  Future<ChatMemory> saveChat(
    ChatMemory chat, {
    List<StoredExchange> added = const [],
    bool replaceExisting = false,
  });

  /// The content hashes already stored for a chat, so a re-import only embeds
  /// what is new.
  Future<Set<String>> hashesFor(int chatId);

  /// Turns a chat on or off for generation.
  Future<void> setChatEnabled(int chatId, {required bool enabled});

  /// Removes one chat and everything learned from it.
  Future<void> deleteChat(int chatId);

  /// Exchanges stored, in the given chats or in all of them.
  Future<int> count({Set<int>? chatIds});

  /// Exchanges in the given chats (or all of them), oldest first.
  Future<List<StoredExchange>> all({Set<int>? chatIds});

  /// Cuts [chatId] down to [from]–[until] (whole days); both `null` uses the
  /// whole chat again. Exchanges outside are kept, just not used.
  Future<void> setChatDates(int chatId, {DateTime? from, DateTime? until});

  /// The first and last dates in [chatId]'s export, whatever dates are used.
  Future<(DateTime?, DateTime?)> dateSpan(int chatId);

  /// Stores search fingerprints for exchanges already saved, by row id.
  Future<void> saveFocus(Map<int, Float32List> focus);

  Future<void> recordFeedback(SuggestionFeedback feedback);

  /// Recorded feedback, newest first.
  Future<List<SuggestionFeedback>> feedback();

  /// Wipes every chat, exchange and feedback record.
  Future<void> deleteEverything();
}
