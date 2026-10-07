import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/chat_app.dart';
import '../models/stored_exchange.dart';
import '../services/share_intake.dart';
import '../state/providers.dart';
import '../theme/bubbles.dart';
import '../theme/tokens.dart';
import '../widgets/export_guides.dart';
import '../widgets/failure_text.dart';
import '../widgets/format.dart';
import '../widgets/paper_dialog.dart';
import '../widgets/paper_ui.dart';
import 'analysis_screen.dart';
import 'ask_screen.dart';
import 'chat_data_screen.dart';
import 'chat_groupings_screen.dart';
import 'check_screen.dart';
import 'generate_screen.dart';
import 'graph_screen.dart';
import 'openers_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'train_screen.dart';

/// What the app knows, which of it to use, and the things you can do.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  StreamSubscription<SharedItem>? _shareSubscription;

  @override
  void initState() {
    super.initState();
    // Something shared into the app skips this screen: an export opens Train,
    // a screenshot opens Generate with it already picked.
    _shareSubscription = ShareIntake.stream().listen(
      _openShared,
      onError: (Object error) {
        if (mounted) showFailureSnackBar(context, error);
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final initial = await ShareIntake.initial();
      if (initial != null && mounted) unawaited(_openShared(initial));
    });
  }

  @override
  void dispose() {
    unawaited(_shareSubscription?.cancel());
    super.dispose();
  }

  Future<void> _openShared(SharedItem item) async {
    await ShareIntake.markHandled();
    if (!mounted) return;
    switch (item) {
      case SharedExport():
        await _push(TrainScreen(sharedExport: item));
      case SharedScreenshot():
        await _push(GenerateScreen(sharedScreenshot: item));
    }
  }

  void _refresh() {
    ref.invalidate(chatsProvider);
    ref.invalidate(feedbackProvider);
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _refresh();
  }

  /// Cuts [chat] down to the dates picked, or [whole] puts all of it back.
  Future<void> _chooseDates(ChatMemory chat, {bool whole = false}) async {
    final notifier = ref.read(chatsProvider.notifier);
    if (whole) {
      await notifier.setDates(chat.id);
      if (mounted) showToast(context, 'Using the whole chat again.');
      return;
    }
    final (first, last) = await ref
        .read(exchangeStoreProvider)
        .dateSpan(chat.id);
    if (!mounted) return;
    if (first == null || last == null) {
      showToast(context, 'This chat has no dates to cut by.');
      return;
    }
    DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
    final range = await showDateRangePicker(
      context: context,
      firstDate: day(first),
      lastDate: day(last),
      initialDateRange: DateTimeRange(
        start: day(chat.from ?? first),
        end: day(chat.until ?? last),
      ),
      helpText: 'Use only these dates',
      saveText: 'Use',
    );
    if (range == null || !mounted) return;
    final all = range.start == day(first) && range.end == day(last);
    await notifier.setDates(
      chat.id,
      from: all ? null : range.start,
      until: all ? null : range.end,
    );
    if (mounted) {
      showToast(
        context,
        all
            ? 'Using the whole chat.'
            : 'Using ${dayMonthYear(range.start)} to '
                  '${dayMonthYear(range.end)}.',
        detail:
            'Replies, search and graphs use these dates now. Run the '
            'analysis and groupings again to update them.',
      );
    }
  }

  Future<void> _confirmDelete(ChatMemory chat) async {
    final name = chat.theirName.isEmpty ? 'this chat' : chat.theirName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => PaperDialog(
        title: 'Forget ${bidiIsolate(name)}?',
        confirmLabel: 'Forget it',
        destructive: true,
        onConfirm: () => Navigator.of(context).pop(true),
        child: Text(
          'Removes the ${grouped(chat.exchangeCount)} replies learned from '
          'this chat.',
          style: Type.prose(size: 14, color: Paper.body),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(chatsProvider.notifier).delete(chat.id);
    } on Object catch (error) {
      if (mounted) showFailureSnackBar(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatsProvider);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();

    void openSettings() => _push(const SettingsScreen());
    void openTrain() => _push(const TrainScreen());

    return chats.when(
      loading: () => _HomeFrame(
        onSettings: openSettings,
        bottom: _Actions(
          trained: false,
          anyEnabled: false,
          onTrain: openTrain,
          onGenerate: null,
        ),
        children: const [_LoadingSkeleton()],
      ),
      error: (error, _) => _HomeFrame(
        onSettings: openSettings,
        bottom: _Actions(
          trained: false,
          anyEnabled: false,
          onTrain: openTrain,
          onGenerate: null,
          trainTitle: 'Rebuild from an export',
        ),
        children: [
          Notice(
            "Couldn't open the memory on this phone. Re-import to rebuild it.",
            tone: NoticeTone.failure,
            title: 'Memory unreadable',
            actionLabel: 'Try again',
            onAction: _refresh,
          ),
        ],
      ),
      data: (all) {
        final learned = all.where((c) => !c.isEmpty).toList();
        final enabled = learned;
        final trained = learned.isNotEmpty;
        final stale = enabled
            .where(
              (c) => !c.matches(
                settings.embeddingModel,
                settings.embeddingDimensions,
              ),
            )
            .toList();
        return _HomeFrame(
          onSettings: openSettings,
          bottom: _Actions(
            trained: trained,
            anyEnabled: enabled.isNotEmpty,
            onTrain: openTrain,
            onGenerate: enabled.isNotEmpty
                ? () => _push(const GenerateScreen())
                : null,
          ),
          children: trained
              ? [
                  _KnowsYou(enabled: enabled),
                  _ChatList(
                    chats: learned,
                    onOpen: (chat) => _push(GenerateScreen(chat: chat)),
                    onDelete: _confirmDelete,
                    onDates: (chat, {whole = false}) =>
                        _chooseDates(chat, whole: whole),
                    onAdd: openTrain,
                  ),
                  if (enabled.where((c) => c.isOutOfDate()).toList()
                      case final old when old.isNotEmpty)
                    Notice(
                      old.length == 1
                          ? '${bidiIsolate(old.single.theirName.isEmpty ? "This chat" : old.single.theirName)}’s '
                                'export ends on '
                                '${dayMonthYear(old.single.lastMessageAt!)}. '
                                'Import a newer one so replies know what '
                                'has been said since.'
                          : 'The exports for '
                                '${nameList([for (final c in old) c.theirName])} '
                                'end over a month ago. Import newer ones so '
                                'replies know what has been said since.',
                      key: const ValueKey('out-of-date'),
                      tone: NoticeTone.caution,
                      title: 'Time for a new export',
                      actionLabel: 'Import a newer export',
                      onAction: openTrain,
                    ),
                  if (stale.isNotEmpty)
                    Notice(
                      '${nameList([for (final c in stale) c.theirName])}: '
                      'made with another fingerprint model, so skipped. '
                      'Import again to rebuild.',
                      tone: NoticeTone.caution,
                      title: 'Needs rebuilding',
                    ),
                  _Explore(open: (screen) => _push(screen)),
                  if (settings.mode == TrainingMode.fineTune &&
                      !settings.hasFineTunedModel)
                    _FineTuneMismatch(onFix: openSettings),
                ]
              : const [_DoesNotKnowYou()],
        );
      },
    );
  }
}

/// The shared chrome: the wordmark and the settings button.
class _HomeFrame extends StatelessWidget {
  const _HomeFrame({
    required this.children,
    required this.bottom,
    required this.onSettings,
  });

  final List<Widget> children;
  final Widget bottom;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => PaperScreen(
    bottom: bottom,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Expanded(
            child: Align(alignment: Alignment.centerLeft, child: DittoLogo()),
          ),
          GestureDetector(
            onTap: onSettings,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Paper.panel,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.settings_outlined,
                size: 18,
                color: Paper.secondary,
              ),
            ),
          ),
        ],
      ),
      ...children,
    ],
  );
}

