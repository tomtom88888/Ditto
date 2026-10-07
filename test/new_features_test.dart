import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replylikeme/models/ai_provider.dart';
import 'package:replylikeme/models/app_settings.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/models/style_profile.dart';
import 'package:replylikeme/screens/ask_screen.dart';
import 'package:replylikeme/screens/check_screen.dart';
import 'package:replylikeme/screens/openers_screen.dart';
import 'package:replylikeme/screens/graph_screen.dart';
import 'package:replylikeme/services/ask_chats.dart';
import 'package:replylikeme/services/chat_search.dart';
import 'package:replylikeme/services/chart_maker.dart';
import 'package:replylikeme/services/memory_exchange_store.dart';
import 'package:replylikeme/services/message_check.dart';
import 'package:replylikeme/services/openai_service.dart';
import 'package:replylikeme/services/reply_generator.dart';
import 'package:replylikeme/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'explore_features_test.dart' show chat, exchange, fake, turn;

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

/// Robin's habits: short, lowercase, no full stops, no emoji, one bubble.
final StyleProfile robin = StyleProfile.measureTexts([
  for (var i = 0; i < 30; i++) i.isEven ? 'yeah sounds good' : 'haha ok',
]);

/// A month of chat in which Maya answers within [reply] minutes, writing
/// [words] words, and starts [starts] of the [days] conversations.
List<StoredExchange> month(
  int year,
  int monthNumber, {
  required int days,
  required int reply,
  int words = 4,
  int starts = 0,
}) => [
  for (var d = 1; d <= days; d++)
    () {
      final at = DateTime(year, monthNumber, d, 20);
      final mayaFirst = d <= starts;
      final mayaAt = mayaFirst ? at : at.add(const Duration(minutes: 1));
      return exchange(
        id: year * 1000 + monthNumber * 40 + d,
        context: [
          if (!mayaFirst) turn('Robin', 'hey', at),
          turn('Maya', List.filled(words, 'word').join(' '), mayaAt),
        ],
        reply: 'nice',
        at: mayaAt.add(Duration(minutes: reply)),
      );
    }(),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('ChartMaker', () {
    test('reads a spec, keeping one axis and at most three series', () {
      final spec = ChartSpec.parse(
        '{"title": "Messages", "kind": "line", "x": "month", "series": ['
        '{"label": "You", "who": "me", "measure": "messages"}, '
        '{"label": "Maya", "who": "them", "measure": "messages"}, '
        '{"label": "Words", "who": "both", "measure": "words"}]}',
      );
      expect(spec.kind, ChartKind.line);
      expect(spec.axis, ChartAxis.month);
      expect(spec.series.map((s) => s.label), ['You', 'Maya']);
      expect(spec.note, contains('one chart'));
    });

    test('a request that cannot be charted says why', () {
      expect(
        () => ChartSpec.parse('{"error": "I can only count messages."}'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            'I can only count messages.',
          ),
        ),
      );
    });

    test('counts each side per month, on the phone', () {
      const spec = ChartSpec(
        title: 't',
        kind: ChartKind.bar,
        axis: ChartAxis.month,
        series: [
          ChartSeries(
            label: 'You',
            who: ChartWho.me,
            measure: ChartMeasure.messages,
          ),
          ChartSeries(
            label: 'Maya',
            who: ChartWho.them,
            measure: ChartMeasure.messages,
          ),
        ],
      );
      final data = ChartMaker.count(spec, [
        ...month(2026, 1, days: 4, reply: 5),
        ...month(2026, 3, days: 2, reply: 5),
      ], myName: 'Robin');
      expect(data.labels, ['Jan 26', 'Feb 26', 'Mar 26']);
      // Each day: Robin's "hey" and reply, and one line from Maya.
      expect(data.values[0], [8, 0, 4]);
      expect(data.values[1], [4, 0, 2]);
    });

    test('reply times, who starts, and words they use', () {
      ChartData count(
        ChartMeasure m,
        ChartWho who, [
        List<String> terms = const [],
      ]) => ChartMaker.count(
        ChartSpec(
          title: 't',
          kind: ChartKind.bar,
          axis: ChartAxis.total,
          series: [ChartSeries(label: 'x', who: who, measure: m, terms: terms)],
        ),
        month(2026, 1, days: 6, reply: 5, starts: 2),
        myName: 'Robin',
      );
      expect(count(ChartMeasure.replyMinutes, ChartWho.me).values[0], [5]);
      expect(count(ChartMeasure.started, ChartWho.them).values[0], [2]);
      expect(count(ChartMeasure.started, ChartWho.me).values[0], [4]);
      expect(count(ChartMeasure.contains, ChartWho.me, ['NICE']).values[0], [
        6,
      ]);
    });

    test('the description is all that is sent', () async {
      final sent = <Map<String, Object?>>[];
      final spec =
          await ChartMaker(
            openai: fake(
              sent: sent,
              answer: (_) =>
                  '{"title": "By hour", "kind": "bar", "x": "hour", '
                  '"series": [{"label": "Both", "who": "both", '
                  '"measure": "messages"}]}',
            ),
          ).design(
            'what time of day we text',
            model: 'gpt-5.6-terra',
            me: 'Robin',
            them: 'Maya',
          );
      expect(spec.axis, ChartAxis.hour);
      final messages = sent.single['messages']! as List;
      expect((messages.last as Map)['content'], 'what time of day we text');
      expect(messages, hasLength(2));
    });
  });

  group('MessageCheck', () {
    test('a message like yours passes', () {
      final c = MessageCheck.of('yeah sounds good', robin);
      expect(c.verdict, CheckVerdict.likeYou);
      expect(c.quickFix, isNull);
    });

    test('flags what is unlike you, and fixes the clear-cut parts free', () {
      final c = MessageCheck.of(
        'Hey! I was wondering if you would like to come to dinner on '
        'Friday evening with me and some friends from work. 😊',
        robin,
      );
      expect(c.verdict, CheckVerdict.notYou);
      final text = c.findings.map((f) => f.text).join(' ');
      expect(text, contains('Long for you'));
      expect(text, contains('emoji'));
      expect(c.quickFix, isNot(contains('😊')));
    });

    test('too few replies measured: says so instead of guessing', () {
      final c = MessageCheck.of('Hello.', StyleProfile.measureTexts(['hi']));
      expect(c.verdict, CheckVerdict.unknown);
      expect(c.findings.single.text, contains('Too few'));
    });
  });

  group('AskChats', () {
    test(
      'the closest moments go in numbered, and citations map back',
      () async {
        final sent = <Map<String, Object?>>[];
        final store = MemoryExchangeStore(
          chats: [chat()],
          rows: [
            exchange(
              id: 1,
              vector: [1, 0],
              context: [turn('Maya', 'we should move to Lisbon')],
              reply: 'honestly yes',
              at: DateTime(2026, 3, 2),
            ),
            exchange(
              id: 2,
              vector: [0, 1],
              reply: 'lol',
              at: DateTime(2026, 1, 1),
            ),
          ],
        );
        final openai = fake(
          sent: sent,
          embed: (_) => [1, 0],
          answer: (_) => 'In March, Maya suggested Lisbon [2].',
        );
        final answer =
            await AskChats(
              openai: openai,
              search: ChatSearch(openai: openai, store: store),
            ).ask(
              'when did we talk about moving?',
              chatIds: {1},
              chatNames: {1: 'Maya'},
              myName: 'Robin',
              model: 'gpt-5.6-terra',
              embeddingModel: 'text-embedding-3-small',
              dimensions: 2,
            );
        // Oldest first: the January "lol" is [1], the Lisbon moment [2].
        expect(answer.cited.single.$1, 2);
        expect(answer.cited.single.$2.exchange.id, 1);
        final prompt =
            ((sent.last['messages']! as List).last as Map)['content'] as String;
        expect(prompt, contains('[2] 2026-03-02 · chat with Maya'));
        expect(prompt, contains('Me: honestly yes'));
        expect(prompt, endsWith('Question: when did we talk about moving?'));
      },
    );

    test('citations out of range or repeated are ignored', () {
      final hit = SearchHit(
        exchange: exchange(id: 1),
        score: 1,
        wordMatch: false,
      );
      final a = AskAnswer(text: 'x [1] y [1][7]', moments: [hit]);
      expect(a.cited.map((c) => c.$1), [1]);
    });
  });

  group('ReplyGenerator', () {
    test(
      'openers: no message to answer, the end of the chat as background',
      () async {
        final sent = <Map<String, Object?>>[];
        final generator = ReplyGenerator(
          openai: fake(sent: sent, answer: (_) => 'how did the exam go'),
        );
        final out = await generator.openers(
          settings: const AppSettings(myName: 'Robin', theirName: 'Maya'),
          recent: [turn('Maya', 'exam on friday, wish me luck')],
          profile: robin,
          facts: const ['Has an exam on Friday'],
          quietFor: '5 days',
        );
        expect(out, contains('how did the exam go'));
        final system =
            ((sent.last['messages']! as List).first as Map)['content']
                as String;
        expect(system, contains('gone quiet for 5 days'));
        expect(system, contains('exam on friday, wish me luck'));
        expect(system, contains('Has an exam on Friday'));
      },
    );

    test('rewriteMine sends your message and keeps what it says', () async {
      final sent = <Map<String, Object?>>[];
      final generator = ReplyGenerator(
        openai: fake(sent: sent, answer: (_) => 'Running late, sorry.'),
      );
      final out = await generator.rewriteMine(
        draft: 'I am running late, I apologise.',
        settings: const AppSettings(myName: 'Robin', theirName: 'Maya'),
        profile: robin,
      );
      // Your habits are applied to the result: no capital, no full stop.
      expect(out, contains('running late, sorry'));
      final messages = sent.last['messages']! as List;
      expect(
        (messages.last as Map)['content'],
        'I am running late, I apologise.',
      );
      expect(
        (messages.first as Map)['content'],
        contains('says the same thing'),
      );
    });
  });

  group('screens', () {
    Future<void> pump(
      WidgetTester tester,
      Widget screen,
      MemoryExchangeStore store,
      OpenAiService openai,
    ) async {
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

    MemoryExchangeStore store() => MemoryExchangeStore(
      chats: [chat().copyWith(profile: robin)],
      rows: month(2026, 1, days: 6, reply: 5),
    );

    testWidgets('ask shows the answer and the moments it cites', (
      tester,
    ) async {
      await pump(
        tester,
        const AskScreen(),
        store(),
        fake(embed: (_) => [1, 0], answer: (_) => 'Every evening [1].'),
      );
      await tester.enterText(find.byKey(const ValueKey('ask-field')), 'when?');
      await tester.tap(find.byTooltip('Ask'));
      await tester.pumpAndSettle();
      expect(find.text('Every evening [1].'), findsOneWidget);
      expect(find.byKey(const ValueKey('cited-1')), findsOneWidget);
    });

    testWidgets('openers are written and shown as your bubbles', (
      tester,
    ) async {
      await pump(
        tester,
        const OpenersScreen(),
        store(),
        fake(answer: (_) => 'how was the weekend'),
      );
      await tester.tap(find.byKey(const ValueKey('suggest-openers')));
      await tester.pumpAndSettle();
      expect(find.text('how was the weekend'), findsOneWidget);
    });

    testWidgets('the check updates as you type, free', (tester) async {
      final sent = <Map<String, Object?>>[];
      await pump(
        tester,
        const CheckScreen(),
        store(),
        fake(sent: sent, answer: (_) => 'x'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('check-field')),
        'Hello there.',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('check-verdict')), findsOneWidget);
      expect(find.text('Quick fix · free'), findsOneWidget);
      expect(sent, isEmpty);
    });

    testWidgets('a described graph is drawn from the phone\'s counts', (
      tester,
    ) async {
      await pump(
        tester,
        const GraphScreen(),
        store(),
        fake(
          answer: (_) =>
              '{"title": "Messages per month", "kind": "bar", "x": "month", '
              '"series": [{"label": "You", "who": "me", "measure": '
              '"messages"}, {"label": "Maya", "who": "them", "measure": '
              '"messages"}]}',
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('graph-field')),
        'messages per month, me vs her',
      );
      await tester.tap(find.byTooltip('Make it'));
      await tester.pumpAndSettle();
      expect(find.text('Messages per month'), findsOneWidget);
      expect(find.byKey(const ValueKey('chart')), findsOneWidget);
      expect(find.text('Jan 26 · You 12 · Maya 6'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chart-table')));
      await tester.pumpAndSettle();
      expect(find.text('Show the chart'), findsOneWidget);
    });
  });
}
