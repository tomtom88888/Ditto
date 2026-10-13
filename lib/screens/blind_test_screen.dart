import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/blind_test.dart';
import '../models/chat_turn.dart';
import '../models/stored_exchange.dart';
import '../services/blind_test.dart';
import '../state/providers.dart';
import '../state/tasks.dart';
import '../theme/bubbles.dart';
import '../theme/tokens.dart';
import '../widgets/background_job_card.dart';
import '../widgets/bidi.dart';
import '../widgets/compose_field.dart';
import '../widgets/failure_text.dart';
import '../widgets/format.dart';
import '../widgets/paper_dialog.dart';
import '../widgets/paper_ui.dart';

/// How often replies written in your place pass for your own, in one chat,
/// for up to three prompts side by side. See [BlindTest].
class BlindTestScreen extends ConsumerStatefulWidget {
  const BlindTestScreen({required this.chat, super.key});

  final ChatMemory chat;

  static String taskId(ChatMemory chat) => 'blind-test-${chat.id}';

  @override
  ConsumerState<BlindTestScreen> createState() => _BlindTestScreenState();
}

class _BlindTestScreenState extends ConsumerState<BlindTestScreen> {
  final _tryThis = TextEditingController();
  BlindTestState? _state;
  bool _useYours = true;
  bool _useTry = false;
  BlindKind _kind = BlindKind.replies;

  /// Which prompts' misses are open.
  final Set<String> _open = {};

  /// Where "Spot the real one" is: a prompt's index, then a pair's.
  (int, int)? _playing;