/// The hero: whose chats replies are drawn from, and how many of your replies
/// that is.
class _KnowsYou extends StatelessWidget {
  const _KnowsYou({required this.enabled});

  final List<ChatMemory> enabled;

  @override
  Widget build(BuildContext context) {
    final count = enabled.fold(0, (sum, c) => sum + c.exchangeCount);
    return InkCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'It knows how you write to',
            style: Type.prose(
              size: 15,
              color: Paper.onHero.withValues(alpha: 0.62),
              height: 1.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            nameList([for (final c in enabled) c.theirName]),
            style: Type.display(40, color: Paper.onHero),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                grouped(count),
                style: Type.numeric(size: 30, color: Paper.amber),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'of your replies learned',
                  style: Type.prose(
                    size: 14,
                    color: Paper.onHero.withValues(alpha: 0.62),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Every learned chat. Tapping one writes a reply to that person.
class _ChatList extends StatelessWidget {
  const _ChatList({
    required this.chats,
    required this.onOpen,
    required this.onDelete,
    required this.onDates,
    required this.onAdd,
  });

  final List<ChatMemory> chats;
  final ValueChanged<ChatMemory> onOpen;
  final ValueChanged<ChatMemory> onDelete;
  final void Function(ChatMemory chat, {bool whole}) onDates;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const MonoLabel('Your chats · tap one to reply'),
      const SizedBox(height: 9),
      PaperCard(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final chat in chats)
              _ChatRow(
                chat: chat,
                onTap: () => onOpen(chat),
                onDelete: () => onDelete(chat),
                onDates: ({whole = false}) => onDates(chat, whole: whole),
              ),
            _AddChatRow(onTap: onAdd),
          ],
        ),
      ),
    ],
  );
}

