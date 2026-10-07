import 'package:flutter/material.dart';

import '../models/stored_exchange.dart';
import '../services/retrieval.dart';
import '../theme/bubbles.dart';
import '../theme/tokens.dart';
import '../widgets/chat_apps.dart';
import '../widgets/paper_ui.dart';
import '../widgets/bidi.dart';

/// The past exchanges similarity search pulled out of the style memory for one
/// generation.
///
/// This is the app showing its working: the suggestions are only as good as
/// what retrieval found, and the only way to judge that is to read it. Each
/// entry is a real conversation off this phone — nothing is fetched to display
/// it.
///
/// It is laid out as a transcript on the page rather than as cards: bubbles
/// inside a panel inside a card stacked three surfaces deep and read as mush.
/// Here the page is the only surface and the bubbles sit straight on it, the
/// way a chat log looks.
class RetrievedExchangesScreen extends StatelessWidget {
  const RetrievedExchangesScreen({
    required this.examples,
    required this.myName,
    required this.theirName,
    this.chatNames = const {},
    super.key,
  });

  final List<ScoredExchange> examples;
  final String myName;
  final String theirName;

  /// Chat id to the name shown for it, so each example says where it came
  /// from.
  final Map<int, String> chatNames;

  @override
  Widget build(BuildContext context) {
    return PaperScreen(
      gap: 0,
      children: [
        ScreenBar(
          title: 'What it drew on',
          onBack: () => Navigator.of(context).pop(),
        ),
        const SizedBox(height: Frame.gap),
        SerifTitle(
          examples.isEmpty
              ? 'Nothing in your memory matched.'
              : '${examples.length} past '
                    '${examples.length == 1 ? "exchange" : "exchanges"} '
                    'like this one',
          size: 28,
        ),
        const SizedBox(height: 9),
        Text(
          examples.isEmpty
              ? 'Nothing matched closely enough (at least $_floor).'
              : 'Closest first. Your reply is the one in colour.',
          style: Type.prose(size: 14),
        ),
        if (examples.isNotEmpty) ...[
          const SizedBox(height: 4),
          for (var i = 0; i < examples.length; i++)
            _Exchange(
              rank: i + 1,
              scored: examples[i],
              myName: myName,
              first: i == 0,
              chat: chatNames[examples[i].exchange.chatId],
            ),
        ],
      ],
    );
  }

  static final String _floor = Retrieval.defaultMinSimilarity.toStringAsFixed(
    2,
  );
}

/// One retrieved conversation: a quiet header line, then the turns.
class _Exchange extends StatelessWidget {
  const _Exchange({
    required this.rank,
    required this.scored,
    required this.myName,
    required this.first,
    this.chat,
  });

  final int rank;
  final ScoredExchange scored;
  final String myName;
  final bool first;

  /// The chat it came from, when known.
  final String? chat;

  @override
  Widget build(BuildContext context) {
    final exchange = scored.exchange;
    final when = exchange.timestamp;
    final bubbles = Bubbles.of(ChatApps.of(context, exchange.chatId));

    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!first)
            Padding(
              padding: EdgeInsets.only(bottom: 18),
              child: Divider(height: 1, thickness: 1, color: Paper.divider),
            ),
          Row(
            children: [
              Text(
                rank.toString().padLeft(2, '0'),
                style: Type.numeric(size: 12, color: Paper.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${when == null ? 'date unknown' : _when(when)}'
                  '${chat == null ? '' : ' · $chat'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Type.numeric(
                    size: 12,
                    color: Paper.muted,
                    weight: FontWeight.w400,
                  ),
                ),
              ),
              Text(
                scored.similarity.toStringAsFixed(2),
                style: Type.numeric(size: 12, color: Paper.tertiary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final turn in exchange.context)
            _Bubble(
              text: turn.text,
              mine: turn.sender == myName,
              bubbles: bubbles,
            ),
          _Bubble(
            text: exchange.replyText,
            mine: true,
            isTheReply: true,
            bubbles: bubbles,
          ),
        ],
      ),
    );
  }

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

  static String _when(DateTime at) =>
      '${at.day} ${_months[at.month - 1]} ${at.year}';
}

/// A single message, sitting directly on the page.
///
/// Side says who spoke, as it does in WhatsApp and on the Generate screen, so
/// no name label is needed and a right-to-left name cannot mislead.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.mine,
    required this.bubbles,
    this.isTheReply = false,
  });

  final String text;
  final bool mine;
  final Bubbles bubbles;

  /// The message actually sent, which is the thing worth reading.
  final bool isTheReply;

  @override
  Widget build(BuildContext context) {
    // Laid out like the chat itself: your bubbles green on the right, theirs
    // on the left. The reply that was actually sent is outlined in the
    // accent, because it is the part worth reading.
    final fill = bubbles.fill(mine: mine || isTheReply);
    final foreground = bubbles.text(mine: mine || isTheReply);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.72,
              ),
              padding: const EdgeInsets.fromLTRB(13, 9, 13, 9),
              decoration: fill.copyWith(
                borderRadius: BorderRadius.only(
                  topLeft: mine ? Corner.bubble : Corner.tail,
                  topRight: mine ? Corner.tail : Corner.bubble,
                  bottomLeft: Corner.bubble,
                  bottomRight: Corner.bubble,
                ),
                border: isTheReply
                    ? Border.all(color: Paper.accent, width: 1.5)
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: Paper.shadowSoft,
                    blurRadius: 1,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Text(
                text,
                textDirection: directionOf(text),
                style: Type.prose(size: 14, color: foreground, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
