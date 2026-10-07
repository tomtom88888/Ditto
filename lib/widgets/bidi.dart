import 'package:flutter/widgets.dart';

/// Right-to-left scripts: Hebrew, Arabic, Syriac, Thaana, N'Ko and the
/// presentation forms of Hebrew and Arabic.
final RegExp _rtl = RegExp(
  r'[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]',
  unicode: true,
);

/// Any letter, of any script.
final RegExp _letter = RegExp(r'\p{L}', unicode: true);

/// The direction [text] reads in, from its first letter: a Hebrew message
/// is right-to-left even when it starts with an emoji or a number, and an
/// English one inside it doesn't change that. Text with no letters at all
/// follows [fallback].
TextDirection directionOf(
  String text, {
  TextDirection fallback = TextDirection.ltr,
}) {
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (_rtl.hasMatch(char)) return TextDirection.rtl;
    if (_letter.hasMatch(char)) return TextDirection.ltr;
  }
  return fallback;
}

/// Whether [text] reads right to left.
bool isRtl(String text) => directionOf(text) == TextDirection.rtl;

/// Lays [child] out in the direction [text] reads in, so a block of Hebrew
/// or Arabic aligns to the right with its punctuation where it belongs.
class ContentDirection extends StatelessWidget {
  const ContentDirection({required this.text, required this.child, super.key});

  final String text;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Directionality(textDirection: directionOf(text), child: child);
}

/// Rebuilds [builder]'s field in the direction of what is typed in
/// [controller], switching as soon as the first letter is in: right to left
/// for Hebrew or Arabic, left to right otherwise. An empty field keeps the
/// app's direction, so its hint reads normally.
class AutoDirection extends StatelessWidget {
  const AutoDirection({
    required this.controller,
    required this.builder,
    super.key,
  });

  final TextEditingController controller;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final ambient = Directionality.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => Directionality(
        textDirection: directionOf(value.text, fallback: ambient),
        child: Builder(builder: builder),
      ),
    );
  }
}