/// A round badge with the chat's initial, in its app's colours.
class _ChatBadge extends StatelessWidget {
  const _ChatBadge({required this.chat});

  final ChatMemory chat;

  @override
  Widget build(BuildContext context) {
    final bubbles = Bubbles.of(chat.app);
    final name = chat.theirName.trim();
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: bubbles.fill(mine: true).copyWith(shape: BoxShape.circle),
      child: chat.isGroup
          ? Icon(
              Icons.groups_rounded,
              size: 20,
              color: bubbles.mineText,
              semanticLabel: 'Group',
            )
          : Text(
              name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: Type.strong(size: 16, color: bubbles.mineText),
            ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    required this.onTap,
    required this.onDelete,
    required this.onDates,
  });

  final ChatMemory chat;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final void Function({bool whole}) onDates;

  @override
  Widget build(BuildContext context) {
    final saved = chat.savedCount > 0 ? ' · ${chat.savedCount} starred' : '';
    final app = chat.app == ChatApp.instagram ? 'Instagram' : 'WhatsApp';
    return InkWell(
      key: ValueKey('chat-${chat.id}'),
      onTap: onTap,
      borderRadius: Corner.all(Corner.small),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
        // Every chat row has a divider under it: the add row follows.
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Paper.divider)),
        ),
        child: Row(
          children: [
            _ChatBadge(chat: chat),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chat.theirName.isEmpty ? 'Unnamed chat' : chat.theirName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.strong(size: 15, height: 1.3),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$app · ${grouped(chat.exchangeCount)} '
                    '${chat.exchangeCount == 1 ? "reply" : "replies"}$saved',
                    style: Type.numeric(
                      size: 11.5,
                      color: Paper.muted,
                      weight: FontWeight.w400,
                    ),
                  ),
                  if (chat.isCut)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        children: [
                          Icon(
                            Icons.content_cut_rounded,
                            size: 13,
                            color: Paper.accent,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '${chat.from == null ? "Start" : dayMonthYear(chat.from!)} – '
                              '${chat.until == null ? "now" : dayMonthYear(chat.until!)}',
                              key: ValueKey('dates-${chat.id}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Type.prose(
                                size: 11.5,
                                color: Paper.accent,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (chat.isOutOfDate() && chat.until == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        children: [
                          Icon(
                            Icons.schedule_rounded,
                            size: 13,
                            color: Paper.warnText,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Ends ${dayMonthYear(chat.lastMessageAt!)} · '
                              'import a newer export',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Type.prose(
                                size: 11.5,
                                color: Paper.warnText,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              color: Paper.bg,
              icon: Icon(Icons.more_horiz, size: 20, color: Paper.tertiary),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'dates',
                  child: Text('Choose dates…', style: Type.strong(size: 14)),
                ),
                if (chat.isCut)
                  PopupMenuItem(
                    value: 'whole',
                    child: Text(
                      'Use the whole chat',
                      style: Type.strong(size: 14),
                    ),
                  ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    'Forget this chat',
                    style: Type.strong(size: 14, color: Paper.errorText),
                  ),
                ),
              ],
              onSelected: (choice) => switch (choice) {
                'dates' => onDates(),
                'whole' => onDates(whole: true),
                _ => onDelete(),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The last row of the chat list: bringing in another chat, or a newer
/// export of one already here.
class _AddChatRow extends StatelessWidget {
  const _AddChatRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: Corner.all(Corner.small),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 13, 12, 13),
      child: Row(
        children: [
          Icon(Icons.add_rounded, size: 22, color: Paper.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add or refresh a chat',
                  style: Type.strong(
                    size: 14.5,
                    height: 1.3,
                    color: Paper.accent,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'Import an export · only new replies are sent',
                  style: Type.prose(size: 12, color: Paper.muted, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The ways to look at what has been learned, two to a row.
class _Explore extends StatelessWidget {
  const _Explore({required this.open});

  /// Opens a screen.
  final ValueChanged<Widget> open;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _Tile(
        icon: Icons.question_answer_outlined,
        title: 'Ask your chats',
        subtitle: 'Questions, answered from them',
        onTap: () => open(const AskScreen()),
      ),
      _Tile(
        icon: Icons.waving_hand_outlined,
        title: 'Start a chat',
        subtitle: 'When it’s gone quiet',
        onTap: () => open(const OpenersScreen()),
      ),
      _Tile(
        icon: Icons.spellcheck_rounded,
        title: 'Check my message',
        subtitle: 'Does it sound like you?',
        onTap: () => open(const CheckScreen()),
      ),
      _Tile(
        icon: Icons.bar_chart_rounded,
        title: 'Make a graph',
        subtitle: 'Describe it, get it',
        onTap: () => open(const GraphScreen()),
      ),
      _Tile(
        icon: Icons.search_rounded,
        title: 'Search',
        subtitle: 'Find a moment by meaning',
        onTap: () => open(const SearchScreen()),
      ),
      _Tile(
        icon: Icons.psychology_outlined,
        title: 'Analysis',
        subtitle: 'How you write, how you both act',
        onTap: () => open(const AnalysisScreen()),
      ),
      _Tile(
        icon: Icons.insights_rounded,
        title: 'Chat data',
        subtitle: 'Reply times, word counts',
        onTap: () => open(const ChatDataScreen()),
      ),
      _Tile(
        icon: Icons.bubble_chart_outlined,
        title: 'Chat groupings',
        subtitle: 'What you talk about',
        onTap: () => open(const ChatGroupingsScreen()),
      ),
    ];
    // Equal heights, so each pair of tiles reads as one row.
    Widget pair(Widget a, Widget b) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: a),
          const SizedBox(width: 10),
          Expanded(child: b),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MonoLabel('Look closer'),
        const SizedBox(height: 9),
        for (var i = 0; i < tiles.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 10),
          pair(tiles[i], tiles[i + 1]),
        ],
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: Ink(
      decoration: BoxDecoration(
        color: Paper.card,
        borderRadius: Corner.all(Corner.card),
        boxShadow: Paper.liftCard,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: Corner.all(Corner.card),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Paper.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 19, color: Paper.accent),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.strong(size: 15, height: 1.3),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Type.prose(
                  size: 12.5,
                  color: Paper.tertiary,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _FineTuneMismatch extends StatelessWidget {
  const _FineTuneMismatch({required this.onFix});

  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) => PaperPanel(
    color: Paper.warnPanel,
    padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(right: 11),
          child: Text(
            '!',
            style: TextStyle(fontSize: 15, height: 1.2, color: Paper.accent),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              emphasised(
                'No fine-tuned model saved, so style memory is used.',
                size: 13.5,
                color: Paper.warnText,
              ),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: onFix,
                child: Text(
                  'Fix in Settings',
                  style: Type.strong(size: 13, color: Paper.accent).copyWith(
                    decoration: TextDecoration.underline,
                    decorationColor: Paper.accent.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The untrained state: what will happen, in three lines.
class _DoesNotKnowYou extends StatelessWidget {
  const _DoesNotKnowYou();

  static const List<String> _steps = [
    'Export a chat from WhatsApp or Instagram: here is exactly how.',
    'Say which name is you. Only your replies get learned.',
    'A minute or two of building. Costs well under a cent.',
  ];

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PaperPanel(
        radius: Corner.hero,
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SerifTitle("It doesn't know you yet.", size: 34),
            const SizedBox(height: 10),
            Text(
              'Import one exported WhatsApp or Instagram conversation and it '
              'will read '
              'every reply you sent in it — how long, how punctuated, how '
              'you open and sign off — and keep that here on the phone.',
              style: Type.prose(size: 14.5),
            ),
          ],
        ),
      ),
      const SizedBox(height: Frame.gap),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            for (var i = 0; i < _steps.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '0${i + 1}',
                      style: Type.numeric(size: 12, color: Paper.accent),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _steps[i],
                      style: Type.prose(
                        size: 14,
                        color: Paper.body,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: Frame.gap),
      const MonoLabel('How to export a chat'),
      const SizedBox(height: 9),
      const ExportGuides(),
    ],
  );
}

/// Skeletons while the local store is read. The actions stay tappable.
class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        height: 150,
        decoration: BoxDecoration(
          color: Paper.panel,
          borderRadius: Corner.all(Corner.hero),
        ),
      ),
      const SizedBox(height: Frame.gap),
      Container(
        height: 132,
        decoration: BoxDecoration(
          color: Paper.panel,
          borderRadius: Corner.all(Corner.card),
        ),
      ),
    ],
  );
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.trained,
    required this.anyEnabled,
    required this.onTrain,
    required this.onGenerate,
    this.trainTitle,
  });

  final bool trained;
  final bool anyEnabled;
  final VoidCallback onTrain;
  final VoidCallback? onGenerate;
  final String? trainTitle;

  @override
  Widget build(BuildContext context) {
    final locked = !trained || !anyEnabled;
    final write = PaperAction(
      title: 'Write a reply',
      subtitle: !trained
          ? 'Nothing learned yet — teach it first'
          : 'From a screenshot or pasted chat',
      tone: ActionTone.accent,
      onTap: onGenerate,
      trailing: locked
          ? Icon(Icons.lock_outline, size: 16, color: Paper.tertiary)
          : null,
    );
    final train = PaperAction(
      title:
          trainTitle ??
          (trained ? 'Add or refresh a chat' : 'Teach it your voice'),
      subtitle: trained
          ? 'Import an export · only new replies are sent'
          : 'Import a WhatsApp or Instagram export',
      tone: trained ? ActionTone.outline : ActionTone.ink,
      onTap: onTrain,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Trained: writing is the everyday act, so it leads. Untrained: there
        // is nothing to write from, so teaching leads.
        // Adding a chat lives in the chat list once there is one.
        if (trained)
          write
        else ...[
          train,
          const SizedBox(height: 11),
          write,
          const SizedBox(height: 15),
          const Footnote('Your chat history never leaves this phone.'),
        ],
      ],
    );
  }
}
