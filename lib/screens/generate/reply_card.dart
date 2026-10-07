import 'package:flutter/material.dart';

import '../../models/reply_suggestion.dart';
import '../../services/reply_generator.dart';
import '../../models/chat_app.dart';
import '../../theme/bubbles.dart';
import '../../theme/tokens.dart';
import '../../widgets/bidi.dart';

/// One suggested message: what it is for, its bubbles, and what can be done
/// with it — copy, tweak, or star it into the memory.
class ReplyCard extends StatelessWidget {
  const ReplyCard({
    required this.suggestion,
    required this.provenance,
    required this.bubblesCopied,
    required this.onCopy,
    required this.onRefine,
    this.refining,
    this.saved = false,
    this.saving = false,
    this.onSave,
    this.app = ChatApp.whatsapp,
    super.key,
  });

  final ReplySuggestion suggestion;

  /// Whose colours the bubbles are drawn in.
  final ChatApp app;
  final String provenance;

  /// How many of this suggestion's bubbles have been copied so far.
  final int bubblesCopied;

  /// Copies the next bubble, or the whole message if it is one bubble.
  final VoidCallback onCopy;

  final ValueChanged<Refinement> onRefine;

  /// The tweak being worked on, if any.
  final Refinement? refining;

  final bool saved;
  final bool saving;

  /// Stars it into the memory; `null` when there is no chat to save into.
  final VoidCallback? onSave;

  /// A line break in a suggestion means a separate WhatsApp bubble.
  static List<String> bubblesOf(String text) => text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final changesSubject = suggestion.isNewTopic;
    final bubbles = bubblesOf(suggestion.text);
    final split = bubbles.length > 1;
    final allCopied = bubblesCopied >= bubbles.length && bubblesCopied > 0;
    final copyLabel = !split
        ? (allCopied ? 'Copied' : 'Copy')
        : allCopied
        ? 'All copied'
        : 'Copy ${bubblesCopied + 1} of ${bubbles.length}';
    final busy = refining != null;

    final maxBubble = MediaQuery.sizeOf(context).width * 0.8;

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // What this option is for. The one that changes the subject is
          // marked in the accent colour because it is the odd one out, and
          // picking it by accident would send the conversation sideways.
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (changesSubject)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Icon(
                      Icons.alt_route_rounded,
                      size: 14,
                      color: Paper.accent,
                    ),
                  ),
                Text(
                  split
                      ? '${suggestion.kind.label} · ${bubbles.length} bubbles'
                      : suggestion.kind.label,
                  style: Type.strong(
                    size: 12,
                    color: changesSubject ? Paper.accent : Paper.muted,
                  ),
                ),
              ],
            ),
          ),
          // The suggestion as it would look once sent: your green bubbles,
          // on the right.
          AnimatedOpacity(
            opacity: busy ? 0.45 : 1,
            duration: const Duration(milliseconds: 150),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxBubble),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < bubbles.length; i++)
                    _Bubble(
                      app: app,
                      text: split ? bubbles[i] : suggestion.text,
                      copied: i < bubblesCopied,
                      first: i == 0,
                      meta: i == bubbles.length - 1 ? provenance : null,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, box) {
              // The quick tweaks wrap onto a second line when the copy button
              // leaves too little room, so no chip is ever cut off. On a narrow
              // screen or with large text they get a line of their own.
              final chips = Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final refinement in Refinement.values)
                    _Chip(
                      label: refinement.label,
                      busy: refining == refinement,
                      onTap: busy ? null : () => onRefine(refinement),
                    ),
                ],
              );
              final actions = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StarButton(saved: saved, saving: saving, onTap: onSave),
                  const SizedBox(width: 8),
                  _CopyButton(
                    label: copyLabel,
                    allCopied: allCopied,
                    onTap: busy ? null : onCopy,
                  ),
                ],
              );
              final scale = MediaQuery.textScalerOf(context).scale(1);
              if (box.maxWidth < 340 * scale) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    chips,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: chips),
                  const SizedBox(width: 8),
                  actions,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.label, required this.allCopied, this.onTap});

  final String label;
  final bool allCopied;
  final VoidCallback? onTap;

  static Color get _onAccent => Paper.isDark ? Paper.onInk : Colors.white;

  @override
  Widget build(BuildContext context) => Material(
    color: allCopied ? Paper.green : Paper.accent,
    borderRadius: Corner.all(Corner.pill),
    child: InkWell(
      onTap: onTap,
      borderRadius: Corner.all(Corner.pill),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 15, 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              allCopied ? Icons.done_all_rounded : Icons.content_copy_rounded,
              size: 15,
              color: _onAccent,
            ),
            const SizedBox(width: 6),
            Text(label, style: Type.strong(size: 13, color: _onAccent)),
          ],
        ),
      ),
    ),
  );
}

/// One outgoing bubble. The first of a run has the tail; a copied bubble
/// shows WhatsApp's double tick, and the last carries the provenance where a
/// sent message shows its time.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.copied,
    required this.first,
    required this.app,
    this.meta,
  });

  final ChatApp app;
  final String text;
  final bool copied;
  final bool first;
  final String? meta;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
      decoration: Bubbles.of(app)
          .fill(mine: true)
          .copyWith(
            borderRadius: BorderRadius.only(
              topLeft: Corner.bubble,
              topRight: first ? Corner.tail : Corner.bubble,
              bottomLeft: Corner.bubble,
              bottomRight: Corner.bubble,
            ),
            boxShadow: [
              BoxShadow(
                color: Paper.shadowSoft,
                blurRadius: 1,
                offset: const Offset(0, 1),
              ),
            ],
          ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: Text(
              text,
              textDirection: directionOf(text),
              style: Type.prose(
                size: 15.5,
                color: Bubbles.of(app).mineText,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (meta != null)
                Flexible(
                  child: Text(
                    meta!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.numeric(
                      size: 10.5,
                      color: Bubbles.of(app).mineMuted,
                      weight: FontWeight.w400,
                    ),
                  ),
                ),
              if (copied) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.done_all_rounded,
                  size: 15,
                  color: Bubbles.of(app).mineText,
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.busy, this.onTap});

  final String label;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Paper.accentSoft,
        borderRadius: Corner.all(Corner.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.prose(
                size: 12,
                color: onTap == null && !busy
                    ? Paper.placeholder
                    : Paper.accent,
                height: 1.2,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _StarButton extends StatelessWidget {
  const _StarButton({
    required this.saved,
    required this.saving,
    required this.onTap,
  });

  final bool saved;
  final bool saving;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (saving) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 1.5),
      );
    }
    return Tooltip(
      message: saved
          ? 'Saved to your memory'
          : onTap == null
          ? 'Pick a chat to save into'
          : 'I sent this — learn from it',
      child: GestureDetector(
        onTap: saved ? null : onTap,
        child: Icon(
          saved ? Icons.star : Icons.star_border,
          size: 20,
          color: saved
              ? Paper.amber
              : onTap == null
              ? Paper.placeholder
              : Paper.tertiary,
        ),
      ),
    );
  }
}
