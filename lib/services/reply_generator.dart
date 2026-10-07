import 'dart:convert';

import '../models/app_settings.dart';
import '../models/chat_turn.dart';
import '../models/extracted_message.dart';
import '../models/reply_suggestion.dart';
import '../models/stored_exchange.dart';
import '../models/style_profile.dart';
import 'openai_exception.dart';
import 'openai_service.dart';
import 'style_conformer.dart';

/// A one-tap adjustment to a single suggestion.
enum Refinement {
  shorter,
  warmer,
  moreLikeMe;

  String get label => switch (this) {
    shorter => 'Shorter',
    warmer => 'Warmer',
    moreLikeMe => 'More like me',
  };

  /// What the model is asked to change, and nothing else.
  String instruction(String me) => switch (this) {
    shorter =>
      'Make it shorter — cut it down to what $me would actually bother to '
          'type, keeping the meaning.',
    warmer =>
      'Make it warmer and friendlier, the way $me is when they are in a good '
          'mood with this person. Do not make it longer than it needs to be.',
    moreLikeMe =>
      'It does not sound enough like $me. Rewrite it to match the examples '
          'and the measured habits more closely — their length, casing, '
          'punctuation, slang and emoji — even if that makes it rougher.',
  };
}

/// Writes the next message as you.
///
/// The model is not asked to imitate you; it is put in your place. Your
/// retrieved real exchanges go in as genuine turns of the conversation —
/// their lines as the user's, your actual reply as the model's own previous
/// message — so writing the next message *is* continuing in your voice. The
/// closest match sits last, right before the live chat.
///
/// The model then writes several plain drafts, which are held to the habits
/// measured from your replies ([StyleConformer]) and ranked by how typical of
/// you they are; the closest are kept.
class ReplyGenerator {
  const ReplyGenerator({required this.openai});

  final OpenAiService openai;

  /// Turns the screenshot transcription into turns, merging consecutive
  /// messages from the same side exactly as training did.
  static List<ChatTurn> turnsFrom(
    List<ExtractedMessage> messages, {
    required String myName,
    required String theirName,
  }) {
    final turns = <ChatTurn>[];
    final buffer = <String>[];
    String? current;

    void flush() {
      if (current == null || buffer.isEmpty) return;
      turns.add(
        ChatTurn(
          sender: current,
          text: buffer.join('\n'),
          messageCount: buffer.length,
        ),
      );
      buffer.clear();
    }

    // In a group each of the others is named, and a new name is a new turn.
    for (final message in messages) {
      if (message.text.trim().isEmpty) continue;
      final sender = message.speaker == Speaker.me
          ? myName
          : (message.author ?? theirName);
      if (current != sender) {
        flush();
        current = sender;
      }
      buffer.add(message.text);
    }
    flush();
    return turns;
  }

  /// How many drafts are written for each reply that is kept.
  static const int draftsPerReply = 2;

  /// Generates [AppSettings.variantCount] suggestions: all but the last
  /// answer what was just said; the last changes the subject.
  Future<List<ReplySuggestion>> generate({
    required List<ChatTurn> conversation,
    required List<ScoredExchange> examples,
    required AppSettings settings,
    String note = '',
    StyleProfile profile = StyleProfile.empty,
    List<String> voiceSample = const [],
    bool group = false,
    List<String> facts = const [],
    List<String> styleGuide = const [],
  }) async {
    if (conversation.isEmpty) {
      throw const OpenAiException(
        OpenAiErrorKind.badRequest,
        'There is nothing to reply to yet.',
      );
    }
    if (conversation.last.sender == settings.myName) {
      throw const OpenAiException(
        OpenAiErrorKind.badRequest,
        'The last message in the screenshot is yours, so there is nothing to '
        'reply to. Check the sides are right and try again.',
      );
    }

    final count = settings.variantCount < 1 ? 1 : settings.variantCount;
    final wantsTopicChange = count > 1;
    final replies = wantsTopicChange ? count - 1 : count;

    List<ChatMessageJson> messagesFor({required bool newTopic}) =>
        buildMessages(
          conversation: conversation,
          examples: examples,
          settings: settings,
          note: note,
          profile: profile,
          voiceSample: voiceSample,
          newTopic: newTopic,
          group: group,
          facts: facts,
          styleGuide: styleGuide,
        );

    final answers = await _bestDrafts(
      messagesFor(newTopic: false),
      settings: settings,
      profile: profile,
      keep: replies,
    );
    final suggestions = [
      for (final text in answers) ReplySuggestion.reply(text),
    ];
    if (wantsTopicChange) {
      final change = await _bestDrafts(
        messagesFor(newTopic: true),
        settings: settings,
        profile: profile,
        keep: 1,
      );
      // Only labelled a topic change because it was asked for as one.
      suggestions.addAll([
        for (final text in change)
          ReplySuggestion(text: text, kind: SuggestionKind.newTopic),
      ]);
    }
    return _deduplicate(suggestions);
  }

