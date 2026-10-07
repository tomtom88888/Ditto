import 'package:flutter/material.dart';

import '../models/stored_exchange.dart';
import '../theme/tokens.dart';

/// A row of pills to choose a chat by, scrolling sideways: one chat, or
/// with [allLabel] also "all of them" (`null`).
class ChatPicker extends StatelessWidget {
  const ChatPicker({
    required this.chats,
    required this.selected,
    required this.onPick,
    this.allLabel,
    super.key,
  });

  final List<ChatMemory> chats;
  final int? selected;
  final ValueChanged<int?> onPick;

  /// Offers a first pill for every chat at once, when set.
  final String? allLabel;

  @override
  Widget build(BuildContext context) {
    Widget pill(String label, int? id) {
      final on = selected == id;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          key: ValueKey('pick-${id ?? "all"}'),
          onTap: () => onPick(id),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: on ? Paper.accent : Paper.card,
              borderRadius: Corner.all(Corner.pill),
              border: on ? null : Border.all(color: Paper.border, width: 1.5),
            ),
            child: Text(
              label,
              style: Type.strong(
                size: 13.5,
                color: on ? Paper.onAccent : Paper.ink,
              ),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (allLabel != null) pill(allLabel!, null),
          for (final c in chats)
            pill(c.theirName.isEmpty ? 'Unnamed' : c.theirName, c.id),
        ],
      ),
    );
  }
}
