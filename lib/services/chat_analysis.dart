import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_usage.dart';
import '../models/stored_exchange.dart';
import '../models/style_profile.dart';
import 'openai_service.dart';

/// What a model made of one chat: how you write in it, how each of you acts,
/// and what goes on between you.
class ChatAnalysis {
  const ChatAnalysis({
    required this.at,
    this.writing = const [],
    this.acting = const [],
    this.you = const [],
    this.them = const [],
    this.together = const [],
  });

  final DateTime at;

  /// How you write to this person, as instructions another writer could
  /// follow. Fed to every reply written to them.
  final List<String> writing;

  /// How you behave with this person, as instructions another writer could
  /// follow: what you react to and how, initiative, interest, humour. Fed to
  /// every reply written to them, next to [writing].
  final List<String> acting;

  /// How you act in the chat, as observations. Older analyses have only
  /// this, not [acting].
  final List<String> you;

  /// How they act.
  final List<String> them;

  /// What goes on between you.
  final List<String> together;

  /// How replies should act: [acting], or for an older analysis, [you].
  List<String> get actingGuide => acting.isNotEmpty ? acting : you;

  bool get isEmpty =>
      writing.isEmpty &&
      acting.isEmpty &&
      you.isEmpty &&
      them.isEmpty &&
      together.isEmpty;

  Map<String, Object?> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'writing': writing,
    'acting': acting,
    'you': you,
    'them': them,
    'together': together,
  };

  static ChatAnalysis? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    return ChatAnalysis(
      at: at is num
          ? DateTime.fromMillisecondsSinceEpoch(at.toInt())
          : DateTime.now(),
      writing: _lines(json['writing']),
      acting: _lines(json['acting']),
      you: _lines(json['you']),
      them: _lines(json['them']),
      together: _lines(json['together']),
    );
  }

  static List<String> _lines(Object? raw) {
    if (raw is String) {
      return [
        for (final l in raw.split('\n'))
          if (l.replaceFirst(RegExp(r'^\s*[-•*]\s*'), '').trim().isNotEmpty)
            l.replaceFirst(RegExp(r'^\s*[-•*]\s*'), '').trim(),
      ];
    }
    if (raw is! List) return const [];
    return [
      for (final l in raw)
        if (l is String && l.trim().isNotEmpty) l.trim(),
    ];
  }
}

/// Reads a sample of a chat and writes a [ChatAnalysis]: one request.
class ChatAnalyst {
  const ChatAnalyst({required this.openai});

  final OpenAiService openai;

  /// Moments read, spread over the whole history.
  static const int sampleSize = 140;

  /// Messages before your reply shown with each moment.
  static const int turnsShown = 2;

  Future<ChatAnalysis> analyse(
    List<StoredExchange> exchanges, {
    required String myName,
    required String them,
    required StyleProfile profile,
    required String model,
    bool group = false,
  }) async {
    final raw = await openai.chat(
      model: model,
      messages: [
        {
          'role': 'system',
          'content': systemPrompt(me: myName, them: them, group: group),
        },
        {
          'role': 'user',
          'content': userPrompt(exchanges, myName: myName, profile: profile),
        },
      ],
      jsonMode: true,
      temperature: 0.3,
      usageKind: UsageKind.generation,
      timeout: const Duration(minutes: 3),
    );
    return parse(raw);
  }

  /// [exchanges] that are read: all of a short chat, or [sampleSize]
  /// spread evenly from the first to the last, oldest first.
  static List<StoredExchange> sample(List<StoredExchange> exchanges) {
    final dated = [...exchanges]
      ..sort((a, b) {
        final x = a.timestamp;
        final y = b.timestamp;
        if (x == null || y == null) return a.id.compareTo(b.id);
        return x.compareTo(y);
      });
    if (dated.length <= sampleSize) return dated;
    final last = dated.length - 1;
    return [
      for (var i = 0; i < sampleSize; i++)
        dated[(i * last / (sampleSize - 1)).round()],
    ];
  }

