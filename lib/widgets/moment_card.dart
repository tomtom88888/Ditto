import 'package:flutter/material.dart';

import '../services/chat_search.dart';
import '../theme/bubbles.dart';
import '../theme/tokens.dart';
import 'chat_apps.dart';
import 'format.dart';
import 'paper_ui.dart';
import 'bidi.dart';

/// One moment from a chat: when and where, the lead-up, and your reply, in
/// the chat's own colours.
class MomentCard extends StatefulWidget {
  const MomentCard({
    required this.hit,
    this.label,
    required this.chat,
    required this.myName,
    super.key,
  });

  final SearchHit hit;

  /// Shown before the date, such as a citation number.
  final String? label;
  final String chat;
  final String myName;

  @override
  State<MomentCard> createState() => _MomentCardState();
}

class _MomentCardState extends State<MomentCard> {
  bool _open = false;

  static const int _collapsed = 3;

  @override
  Widget build(BuildContext context) {
    final e = widget.hit.exchange;
    final when = e.timestamp;
    final turns = _open || e.context.length <= _collapsed
        ? e.context
        : e.context.sublist(e.context.length - _collapsed);
    final hidden = e.context.length - turns.length;
    final bubbles = Bubbles.of(ChatApps.of(context, e.chatId));

    return PaperCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.label == null ? "" : "${widget.label}  "}'
                  '${when == null ? "Date unknown" : dayMonthYear(when)}'
                  '${widget.chat.isEmpty ? "" : " · ${bidiIsolate(widget.chat)}"}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Type.strong(size: 13, height: 1.3),
                ),
              ),
              if (widget.hit.wordMatch) ...[
                Icon(Icons.text_fields_rounded, size: 14, color: Paper.accent),
                const SizedBox(width: 4),
              ],
              Text(
                widget.hit.score.clamp(0, 1).toStringAsFixed(2),
                style: Type.numeric(
                  size: 11.5,
                  color: Paper.muted,
                  weight: FontWeight.w400,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (hidden > 0)
            GestureDetector(
              onTap: () => setState(() => _open = true),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '…$hidden earlier · show',
                  style: Type.prose(size: 12, color: Paper.accent),
                ),
              ),
            ),
          for (final turn in turns)
            _MomentLine(
              text: turn.text,
              who: turn.sender,
              mine: turn.sender == widget.myName,
              bubbles: bubbles,
            ),
          _MomentLine(
            text: e.replyText,
            who: 'You',
            mine: true,
            reply: true,
            bubbles: bubbles,
          ),
        ],
      ),
    );
  }
}

class _MomentLine extends StatelessWidget {
  const _MomentLine({
    required this.text,
    required this.who,
    required this.mine,
    required this.bubbles,
    this.reply = false,
  });

  final String text;
  final String who;
  final bool mine;
  final bool reply;
  final Bubbles bubbles;

  @override
  Widget build(BuildContext context) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      constraints: const BoxConstraints(maxWidth: 290),
      decoration: bubbles
          .fill(mine: mine)
          .copyWith(
            borderRadius: Corner.all(Corner.bubble),
            border: reply ? Border.all(color: Paper.accent, width: 1.5) : null,
          ),
      child: Text(
        text,
        textDirection: directionOf(text),
        style: Type.prose(
          size: 13.5,
          color: bubbles.text(mine: mine),
          height: 1.35,
        ),
      ),
    ),
  );
}
