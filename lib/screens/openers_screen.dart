import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/stored_exchange.dart';
import '../services/chat_facts.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/chat_picker.dart';
import '../widgets/compose_field.dart';
import '../widgets/failure_text.dart';
import '../widgets/paper_ui.dart';

/// When a chat has gone quiet: messages to start it up again, in your voice,
/// following up on what you talked about and what you know about them.
class OpenersScreen extends ConsumerStatefulWidget {
  const OpenersScreen({this.chat, super.key});

  /// The chat to open on.
  final ChatMemory? chat;

  @override
  ConsumerState<OpenersScreen> createState() => _OpenersScreenState();
}

class _OpenersScreenState extends ConsumerState<OpenersScreen> {
  final _note = TextEditingController();
  late int? _chatId = widget.chat?.id;
  bool _busy = false;
  Object? _error;
  List<String> _openers = const [];

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// "3 days", "2 weeks", "4 months", or empty when unknown or recent.
  static String quietFor(DateTime? last, [DateTime? now]) {
    if (last == null) return '';
    final days = (now ?? DateTime.now()).difference(last).inDays;
    if (days < 1) return '';
    if (days < 14) return '$days ${days == 1 ? "day" : "days"}';
    if (days < 60) return '${days ~/ 7} weeks';
    return '${days ~/ 30} months';
  }

  Future<void> _suggest(ChatMemory chat) async {
    final generator = ref.read(replyGeneratorProvider);
    final memory = ref.read(styleMemoryServiceProvider);
    if (generator == null || memory == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final settings = await ref.read(settingsProvider.future);
      final recent = await memory.latestTurns(chat);
      final voice = await memory.voiceSample(
        chatIds: {chat.id},
        preferChatId: chat.id,
      );
      final facts = [
        for (final f
            in (await ref.read(factsStoreProvider).forChat(chat.id))?.facts ??
                const <ChatFact>[])
          f.text,
      ];
      final styleGuide =
          (await ref.read(analysisStoreProvider).forChat(chat.id))?.writing ??
          const <String>[];
      final openers = await generator.openers(
        settings: settings.copyWith(
          myName: chat.myName.isEmpty ? 'Me' : chat.myName,
          theirName: chat.theirName.isEmpty ? 'Them' : chat.theirName,
        ),
        recent: recent,
        profile: chat.profile,
        voiceSample: voice,
        facts: facts,
        styleGuide: styleGuide,
        note: _note.text,
        quietFor: quietFor(chat.lastMessageAt),
        group: chat.isGroup,
      );
      if (mounted) setState(() => _openers = openers);
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
          title: 'Start a conversation',
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
                SerifTitle('No one to text yet.', size: 34),
                Notice('Import a chat first.', tone: NoticeTone.caution),
              ];
            }
            final chat = learned.firstWhere(
              (c) => c.id == _chatId,
              orElse: () => learned.first,
            );
            final them = chat.theirName.isEmpty ? 'them' : chat.theirName;
            final quiet = quietFor(chat.lastMessageAt);
            return [
              SerifTitle(
                'Something to send ',
                accent: bidiIsolate(them),
                trailing: '.',
                size: 32,
              ),
              if (learned.length > 1)
                ChatPicker(
                  chats: learned,
                  selected: chat.id,
                  onPick: (id) => setState(() {
                    _chatId = id;
                    _openers = const [];
                  }),
                ),
              if (quiet.isNotEmpty)
                Text(
                  'Your export with ${bidiIsolate(them)} ends $quiet ago.',
                  style: Type.prose(size: 14, color: Paper.body),
                ),
              ComposeField(
                controller: _note,
                hint: 'optional: about the trip, ask her out…',
                maxLines: 3,
              ),
              PaperAction(
                key: const ValueKey('suggest-openers'),
                title: _openers.isEmpty
                    ? 'Suggest openers'
                    : 'Suggest different ones',
                subtitle: hasKey
                    ? 'Written by ${settings.generationModel}'
                    : 'Add an API key in Settings first',
                tone: _openers.isEmpty ? ActionTone.accent : ActionTone.outline,
                busy: _busy,
                onTap: hasKey && !_busy ? () => _suggest(chat) : null,
              ),
              if (_error != null)
                FailureNotice(error: _error!, onRetry: () => _suggest(chat)),
              for (final (i, text) in _openers.indexed)
                SendableBubble(
                  key: ValueKey('opener-$i'),
                  text: text,
                  app: chat.app,
                ),
            ];
          },
        ),
        const Footnote(
          'Uses the end of your chat, things from Remember, and how you text '
          'them.',
        ),
      ],
    );
  }
}
