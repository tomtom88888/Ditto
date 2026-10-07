import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../theme/tokens.dart';
import '../../widgets/paper_dialog.dart';
import '../../widgets/paper_ui.dart';
import '../../widgets/bidi.dart';

class TapRow extends StatelessWidget {
  const TapRow({
    required this.label,
    required this.value,
    required this.onTap,
    this.actionLabel,
    this.mono = false,
    this.busy = false,
    this.last = false,
    super.key,
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final String? actionLabel;
  final bool mono;
  final bool busy;
  final bool last;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 12),
    decoration: BoxDecoration(
      border: last ? null : Border(bottom: BorderSide(color: Paper.divider)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Type.prose(size: 12, color: Paper.tertiary, height: 1.3),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: mono
                    ? Type.numeric(size: 13, weight: FontWeight.w400)
                    : Type.strong(size: 14, height: 1.35),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (busy)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (actionLabel != null)
          GestureDetector(
            onTap: onTap,
            child: Text(
              actionLabel!,
              style: Type.strong(size: 13, color: Paper.accent),
            ),
          ),
      ],
    ),
  );
}

/// A model id as free text with a menu of suggestions: any id can be typed,
/// because this list ages faster than the app ships.
class ModelField extends StatefulWidget {
  const ModelField({
    required this.label,
    required this.value,
    required this.suggestions,
    required this.onChanged,
    this.helper,
    super.key,
  });

  final String label;
  final String value;
  final List<String> suggestions;
  final String? helper;
  final ValueChanged<String> onChanged;

  @override
  State<ModelField> createState() => _ModelFieldState();
}

class _ModelFieldState extends State<ModelField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(ModelField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      _controller.text = widget.value;
      return;
    }
    if (value != widget.value) widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(widget.label, style: Type.strong(size: 13, height: 1.35)),
      const SizedBox(height: 7),
      TextField(
        controller: _controller,
        autocorrect: false,
        style: Type.numeric(size: 14, weight: FontWeight.w400),
        decoration: paperFieldDecoration('model id').copyWith(
          suffixIcon: PopupMenuButton<String>(
            icon: Icon(Icons.expand_more, size: 20, color: Paper.tertiary),
            tooltip: 'Suggestions',
            color: Paper.bg,
            itemBuilder: (context) => [
              for (final suggestion in widget.suggestions.take(60))
                PopupMenuItem(
                  value: suggestion,
                  child: Text(
                    suggestion,
                    style: Type.numeric(size: 13, weight: FontWeight.w400),
                  ),
                ),
            ],
            onSelected: (value) {
              _controller.text = value;
              widget.onChanged(value);
            },
          ),
        ),
        onEditingComplete: _commit,
        onTapOutside: (_) => _commit(),
      ),
      if (widget.helper != null) ...[
        const SizedBox(height: 6),
        Text(
          widget.helper!,
          style: Type.prose(size: 12.5, color: Paper.muted, height: 1.4),
        ),
      ],
    ],
  );
}

class NumberStepper extends StatelessWidget {
  const NumberStepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.helper,
    super.key,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final int step;
  final String? helper;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => PaperCard(
    padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Type.strong(size: 14, height: 1.35)),
              if (helper != null) ...[
                const SizedBox(height: 3),
                Text(
                  helper!,
                  style: Type.prose(
                    size: 12.5,
                    color: Paper.tertiary,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
        _Nudge(
          icon: Icons.remove,
          onTap: value - step < min ? null : () => onChanged(value - step),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: Type.numeric(size: 15),
          ),
        ),
        _Nudge(
          icon: Icons.add,
          onTap: value + step > max ? null : () => onChanged(value + step),
        ),
      ],
    ),
  );
}

class _Nudge extends StatelessWidget {
  const _Nudge({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: onTap == null ? Paper.bg : Paper.panel,
        borderRadius: Corner.all(Corner.pill),
      ),
      child: Icon(
        icon,
        size: 17,
        color: onTap == null ? Paper.placeholder : Paper.ink,
      ),
    ),
  );
}

