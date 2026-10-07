import 'dart:math' as math;
import 'dart:typed_data';

import '../models/stored_exchange.dart';
import 'exchange_store.dart';
import 'openai_service.dart';
import 'vector_math.dart';

/// One moment found by a search.
class SearchHit {
  const SearchHit({
    required this.exchange,
    required this.score,
    required this.wordMatch,
    this.weak = false,
  });

  final StoredExchange exchange;

  /// How well it matches: fingerprint similarity plus a lift for words.
  final double score;

  /// Whether every word of the query appears in the moment.
  final bool wordMatch;

  /// Shown only because nothing clearly matched: the closest there was.
  final bool weak;
}

/// Finds moments in your chats by what they are about, not only by the
/// words in them: "that restaurant she mentioned" finds the evening she
/// raved about a ramen place. One embedding call per search; the rest
/// happens on the phone.
///
/// Three things keep the results on topic:
///
/// - Each moment has a tight fingerprint of just the last couple of messages
///   and your reply ([StoredExchange.focus]), which a short query matches far
///   better than the ten-turn stretch used for writing replies.
/// - Words are scored the way search engines do (BM25): a rare word that
///   appears counts for much more than a common one.
/// - Similarities between a short query and chat text sit close together
///   whatever the topic, so a fixed cut-off lets noise through. Instead a
///   moment has to stand out from all the others: [minStandout] standard
///   deviations above the average, or a strong word match.
class ChatSearch {
  ChatSearch({required this.openai, required this.store});

  final OpenAiService openai;
  final ExchangeStore store;

  static const int defaultLimit = 25;

  /// How many standard deviations above the average similarity a moment has
  /// to be to count as a match on meaning alone.
  static const double minStandout = 2.0;

  /// The word score (0 to 1, best moment = 1) that counts as a match on its
  /// own.
  static const double strongWords = 0.6;

  /// How much the word score adds to similarity when ranking.
  static const double wordWeight = 0.2;

  /// A match on meaning must also be within this of the best one.
  static const double maxBehindBest = 0.12;

  /// Shown, marked as weak, when nothing clearly matches.
  static const int closestWhenNone = 3;