  /// Writes drafts, tidies and conforms them, and keeps the [keep] most like
  /// you.
  Future<List<String>> _bestDrafts(
    List<ChatMessageJson> messages, {
    required AppSettings settings,
    required StyleProfile profile,
    required int keep,
  }) async {
    final drafts = await openai.chatDrafts(
      model: settings.effectiveGenerationModel,
      messages: messages,
      count: keep * draftsPerReply,
      temperature: 0.9,
      maxOutputTokens: 300,
    );
    final cleaned = <String>[];
    final seen = <String>{};
    for (final draft in drafts) {
      final text = StyleConformer.conform(
        _tidy(draft, name: settings.myName),
        profile,
      );
      if (text.isEmpty || !seen.add(text.toLowerCase())) continue;
      cleaned.add(text);
    }
    return StyleConformer.rank(cleaned, profile).take(keep).toList();
  }

  /// Messages to start the chat with [settings.theirName] again after it
  /// went quiet: [count] options in your voice, drawing on [facts] and the
  /// [recent] end of the chat, nudged by [note].
  Future<List<String>> openers({
    required AppSettings settings,
    required List<ChatTurn> recent,
    StyleProfile profile = StyleProfile.empty,
    List<String> voiceSample = const [],
    List<String> facts = const [],
    List<String> styleGuide = const [],
    String note = '',
    String quietFor = '',
    bool group = false,
    int count = 3,
  }) async {
    final me = _name(settings.myName, 'the user');
    final them = _name(settings.theirName, 'them');
    final system = buildSystemPrompt(
      settings,
      profile: profile,
      voiceSample: voiceSample,
      note: note,
      hasExamples: false,
      group: group,
      earlier: recent,
      earlierIntro: 'How the chat with $them went the last time you talked:',
      facts: facts,
      styleGuide: styleGuide,
      extra:
          'There is no new message to answer: the chat has gone quiet'
          '${quietFor.isEmpty ? "" : " for $quietFor"}. Write one message $me '
          'could send to start it up again with $them. Make it easy to '
          'answer and specific to the two of them: follow up on something '
          'from the end of the chat or from what $me knows about $them, or '
          'open something new they would enjoy. No "hey stranger", no '
          'apologising for the silence unless $me would.',
    );
    final drafts = await _bestDrafts(
      [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': 'Write the message $me sends to $them.'},
      ],
      settings: settings,
      profile: profile,
      keep: count,
    );
    return drafts;
  }

  /// [draft], a message you wrote yourself, rewritten to sound like you
  /// write to [settings.theirName], saying the same thing. Two options.
  Future<List<String>> rewriteMine({
    required String draft,
    required AppSettings settings,
    StyleProfile profile = StyleProfile.empty,
    List<String> voiceSample = const [],
    List<ChatTurn> recent = const [],
    bool group = false,
    List<String> styleGuide = const [],
  }) async {
    final me = _name(settings.myName, 'the user');
    final system = buildSystemPrompt(
      settings,
      profile: profile,
      voiceSample: voiceSample,
      hasExamples: false,
      group: group,
      earlier: recent,
      styleGuide: styleGuide,
      earlierIntro: 'The end of the chat so far, for background:',
      extra:
          '$me has written the message in the last user message and wants '
          'it to sound like them. Rewrite it so it says the same thing, '
          'with nothing added or left out, in exactly the way $me writes: '
          'length, casing, punctuation, slang, emoji and bubbles. Send only '
          'the rewritten message.',
    );
    return _bestDrafts(
      [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': draft.trim()},
      ],
      settings: settings,
      profile: profile,
      keep: 2,
    );
  }

