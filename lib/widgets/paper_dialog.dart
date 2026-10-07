import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'bidi.dart';

/// A dialog in the design's language rather than Material's.
class PaperDialog extends StatelessWidget {
  const PaperDialog({
    required this.title,
    required this.child,
    required this.confirmLabel,
    required this.onConfirm,
    this.destructive = false,
    this.extraLabel,
    this.onExtra,
    super.key,
  });

  final String title;
  final Widget child;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final bool destructive;
  final String? extraLabel;
  final VoidCallback? onExtra;

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: Paper.bg,
    surfaceTintColor: Paper.bg,
    shape: RoundedRectangleBorder(borderRadius: Corner.all(Corner.card)),
    title: Text(title, style: Type.strong(size: 17)),
    content: child,
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(
          'Cancel',
          style: Type.strong(size: 14, color: Paper.secondary),
        ),
      ),
      if (extraLabel != null && onExtra != null)
        TextButton(
          onPressed: onExtra,
          child: Text(
            extraLabel!,
            style: Type.strong(size: 14, color: Paper.secondary),
          ),
        ),
      TextButton(
        onPressed: onConfirm,
        child: Text(
          confirmLabel,
          style: Type.strong(
            size: 14,
            color: destructive ? Paper.errorText : Paper.accent,
          ),
        ),
      ),
    ],
  );
}

/// The text-field look used across the app: white, softly bordered, accent
/// on focus. Hints are mono because most fields hold ids and numbers.
InputDecoration paperFieldDecoration(String hint, {bool monoHint = true}) =>
    InputDecoration(
      isDense: true,
      filled: true,
      fillColor: Paper.card,
      hintText: hint,
      hintStyle: monoHint
          ? Type.numeric(
              size: 14,
              color: Paper.placeholder,
              weight: FontWeight.w400,
            )
          : Type.prose(size: 14, color: Paper.placeholder),
      contentPadding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
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
    );

/// Asks for some text in a [PaperDialog] and pops with it, or with nothing if
/// cancelled.
///
/// The dialog owns its controller, so the field is never left holding a
/// disposed one while the dialog animates away.
class TextEntryDialog extends StatefulWidget {
  const TextEntryDialog({
    required this.title,
    required this.confirmLabel,
    this.initialText = '',
    this.hint = '',
    this.helper,
    this.minLines = 1,
    this.maxLines,
    super.key,
  });

  final String title;
  final String confirmLabel;
  final String initialText;
  final String hint;
  final String? helper;
  final int minLines;

  /// `null` grows with the text.
  final int? maxLines;

  @override
  State<TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<TextEntryDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PaperDialog(
    title: widget.title,
    confirmLabel: widget.confirmLabel,
    onConfirm: () => Navigator.of(context).pop(_controller.text),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AutoDirection(
            controller: _controller,
            builder: (context) => TextField(
              controller: _controller,
              autofocus: true,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              style: Type.prose(size: 14.5, color: Paper.ink, height: 1.4),
              decoration: paperFieldDecoration(widget.hint, monoHint: false),
            ),
          ),
          if (widget.helper != null) ...[
            const SizedBox(height: 8),
            Text(
              widget.helper!,
              style: Type.prose(size: 12.5, color: Paper.muted, height: 1.4),
            ),
          ],
        ],
      ),
    ),
  );
}
