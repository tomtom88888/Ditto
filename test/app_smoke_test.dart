import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:replylikeme/models/ai_provider.dart';
import 'package:replylikeme/main.dart';
import 'package:replylikeme/models/app_settings.dart';
import 'package:replylikeme/models/chat_app.dart';
import 'package:replylikeme/models/chat_stats.dart';
import 'package:replylikeme/models/chat_turn.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/screens/settings_screen.dart';
import 'package:replylikeme/services/memory_exchange_store.dart';
import 'package:replylikeme/services/whatsapp_parser.dart';
import 'package:replylikeme/state/providers.dart';
import 'package:replylikeme/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory style memory, so no database is touched.
typedef FakeStore = MemoryExchangeStore;

/// Stands in for the keystore-backed notifier.
class FakeApiKey extends ApiKeysNotifier {
  FakeApiKey(this.key);

  final String? key;

  @override
  Future<ApiKeys> build() async => key == null
      ? const ApiKeys()
      : const ApiKeys().withKey(AiProvider.openai, key!);
}

StoredExchange exampleExchange({int chatId = 1}) => StoredExchange(
  id: -1,
  chatId: chatId,
  context: const [ChatTurn(sender: 'Sam', text: 'pub?', messageCount: 1)],
  contextText: 'Sam: pub?',
  replyText: 'go on then',
  vector: Float32List(2),
);

ChatMemory exampleChat({int id = 1, String them = 'Sam'}) => ChatMemory(
  id: id,
  embeddingModel: AppSettings.defaultEmbeddingModel,
  dimensions: 512,
  myName: 'Robin',
  theirName: them,
  builtAt: DateTime(2026, 9, 19, 14, 30),
);

/// A store holding one learned chat with Sam.
FakeStore trainedStore() =>
    FakeStore(chats: [exampleChat()], rows: [exampleExchange()]);

/// The test viewport is short, so anything below the fold has to be scrolled
/// into view before it is built at all.
Future<void> scrollTo(WidgetTester tester, Finder target) async {
  await tester.dragUntilVisible(
    target,
    find.byType(ListView).last,
    const Offset(0, -200),
  );
  await tester.pumpAndSettle();
}