  /// The best [limit] moments in [chatIds] for [query].
  Future<List<SearchHit>> search(
    String query, {
    required Set<int> chatIds,
    required String embeddingModel,
    required int dimensions,
    int limit = defaultLimit,
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
    return rank(
      VectorMath.normalise(vectors.first),
      text,
      candidates,
      limit: limit,
    );
  }

  /// The [count] moments closest to [query], with no cut-off: material for
  /// answering a question rather than a list to show.
  Future<List<SearchHit>> closest(
    String query, {
    required Set<int> chatIds,
    required String embeddingModel,
    required int dimensions,
    int count = 12,
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
    final scored = score(VectorMath.normalise(vectors.first), text, candidates)
      ..sort((a, b) => b.total.compareTo(a.total));
    return [
      for (final s in scored.take(count))
        SearchHit(exchange: s.exchange, score: s.total, wordMatch: s.allWords),
    ];
  }

  /// [candidates] ranked for a query, keeping only clear matches, best
  /// first. When none are clear, the [closestWhenNone] nearest come back
  /// marked [SearchHit.weak]. Candidates fingerprinted at another size are
  /// skipped.
  static List<SearchHit> rank(
    Float32List query,
    String text,
    List<StoredExchange> candidates, {
    int limit = defaultLimit,
  }) {
    final scored = score(query, text, candidates);
    if (scored.isEmpty) return const [];
    final sims = [for (final s in scored) s.similarity];
    final mean = sims.reduce((a, b) => a + b) / sims.length;
    final spread = math.sqrt(
      sims.map((s) => (s - mean) * (s - mean)).reduce((a, b) => a + b) /
          sims.length,
    );
    final best = sims.reduce(math.max);

    // Words decide on their own only when they pick out a few moments; a
    // word that is everywhere says nothing.
    final withWords = scored.where((s) => s.words > 0).length;
    final rareWords = scored.length < 8 || withWords <= scored.length * 0.2;

    bool clear(ScoredMoment s) {
      if (rareWords && s.words >= strongWords) return true;
      if (scored.length < 8) return s.similarity >= best - maxBehindBest;
      final standout = spread == 0 ? 0 : (s.similarity - mean) / spread;
      return standout >= minStandout && s.similarity >= best - maxBehindBest;
    }

    scored.sort((a, b) => b.total.compareTo(a.total));
    final kept = [
      for (final s in scored)
        if (clear(s))
          SearchHit(
            exchange: s.exchange,
            score: s.total,
            wordMatch: s.allWords,
          ),
    ];
    if (kept.isNotEmpty) return kept.take(limit).toList();
    return [
      for (final s in scored.take(math.min(closestWhenNone, limit)))
        SearchHit(
          exchange: s.exchange,
          score: s.total,
          wordMatch: s.allWords,
          weak: true,
        ),
    ];
  }

  /// Every usable candidate's similarity and word score.
  static List<ScoredMoment> score(
    Float32List query,
    String text,
    List<StoredExchange> candidates,
  ) {
    final usable = [
      for (final c in candidates)
        if (c.vector.length == query.length) c,
    ];
    final words = wordsOf(text);
    final docs = [
      for (final c in usable) wordsOf('${c.contextText}\n${c.replyText}'),
    ];
    final bm25 = Bm25(docs).scores(words);
    final top = bm25.isEmpty ? 0.0 : bm25.reduce(math.max);
    return [
      for (var i = 0; i < usable.length; i++)
        ScoredMoment(
          exchange: usable[i],
          similarity: _similarity(query, usable[i]),
          words: top == 0 ? 0 : bm25[i] / top,
          allWords: words.isNotEmpty && words.every(docs[i].contains),
        ),
    ];
  }

  /// The tight fingerprint when there is one; the whole stretch counts too,
  /// a little discounted, for moments the tight one misses.
  static double _similarity(Float32List query, StoredExchange e) {
    final wide = VectorMath.dot(query, e.vector);
    final focus = e.focus;
    if (focus == null || focus.length != query.length) return wide;
    return math.max(VectorMath.dot(query, focus), wide - 0.03);
  }

  /// Words worth matching, lowercased: three letters or more, so "a" and
  /// "is" don't count.
  static List<String> wordsOf(String text) => [
    for (final w in text.toLowerCase().split(
      RegExp(r'[^\p{L}\p{N}]+', unicode: true),
    ))
      if (w.length >= 3) w,
  ];
}

/// A candidate moment's similarity to a query and its word score.
class ScoredMoment {
  ScoredMoment({
    required this.exchange,
    required this.similarity,
    required this.words,
    required this.allWords,
  });

  final StoredExchange exchange;
  final double similarity;

  /// BM25, scaled so the best candidate is 1.
  final double words;
  final bool allWords;

  double get total => similarity + ChatSearch.wordWeight * words;
}

/// Okapi BM25 over a fixed set of documents: how well each matches a set of
/// query words, weighting rare words more. A query word also matches a
/// longer word it starts ("plan" in "plans", "planning").
class Bm25 {
  Bm25(this.docs, {this.k1 = 1.2, this.b = 0.75})
    : _avgLength = docs.isEmpty
          ? 0
          : docs.fold(0, (sum, d) => sum + d.length) / docs.length;

  final List<List<String>> docs;
  final double k1;
  final double b;
  final double _avgLength;

  static bool _matches(String word, String term) =>
      word == term || (term.length >= 4 && word.startsWith(term));

  List<double> scores(List<String> query) {
    if (docs.isEmpty) return const [];
    final terms = query.toSet();
    final idf = <String, double>{};
    for (final t in terms) {
      final df = docs.where((d) => d.any((w) => _matches(w, t))).length;
      idf[t] = math.log(1 + (docs.length - df + 0.5) / (df + 0.5));
    }
    return [
      for (final d in docs)
        terms.fold(0.0, (sum, t) {
          final tf = d.where((w) => _matches(w, t)).length;
          if (tf == 0) return sum;
          final norm =
              1 - b + b * d.length / (_avgLength == 0 ? 1 : _avgLength);
          return sum + idf[t]! * tf * (k1 + 1) / (tf + k1 * norm);
        }),
    ];
  }
}