class ModeChoice extends StatelessWidget {
  const ModeChoice({
    required this.settings,
    required this.onPick,
    required this.onOpenFineTune,
    super.key,
  });

  final AppSettings settings;
  final ValueChanged<TrainingMode> onPick;
  final VoidCallback onOpenFineTune;

  @override
  Widget build(BuildContext context) {
    final explanation = switch (settings.mode) {
      TrainingMode.styleMemory => 'Uses your most similar past replies.',
      TrainingMode.fineTune =>
        settings.hasFineTunedModel
            ? 'Generating with ${settings.fineTunedModel}, still using your '
                  'retrieved examples as context.'
            : 'No fine-tuned model exists yet, so style memory is used until '
                  'one does.',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final mode in TrainingMode.values) ...[
              if (mode != TrainingMode.values.first) const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () => onPick(mode),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    decoration: BoxDecoration(
                      color: settings.mode == mode ? Paper.accent : Paper.card,
                      borderRadius: Corner.all(Corner.small),
                      border: settings.mode == mode
                          ? null
                          : Border.all(color: Paper.border, width: 1.5),
                    ),
                    child: Center(
                      child: Text(
                        mode == TrainingMode.styleMemory
                            ? 'Style memory'
                            : 'Fine-tuned',
                        style: Type.strong(
                          size: 14,
                          color: settings.mode == mode
                              ? Paper.onAccent
                              : Paper.ink,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          explanation,
          style: Type.prose(size: 12.5, color: Paper.tertiary, height: 1.45),
        ),
        const SizedBox(height: 10),
        PaperAction(
          title: 'Fine-tuning',
          subtitle: 'Costs money, and OpenAI is retiring it',
          tone: ActionTone.outline,
          onTap: onOpenFineTune,
        ),
      ],
    );
  }
}

/// The generating model's instructions, editable, with a way back.
///
/// This is the bluntest control over how replies read, so it is shown in full
/// rather than hidden behind a dialog, and the reset is only offered once the
/// text differs from the default \u2014 there is nothing to undo otherwise.
class SystemPromptField extends StatefulWidget {
  const SystemPromptField({
    required this.value,
    required this.edited,
    required this.onChanged,
    required this.onReset,
    super.key,
  });

  final String value;
  final bool edited;
  final ValueChanged<String> onChanged;
  final VoidCallback onReset;

  @override
  State<SystemPromptField> createState() => _SystemPromptFieldState();
}

class _SystemPromptFieldState extends State<SystemPromptField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  // Enter inserts a newline in a multi-line field, so onEditingComplete never
  // fires and tapping outside is not the only way a person leaves it: they
  // also scroll away, dismiss the keyboard, or go back. Committing when focus
  // is lost covers all of those.
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChanged);

  void _onFocusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  @override
  void didUpdateWidget(SystemPromptField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reset changes the value from outside; adopt it.
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final next = _controller.text;
    if (next.trim().isEmpty) {
      // An empty prompt would leave the model with no instructions at all.
      widget.onReset();
      return;
    }
    if (next != widget.value) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              'What the model is told before your examples',
              style: Type.strong(size: 13, height: 1.35),
            ),
          ),
          if (widget.edited)
            GestureDetector(
              onTap: () {
                _controller.text = AppSettings.defaultSystemPrompt;
                widget.onReset();
              },
              child: Text(
                'Reset to default',
                style: Type.strong(size: 13, color: Paper.accent),
              ),
            ),
        ],
      ),
      const SizedBox(height: 7),
      AutoDirection(
        controller: _controller,
        builder: (context) => TextField(
          controller: _controller,
          focusNode: _focus,
          maxLines: null,
          minLines: 6,
          textCapitalization: TextCapitalization.sentences,
          style: Type.prose(size: 13, color: Paper.ink, height: 1.5),
          decoration: paperFieldDecoration(
            'The instructions the model follows',
          ),
          onTapOutside: (_) => _commit(),
          onEditingComplete: _commit,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        '{me} and {them} become the names in the chat.',
        style: Type.prose(size: 12.5, color: Paper.muted, height: 1.4),
      ),
    ],
  );
}
