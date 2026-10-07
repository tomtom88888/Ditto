import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/stored_exchange.dart';
import '../services/chat_facts.dart';
import '../state/providers.dart';
import '../state/tasks.dart';
import '../theme/tokens.dart';
import '../widgets/background_job_card.dart';
import '../widgets/failure_text.dart';
import '../widgets/format.dart';
import '../widgets/paper_ui.dart';
import '../widgets/bidi.dart';

/// Things the other person has told you, pulled out of the chat so replies
/// can call back to them: the dog's name, the exam on Friday.
class FactsScreen extends ConsumerStatefulWidget {
  const FactsScreen({super.key});

  @override
  ConsumerState<FactsScreen> createState() => _FactsScreenState();
}

class _FactsScreenState extends ConsumerState<FactsScreen> {
  int? _chatId;
  Map<int, SavedFacts> _saved = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = await ref.read(factsStoreProvider).load();
      if (mounted) setState(() => _saved = saved);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _them(ChatMemory chat) =>
      chat.theirName.isEmpty ? 'them' : chat.theirName;

  static String _taskId(ChatMemory chat) => 'facts-${chat.id}';

  /// The chat to open on when none is picked: one being read now, else the
  /// one read most recently, so coming back shows what was just found.
  int? _lastUsed(List<ChatMemory> chats, List<BackgroundTask> tasks) {
    for (final c in chats) {
      if (tasks.any((t) => t.id == _taskId(c))) return c.id;
    }
    int? newest;
    DateTime? at;
    for (final c in chats) {
      final saved = _saved[c.id];
      if (saved != null && (at == null || saved.at.isAfter(at))) {
        newest = c.id;
        at = saved.at;
      }
    }
    return newest;
  }

  /// Starts reading [chat] as a background job: it keeps going if this
  /// screen is left, and only Stop ends it.
  void _find(ChatMemory chat) {
    final finder = ref.read(chatFactsProvider);
    if (finder == null) return;
    final store = ref.read(exchangeStoreProvider);
    final facts = ref.read(factsStoreProvider);
    final settingsFuture = ref.read(settingsProvider.future);
    ref
        .read(taskCenterProvider.notifier)
        .start(
          id: _taskId(chat),
          title: 'Remembering ${_them(chat)}',
          detail: 'Reading what ${_them(chat)} wrote',
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
                    detail: of <= 1
                        ? 'Picking out what is worth remembering'
                        : done < of
                        ? 'Part ${done + 1} of $of'
                        : 'Merging what was found',
                    progress: of == 0 ? null : done / of,
                  );
              },
            );
            task.check();
            await facts.save(
              chat.id,
              SavedFacts(at: DateTime.now(), facts: found),
            );
            return null;
          },
        );
  }

  Future<void> _forget(ChatMemory chat, ChatFact fact) async {
    final current = _saved[chat.id];
    if (current == null) return;
    final next = current.without(fact);
    setState(() => _saved = {..._saved, chat.id: next});
    await ref.read(factsStoreProvider).save(chat.id, next);
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatsProvider);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final hasKey = ref.watch(chatFactsProvider) != null;
    final tasks = ref.watch(taskCenterProvider);
    // A job that finished while this screen was open: show what it found.
    ref.listen(taskCenterProvider, (before, now) {
      for (final t in now) {
        if (t.id.startsWith('facts-') && t.status == TaskStatus.done) {
          final was = before?.where((b) => b.id == t.id).firstOrNull;
          if (was?.status != TaskStatus.done) _load();
        }
      }
    });

    return PaperScreen(
      children: [
        ScreenBar(title: 'Remember', onBack: () => Navigator.of(context).pop()),
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
                SerifTitle('Nothing to remember yet.', size: 34),
                Notice('Import a chat export first.', tone: NoticeTone.caution),
              ];
            }
            final chat = learned.firstWhere(
              (c) => c.id == (_chatId ?? _lastUsed(learned, tasks)),
              orElse: () => learned.first,
            );
            final them = _them(chat);
            final saved = _saved[chat.id];
            final task = tasks.where((t) => t.id == _taskId(chat)).firstOrNull;
            final busy = task?.running ?? false;
            return [
              SerifTitle(
                'What to remember about ',
                accent: bidiIsolate(them),
                trailing: '.',
                size: 32,
              ),
              if (learned.length > 1)
                _ChatPills(
                  chats: learned,
                  selected: chat.id,
                  onPick: (id) => setState(() => _chatId = id),
                ),
              Text(
                'Things ${bidiIsolate(them)} told you, for replies to call '
                'back to.',
                style: Type.prose(size: 14, color: Paper.body, height: 1.45),
              ),
              if (_loading) const LinearProgressIndicator(minHeight: 3),
              if (busy)
                BackgroundJobCard(
                  task: task!,
                  onStop: () => ref
                      .read(taskCenterProvider.notifier)
                      .cancel(_taskId(chat)),
                ),
              if (!busy)
                PaperAction(
                  title: saved == null
                      ? 'Find things to remember'
                      : 'Look through the chat again',
                  subtitle: hasKey
                      ? 'Sends what ${bidiIsolate(them)} wrote to '
                            '${settings.generationModel}'
                      : 'Add an API key in Settings first',
                  tone: saved == null ? ActionTone.accent : ActionTone.outline,
                  onTap: hasKey ? () => _find(chat) : null,
                ),
              if (task != null && task.status == TaskStatus.failed)
                FailureNotice(error: task.error!, onRetry: () => _find(chat)),
              if (saved != null && saved.facts.isEmpty)
                Notice(
                  'Nothing stood out in what ${bidiIsolate(them)} wrote. A '
                  'longer export may have more.',
                ),
              if (saved != null && saved.facts.isNotEmpty) ...[
                Text(
                  'Found on ${dayMonthTime(saved.at)}. Tap × on anything wrong '
                  'and it won’t be used.',
                  style: Type.prose(size: 12.5, color: Paper.muted),
                ),
                for (final category in ChatFacts.categories)
                  if (saved.facts.where((f) => f.category == category).toList()
                      case final facts when facts.isNotEmpty)
                    _Category(
                      title: category,
                      facts: facts,
                      onForget: (f) => _forget(chat, f),
                    ),
              ],
            ];
          },
        ),
        const Footnote(
          'Kept on this phone. Forgetting a chat forgets these too.',
        ),
      ],
    );
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
                  padding: const EdgeInsets.only(top: 12, right: 10),
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
                      textDirection: directionOf(fact.text),
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

class _ChatPills extends StatelessWidget {
  const _ChatPills({
    required this.chats,
    required this.selected,
    required this.onPick,
  });

  final List<ChatMemory> chats;
  final int selected;
  final ValueChanged<int>? onPick;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final chat in chats)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: onPick == null ? null : () => onPick!(chat.id),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: chat.id == selected ? Paper.accent : Paper.card,
                  borderRadius: Corner.all(Corner.pill),
                  border: chat.id == selected
                      ? null
                      : Border.all(color: Paper.border, width: 1.5),
                ),
                child: Text(
                  chat.theirName.isEmpty ? 'Unnamed' : chat.theirName,
                  style: Type.strong(
                    size: 14,
                    color: chat.id == selected ? Paper.onAccent : Paper.ink,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
