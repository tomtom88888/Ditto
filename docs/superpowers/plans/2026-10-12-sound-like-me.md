# Sounding like you — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put real past exchanges back in as turns the model "sent", guard
against leaks, stop feeding Analysis into other features, remove "Is it like
me?", then add a per-chat blind test that compares up to three prompts.

**Architecture:** Part 1 edits `ReplyGenerator` and three screens, plus a
pure `LeakGuard`. Part 2 adds a `BlindTest` service (pure helpers plus one
async `run`), a `BlindTestStore` in SharedPreferences, a screen opened from
the Home chat menu, and an `exclude` predicate on two `StyleMemoryService`
methods.

**Tech Stack:** Flutter 3.47 / Dart ^3.12, Riverpod 3, shared_preferences,
flutter_test with `MockClient` fakes (`test/explore_features_test.dart`
exports `fake`, `chat`, `exchange`, `turn`).

**Spec:** `docs/superpowers/specs/2026-10-12-sound-like-me-design.md`

## Global Constraints

- Run `flutter analyze` and `flutter test` clean before every commit.
- Match the code style: prose doc comments explaining why, British English
  in UI copy, `Paper*` widgets from `lib/widgets/paper_ui.dart`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Nothing from `AnalysisStore` or `FactsStore` may reach `ReplyGenerator`.
- Blind-test moments: 20, reply 2–160 chars, exclusion window 12 h (±10 ids
  without timestamps), judge sample 15, close call at p < 0.1 (|z| > 1.645).

---

## Part 1

### Task 1: Examples back as turns

**Files:**
- Modify: `lib/services/reply_generator.dart` (`buildMessages`,
  `buildSystemPrompt`, `_moment` removed, `Refinement.moreLikeMe`, class doc)
- Modify: `lib/models/app_settings.dart` (`defaultSystemPrompt`)
- Test: `test/reply_generator_test.dart`, `test/generate_screen_test.dart`,
  `test/group_chat_test.dart`

**Interfaces:**
- Produces: `buildSystemPrompt(settings, {…, bool hasExamples = true, …})`
  replacing `List<ScoredExchange> examples`.

- [ ] **Step 1: Restore the pre-`a4116c5` test expectations** (from
  `git show a4116c5 -- test/`): roles
  `[system, user, assistant, user, assistant, user]`, `m[1]=='cinema?'`,
  `m[2]=='nah skint'`, `m[3]=='drinks tonight?'`, `m[4]=='go on then'`;
  system contains `'each assistant message is exactly what Robin sent back'`;
  generate_screen `content(1)=='pub?'`, `content(2)=='go on then'`;
  group chat `messages[1]['content']=='Sam: pub?\nAlex: yes'`. Replace the
  "asks for how you act" test with one asserting the system prompt does
  **not** contain `'Act like you too'` or `'Reference moments'`.
- [ ] **Step 2: Run** `flutter test test/reply_generator_test.dart test/generate_screen_test.dart test/group_chat_test.dart` — expect FAIL.
- [ ] **Step 3: Implement** — reinstate the example loop in
  `buildMessages`:

```dart
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
```

  restore the "How this chat is laid out" section with `hasExamples`, the
  voice-sample wording "Other messages $me has really sent, to hear the voice
  (not to copy):", the old `moreLikeMe` text, and drop the "Sounding like you
  is more than the words…" paragraph from `defaultSystemPrompt`. Openers and
  `rewriteMine` pass `hasExamples: false`.
- [ ] **Step 4: Run** the same tests — PASS.
- [ ] **Step 5: Commit** "Your real replies are turns again".

### Task 2: Leak guard

**Files:**
- Create: `lib/services/leak_guard.dart`
- Modify: `lib/services/reply_generator.dart` (`_bestDrafts`, `generate`, `refine`)
- Test: `test/leak_guard_test.dart`, `test/reply_generator_test.dart`

**Interfaces:**
- Produces: `LeakGuard.risky(List<StoredExchange> examples, List<ChatTurn> conversation, {Set<String> names}) → Set<String>`;
  `LeakGuard.leaks(String draft, Set<String> risky) → bool`.

- [ ] **Step 1: Tests**

