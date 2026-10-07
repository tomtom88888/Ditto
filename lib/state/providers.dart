import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ai_provider.dart';
import '../models/api_usage.dart';
import '../models/app_settings.dart';
import '../models/stored_exchange.dart';
import '../models/suggestion_feedback.dart';
import '../services/ask_chats.dart';
import '../services/chart_maker.dart';
import '../services/chat_analysis.dart';
import '../services/chat_facts.dart';
import '../services/chat_groupings.dart';
import '../services/chat_search.dart';
import '../services/embeddings_store.dart';
import '../services/exchange_store.dart';
import '../services/finetune_service.dart';
import '../services/groupings_store.dart';
import '../services/openai_service.dart';
import '../services/reply_generator.dart';
import '../services/secure_key_store.dart';
import '../services/settings_store.dart';
import '../services/style_memory_service.dart';
import '../services/usage_store.dart';
import 'app_activity.dart';
import 'keep_awake.dart';

// --------------------------------------------------------------------- storage

final secureKeyStoreProvider = Provider<SecureKeyStore>(
  (ref) => SecureKeyStore(),
);

final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => const SettingsStore(),
);

final usageStoreProvider = Provider<UsageStore>((ref) => const UsageStore());

final groupingsStoreProvider = Provider<GroupingsStore>(
  (ref) => const GroupingsStore(),
);

final factsStoreProvider = Provider<FactsStore>((ref) => const FactsStore());

final analysisStoreProvider = Provider<AnalysisStore>(
  (ref) => const AnalysisStore(),
);

/// Typed as the interface so tests can substitute an in-memory store.
final exchangeStoreProvider = Provider<ExchangeStore>((ref) {
  final store = SqfliteExchangeStore();
  ref.onDispose(store.close);
  return store;
});

// ------------------------------------------------------------------- API key

/// The saved API keys: none until setup has happened.
///
/// The values are held in memory only while the app runs; the only copy at
/// rest is in the platform keystore.
class ApiKeysNotifier extends AsyncNotifier<ApiKeys> {
  @override
  Future<ApiKeys> build() => ref.read(secureKeyStoreProvider).readAll();

  /// Saves [key] for [provider], and moves any model whose provider has no
  /// key over to one that does.
  Future<void> save(AiProvider provider, String key) async {
    await ref.read(secureKeyStoreProvider).write(provider, key);
    final current = state.value ?? await future;
    await _publish(current.withKey(provider, key));
  }

  Future<void> remove(AiProvider provider) async {
    await ref.read(secureKeyStoreProvider).delete(provider);
    final current = state.value ?? await future;
    await _publish(current.without(provider));
  }

  Future<void> clear() async {
    await ref.read(secureKeyStoreProvider).deleteAll();
    state = const AsyncValue.data(ApiKeys());
  }

  Future<void> _publish(ApiKeys keys) async {
    state = AsyncValue.data(keys);
    await ref.read(settingsProvider.notifier).edit((s) => s.fittedTo(keys));
  }
}

final apiKeysProvider = AsyncNotifierProvider<ApiKeysNotifier, ApiKeys>(
  ApiKeysNotifier.new,
);