  ChatMemory get chat => widget.chat;
  String get them => chat.theirName.isEmpty ? 'them' : chat.theirName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tryThis.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final store = ref.read(blindTestStoreProvider);
    var state = await store.forChat(chat.id);
    if (state == null) {
      state = BlindTestState(seed: _newSeed());
      await store.save(chat.id, state);
    }
    if (!mounted) return;
    setState(() {
      if (_state == null) {
        _tryThis.text = state!.tryThis;
        _useTry = state.tryThis.trim().isNotEmpty;
      }
      _state = state;
    });
  }

  static int _newSeed() => math.Random().nextInt(1 << 31);

  Future<void> _save(BlindTestState next) async {
    setState(() => _state = next);
    await ref.read(blindTestStoreProvider).save(chat.id, next);
  }

  List<BlindPrompt> _prompts(AppSettings settings) => [
    const BlindPrompt(
      label: BlindPrompt.builtIn,
      text: AppSettings.defaultSystemPrompt,
    ),
    if (settings.hasCustomSystemPrompt && _useYours)
      BlindPrompt(label: BlindPrompt.yours, text: settings.systemPrompt!),
    if (_useTry && _tryThis.text.trim().isNotEmpty)
      BlindPrompt(label: BlindPrompt.tryThis, text: _tryThis.text.trim()),
  ];

  /// Runs the test as a background job: it carries on if the screen is left.
  void _run(AppSettings settings) {
    final tester = ref.read(blindTesterProvider);
    final state = _state;
    if (tester == null || state == null) return;
    final store = ref.read(blindTestStoreProvider);
    final prompts = _prompts(settings);
    final named = settings.copyWith(
      myName: chat.myName.isEmpty ? 'Me' : chat.myName,
      theirName: chat.theirName.isEmpty ? 'Them' : chat.theirName,
    );
    setState(() => _playing = null);
    ref
        .read(taskCenterProvider.notifier)
        .start(
          id: BlindTestScreen.taskId(chat),
          title: _kind == BlindKind.openers
              ? 'Opener blind test with $them'
              : 'Blind test with $them',
          detail: 'Picking moments',
          work: (task) async {
            void progress(int done, int of) => task
              ..check()
              ..report(
                detail: 'Moment ${math.min(done + 1, of)} of $of',
                progress: of == 0 ? null : done / of,
              );
            final run = _kind == BlindKind.openers
                ? await tester.runOpeners(
                    chat: chat,
                    settings: named,
                    prompts: prompts,
                    seed: state.seed,
                    onProgress: progress,
                  )
                : await tester.run(
                    chat: chat,
                    settings: named,
                    prompts: prompts,
                    seed: state.seed,
                    onProgress: progress,
                  );
            task.check();
            final current =
                await store.forChat(chat.id) ??
                BlindTestState(seed: state.seed);
            await store.save(chat.id, current.adding(run));
            return null;
          },
        );
  }

  Future<void> _copy(BlindRun run) async {
    Future<void> copy({required bool scoresOnly}) async {
      Navigator.of(context).pop();
      await Clipboard.setData(
        ClipboardData(
          text: BlindTest.report(run, them: them, scoresOnly: scoresOnly),
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(scoresOnly ? 'Scores copied' : 'Results copied'),
        ),
      );
    }

    await showDialog<void>(
      context: context,
      builder: (_) => PaperDialog(
        title: 'Copy results',
        confirmLabel: 'Copy everything',
        onConfirm: () => copy(scoresOnly: false),
        extraLabel: 'Scores only',
        onExtra: () => copy(scoresOnly: true),
        child: Text(
          'Everything includes the prompts and the moments that gave a reply '
          'away, which are real lines from your chat with ${bidiIsolate(them)}. '
          'Scores only leaves all of that out.',
          style: Type.prose(size: 14, color: Paper.body, height: 1.45),
        ),
      ),
    );
  }

  Future<void> _usePrompt(BlindPrompt prompt) async {
    await ref
        .read(settingsProvider.notifier)
        .edit((s) => s.copyWith(systemPrompt: prompt.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Replies now use "${prompt.label}"')),
    );
  }

  /// Records your guess for the pair being played and moves on.
  Future<void> _pick(String side) async {
    final state = _state;
    final at = _playing;
    final run = state?.runsOf(_kind).firstOrNull;
    if (state == null || run == null || at == null) return;
    final (r, p) = at;
    final result = run.results[r];
    final pairs = [...result.pairs]..[p] = result.pairs[p].withUserPick(side);
    final results = [...run.results]..[r] = result.withPairs(pairs);
    final index = state.runs.indexOf(run);
    final next = state.copyWith(
      runs: [...state.runs]..[index] = run.withResults(results),
    );
    setState(() => _playing = _after(results, r, p));
    await _save(next);
  }

  /// The next pair not yet guessed, or `null` when every one has been.
  static (int, int)? _after(List<BlindPromptResult> results, int r, int p) {
    for (var i = r; i < results.length; i++) {
      for (var j = i == r ? p + 1 : 0; j < results[i].pairs.length; j++) {
        if (results[i].pairs[j].userPick == null) return (i, j);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final hasKey = ref.watch(blindTesterProvider) != null;
    final tasks = ref.watch(taskCenterProvider);
    final task = tasks
        .where((t) => t.id == BlindTestScreen.taskId(chat))
        .firstOrNull;
    final busy = task?.running ?? false;
    ref.listen(taskCenterProvider, (before, now) {
      final id = BlindTestScreen.taskId(chat);
      final t = now.where((t) => t.id == id).firstOrNull;
      final was = before?.where((b) => b.id == id).firstOrNull;
      if (t?.status == TaskStatus.done && was?.status != TaskStatus.done) {
        _load();
      }
    });

    final state = _state;
    final runs = state?.runsOf(_kind) ?? const <BlindRun>[];
    final latest = runs.firstOrNull;
    final prompts = _prompts(settings);
    final calls = BlindTest.calls(
      moments: BlindTest.momentCount,
      prompts: prompts.length,
      kind: _kind,
    );
    final openers = _kind == BlindKind.openers;

    return PaperScreen(
      children: [
        ScreenBar(
          title: 'Blind test',
          onBack: () => Navigator.of(context).pop(),
        ),
        SerifTitle(
          'Would ',
          accent: bidiIsolate(them),
          trailing: ' know?',
          size: 32,
        ),
        _KindPicker(
          kind: _kind,
          onPick: busy || _playing != null
              ? null
              : (kind) => setState(() => _kind = kind),
        ),
        Text(
          openers
              ? 'Takes ${BlindTest.momentCount} times you started this chat '
                    'again after ${BlindTest.minQuiet.inHours}+ hours of '
                    'quiet, and writes an opener in your place, told what '
                    'you brought up but none of your words. A judge then '
                    'guesses which one you sent.'
              : 'Takes ${BlindTest.momentCount} real moments from this chat, '
                    'hides what you replied, and writes a reply in your '
                    'place. A judge then sees both and guesses which one you '
                    'sent. Passing as you about half the time means it '
                    'couldn\'t tell.',
          style: Type.prose(size: 14, color: Paper.body, height: 1.45),
        ),
        if (state == null) const LinearProgressIndicator(minHeight: 3),
        if (_playing != null && latest != null)
          _Play(
            run: latest,
            at: _playing!,
            app: chat,
            onPick: _pick,
            onDone: () => setState(() => _playing = null),
          )
        else ...[
          const MonoLabel('Prompts to compare'),
          _PromptSwitch(
            key: const ValueKey('built-in-switch'),
            title: BlindPrompt.builtIn,
            subtitle: 'The prompt the app comes with',
            value: true,
          ),
          if (settings.hasCustomSystemPrompt)
            _PromptSwitch(
              key: const ValueKey('yours-switch'),
              title: BlindPrompt.yours,
              subtitle: 'Your edited prompt from Settings',
              value: _useYours,
              onChanged: busy ? null : (v) => setState(() => _useYours = v),
            ),
          _PromptSwitch(
            key: const ValueKey('try-this-switch'),
            title: BlindPrompt.tryThis,
            subtitle: 'A prompt to try out; replies keep using theirs',
            value: _useTry,
            onChanged: busy ? null : (v) => setState(() => _useTry = v),
          ),
          if (_useTry)
            ComposeField(
              controller: _tryThis,
              fieldKey: const ValueKey('try-this-field'),
              hint: 'paste a prompt · {me} and {them} become the names',
              maxLines: 10,
              enabled: !busy,
              onChanged: (text) {
                final s = _state;
                setState(() {});
                if (s != null) _save(s.copyWith(tryThis: text));
              },
            ),
          if (busy)
            BackgroundJobCard(
              task: task!,
              onStop: () => ref
                  .read(taskCenterProvider.notifier)
                  .cancel(BlindTestScreen.taskId(chat)),
            )
          else ...[
            PaperAction(
              key: const ValueKey('run'),
              title: latest == null ? 'Run the blind test' : 'Run again',
              subtitle: hasKey
                  ? '$calls calls · ${settings.generationModel}'
                  : 'Add an API key in Settings first',
              tone: ActionTone.accent,
              onTap: hasKey && state != null ? () => _run(settings) : null,
            ),
            if (state != null)
              PaperAction(
                key: const ValueKey('new-moments'),
                title: 'New moments',
                subtitle: 'Test on a different ${BlindTest.momentCount}',
                tone: ActionTone.outline,
                onTap: () => _save(state.copyWith(seed: _newSeed())),
              ),
          ],
          if (task?.status == TaskStatus.failed && task?.error != null)
            FailureNotice(error: task!.error!, onRetry: () => _run(settings)),
          if (latest != null) ...[
            MonoLabel(
              'Latest · ${dayMonthTime(latest.at)} · '
              'prompt v${latest.promptVersion}',
            ),
            for (final result in latest.results)
              _Score(
                run: latest,
                result: result,
                canUse:
                    !result.prompt.isBuiltIn &&
                    result.prompt.text.trim() !=
                        settings.effectiveSystemPrompt.trim(),
                onUse: () => _usePrompt(result.prompt),
                open: _open.contains(result.prompt.label),
                onToggle: () => setState(() {
                  if (!_open.remove(result.prompt.label)) {
                    _open.add(result.prompt.label);
                  }
                }),
              ),
            if (_after(latest.results, 0, -1) case final next?)
              PaperAction(
                key: const ValueKey('play'),
                title: 'Spot the real one',
                subtitle: 'Guess yourself · nothing is sent',
                tone: ActionTone.outline,
                onTap: () => setState(() => _playing = next),
              ),
            PaperAction(
              key: const ValueKey('copy'),
              title: 'Copy results',
              subtitle: 'To share the scores, or ask for a better prompt',
              tone: ActionTone.outline,
              onTap: () => _copy(latest),
            ),
          ],
          if (runs.length > 1) ...[
            const MonoLabel('Earlier runs'),
            PaperCard(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final run in runs.skip(1))
                    FigureRow(
                      '${dayMonthTime(run.at)} · v${run.promptVersion}',
                      run.results
                          .map(
                            (r) =>
                                '${r.prompt.label} '
                                '${percent(r.judgeFoolRate)}',
                          )
                          .join(' · '),
                    ),
                ],
              ),
            ),
          ],
        ],
        const Footnote(
          'Sends the moments, your real replies and the prompts to your AI '
          'provider, like writing a reply does. Results stay on this phone.',
        ),
      ],
    );
  }
}

