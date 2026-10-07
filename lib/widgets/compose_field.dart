import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_app.dart';
import '../theme/bubbles.dart';
import '../theme/tokens.dart';
import 'failure_text.dart';
import 'bidi.dart';

/// A text box that grows a line at a time as you write, with an optional
/// button at its end, by the last line.
class ComposeField extends StatelessWidget {
  const ComposeField({
    required this.controller,
    required this.hint,
    this.fieldKey,
    this.enabled = true,
    this.busy = false,
    this.onSubmit,
    this.icon = Icons.arrow_upward_rounded,
    this.tooltip = 'Go',
    this.onChanged,
    this.maxLines = 6,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final Key? fieldKey;
  final bool enabled;
  final bool busy;
  final VoidCallback? onSubmit;
  final IconData icon;
  final String tooltip;
  final ValueChanged<String>? onChanged;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Paper.card,
      borderRadius: Corner.all(Corner.field),
      border: Border.all(color: Paper.border, width: 1.5),
    ),
    padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: AutoDirection(
            controller: controller,
            builder: (context) => TextField(
              key: fieldKey,
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: maxLines,
              onChanged: onChanged,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              style: Type.prose(size: 15, color: Paper.ink, height: 1.4),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                hintStyle: Type.prose(size: 15, color: Paper.placeholder),
              ),
            ),
          ),
        ),
        if (onSubmit != null || busy)
          SizedBox(
            width: 44,
            height: 44,
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: tooltip,
                    onPressed: enabled ? onSubmit : null,
                    icon: Icon(icon, color: Paper.accent),
                  ),
          ),
      ],
    ),
  );
}

/// A message you could send, drawn as your bubble in the chat's colours,
/// with a copy button under it.
class SendableBubble extends StatelessWidget {
  const SendableBubble({
    required this.text,
    this.app = ChatApp.whatsapp,
    this.caption,
    super.key,
  });

  final String text;
  final ChatApp app;

  /// A small note under the bubble, such as what it is for.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final bubbles = Bubbles.of(app);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.8,
          ),
          padding: const EdgeInsets.fromLTRB(13, 9, 13, 9),
          decoration: bubbles
              .fill(mine: true)
              .copyWith(
                borderRadius: const BorderRadius.only(
                  topLeft: Corner.bubble,
                  topRight: Corner.tail,
                  bottomLeft: Corner.bubble,
                  bottomRight: Corner.bubble,
                ),
              ),
          child: Text(
            text,
            textDirection: directionOf(text),
            style: Type.prose(size: 15, color: bubbles.mineText, height: 1.4),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (caption != null)
              Flexible(
                child: Text(
                  caption!,
                  style: Type.prose(size: 12, color: Paper.muted),
                ),
              ),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) showToast(context, 'Copied.');
              },
              icon: Icon(Icons.copy_rounded, size: 16, color: Paper.accent),
              label: Text(
                'Copy',
                style: Type.strong(size: 13, color: Paper.accent),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
