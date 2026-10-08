import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/stored_exchange.dart';
import '../services/chat_analysis.dart';
import '../services/chat_facts.dart';
import '../state/providers.dart';
import '../state/tasks.dart';
import '../theme/tokens.dart';
import '../widgets/background_job_card.dart';
import '../widgets/bidi.dart';
import '../widgets/chat_picker.dart';
import '../widgets/failure_text.dart';
import '../widgets/format.dart';
import '../widgets/paper_ui.dart';

/// What the app has worked out about one chat: how you write in it (used
/// for every reply to them), how each of you acts, what goes on between
/// you, and things they've told you worth remembering.
class AnalysisScreen extends ConsumerStatefulWidget {
  const AnalysisScreen({super.key});

  @override
  ConsumerState<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends ConsumerState<AnalysisScreen> {
  int? _chatId;
  Map<int, SavedFacts> _facts = const {};
  Map<int, ChatAnalysis> _analyses = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final facts = await ref.read(factsStoreProvider).load();
      final analyses = await ref.read(analysisStoreProvider).load();
      if (mounted) {
        setState(() {
          _facts = facts;
          _analyses = analyses;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _them(ChatMemory chat) =>
      chat.theirName.isEmpty ? 'them' : chat.theirName;

  static String taskId(ChatMemory chat) => 'analysis-${chat.id}';

  /// The chat to open on when none is picked: one being analysed now, else
  /// the one analysed most recently.
  int? _lastUsed(List<ChatMemory> chats, List<BackgroundTask> tasks) {
    for (final c in chats) {
      if (tasks.any((t) => t.id == taskId(c))) return c.id;
    }
    int? newest;
    DateTime? at;
    for (final c in chats) {
      final when = _analyses[c.id]?.at ?? _facts[c.id]?.at;
      if (when != null && (at == null || when.isAfter(at))) {
        newest = c.id;
        at = when;
      }
    }
    return newest;
  }

  /// Analyses [chat] as a background job: it keeps going if this screen is
  /// left, and only Stop ends it.
  void _analyse(ChatMemory chat) {
    final finder = ref.read(chatFactsProvider);
    final analyst = ref.read(chatAnalystProvider);
    if (finder == null || analyst == null) return;
    final store = ref.read(exchangeStoreProvider);
    final factsStore = ref.read(factsStoreProvider);
    final analysisStore = ref.read(analysisStoreProvider);
    final settingsFuture = ref.read(settingsProvider.future);
    final them = _them(chat);
    ref
        .read(taskCenterProvider.notifier)
        .start(
          id: taskId(chat),
          title: 'Analysing $them',
          detail: 'Reading the chat',
          work: (task) async {
            final settings = await settingsFuture;
            final exchanges = await store.all(chatIds: {chat.id});
            task.check();
            final found = await finder.find(
              exchanges,
              myName: chat.myName,
              them: chat.theirName,
              model: settings.generationModel,
              group: chat.isGroup,
              onProgress: (done, of) {
                task
                  ..check()
                  ..report(
                    detail:
                        'Things to remember · part ${done + 1 > of ? of : done + 1} of $of',
                    progress: of == 0 ? null : done / (of + 1),
                  );
              },
            );
            task.check();
            await factsStore.save(
              chat.id,
              SavedFacts(at: DateTime.now(), facts: found),
            );
            task.report(detail: 'How you write, and how you both act');
            final analysis = await analyst.analyse(
              exchanges,
              myName: chat.myName,
              them: chat.theirName,
              profile: chat.profile,
              model: settings.generationModel,
              group: chat.isGroup,
            );
            task.check();
            await analysisStore.save(chat.id, analysis);
            return null;
          },
        );
  }

  Future<void> _forget(ChatMemory chat, ChatFact fact) async {
    final current = _facts[chat.id];
    if (current == null) return;
    final next = current.without(fact);
    setState(() => _facts = {..._facts, chat.id: next});
    await ref.read(factsStoreProvider).save(chat.id, next);
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatsProvider);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final hasKey = ref.watch(chatAnalystProvider) != null;
    final tasks = ref.watch(taskCenterProvider);
    // A job that finished while this screen was open: show what it found.
    ref.listen(taskCenterProvider, (before, now) {
      for (final t in now) {
        if (t.id.startsWith('analysis-') && t.status == TaskStatus.done) {
          final was = before?.where((b) => b.id == t.id).firstOrNull;
          if (was?.status != TaskStatus.done) _load();
        }
      }
    });

    return PaperScreen(
      children: [
        ScreenBar(title: 'Analysis', onBack: () => Navigator.of(context).pop()),
        ...chats.when(
          loading: () => [const LinearProgressIndicator(minHeight: 3)],
          error: (error, _) => [FailureNotice(error: error)],
          data: (all) {
            final learned = [
              for (final c in all)
                if (!c.isEmpty) c,
            ];
            if (learned.isEmpty) {
              return const [
                SerifTitle('Nothing to analyse yet.', size: 34),
                Notice('Import a chat first.', tone: NoticeTone.caution),
              ];
            }
            final chat = learned.firstWhere(
              (c) => c.id == (_chatId ?? _lastUsed(learned, tasks)),
              orElse: () => learned.first,
            );
            final them = _them(chat);
            final facts = _facts[chat.id];
            final analysis = _analyses[chat.id];
            final done = facts != null || analysis != null;
            final task = tasks.where((t) => t.id == taskId(chat)).firstOrNull;
            final busy = task?.running ?? false;
            return [
              SerifTitle(
                'You and ',
                accent: bidiIsolate(them),
                trailing: '.',
                size: 34,
              ),
              if (learned.length > 1)
                ChatPicker(
                  chats: learned,
                  selected: chat.id,
                  onPick: (id) => setState(() => _chatId = id),
                ),
              if (_loading) const LinearProgressIndicator(minHeight: 3),
              if (busy)
                BackgroundJobCard(
                  task: task!,
                  onStop: () => ref
                      .read(taskCenterProvider.notifier)
                      .cancel(taskId(chat)),
                ),
              if (!busy)
                PaperAction(
                  key: const ValueKey('analyse'),
                  title: done ? 'Analyse again' : 'Analyse the chat',
                  subtitle: hasKey
                      ? 'Reads the chat with ${settings.generationModel}'
                      : 'Add an API key in Settings first',
                  tone: done ? ActionTone.outline : ActionTone.accent,
                  onTap: hasKey ? () => _analyse(chat) : null,
                ),
              if (task != null && task.status == TaskStatus.failed)
                FailureNotice(
                  error: task.error!,
                  onRetry: () => _analyse(chat),
                ),
              if (!done && !busy)
                Text(
                  'Works out how you write to ${bidiIsolate(them)}, which '
                  'every reply to them then follows, plus how you both act '
                  'and what they\'ve told you.',
                  style: Type.prose(size: 14, color: Paper.body, height: 1.45),
                ),
              if (analysis != null && !analysis.isEmpty) ...[
                if (analysis.writing.isNotEmpty)
                  _Section(
                    key: const ValueKey('how-you-write'),
                    title: 'How you write',
                    caption: 'Every reply to ${bidiIsolate(them)} follows this',
                    lines: analysis.writing,
                    highlight: true,
                  ),
                if (analysis.acting.isNotEmpty)
                  _Section(
                    key: const ValueKey('how-you-act'),
                    title: 'How you act',
                    caption: 'Replies act like this too',
                    lines: analysis.acting,
                    highlight: true,
                  )
                else if (analysis.you.isNotEmpty)
                  _Section(title: 'How you act', lines: analysis.you),
                if (analysis.them.isNotEmpty)
                  _Section(
                    title: chat.isGroup
                        ? 'How the others act'
                        : 'How ${bidiIsolate(them)} acts',
                    lines: analysis.them,
                  ),
                if (analysis.together.isNotEmpty)
                  _Section(title: 'Between you', lines: analysis.together),
              ],
              if (facts != null) ...[
                const MonoLabel('Things to remember'),
                if (facts.facts.isEmpty)
                  Notice(
                    'Nothing stood out in what ${bidiIsolate(them)} wrote.',
                  )
                else
                  for (final category in ChatFacts.categories)
                    if (facts.facts
                            .where((f) => f.category == category)
                            .toList()
                        case final list when list.isNotEmpty)
                      _Category(
                        title: category,
                        facts: list,
                        onForget: (f) => _forget(chat, f),
                      ),
              ],
              if (analysis != null)
                Text(
                  'Analysed ${dayMonthTime(analysis.at)}.',
                  style: Type.prose(size: 12.5, color: Paper.muted),
                ),
            ];
          },
        ),
        const Footnote(
          'Kept on this phone. Forgetting a chat forgets this too.',
        ),
      ],
    );
  }
}

/// A titled list of short observations.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.lines,
    this.caption,
    this.highlight = false,
    super.key,
  });

