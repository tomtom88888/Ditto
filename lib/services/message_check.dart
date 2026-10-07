import '../models/style_profile.dart';
import 'style_conformer.dart';

/// One thing noticed about a message you wrote.
class CheckFinding {
  const CheckFinding(this.text, {this.fine = false});

  final String text;

  /// Whether it is in line with how you usually write.
  final bool fine;
}

/// How close a message sits to how you usually write.
enum CheckVerdict { likeYou, close, notYou, unknown }

/// Compares a message you wrote with your habits in one chat, on the phone:
/// length, capitals, full stops, emoji, questions and bubbles. Free; only
/// rewriting it costs a call.
class MessageCheck {
  const MessageCheck({
    required this.verdict,
    required this.findings,
    required this.quickFix,
  });

  final CheckVerdict verdict;
  final List<CheckFinding> findings;

  /// The message with the clear-cut habits applied, or `null` if that
  /// changes nothing.
  final String? quickFix;

  static final RegExp _space = RegExp(r'\s+');
  static final RegExp _emoji = RegExp(
    r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]',
    unicode: true,
  );

  static MessageCheck of(String draft, StyleProfile profile) {
    final text = draft.trim();
    if (text.isEmpty) {
      return const MessageCheck(
        verdict: CheckVerdict.unknown,
        findings: [],
        quickFix: null,
      );
    }
    if (profile.turns < StyleConformer.minimumReplies) {
      return const MessageCheck(
        verdict: CheckVerdict.unknown,
        findings: [
          CheckFinding(
            'Too few of your replies in this chat to know your habits yet.',
          ),
        ],
        quickFix: null,
      );
    }

    final findings = <CheckFinding>[];
    final bubbles = text
        .split('\n')
        .map((b) => b.trim())
        .where((b) => b.isNotEmpty)
        .toList();
    final words = text.split(_space).where((w) => w.isNotEmpty).length;
    final median = profile.medianWords;
    final long = profile.longWords;

    if (words > long) {
      findings.add(
        CheckFinding(
          'Long for you: $words words. Half your messages are $median or '
          'fewer, and nine in ten are $long or fewer.',
        ),
      );
    } else if (words <= median * 2) {
      findings.add(const CheckFinding('A usual length for you.', fine: true));
    } else {
      findings.add(
        CheckFinding(
          'On the long side: $words words, where you usually write about '
          '$median.',
        ),
      );
    }

    final startsUpper = bubbles.any(_startsWithCapital);
    if (profile.lowercaseShare >= StyleConformer.usually && startsUpper) {
      findings.add(
        CheckFinding(
          'Starts with a capital; ${_pct(profile.lowercaseShare)} of your '
          'messages start lowercase.',
        ),
      );
    }

    final fullStop = bubbles.any((b) => b.endsWith('.') && !b.endsWith('..'));
    if (profile.fullStopShare <= StyleConformer.rarely && fullStop) {
      findings.add(
        CheckFinding(
          'Ends with a full stop, which you do in only '
          '${_pct(profile.fullStopShare)} of messages.',
        ),
      );
    }

    final hasEmoji = _emoji.hasMatch(text);
    if (hasEmoji && profile.emojiShare < StyleConformer.rarely) {
      findings.add(
        CheckFinding(
          'Has emoji; you use them in only ${_pct(profile.emojiShare)} of '
          'messages here.',
        ),
      );
    } else if (!hasEmoji && profile.emojiShare > 0.6) {
      final favourite = profile.topEmoji.isEmpty
          ? ''
          : ' (your favourite: ${profile.topEmoji.first.key})';
      findings.add(
        CheckFinding(
          'No emoji, though ${_pct(profile.emojiShare)} of your messages '
          'have one$favourite.',
        ),
      );
    }

    final questions = '?'.allMatches(text).length;
    if (questions >= 2) {
      findings.add(
        CheckFinding(
          '$questions questions at once. You ask one in '
          '${_pct(profile.questionShare)} of messages.',
        ),
      );
    }

    if (bubbles.length > 1 &&
        profile.multiBubbleShare < StyleConformer.rarely) {
      findings.add(
        const CheckFinding(
          'Split over several bubbles; you nearly always send one.',
        ),
      );
    } else if (bubbles.length == 1 &&
        profile.multiBubbleShare > 0.5 &&
        words > median) {
      findings.add(
        CheckFinding(
          'One long bubble; ${_pct(profile.multiBubbleShare)} of the time '
          'you split a message like this into several.',
        ),
      );
    }

    if (findings.every((f) => f.fine)) {
      findings.add(
        const CheckFinding(
          'Capitals, punctuation and emoji like yours.',
          fine: true,
        ),
      );
    }

    final distance = StyleConformer.distance(text, profile);
    final fixed = StyleConformer.conform(text, profile);
    return MessageCheck(
      verdict: distance <= 0.6 && findings.every((f) => f.fine)
          ? CheckVerdict.likeYou
          : distance <= 1.5
          ? CheckVerdict.close
          : CheckVerdict.notYou,
      findings: findings,
      quickFix: fixed == text ? null : fixed,
    );
  }

  static bool _startsWithCapital(String bubble) {
    final first = bubble.split(_space).first;
    if (RegExp(r"^I(?:$|['’])").hasMatch(first)) return false;
    final letters = first.replaceAll(RegExp(r'[^A-Za-z]'), '');
    if (letters.isEmpty) return false;
    if (letters.length > 1 && letters == letters.toUpperCase()) return false;
    return letters[0] == letters[0].toUpperCase();
  }

  static String _pct(double share) => '${(share * 100).round()}%';
}
