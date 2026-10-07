import 'package:flutter/material.dart';

import '../../models/stored_exchange.dart';
import '../../theme/tokens.dart';
import '../../widgets/failure_text.dart';
import '../../widgets/format.dart';
import '../../widgets/paper_ui.dart';
import '../../widgets/bidi.dart';

/// The top bar: back, who you are replying to, and a new source.
class GenerateHeader extends StatelessWidget {
  const GenerateHeader({
    required this.them,
    required this.onBack,
    required this.onChangeSource,
    this.onPickChat,
    super.key,
  });

  final String them;
  final VoidCallback onBack;

  /// Starts again from a new screenshot or paste; `null` before the first.
  final VoidCallback? onChangeSource;

  /// Opens the chat chooser; `null` when there is only one choice.
  final VoidCallback? onPickChat;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      BackArrow(onTap: onBack),
      Expanded(
        child: Center(
          child: GestureDetector(
            onTap: onPickChat,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    'Replying to ${bidiIsolate(them)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.strong(size: 15, height: 1.3),
                  ),
                ),
                if (onPickChat != null)
                  Icon(Icons.expand_more, size: 18, color: Paper.tertiary),
              ],
            ),
          ),
        ),
      ),
      GestureDetector(
        onTap: onChangeSource,
        child: Text(
          'Start over',
          style: Type.prose(
            size: 12,
            color: onChangeSource == null ? Paper.muted : Paper.accent,
            height: 1.3,
            weight: FontWeight.w500,
          ),
        ),
      ),
    ],
  );
}

/// Chooses who the reply is to, among the learned chats — or someone new —
/// and whether it may also borrow from the other chats.
///
/// Returns the chosen chat, `null` for "someone else", or nothing if
/// dismissed; callers tell the last two apart with the record's flag.
Future<({ChatMemory? chat})?> pickReplyChat(
  BuildContext context, {
  required List<ChatMemory> chats,
  required ChatMemory? current,
  required bool useAllChats,
  required ValueChanged<bool> onUseAllChats,
}) => showModalBottomSheet<({ChatMemory? chat})>(
  context: context,
  backgroundColor: Paper.bg,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Corner.card),
  ),
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MonoLabel('Replying to'),
          const SizedBox(height: 8),
          for (final chat in chats)
            _ChoiceRow(
              title: chat.theirName.isEmpty ? 'Unnamed chat' : chat.theirName,
              subtitle: '${grouped(chat.exchangeCount)} replies learned',
              selected: current?.id == chat.id,
              onTap: () => Navigator.of(context).pop((chat: chat)),
            ),
          _ChoiceRow(
            title: 'Someone else',
            subtitle: 'Written in your voice, from all your chats',
            selected: current == null,
            onTap: () => Navigator.of(context).pop((chat: null)),
          ),
          if (chats.length > 1) ...[
            const SizedBox(height: 6),
            Divider(height: 1, color: Paper.divider),
            _AllChatsSwitch(value: useAllChats, onChanged: onUseAllChats),
          ],
        ],
      ),
    ),
  ),
);

/// Whether a reply to one person also borrows from the other chats.
class _AllChatsSwitch extends StatefulWidget {
  const _AllChatsSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_AllChatsSwitch> createState() => _AllChatsSwitchState();
}

class _AllChatsSwitchState extends State<_AllChatsSwitch> {
  late bool _on = widget.value;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const ValueKey('use-all-chats'),
    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
    value: _on,
    activeThumbColor: Paper.accent,
    title: Text(
      'Also learn from my other chats',
      style: Type.strong(size: 15, height: 1.3),
    ),
    subtitle: Text(
      _on
          ? 'More examples, less like how you text this person'
          : 'Only your chat with this person',
      style: Type.prose(size: 12.5, color: Paper.muted, height: 1.3),
    ),
    onChanged: (on) {
      setState(() => _on = on);
      widget.onChanged(on);
    },
  );
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: Corner.all(Corner.small),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Type.strong(size: 15, height: 1.3)),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Type.prose(
                    size: 12.5,
                    color: Paper.muted,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          if (selected) Icon(Icons.check, size: 18, color: Paper.accent),
        ],
      ),
    ),
  );
}

/// Before anything is picked: a screenshot, or a paste.
class EmptyState extends StatelessWidget {
  const EmptyState({required this.onPick, required this.onPaste, super.key});

  final VoidCallback onPick;
  final VoidCallback onPaste;

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
            const SerifTitle('Screenshot the chat as it stands.', size: 30),
            const SizedBox(height: 10),
            Text(
              'Pick one or more screenshots; several are joined into one.',
              style: Type.prose(size: 14.5),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      PaperAction(
        title: 'Pick screenshots',
        centred: true,
        tone: ActionTone.accent,
        onTap: onPick,
      ),
      const SizedBox(height: 10),
      PaperAction(
        title: 'Paste the conversation',
        subtitle: 'Faster and cheaper — no screenshot to read',
        tone: ActionTone.outline,
        onTap: onPaste,
      ),
      const SizedBox(height: 10),
      const Footnote(
        'You can also share a screenshot to Ditto from your gallery.',
      ),
    ],
  );
}

class ReadingState extends StatelessWidget {
  const ReadingState({this.count = 1, super.key});

  /// How many screenshots are being read at once.
  final int count;

