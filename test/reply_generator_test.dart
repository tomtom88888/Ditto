import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:replylikeme/models/app_settings.dart';
import 'package:replylikeme/models/chat_turn.dart';
import 'package:replylikeme/models/extracted_message.dart';
import 'package:replylikeme/models/reply_suggestion.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/models/style_profile.dart';
import 'package:replylikeme/services/openai_exception.dart';
import 'package:replylikeme/services/openai_service.dart';
import 'package:replylikeme/services/reply_generator.dart';
import 'package:replylikeme/services/style_conformer.dart';

ChatTurn turn(String sender, String text) =>
    ChatTurn(sender: sender, text: text, messageCount: 1);

ScoredExchange example(String context, String reply, double similarity) =>
    ScoredExchange(
      similarity: similarity,
      exchange: StoredExchange(
        id: 1,
        context: [turn('Sam', context)],
        contextText: 'Sam: $context',
        replyText: reply,
        vector: Float32List(2),
      ),
    );

void main() {
  const settings = AppSettings(myName: 'Robin', theirName: 'Sam');

  group('turnsFrom', () {
    test('merges consecutive messages from one side, as training did', () {
      final turns = ReplyGenerator.turnsFrom(
        const [
          ExtractedMessage(speaker: Speaker.them, text: 'yo'),
          ExtractedMessage(speaker: Speaker.them, text: 'you up?'),
          ExtractedMessage(speaker: Speaker.me, text: 'barely'),
          ExtractedMessage(speaker: Speaker.them, text: 'lol'),
        ],
        myName: 'Robin',
        theirName: 'Sam',
      );

      expect(turns, hasLength(3));
      expect(turns.first.sender, 'Sam');
      expect(turns.first.text, 'yo\nyou up?');
      expect(turns.first.messageCount, 2);
      expect(turns[1].sender, 'Robin');
    });

    test('skips blank bubbles', () {
      final turns = ReplyGenerator.turnsFrom(
        const [
          ExtractedMessage(speaker: Speaker.them, text: '   '),
          ExtractedMessage(speaker: Speaker.them, text: 'hi'),
        ],
        myName: 'Robin',
        theirName: 'Sam',
      );
      expect(turns.single.messageCount, 1);
    });
  });

  group('the editable system prompt', () {
    test('the default is a template, not finished text', () {
      expect(AppSettings.defaultSystemPrompt, contains('{me}'));
      expect(AppSettings.defaultSystemPrompt, contains('{them}'));
    });

    test('names are filled in when the prompt is built', () {
      final prompt = ReplyGenerator.buildSystemPrompt(settings);
      expect(prompt, contains('Robin'));
      expect(prompt, contains('Sam'));
      expect(prompt, isNot(contains('{me}')));
      expect(prompt, isNot(contains('{them}')));
    });

    test('an edited prompt replaces the default', () {
      final prompt = ReplyGenerator.buildSystemPrompt(
        settings.copyWith(systemPrompt: 'Answer as {me}. Be terse.'),
      );
      expect(prompt, startsWith('Answer as Robin. Be terse.'));
      expect(prompt, isNot(contains('not an assistant')));
    });

    test('an empty edit falls back rather than sending no instructions', () {
      for (final empty in ['', '   ', '\n']) {
        final s = settings.copyWith(systemPrompt: empty);
        expect(s.effectiveSystemPrompt, AppSettings.defaultSystemPrompt);
        expect(s.hasCustomSystemPrompt, isFalse);
      }
    });

    test('an edit is recognised as one, and reset undoes it', () {
      final edited = settings.copyWith(systemPrompt: 'Be terse.');
      expect(edited.hasCustomSystemPrompt, isTrue);

      final reset = edited.copyWith(resetSystemPrompt: true);
      expect(reset.systemPrompt, isNull);
      expect(reset.hasCustomSystemPrompt, isFalse);
      expect(reset.effectiveSystemPrompt, AppSettings.defaultSystemPrompt);
    });

    test('re-saving the default text is not treated as an edit', () {
      final same = settings.copyWith(
        systemPrompt: AppSettings.defaultSystemPrompt,
      );
      expect(same.hasCustomSystemPrompt, isFalse);
    });

    test('an edited prompt survives being stored and read back', () {
      final edited = settings.copyWith(systemPrompt: 'Answer as {me}.');
      final restored = AppSettings.fromJson(edited.toJson());
      expect(restored.systemPrompt, 'Answer as {me}.');
      expect(restored.hasCustomSystemPrompt, isTrue);
    });

    test('the names still reach an edited prompt that uses the tokens', () {
      final prompt = ReplyGenerator.buildSystemPrompt(
        settings.copyWith(systemPrompt: '{me} is replying to {them}. {me}!'),
      );
      expect(prompt, startsWith('Robin is replying to Sam. Robin!'));
    });
  });

  group('the request', () {
    final examples = [
      example('drinks tonight?', 'go on then', 0.9),
      example('cinema?', 'nah skint', 0.6),
    ];

    List<Map<String, Object?>> build({
      String note = '',
      bool newTopic = false,
      StyleProfile profile = StyleProfile.empty,
      List<String> voiceSample = const [],
    }) => ReplyGenerator.buildMessages(
      conversation: [
        turn('Sam', 'pub?'),
        turn('Robin', 'maybe'),
        turn('Sam', 'go on'),
      ],
      examples: examples,
      settings: settings,
      note: note,
      newTopic: newTopic,
      profile: profile,
      voiceSample: voiceSample,
    );

    String system(List<Map<String, Object?>> m) =>
        m.first['content']! as String;

    test('puts your real replies in as reference moments, not turns', () {
      final m = build();
      // Only the live chat is a turn, so nothing from other chats can be
      // taken for part of this one.
      expect(m.map((x) => x['role']), ['system', 'user']);
      final text = system(m);
      expect(text, contains('not part of this conversation'));
      expect(text, contains('Never mention, continue, answer'));
      // Least similar first, so the closest match comes last.
      final cinema = text.indexOf('Them: cinema?\nMe: nah skint');
      final drinks = text.indexOf('Them: drinks tonight?\nMe: go on then');
      expect(cinema, greaterThan(0));
      expect(drinks, greaterThan(cinema));
    });

    test('asks for how you act, not only how you write', () {
      final text = system(build());
      expect(text, contains('Act like you too'));
      final withActing = ReplyGenerator.buildSystemPrompt(
        settings,
        acting: const ['Rarely asks back'],
      );
      expect(withActing, contains('How Robin acts with Sam'));
      expect(withActing, contains('- Rarely asks back'));
    });

    test('ends with the live chat, your earlier lines marked', () {
      expect(build().last['content'], 'pub?\n(you) maybe\ngo on');
    });

    test('keeps only the most recent context turns of the live chat', () {
      final m = ReplyGenerator.buildMessages(
        conversation: [
          for (var i = 0; i < 20; i++) turn(i.isEven ? 'Sam' : 'Robin', 'm$i'),
          turn('Sam', 'last'),
        ],
        examples: const [],
        settings: settings.copyWith(contextTurns: 3),
      );
      expect((m.last['content']! as String).split('\n'), [
        'm18',
        '(you) m19',
        'last',
      ]);
      // The rest is background in the system prompt, not dropped.
      final background = system(m);
      expect(background, contains('Earlier in this same conversation'));
      expect(background, contains('m0\n(you) m1\nm2'));
      expect(background, contains('(you) m17'));
      expect(background, isNot(contains('m18')));
    });

    test('a short chat has no earlier background', () {
      expect(system(build()), isNot(contains('Earlier in this same')));
    });

    test('long background keeps its newest lines', () {
      final m = ReplyGenerator.buildMessages(
        conversation: [
          for (var i = 0; i < 400; i++) turn('Sam', 'message number $i'),
          turn('Sam', 'last'),
        ],
        examples: const [],
        settings: settings.copyWith(contextTurns: 1),
      );
      final text = system(m);
      expect(text, contains('message number 399'));
      expect(text, isNot(contains('message number 0\n')));
      expect(text, contains('…'));
    });

    test('tells the model it is you, not an assistant', () {
      final text = system(build());
      expect(text, contains('You are Robin'));
      expect(text, contains('not an assistant'));
      expect(text, contains('Reply to that conversation only'));
      expect(text, isNot(contains('{me}')));
    });

    test('carries the note, and keeps it out of the chat itself', () {
      final m = build(note: "say I'll be late");
      expect(system(m), contains("Robin wants it to: say I'll be late"));
      expect(m.last['content'], isNot(contains('late')));
    });

    test('asks for a change of subject only when told to', () {
      expect(system(build()), isNot(contains('do not answer')));
      expect(
        system(build(newTopic: true)),
        contains('do not answer what Sam just said'),
      );
    });

    test('includes the measured habits and bubble guidance', () {
      final profile = StyleProfile.measure([
        for (var i = 0; i < 10; i++)
          const ChatTurn(sender: 'Robin', text: 'haha\nok', messageCount: 2),
      ], me: 'Robin');
      final text = system(build(profile: profile));
      expect(text, contains("Measured from 10 of Robin's real replies"));
      expect(text, contains('a line break means a separate bubble'));
    });

    test('includes a sample of real messages, one per line', () {
      final text = system(build(voiceSample: ['omw', 'haha\nyes']));
      expect(text, contains('- omw'));
      expect(text, contains('- haha / yes'));
    });

    test('says nothing about habits or samples when there are none', () {
      final text = system(build());
      expect(text, isNot(contains('Measured from')));
      expect(text, isNot(contains('really sent')));
    });
  });

  group('generate', () {
    const habitual = 'ok see you there';
    // Twenty lowercase, full-stop-free, emoji-free replies of about 4 words.
    final profile = StyleProfile.measureTexts([
      for (var i = 0; i < 20; i++) habitual,
    ]);

    OpenAiService serviceThat(
      List<String> Function(Map<String, Object?> body) answer, {
      List<Map<String, Object?>>? sent,
    }) => OpenAiService(
      apiKey: 'sk-test-0123456789abcdefghij',
      maxRetries: 0,
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        sent?.add(body);
        return http.Response(
          jsonEncode({
            'choices': [
              for (final text in answer(body))
                {
                  'message': {'content': text},
                },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    bool isTopic(Map<String, Object?> body) =>
        (((body['messages']! as List).first as Map)['content'] as String)
            .contains('do not answer');

    test('keeps the drafts most like you, then adds a topic change', () async {
      final sent = <Map<String, Object?>>[];
      final generator = ReplyGenerator(
        openai: serviceThat(
          (body) => isTopic(body)
              ? [
                  'anyway did u see the match',
                  'Anyway, how was your week at work?',
                ]
              : [
                  'Sounds great! I would absolutely love to come along tonight.',
                  'yeah go on',
                  'ok see u there',
                  'Sure.',
                ],
          sent: sent,
        ),
      );

      final variants = await generator.generate(
        conversation: [turn('Sam', 'pub?')],
        examples: [example('drinks?', 'go on then', 0.8)],
        settings: settings,
        profile: profile,
      );

      expect(variants.map((v) => v.kind), [
        SuggestionKind.reply,
        SuggestionKind.reply,
        SuggestionKind.newTopic,
      ]);
      // The long, polished draft is dropped; "Sure." loses its capital and
      // full stop but is a word short of the other two.
      expect(variants.map((v) => v.text), [
        'ok see u there',
        'yeah go on',
        'anyway did u see the match',
      ]);

      // Two requests: drafts for the answers, drafts for the topic change,
      // each asking for several choices at once and no JSON.
      expect(sent, hasLength(2));
      expect(sent.first['n'], 4);
      expect(sent.last['n'], 2);
      expect(sent.first.containsKey('response_format'), isFalse);
    });

    test('with one option asked for, there is no topic change', () async {
      final sent = <Map<String, Object?>>[];
      final generator = ReplyGenerator(
        openai: serviceThat((body) => ['yeah', 'yep'], sent: sent),
      );
      final variants = await generator.generate(
        conversation: [turn('Sam', 'pub?')],
        examples: const [],
        settings: settings.copyWith(variantCount: 1),
      );
      expect(variants.single.kind, SuggestionKind.reply);
      expect(sent, hasLength(1));
    });

    test('falls back to single requests when a model rejects n', () async {
      var calls = 0;
      final generator = ReplyGenerator(
        openai: OpenAiService(
          apiKey: 'sk-test-0123456789abcdefghij',
          maxRetries: 0,
          client: MockClient((request) async {
            calls++;
            final body = jsonDecode(request.body) as Map<String, Object?>;
            if (body.containsKey('n')) {
              return http.Response(
                jsonEncode({
                  'error': {
                    'message':
                        "Unsupported parameter: 'n' is not supported "
                        'with this model.',
                    'type': 'invalid_request_error',
                  },
                }),
                400,
              );
            }
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'draft $calls'},
                  },
                ],
              }),
              200,
            );
          }),
        ),
      );
      final variants = await generator.generate(
        conversation: [turn('Sam', 'pub?')],
        examples: const [],
        settings: settings.copyWith(variantCount: 2),
      );
      expect(variants, hasLength(2));
      // One rejected request, two single drafts; the topic change then goes
      // straight to single requests.
      expect(calls, 1 + 2 + 2);
    });

    test('refuses when the last message is yours', () async {
      final generator = ReplyGenerator(openai: serviceThat((_) => ['x']));
      await expectLater(
        generator.generate(
          conversation: [turn('Sam', 'pub?'), turn('Robin', 'yes')],
          examples: const [],
          settings: settings,
        ),
        throwsA(isA<OpenAiException>()),
      );
    });

    test('strips a speaker name or quotes the model wrote', () async {
      final generator = ReplyGenerator(
        openai: serviceThat((_) => ['Robin: yeah', '"yeah go on"']),
      );
      final variants = await generator.generate(
        conversation: [turn('Sam', 'pub?')],
        examples: const [],
        settings: settings.copyWith(variantCount: 1),
      );
      expect(variants.single.text, isIn(['yeah', 'yeah go on']));
    });
  });

  group('refine', () {
    test('sends the draft and the tweak, and keeps what it was for', () async {
      Map<String, Object?>? sent;
      final generator = ReplyGenerator(
        openai: OpenAiService(
          apiKey: 'sk-test-0123456789abcdefghij',
          maxRetries: 0,
          client: MockClient((request) async {
            sent = jsonDecode(request.body) as Map<String, Object?>;
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '"anyway, weekend?"'},
                  },
                ],
              }),
              200,
            );
          }),
        ),
      );

      final result = await generator.refine(
        suggestion: const ReplySuggestion(
          text: 'anyway, how are your plans for the weekend looking?',
          kind: SuggestionKind.newTopic,
        ),
        refinement: Refinement.shorter,
        conversation: [turn('Sam', 'pub?')],
        examples: const [],
        settings: settings,
      );

      expect(result.text, 'anyway, weekend?');
      expect(result.kind, SuggestionKind.newTopic);
      final system =
          ((sent!['messages']! as List).first as Map)['content'] as String;
      expect(system, contains('You had drafted this as your next message'));
      expect(system, contains('how are your plans for the weekend'));
      expect(system, contains('Make it shorter'));
      // A topic change is refined as a topic change.
      expect(system, contains('do not answer what Sam just said'));
    });
  });

  group('holding drafts to your habits', () {
    final lowercase = StyleProfile.measureTexts([
      for (var i = 0; i < 25; i++) 'ok see you there',
    ]);

    test('drops the capital, full stop and emoji you never use', () {
      expect(
        StyleConformer.conform('Sounds good. 😂\nSee you there.', lowercase),
        'sounds good\nsee you there',
      );
    });

    test('leaves "I" and acronyms their capitals', () {
      expect(StyleConformer.conform("I'm late", lowercase), "I'm late");
      expect(StyleConformer.conform('LOL same', lowercase), 'LOL same');
    });

    test('keeps what you do use', () {
      final punctual = StyleProfile.measureTexts([
        for (var i = 0; i < 25; i++) 'Sounds good. 😂',
      ]);
      expect(
        StyleConformer.conform('Sounds good. 😂', punctual),
        'Sounds good. 😂',
      );
    });

    test('changes nothing with too few replies to be sure', () {
      final few = StyleProfile.measureTexts(['ok', 'yes']);
      expect(StyleConformer.conform('Sounds good.', few), 'Sounds good.');
    });

    test('ranks drafts by how typical their length is', () {
      expect(
        StyleConformer.rank([
          'I would absolutely love to come along with you all tonight',
          'ok',
          'ok see u there',
        ], lowercase),
        [
          'ok see u there',
          'ok',
          'I would absolutely love to come along with you all tonight',
        ],
      );
    });
  });
}
