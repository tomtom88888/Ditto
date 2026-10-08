import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replylikeme/models/ai_provider.dart';
import 'package:replylikeme/models/app_settings.dart';
import 'package:replylikeme/screens/analysis_screen.dart';
import 'package:replylikeme/screens/check_screen.dart';
import 'package:replylikeme/services/chat_analysis.dart';
import 'package:replylikeme/services/memory_exchange_store.dart';
import 'package:replylikeme/services/openai_service.dart';
import 'package:replylikeme/services/reply_generator.dart';
import 'package:replylikeme/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'explore_features_test.dart' show chat, exchange, fake, turn;
import 'new_features_test.dart' show robin;

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

const String _analysisJson =
    '{"writing": ["Mostly two or three words, all lowercase", '
    '"Says \\"yalla\\" to wrap things up"], '
    '"you": ["Starts most conversations"], '
    '"them": ["Answers fast and asks questions back"], '
    '"together": ["Bond over food"]}';

/// Answers the analysis request with [_analysisJson] and anything else with
/// an empty fact list.
String _answer(Map<String, Object?> body) {
  final system =
      ((body['messages']! as List).first as Map)['content'] as String;
  return system.contains('You study how')
      ? _analysisJson
      : '{"facts": [{"text": "Loves ramen", "category": "Likes"}]}';
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('ChatAnalyst', () {
    test('reads a sample spread over the whole chat, with the numbers', () {
      final rows = [
        for (var i = 0; i < 400; i++)
          exchange(
            id: i,
            context: [turn('Maya', 'm$i')],
            reply: 'r$i',
            at: DateTime(2026, 1, 1).add(Duration(hours: i)),
          ),
      ];
      final picked = ChatAnalyst.sample(rows);
      expect(picked, hasLength(ChatAnalyst.sampleSize));
      expect(picked.first.replyText, 'r0');
      expect(picked.last.replyText, 'r399');
      final prompt = ChatAnalyst.userPrompt(
        rows,
        myName: 'Robin',
        profile: robin,
      );
      expect(prompt, startsWith('Measured from'));
      expect(prompt, contains('Maya: m0\nMe: r0'));
    });

    test('parses the four parts, and survives a bad answer', () {
      final a = ChatAnalyst.parse(_analysisJson);
      expect(a.writing, hasLength(2));
      expect(a.you.single, 'Starts most conversations');
      expect(ChatAnalyst.parse('nope').isEmpty, isTrue);
      final lines = ChatAnalysis.fromJson({'writing': '- one\n• two\n\n'})!;
      expect(lines.writing, ['one', 'two']);
    });

    test('asks how you act as well as how you write', () {
      final prompt = ChatAnalyst.systemPrompt(me: 'Robin', them: 'Maya');
      expect(prompt, contains('"acting"'));
      expect(prompt, contains('how keen or unbothered'));
      final a = ChatAnalysis.fromJson({
        'acting': ['Rarely asks back'],
        'you': ['Starts most conversations'],
      })!;
      expect(a.actingGuide, ['Rarely asks back']);
      // An older analysis, with no "acting", falls back to its observations.
      final old = ChatAnalysis.fromJson({
        'you': ['Starts most conversations'],
      })!;
      expect(old.actingGuide, ['Starts most conversations']);
      expect(ChatAnalysis.fromJson(a.toJson())!.acting, ['Rarely asks back']);
    });
  });

  group('the style guide', () {
    test('goes into every reply prompt', () {
      final prompt = ReplyGenerator.buildSystemPrompt(
        const AppSettings(myName: 'Robin', theirName: 'Maya'),
        styleGuide: const ['Mostly two or three words, all lowercase'],
      );
      expect(prompt, contains('How Robin writes to Maya'));
      expect(prompt, contains('- Mostly two or three words, all lowercase'));
    });

    test('and into the judgement of your own message', () async {
      final sent = <Map<String, Object?>>[];
      final verdict =
          await ReplyGenerator(
            openai: fake(
              sent: sent,
              answer: (_) =>
                  '{"score": 3, "verdict": "Too formal", '
                  '"notes": ["\\"I apologise\\" is not you"]}',
            ),
          ).judgeMine(
            draft: 'I apologise for the delay.',
            settings: const AppSettings(myName: 'Robin', theirName: 'Maya'),
            profile: robin,
            voiceSample: const ['haha ok'],
            styleGuide: const ['Never apologises formally'],
          );
      expect(verdict.score, 3);
      expect(verdict.notes.single, contains('apologise'));
      final system =
          ((sent.single['messages']! as List).first as Map)['content']
              as String;
      expect(system, contains('- Never apologises formally'));
      expect(system, contains('Measured from'));
      expect(system, contains('- haha ok'));
    });
  });

  group('screens', () {
    Future<MemoryExchangeStore> pump(
      WidgetTester tester,
      Widget screen,
      OpenAiService openai,
    ) async {
      tester.view.physicalSize = const Size(1200, 9000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final store = MemoryExchangeStore(
        chats: [chat().copyWith(profile: robin)],
        rows: [
          exchange(context: [turn('Maya', 'ramen tonight?')], reply: 'yalla'),
        ],
      );
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
      return store;
    }

    testWidgets('analysis shows how you write, how you act, and facts', (
      tester,
    ) async {
      await pump(tester, const AnalysisScreen(), fake(answer: _answer));
      await tester.tap(find.byKey(const ValueKey('analyse')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('how-you-write')), findsOneWidget);
      expect(
        find.text('Mostly two or three words, all lowercase'),
        findsOneWidget,
      );
      expect(find.text('How you act'), findsOneWidget);
      expect(find.text('How \u2068Maya\u2069 acts'), findsOneWidget);
      expect(find.text('Between you'), findsOneWidget);
      expect(find.text('Loves ramen'), findsOneWidget);
      final saved = await const AnalysisStore().forChat(1);
      expect(saved!.writing, hasLength(2));
    });

    testWidgets('is it like me uses the saved guide', (tester) async {
      await const AnalysisStore().save(
        1,
        ChatAnalysis(
          at: DateTime(2026, 10, 1),
          writing: const ['Never apologises formally'],
        ),
      );
      final sent = <Map<String, Object?>>[];
      await pump(
        tester,
        const CheckScreen(),
        fake(
          sent: sent,
          answer: (_) => '{"score": 9, "verdict": "That\'s you", "notes": []}',
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('check-field')),
        'yalla',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('judge')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('judgement')), findsOneWidget);
      expect(find.text("That's you"), findsOneWidget);
      expect(jsonEncode(sent.last), contains('Never apologises formally'));
    });
  });
}
