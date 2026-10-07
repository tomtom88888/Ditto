import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Tappable examples of what to type, in a row that scrolls sideways.
class ExampleChips extends StatelessWidget {
  const ExampleChips({required this.examples, required this.onPick, super.key});

  final List<String> examples;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final e in examples)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: GestureDetector(
              onTap: () => onPick(e),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Paper.panel,
                  borderRadius: Corner.all(Corner.pill),
                ),
                child: Text(
                  e,
                  style: Type.prose(size: 13, color: Paper.secondary),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
