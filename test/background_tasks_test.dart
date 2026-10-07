import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:replylikeme/models/ai_provider.dart';
import 'package:replylikeme/screens/analysis_screen.dart';
import 'package:replylikeme/services/chat_facts.dart';
import 'package:replylikeme/services/memory_exchange_store.dart';
import 'package:replylikeme/services/openai_exception.dart';
import 'package:replylikeme/services/openai_service.dart';
import 'package:replylikeme/state/providers.dart';
import 'package:replylikeme/state/tasks.dart';
import 'package:replylikeme/widgets/task_tray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'explore_features_test.dart' show chat, exchange, turn;

class _Key extends ApiKeysNotifier {
  @override
  Future<ApiKeys> build() async => const ApiKeys().withKey(
    AiProvider.openai,
    'sk-test-0123456789abcdefghij',
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('TaskCenter', () {
    late ProviderContainer container;
    late TaskCenter center;
    setUp(() {
      container = ProviderContainer();
      center = container.read(taskCenterProvider.notifier);
    });
    tearDown(() => container.dispose());

    List<BackgroundTask> tasks() => container.read(taskCenterProvider);

    testWidgets('runs a job, reports progress, keeps its result, then '
        'clears', (tester) async {
      final gate = Completer<void>();
      center.start(
        id: 'a',
        title: 'Job',
        work: (task) async {
          task.report(detail: 'half', progress: 0.5);
          await gate.future;
          return 42;
        },
      );
      await tester.pump();
      var t = tasks().single;
      expect((t.detail, t.progress, t.running), ('half', 0.5, true));

      // Starting it again while it runs does nothing.
      center.start(id: 'a', title: 'Again', work: (_) async => 0);
      expect(tasks().single.title, 'Job');

      gate.complete();
      await tester.pump();
      t = tasks().single;
      expect((t.status, t.result), (TaskStatus.done, 42));

      await tester.pump(TaskCenter.doneShownFor);
      expect(tasks(), isEmpty);
    });

    testWidgets('Stop ends a job at its next step and keeps nothing', (
      tester,
    ) async {
      final gate = Completer<void>();
      var saved = false;
      center.start(
        id: 'a',
        title: 'Job',
        work: (task) async {
          await gate.future;
          task.check();
          saved = true;
          return null;
        },
      );
      await tester.pump();
      center.cancel('a');
      expect(tasks(), isEmpty);
      gate.complete();
      await tester.pump();
      expect(saved, isFalse);
      expect(tasks(), isEmpty);
    });

    testWidgets('a failure stays until dismissed', (tester) async {
      center.start(
        id: 'a',
        title: 'Job',
        work: (_) async => throw StateError('boom'),
      );
      await tester.pump(const Duration(minutes: 1));
      final t = tasks().single;
      expect(t.status, TaskStatus.failed);
      expect(t.error, isA<StateError>());
      center.dismiss('a');
      expect(tasks(), isEmpty);
    });
  });

  group('requests sent away mid-flight', () {
    OpenAiService service({
      required int Function() interruptions,
      required Future<void> Function() whenActive,
      required List<int> calls,
    }) => OpenAiService(
      apiKey: 'sk-test-0123456789abcdefghij',
      maxRetries: 0,
      interruptions: interruptions,
      whenActive: whenActive,
      client: MockClient((request) async {
        calls.add(1);
        if (calls.length == 1) {
          throw http.ClientException('Connection closed while receiving');
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'hey'},
              },
            ],
          }),
          200,
        );
      }),
    );

    test('wait for the app to come back, then try again', () async {
      var interruptions = 0;
      final back = Completer<void>();
      final calls = <int>[];
      final openai = service(
        interruptions: () => interruptions,
        whenActive: () => back.future,
        calls: calls,
      );
      final reply = openai.chat(
        model: 'm',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      // The screen turns off while the request is out.
      interruptions++;
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(1));
      back.complete();
      expect(await reply, 'hey');
      expect(calls, hasLength(2), reason: 'retried, though no retries allowed');
    });

    test('still fail when the app never left', () async {
      final calls = <int>[];
      final openai = service(
        interruptions: () => 0,
        whenActive: () async {},
        calls: calls,
      );
      await expectLater(
        openai.chat(
          model: 'm',
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
        ),
        throwsA(isA<OpenAiException>()),
      );
      expect(calls, hasLength(1));
    });
  });

  testWidgets('Remember keeps going after its screen is left, and can be '
      'stopped from the tray', (tester) async {
    tester.view.physicalSize = const Size(1200, 7000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final gate = Completer<void>();
    final store = MemoryExchangeStore(
      chats: [chat()],
      rows: [
        exchange(context: [turn('Maya', 'my dog Biscuit is ill')]),
      ],
    );
    final openai = OpenAiService(
      apiKey: 'sk-test-0123456789abcdefghij',
      maxRetries: 0,
      client: MockClient((request) async {
        await gate.future;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content':
                      '{"facts": [{"text": "Has a dog called Biscuit", '
                      '"category": "People & pets"}]}',
                },
              },
            ],
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiKeysProvider.overrideWith(_Key.new),
          exchangeStoreProvider.overrideWithValue(store),
          openAiServiceProvider.overrideWithValue(openai),
        ],
        child: MaterialApp(
          builder: (context, child) => TaskTrayFrame(child: child!),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AnalysisScreen(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Analyse the chat'));
    await tester.pump();
    await tester.pump();

    // On the screen: the job, a note that it's safe to leave, and Stop.
    expect(find.byKey(const ValueKey('background-job')), findsOneWidget);
    expect(find.textContaining('You can leave this screen'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-tray')), findsOneWidget);

    // Leave. The job carries on, in the tray.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AnalysisScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(find.text('Analysing Maya'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-stop-analysis-1')), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final saved = await const FactsStore().forChat(1);
    expect(saved!.facts.single.text, 'Has a dog called Biscuit');
    expect(find.text('Done'), findsOneWidget);
    await tester.pump(TaskCenter.doneShownFor);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('task-tray')), findsNothing);
  });
}
