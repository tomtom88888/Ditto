import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../models/app_settings.dart';
import '../models/chat_app.dart';
import '../models/chat_turn.dart';
import '../models/extracted_message.dart';
import '../models/reply_suggestion.dart';
import '../models/stored_exchange.dart';
import '../models/style_profile.dart';
import '../models/suggestion_feedback.dart';
import '../services/chat_facts.dart';
import '../services/exchange_store.dart';
import '../services/pasted_conversation.dart';
import '../services/reply_generator.dart';
import '../services/screenshot_stitcher.dart';
import '../services/share_intake.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/failure_text.dart';
import '../widgets/format.dart';
import '../widgets/paper_dialog.dart';
import '../widgets/paper_ui.dart';
import 'generate/generate_parts.dart';
import 'generate/reply_card.dart';
import 'generate/transcript.dart';
import 'retrieved_exchanges_screen.dart';

/// Pick a screenshot (or paste the chat), check what was read, take one of
/// the suggested replies.
class GenerateScreen extends ConsumerStatefulWidget {
  const GenerateScreen({
    this.sharedScreenshot,
    this.pickImages,
    this.chat,
    super.key,
  });

  /// Who the reply is to, when opened from their chat on the home screen.
  final ChatMemory? chat;

  /// Set when a screenshot was shared into the app.
  final SharedScreenshot? sharedScreenshot;

  /// Picks up to `limit` screenshots from the gallery. Replaced in tests; the
  /// app uses the system picker.
  final Future<List<XFile>> Function(int limit)? pickImages;

  @override
  ConsumerState<GenerateScreen> createState() => _GenerateScreenState();
}

class _GenerateScreenState extends ConsumerState<GenerateScreen> {
  /// Read up front: feedback is recorded from dispose, when `ref` is gone.
  late final ExchangeStore _store;

  /// How many screenshots the conversation was read from; 0 when pasted or
  /// not yet picked.
  int _screenshots = 0;

  /// How many are being read right now.
  int _readingCount = 0;
  bool _pasted = false;
  List<ExtractedMessage> _messages = [];

  /// Who this reply is to. `null` means someone the app has no chat for: the
  /// voice then comes from every chat.
  ChatMemory? _replyingTo;
  bool _choseChat = false;

  List<ReplySuggestion> _variants = [];
  List<ScoredExchange> _examples = [];
  List<ChatMemory> _skipped = [];
  List<ChatTurn> _conversation = [];
  StyleProfile _profile = StyleProfile.empty;
  List<String> _voiceSample = const [];

  /// What is remembered about the person being replied to, for callbacks.
  List<String> _facts = const [];

  /// How you write to the person replied to, from their chat's analysis.
  List<String> _styleGuide = const [];
  List<String> _acting = const [];

  /// A one-off instruction for this reply: what to say, as opposed to how.
  /// Cleared with the screenshot, because it belongs to this moment.
  final _noteController = TextEditingController();
  String _note = '';

  bool _reading = false;
  bool _generating = false;
  bool _fixing = false;
  Object? _error;

  // Per-suggestion state for the set on screen.
  final Map<int, int> _bubblesCopied = {};
  final Set<int> _saved = {};
  int? _savingIndex;
  int? _refiningIndex;
  Refinement? _refining;

  // What happens to this set, for the feedback log.
  int? _pickedIndex;
  final List<String> _refinementsAsked = [];

  /// The ticked chats as of the last build, for [_recordFeedback], which can
  /// run from dispose when providers can no longer be read.
  List<ChatMemory> _lastEnabled = const [];

  bool get _hasSource => _screenshots > 0 || _pasted;

  /// Most screenshots one conversation is read from.
  static const int maxScreenshots = 5;