```dart
test('names and numbers only the examples had are risky', () {
  final risky = LeakGuard.risky(
    [exchange(context: [turn('Maya', 'dinner with Josh at 8?')], reply: 'is Josh coming. Lisbon was fun')],
    [turn('Maya', 'what are you up to')],
    names: {'Robin', 'Maya'},
  );
  expect(risky, containsAll(['josh', '8', 'lisbon']));
  expect(risky, isNot(contains('dinner')));   // not capitalised
  expect(risky, isNot(contains('is')));       // sentence start
});
test('words the live chat already has are fine', () {
  final risky = LeakGuard.risky(
    [exchange(context: [turn('Maya', 'see Josh later')])],
    [turn('Maya', 'josh says hi')],
  );
  expect(risky, isNot(contains('josh')));
});
test('a draft leaks on a whole-word match, any case', () {
  expect(LeakGuard.leaks('tell josh hi', {'josh'}), isTrue);
  expect(LeakGuard.leaks('joshua is here', {'josh'}), isFalse);
  expect(LeakGuard.leaks('at 8 then', {'8'}), isTrue);
  expect(LeakGuard.leaks('anything', {}), isFalse);
});
test("I and I'm are never risky", () {
  expect(LeakGuard.risky([exchange(reply: "ok I'm in, and I said so")], []),
      isNot(anyOf(contains('i'), contains("i'm"))));
});
```

  And in `reply_generator_test.dart`: a `generate` with an example whose
  reply mentions "Josh" and a fake returning drafts `['say hi to Josh', 'sounds good']`
  keeps `'sounds good'` only; with drafts `['Josh?', 'Josh!']` both survive
  (all leak → unfiltered).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**

```dart
/// Spots drafts that bring in something only the retrieved examples had.
///
/// The examples are real moments from other times, put in as turns so the
/// model writes in your voice; the cost is that it may carry on from them —
/// a name, a place, a time. Words that could only have come from there are
/// collected, and drafts that use one are set aside.
class LeakGuard {
  const LeakGuard._();

  static final RegExp _word = RegExp(r"[\p{L}\p{N}][\p{L}\p{N}'’]*", unicode: true);
  static final RegExp _number = RegExp(r'^\d+(?:[:.]\d{2})?(?:am|pm)?$', caseSensitive: false);
  static final RegExp _sentenceEnd = RegExp(r'[.!?]\s*$');

  static Set<String> risky(List<StoredExchange> examples, List<ChatTurn> conversation, {Set<String> names = const {}}) {
    final out = <String>{};
    void scan(String text) {
      for (final line in text.split('\n')) {
        var start = true;
        for (final m in _word.allMatches(line)) {
          final w = m[0]!;
          final before = line.substring(0, m.start);
          final atStart = start || _sentenceEnd.hasMatch(before);
          start = false;
          if (RegExp(r"^I(?:$|['’])").hasMatch(w)) continue;
          final capital = w[0] != w[0].toLowerCase();
          if (_number.hasMatch(w) || (capital && !atStart)) out.add(w.toLowerCase());
        }
      }
    }
    for (final e in examples) {
      for (final t in e.context) { scan(t.text); }
      scan(e.replyText);
    }
    final live = conversation.map((t) => t.text).join('\n').toLowerCase();
    final liveWords = {for (final m in _word.allMatches(live)) m[0]!};
    out.removeWhere((w) => liveWords.contains(w));
    out.removeAll(names.map((n) => n.toLowerCase()));
    return out;
  }

  static bool leaks(String draft, Set<String> risky) {
    if (risky.isEmpty) return false;
    return _word.allMatches(draft.toLowerCase()).any((m) => risky.contains(m[0]));
  }
}
```

  `_bestDrafts` gains `Set<String> risky = const {}`: after cleaning,
  `final safe = cleaned.where((d) => !LeakGuard.leaks(d, risky)).toList();`
  and ranks `safe.isEmpty ? cleaned : safe`. `generate` computes
  `LeakGuard.risky(examples.map((e) => e.exchange).toList(), conversation, names: {settings.myName, settings.theirName})`
  once and passes it to both `_bestDrafts` calls. `refine` writes a single
  draft of a reply already chosen, so it is not filtered.
- [ ] **Step 4: Run** `flutter test test/leak_guard_test.dart test/reply_generator_test.dart` — PASS.
- [ ] **Step 5: Commit** "Drafts that borrow from other chats are set aside".

