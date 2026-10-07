import 'dart:convert';
import 'dart:typed_data';

import '../models/api_usage.dart';
import '../models/stored_exchange.dart';
import 'exchange_store.dart';
import 'openai_exception.dart';
import 'openai_service.dart';
import 'vector_math.dart';

/// One moment found by a search.
class SearchHit {
  const SearchHit({
    required this.exchange,
    required this.score,
    required this.wordMatch,
    this.why,
  });

  final StoredExchange exchange;

  /// How well it matches, 0 to 1: the AI's judgement when the moment was
  /// read, otherwise similarity with a lift for matching words.
  final double score;

  /// Whether every word of the query appears in the moment.
  final bool wordMatch;

  /// What in the moment matches, in a few words, when the AI read it.
  final String? why;
}

/// Finds moments in your chats by what they are about, not only by the
/// words in them: "that restaurant she mentioned" finds the evening she
/// raved about a ramen place.
///
/// Two steps. The query is fingerprinted (one embedding call) and compared
/// with every stored moment on the phone, which cheaply shortlists the
/// closest few dozen. A fingerprint covers a whole stretch of conversation,
/// though, so on its own it ranks loosely related moments almost as high as
/// the right one. So the shortlist is then read by the chat model (one more
/// call), which keeps only the moments that really are about what was asked,
/// best first, and says why each matches.
class ChatSearch {
  ChatSearch({required this.openai, required this.store});

  final OpenAiService openai;
  final ExchangeStore store;

  static const int defaultLimit = 25;

  /// How many of the closest moments the model reads.
  static const int shortlist = 40;

  /// Without the model's reading: below this, a moment has too little to do
  /// with the query to show.
  static const double minScore = 0.25;

  /// Added, in proportion, for the query's words found in the moment.
  static const double wordBoost = 0.15;

  /// Out of 10, the least the model must give a moment for it to show.
  static const int keepFrom = 5;

  /// The turns before your reply shown to the model for each moment.
  static const int turnsShown = 4;

  /// Searches [chatIds] for [query]. With [model], the shortlist is read by
  /// that chat model; if that call fails, the plain ranking is returned.
  Future<List<SearchHit>> search(
    String query, {
    required Set<int> chatIds,
    required String embeddingModel,
    required int dimensions,
    int limit = defaultLimit,
    String? model,
  }) async {
    final text = query.trim();
    if (text.isEmpty || chatIds.isEmpty) return const [];
    final candidates = await store.all(chatIds: chatIds);
    if (candidates.isEmpty) return const [];
    final vectors = await openai.embed(
      [text],
      model: embeddingModel,
      dimensions: dimensions,
    );
    final queryVector = VectorMath.normalise(vectors.first);
    if (model == null) {
      return rank(queryVector, text, candidates, limit: limit);
    }
    final closest = rank(
      queryVector,
      text,
      candidates,
      limit: shortlist,
      floor: 0,
    );
    if (closest.isEmpty) return const [];
    try {
      final judged = await judge(text, closest, model: model);
      return judged.take(limit).toList();
    } on OpenAiException {
      return closest.where((h) => h.score >= minScore).take(limit).toList();
    }
  }