/// Replies or openers: which the test writes.
class _KindPicker extends StatelessWidget {
  const _KindPicker({required this.kind, this.onPick});

  final BlindKind kind;
  final ValueChanged<BlindKind>? onPick;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final (k, label) in [
        (BlindKind.replies, 'Replies'),
        (BlindKind.openers, 'Openers'),
      ]) ...[
        if (k != BlindKind.replies) const SizedBox(width: 8),
        Expanded(
          child: Semantics(
            selected: k == kind,
            button: true,
            child: InkWell(
              key: ValueKey('kind-${k.name}'),
              borderRadius: Corner.all(Corner.pill),
              onTap: onPick == null ? null : () => onPick!(k),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: k == kind ? Paper.accent : Paper.card,
                  borderRadius: Corner.all(Corner.pill),
                  border: Border.all(
                    color: k == kind ? Paper.accent : Paper.border,
                  ),
                ),
                child: Text(
                  label,
                  style: Type.strong(
                    size: 14,
                    color: k == kind ? Paper.onAccent : Paper.secondary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ],
  );
}

class _PromptSwitch extends StatelessWidget {
  const _PromptSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    this.onChanged,
    super.key,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => PaperCard(
    padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
    // Its own Material, so the switch's ripple shows over the card.
    child: Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        activeThumbColor: Paper.accent,
        value: value,
        onChanged: onChanged,
        title: Text(title, style: Type.strong(size: 15)),
        subtitle: Text(
          subtitle,
          style: Type.prose(size: 12.5, color: Paper.muted),
        ),
      ),
    ),
  );
}

