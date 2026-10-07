import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../models/extracted_message.dart';
import '../../models/chat_app.dart';
import '../../theme/bubbles.dart';
import '../../theme/tokens.dart';
import '../../widgets/paper_ui.dart';
import '../../widgets/bidi.dart';

/// What the vision model read, and the correction affordances.
class Transcript extends StatelessWidget {
  const Transcript({
    required this.messages,
    required this.settings,
    required this.fixing,
    required this.onToggleFixing,
    required this.onToggleSide,
    required this.onEdit,
    this.app = ChatApp.whatsapp,
    super.key,
  });

  final List<ExtractedMessage> messages;
  final AppSettings settings;
  final bool fixing;
  final VoidCallback onToggleFixing;
  final ValueChanged<int> onToggleSide;
  final ValueChanged<int> onEdit;

  /// Whose colours the bubbles are drawn in.
  final ChatApp app;

  @override
  Widget build(BuildContext context) {
    // Collapsed, the transcript shows only the tail — the exchange being
    // replied to. Fixing shows every message with its controls.
    final visible = fixing || messages.length <= 3
        ? messages
        : messages.sublist(messages.length - 3);
    final hidden = messages.length - visible.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: MonoLabel(
                'It read ${messages.length} '
                '${messages.length == 1 ? "message" : "messages"}',
                spacing: 0.12,
              ),
            ),
            GestureDetector(
              onTap: onToggleFixing,
              child: Text(
                fixing ? 'Done fixing' : 'Fix the reading',
                style: Type.prose(
                  size: 12,
                  color: Paper.accent,
                  height: 1.3,
                  weight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        // The conversation as it would look in the chat itself: bubbles on
        // the chat's wallpaper.
        PaperPanel(
          color: Paper.chatBg,
          radius: Corner.card,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hidden > 0) ...[
                Text(
                  '…$hidden earlier',
                  style: Type.prose(size: 12, color: Paper.muted, height: 1.3),
                ),
                const SizedBox(height: 7),
              ],
              for (var i = 0; i < visible.length; i++)
                _TranscriptLine(
                  app: app,
                  message: visible[i],
                  settings: settings,
                  fixing: fixing,
                  onToggleSide: () =>
                      onToggleSide(messages.length - visible.length + i),
                  onEdit: () => onEdit(messages.length - visible.length + i),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TranscriptLine extends StatelessWidget {
  const _TranscriptLine({
    required this.message,
    required this.settings,
    required this.fixing,
    required this.onToggleSide,
    required this.onEdit,
    required this.app,
  });

  final ExtractedMessage message;
  final ChatApp app;
  final AppSettings settings;
  final bool fixing;
  final VoidCallback onToggleSide;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final mine = message.speaker == Speaker.me;
    final bubbles = Bubbles.of(app);
    final bubble = GestureDetector(
      onTap: fixing ? onEdit : null,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.62,
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: bubbles
            .fill(mine: mine)
            .copyWith(
              borderRadius: BorderRadius.only(
                topLeft: mine ? Corner.bubble : Corner.tail,
                topRight: mine ? Corner.tail : Corner.bubble,
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
        child: ContentDirection(
          text: message.text,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The message this one replies to, drawn like WhatsApp's quote
              // box so it reads as context rather than as words sent here.
              // In a group, who wrote it, as WhatsApp labels the others'
              // bubbles.
              if (!mine && message.author != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    message.author!,
                    style: Type.strong(
                      size: 12.5,
                      color: _authorColour(message.author!),
                      height: 1.3,
                    ),
                  ),
                ),
              if (message.quoted != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 5),
                  padding: const EdgeInsets.fromLTRB(7, 3, 7, 3),
                  decoration: BoxDecoration(
                    color: mine
                        ? Paper.accent.withValues(alpha: 0.12)
                        : Paper.panel,
                    border: Border(
                      left: BorderSide(color: Paper.accent, width: 2.5),
                    ),
                  ),
                  child: Text(
                    message.quoted!,
                    textDirection: directionOf(message.quoted!),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Type.prose(
                      size: 12,
                      color: Paper.tertiary,
                      height: 1.35,
                    ),
                  ),
                ),
              Text(
                message.text,
                textDirection: directionOf(message.text),
                style: Type.prose(
                  size: 13.5,
                  color: bubbles.text(mine: mine),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (mine && fixing) _SideToggle(onTap: onToggleSide, mine: true),
          bubble,
          if (!mine && fixing) _SideToggle(onTap: onToggleSide, mine: false),
        ],
      ),
    );
  }
}

/// The correction that matters most: which side a message came from.
class _SideToggle extends StatelessWidget {
  const _SideToggle({required this.onTap, required this.mine});

  final VoidCallback onTap;
  final bool mine;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: EdgeInsets.only(right: mine ? 8 : 0, left: mine ? 0 : 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Paper.card,
        borderRadius: Corner.all(Corner.pill),
        border: Border.all(color: Paper.border),
      ),
      child: Text(
        mine ? '→ them' : 'me ←',
        style: Type.prose(
          size: 11,
          color: Paper.secondary,
          height: 1.2,
          weight: FontWeight.w500,
        ),
      ),
    ),
  );
}

/// A steady colour per name, from a small set that reads on both themes, so
/// the members of a group are told apart at a glance as in WhatsApp.
Color _authorColour(String name) {
  const light = [
    Color(0xFF1F7AC6),
    Color(0xFFB4501E),
    Color(0xFF7B4FC6),
    Color(0xFF0F8A5F),
    Color(0xFFC0306A),
    Color(0xFF8A6D00),
  ];
  const dark = [
    Color(0xFF6CB6FF),
    Color(0xFFFFA36B),
    Color(0xFFC3A1FF),
    Color(0xFF53D6A0),
    Color(0xFFFF8BB8),
    Color(0xFFE6C34F),
  ];
  final palette = Paper.isDark ? dark : light;
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}
