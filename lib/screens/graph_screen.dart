import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/stored_exchange.dart';
import '../services/chart_maker.dart';
import '../state/providers.dart';
import '../widgets/example_chips.dart';
import '../widgets/chart_view.dart';
import '../widgets/chat_picker.dart';
import '../widgets/compose_field.dart';
import '../widgets/failure_text.dart';
import '../widgets/paper_ui.dart';

/// Describe a graph about a chat and get it: "messages per month, me vs
/// her", "when do we text, by hour", "how often we say love".
///
/// The description goes to the writing model, which answers with what to
/// count; the counting happens on the phone, so no messages are sent.
class GraphScreen extends ConsumerStatefulWidget {
  const GraphScreen({super.key});

  @override
  ConsumerState<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends ConsumerState<GraphScreen> {
  final _description = TextEditingController();
  int? _chatId;
  bool _busy = false;
  Object? _error;
  ChartSpec? _spec;

  /// Each chat's count of [_spec], so switching chat redraws for free.
  final Map<(int, ChartSpec), Future<ChartData>> _counted = {};

  static const List<String> examples = [
    'Messages per month, me vs them',
    'What time of day we text',
    'Who starts conversations, by month',
    'How fast we each answer, by month',
    'How often we laugh, by weekday',
  ];

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<ChartData> _count(ChartMemoryKey key, ChatMemory chat) =>
      _counted.putIfAbsent(
        key,
        () async => ChartMaker.count(
          key.$2,
          await ref.read(exchangeStoreProvider).all(chatIds: {chat.id}),
          myName: chat.myName,
        ),
      );

  Future<void> _make(ChatMemory chat) async {
    final maker = ref.read(chartMakerProvider);
    final text = _description.text.trim();
    if (maker == null || text.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final settings = await ref.read(settingsProvider.future);
      final spec = await maker.design(
        text,
        model: settings.generationModel,
        me: chat.myName.isEmpty ? 'Me' : chat.myName,
        them: chat.isGroup
            ? 'the others'
            : (chat.theirName.isEmpty ? 'Them' : chat.theirName),
      );
      if (mounted) setState(() => _spec = spec);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatsProvider);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final hasKey = ref.watch(chartMakerProvider) != null;

    return PaperScreen(
      children: [
        ScreenBar(
          title: 'Make a graph',
          onBack: () => Navigator.of(context).pop(),
        ),
        const SerifTitle('Graph ', accent: 'anything', trailing: '.'),
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
            final spec = _spec;
            return [
              if (learned.length > 1)
                ChatPicker(
                  chats: learned,
                  selected: chat.id,
                  onPick: (id) => setState(() => _chatId = id),
                ),
              ComposeField(
                controller: _description,
                fieldKey: const ValueKey('graph-field'),
                hint: 'describe the graph you want',
                enabled: hasKey,
                busy: _busy,
                tooltip: 'Make it',
                onSubmit: () => _make(chat),
              ),
              ExampleChips(
                examples: examples,
                onPick: (text) {
                  _description.text = text;
                  _make(chat);
                },
              ),
              if (!hasKey)
                const Notice(
                  'Add an API key in Settings to make graphs.',
                  tone: NoticeTone.caution,
                ),
              if (_error != null)
                FailureNotice(error: _error!, onRetry: () => _make(chat)),
              if (spec != null)
                FutureBuilder<ChartData>(
                  key: ValueKey((chat.id, spec)),
                  future: _count((chat.id, spec), chat),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return FailureNotice(error: snap.error!);
                    }
                    final data = snap.data;
                    if (data == null) {
                      return const LinearProgressIndicator(minHeight: 3);
                    }
                    if (data.isEmpty) {
                      return const Notice(
                        'Nothing to show for this chat: no dated messages '
                        'match.',
                      );
                    }
                    return PaperCard(child: ChartView(data: data));
                  },
                ),
            ];
          },
        ),
        Footnote(
          'Only your description goes to ${settings.generationModel}. The '
          'numbers are counted on this phone.',
        ),
      ],
    );
  }
}

typedef ChartMemoryKey = (int, ChartSpec);
