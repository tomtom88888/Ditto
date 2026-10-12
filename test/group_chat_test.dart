import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:replylikeme/models/app_settings.dart';
import 'package:replylikeme/models/chat_stats.dart';
import 'package:replylikeme/models/chat_turn.dart';
import 'package:replylikeme/models/extracted_message.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/services/chat_export_reader.dart';
import 'package:replylikeme/services/finetune_service.dart';
import 'package:replylikeme/services/memory_exchange_store.dart';
import 'package:replylikeme/services/openai_service.dart';
import 'package:replylikeme/services/pasted_conversation.dart';
import 'package:replylikeme/services/reply_generator.dart';
import 'package:replylikeme/services/style_memory_service.dart';
import 'package:replylikeme/services/whatsapp_parser.dart';

void main() {
  final chat = WhatsAppParser.parse(
    File('test/fixtures/group_export.txt').readAsStringSync(),
  );

  group('reading a group export', () {
    test('is recognised as a group of four', () {
      expect(chat.isGroup, isTrue);
      expect(chat.senders.toSet(), {'Sam', 'Priya', 'Robin', 'Alex'});
    });

    test('a one-to-one export is not a group', () {
      final pair = WhatsAppParser.parse(
        File('test/fixtures/android_export.txt').readAsStringSync(),
      );
      expect(pair.isGroup, isFalse);
    });

    test('the group name comes from the file name', () {
      expect(
        ChatExportReader.chatNameFromFilename(
          'WhatsApp Chat with Friday crew.txt',
        ),
        'Friday crew',
      );
      expect(
        ChatExportReader.chatNameFromFilename(
          'WhatsApp Chat - Friday crew.zip',
        ),
        'Friday crew',
      );
      expect(
        ChatExportReader.chatNameFromFilename(
          '/storage/Download/WhatsApp Chat with Family (1).txt',
        ),
        'Family',
      );
      expect(ChatExportReader.chatNameFromFilename('_chat.txt'), isNull);
      expect(ChatExportReader.chatNameFromFilename('export.txt'), isNull);
    });

    test('learns replies to anyone, with everyone named in the context', () {
      final exchanges = WhatsAppParser.buildExchanges(chat.turns, me: 'Robin');
      expect(exchanges.map((e) => e.replyText), [
        'yes obviously\nusual place?',
        'boo',
        '👍',
        'where is that',
      ]);
      // "boo" answers Alex, whose line is in the context under their name.
      expect(exchanges[1].contextText, endsWith("Alex: can't this week sorry"));
      expect(exchanges[3].contextText, contains('Priya: look what I found'));
    });

    test('counts each member', () {
      final stats = ChatStats.from(chat, myName: 'Robin');
      expect(stats.me.messages, 5);
      expect(stats.members, {'Priya': 3, 'Sam': 2, 'Alex': 2});
      final back = ChatStats.fromJson(stats.toJson());
      expect(back.members, stats.members);
    });
  });

  group('reading a group screenshot', () {
    test('keeps each sender name as the author, not the text', () {
      final messages = OpenAiService.parseExtractedConversation(
        jsonEncode({
          'messages': [
            {'sender': 'them', 'name': 'Sam', 'text': "who's in"},
            {'sender': 'them', 'name': 'Priya', 'text': 'Priya\nme!!'},
            {'sender': 'me', 'name': 'Robin', 'text': 'yes'},
          ],
        }),
      );
      expect(messages.map((m) => (m.author, m.text)), [
        ('Sam', "who's in"),
        ('Priya', 'me!!'),
        (null, 'yes'),
      ]);
    });

    test('a new member is a new turn, even with no reply between', () {
      final turns = ReplyGenerator.turnsFrom(
        const [
          ExtractedMessage(
            speaker: Speaker.them,
            text: 'friday?',
            author: 'Sam',
          ),
          ExtractedMessage(
            speaker: Speaker.them,
            text: 'me!!',
            author: 'Priya',
          ),
          ExtractedMessage(
            speaker: Speaker.them,
            text: 'where',
            author: 'Priya',
          ),
        ],
        myName: 'Robin',
        theirName: 'Friday crew',
      );
      expect(turns.map((t) => (t.sender, t.text)), [
        ('Sam', 'friday?'),
        ('Priya', 'me!!\nwhere'),
      ]);
    });

    test('pasted lines keep who said them', () {
      final messages = PastedConversation.parse(
        'Sam: friday?\nPriya: me!!\nme: yes',
        myName: 'Robin',
      );
      expect(messages.map((m) => m.author), ['Sam', 'Priya', null]);
    });
  });

  group('writing into a group', () {
    const settings = AppSettings(myName: 'Robin', theirName: 'Friday crew');
    final conversation = [
      const ChatTurn(sender: 'Sam', text: 'friday?', messageCount: 1),
      const ChatTurn(sender: 'Robin', text: 'maybe', messageCount: 1),
      const ChatTurn(sender: 'Priya', text: 'come on', messageCount: 1),
    ];

    test('names every member in the chat, and calls it a group', () {
      final messages = ReplyGenerator.buildMessages(
        conversation: conversation,
        examples: const [],
        settings: settings,
        group: true,
      );
      expect(
        messages.last['content'],
        'Sam: friday?\n(you) maybe\nPriya: come on',
      );
      final system = messages.first['content']! as String;
      expect(system, contains('texting the group chat "Friday crew"'));
      expect(system, contains('each line starting with who said it'));
      expect(system, contains('Several people are talking'));
    });

    test('a topic change is asked for in front of everyone', () {
      final system = ReplyGenerator.buildSystemPrompt(
        settings,
        group: true,
        newTopic: true,
      );
      expect(system, contains('do not answer what was just said'));
      expect(system, contains('in front of everyone'));
    });

    test('a one-to-one chat still hides the name on their lines', () {
      final messages = ReplyGenerator.buildMessages(
        conversation: conversation.take(2).toList(),
        examples: const [],
        settings: settings,
      );
      expect(messages.last['content'], 'friday?\n(you) maybe');
    });

    test('an example with several people in it is shown with names', () {
      final messages = ReplyGenerator.buildMessages(
        conversation: conversation.take(1).toList(),
        examples: [
          ScoredExchange(
            similarity: 0.9,
            exchange: StoredExchange(
              id: 1,
              context: const [
                ChatTurn(sender: 'Sam', text: 'pub?', messageCount: 1),
                ChatTurn(sender: 'Alex', text: 'yes', messageCount: 1),
              ],
              contextText: '',
              replyText: 'same',
              vector: Float32List(2),
            ),
          ),
        ],
        settings: settings,
      );
      expect(messages[1]['content'], 'Sam: pub?\nAlex: yes');
    });

    test('the fine-tuning dataset names members too', () {
      final jsonl = FineTuneService.buildJsonl(
        [
          StoredExchange(
            id: 1,
            chatId: 3,
            context: conversation.take(1).toList(),
            contextText: 'Sam: friday?',
            replyText: 'yes',
            vector: Float32List(2),
          ),
        ],
        myName: 'Robin',
        theirName: '',
        contextTurns: 10,
        chats: {
          3: ChatMemory(
            id: 3,
            myName: 'Robin',
            theirName: 'Friday crew',
            embeddingModel: 'e',
            dimensions: 2,
            builtAt: DateTime(2026),
            isGroup: true,
          ),
        },
      );
      final messages = (jsonDecode(jsonl.trim()) as Map)['messages'] as List;
      expect(
        (messages[0] as Map)['content'],
        contains('the group chat "Friday crew"'),
      );
      expect((messages[1] as Map)['content'], 'Sam: friday?');
    });
  });

  test('building a group chat remembers that it is one', () async {
    final store = MemoryExchangeStore();
    final service = StyleMemoryService(
      openai: OpenAiService(
        apiKey: 'sk-test-0123456789abcdefghij',
        maxRetries: 0,
        client: MockClient((request) async {
          final inputs = (jsonDecode(request.body) as Map)['input'] as List;
          return http.Response(
            jsonEncode({
              'data': [
                for (var i = 0; i < inputs.length; i++)
                  {
                    'index': i,
                    'embedding': [1, 0],
                  },
              ],
            }),
            200,
          );
        }),
      ),
      store: store,
    );
    final built = await service.build(
      exchanges: WhatsAppParser.buildExchanges(chat.turns, me: 'Robin'),
      myName: 'Robin',
      theirName: 'Friday crew',
      embeddingModel: 'text-embedding-3-small',
      dimensions: 2,
      isGroup: true,
    );
    expect(built.isGroup, isTrue);
    expect(built.exchangeCount, 4);
    expect((await store.chats()).single.theirName, 'Friday crew');
  });
}