  static String systemPrompt({
    required String me,
    required String them,
    bool group = false,
  }) {
    final who = group ? 'the group chat "$them"' : 'their chat with $them';
    final other = group ? 'the others' : them;
    return 'You study how $me texts in $who. You get moments spread over the '
        'whole chat, oldest first: a message or two, then $me\'s reply '
        '(marked "Me"), and numbers measured from all of $me\'s replies. '
        'Write in English, but quote $me\'s words and phrases exactly as '
        'written, in their own language.\n\n'
        'Answer only with JSON:\n'
        '{"writing": [...], "acting": [...], "them": [...], '
        '"together": [...]}\n\n'
        '"writing" and "acting" matter most: together they must let another '
        'writer pass as $me with $other.\n'
        '"writing": 8 to 12 short lines on how $me\'s texts look and sound, '
        'specific enough to imitate. Cover length and rhythm, splitting into '
        'bubbles, casing and punctuation, spelling, slang and abbreviations, '
        'which language and how languages mix, emoji and laughter, and the '
        'words and phrases $me uses most, quoted. Say what $me never does '
        'too.\n'
        '"acting": 8 to 12 short lines on how $me behaves with $other, as '
        'instructions to act the same way. Cover how much $me cares to '
        'answer and how keen or unbothered $me comes across, whether $me '
        'matches $other\'s energy, who takes the initiative and how often '
        '$me asks back, what $me picks up on and what $me ignores, how $me '
        'teases, jokes, flirts or shows interest, how $me takes compliments, '
        'news and pushback, how $me makes, accepts or dodges plans, what $me '
        'shares about themselves, how $me opens and ends conversations, and '
        'what $me would never do. Give a short example from the messages '
        'where it helps.\n'
        'No generic advice in either: only what these messages show.\n'
        '"them": 3 to 6 about how $other act${group ? "" : "s"} towards $me, '
        'from what they wrote.\n'
        '"together": 2 to 4 about what goes on between them: what they bond '
        'over, running jokes, how it has changed over time.\n\n'
        'Be honest and specific, kind in tone, and only say what the '
        'messages support.';
  }

  static String userPrompt(
    List<StoredExchange> exchanges, {
    required String myName,
    required StyleProfile profile,
  }) {
    final b = StringBuffer();
    final habits = profile.describe(myName.isEmpty ? 'Me' : myName);
    if (habits.isNotEmpty) {
      b
        ..writeln(habits)
        ..writeln();
    }
    for (final e in sample(exchanges)) {
      final at = e.timestamp;
      if (at != null) {
        b.writeln(
          '[${at.year}-${at.month.toString().padLeft(2, '0')}-'
          '${at.day.toString().padLeft(2, '0')}]',
        );
      }
      final turns = e.context.length > turnsShown
          ? e.context.sublist(e.context.length - turnsShown)
          : e.context;
      for (final t in turns) {
        b.writeln('${t.sender == myName ? "Me" : t.sender}: ${_flat(t.text)}');
      }
      b
        ..writeln('Me: ${_flat(e.replyText)}')
        ..writeln();
    }
    return b.toString().trimRight();
  }

  static ChatAnalysis parse(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final json = jsonDecode(raw.substring(start, end + 1));
        if (json is Map) {
          return ChatAnalysis.fromJson({
            ...json,
            'at': DateTime.now().millisecondsSinceEpoch,
          })!;
        }
      } on FormatException {
        // Falls through to an empty analysis.
      }
    }
    return ChatAnalysis(at: DateTime.now());
  }

  static String _flat(String text) {
    final flat = text.replaceAll(RegExp(r'\s*\n\s*'), ' / ');
    return flat.length <= 280 ? flat : '${flat.substring(0, 280)}…';
  }
}

/// Each chat's analysis, kept on the device.
class AnalysisStore {
  const AnalysisStore();

  static const String _prefsKey = 'ditto_analysis_v1';

  Future<Map<int, ChatAnalysis>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return decode(prefs.getString(_prefsKey));
  }

  Future<ChatAnalysis?> forChat(int chatId) async => (await load())[chatId];

  Future<void> save(int chatId, ChatAnalysis analysis) async {
    final all = await load();
    all[chatId] = analysis;
    await _write(all);
  }

  Future<void> remove(int chatId) async {
    final all = await load();
    if (all.remove(chatId) != null) await _write(all);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  Future<void> _write(Map<int, ChatAnalysis> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({for (final e in all.entries) '${e.key}': e.value.toJson()}),
    );
  }

  static Map<int, ChatAnalysis> decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          ?int.tryParse('${e.key}'): ?ChatAnalysis.fromJson(e.value),
      };
    } on FormatException {
      return {};
    }
  }
}
