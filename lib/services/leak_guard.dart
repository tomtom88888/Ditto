import '../models/chat_turn.dart';
import '../models/stored_exchange.dart';

/// Spots drafts that bring in something only the retrieved examples had.
///
/// The examples are real moments from other times, put in as turns so the
/// model writes in your voice. The cost is that it may carry on from them:
/// a name, a place, a time that has nothing to do with the chat in front of
/// you. Words that could only have come from there are collected, and drafts
/// that use one are set aside.
///
/// What counts is deliberately narrow, so ordinary words never trip it:
/// capitalised words that don't start a sentence (names and places, for
/// people who capitalise them), and numbers and times.
class LeakGuard {
  const LeakGuard._();

  /// A time like 7:30, or a word: letters and digits, with apostrophes.
  static final RegExp _token = RegExp(
    r"\d{1,2}[:.]\d{2}(?:am|pm)?|[\p{L}\p{N}][\p{L}\p{N}'’]*",
    unicode: true,
    caseSensitive: false,
  );
  static final RegExp _number = RegExp(
    r'^\d+(?:[:.]\d{2})?(?:am|pm)?$',
    caseSensitive: false,
  );
  static final RegExp _sentenceEnd = RegExp(r'[.!?]\s*$');
  static final RegExp _pronoun = RegExp(r"^I(?:$|['’])");

  /// The words, lower case, that appear in [examples] but nowhere in the
  /// live [conversation], and could only have been taken from there.
  /// [names] — you and them — are never risky.
  static Set<String> risky(
    List<StoredExchange> examples,
    List<ChatTurn> conversation, {
    Set<String> names = const {},
  }) {
    final out = <String>{};
    void scan(String text) {
      for (final line in text.split('\n')) {
        var first = true;
        for (final m in _token.allMatches(line)) {
          final word = m[0]!;
          final startsSentence =
              first || _sentenceEnd.hasMatch(line.substring(0, m.start));
          first = false;
          if (_number.hasMatch(word)) {
            out.add(word.toLowerCase());
            continue;
          }
          if (startsSentence || _pronoun.hasMatch(word)) continue;
          if (word[0] != word[0].toLowerCase()) out.add(word.toLowerCase());
        }
      }
    }

    for (final e in examples) {
      for (final t in e.context) {
        scan(t.text);
      }
      scan(e.replyText);
    }
    if (out.isEmpty) return out;
    out.removeAll(_words(conversation.map((t) => t.text).join('\n')));
    out.removeAll(names.map((n) => n.toLowerCase()));
    return out;
  }

  /// Whether [draft] uses one of the [risky] words.
  static bool leaks(String draft, Set<String> risky) =>
      risky.isNotEmpty && _words(draft).any(risky.contains);

  static Iterable<String> _words(String text) =>
      _token.allMatches(text).map((m) => m[0]!.toLowerCase());
}
