import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/stored_exchange.dart';
import '../services/chat_trends.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/chat_picker.dart';
import '../widgets/failure_text.dart';
import '../widgets/format.dart';
import '../widgets/paper_ui.dart';
import 'chat_data_screen.dart';

/// Whether a chat is warming up or cooling off, month by month: how much you
/// each write, how fast they answer, who starts. Counted on the phone.
class TrendsScreen extends ConsumerStatefulWidget {
  const TrendsScreen({super.key});

  @override
  ConsumerState<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends ConsumerState<TrendsScreen> {
  int? _chatId;
  final Map<int, Future<ChatTrends>> _trends = {};

  Future<ChatTrends> _trendsFor(ChatMemory chat) => _trends.putIfAbsent(
    chat.id,
    () async => ChatTrends.of(
      await ref.read(exchangeStoreProvider).all(chatIds: {chat.id}),
      myName: chat.myName,
      them: chat.isGroup || chat.theirName.isEmpty ? 'They' : chat.theirName,
    ),
  );

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _month(DateTime m) =>
      '${_months[m.month - 1]} ${m.year.toString().substring(2)}';

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatsProvider);
    return PaperScreen(
      children: [
        ScreenBar(
          title: 'How it’s going',
          onBack: () => Navigator.of(context).pop(),
        ),
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
                Notice('Import a chat first.', tone: NoticeTone.caution),
              ];
            }
            final chat = learned.firstWhere(
              (c) => c.id == _chatId,
              orElse: () => learned.first,
            );
            final them = chat.theirName.isEmpty ? 'them' : chat.theirName;
            return [
              SerifTitle(
                'You and ',
                accent: bidiIsolate(them),
                trailing: ', lately.',
                size: 32,
              ),
              if (learned.length > 1)
                ChatPicker(
                  chats: learned,
                  selected: chat.id,
                  onPick: (id) => setState(() => _chatId = id),
                ),
              FutureBuilder<ChatTrends>(
                key: ValueKey('trends-${chat.id}'),
                future: _trendsFor(chat),
                builder: (context, snap) {
                  if (snap.hasError) return FailureNotice(error: snap.error!);
                  final trends = snap.data;
                  if (trends == null) {
                    return const LinearProgressIndicator(minHeight: 3);
                  }
                  if (trends.isEmpty) {
                    return const Notice(
                      'This export has no dates to count by.',
                      tone: NoticeTone.caution,
                    );
                  }
                  return _Trends(trends: trends, them: them);
                },
              ),
            ];
          },
        ),
        const Footnote(
          'Counted on your phone from the messages before each of your '
          'replies. No API calls.',
        ),
      ],
    );
  }
}

class _Trends extends StatelessWidget {
  const _Trends({required this.trends, required this.them});

  final ChatTrends trends;
  final String them;

  @override
  Widget build(BuildContext context) {
    final (title, line) = switch (trends.direction) {
      TrendDirection.warming => (
        'Warming up',
        'More, and closer, than a few months ago.',
      ),
      TrendDirection.cooling => ('Cooling off', 'Less than a few months ago.'),
      TrendDirection.steady => ('Steady', 'Much like a few months ago.'),
      TrendDirection.unknown => (
        'Too early to tell',
        'It takes a few months of chat to see a trend.',
      ),
    };
    final shown = trends.months.length > 12
        ? trends.months.sublist(trends.months.length - 12)
        : trends.months;
    final table = shown.length > 6 ? shown.sublist(shown.length - 6) : shown;
    final last = trends.lastMessageAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkCard(
          key: const ValueKey('trend-verdict'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Type.display(36, color: Paper.onHero)),
              const SizedBox(height: 6),
              Text(
                '$line${last == null ? "" : " Export ends ${dayMonthYear(last)}."}',
                style: Type.prose(
                  size: 14,
                  color: Paper.onHero.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        if (trends.notes.isNotEmpty) ...[
          const SizedBox(height: Frame.gap),
          PaperCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final n in trends.notes)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '• ${bidiIsolate(n)}',
                      style: Type.prose(
                        size: 14,
                        color: Paper.ink,
                        height: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Frame.gap),
        PaperCard(
          child: BarStrip(
            title: 'Messages each month',
            values: [for (final m in shown) m.total],
            describe: (i) => _TrendsScreenState._month(shown[i].month),
            axisLabel: (i) =>
                _TrendsScreenState._months[shown[i].month.month - 1][0],
          ),
        ),
        const SizedBox(height: Frame.gap),
        const MonoLabel('Month by month'),
        const SizedBox(height: 9),
        PaperCard(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            children: [
              _Row(
                cells: [
                  '',
                  'You',
                  bidiIsolate(them),
                  'They answer in',
                  'They start',
                ],
                header: true,
              ),
              for (final m in table.reversed)
                _Row(
                  cells: [
                    _TrendsScreenState._month(m.month),
                    grouped(m.mine),
                    grouped(m.theirs),
                    m.theirReply == null
                        ? '–'
                        : ChatTrends.minutesLabel(m.theirReply!),
                    m.theirStartShare == null
                        ? '–'
                        : '${(m.theirStartShare! * 100).round()}%',
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.cells, this.header = false});

  final List<String> cells;
  final bool header;

  static const List<int> _flex = [5, 4, 4, 6, 5];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            flex: _flex[i],
            child: Text(
              cells[i],
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: i == 0 ? TextAlign.start : TextAlign.end,
              style: header
                  ? Type.prose(size: 11.5, color: Paper.muted, height: 1.2)
                  : Type.numeric(
                      size: 12.5,
                      color: i == 0 ? Paper.ink : Paper.body,
                      weight: FontWeight.w400,
                    ),
            ),
          ),
      ],
    ),
  );
}
