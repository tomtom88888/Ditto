import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/stored_exchange.dart';
import '../services/chat_search.dart';
import '../state/providers.dart';
import '../theme/bubbles.dart';
import '../theme/tokens.dart';
import '../widgets/chat_apps.dart';
import '../widgets/failure_text.dart';
import '../widgets/format.dart';
import '../widgets/paper_ui.dart';
import 'settings/settings_widgets.dart';

/// Search your chats by what was said: "that restaurant she mentioned"
/// finds the moment even when the word "restaurant" never came up.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _query = TextEditingController();

  /// `null` searches every chat.
  int? _chatId;
  bool _busy = false;
  Object? _error;
  List<SearchHit>? _hits;
  String _searched = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Every learned chat that can be searched with the current fingerprint
  /// settings, ticked or not.
  static List<ChatMemory> _searchable(
    List<ChatMemory> all,
    AppSettings settings,
  ) => [
    for (final c in all)
      if (!c.isEmpty &&
          c.matches(settings.embeddingModel, settings.embeddingDimensions))
        c,
  ];

  Future<void> _search(List<ChatMemory> chats) async {
    final search = ref.read(chatSearchProvider);
    final text = _query.text.trim();
    if (search == null || text.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final settings = await ref.read(settingsProvider.future);
      final hits = await search.search(
        text,
        chatIds: {
          for (final c in chats)
            if (_chatId == null || c.id == _chatId) c.id,
        },
        embeddingModel: settings.embeddingModel,
        dimensions: settings.embeddingDimensions,
        limit: settings.searchResultCount,
        // The closest moments are read by the chat model, which keeps
        // only the ones that really match.
        model: settings.generationModel,
      );
      if (mounted) {
        setState(() {
          _hits = hits;
          _searched = text;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatsProvider);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final hasKey = ref.watch(chatSearchProvider) != null;

    return PaperScreen(
      children: [
        ScreenBar(title: 'Search', onBack: () => Navigator.of(context).pop()),
        const SerifTitle('Find a ', accent: 'moment', trailing: '.'),
        ...chats.when(
          loading: () => [const LinearProgressIndicator(minHeight: 3)],
          error: (error, _) => [FailureNotice(error: error)],
          data: (all) {
            final searchable = _searchable(all, settings);
            if (searchable.isEmpty) {
              return const [
                Notice(
                  'Import a chat first.',
                  tone: NoticeTone.caution,
                  title: 'Nothing to search',
                ),
              ];
            }
            final names = {
              for (final c in all)
                c.id: c.theirName.isEmpty ? 'Unnamed chat' : c.theirName,
            };
            final hits = _hits;
            return [
              Text(
                'Describe it in your own words. It searches by meaning.',
                style: Type.prose(size: 14, color: Paper.body, height: 1.45),
              ),
              _SearchField(
                controller: _query,
                busy: _busy,
                enabled: hasKey,
                onSubmit: () => _search(searchable),
              ),
              NumberStepper(
                label: 'Moments to show',
                helper: 'The most a search brings back, closest first',
                value: settings.searchResultCount,
                min: 5,
                max: 100,
                step: 5,
                onChanged: (v) {
                  ref
                      .read(settingsProvider.notifier)
                      .edit((s) => s.copyWith(searchResultCount: v));
                  if (_hits != null && !_busy) _search(searchable);
                },
              ),
              if (!hasKey)
                const Notice(
                  'Add an OpenAI or Gemini key in Settings to search.',
                  tone: NoticeTone.caution,
                ),
              if (searchable.length > 1)
                _ChatFilter(
                  chats: searchable,
                  selected: _chatId,
                  onPick: (id) {
                    setState(() => _chatId = id);
                    if (_hits != null) _search(searchable);
                  },
                ),
              if (_error != null)
                FailureNotice(
                  error: _error!,
                  onRetry: () => _search(searchable),
                ),
              if (hits != null && hits.isEmpty)
                Notice(
                  'Nothing matched "$_searched". Try other words, or search '
                  'every chat.',
                ),
              if (hits != null && hits.isNotEmpty) ...[
                MonoLabel(
                  '${hits.length} ${hits.length == 1 ? "moment" : "moments"}, '
                  'best match first',
                ),
                for (final hit in hits)
                  _HitCard(
                    key: ValueKey(hit.exchange.id),
                    hit: hit,
                    chat: names[hit.exchange.chatId] ?? '',
                    myName:
                        {
                          for (final c in all) c.id: c.myName,
                        }[hit.exchange.chatId] ??
                        '',
                  ),
              ],
            ];
          },
        ),
        const Footnote(
          'The closest moments are read by your writing model, which keeps '
          'only the real matches.',
        ),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.busy,
    required this.enabled,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool busy;
  final bool enabled;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Paper.card,
      borderRadius: Corner.all(Corner.field),
      border: Border.all(color: Paper.border, width: 1.5),
    ),
    padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
    child: Row(
      // The field grows a line at a time as you write; the button stays at
      // the bottom, by the last line.
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('search-field'),
            controller: controller,
            enabled: enabled,
            minLines: 1,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            style: Type.prose(size: 15, color: Paper.ink, height: 1.4),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: 'that place she wanted to go…',
              hintStyle: Type.prose(size: 15, color: Paper.placeholder),
            ),
          ),
        ),
        SizedBox(
          width: 44,
          height: 44,
          child: busy
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  key: const ValueKey('search-go'),
                  tooltip: 'Search',
                  onPressed: enabled ? onSubmit : null,
                  icon: Icon(Icons.search_rounded, color: Paper.accent),
                ),
        ),
      ],
    ),
  );
}

/// All chats, or one.
class _ChatFilter extends StatelessWidget {
  const _ChatFilter({
    required this.chats,
    required this.selected,
    required this.onPick,
  });

  final List<ChatMemory> chats;
  final int? selected;
  final ValueChanged<int?> onPick;

  @override
  Widget build(BuildContext context) {
    Widget pill(String label, int? id) {
      final on = selected == id;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
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
          pill('All chats', null),
          for (final c in chats)
            pill(c.theirName.isEmpty ? 'Unnamed' : c.theirName, c.id),
        ],
      ),
    );
  }
}

/// One moment: when and where, the lead-up, and your reply.
class _HitCard extends StatefulWidget {
  const _HitCard({
    required this.hit,
    required this.chat,
    required this.myName,
    super.key,
  });

  final SearchHit hit;
  final String chat;
  final String myName;

  @override
  State<_HitCard> createState() => _HitCardState();
}

class _HitCardState extends State<_HitCard> {
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
          if (widget.hit.why != null) ...[
            const SizedBox(height: 3),
            Text(
              widget.hit.why!,
              style: Type.prose(size: 12.5, color: Paper.accent, height: 1.3),
            ),
          ],
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
            _Line(
              text: turn.text,
              who: turn.sender,
              mine: turn.sender == widget.myName,
              bubbles: bubbles,
            ),
          _Line(
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

class _Line extends StatelessWidget {
  const _Line({
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
        style: Type.prose(
          size: 13.5,
          color: bubbles.text(mine: mine),
          height: 1.35,
        ),
      ),
    ),
  );
}