/// One prompt's score, how it compares with Built-in, and what gave it away.
class _Score extends StatelessWidget {
  const _Score({
    required this.run,
    required this.result,
    required this.canUse,
    required this.onUse,
    required this.open,
    required this.onToggle,
  });

  final BlindRun run;
  final BlindPromptResult result;
  final bool canUse;
  final VoidCallback onUse;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final n = result.pairs.length;
    final versus = BlindTest.versusBuiltIn(run, result);
    final better = versus.startsWith('Clearly better');
    final label = result.prompt.label;
    final misses = result.misses;
    return PaperCard(
      key: ValueKey('score-$label'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Text(label, style: Type.strong(size: 16))),
              Text(
                percent(result.judgeFoolRate),
                style: Type.numeric(size: 26, color: Paper.accent),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Passed as you in ${result.judgeFooled} of $n with the judge'
            '${result.played ? ' · ${result.userFooled} of $n with you' : ''}',
            style: Type.prose(size: 13.5, color: Paper.body, height: 1.4),
          ),
          if (versus.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              versus,
              style: Type.strong(
                size: 13.5,
                color: better
                    ? Paper.green
                    : versus.startsWith('Clearly worse')
                    ? Paper.errorText
                    : Paper.muted,
              ),
            ),
          ],
          if (better && canUse) ...[
            const SizedBox(height: 10),
            PaperAction(
              key: ValueKey('use-$label'),
              title: 'Use this prompt',
              subtitle: 'Replies will be written with it',
              tone: ActionTone.accent,
              onTap: onUse,
            ),
          ],
          if (misses.isNotEmpty) ...[
            const SizedBox(height: 6),
            TextButton(
              key: ValueKey('misses-$label'),
              onPressed: onToggle,
              child: Text(
                open
                    ? 'Hide what gave it away'
                    : 'What gave it away (${misses.length})',
                style: Type.strong(size: 13.5, color: Paper.accent),
              ),
            ),
            if (open)
              for (final miss in misses) _Miss(pair: miss),
          ],
        ],
      ),
    );
  }
}

