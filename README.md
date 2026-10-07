# Ditto

A Flutter app (Android + iOS) that writes replies in *your* texting style,
learned from your own WhatsApp and Instagram chats. Screenshot the
conversation you're in, and it suggests what you'd send next.

Your chats stay on the phone. The only things that leave it are calls to the
AI provider you choose (OpenAI, Claude or Gemini), made with your own key.

---

## What it does

- **Learns your voice per person.** Import a chat export and it learns every
  reply you sent in it: your length, casing, emoji, slang and the bubbles you
  split messages into. Each person is their own chat, because how you text a
  date is not how you text your boss.
- **Writes replies.** Tap a chat on the home screen (or **Write a reply**),
  pick a screenshot or paste the messages, check what it read, and get three
  options: two that answer what was said and one that moves the conversation
  on. Tweak any of them (*Shorter*, *Warmer*, *More like me*), copy it a bubble
  at a time, or star it to teach the chat something new.
- **Analysis.** Per chat, a model reads a sample of the whole history and
  writes **How you write**: a guide to how you text that person, with your
  own phrases quoted. Every reply, tweak, opener and rewrite for them
  follows it. Alongside: how you act, how they act, what goes on between
  you, and things they've told you worth remembering.
- **Search.** Find a moment by describing it in your own words ("that place
  she wanted to go"). One embedding call; the ranking happens on the phone,
  using a tight fingerprint of each moment, keyword scoring (BM25), and only
  showing moments that clearly stand out from the rest.
- **Ask your chats.** Ask a question ("when did we first talk about
  moving?") and get a short answer citing the moments it came from.
- **Start a chat.** When a chat has gone quiet, openers in your voice that
  follow up on how it ended and what you know about them.
- **Check my message.** Paste a message you wrote: it's compared with how
  you usually text that person (length, capitals, full stops, emoji,
  questions, bubbles), with a free quick fix. **Is it like me?** has the
  model score it against your How you write guide, your numbers and real
  messages; the rewrite follows the guide too.
- **How it's going.** Month by month: how much you each write, how fast they
  answer, who starts conversations, and whether it's warming up or cooling
  off. Counted on the phone, no API calls.
- **Chat groupings.** Groups your replies by what was being talked about,
  names each group, draws them on a map, and shows how topics change over
  time.
- **Chat data.** Reply times, who texts first, double texts, busiest days,
  favourite words and emoji. Counted on the phone, no API calls.

Long jobs (importing, Analysis, groupings) run in the background with a
progress tray at the bottom of every screen. You can leave the screen or
switch apps; on Android a "Ditto is working" notification keeps the job
alive until it finishes.

Chats from Instagram are drawn in Instagram's colours (purple-to-blue and
grey), WhatsApp chats in WhatsApp's green and white.

---

## Getting started

1. **Add a key.** Paste an OpenAI (`sk-…`), Claude (`sk-ant-…`) or Gemini
   (`AIza…`) key. The app tells which it is, checks it once, and stores it in
   the phone's keystore. Add the others later in **Settings → API keys**.
2. **Import a chat.** Export it from WhatsApp or Instagram (see below), then
   share it to Ditto or pick the file. Pick which name is you. Importing a
   newer export of the same chat only sends the replies it hasn't seen.
3. **Reply.** Tap the person's chat on the home screen and add a screenshot.

### Which key does what

| | OpenAI | Claude | Gemini |
|---|---|---|---|
| Write replies, read screenshots | yes | yes | yes |
| Learn chats, Search (fingerprints) | yes | **no** | yes |
| Fine-tuning | yes | no | no |

Claude has no embeddings API, so learning chats needs an OpenAI or Gemini key
alongside it. A model's name decides who runs it: `claude-…` goes to Claude,
`gemini-…` to Gemini, anything else to OpenAI. Adding or removing a key moves
any model whose provider has no key to one that does.

---

## Exporting a chat

The same steps are shown in the app, on the add-a-chat screen.

**WhatsApp:** open the chat → tap the name at the top (iPhone) or the three
dots → *More* (Android) → **Export chat** → **Without media**. Share it to
Ditto, or save the `.txt` / `.zip` and pick it.

**Instagram:** profile → menu (three lines) → **Accounts Center** → **Your
information and permissions** → **Download your information** → **Some of
your information** → tick only **Messages** → **Download to device**, format
**JSON** (not HTML), date range **All time**, media quality **Low**. When
Instagram says it's ready, download the `.zip` and pick it; Ditto lists the
conversations inside, newest first, and asks which one to learn. Keep the zip
to add another person later.

**Group chats** work too: pick yourself from the members, and every reply you
sent in the group is learned, with who said what kept in the context.

### What the parsers handle

| | |
|---|---|
| WhatsApp layouts | Android (`12/03/2023, 19:45 - Alice: hi`) and iOS (`[12/03/2023, 19:45:12] Alice: hi`); 12/24-hour clocks, day/month/ISO dates, multi-line messages, bidi marks |
| WhatsApp extras | media placeholders, deleted and edited messages, system lines |
| Instagram | `messages/inbox/<chat>/message_N.json` (older and newer export layouts), long chats split over several files, newest-first ordering, and Instagram's broken text encoding (`cafÃ©`, mangled emoji) repaired |
| Instagram extras | likes, reactions, shared posts and reels, calls, unsent messages and group events told apart from what was typed |

Media, deleted and system messages are kept out of learning. Consecutive
messages from one sender merge into one turn (split again after an hour's
gap).

---

## How it works

**Learning (style memory).** Each `their turn(s) → my reply` pair becomes an
exchange. Its context (the last 10 turns) is fingerprinted once with an
embedding model and stored in a local SQLite database under its chat, with a
content hash so re-imports skip what's already there. The import also
measures your habits: reply length, lowercase starts, full stops, emoji,
questions, multi-bubble replies and phrases you repeat.

**Writing a reply.** The conversation is fingerprinted and matched against
your chat with that person (or all your chats, if you turn on **Also learn
from my other chats** in the *Replying to* sheet, or reply to *Someone
else*). Retrieval takes a shortlist by similarity, then picks varied
examples, nudged towards recent ones. Those real exchanges go into the
request as actual turns of the conversation, closest last, and the model is
told it *is* you texting that person, with your measured habits, a sample of
your recent messages, your How you write guide, facts from Analysis, and your note ("say I'll be
late"). Several drafts come back in one request; each is held to your habits
where the numbers are clear (no capitals you never use, no emoji if you send
none) and the most typical are kept.

**Fine-tuning (optional, OpenAI only, costs money).** The same exchanges can
be uploaded as JSONL to train a model; the app shows the cost and asks you to
confirm the amount first. OpenAI is retiring fine-tuning: new organisations
can't start jobs since May 2026, and existing ones lose access in January
2027. Style memory needs no training and is usually just as convincing.

**Staying alive in the background.** Android can pause, kill or drop the
screen of a backgrounded app. Ditto:
- starts a foreground service (with a notification) while any job or request
  is running;
- keeps its Flutter engine in the app process rather than the screen, so
  Android closing the screen doesn't end running jobs;
- retries a request whose connection dropped while the app was away, waiting
  for it to come back to the front if needed.

iOS has no equivalent; there, an interrupted request retries when you return
to the app.

---

## Settings

| Setting | Default | Notes |
|---|---|---|
| API keys | none | One each for OpenAI, Claude and Gemini. |
| Reads screenshots | `gpt-5.6-terra` | Any vision-capable model; Claude: `claude-opus-5-5`, Gemini: `gemini-3.8-flash`. |
| Writes replies | `gpt-5.6-terra` | Same choices. |
| Fingerprints the memory | `text-embedding-3-small` | Or `gemini-embedding-001`. Changing it means re-importing. |
| Fingerprint size | 512 | Smaller is a smaller, faster memory. |
| Mode | Style memory | Or fine-tuned (OpenAI). |
| Context turns | 10 | How much conversation is used. |
| Retrieved examples | 8 | Past exchanges the model is shown. |
| Reply options | 3 | |
| The prompt | built-in | Editable; `{me}` and `{them}` become the names. |
| Chat prices | unset | For the spending tally. |

**Load** in Settings pulls the model ids your keys can actually use, since
model names change. **Spending** shows tokens used per month by kind, from the
figures each provider returns. **Delete all my data** removes everything the
app stored, optionally including the keys.

---

## Privacy

- Keys live only in the platform keystore (Keychain / encrypted storage).
  They are never logged, committed or put in an error message.
- Chats, fingerprints, facts, groupings and settings live only in app-private
  storage on the phone.
- What is sent to your AI provider: the text being fingerprinted when
  importing (and a search query), the screenshot you pick, the prompt when
  writing a reply, a sample of the chat when you run Analysis, and a
  few short samples per group when naming groupings. Nothing goes anywhere
  else.
- `.gitignore` blocks `*.txt`, `*.zip` and `*.jsonl` outside `test/fixtures/`,
  so a WhatsApp export can't be committed by accident. Instagram's `.json`
  files aren't blocked: keep them out of the repo folder.

---

## Building

### Requirements

- Flutter 3.47 (Dart `^3.12.0`)
- Android (Flutter's default minimum) / iOS 15+
- An API key with credit on it

```bash
git clone https://github.com/tomtom88888/ChatingTools.git
cd ChatingTools
flutter pub get
flutter test          # 372 tests, no network or device needed
flutter run
```

The bundle id is still `com.example.replylikeme`, the working title, so
updates install over earlier builds without losing data. Change it before
publishing (`android/app/build.gradle.kts`, the Kotlin package folder, and
`PRODUCT_BUNDLE_IDENTIFIER` in the iOS project); installed copies then need a
reinstall.

### APKs and releases

The [Build APK workflow](.github/workflows/build-apk.yml) runs `analyze`,
`test` and `build apk` on every push; the APK is attached to the run under
**Artifacts**. Pushes never publish a release. To publish one, start the
workflow by hand (**Actions → Build APK → Run workflow**); it creates a
GitHub release tagged `v<version>-<commit>` with a plain download link. Untick
**prerelease** for a full release.

Release builds are signed with `android/app/sideload.keystore` (password
`sideload`), committed on purpose so every build signs the same and one APK
installs over another. It is **not** a real release key: replace it before
publishing anywhere.

If Android says "App not installed", the copy on the phone was signed with a
different key (uninstall once and reinstall), or you picked an APK for the
wrong CPU (`app-arm64-v8a-release.apk` fits nearly every phone;
`app-release.apk` fits all).

### iOS share sheet (optional)

Sharing *into* the app on iOS needs a Share Extension target made in Xcode
(**File → New → Target → Share Extension**), an App Group shared with Runner
set as `CUSTOM_GROUP_ID`, and the steps in the
[receive_sharing_intent](https://pub.dev/packages/receive_sharing_intent)
README. The file picker works without it.

---

## Project layout

```
lib/
  main.dart                  app, theme, task tray and chat-colour scopes
  models/                    settings, providers and keys, chats, exchanges,
                             style profile, chat stats, usage, feedback
  services/
    whatsapp_parser.dart     WhatsApp .txt -> messages, turns, exchanges
    instagram_parser.dart    Instagram JSON -> the same, with text repair
    chat_export_reader.dart  .txt / .json / .zip -> WhatsApp text or threads
    openai_service.dart      one client for OpenAI, Claude and Gemini:
                             chat, vision, embeddings, fine-tuning, retries
    style_memory_service.dart   import, retrieval, saving starred replies
    embeddings_store.dart    SQLite style memory, with schema upgrades
    retrieval.dart           shortlist, variety, recency
    reply_generator.dart     prompts, drafts and tweaks
    style_conformer.dart     holds drafts to your habits
    chat_facts.dart          things to remember (Analysis)
    chat_analysis.dart       How you write, and how you both act
    chat_search.dart         Search
    chat_groupings.dart      groupings, plus group_map and topic_timeline
    finetune_service.dart    JSONL, cost estimate, job polling
    secure_key_store.dart    the API keys
  state/
    providers.dart           Riverpod providers
    tasks.dart               background jobs and their tray
    keep_awake.dart          Android foreground service while work runs
    app_activity.dart        notices the app leaving and returning
  screens/                   setup, home, import, reply, search, remember,
                             groupings, chat data, settings, fine-tune
  theme/                     palettes, type, and per-app bubble colours
  widgets/                   shared UI kit, export guides, job cards, tray
android/.../MainActivity.kt  keeps the Flutter engine beyond the screen
test/                        372 unit and widget tests
test/fixtures/               invented Android and iOS exports
docs/business-plan.txt       backlog: how it could be sold one day
```

## Tests

```bash
flutter test
```

372 tests, none needing a network or device. They cover both parsers
(including Instagram's encoding repair and multi-file threads), the
OpenAI/Claude/Gemini request and response shapes, error mapping, retries and
resuming after the app was away, retrieval and the vector maths, prompt
building, Analysis, Search and groupings, the SQLite store and its upgrades
(against real SQLite via `sqflite_common_ffi`), background jobs and the tray,
and widget tests that boot the real app: setup and key checks, home,
settings, importing, and the whole reply flow.