### Task 3: Analysis stops feeding; "Is it like me?" goes

**Files:**
- Modify: `lib/services/reply_generator.dart` (drop `facts`, `styleGuide`,
  `acting` params and sections; delete `judgeMine`, `StyleVerdict`)
- Modify: `lib/screens/generate_screen.dart`, `lib/screens/openers_screen.dart`,
  `lib/screens/check_screen.dart`
- Test: `test/analysis_test.dart`, `test/new_features_test.dart`,
  `test/explore_features_test.dart`, `test/generate_screen_test.dart`

- [ ] **Step 1: Tests** — delete the `the style guide` group and the
  `is it like me uses the saved guide` widget test in `analysis_test.dart`;
  delete `the reply writer is told the facts` in `explore_features_test.dart`;
  drop `facts:` from the openers test and its `Has an exam on Friday`
  expectation in `new_features_test.dart`. Turn
  `what is remembered about them goes to the writer` into
  `nothing from Analysis reaches the writer`: save facts **and** an
  `AnalysisStore` entry with `writing: ['Never apologises formally']`, write
  a reply, and assert the system prompt contains neither
  `'Biscuit'` nor `'Never apologises'`. Add to `analysis_test.dart` a
  widget test on `CheckScreen`: after entering text,
  `find.byKey(ValueKey('judge'))` finds nothing and `find.text('Is it like me?')` finds nothing.
- [ ] **Step 2: Run** — the new assertions FAIL (compile errors for removed params come in Step 3).
- [ ] **Step 3: Implement** — remove the parameters, the three prompt
  sections, `judgeMine`, `StyleVerdict`, `_judge`, `_verdict`, `_judging`,
  `_analyses`/`_analysisOf`, the judge `PaperAction`, `_Judgement`, the
  `_facts`/`_styleGuide`/`_acting` fields and their loads in the screens, and
  now-unused imports (`chat_analysis.dart`, `chat_facts.dart`, `dart:convert`
  if unused). Update the Check-screen footnote and title copy if they mention
  the judge.
- [ ] **Step 4: Run** `flutter analyze && flutter test` — PASS.
- [ ] **Step 5: Commit** "Analysis stays on its own screen; Is it like me goes".

### Task 4: README and version for Part 1

- [ ] Update README: Analysis paragraph (drop "Every reply, tweak, opener
  and rewrite for them follows both"), Check my message (drop **Is it like
  me?**), "How it works → Writing a reply" (examples go in as turns, leak
  guard, no guides/facts), test count from `flutter test`. Bump
  `pubspec.yaml` to `0.19.0+26`.
- [ ] Commit "README for 0.19.0".

## Part 2

### Task 5: `exclude` on retrieval and the voice sample

**Files:**
- Modify: `lib/services/style_memory_service.dart` (`retrieve`, `voiceSample`)
- Test: `test/style_memory_service_test.dart`

**Interfaces:**
- Produces: `retrieve({…, bool Function(StoredExchange)? exclude})`,
  `voiceSample({…, int count = 25, bool Function(StoredExchange)? exclude})`.

- [ ] **Step 1: Tests** — with a `MemoryExchangeStore` of two exchanges
  (reply 'secret' id 1, reply 'other' id 2) and a fake embed returning the
  same vector: `retrieve(exclude: (e) => e.id == 1)` returns only id 2;
  `voiceSample(chatIds: {1}, exclude: (e) => e.id == 1)` is `['other']`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — after `store.all(...)`, `candidates.removeWhere(exclude)` / skip rows where `exclude?.call(row) ?? false`.
- [ ] **Step 4: Run** — PASS. **Step 5: Commit** "Retrieval can leave moments out".

### Task 6: Blind test model and pure helpers

**Files:**
- Create: `lib/models/blind_test.dart` (data + JSON)
- Create: `lib/services/blind_test.dart` (pure statics now; `run` in Task 7)
- Test: `test/blind_test_test.dart`

**Interfaces:**
- Produces:

