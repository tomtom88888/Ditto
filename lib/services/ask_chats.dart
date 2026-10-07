import '../models/api_usage.dart';
import 'chat_search.dart';
import 'openai_service.dart';

/// An answer to a question about your chats, and the moments it came from.
class AskAnswer {
  const AskAnswer({required this.text, required this.moments});

  /// The answer, with the moments it used cited like `[2]`.
  final String text;

  /// The moments the model was shown, numbered from 1 in the answer.
  final List<SearchHit> moments;

  /// The moments the answer cites, in the order first cited, with their
  /// numbers.
  List<(int, SearchHit)> get cited {
    final out = <(int, SearchHit)>[];
    final seen = <int>{};
    for (final m in RegExp(r'\[(\d+)\]').allMatches(text)) {
      final n = int.parse(m.group(1)!);
      if (n < 1 || n > moments.length || !seen.add(n)) continue;
      out.add((n, moments[n - 1]));
    }
    return out;
  }
}

/// Answers a question about your chats ("when did we first talk about
/// moving?", "what does she think of my job?") from the moments closest to
/// it: one embedding call to find them, one chat call to answer.
class AskChats {
  const AskChats({required this.openai, required this.search});

  final OpenAiService openai;
  final ChatSearch search;

  /// Moments the model is shown.
  static const int moments = 12;

  /// Turns shown before your reply in each moment.
  static const int turnsShown = 6;

  Future<AskAnswer> ask(
    String question, {
    required Set<int> chatIds,
    required Map<int, String> chatNames,
    required String myName,
    required String model,
    required String embeddingModel,
    required int dimensions,
  }) async {
    final found = await search.closest(
      question,
      chatIds: chatIds,
      embeddingModel: embeddingModel,
      dimensions: dimensions,
      count: moments,
    );
    if (found.isEmpty) {
      return const AskAnswer(
        text: "There's nothing in your chats to answer from yet.",
        moments: [],
      );
    }
    // Oldest first, so the model can tell what came before what.
    final ordered = [...found]
      ..sort((a, b) {
        final x = a.exchange.timestamp;
        final y = b.exchange.timestamp;
        if (x == null || y == null) return 0;
        return x.compareTo(y);
      });
    final raw = await openai.chat(
      model: model,
      messages: [
        {'role': 'system', 'content': systemPrompt(myName)},
        {
          'role': 'user',
          'content': userPrompt(question, ordered, chatNames: chatNames),
        },
      ],
      temperature: 0.2,
      usageKind: UsageKind.generation,
      timeout: const Duration(minutes: 2),
    );
    return AskAnswer(text: raw.trim(), moments: ordered);
  }

  static String systemPrompt(String myName) {
    final me = myName.isEmpty ? 'the user' : myName;
    return 'You answer questions about $me\'s own chats, using only the '
        'numbered moments from those chats below. Each moment is dated and '
        'says which chat it is from; lines are "Name: message", and "Me" '
        'is $me. Answer the question directly and briefly, in one to four '
        'sentences, in the language it was asked in, speaking to $me as '
        '"you". Cite the moments you rely on with their numbers, like [2] '
        'or [3][5]. If the moments do not answer it, say you could not find '
        'it in the chats, and do not guess.';
  }

  static String userPrompt(
    String question,
    List<SearchHit> moments, {
    Map<int, String> chatNames = const {},
  }) {
    final b = StringBuffer();
    for (final (i, hit) in moments.indexed) {
      final e = hit.exchange;
      final at = e.timestamp;
      final where = chatNames[e.chatId];
      b.writeln(
        '[${i + 1}]'
        '${at == null ? "" : " ${at.year}-${_two(at.month)}-${_two(at.day)}"}'
        '${where == null || where.isEmpty ? "" : " · chat with $where"}',
      );
      final turns = e.context.length > turnsShown
          ? e.context.sublist(e.context.length - turnsShown)
          : e.context;
      for (final t in turns) {
        b.writeln('${t.sender}: ${_flat(t.text)}');
      }
      b.writeln('Me: ${_flat(e.replyText)}');
      b.writeln();
    }
    b.write('Question: ${question.trim()}');
    return b.toString();
  }

  static String _flat(String text) =>
      text.replaceAll(RegExp(r'\s*\n\s*'), ' / ');

  static String _two(int n) => n.toString().padLeft(2, '0');
}