  final String title;
  final String? caption;
  final List<String> lines;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Type.display(
            highlight ? 24 : 20,
            color: highlight ? Paper.onHero : null,
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: 2),
          Text(
            caption!,
            style: Type.prose(
              size: 12.5,
              color: highlight
                  ? Paper.onHero.withValues(alpha: 0.7)
                  : Paper.muted,
            ),
          ),
        ],
        const SizedBox(height: 6),
        for (final line in lines)
          ContentDirection(
            text: line,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.only(top: 8, end: 10),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: highlight ? Paper.amber : Paper.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line,
                      style: Type.prose(
                        size: 14,
                        color: highlight ? Paper.onHero : Paper.ink,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
    return highlight
        ? InkCard(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: body,
          )
        : PaperCard(child: body);
  }
}

class _Category extends StatelessWidget {
  const _Category({
    required this.title,
    required this.facts,
    required this.onForget,
  });

  final String title;
  final List<ChatFact> facts;
  final ValueChanged<ChatFact> onForget;

  @override
  Widget build(BuildContext context) => PaperCard(
    padding: const EdgeInsets.fromLTRB(16, 12, 6, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Type.display(20)),
        const SizedBox(height: 4),
        for (final fact in facts)
          ContentDirection(
            text: fact.text,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: 12, end: 10),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: Paper.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      fact.text,
                      style: Type.prose(
                        size: 14,
                        color: Paper.ink,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Forget this',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onForget(fact),
                  icon: Icon(Icons.close_rounded, size: 18, color: Paper.muted),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