  @override
  Widget build(BuildContext context) => PaperPanel(
    padding: const EdgeInsets.fromLTRB(15, 15, 15, 15),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonoLabel(
          count == 1 ? 'Reading the screenshot' : 'Reading $count screenshots',
          spacing: 0.12,
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: Corner.all(Corner.pill),
          child: const LinearProgressIndicator(minHeight: 4),
        ),
        const SizedBox(height: 10),
        Text(
          count == 1
              ? 'Working out who said what, oldest first.'
              : 'Working out who said what, then joining them up where they '
                    'overlap.',
          style: Type.prose(size: 13, color: Paper.body, height: 1.45),
        ),
      ],
    ),
  );
}

class GeneratingState extends StatelessWidget {
  const GeneratingState({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < 3; i++) ...[
        if (i > 0) const SizedBox(height: 10),
        Container(
          height: 92,
          decoration: BoxDecoration(
            color: Paper.card,
            borderRadius: Corner.all(Corner.card),
            boxShadow: Paper.liftCard,
          ),
        ),
      ],
    ],
  );
}

/// A one-off instruction for this reply.
///
/// The retrieved examples decide how a message is written; this decides what
/// it says. It is deliberately per-screenshot rather than a saved setting,
/// because it is about this moment in the conversation.
class NoteField extends StatelessWidget {
  const NoteField({
    required this.controller,
    required this.onCommit,
    super.key,
  });

  final TextEditingController controller;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const MonoLabel('Anything it should know', spacing: 0.12),
      const SizedBox(height: 8),
      AutoDirection(
        controller: controller,
        builder: (context) => TextField(
          controller: controller,
          maxLines: null,
          minLines: 2,
          textCapitalization: TextCapitalization.sentences,
          style: Type.prose(size: 14, color: Paper.ink, height: 1.45),
          onTapOutside: (_) => onCommit(),
          onEditingComplete: onCommit,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Paper.card,
            hintText:
                "say I'll be late \u00b7 keep it short \u00b7 ask about "
                'the weekend',
            hintStyle: Type.prose(size: 14, color: Paper.placeholder),
            contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            border: OutlineInputBorder(
              borderRadius: Corner.all(Corner.small),
              borderSide: BorderSide(color: Paper.border, width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: Corner.all(Corner.small),
              borderSide: BorderSide(color: Paper.border, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: Corner.all(Corner.small),
              borderSide: BorderSide(color: Paper.accent, width: 1.5),
            ),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(
        'Optional. What the message should say.',
        style: Type.prose(size: 12.5, color: Paper.muted, height: 1.4),
      ),
    ],
  );
}

/// Where the replies came from — and the way into reading it.
class Provenance extends StatelessWidget {
  const Provenance({
    required this.examples,
    required this.model,
    required this.mode,
    required this.onInspect,
    this.skipped = const [],
    super.key,
  });

  final List<ScoredExchange> examples;

  /// Ticked chats that couldn't be searched: built with another model.
  final List<ChatMemory> skipped;
  final String model;
  final String mode;
  final VoidCallback onInspect;

  @override
  Widget build(BuildContext context) {
    final none = examples.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (skipped.isNotEmpty) ...[
          Notice(
            '${nameList([for (final c in skipped) c.theirName])} left out: '
            'import again to rebuild.',
            tone: NoticeTone.caution,
          ),
          const SizedBox(height: 10),
        ],
        if (none)
          const Notice(
            'These lean on your habits instead.',
            tone: NoticeTone.caution,
            title: 'Nothing similar in your memory',
          )
        else
          emphasised(
            'Built from *${examples.length} past '
            '${examples.length == 1 ? "exchange" : "exchanges"}* that looked '
            'like this one — closest match '
            '${examples.first.similarity.toStringAsFixed(2)}.',
            size: 12.5,
            color: Paper.tertiary,
          ),
        const SizedBox(height: 6),
        Text(
          'written by $model · $mode',
          style: Type.numeric(
            size: 12.5,
            color: Paper.muted,
            weight: FontWeight.w400,
          ),
        ),
        const SizedBox(height: 12),
        // The app showing its working: the retrieved conversations are the
        // whole reason the replies sound like the user, so they are readable.
        PaperAction(
          title: none
              ? 'See why nothing matched'
              : 'Read the ${examples.length} chats it drew on',
          subtitle: none
              ? 'What retrieval looked for'
              : 'Your real exchanges, closest first',
          tone: ActionTone.outline,
          onTap: onInspect,
        ),
      ],
    );
  }
}

/// The three refusals, each with the way out the design gives it.
class Refusal extends StatelessWidget {
  const Refusal({required this.error, this.onFlipAll, this.onFix, super.key});

  final Object error;
  final VoidCallback? onFlipAll;
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    final message = describeFailure(error);
    final sidesLikelyBackwards = onFlipAll != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Notice(
          sidesLikelyBackwards
              ? 'The last message reads as yours, so there’s nothing to '
                    'reply to. Usually the sides came out backwards.'
              : message,
          tone: NoticeTone.failure,
        ),
        if (sidesLikelyBackwards) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: PaperAction(
                  title: 'Flip everything',
                  centred: true,
                  radius: Corner.small,
                  onTap: onFlipAll,
                ),
              ),
              if (onFix != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: PaperAction(
                    title: 'Fix the reading',
                    centred: true,
                    tone: ActionTone.outline,
                    radius: Corner.small,
                    onTap: onFix,
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