```dart
class BlindPrompt { const BlindPrompt({required this.label, required this.text}); final String label, text; }
class BlindPair {
  // context, real, generated, realIsA, judgePick ('A'|'B'|null = unreadable), why, userPick
  bool get judgeFooled;          // judgePick != null && (judgePick == 'A') != realIsA
  bool? get userFooled;          // null until played
}
class BlindPromptResult { BlindPrompt prompt; List<BlindPair> pairs; double get judgeFoolRate; double? get userFoolRate; }
class BlindRun { DateTime at; String replyModel; int promptVersion; List<BlindPromptResult> results; }
class BlindTestState { int seed; String tryThis; List<BlindRun> runs; }   // all with toJson/fromJson
class BlindTest {
  static const momentCount = 20, judgeSampleCount = 15;
  static const window = Duration(hours: 12);
  static List<StoredExchange> pickMoments(List<StoredExchange> all, {required String me, required int seed, int count = momentCount});
  static bool Function(StoredExchange) excluding(StoredExchange held);
  static String judgeSystem({required String me, required String them, required List<String> realReplies});
  static String judgeUser({required List<ChatTurn> context, required String me, required String a, required String b, bool group = false});
  static (String?, String) parseJudge(String raw);
  static bool clearlyDifferent(int n, double a, double b);
  static String report(BlindRun run, {required String them, bool scoresOnly = false});
  static int calls({required int moments, required int prompts}); // moments * (1 + 2 * prompts)
}
```

`ReplyGenerator.promptVersion` (int, starts at 2 — 1 was the
reference-moments prompt) is added in this task.

- [ ] **Step 1: Tests**
  - `pickMoments`: same seed → same ids; different seed → different order;
    skips `source == saved`, replies of length 1 or > 160, moments whose
    last context turn is `me`, and empty contexts; returns ≤ count.
  - `excluding`: with timestamps, an exchange 11 h later is excluded and
    13 h later is not; another chat never is; without timestamps, id ±10 is
    excluded and +11 is not.
  - `parseJudge`: `'{"pick":"B","why":"too keen"}'` → `('B','too keen')`;
    a fenced block and leading prose parse the same; `'b'` lower case reads
    as `'B'`; garbage → `(null, '')`.
  - Fool rates: 3 pairs, judge fooled on 1 → `1/3`; unreadable counts as
    not fooled; `userFoolRate` null until every pair has a `userPick`.
  - `clearlyDifferent(20, 0.10, 0.45)` true; `(20, 0.30, 0.40)` false;
    `(20, 0, 0)` false.
  - `report`: contains each label, both rates as percentages, the miss lines
    with "You:", "Generated:", "Judge:"; with `scoresOnly` it contains no
    prompt text, no context and no replies.
  - JSON round-trip of a `BlindTestState` with one run.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — pick: filter, sort by id for stability, then
  `..shuffle(Random(seed))`, take count. Close call: pooled two-proportion
  z-test; return false when the pooled rate is 0 or 1. Judge system prompt:

```
You are shown a moment from a chat between {me} and {them}, and two
messages, A and B. One is what {me} really sent next; the other was
written by someone imitating {me}. Decide which one {me} really sent.

Real messages {me} has sent {them} at other times, to know how {me} texts:
- …

Answer only with JSON: {"pick": "A" or "B", "why": "<one short line: what gave the other one away>"}
```

  Judge user message: the context via the same `(you)` marking as
  `ReplyGenerator.buildUserPrompt`, then `\n\nA: …\nB: …`.
- [ ] **Step 4: Run** — PASS. **Step 5: Commit** "Blind test: moments, judging and scores".

### Task 7: `BlindTest.run` and the store

**Files:**
- Modify: `lib/services/blind_test.dart` (instance with `openai`, `memory`, `generator`; `run`)
- Create: `lib/services/blind_test_store.dart`
- Modify: `lib/state/providers.dart` (`blindTestStoreProvider`,
  `blindTestProvider` (nullable like the others), clear in delete-all and in
  `ChatsNotifier.delete`)
- Test: `test/blind_test_test.dart`

**Interfaces:**

```dart
class BlindTest {
  BlindTest({required this.memory, required this.generator, required this.openai});
  Future<BlindRun> run({
    required ChatMemory chat,
    required AppSettings settings,     // named for the chat
    required List<BlindPrompt> prompts,
    required int seed,
    void Function(double progress)? onProgress,
    bool Function()? cancelled,
  });
}
class BlindTestStore { load(); forChat(int); save(int, BlindTestState); remove(int); clear(); }  // key 'ditto_blind_test_v1'
```