  /// How much [draft], a message you wrote, sounds like you writing to
  /// [settings.theirName]: judged against [styleGuide], your measured habits
  /// and real messages you sent them.
  Future<StyleVerdict> judgeMine({
    required String draft,
    required AppSettings settings,
    StyleProfile profile = StyleProfile.empty,
    List<String> voiceSample = const [],
    List<String> styleGuide = const [],
  }) async {
    final me = _name(settings.myName, 'the user');
    final them = _name(settings.theirName, 'them');
    final habits = profile.describe(me);
    final system = StringBuffer(
      'You judge whether a message sounds like $me texting $them. Compare it '
      'with how $me really writes to $them, below, and nothing else: not '
      'whether it is a good message, only whether it is $me.',
    );
    if (styleGuide.isNotEmpty) {
      system
        ..writeln()
        ..writeln()
        ..writeln('How $me writes to $them:')
        ..write(styleGuide.map((l) => '- $l').join('\n'));
    }
    if (habits.isNotEmpty) {
      system
        ..writeln()
        ..writeln()
        ..write(habits);
    }
    if (voiceSample.isNotEmpty) {
      system
        ..writeln()
        ..writeln()
        ..writeln('Messages $me really sent $them:')
        ..write(
          voiceSample.map((m) => '- ${m.replaceAll('\n', ' / ')}').join('\n'),
        );
    }
    system
      ..writeln()
      ..writeln()
      ..write(
        'Answer only with JSON: {"score": <0-10, 10 = exactly how $me writes>, '
        '"verdict": "<a few words>", "notes": ["<what gives it away, or what '
        'is spot on, quoting the words; at most 4>"]}. Notes in English, '
        'quotes as written.',
      );
    final raw = await openai.chat(
      model: settings.generationModel,
      messages: [
        {'role': 'system', 'content': system.toString()},
        {'role': 'user', 'content': draft.trim()},
      ],
      jsonMode: true,
      temperature: 0,
    );
    return StyleVerdict.parse(raw);
  }