  /// The best [limit] of [candidates] for a query, best first, none scoring
  /// under [floor]. Candidates fingerprinted at another size are skipped.
  static List<SearchHit> rank(
    Float32List query,
    String text,
    List<StoredExchange> candidates, {
    int limit = defaultLimit,
    double floor = minScore,
  }) {
    final words = _words(text);
    final hits = <SearchHit>[];
    for (final c in candidates) {
      if (c.vector.length != query.length) continue;
      final haystack = '${c.contextText}\n${c.replyText}'.toLowerCase();
      final found = words.where(haystack.contains).length;
      final all = words.isNotEmpty && found == words.length;
      final lift = words.isEmpty ? 0.0 : wordBoost * found / words.length;
      final score = VectorMath.dot(query, c.vector) + lift;
      if (score < floor) continue;
      hits.add(SearchHit(exchange: c, score: score, wordMatch: all));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  /// Has the chat model read [hits] and keep the ones that match [query],
  /// best first.
  Future<List<SearchHit>> judge(
    String query,
    List<SearchHit> hits, {
    required String model,
  }) async {
    final raw = await openai.chat(
      model: model,
      messages: [
        {'role': 'system', 'content': judgePrompt},
        {'role': 'user', 'content': judgeInput(query, hits)},
      ],
      jsonMode: true,
      temperature: 0,
      usageKind: UsageKind.generation,
      timeout: const Duration(minutes: 2),
    );
    final verdicts = parseVerdicts(raw);
    final kept = <(int, int, SearchHit)>[];
    for (final (index, hit) in hits.indexed) {
      final v = verdicts[index];
      if (v == null || v.$1 < keepFrom) continue;
      kept.add((
        v.$1,
        index,
        SearchHit(
          exchange: hit.exchange,
          score: v.$1 / 10,
          wordMatch: hit.wordMatch,
          why: v.$2,
        ),
      ));
    }
    kept.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
    });
    return [for (final k in kept) k.$3];
  }

  static const String judgePrompt =
      'You help someone find a moment in their own chat history. You get '
      'what they are looking for, then numbered moments from their chats: '
      'a few messages, then their reply, marked "Me". Decide for each '
      'moment whether it is what they are looking for: about the same '
      'thing, event, place, person or plan. Sharing a word is not enough, '
      'and a vague or general chat is not a match. Score 0 to 10, where 10 '
      'is clearly the moment they mean. Answer only with JSON: {"matches": '
      '[{"id": <number>, "score": <0-10>, "why": "<at most 10 words, in the '
      'language of the chat, saying what in it matches>"}]}, listing only '
      'moments scoring 5 or more, best first. An empty list is fine.';

  /// The query and the shortlisted moments, numbered from 0.
  static String judgeInput(String query, List<SearchHit> hits) {
    final b = StringBuffer('Looking for: $query\n');
    for (final (i, hit) in hits.indexed) {
      final e = hit.exchange;
      final at = e.timestamp;
      b.writeln();
      b.writeln(
        '[$i]${at == null ? "" : " ${at.year}-${_two(at.month)}-${_two(at.day)}"}',
      );
      final turns = e.context.length > turnsShown
          ? e.context.sublist(e.context.length - turnsShown)
          : e.context;
      for (final t in turns) {
        b.writeln('${t.sender}: ${_clip(t.text)}');
      }
      b.writeln('Me: ${_clip(e.replyText)}');
    }
    return b.toString();
  }

  /// Score and reason for each moment the model kept, by its number.
  static Map<int, (int, String?)> parseVerdicts(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return const {};
    Object? json;
    try {
      json = jsonDecode(raw.substring(start, end + 1));
    } on FormatException {
      return const {};
    }
    final list = json is Map ? json['matches'] : null;
    if (list is! List) return const {};
    final out = <int, (int, String?)>{};
    for (final m in list) {
      if (m is! Map) continue;
      final id = m['id'];
      final score = m['score'];
      if (id is! num || score is! num) continue;
      final why = m['why'];
      out[id.toInt()] = (
        score.round().clamp(0, 10),
        why is String && why.trim().isNotEmpty ? why.trim() : null,
      );
    }
    return out;
  }

  static String _clip(String text) {
    final flat = text.replaceAll(RegExp(r'\s*\n\s*'), ' / ');
    return flat.length <= 300 ? flat : '${flat.substring(0, 300)}…';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// The query's words worth matching: three letters or more, so "a" and
  /// "is" don't count.
  static List<String> _words(String text) => [
    for (final w in text.toLowerCase().split(
      RegExp(r'[^\p{L}\p{N}]+', unicode: true),
    ))
      if (w.length >= 3) w,
  ];
}