Future<void> pumpApp(
  WidgetTester tester, {
  String? apiKey,
  FakeStore? store,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiKeysProvider.overrideWith(() => FakeApiKey(apiKey)),
        exchangeStoreProvider.overrideWithValue(store ?? FakeStore()),
      ],
      child: const DittoApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: const Stream.empty(),
    );
  });

  testWidgets('with no key saved, the app opens on setup', (tester) async {
    await pumpApp(tester);

    expect(find.text('Your OpenAI, Claude or Gemini API key'), findsOneWidget);
    expect(find.text('Check key & continue'), findsOneWidget);
    // The privacy promise is made before the key is asked for.
    expect(find.text('WHERE YOUR WORDS GO'), findsOneWidget);
    expect(
      find.text('Your chat file stays on this phone. Always.'),
      findsOneWidget,
    );
  });

  testWidgets('a malformed key is rejected without a network call', (
    tester,
  ) async {
    await pumpApp(tester);

    // The design dims the button until there is something to check, so the
    // frame has to land before it can be tapped.
    await tester.enterText(find.byType(TextField), 'not-a-key');
    await tester.pump();
    await tester.tap(find.text('Check key & continue'));
    await tester.pump();

    expect(
      find.textContaining("doesn't look like an OpenAI (sk-…), Claude"),
      findsOneWidget,
    );
  });

  testWidgets('with a key but nothing learned, home says so', (tester) async {
    await pumpApp(tester, apiKey: 'sk-test-0123456789abcdefghij');

    expect(find.text('Ditto'), findsOneWidget);
    expect(find.text("It doesn't know you yet."), findsOneWidget);
    expect(find.text('Teach it your voice'), findsOneWidget);

    // Writing a reply is locked until there is something to imitate.
    expect(find.text('Write a reply'), findsOneWidget);
    expect(
      find.text('Nothing learned yet \u2014 teach it first'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('a trained memory is summarised on home', (tester) async {
    await pumpApp(
      tester,
      apiKey: 'sk-test-0123456789abcdefghij',
      store: trainedStore(),
    );

    // The hero names who it knows and how much of you it read; 'Sam' is in
    // the hero and in the chat list.
    expect(find.text('Sam'), findsNWidgets(2));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('of your replies learned'), findsOneWidget);

    // Trained, writing is the one big button. Adding a chat is the last row
    // of the chat list, and the two ways to look closer sit side by side.
    expect(find.text('Write a reply'), findsOneWidget);
    expect(find.text('From a screenshot or pasted chat'), findsOneWidget);
    expect(find.text('Add or refresh a chat'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(
      tester.getTopLeft(find.text('Chat data')).dy,
      tester.getTopLeft(find.text('Chat groupings')).dy,
      reason: 'the two tiles share a row',
    );

    await tester.tap(find.text('Add or refresh a chat'));
    await tester.pumpAndSettle();
    expect(find.textContaining('export'), findsWidgets);
  });

  testWidgets('settings opens and shows the masked key and defaults', (
    tester,
  ) async {
    await pumpApp(
      tester,
      apiKey: 'sk-proj-0123456789abcdefghij',
      store: FakeStore(chats: [exampleChat()]),
    );

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    // Masked, never the whole key.
    expect(find.text('sk-proj******ghij'), findsOneWidget);
    expect(find.text('sk-proj-0123456789abcdefghij'), findsNothing);

    // The defaults the README documents. The vision and generation fields
    // share a default, so that id appears twice.
    expect(find.text(AppSettings.defaultVisionModel), findsNWidgets(2));
    expect(find.text(AppSettings.defaultEmbeddingModel), findsOneWidget);

    await scrollTo(tester, find.text('Style memory'));
    expect(find.text('Style memory'), findsOneWidget);
    expect(find.text('Fine-tuned'), findsOneWidget);

    // Spending is tallied on the phone; nothing has been spent yet.
    await scrollTo(tester, find.text('Spending'));
    expect(find.text('nothing yet'), findsOneWidget);
    expect(find.text('Chat input price'), findsOneWidget);

    await scrollTo(tester, find.text('Delete all my data'));
    expect(find.text('Delete all my data'), findsOneWidget);
  });

  testWidgets('the system prompt is editable and resettable', (tester) async {
    await pumpApp(
      tester,
      apiKey: 'sk-test-0123456789abcdefghij',
      store: FakeStore(chats: [exampleChat()]),
    );

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    await scrollTo(
      tester,
      find.text('What the model is told before your examples'),
    );

    // Unedited, there is nothing to undo, so no reset is offered.
    expect(find.text('Reset to default'), findsNothing);

    final field = find.byWidgetPredicate(
      (w) => w is TextField && (w.controller?.text ?? '').contains('{me}'),
    );
    expect(field, findsOneWidget);

    await tester.enterText(field, 'Answer as {me}. Be terse.');
    await tester.pump();
    // The edit is committed when the field loses focus.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text('Reset to default'));
    expect(find.text('Reset to default'), findsOneWidget);

    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();
    expect(find.text('Reset to default'), findsNothing);
  });

  testWidgets('the delete dialog separates the data from the key', (
    tester,
  ) async {
    final store = trainedStore();
    await pumpApp(tester, apiKey: 'sk-test-0123456789abcdefghij', store: store);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('Delete all my data'));
    await tester.tap(find.text('Delete all my data'));
    await tester.pumpAndSettle();

    expect(find.text('Delete all my data?'), findsOneWidget);
    expect(find.text('Delete, keep my key'), findsOneWidget);

    await tester.tap(find.text('Delete, keep my key'));
    await tester.pumpAndSettle();

    expect(store.rows, isEmpty);
    expect(await store.chats(), isEmpty);
  });

  testWidgets('tapping a chat writes a reply to that person', (tester) async {
    final store = FakeStore(
      chats: [
        exampleChat(),
        exampleChat(id: 2, them: 'Mum').copyWith(app: ChatApp.instagram),
      ],
      rows: [exampleExchange(), exampleExchange(chatId: 2)],
    );
    await pumpApp(tester, apiKey: 'sk-test-0123456789abcdefghij', store: store);

    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('Sam & Mum'), findsWidgets);
    expect(find.textContaining('Instagram ·'), findsOneWidget);
    expect(find.textContaining('WhatsApp ·'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('chat-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-2')));
    await tester.pumpAndSettle();
    expect(find.text('Replying to \u2068Mum\u2069'), findsOneWidget);
  });

  testWidgets('a chat cut down to some dates says so on home', (tester) async {
    final store = trainedStore();
    await store.setChatDates(
      1,
      from: DateTime(2026, 2, 1),
      until: DateTime(2026, 3, 31),
    );
    await pumpApp(tester, apiKey: 'sk-test-0123456789abcdefghij', store: store);
    expect(find.byKey(const ValueKey('dates-1')), findsOneWidget);
    expect(find.text('1 Feb 2026 – 31 Mar 2026'), findsOneWidget);
  });

  testWidgets('chat data asks for a re-import when a chat has no numbers', (
    tester,
  ) async {
    await pumpApp(
      tester,
      apiKey: 'sk-test-0123456789abcdefghij',
      store: FakeStore(chats: [exampleChat()], rows: [exampleExchange()]),
    );
    await scrollTo(tester, find.text('Chat data'));
    await tester.tap(find.text('Chat data'));
    await tester.pumpAndSettle();

    expect(find.text('No numbers yet'), findsOneWidget);
    expect(find.text('Counted on your phone. No API calls.'), findsOneWidget);
  });

  testWidgets('chat data shows the numbers for the chat picked', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 9000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final stats = ChatStats.from(
      WhatsAppParser.parse(
        '02/03/2026, 09:00 - Sam: pub tonight?\n'
        '02/03/2026, 09:04 - Robin: go on then\n'
        '02/03/2026, 21:00 - Sam: home safe?\n'
        '02/03/2026, 21:02 - Robin: yep',
      ),
      myName: 'Robin',
    );
    await pumpApp(
      tester,
      apiKey: 'sk-test-0123456789abcdefghij',
      store: FakeStore(
        chats: [
          exampleChat().copyWith(stats: stats),
          exampleChat(id: 2, them: 'Mum'),
        ],
        rows: [exampleExchange(), exampleExchange(chatId: 2)],
      ),
    );
    await tester.tap(find.text('Chat data'));
    await tester.pumpAndSettle();

    // Sam's chat is first, and has numbers.
    expect(find.text('4'), findsWidgets);
    expect(find.text('Typical reply time'), findsOneWidget);
    expect(find.text('3 min'), findsOneWidget, reason: 'median of 4 and 2');
    expect(find.text('Through the day'), findsOneWidget);
    expect(find.text('What stands out'), findsOneWidget);
    expect(find.text('09:00–10:00 · 2 messages — the busiest'), findsOneWidget);

    // Tapping a bar reads out that bar.
    final hours = find.byKey(const ValueKey('by-hour'));
    final bars = find.descendant(
      of: hours,
      matching: find.byType(GestureDetector),
    );
    await tester.tap(bars.at(21));
    await tester.pumpAndSettle();
    expect(find.text('21:00–22:00 · 2 messages'), findsOneWidget);

    // Mum's chat was imported before numbers were counted.
    await tester.tap(find.text('Mum'));
    await tester.pumpAndSettle();
    expect(find.text('No numbers yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('follows the phone into dark mode without losing its place', (
    tester,
  ) async {
    addTearDown(() {
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
      Paper.use(Brightness.light);
    });
    await pumpApp(
      tester,
      apiKey: 'sk-test-0123456789abcdefghij',
      store: trainedStore(),
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    Color background() =>
        tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor!;
    expect(background(), Palette.light.bg);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();

    // Still on Settings, now drawn from the dark palette.
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(Paper.isDark, isTrue);
    expect(background(), Palette.dark.bg);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(background(), Palette.light.bg);
  });

  testWidgets('a group chat is marked on home, and its members counted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 9000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final stats = ChatStats.from(
      WhatsAppParser.parse(
        '02/03/2026, 19:00 - Sam: friday?\n'
        '02/03/2026, 19:01 - Priya: me!!\n'
        '02/03/2026, 19:02 - Robin: yes\n'
        '02/03/2026, 19:03 - Alex: cant',
      ),
      myName: 'Robin',
    );
    await pumpApp(
      tester,
      apiKey: 'sk-test-0123456789abcdefghij',
      store: FakeStore(
        chats: [
          exampleChat(
            them: 'Friday crew',
          ).copyWith(isGroup: true, stats: stats),
        ],
        rows: [exampleExchange()],
      ),
    );
    expect(find.byIcon(Icons.groups_rounded), findsOneWidget);

    await tester.tap(find.text('Chat data'));
    await tester.pumpAndSettle();
    expect(find.text('Who talks most'), findsOneWidget);
    for (final name in ['You', 'Sam', 'Priya', 'Alex']) {
      expect(find.text(name), findsWidgets);
    }
  });
}