class _Miss extends StatelessWidget {
  const _Miss({required this.pair});

  final BlindPair pair;

  @override
  Widget build(BuildContext context) {
    final lead = pair.context.length > 3
        ? pair.context.sublist(pair.context.length - 3)
        : pair.context;
    Text line(String label, String text, {Color? color}) => Text(
      '$label: ${text.replaceAll('\n', ' / ')}',
      textDirection: directionOf(text),
      style: Type.prose(size: 13, color: color ?? Paper.body, height: 1.4),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: PaperPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final t in lead) line(t.sender, t.text, color: Paper.muted),
            if (pair.setup.isNotEmpty)
              Text(
                pair.setup,
                style: Type.prose(size: 12.5, color: Paper.muted, height: 1.4),
              ),
            const SizedBox(height: 4),
            line('You', pair.real),
            line('Generated', pair.generated),
            if (pair.why.isNotEmpty)
              line('Judge', pair.why, color: Paper.muted),
          ],
        ),
      ),
    );
  }
}

/// "Spot the real one": one moment at a time, the two replies as A and B.
class _Play extends StatelessWidget {
  const _Play({
    required this.run,
    required this.at,
    required this.app,
    required this.onPick,
    required this.onDone,
  });

  final BlindRun run;
  final (int, int) at;
  final ChatMemory app;
  final ValueChanged<String> onPick;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final (r, p) = at;
    final pair = run.results[r].pairs[p];
    final total = run.results.fold<int>(0, (n, x) => n + x.pairs.length);
    final index =
        run.results.take(r).fold<int>(0, (n, x) => n + x.pairs.length) + p + 1;
    final List<ChatTurn> lead = pair.context.length > 4
        ? pair.context.sublist(pair.context.length - 4)
        : pair.context;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonoLabel('Spot the real one · $index of $total'),
        const SizedBox(height: 10),
        PaperPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final t in lead)
                Text(
                  '${t.sender}: ${t.text.replaceAll('\n', ' / ')}',
                  textDirection: directionOf(t.text),
                  style: Type.prose(size: 14, color: Paper.body, height: 1.4),
                ),
              if (pair.setup.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  pair.setup,
                  style: Type.prose(size: 13, color: Paper.muted, height: 1.4),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text('Which did you send?', style: Type.strong(size: 15)),
        for (final (side, text) in [('A', pair.a), ('B', pair.b)]) ...[
          const SizedBox(height: 10),
          _Choice(
            key: ValueKey('pick-$side'),
            side: side,
            text: text,
            chat: app,
            onTap: () => onPick(side),
          ),
        ],
        const SizedBox(height: 10),
        PaperAction(
          key: const ValueKey('play-done'),
          title: 'Stop for now',
          tone: ActionTone.outline,
          onTap: onDone,
        ),
      ],
    );
  }
}

/// One of the two replies to choose between, as a tappable bubble.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.side,
    required this.text,
    required this.chat,
    required this.onTap,
    super.key,
  });

  final String side;
  final String text;
  final ChatMemory chat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bubbles = Bubbles.of(chat.app);
    return InkWell(
      onTap: onTap,
      borderRadius: Corner.all(Corner.small),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              child: Text(
                side,
                style: Type.strong(size: 17, color: Paper.accent),
              ),
            ),
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(13, 9, 13, 9),
                  decoration: bubbles.fill(mine: true),
                  child: Text(
                    text.isEmpty ? '(nothing was written)' : text,
                    textDirection: directionOf(text),
                    style: Type.prose(
                      size: 15,
                      color: bubbles.mineText,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
