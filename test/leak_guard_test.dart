import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:replylikeme/models/chat_turn.dart';
import 'package:replylikeme/models/stored_exchange.dart';
import 'package:replylikeme/services/leak_guard.dart';

ChatTurn turn(String sender, String text) =>
    ChatTurn(sender: sender, text: text, messageCount: 1);

StoredExchange exchange(List<ChatTurn> context, String reply) =>
    StoredExchange(
      id: 1,
      context: context,
      contextText: '',
      replyText: reply,
      vector: Float32List(2),
    );

void main() {
  group('risky', () {
    test('names and numbers only the examples had are risky', () {
      final risky = LeakGuard.risky(
        [
          exchange([
            turn('Maya', 'dinner with Josh at 8?'),
          ], 'is Josh coming, we loved Lisbon'),
        ],
        [turn('Maya', 'what are you up to')],
        names: {'Robin', 'Maya'},
      );
      expect(risky, containsAll(['josh', '8', 'lisbon']));
      // Plain words, and a capital that only starts a sentence, are not.
      expect(risky, isNot(contains('dinner')));
      expect(risky, isNot(contains('is')));
    });

    test('a capital after a full stop starts a sentence', () {
      final risky = LeakGuard.risky([
        exchange([turn('Maya', 'ok. Sounds good')], 'Fine! See you'),
      ], const []);
      expect(risky, isEmpty);
    });

    test('times count as numbers', () {
      final risky = LeakGuard.risky([
        exchange([turn('Maya', 'is it 7:30 or 9pm')], 'ok'),
      ], const []);
      expect(risky, containsAll(['7:30', '9pm']));
    });

    test('words the live chat already has are fine', () {
      final risky = LeakGuard.risky(
        [
          exchange([turn('Maya', 'see Josh later')], 'ok'),
        ],
        [turn('Maya', 'josh says hi')],
      );
      expect(risky, isNot(contains('josh')));
    });

    test("the chat's own names are fine", () {
      final risky = LeakGuard.risky(
        [
          exchange([turn('Maya', 'ask Robin')], 'tell Maya'),
        ],
        const [],
        names: {'Robin', 'Maya'},
      );
      expect(risky, isEmpty);
    });

    test("I and I'm are never risky", () {
      final risky = LeakGuard.risky([
        exchange(const [], "ok I'm in, and I said so"),
      ], const []);
      expect(risky, isEmpty);
    });
  });

  group('leaks', () {
    test('on a whole-word match, in any case', () {
      expect(LeakGuard.leaks('tell josh hi', {'josh'}), isTrue);
      expect(LeakGuard.leaks('Tell JOSH hi', {'josh'}), isTrue);
      expect(LeakGuard.leaks('joshua is here', {'josh'}), isFalse);
      expect(LeakGuard.leaks('at 8 then', {'8'}), isTrue);
      expect(LeakGuard.leaks('at 18 then', {'8'}), isFalse);
      expect(LeakGuard.leaks('7:30 works', {'7:30'}), isTrue);
    });

    test('never with nothing risky', () {
      expect(LeakGuard.leaks('anything at all', const {}), isFalse);
    });
  });
}
