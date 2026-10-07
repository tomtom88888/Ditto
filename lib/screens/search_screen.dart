import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/stored_exchange.dart';
import '../services/chat_search.dart';
import '../state/providers.dart';
import '../state/tasks.dart';
import '../theme/tokens.dart';
import '../widgets/failure_text.dart';
import '../widgets/format.dart';
import '../widgets/moment_card.dart';
import '../widgets/paper_ui.dart';
import 'settings/settings_widgets.dart';
import '../widgets/bidi.dart';

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

  /// The one-time job that gives chats imported before search fingerprints
  /// existed their own.
  static const String prepTaskId = 'search-prep';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  /// Starts making the missing search fingerprints, if any are missing. A
  /// one-time, cheap embedding job that runs in the background.
  Future<void> _prepare() async {
    final memory = ref.read(styleMemoryServiceProvider);
    if (memory == null) return;
    final settings = await ref.read(settingsProvider.future);
    final chats = await ref.read(chatsProvider.future);
    final ids = {for (final c in _searchable(chats, settings)) c.id};
    if (ids.isEmpty) return;
    final missing = await memory.missingFocus(
      chatIds: ids,
      embeddingModel: settings.embeddingModel,
      dimensions: settings.embeddingDimensions,
    );
    if (missing == 0 || !mounted) return;
    ref
        .read(taskCenterProvider.notifier)
        .start(
          id: prepTaskId,
          title: 'Sharpening search',
          detail: '${grouped(missing)} moments, one time',
          work: (task) async {
            await memory.addFocus(
              chatIds: ids,
              embeddingModel: settings.embeddingModel,
              dimensions: settings.embeddingDimensions,
              onProgress: (done, of) => task
                ..check()
                ..report(
                  detail: '${grouped(done)} of ${grouped(of)} moments',
                  progress: of == 0 ? null : done / of,
                ),
            );
            return null;
          },
        );
  }

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
    final preparing = ref
        .watch(taskCenterProvider)
        .any((t) => t.id == prepTaskId && t.running);

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
              if (preparing)
                const Notice(
                  'Sharpening search for the chats you imported earlier. '
                  'Results get better when it finishes.',
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
                  hits.first.weak
                      ? 'Nothing clearly matched · the closest'
                      : '${hits.length} '
                            '${hits.length == 1 ? "moment" : "moments"}, '
                            'best match first',
                ),
                for (final hit in hits)
                  MomentCard(
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
        const Footnote('Your chats are searched on this phone.'),
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
          child: AutoDirection(
            controller: controller,
            builder: (context) => TextField(
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
