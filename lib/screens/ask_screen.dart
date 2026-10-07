import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/stored_exchange.dart';
import '../services/ask_chats.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/chat_picker.dart';
import '../widgets/compose_field.dart';
import '../widgets/failure_text.dart';
import '../widgets/moment_card.dart';
import '../widgets/paper_ui.dart';
import '../widgets/bidi.dart';

/// Ask a question about your chats and get an answer, with the moments it
/// came from.
class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key});

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final _question = TextEditingController();

  /// `null` asks every chat.
  int? _chatId;
  bool _busy = false;
  Object? _error;
  AskAnswer? _answer;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  static List<ChatMemory> _askable(List<ChatMemory> all, AppSettings s) => [
    for (final c in all)
      if (!c.isEmpty && c.matches(s.embeddingModel, s.embeddingDimensions)) c,
  ];

  Future<void> _ask(List<ChatMemory> chats) async {
    final asker = ref.read(askChatsProvider);
    final text = _question.text.trim();
    if (asker == null || text.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final settings = await ref.read(settingsProvider.future);
      final picked = [
        for (final c in chats)
          if (_chatId == null || c.id == _chatId) c,
      ];
      final answer = await asker.ask(
        text,
        chatIds: {for (final c in picked) c.id},
        chatNames: {for (final c in chats) c.id: c.theirName},
        myName: picked.isEmpty ? settings.myName : picked.first.myName,
        model: settings.generationModel,
        embeddingModel: settings.embeddingModel,
        dimensions: settings.embeddingDimensions,
      );
      if (mounted) setState(() => _answer = answer);
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
    final hasKey = ref.watch(askChatsProvider) != null;

    return PaperScreen(
      children: [
        ScreenBar(
          title: 'Ask your chats',
          onBack: () => Navigator.of(context).pop(),
        ),
        const SerifTitle('Ask your ', accent: 'chats', trailing: '.'),
        ...chats.when(
          loading: () => [const LinearProgressIndicator(minHeight: 3)],
          error: (error, _) => [FailureNotice(error: error)],
          data: (all) {
            final askable = _askable(all, settings);
            if (askable.isEmpty) {
              return const [
                Notice(
                  'Import a chat first.',
                  tone: NoticeTone.caution,
                  title: 'Nothing to ask',
                ),
              ];
            }
            final names = {
              for (final c in all)
                c.id: c.theirName.isEmpty ? 'Unnamed chat' : c.theirName,
            };
            final answer = _answer;
            return [
              ComposeField(
                controller: _question,
                fieldKey: const ValueKey('ask-field'),
                hint: 'when did we first talk about moving?',
                enabled: hasKey,
                busy: _busy,
                tooltip: 'Ask',
                onSubmit: () => _ask(askable),
              ),
              if (askable.length > 1)
                ChatPicker(
                  chats: askable,
                  selected: _chatId,
                  allLabel: 'All chats',
                  onPick: (id) => setState(() => _chatId = id),
                ),
              if (!hasKey)
                const Notice(
                  'Add an OpenAI or Gemini key in Settings to ask.',
                  tone: NoticeTone.caution,
                ),
              if (_error != null)
                FailureNotice(error: _error!, onRetry: () => _ask(askable)),
              if (answer != null) ...[
                PaperCard(
                  child: Text(
                    answer.text,
                    textDirection: directionOf(answer.text),
                    key: const ValueKey('ask-answer'),
                    style: Type.prose(
                      size: 15.5,
                      color: Paper.ink,
                      height: 1.5,
                    ),
                  ),
                ),
                if (answer.cited.isNotEmpty) ...[
                  const MonoLabel('Where that comes from'),
                  for (final (n, hit) in answer.cited)
                    MomentCard(
                      key: ValueKey('cited-$n'),
                      hit: hit,
                      label: '[$n]',
                      chat: names[hit.exchange.chatId] ?? '',
                      myName:
                          {
                            for (final c in all) c.id: c.myName,
                          }[hit.exchange.chatId] ??
                          '',
                    ),
                ],
              ],
            ];
          },
        ),
        Footnote(
          'Sends your question and the ${AskChats.moments} moments closest to '
          'it to ${settings.generationModel}.',
        ),
      ],
    );
  }
}
