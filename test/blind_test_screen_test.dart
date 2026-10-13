import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replylikeme/models/chat_turn.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:replylikeme/models/ai_provider.dart';
import 'package:replylikeme/models/app_settings.dart';
import 'package:replylikeme/models/blind_test.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/screens/blind_test_screen.dart';
import 'package:replylikeme/services/blind_test_store.dart';
import 'package:replylikeme/services/memory_exchange_store.dart';
import 'package:replylikeme/services/openai_service.dart';
import 'package:replylikeme/services/vector_math.dart';
import 'package:replylikeme/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_smoke_test.dart' show pumpApp, trainedStore;
import 'explore_features_test.dart' show chat, fake, turn;

class _Key extends ApiKeysNotifier {
  @override
  Future<ApiKeys> build() async => const ApiKeys().withKey(
    AiProvider.openai,
    'sk-test-0123456789abcdefghij',
  );
}

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async =>
      const AppSettings(embeddingDimensions: 2);
}

BlindPair pair({required bool fooled, String real = 'real reply'}) => BlindPair(
  context: [turn('Maya', 'pub?')],
  real: real,
  generated: 'fake reply',
  realIsA: true,
  judgePick: fooled ? 'B' : 'A',
  why: 'too keen',
);

/// Built-in passes 2 times in 20; Try this 10 in 20: clearly better.
BlindRun run() => BlindRun(
  at: DateTime(2026, 10, 12, 9),
  replyModel: 'gpt-5.6-terra',
  promptVersion: 2,
  results: [
    BlindPromptResult(
      prompt: const BlindPrompt(
        label: BlindPrompt.builtIn,
        text: AppSettings.defaultSystemPrompt,
      ),
      pairs: [for (var i = 0; i < 20; i++) pair(fooled: i < 2)],
    ),
    BlindPromptResult(
      prompt: const BlindPrompt(label: BlindPrompt.tryThis, text: 'BE TERSE'),
      pairs: [for (var i = 0; i < 20; i++) pair(fooled: i < 10)],
    ),
  ],
);

