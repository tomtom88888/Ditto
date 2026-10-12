import 'chat_turn.dart';

/// A prompt under test: what it is called on screen, and its text.
class BlindPrompt {
  const BlindPrompt({required this.label, required this.text});

  static const String builtIn = 'Built-in';
  static const String yours = 'Yours';
  static const String tryThis = 'Try this';

  final String label;
  final String text;

  bool get isBuiltIn => label == builtIn;

  Map<String, Object?> toJson() => {'label': label, 'text': text};

  static BlindPrompt? fromJson(Object? json) {
    if (json is! Map) return null;
    final label = json['label'];
    final text = json['text'];
    if (label is! String || text is! String) return null;
    return BlindPrompt(label: label, text: text);
  }
}

/// One moment of the test: what you really replied, what was written in
/// your place, and who could tell them apart.
///
/// The two are shown as A and B; [realIsA] says which is yours. A pick is
/// "A" or "B"; the judge's is `null` when its answer couldn't be read.
class BlindPair {
  const BlindPair({
    required this.context,
    required this.real,
    required this.generated,
    required this.realIsA,
    this.judgePick,
    this.why = '',
    this.userPick,
  });

  final List<ChatTurn> context;
  final String real;
  final String generated;
  final bool realIsA;
  final String? judgePick;

  /// The judge's one line on what gave the other one away.
  final String why;
  final String? userPick;

  String get a => realIsA ? real : generated;
  String get b => realIsA ? generated : real;

  /// Whether [pick] chose the generated message as the real one.
  bool _fooled(String pick) => (pick == 'A') != realIsA;

  /// Whether the judge took the generated message for yours. An unreadable
  /// answer counts as spotted, so a broken judge never flatters a prompt.
  bool get judgeFooled => judgePick != null && _fooled(judgePick!);

  /// Whether you took it for yours; `null` until you've played this one.
  bool? get userFooled => userPick == null ? null : _fooled(userPick!);

  BlindPair withUserPick(String? pick) => BlindPair(
    context: context,
    real: real,
    generated: generated,
    realIsA: realIsA,
    judgePick: judgePick,
    why: why,
    userPick: pick,
  );

  Map<String, Object?> toJson() => {
    'context': [for (final t in context) t.toJson()],
    'real': real,
    'generated': generated,
    'realIsA': realIsA,
    'judgePick': judgePick,
    'why': why,
    'userPick': userPick,
  };

  static BlindPair? fromJson(Object? json) {
    if (json is! Map) return null;
    final context = json['context'];
    final real = json['real'];
    final generated = json['generated'];
    if (context is! List || real is! String || generated is! String) {
      return null;
    }
    String? pick(Object? value) =>
        value == 'A' || value == 'B' ? value as String : null;
    return BlindPair(
      context: [
        for (final t in context)
          if (t is Map) ChatTurn.fromJson(t.cast<String, Object?>()),
      ],
      real: real,
      generated: generated,
      realIsA: json['realIsA'] == true,
      judgePick: pick(json['judgePick']),
      why: json['why'] is String ? json['why'] as String : '',
      userPick: pick(json['userPick']),
    );
  }
}

/// How one prompt did over every moment of a run.
class BlindPromptResult {
  const BlindPromptResult({required this.prompt, required this.pairs});

  final BlindPrompt prompt;
  final List<BlindPair> pairs;

  int get judgeFooled => pairs.where((p) => p.judgeFooled).length;

  /// The share of moments where the judge took the generated message for
  /// yours: about half means it couldn't tell, none means it always could.
  double get judgeFoolRate => pairs.isEmpty ? 0 : judgeFooled / pairs.length;

  bool get played => pairs.isNotEmpty && pairs.every((p) => p.userPick != null);

  int get userFooled => pairs.where((p) => p.userFooled ?? false).length;

  /// The same, by your own guesses; `null` until you've played every pair.
  double? get userFoolRate => played ? userFooled / pairs.length : null;

  /// The moments where the generated message was spotted.
  List<BlindPair> get misses => [
    for (final p in pairs)
      if (!p.judgeFooled) p,
  ];

  BlindPromptResult withPairs(List<BlindPair> next) =>
      BlindPromptResult(prompt: prompt, pairs: next);

  Map<String, Object?> toJson() => {
    'prompt': prompt.toJson(),
    'pairs': [for (final p in pairs) p.toJson()],
  };

  static BlindPromptResult? fromJson(Object? json) {
    if (json is! Map) return null;
    final prompt = BlindPrompt.fromJson(json['prompt']);
    final pairs = json['pairs'];
    if (prompt == null || pairs is! List) return null;
    return BlindPromptResult(
      prompt: prompt,
      pairs: [for (final p in pairs) ?BlindPair.fromJson(p)],
    );
  }
}

/// One go of the blind test: every prompt over the same moments.
class BlindRun {
  const BlindRun({
    required this.at,
    required this.replyModel,
    required this.promptVersion,
    required this.results,
  });

  final DateTime at;
  final String replyModel;

  /// Which built-in reply prompt was in the app, so runs from different
  /// versions aren't mistaken for like with like.
  final int promptVersion;
  final List<BlindPromptResult> results;

  BlindPromptResult? get builtIn {
    for (final r in results) {
      if (r.prompt.isBuiltIn) return r;
    }
    return null;
  }

  BlindRun withResults(List<BlindPromptResult> next) => BlindRun(
    at: at,
    replyModel: replyModel,
    promptVersion: promptVersion,
    results: next,
  );

  Map<String, Object?> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'replyModel': replyModel,
    'promptVersion': promptVersion,
    'results': [for (final r in results) r.toJson()],
  };

  static BlindRun? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final results = json['results'];
    if (at is! num || results is! List) return null;
    return BlindRun(
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      replyModel: json['replyModel'] is String
          ? json['replyModel'] as String
          : '',
      promptVersion: (json['promptVersion'] as num?)?.toInt() ?? 0,
      results: [for (final r in results) ?BlindPromptResult.fromJson(r)],
    );
  }
}

/// Everything the blind test keeps for one chat.
class BlindTestState {
  const BlindTestState({
    required this.seed,
    this.tryThis = '',
    this.runs = const [],
  });

  /// Picks the moments, so every run tests the same ones until you ask for
  /// new ones.
  final int seed;

  /// The prompt typed into "Try this".
  final String tryThis;

  /// Newest first.
  final List<BlindRun> runs;

  /// The most runs kept per chat; each holds every moment's messages.
  static const int maxRuns = 10;

  BlindTestState copyWith({int? seed, String? tryThis, List<BlindRun>? runs}) =>
      BlindTestState(
        seed: seed ?? this.seed,
        tryThis: tryThis ?? this.tryThis,
        runs: runs ?? this.runs,
      );

  /// With [run] added as the newest.
  BlindTestState adding(BlindRun run) =>
      copyWith(runs: [run, ...runs].take(maxRuns).toList());

  Map<String, Object?> toJson() => {
    'seed': seed,
    'tryThis': tryThis,
    'runs': [for (final r in runs) r.toJson()],
  };

  static BlindTestState? fromJson(Object? json) {
    if (json is! Map) return null;
    final seed = json['seed'];
    if (seed is! num) return null;
    final runs = json['runs'];
    return BlindTestState(
      seed: seed.toInt(),
      tryThis: json['tryThis'] is String ? json['tryThis'] as String : '',
      runs: [
        if (runs is List)
          for (final r in runs) ?BlindRun.fromJson(r),
      ],
    );
  }
}