  @override
  void initState() {
    super.initState();
    _store = ref.read(exchangeStoreProvider);
    final shared = widget.sharedScreenshot;
    if (shared != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final bytes = await File(shared.path).readAsBytes();
          if (mounted) await _useScreenshot(bytes, shared.mimeType);
        } on Object catch (error) {
          if (mounted) setState(() => _error = error);
        }
      });
    }
  }

  @override
  void dispose() {
    _recordFeedback();
    _noteController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ chats

  /// Every learned chat, and who the reply is to unless you picked
  /// otherwise.
  List<ChatMemory> _enabledChats() {
    final chats = ref.read(chatsProvider).value ?? const <ChatMemory>[];
    return chats.where((c) => !c.isEmpty).toList();
  }

  ChatMemory? _defaultReplyingTo(List<ChatMemory> enabled) {
    final opened = widget.chat;
    if (opened != null) {
      for (final c in enabled) {
        if (c.id == opened.id) return c;
      }
    }
    return enabled.isEmpty ? null : enabled.first;
  }

  /// The chats a reply learns from: the chat with the person being replied
  /// to, or every chat when replying to someone new or when asked to.
  static List<ChatMemory> _sources(
    List<ChatMemory> chats,
    ChatMemory? chat,
    AppSettings settings,
  ) => chat == null || settings.useAllChats ? chats : [chat];

  Future<void> _pickChat() async {
    final enabled = _enabledChats();
    final settings = await ref.read(settingsProvider.future);
    if (!mounted) return;
    final picked = await pickReplyChat(
      context,
      chats: enabled,
      current: _currentReplyingTo(enabled),
      useAllChats: settings.useAllChats,
      onUseAllChats: (on) {
        ref
            .read(settingsProvider.notifier)
            .edit((s) => s.copyWith(useAllChats: on));
        setState(_retireVariants);
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      _choseChat = true;
      _replyingTo = picked.chat;
      _retireVariants();
    });
  }

  ChatMemory? _currentReplyingTo(List<ChatMemory> enabled) {
    if (!_choseChat) return _defaultReplyingTo(enabled);
    final chosen = _replyingTo;
    if (chosen == null) return null;
    for (final chat in enabled) {
      if (chat.id == chosen.id) return chat;
    }
    // Unticked since it was chosen: fall back to the default.
    return _defaultReplyingTo(enabled);
  }

  /// A group chat: a chat learned as one, or several different people named
  /// on the other side of what was read.
  bool _isGroup(ChatMemory? chat) =>
      (chat?.isGroup ?? false) ||
      {
            for (final m in _messages)
              if (m.speaker == Speaker.them && m.author != null) m.author,
          }.length >
          1;

  /// Settings with the names of the chat being replied in.
  AppSettings _named(AppSettings settings, ChatMemory? chat) {
    final me = chat?.myName ?? settings.myName;
    return settings.copyWith(
      myName: me.isEmpty ? 'Me' : me,
      theirName: chat == null
          ? 'Them'
          : (chat.theirName.isEmpty ? 'Them' : chat.theirName),
    );
  }

  // ---------------------------------------------------------------- sources

  void _resetForNewSource() {
    _recordFeedback();
    _noteController.clear();
    _messages = [];
    _variants = [];
    _examples = [];
    _skipped = [];
    _note = '';
    _fixing = false;
    _clearSetState();
  }

  /// Picks one or more screenshots. With [add], they join the conversation
  /// already read (keeping any fixes made to it) instead of replacing it.
  Future<void> _pickScreenshots({bool add = false}) async {
    setState(() => _error = null);
    try {
      final room = add ? maxScreenshots - _screenshots : maxScreenshots;
      if (room < 1) return;
      final picked = await (widget.pickImages ?? _systemPicker)(room);
      if (picked.isEmpty) return;
      final images = [
        for (final file in picked.take(room))
          (
            await file.readAsBytes(),
            file.mimeType ?? _guessMimeType(file.name),
          ),
      ];
      await _useScreenshots(images, add: add);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  static Future<List<XFile>> _systemPicker(int limit) async {
    final picker = ImagePicker();
    // Big enough for small text to stay legible, small enough to keep the
    // vision call cheap.
    if (limit == 1) {
      final one = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1400,
        imageQuality: 90,
      );
      return [?one];
    }
    return picker.pickMultiImage(
      maxWidth: 1400,
      imageQuality: 90,
      limit: limit,
    );
  }

  Future<void> _useScreenshot(Uint8List bytes, String mimeType) =>
      _useScreenshots([(bytes, mimeType)]);

  Future<void> _useScreenshots(
    List<(Uint8List, String)> images, {
    bool add = false,
  }) async {
    final keep = add ? List.of(_messages) : const <ExtractedMessage>[];
    final before = add ? _screenshots : 0;
    setState(() {
      if (add) {
        _retireVariants();
      } else {
        _resetForNewSource();
      }
      _screenshots = before + images.length;
      _pasted = false;
    });
    await _extract(images, keep: keep);
  }

  static String _guessMimeType(String name) =>
      name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';

  Future<void> _paste() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (context) => TextEntryDialog(
        title: 'Paste the conversation',
        confirmLabel: 'Use this',
        initialText: clipboard?.text ?? '',
        hint: 'Sam: are you coming tonight?\nme: maybe',
        minLines: 5,
        maxLines: 10,
        helper: 'Paste copied messages, or type "Name: message" lines.',
      ),
    );
    if (text == null || !mounted) return;

    final settings = await ref.read(settingsProvider.future);
    final me = _currentReplyingTo(_enabledChats())?.myName ?? settings.myName;
    final messages = PastedConversation.parse(text, myName: me);
    if (!mounted) return;
    setState(() {
      _resetForNewSource();
      _screenshots = 0;
      _pasted = true;
      _messages = messages;
      _error = messages.isEmpty
          ? Exception('There was nothing in that paste to reply to.')
          : null;
      if (messages.isEmpty) _pasted = false;
    });
  }

  /// Reads every screenshot at once, then joins them with [keep] (what was
  /// already read) into one conversation.
  Future<void> _extract(
    List<(Uint8List, String)> images, {
    List<ExtractedMessage> keep = const [],
  }) async {
    final openai = ref.read(openAiServiceProvider);
    if (openai == null) return;
    final settings = await ref.read(settingsProvider.future);

    setState(() {
      _reading = true;
      _readingCount = images.length;
      _error = null;
    });
    try {
      final parts = await Future.wait([
        for (final (bytes, mimeType) in images)
          openai.extractConversation(
            imageBytes: bytes,
            model: settings.visionModel,
            imageMimeType: mimeType,
          ),
      ]);
      final messages = ScreenshotStitcher.stitch([keep, ...parts]);
      if (mounted) setState(() => _messages = messages);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          // Nothing new was read: back to what there was.
          _messages = keep;
          _screenshots = keep.isEmpty ? 0 : _screenshots - images.length;
        });
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  // -------------------------------------------------------------- generating

  void _commitNote() {
    final next = _noteController.text.trim();
    if (next == _note) return;
    setState(() {
      _note = next;
      // The shown options no longer match the inputs.
      _retireVariants();
    });
  }

  Future<void> _generate() async {
    final generator = ref.read(replyGeneratorProvider);
    final memory = ref.read(styleMemoryServiceProvider);
    if (generator == null || memory == null) return;
    final settings = await ref.read(settingsProvider.future);
    final chats = _enabledChats();
    final chat = _currentReplyingTo(chats);
    final named = _named(settings, chat);
    final enabled = _sources(chats, chat, settings);

    setState(() {
      _generating = true;
      _error = null;
      _retireVariants();
    });
    try {
      final conversation = ReplyGenerator.turnsFrom(
        _messages,
        myName: named.myName,
        theirName: named.theirName,
      );
      final retrieved = await memory.retrieve(
        context: conversation,
        embeddingModel: named.embeddingModel,
        dimensions: named.embeddingDimensions,
        limit: named.retrievedExampleCount,
        chatIds: {for (final c in enabled) c.id},
        preferChatId: chat?.id,
        queryTurns: named.contextTurns,
      );
      // The chat being replied in speaks loudest; with no chat, all of them
      // together.
      final profile = chat != null && !chat.profile.isEmpty
          ? chat.profile
          : StyleProfile.mergeAll(enabled.map((c) => c.profile));
      final voiceSample = await memory.voiceSample(
        chatIds: {for (final c in enabled) c.id},
        preferChatId: chat?.id,
      );
      final facts = chat == null
          ? const <String>[]
          : [
              for (final f
                  in (await ref.read(factsStoreProvider).forChat(chat.id))
                          ?.facts ??
                      const <ChatFact>[])
                f.text,
            ];
      final analysis = chat == null
          ? null
          : await ref.read(analysisStoreProvider).forChat(chat.id);
      final styleGuide = analysis?.writing ?? const <String>[];
      final acting = analysis?.actingGuide ?? const <String>[];
      final variants = await generator.generate(
        conversation: conversation,
        examples: retrieved.examples,
        settings: named,
        note: _note,
        profile: profile,
        voiceSample: voiceSample,
        group: _isGroup(chat),
        facts: facts,
        styleGuide: styleGuide,
        acting: acting,
      );
      if (mounted) {
        setState(() {
          _facts = facts;
          _styleGuide = styleGuide;
          _acting = acting;
          _conversation = conversation;
          _examples = retrieved.examples;
          _skipped = retrieved.skipped;
          _profile = profile;
          _voiceSample = voiceSample;
          _variants = variants;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _refine(int index, Refinement refinement) async {
    final generator = ref.read(replyGeneratorProvider);
    if (generator == null) return;
    final settings = await ref.read(settingsProvider.future);
    final named = _named(settings, _currentReplyingTo(_enabledChats()));
    setState(() {
      _refiningIndex = index;
      _refining = refinement;
      _error = null;
    });
    try {
      final rewritten = await generator.refine(
        suggestion: _variants[index],
        refinement: refinement,
        conversation: _conversation,
        examples: _examples,
        settings: named,
        note: _note,
        profile: _profile,
        voiceSample: _voiceSample,
        group: _isGroup(_currentReplyingTo(_enabledChats())),
        facts: _facts,
        styleGuide: _styleGuide,
        acting: _acting,
      );
      if (!mounted) return;
      setState(() {
        _variants = [..._variants]..[index] = rewritten;
        _bubblesCopied.remove(index);
        _saved.remove(index);
        _refinementsAsked.add(refinement.name);
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() {
          _refiningIndex = null;
          _refining = null;
        });
      }
    }
  }

  // ------------------------------------------------------- copying & saving

  Future<void> _copy(int index) async {
    final bubbles = ReplyCard.bubblesOf(_variants[index].text);
    final done = _bubblesCopied[index] ?? 0;
    final split = bubbles.length > 1;
    // After the last bubble, a further tap starts again from the first.
    final next = split ? done % bubbles.length : 0;
    final text = split ? bubbles[next] : _variants[index].text;

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() {
      _bubblesCopied[index] = split ? next + 1 : 1;
      _pickedIndex = index;
    });
    if (split && next + 1 < bubbles.length) {
      showToast(
        context,
        'Bubble ${next + 1} of ${bubbles.length} copied.',
        detail: 'Paste and send it, then come back for the next one.',
      );
    } else {
      showToast(
        context,
        'Copied. Go paste it.',
        detail: "The app can't send it — you're leaving for WhatsApp now.",
      );
    }
  }

  Future<void> _save(int index) async {
    final memory = ref.read(styleMemoryServiceProvider);
    final chat = _currentReplyingTo(_enabledChats());
    if (memory == null || chat == null) return;
    final settings = await ref.read(settingsProvider.future);
    setState(() => _savingIndex = index);
    try {
      await memory.saveReply(
        chat: chat,
        conversation: _conversation,
        reply: _variants[index].text,
        contextTurns: settings.contextTurns,
      );
      await ref.read(chatsProvider.notifier).reload();
      if (!mounted) return;
      setState(() {
        _saved.add(index);
        _pickedIndex ??= index;
      });
      showToast(
        context,
        'Saved to ${chat.theirName.isEmpty ? "the chat" : chat.theirName}.',
        detail: 'It will be used as an example of you from now on.',
      );
    } on Object catch (error) {
      if (mounted) showFailureSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _savingIndex = null);
    }
  }

  // ----------------------------------------------------------------- feedback

  /// Logs what happened to the set on screen — which option was taken, or
  /// that none was — then forgets it. Called whenever the set is replaced.
  void _recordFeedback() {
    if (_variants.isEmpty) return;
    final picked = _pickedIndex;
    final feedback = SuggestionFeedback(
      at: DateTime.now(),
      chatId: _currentReplyingTo(_lastEnabled)?.id,
      shownKinds: [for (final v in _variants) v.kind],
      pickedIndex: picked,
      pickedText: picked == null ? null : _variants[picked].text,
      refinements: List.of(_refinementsAsked),
      saved: picked != null && _saved.contains(picked),
      hadNote: _note.isNotEmpty,
    );
    // Fire and forget: the log must never hold up the screen.
    unawaited(_store.recordFeedback(feedback).catchError((Object _) {}));
    _pickedIndex = null;
    _refinementsAsked.clear();
  }

  void _clearSetState() {
    _bubblesCopied.clear();
    _saved.clear();
    _savingIndex = null;
    _refiningIndex = null;
    _refining = null;
  }

  /// Takes the current suggestions off screen, logging what became of them.
  void _retireVariants() {
    _recordFeedback();
    _variants = [];
    _clearSetState();
  }

  // --------------------------------------------------------------- transcript

  void _flipAll() {
    setState(() {
      _messages = [
        for (final m in _messages)
          m.copyWith(
            speaker: m.speaker == Speaker.me ? Speaker.them : Speaker.me,
          ),
      ];
      _retireVariants();
      _error = null;
    });
  }

  void _toggleSide(int index) {
    setState(() {
      final message = _messages[index];
      _messages[index] = message.copyWith(
        speaker: message.speaker == Speaker.me ? Speaker.them : Speaker.me,
      );
      _retireVariants();
    });
  }

  Future<void> _editText(int index) async {
    final updated = await showDialog<String>(
      context: context,
      builder: (context) => TextEntryDialog(
        title: 'Fix the text',
        confirmLabel: 'Save',
        initialText: _messages[index].text,
      ),
    );
    if (updated == null || !mounted) return;
    setState(() {
      if (updated.trim().isEmpty) {
        _messages.removeAt(index);
      } else {
        _messages[index] = _messages[index].copyWith(text: updated.trim());
      }
      _retireVariants();
    });
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final enabled = [
      for (final c in ref.watch(chatsProvider).value ?? const <ChatMemory>[])
        if (!c.isEmpty) c,
    ];
    _lastEnabled = enabled;
    final chat = _currentReplyingTo(enabled);
    final named = _named(settings, chat);
    final ready = _messages.isNotEmpty && !_generating && !_reading;
    final lastIsMine =
        _messages.isNotEmpty && _messages.last.speaker == Speaker.me;

    return PaperScreen(
      padding: const EdgeInsets.fromLTRB(22, 62, 22, 34),
      gap: 16,
      bottom: _variants.isEmpty
          ? null
          : Row(
              children: [
                Expanded(
                  child: PaperAction(
                    title: 'Try again',
                    centred: true,
                    radius: Corner.choice,
                    onTap: _generating ? null : _generate,
                  ),
                ),
                const SizedBox(width: 10),
                PaperAction(
                  title: 'New chat',
                  centred: true,
                  tone: ActionTone.outline,
                  radius: Corner.choice,
                  onTap: () => setState(() {
                    _resetForNewSource();
                    _screenshots = 0;
                    _pasted = false;
                  }),
                ),
              ],
            ),
      children: [
        GenerateHeader(
          them: chat == null ? 'someone new' : named.theirName,
          onBack: () => Navigator.of(context).pop(),
          onChangeSource: _hasSource
              ? () => setState(() {
                  _resetForNewSource();
                  _screenshots = 0;
                  _pasted = false;
                })
              : null,
          onPickChat: enabled.isEmpty ? null : _pickChat,
        ),
        if (_error != null)
          Refusal(
            error: _error!,
            onFlipAll: lastIsMine ? _flipAll : null,
            onFix: _messages.isEmpty
                ? null
                : () => setState(() => _fixing = true),
          ),
        if (!_hasSource)
          EmptyState(onPick: _pickScreenshots, onPaste: _paste)
        else if (_reading)
          ReadingState(count: _readingCount)
        else if (_messages.isNotEmpty)
          Transcript(
            app: _replyingTo?.app ?? ChatApp.whatsapp,
            messages: _messages,
            settings: named,
            fixing: _fixing,
            onToggleFixing: () => setState(() => _fixing = !_fixing),
            onToggleSide: _toggleSide,
            onEdit: _editText,
          ),
        if (_screenshots > 0 &&
            _screenshots < maxScreenshots &&
            _messages.isNotEmpty &&
            !_reading &&
            !_generating)
          PaperAction(
            key: const ValueKey('add-screenshot'),
            title: 'Add another screenshot',
            subtitle: _screenshots == 1
                ? 'Scroll up in WhatsApp for more of the conversation'
                : 'Read from $_screenshots so far · up to $maxScreenshots',
            tone: ActionTone.outline,
            onTap: () => _pickScreenshots(add: true),
          ),
        if (_messages.isNotEmpty && !_generating)
          NoteField(controller: _noteController, onCommit: _commitNote),
        if (_messages.isNotEmpty && _variants.isEmpty && !_generating)
          PaperAction(
            title:
                'Write ${settings.variantCount} '
                '${settings.variantCount == 1 ? "reply" : "replies"}',
            centred: true,
            tone: ActionTone.accent,
            onTap: ready ? _generate : null,
          ),
        if (_generating) const GeneratingState(),
        if (_variants.isNotEmpty) ...[
          SerifTitle(
            _variants.length == 1
                ? 'How you’d answer that'
                : '${_countWord(_variants.length)} ways you’d answer that',
            size: 22,
          ),
          for (var i = 0; i < _variants.length; i++)
            ReplyCard(
              app: _replyingTo?.app ?? ChatApp.whatsapp,
              key: ValueKey('reply-$i'),
              suggestion: _variants[i],
              provenance: _provenance(i),
              bubblesCopied: _bubblesCopied[i] ?? 0,
              onCopy: () => _copy(i),
              onRefine: (r) => _refine(i, r),
              refining: _refiningIndex == i ? _refining : null,
              saved: _saved.contains(i),
              saving: _savingIndex == i,
              onSave: chat == null || _savingIndex != null
                  ? null
                  : () => _save(i),
            ),
          Provenance(
            examples: _examples,
            skipped: _skipped,
            model: settings.effectiveGenerationModel,
            mode:
                settings.mode == TrainingMode.fineTune &&
                    settings.hasFineTunedModel
                ? 'fine-tuned model'
                : 'style memory',
            onInspect: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RetrievedExchangesScreen(
                  examples: _examples,
                  myName: named.myName,
                  theirName: named.theirName,
                  chatNames: {
                    for (final c in enabled)
                      c.id: c.theirName.isEmpty ? 'unnamed chat' : c.theirName,
                  },
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _countWord(int n) => switch (n) {
    2 => 'Two',
    3 => 'Three',
    4 => 'Four',
    5 => 'Five',
    6 => 'Six',
    _ => '$n',
  };

  /// The design labels each reply with its shape and the date of the example it
  /// most resembles; without a match it says only how long it is.
  String _provenance(int index) {
    final bubbles = ReplyCard.bubblesOf(_variants[index].text).length;
    final unit = bubbles == 1 ? 'line' : 'lines';
    if (_examples.isEmpty) return '$bubbles $unit';
    final when = _examples[index % _examples.length].exchange.timestamp;
    if (when == null) return '$bubbles $unit · like you before';
    return '$bubbles $unit · like you on ${dayMonth(when)}';
  }
}