  /// Rewrites one suggestion according to [refinement], keeping what it is
  /// for: a topic change stays a topic change.
  Future<ReplySuggestion> refine({
    required ReplySuggestion suggestion,
    required Refinement refinement,
    required List<ChatTurn> conversation,
    required List<ScoredExchange> examples,
    required AppSettings settings,
    String note = '',
    StyleProfile profile = StyleProfile.empty,
    List<String> voiceSample = const [],
    bool group = false,
    List<String> facts = const [],
    List<String> styleGuide = const [],
  }) async {
    final me = _name(settings.myName, 'the user');
    final messages = buildMessages(
      conversation: conversation,
      examples: examples,
      settings: settings,
      note: note,
      profile: profile,
      voiceSample: voiceSample,
      newTopic: suggestion.isNewTopic,
      group: group,
      facts: facts,
      styleGuide: styleGuide,
      extra:
          'You had drafted this as your next message:\n'
          '${suggestion.text}\n\n'
          '${refinement.instruction(me)} Send the rewritten message only.',
    );
    final drafts = await openai.chatDrafts(
      model: settings.effectiveGenerationModel,
      messages: messages,
      count: 1,
      temperature: 0.8,
      maxOutputTokens: 300,
    );
    final text = StyleConformer.conform(
      _tidy(drafts.first, name: settings.myName),
      profile,
    );
    if (text.isEmpty) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'The model returned an empty rewrite. Try again.',
      );
    }
    return suggestion.copyWith(text: text);
  }

  // ------------------------------------------------------------------ prompts

  /// The whole request: the system prompt, each retrieved exchange as a real
  /// back-and-forth (least similar first, so the closest sits nearest the live
  /// chat), then the live chat as the last user turn.
  static List<ChatMessageJson> buildMessages({
    required List<ChatTurn> conversation,
    required List<ScoredExchange> examples,
    required AppSettings settings,
    String note = '',
    StyleProfile profile = StyleProfile.empty,
    List<String> voiceSample = const [],
    bool newTopic = false,
    bool group = false,
    List<String> facts = const [],
    List<String> styleGuide = const [],
    String? extra,
  }) {
    final me = settings.myName;
    final earlier = conversation.length > settings.contextTurns
        ? conversation.sublist(0, conversation.length - settings.contextTurns)
        : const <ChatTurn>[];
    return [
      {
        'role': 'system',
        'content': buildSystemPrompt(
          settings,
          profile: profile,
          voiceSample: voiceSample,
          note: note,
          newTopic: newTopic,
          hasExamples: examples.isNotEmpty,
          group: group,
          earlier: earlier,
          facts: facts,
          styleGuide: styleGuide,
          extra: extra,
        ),
      },
      for (final example in examples.reversed) ...[
        {
          'role': 'user',
          'content': _theirSide(
            example.exchange.context,
            me: me,
            named: group || _othersIn(example.exchange.context, me) > 1,
          ),
        },
        {'role': 'assistant', 'content': example.exchange.replyText},
      ],
      {
        'role': 'user',
        'content': buildUserPrompt(
          conversation: conversation,
          settings: settings,
          group: group,
        ),
      },
    ];
  }

  /// A retrieved exchange's lead-up, as it appears in a user turn. Your own
  /// earlier lines in it are kept and marked, since they are part of what
  /// was said.
  ///
  /// With [named] — in a group, where "them" is several people — each of
  /// the others' lines starts with who said it.
  static String _theirSide(
    List<ChatTurn> context, {
    required String me,
    bool named = false,
  }) => context
      .map(
        (t) => t.sender == me
            ? '(you) ${t.text}'
            : (named ? '${t.sender}: ${t.text}' : t.text),
      )
      .join('\n');

  /// Most of the conversation before the live window that goes in the
  /// prompt as background.
  static const int maxBackgroundCharacters = 4000;

  /// The earlier turns, newest kept when they run long.
  static String _background(
    List<ChatTurn> earlier, {
    required String me,
    required bool named,
  }) {
    final text = _theirSide(earlier, me: me, named: named);
    if (text.length <= maxBackgroundCharacters) return text;
    final cut = text.substring(text.length - maxBackgroundCharacters);
    final line = cut.indexOf('\n');
    return '…\n${line < 0 ? cut : cut.substring(line + 1)}';
  }

  /// How many different people besides [me] speak in [turns].
  static int _othersIn(List<ChatTurn> turns, String me) => {
    for (final t in turns)
      if (t.sender != me) t.sender,
  }.length;

  /// The live chat as the final user turn: the other person's lines, with
  /// your own earlier ones marked, in the same shape as the examples.
  static String buildUserPrompt({
    required List<ChatTurn> conversation,
    required AppSettings settings,
    bool group = false,
  }) {
    final recent = conversation.length > settings.contextTurns
        ? conversation.sublist(conversation.length - settings.contextTurns)
        : conversation;
    return _theirSide(recent, me: settings.myName, named: group);
  }

  /// The system prompt: the editable instructions with the names filled in,
  /// then what this particular message needs — the measured habits, a sample
  /// of real messages, the note, and whether to change the subject.
  static String buildSystemPrompt(
    AppSettings settings, {
    StyleProfile profile = StyleProfile.empty,
    List<String> voiceSample = const [],
    String note = '',
    bool newTopic = false,
    bool hasExamples = true,
    bool group = false,
    List<ChatTurn> earlier = const [],
    List<String> facts = const [],
    List<String> styleGuide = const [],
    String? extra,
    String? earlierIntro,
  }) {
    final me = settings.myName.isEmpty ? 'the user' : settings.myName;
    final name = settings.theirName;
    // In a group, "{them}" is the chat, not a person.
    final them = group
        ? (name.isEmpty ? 'a group chat' : 'the group chat "$name"')
        : (name.isEmpty ? 'someone they know' : name);
    final out = StringBuffer(
      settings.effectiveSystemPrompt
          .replaceAll('{me}', me)
          .replaceAll('{them}', them),
    );

    void section(String text) {
      if (text.trim().isEmpty) return;
      out
        ..writeln()
        ..writeln()
        ..write(text.trim());
    }

    section(
      '${group ? "How this chat is laid out: each user message is what the "
                "others in $them said, each line starting with who said it "
                "(lines marked \"(you)\" are yours, from earlier), and each "
                "assistant message is exactly what $me sent back. Several "
                "people are talking: answer as $me would in the group — to "
                "whoever it makes sense to answer, usually the last message, "
                "without addressing everyone." : "How this chat is laid out: "
                "each user message is what $them said (lines marked "
                "\"(you)\" are yours, from earlier), and each assistant "
                "message is exactly what $me sent back."}'
      '${hasExamples ? " The earlier pairs are real moments from $me's chat "
                "history, chosen because they resemble this one — the last "
                "pair is the closest." : ""}',
    );

    if (earlier.isNotEmpty) {
      final background = _background(
        earlier,
        me: settings.myName,
        named: group,
      );
      section(
        '${earlierIntro ?? "Earlier in this same conversation, before the "
                "part in the last user message (background only — what $me "
                "writes answers the latest messages):"}\n$background',
      );
    }

    if (facts.isNotEmpty) {
      section(
        'Things $me knows about $them from their chats, to call back to only '
        'when one fits what is being said (never list them, never force one '
        'in):\n${facts.map((f) => '- $f').join('\n')}',
      );
    }

    if (styleGuide.isNotEmpty) {
      section(
        'How $me writes to $them, as studied from their whole chat (follow '
        'it closely; it is $me\'s voice):\n'
        '${styleGuide.map((l) => '- $l').join('\n')}',
      );
    }

    final habits = profile.describe(me);
    if (habits.isNotEmpty) {
      section(
        '$habits\nStay inside these habits. A message longer, tidier or '
        'more punctuated than this is out of character.',
      );
    }
    section(_bubbleGuidance(profile, me));

    if (voiceSample.isNotEmpty) {
      section(
        'Other messages $me has really sent, to hear the voice (not to '
        'copy):\n${voiceSample.map((m) => '- ${m.replaceAll('\n', ' / ')}').join('\n')}',
      );
    }

    if (note.trim().isNotEmpty) {
      section(
        'For this next message only, $me wants it to: ${note.trim()}\n'
        'That decides what the message says; how it is written still has to '
        'be $me. Do not quote the note back.',
      );
    }

    if (newTopic) {
      section(
        group
            ? 'For this next message, do not answer what was just said. Move '
                  'the conversation in $them on to something else, the way $me '
                  'would change the subject in front of everyone — still '
                  'sounding like $me, and still fitting where the chat has '
                  'got to.'
            : 'For this next message, do not answer what $them just said. '
                  'Move the conversation on to something else, the way $me '
                  'would change the subject with $them — still sounding like '
                  '$me, and still fitting where the chat has got to.',
      );
    }
    section(extra ?? '');
    return out.toString();
  }

  /// Whether to split a message into bubbles, from how often [me] does.
  ///
  /// A line break in the output means a separate bubble, which the app lets
  /// you copy one at a time.
  static String _bubbleGuidance(StyleProfile profile, String me) {
    if (profile.turns < 5) return '';
    final share = profile.multiBubbleShare;
    if (share >= 0.15) {
      return '$me sends several bubbles in a row ${(share * 100).round()}% '
          'of the time, about ${profile.bubblesPerReply.toStringAsFixed(1)} '
          'per reply. When $me would split a message, put each bubble on its '
          'own line; a line break means a separate bubble.';
    }
    return '$me almost always sends one bubble at a time, so keep each '
        'message to a single bubble with no line breaks.';
  }

  static String _name(String name, String fallback) =>
      name.isEmpty ? fallback : name;

  static List<ReplySuggestion> _deduplicate(List<ReplySuggestion> variants) {
    final seen = <String>{};
    final out = <ReplySuggestion>[];
    for (final variant in variants) {
      if (variant.text.isEmpty) continue;
      if (seen.add(variant.text.toLowerCase())) out.add(variant);
    }
    return out;
  }

  /// Strips the quotes and labels models like to wrap a single message in.
  static String _tidy(String reply, {String name = ''}) {
    var out = reply.trim();
    out = out.replaceFirst(
      RegExp(r'^(?:reply|message|option \d+)\s*:\s*', caseSensitive: false),
      '',
    );
    // A model continuing a chat sometimes starts with the speaker's name, or
    // the "(you)" marker the examples use.
    out = out.replaceFirst(RegExp(r'^\(you\)\s*'), '');
    if (name.isNotEmpty && out.startsWith('$name:')) {
      out = out.substring(name.length + 1);
    }
    if (out.length > 1) {
      const pairs = {'"': '"', "'": "'", '\u201c': '\u201d'};
      final closing = pairs[out[0]];
      if (closing != null && out.endsWith(closing)) {
        out = out.substring(1, out.length - 1);
      }
    }
    return out.trim();
  }
}

/// A model's judgement of whether a message sounds like you.
class StyleVerdict {
  const StyleVerdict({
    required this.score,
    required this.verdict,
    this.notes = const [],
  });

  /// 0 to 10; 10 is exactly how you write.
  final int score;
  final String verdict;
  final List<String> notes;

  static StyleVerdict parse(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    Object? json;
    if (start >= 0 && end > start) {
      try {
        json = jsonDecode(raw.substring(start, end + 1));
      } on FormatException {
        json = null;
      }
    }
    if (json is! Map) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        "Couldn't read the judgement. Try again.",
      );
    }
    final score = json['score'];
    final verdict = json['verdict'];
    final notes = json['notes'];
    return StyleVerdict(
      score: score is num ? score.round().clamp(0, 10) : 0,
      verdict: verdict is String ? verdict.trim() : '',
      notes: [
        if (notes is List)
          for (final n in notes)
            if (n is String && n.trim().isNotEmpty) n.trim(),
      ],
    );
  }
}