- [ ] **Step 1: Tests** — with a `MemoryExchangeStore` of 25 exchanges
  (timestamps a day apart, distinct replies) and a fake that answers
  generation with `'generated'` and judge calls (detected by
  `body['response_format'] != null`) with `{"pick":"A","why":"x"}`:
  `run` with two prompts returns 2 results × 20 pairs; generation requests
  carry each prompt's text as the start of the system message; no
  generation request contains the held-out reply in any message; progress
  reaches 1.0. Store round-trip, `remove`, and `clear`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `run`: `rows = await memory.store.all(chatIds: {chat.id})`;
  `moments = pickMoments(rows, me: settings.myName, seed: seed)`; throw an
  `OpenAiException(badRequest, 'Not enough of your replies…')` if fewer than
  5. For each moment (index i): `exclude = excluding(m)`;
  `retrieved = await memory.retrieve(context: m.context, …, chatIds: {chat.id}, preferChatId: chat.id, queryTurns: settings.contextTurns, exclude: exclude)`;
  `voice = await memory.voiceSample(chatIds: {chat.id}, preferChatId: chat.id, exclude: exclude)`;
  `judgeSample = voice.take(judgeSampleCount)`; then per prompt:
  `generator.generate(conversation: m.context, examples: retrieved.examples, settings: settings.copyWith(systemPrompt: p.text, variantCount: 1), profile: chat.profile, voiceSample: voice, group: chat.isGroup)`,
  `realIsA = Random(seed + i).nextBool()`, judge via
  `openai.chat(model: settings.generationModel, jsonMode: true, temperature: 0, messages: …)`.
  Check `cancelled` between calls and throw `TaskCancelled`.
- [ ] **Step 4: Run** — PASS. **Step 5: Commit** "Blind test runs against your chat".

### Task 8: Blind test screen and the Home menu item

**Files:**
- Create: `lib/screens/blind_test_screen.dart`
- Modify: `lib/screens/home_screen.dart` (menu item `'blind'` → push screen)
- Test: `test/blind_test_screen_test.dart`

Screen layout (Paper widgets), keys in brackets:
- `ScreenBar('Blind test')`, a short explainer `Notice`.
- Prompts: switch rows for **Built-in** (always on), **Yours** (only when
  `settings.hasCustomSystemPrompt`), **Try this** [`try-this-switch`] with a
  `ComposeField` [`try-this-field`] saved to the store on change.
- Run `PaperAction` [`run`] with subtitle
  `'${BlindTest.calls(...)} calls · ${settings.generationModel}'`; starts
  `TaskCenter.start(id: 'blind-test-${chat.id}', …)`; the work saves the run
  to the store; the screen re-reads the store when the task finishes.
  **New moments** [`new-moments`] sets a new random seed.
- Latest run: per prompt a card [`score-<label>`] with judge fool rate
  ("Passed as you in 7 of 20"), user rate when played, and a verdict line
  versus Built-in: "Clearly better" / "Clearly worse" / "Too close to
  call — try New moments". **Use this prompt** [`use-<label>`] on a
  non-built-in prompt that is clearly better saves it via
  `settingsProvider.notifier.edit((s) => s.copyWith(systemPrompt: text))`.
- Misses per prompt, collapsible: context, "You:", "Generated:", "Judge:".
- **Spot the real one** [`play`]: one pair at a time, two bubbles A/B
  [`pick-A`/`pick-B`], skip [`play-done`]; saves `userPick`s.
- **Copy results** [`copy`] opens a `PaperDialog` warning "The full results
  include real lines from your chat." with **Copy everything**
  [`copy-all`] and **Scores only** [`copy-scores`] → `Clipboard.setData`.
- Past runs list: date, version, best fool rate.

- [ ] **Step 1: Widget tests** — with a saved state holding one run (two
  prompts, a miss each): scores and verdict text show; `copy` → `copy-scores`
  puts text on the clipboard without reply text; `play` → `pick-A` ×n saves
  user picks; the Home menu shows "Blind test…" and opens the screen.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `flutter analyze && flutter test` — PASS.
- [ ] **Step 5: Commit** "Blind test screen".

### Task 9: README and version for Part 2

- [ ] README: a **Blind test** bullet in What it does, a paragraph under
  How it works, privacy line (judge sees moments from the chat), test count,
  project layout. Bump to `0.20.0+27`. Commit.