void main() {
  late String clipboard;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    clipboard = '';
  });

  Future<MemoryExchangeStore> pump(
    WidgetTester tester, {
    OpenAiService? openai,
    List<StoredExchange> rows = const [],
  }) async {
    tester.view.physicalSize = const Size(1200, 12000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    final store = MemoryExchangeStore(chats: [chat()], rows: rows);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiKeysProvider.overrideWith(_Key.new),
          exchangeStoreProvider.overrideWithValue(store),
          openAiServiceProvider.overrideWithValue(
            openai ?? fake(answer: (_) => ''),
          ),
          settingsProvider.overrideWith(_Settings.new),
        ],
        child: MaterialApp(home: BlindTestScreen(chat: chat())),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('shows each prompt\'s score and how it compares', (tester) async {
    await const BlindTestStore().save(
      1,
      BlindTestState(seed: 1, runs: [run()]),
    );
    await pump(tester);
    expect(find.byKey(const ValueKey('score-Built-in')), findsOneWidget);
    expect(
      find.text('Passed as you in 2 of 20 with the judge'),
      findsOneWidget,
    );
    expect(
      find.text('Passed as you in 10 of 20 with the judge'),
      findsOneWidget,
    );
    expect(find.text('Clearly better than Built-in'), findsOneWidget);

    // The misses are there on request.
    expect(find.text('You: real reply'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('misses-Try this')));
    await tester.pumpAndSettle();
    expect(find.text('You: real reply'), findsNWidgets(10));
    expect(find.text('Judge: too keen'), findsNWidgets(10));

    // A clearly better prompt can be taken on.
    await tester.tap(find.byKey(const ValueKey('use-Try this')));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BlindTestScreen)),
    );
    expect(container.read(settingsProvider).value!.systemPrompt, 'BE TERSE');
  });

  testWidgets('copies the scores alone, or everything', (tester) async {
    await const BlindTestStore().save(
      1,
      BlindTestState(seed: 1, runs: [run()]),
    );
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('copy')));
    await tester.pumpAndSettle();
    expect(find.textContaining('real lines from your chat'), findsOneWidget);
    await tester.tap(find.text('Scores only'));
    await tester.pumpAndSettle();
    expect(clipboard, contains('passed as you 10 of 20 (50%)'));
    expect(clipboard, isNot(contains('real reply')));
    expect(clipboard, isNot(contains('BE TERSE')));

    await tester.tap(find.byKey(const ValueKey('copy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy everything'));
    await tester.pumpAndSettle();
    expect(clipboard, contains('BE TERSE'));
    expect(clipboard, contains('You: real reply'));
  });

  testWidgets('you can play spot the real one', (tester) async {
    await const BlindTestStore().save(
      1,
      BlindTestState(
        seed: 1,
        runs: [
          BlindRun(
            at: DateTime(2026, 10, 12),
            replyModel: 'm',
            promptVersion: 2,
            results: [
              BlindPromptResult(
                prompt: const BlindPrompt(
                  label: BlindPrompt.builtIn,
                  text: 'p',
                ),
                pairs: [pair(fooled: false), pair(fooled: true)],
              ),
            ],
          ),
        ],
      ),
    );
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('play')));
    await tester.pumpAndSettle();
    expect(find.text('Spot the real one · 1 of 2'), findsOneWidget);
    // A is the real one: right once, then fooled once.
    await tester.tap(find.byKey(const ValueKey('pick-A')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-B')));
    await tester.pumpAndSettle();
    // All played: back to the scores, now with yours.
    expect(find.byKey(const ValueKey('play')), findsNothing);
    expect(
      find.text('Passed as you in 1 of 2 with the judge · 1 of 2 with you'),
      findsOneWidget,
    );
    final saved = await const BlindTestStore().forChat(1);
    expect(saved!.runs.single.results.single.userFoolRate, 0.5);
  });

  testWidgets('a run writes, judges and shows the score', (tester) async {
    final start = DateTime(2026, 1, 1, 12);
    final openai = fake(
      embed: (_) => [1, 0],
      answer: (body) => body.containsKey('response_format')
          ? '{"pick": "B", "why": "x"}'
          : 'generated',
    );
    await pump(
      tester,
      openai: openai,
      rows: [
        for (var i = 1; i <= 25; i++)
          StoredExchange(
            id: i,
            chatId: 1,
            context: [turn('Maya', 'question $i')],
            contextText: 'Maya: question $i',
            replyText: 'answer $i',
            vector: VectorMath.normalise([1, 0]),
            timestamp: start.add(Duration(days: i)),
          ),
      ],
    );
    expect(find.text('60 calls · gpt-5.6-terra'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('run')));
    await tester.pumpAndSettle();
    final saved = await const BlindTestStore().forChat(1);
    expect(saved!.runs, hasLength(1));
    expect(find.byKey(const ValueKey('score-Built-in')), findsOneWidget);
  });

  testWidgets('openers can be tested too, kept apart from replies', (
    tester,
  ) async {
    final start = DateTime(2026, 1, 1, 12);
    final openai = fake(
      embed: (_) => [1, 0],
      answer: (body) => body.containsKey('response_format')
          ? '{"pick": "B", "why": "x"}'
          : 'generated',
    );
    await pump(
      tester,
      openai: openai,
      rows: [
        for (var i = 1; i <= 25; i++)
          StoredExchange(
            id: i,
            chatId: 1,
            context: [
              ChatTurn(
                sender: 'Maya',
                text: 'night $i',
                messageCount: 1,
                lastTimestamp: start.add(Duration(days: 2 * i)),
              ),
            ],
            contextText: 'Maya: night $i',
            replyText: 'morning $i',
            vector: VectorMath.normalise([1, 0]),
            timestamp: start.add(Duration(days: 2 * i + 1)),
          ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('kind-openers')));
    await tester.pumpAndSettle();
    expect(find.text('80 calls · gpt-5.6-terra'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('run')));
    await tester.pumpAndSettle();
    final saved = await const BlindTestStore().forChat(1);
    expect(saved!.runs.single.kind, BlindKind.openers);
    expect(find.byKey(const ValueKey('score-Built-in')), findsOneWidget);
    // Replies have no run of their own yet.
    await tester.tap(find.byKey(const ValueKey('kind-replies')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('score-Built-in')), findsNothing);
  });

  testWidgets('home opens the blind test from a chat\'s menu', (tester) async {
    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: const Stream.empty(),
    );
    await pumpApp(
      tester,
      apiKey: 'sk-test-0123456789abcdefghij',
      store: trainedStore(),
    );
    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Blind test…'));
    await tester.pumpAndSettle();
    expect(find.byType(BlindTestScreen), findsOneWidget);
  });
}