// ------------------------------------------------------------------- settings

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() => ref.read(settingsStoreProvider).load();

  /// Persists [next] and publishes it.
  ///
  /// Not called `update`: AsyncNotifier already defines that.
  Future<void> replace(AppSettings next) async {
    await ref.read(settingsStoreProvider).save(next);
    state = AsyncValue.data(next);
  }

  /// Applies a change to the current settings, loading them first if needed.
  Future<void> edit(AppSettings Function(AppSettings current) change) async {
    final current = state.value ?? await future;
    await replace(change(current));
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

// -------------------------------------------------------------------- services

/// `null` until a key is saved, so screens can't accidentally call an AI
/// without one. Talks to whichever providers have a key.
final openAiServiceProvider = Provider<OpenAiService?>((ref) {
  final keys = ref.watch(apiKeysProvider).value;
  if (keys == null || keys.isEmpty) return null;
  final service = OpenAiService.forKeys(
    keys,
    // Looked up on every call rather than captured, so the tally keeps
    // counting after "delete all my data" rebuilds it.
    onUsage: (usage) => ref.read(usageProvider.notifier).record(usage),
    // Survive the screen turning off or another app coming to the front:
    // Android is asked to keep the app running while a request is out, and
    // one the phone cuts off anyway waits for the app to come back.
    interruptions: () => AppActivity.instance.interruptions,
    // Kept alive by the service, a dropped connection is simply tried again
    // after a moment; otherwise it waits for the app to be back in front.
    whenActive: () => KeepAwake.instance.running
        ? Future<void>.delayed(const Duration(seconds: 2))
        : AppActivity.instance.whenActive(),
    keepAlive: KeepAwake.instance.during,
  );
  ref.onDispose(service.close);
  return service;
});

final styleMemoryServiceProvider = Provider<StyleMemoryService?>((ref) {
  final openai = ref.watch(openAiServiceProvider);
  if (openai == null) return null;
  return StyleMemoryService(
    openai: openai,
    store: ref.watch(exchangeStoreProvider),
  );
});

final replyGeneratorProvider = Provider<ReplyGenerator?>((ref) {
  final openai = ref.watch(openAiServiceProvider);
  if (openai == null) return null;
  return ReplyGenerator(openai: openai);
});

final chatGrouperProvider = Provider<ChatGrouper?>((ref) {
  final openai = ref.watch(openAiServiceProvider);
  if (openai == null) return null;
  return ChatGrouper(openai: openai);
});

final chatFactsProvider = Provider<ChatFacts?>((ref) {
  final openai = ref.watch(openAiServiceProvider);
  if (openai == null) return null;
  return ChatFacts(openai: openai);
});

final chatAnalystProvider = Provider<ChatAnalyst?>((ref) {
  final openai = ref.watch(openAiServiceProvider);
  if (openai == null) return null;
  return ChatAnalyst(openai: openai);
});

final chartMakerProvider = Provider<ChartMaker?>((ref) {
  final openai = ref.watch(openAiServiceProvider);
  if (openai == null) return null;
  return ChartMaker(openai: openai);
});

final chatSearchProvider = Provider<ChatSearch?>((ref) {
  final openai = ref.watch(openAiServiceProvider);
  if (openai == null) return null;
  return ChatSearch(openai: openai, store: ref.watch(exchangeStoreProvider));
});

final askChatsProvider = Provider<AskChats?>((ref) {
  final openai = ref.watch(openAiServiceProvider);
  final search = ref.watch(chatSearchProvider);
  if (openai == null || search == null) return null;
  return AskChats(openai: openai, search: search);
});

final fineTuneServiceProvider = Provider<FineTuneService?>((ref) {
  final openai = ref.watch(openAiServiceProvider);
  if (openai == null) return null;
  return FineTuneService(openai: openai);
});

// ---------------------------------------------------------------- style memory

/// Every learned chat, with whether it is switched on.
class ChatsNotifier extends AsyncNotifier<List<ChatMemory>> {
  @override
  Future<List<ChatMemory>> build() => ref.read(exchangeStoreProvider).chats();

  /// Re-reads the store, after training or saving a reply.
  Future<void> reload() async {
    state = AsyncValue.data(await ref.read(exchangeStoreProvider).chats());
  }

  /// Checks or unchecks a chat in the home list. The change shows at once and
  /// is written behind it.
  Future<void> setEnabled(int chatId, {required bool enabled}) async {
    final current = state.value;
    if (current != null) {
      state = AsyncValue.data([
        for (final chat in current)
          chat.id == chatId ? chat.copyWith(enabled: enabled) : chat,
      ]);
    }
    await ref
        .read(exchangeStoreProvider)
        .setChatEnabled(chatId, enabled: enabled);
  }

  Future<void> delete(int chatId) async {
    await ref.read(exchangeStoreProvider).deleteChat(chatId);
    // What was learned about them goes with the chat.
    await ref.read(factsStoreProvider).remove(chatId);
    await ref.read(analysisStoreProvider).remove(chatId);
    await reload();
  }
}

final chatsProvider = AsyncNotifierProvider<ChatsNotifier, List<ChatMemory>>(
  ChatsNotifier.new,
);

/// What happened to each set of suggestions, newest first.
final feedbackProvider = FutureProvider<List<SuggestionFeedback>>(
  (ref) => ref.watch(exchangeStoreProvider).feedback(),
);

// ---------------------------------------------------------------------- usage

/// Tokens used per month, newest month first.
class UsageNotifier extends AsyncNotifier<List<MonthlyUsage>> {
  /// Records are chained so two calls finishing together can't both read the
  /// old tally and lose one of the updates.
  Future<void> _pending = Future.value();

  @override
  Future<List<MonthlyUsage>> build() => ref.read(usageStoreProvider).load();

  void record(ApiUsage usage) {
    _pending = _pending.then((_) async {
      try {
        final months = await ref.read(usageStoreProvider).record(usage);
        state = AsyncValue.data(months);
      } on Object {
        // Counting is a convenience; a failure to count must never fail the
        // call that was counted.
      }
    });
  }
}

final usageProvider = AsyncNotifierProvider<UsageNotifier, List<MonthlyUsage>>(
  UsageNotifier.new,
);

// ----------------------------------------------------------------- data wiping

/// Deletes everything this app stored on the device.
///
/// The API keys are handled separately, because "forget what you learned
/// about me" and "forget my credentials" are different requests.
class DataWiper {
  const DataWiper(this._ref);

  final Ref _ref;

  Future<void> wipe({required bool includeApiKey}) async {
    await _ref.read(exchangeStoreProvider).deleteEverything();
    await _ref.read(settingsStoreProvider).clear();
    await _ref.read(usageStoreProvider).clear();
    await _ref.read(groupingsStoreProvider).clear();
    await _ref.read(factsStoreProvider).clear();
    await _ref.read(analysisStoreProvider).clear();
    if (includeApiKey) await _ref.read(apiKeysProvider.notifier).clear();
    _ref.invalidate(settingsProvider);
    _ref.invalidate(exchangeStoreProvider);
    _ref.invalidate(chatsProvider);
    _ref.invalidate(feedbackProvider);
    _ref.invalidate(usageProvider);
    if (!includeApiKey) {
      // The default models may belong to a provider without a key.
      final keys = await _ref.read(apiKeysProvider.future);
      await _ref.read(settingsProvider.notifier).edit((s) => s.fittedTo(keys));
    }
  }
}

final dataWiperProvider = Provider<DataWiper>(DataWiper.new);
