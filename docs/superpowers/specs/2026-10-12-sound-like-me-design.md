# Sounding like you: show, don't describe, and a blind test

Date: 2026-10-12

## Problem

Replies read as a believable human, but not as the user. Three symptoms,
across big and small chats: generic content, the wrong energy (keener,
nicer or more curious than the user is), and a caricature effect (the
user's slang and phrases over-applied). The user's sense is that replies
were better before `a4116c5` ("Replies act like you, and past chats are
reference only").

Likely causes:

- The model is mostly *told about* the user (How you write / How you act
  bullets with quoted phrases, habit numbers, a 25-line voice sample), which
  invites an impression.
- Since `a4116c5`, real past exchanges sit in a labelled "reference moments"
  block the model must never mention, rather than as turns it has itself
  "sent". Voice is copied best from turns in the same format as the output.
- Nothing measures whether a change helps.

## Part 1 — Replies (do first)

### 1.1 Examples back as turns

`ReplyGenerator.buildMessages` returns, as before `a4116c5`:

1. the system prompt;
2. for each retrieved example, least similar first: a `user` message with
   their side of the context (`_theirSide`, named in groups) and an
   `assistant` message with the user's real reply;
3. the live chat as the final `user` message.

`buildSystemPrompt`:

- takes `bool hasExamples` again instead of `List<ScoredExchange> examples`;
- restores the pre-`a4116c5` layout section ("How this chat is laid out:
  each user message is … each assistant message is exactly what {me} sent
  back", plus the "earlier pairs are real moments … the last pair is the
  closest" sentence when there are examples);
- drops the "Reference moments" block and `_moment`;
- restores the voice-sample wording "Other messages {me} has really sent, to
  hear the voice (not to copy):".

`Refinement.moreLikeMe` goes back to "Rewrite it to match the examples and
the measured habits more closely — their length, casing, punctuation, slang
and emoji — even if that makes it rougher."

`AppSettings.defaultSystemPrompt` loses the "Sounding like you is more than
the words. Act like you too: …" paragraph added in `a4116c5`.

Openers and the Check-my-message rewrite keep passing `hasExamples: false`
(they send no example turns).

### 1.2 Leak guard

New `lib/services/leak_guard.dart`, pure and separately tested.

- `LeakGuard.risky(examples, conversation)` returns the set of words, in
  lower case, that could only have come from the examples:
  - capitalised words in the examples' context and reply text that are not
    the first word of a line or sentence, and are not "I" / "I'm" etc.;
  - numbers and times (`\d+`, `\d{1,2}[:.]\d{2}`, `\d+(am|pm)`);
  - minus any that appear (case-insensitively) anywhere in the live
    conversation, and minus the names `{me}` / `{them}`.
- `LeakGuard.leaks(draft, risky)` is true when the draft contains any risky
  word as a whole word, case-insensitively.

`ReplyGenerator._bestDrafts` takes the risky set: drafts that leak are set
aside before ranking. If every draft leaks, the unfiltered drafts are used
(a reply beats none). `generate` and `refine` compute the set from their
examples and conversation; openers and rewrite pass an empty set.

### 1.3 Analysis no longer feeds other features

- `ReplyGenerator.generate`, `refine`, `openers`, `rewriteMine` and
  `buildMessages` / `buildSystemPrompt` lose the `facts`, `styleGuide` and
  `acting` parameters and their prompt sections.
- `generate_screen.dart`, `openers_screen.dart` and `check_screen.dart` stop
  reading `analysisStoreProvider` and `factsStoreProvider`.
- The Analysis screen, `ChatAnalyst`, `ChatFacts`, their stores, and what
  the Analysis screen shows are unchanged.

### 1.4 "Is it like me?" removed

`ReplyGenerator.judgeMine`, `StyleVerdict`, the button, verdict UI and
state in `check_screen.dart`, and their tests are deleted. Check my message
keeps the stats comparison, quick fix and rewrite.

### 1.5 Docs

README: the feature list (Analysis, Check my message), "How it works →
Writing a reply", test count, and version bump.

## Part 2 — Blind test (after Part 1)

A per-chat screen that scores how often generated replies pass as the user's
own, for up to three prompts at once on the same moments, so prompts can be
compared.

### 2.1 Entry

A **Blind test…** item in each chat's menu on Home, next to *Choose
dates…*, opening `lib/screens/blind_test_screen.dart`.

### 2.2 Moments

`BlindTest.pickMoments(exchanges, seed, count = 20)`:

- candidates: `source == export`, last context turn not the user's, reply
  length 2–160 characters, within the chat's chosen dates (the store already
  filters `all()` by them);
- shuffled with `Random(seed)`, first `count` taken;
- the seed is saved per chat; **New moments** replaces it.

### 2.3 Prompts compared

Up to three, each optional except Built-in:

- **Built-in** — `AppSettings.defaultSystemPrompt`;
- **Yours** — the Settings prompt, offered only when it differs;
- **Try this** — a text box on the screen, remembered per chat, prefilled
  empty; never changes what replies use.

The screen shows the call count before running
(`moments × prompts × 3`).

### 2.4 Generating as if live

For each moment and prompt, the real pipeline runs with these differences:

- the conversation is the moment's stored context;
- retrieval and the voice sample exclude the held-out exchange and every
  exchange from the same chat within 12 hours of it (±10 row ids when there
  is no timestamp). `StyleMemoryService.retrieve` and `voiceSample` gain an
  `exclude` predicate;
- one reply: `variantCount: 1` (no new-topic option), top-ranked draft,
  via drafts → conformer → leak guard → rank;
- the system prompt template is the prompt under test.

The embedding of a moment is made once and shared across prompts.

### 2.5 Scoring

**Judge.** One call per moment and prompt. System: who the user is and
that the task is to spot which of two messages the user really sent,
followed by ~15 of the user's real replies in this chat from outside the
excluded window. User message: the context, then `A:` and `B:` in an order
from `Random(seed + moment index)`. It answers JSON
`{"pick":"A"|"B","why":"…"}`; parsing tolerates code fences and stray text,
and an unreadable answer counts as "spotted" (the conservative side) and is
marked.

**You.** After a run, optional "Which did you send?" cards, one per moment
and prompt, A/B in the same order. Skippable at any point.

**Fool rate** = share of moments where the generated reply was picked. Per
prompt, from the judge, and from the user when they played.

**Too close to call.** Two prompts' judge fool rates are called "clearly
different" only when a two-proportion test on the same n gives p < 0.1;
otherwise "too close to call — try New moments".

### 2.6 Running

A background job through `TaskCenter` (`id: blind-test-<chatId>`), with
progress per completed moment. Cancel keeps nothing. Errors on one moment
fail the job, like other jobs.

### 2.7 Results, history and sharing

`BlindTestStore` (SharedPreferences, like `AnalysisStore`): per chat, the
seed, the Try-this text, and the runs. A run holds: time, reply model,
judge model, `ReplyGenerator.promptVersion` (a constant bumped when the
built-in prompt changes), and per prompt: its label and text, judge fool
rate, user fool rate (nullable), and each pair (context, real, generated,
which side was real, judge pick and reason, user pick).

Cleared by "Delete all my data" and when the chat is deleted.

The screen shows: the Run panel (prompts, call count), the latest run's
scores per prompt with the close-call verdict, its misses per prompt
(context, your reply, generated, judge's reason), past runs as a list, and
**Use this prompt** on a non-built-in prompt that beat Built-in, which
saves it as the Settings prompt.

**Copy results** puts a plain-text report on the clipboard: per prompt, its
label, the prompt text, the fool rates, then the misses. A line at the top
of the sheet warns that misses contain real chat lines, with a **Scores
only** option that leaves the pairs and prompt text out.

### 2.8 Tests

Moment picking (seed is deterministic, filters), the exclusion window, the
judge prompt and lenient parsing, fool rates and the close-call test, the
store round-trip and deletion, the report text in both forms, and a widget
test of the screen with a fake service.

## Out of scope

- Automatic prompt search.
- Facts about the user themselves.
- Changing retrieval, the conformer or ranking.
