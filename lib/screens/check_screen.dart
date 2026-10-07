import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/stored_exchange.dart';
import '../services/message_check.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/chat_picker.dart';
import '../widgets/compose_field.dart';
import '../widgets/failure_text.dart';
import '../widgets/paper_ui.dart';

/// Before you send a message you wrote yourself: how it compares with how
/// you usually text that person, a free quick fix, and a rewrite in your
/// voice if you want one.
class CheckScreen extends ConsumerStatefulWidget {
  const CheckScreen({super.key});

  @override
  ConsumerState<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends ConsumerState<CheckScreen> {
  final _draft = TextEditingController();
  int? _chatId;
  bool _busy = false;
  Object? _error;
  List<String> _rewrites = const [];

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  Future<void> _rewrite(ChatMemory chat) async {
    final generator = ref.read(replyGeneratorProvider);
    final memory = ref.read(styleMemoryServiceProvider);
    final text = _draft.text.trim();
    if (generator == null || memory == null || text.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final settings = await ref.read(settingsProvider.future);
      final rewrites = await generator.rewriteMine(
        draft: text,
        settings: settings.copyWith(
          myName: chat.myName.isEmpty ? 'Me' : chat.myName,
          theirName: chat.theirName.isEmpty ? 'Them' : chat.theirName,
        ),
        profile: chat.profile,
        voiceSample: await memory.voiceSample(
          chatIds: {chat.id},
          preferChatId: chat.id,
        ),
        group: chat.isGroup,
      );
      if (mounted) setState(() => _rewrites = rewrites);
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
    final hasKey = ref.watch(replyGeneratorProvider) != null;

    return PaperScreen(
      children: [
        ScreenBar(
          title: 'Check my message',
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
            final check = MessageCheck.of(_draft.text, chat.profile);
            return [
              SerifTitle(
                'Does it sound like you to ',
                accent: bidiIsolate(them),
                trailing: '?',
                size: 30,
              ),
              if (learned.length > 1)
                ChatPicker(
                  chats: learned,
                  selected: chat.id,
                  onPick: (id) => setState(() {
                    _chatId = id;
                    _rewrites = const [];
                  }),
                ),
              ComposeField(
                controller: _draft,
                fieldKey: const ValueKey('check-field'),
                hint: 'paste or write the message you want to send',
                maxLines: 8,
                onChanged: (_) => setState(() => _rewrites = const []),
              ),
              if (check.verdict != CheckVerdict.unknown ||
                  check.findings.isNotEmpty)
                _Verdict(check: check),
              if (check.quickFix != null) ...[
                const MonoLabel('Quick fix · free'),
                SendableBubble(text: check.quickFix!, app: chat.app),
              ],
              if (_draft.text.trim().isNotEmpty)
                PaperAction(
                  key: const ValueKey('rewrite'),
                  title: 'Rewrite it like me',
                  subtitle: hasKey
                      ? 'Same message, your way · ${settings.generationModel}'
                      : 'Add an API key in Settings first',
                  tone: ActionTone.outline,
                  busy: _busy,
                  onTap: hasKey && !_busy ? () => _rewrite(chat) : null,
                ),
              if (_error != null)
                FailureNotice(error: _error!, onRetry: () => _rewrite(chat)),
              for (final (i, text) in _rewrites.indexed)
                SendableBubble(
                  key: ValueKey('rewrite-$i'),
                  text: text,
                  app: chat.app,
                ),
            ];
          },
        ),
        const Footnote(
          'The check runs on your phone. Only "Rewrite it like me" sends '
          'anything.',
        ),
      ],
    );
  }
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.check});

  final MessageCheck check;

  @override
  Widget build(BuildContext context) {
    final (title, colour) = switch (check.verdict) {
      CheckVerdict.likeYou => ('Sounds like you', Paper.green),
      CheckVerdict.close => ('Nearly you', Paper.warnText),
      CheckVerdict.notYou => ('Not quite you', Paper.errorText),
      CheckVerdict.unknown => ('', Paper.muted),
    };
    return PaperCard(
      key: const ValueKey('check-verdict'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title.isNotEmpty) ...[
            Text(title, style: Type.display(22, color: colour)),
            const SizedBox(height: 6),
          ],
          for (final f in check.findings)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 8),
                    child: Icon(
                      f.fine
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 16,
                      color: f.fine ? Paper.green : Paper.warnText,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      f.text,
                      style: Type.prose(
                        size: 13.5,
                        color: Paper.body,
                        height: 1.4,
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
}
