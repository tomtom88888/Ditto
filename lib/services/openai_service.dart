import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/ai_provider.dart';
import '../models/api_usage.dart';
import '../models/extracted_message.dart';
import '../models/finetune_job.dart';
import 'openai_exception.dart';
import 'pricing.dart';
import 'quoted_replies.dart';

/// A message in a chat request, in OpenAI's shape. Requests to Claude and
/// Gemini are written in the same shape and translated on the way out.
typedef ChatMessageJson = Map<String, Object?>;

/// Thin, direct client for the OpenAI, Claude and Gemini REST APIs.
///
/// Every call names a model, and the model's name decides which provider it
/// goes to (see [AiProvider.forModel]), so the rest of the app never has to
/// know which one it is talking to. Fine-tuning is OpenAI's alone.
///
/// Deliberately has no Flutter dependency and no storage of its own: the keys
/// are handed in per instance by whoever read them out of secure storage. A
/// key is never logged, never put in an exception, and never written to disk
/// here.
class OpenAiService {
  OpenAiService({
    String apiKey = '',
    String anthropicKey = '',
    String geminiKey = '',
    http.Client? client,
    this.baseUrl = 'https://api.openai.com/v1',
    this.anthropicBaseUrl = 'https://api.anthropic.com/v1',
    this.geminiBaseUrl = 'https://generativelanguage.googleapis.com/v1beta',
    this.requestTimeout = const Duration(seconds: 90),
    this.visionTimeout = const Duration(seconds: 120),
    this.thinkingTimeout = const Duration(minutes: 3),
    this.maxRetries = 3,
    this.onUsage,
    this.interruptions,
    this.whenActive,
    this.keepAlive,
  }) : _keys = ApiKeys({
         AiProvider.openai: apiKey.trim(),
         AiProvider.anthropic: anthropicKey.trim(),
         AiProvider.gemini: geminiKey.trim(),
       }),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// A client for every provider in [keys].
  factory OpenAiService.forKeys(
    ApiKeys keys, {
    http.Client? client,
    int maxRetries = 3,
    void Function(ApiUsage usage)? onUsage,
    int Function()? interruptions,
    Future<void> Function()? whenActive,
    Future<T> Function<T>(Future<T> Function() work)? keepAlive,
  }) => OpenAiService(
    apiKey: keys[AiProvider.openai] ?? '',
    anthropicKey: keys[AiProvider.anthropic] ?? '',
    geminiKey: keys[AiProvider.gemini] ?? '',
    client: client,
    maxRetries: maxRetries,
    onUsage: onUsage,
    interruptions: interruptions,
    whenActive: whenActive,
    keepAlive: keepAlive,
  );

  final ApiKeys _keys;
  final http.Client _client;
  final bool _ownsClient;
  final String baseUrl;
  final String anthropicBaseUrl;
  final String geminiBaseUrl;
  final Duration requestTimeout;
  final Duration visionTimeout;

  /// Claude and Gemini think before they answer, which can take a while.
  final Duration thinkingTimeout;
  final int maxRetries;

  /// Told about the tokens every successful call used, as OpenAI reported
  /// them, so spending can be tracked on the device.
  final void Function(ApiUsage usage)? onUsage;

  /// How many times the app has left the foreground so far, and a wait for
  /// it to come back. A request that fails because the phone froze the app
  /// (screen off, another app in front) waits for it to return and tries
  /// again, without using up a retry. Both null outside the app.
  final int Function()? interruptions;
  final Future<void> Function()? whenActive;

  /// Runs each request, so the app can ask the phone to keep it alive while
  /// one is in flight. Null outside the app.
  final Future<T> Function<T>(Future<T> Function() work)? keepAlive;

  /// Most times one request is resumed after the app was sent away.
  static const int maxResumes = 5;

  void _report(
    Map<String, Object?> json, {
    required UsageKind kind,
    required String model,
  }) {
    final callback = onUsage;
    if (callback == null) return;
    final usage = ApiUsage.fromResponse(json, kind: kind, model: model);
    if (usage != null) callback(usage);
  }

  /// Newer models take `max_completion_tokens`; older ones only understand
  /// `max_tokens`. Discovered once from a 400 and remembered, so the fallback
  /// costs at most one wasted request per process.
  bool _useMaxCompletionTokens = true;

  /// Reasoning-tier models reject a `temperature` other than 1. Same trick.
  bool _sendTemperature = true;

  void close() {
    if (_ownsClient) _client.close();
  }

  /// Whether any key was given.
  bool get hasKey => _keys.isNotEmpty;

  /// Whether there is a key for [provider].
  bool hasKeyFor(AiProvider provider) => _keys.has(provider);

  // ---------------------------------------------------------------- embeddings

  /// Embeds [inputs] in one request and returns vectors in the same order.
  ///
  /// [dimensions] is only sent for models that support shortening
  /// (`text-embedding-3-*`); other models reject the parameter.
  Future<List<List<double>>> embed(
    List<String> inputs, {
    required String model,
    int? dimensions,
  }) async {
    if (inputs.isEmpty) return const [];
    switch (AiProvider.forModel(model)) {
      case AiProvider.gemini:
        return _geminiEmbed(inputs, model: model, dimensions: dimensions);
      case AiProvider.anthropic:
        throw const OpenAiException(
          OpenAiErrorKind.notAvailable,
          "Claude can't fingerprint chats: it has no embeddings. In "
          'Settings, add an OpenAI or Gemini key and pick one of its '
          'fingerprint models.',
        );
      case AiProvider.openai:
        break;
    }
    final body = <String, Object?>{'model': model, 'input': inputs};
    if (dimensions != null && model.startsWith('text-embedding-3')) {
      body['dimensions'] = dimensions;
    }

    final json = await _postJson('/embeddings', body, timeout: requestTimeout);
    _report(json, kind: UsageKind.embedding, model: model);
    final data = json['data'];
    if (data is! List || data.length != inputs.length) {
      throw OpenAiException(
        OpenAiErrorKind.badResponse,
        'The embeddings response had ${data is List ? data.length : 0} vectors '
        'for ${inputs.length} inputs.',
      );
    }
    // The API documents that `data` may come back out of order, so index by
    // the `index` field rather than trusting position.
    final vectors = List<List<double>?>.filled(inputs.length, null);
    for (final entry in data) {
      if (entry is! Map) continue;
      final index = (entry['index'] as num?)?.toInt();
      final embedding = entry['embedding'];
      if (index == null || index < 0 || index >= inputs.length) continue;
      if (embedding is! List) continue;
      vectors[index] = embedding
          .whereType<num>()
          .map((n) => n.toDouble())
          .toList(growable: false);
    }
    if (vectors.any((v) => v == null || v.isEmpty)) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'The embeddings response was missing vectors.',
      );
    }
    return vectors.cast<List<double>>();
  }

  // --------------------------------------------------------------------- chat

  /// One chat completion, returning the assistant's text.
  Future<String> chat({
    required String model,
    required List<ChatMessageJson> messages,
    double? temperature,
    int? maxOutputTokens,
    bool jsonMode = false,
    Duration? timeout,
    UsageKind usageKind = UsageKind.generation,
  }) async {
    final text = await _chat(
      model: model,
      messages: messages,
      temperature: temperature,
      maxOutputTokens: maxOutputTokens,
      jsonMode: jsonMode,
      timeout: timeout ?? requestTimeout,
      usageKind: usageKind,
    );
    if (text.trim().isEmpty) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'The model returned an empty reply. Try again.',
      );
    }
    return text.trim();
  }

  /// Several independent completions of the same prompt — drafts to choose
  /// between — returning every non-empty one.
  ///
  /// Uses the API's `n` parameter, so the prompt is sent and billed once.
  /// A model that rejects `n` gets [count] separate requests instead.
  Future<List<String>> chatDrafts({
    required String model,
    required List<ChatMessageJson> messages,
    required int count,
    double? temperature,
    int? maxOutputTokens,
    Duration? timeout,
  }) async {
    Future<List<String>> ask(int n) => _chatChoices(
      model: model,
      messages: messages,
      temperature: temperature,
      maxOutputTokens: maxOutputTokens,
      jsonMode: false,
      timeout: timeout ?? requestTimeout,
      usageKind: UsageKind.generation,
      n: n,
    );

    List<String> drafts;
    if (count <= 1 || !_sendN) {
      drafts = [
        for (var i = 0; i < (count < 1 ? 1 : count); i++) ...await ask(1),
      ];
    } else {
      try {
        drafts = await ask(count);
      } on OpenAiException catch (error) {
        final complaint = error.message.toLowerCase();
        final aboutN =
            error.kind == OpenAiErrorKind.badRequest &&
            (complaint.contains("'n'") ||
                complaint.contains('"n"') ||
                complaint.contains(' n ') ||
                complaint.contains('number of choices'));
        if (!aboutN) rethrow;
        _sendN = false;
        drafts = [for (var i = 0; i < count; i++) ...await ask(1)];
      }
    }
    final kept = [
      for (final d in drafts)
        if (d.trim().isNotEmpty) d.trim(),
    ];
    if (kept.isEmpty) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'The model returned an empty reply. Try again.',
      );
    }
    return kept;
  }

  /// Some models only return one choice; learned once, like the others.
  bool _sendN = true;

  Future<String> _chat({
    required String model,
    required List<ChatMessageJson> messages,
    required double? temperature,
    required int? maxOutputTokens,
    required bool jsonMode,
    required Duration timeout,
    required UsageKind usageKind,
  }) async => (await _chatChoices(
    model: model,
    messages: messages,
    temperature: temperature,
    maxOutputTokens: maxOutputTokens,
    jsonMode: jsonMode,
    timeout: timeout,
    usageKind: usageKind,
    n: 1,
  )).first;

  Future<List<String>> _chatChoices({
    required String model,
    required List<ChatMessageJson> messages,
    required double? temperature,
    required int? maxOutputTokens,
    required bool jsonMode,
    required Duration timeout,
    required UsageKind usageKind,
    required int n,
  }) async {
    final provider = AiProvider.forModel(model);
    if (provider != AiProvider.openai) {
      // Neither takes OpenAI's `n` reliably, so several drafts are several
      // requests, sent together.
      Future<String> one() => provider == AiProvider.anthropic
          ? _claudeText(
              model: model,
              messages: messages,
              maxOutputTokens: maxOutputTokens,
              jsonMode: jsonMode,
              timeout: timeout,
              usageKind: usageKind,
            )
          : _geminiText(
              model: model,
              messages: messages,
              temperature: temperature,
              jsonMode: jsonMode,
              timeout: timeout,
              usageKind: usageKind,
            );
      return Future.wait([for (var i = 0; i < (n < 1 ? 1 : n); i++) one()]);
    }
    // Up to two extra attempts, each dropping a parameter this model rejected.
    for (var attempt = 0; attempt < 3; attempt++) {
      final body = <String, Object?>{'model': model, 'messages': messages};
      if (n > 1) body['n'] = n;
      if (maxOutputTokens != null) {
        body[_useMaxCompletionTokens ? 'max_completion_tokens' : 'max_tokens'] =
            maxOutputTokens;
      }
      if (temperature != null && _sendTemperature) {
        body['temperature'] = temperature;
      }
      if (jsonMode) {
        body['response_format'] = const {'type': 'json_object'};
      }

      try {
        final json = await _postJson(
          '/chat/completions',
          body,
          timeout: timeout,
        );
        _report(json, kind: usageKind, model: model);
        return _choiceContents(json);
      } on OpenAiException catch (error) {
        if (error.kind != OpenAiErrorKind.badRequest) rethrow;
        final complaint = error.message.toLowerCase();
        if (_useMaxCompletionTokens &&
            maxOutputTokens != null &&
            complaint.contains('max_completion_tokens')) {
          _useMaxCompletionTokens = false;
          continue;
        }
        if (_sendTemperature &&
            temperature != null &&
            complaint.contains('temperature')) {
          _sendTemperature = false;
          continue;
        }
        rethrow;
      }
    }
    throw OpenAiException(
      OpenAiErrorKind.badRequest,
      'The model "$model" rejected the request even after dropping optional '
      'parameters. Try a different model in Settings.',
    );
  }

  /// The text of every choice in a completion, in order.
  static List<String> _choiceContents(Map<String, Object?> json) {
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'The response contained no choices.',
      );
    }
    return [for (final choice in choices) _contentOf(choice)];
  }

  static String _contentOf(Object? choice) {
    final message = choice is Map ? choice['message'] : null;
    if (message is! Map) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'The response contained no message.',
      );
    }
    final content = message['content'];
    if (content is String) return content;
    // Some models return content as a list of typed parts.
    if (content is List) {
      return content
          .whereType<Map<String, Object?>>()
          .map((part) => part['text'])
          .whereType<String>()
          .join();
    }
    throw const OpenAiException(
      OpenAiErrorKind.badResponse,
      'The response message had no text content.',
    );
  }

  // ------------------------------------------------------------------- claude

  /// Sent only while Claude accepts them; a model that rejects one gets it
  /// dropped, like OpenAI's optional parameters.
  bool _claudeFallbacks = true;
  bool _claudeEffort = true;

  /// Room for Claude's thinking as well as its answer.
  static const int claudeMaxTokens = 16000;

  Future<String> _claudeText({
    required String model,
    required List<ChatMessageJson> messages,
    required int? maxOutputTokens,
    required bool jsonMode,
    required Duration timeout,
    required UsageKind usageKind,
  }) async {
    final (system, turns) = claudeMessages(messages);
    final instructions = [
      if (system.isNotEmpty) system,
      if (jsonMode) 'Answer with one JSON object and nothing else.',
    ].join('\n\n');
    // Replies want speed more than deep thought; reading a screenshot or a
    // chat's facts gets Claude's default.
    final effort = usageKind == UsageKind.generation && !jsonMode
        ? 'low'
        : null;

    for (var attempt = 0; attempt < 3; attempt++) {
      final body = <String, Object?>{
        'model': model,
        'max_tokens': math.max(maxOutputTokens ?? 0, claudeMaxTokens),
        if (instructions.isNotEmpty) 'system': instructions,
        'messages': turns,
        if (effort != null && _claudeEffort)
          'output_config': {'effort': effort},
        // If Claude declines, the request is run again on another Claude
        // model rather than failing.
        if (_claudeFallbacks) 'fallbacks': 'default',
      };
      try {
        final json = await _postJson(
          '/messages',
          body,
          provider: AiProvider.anthropic,
          timeout: timeout > thinkingTimeout ? timeout : thinkingTimeout,
        );
        _report(json, kind: usageKind, model: model);
        return claudeTextOf(json);
      } on OpenAiException catch (error) {
        if (error.kind != OpenAiErrorKind.badRequest) rethrow;
        final complaint = error.message.toLowerCase();
        if (_claudeFallbacks && complaint.contains('fallback')) {
          _claudeFallbacks = false;
          continue;
        }
        if (_claudeEffort &&
            effort != null &&
            (complaint.contains('effort') ||
                complaint.contains('output_config'))) {
          _claudeEffort = false;
          continue;
        }
        rethrow;
      }
    }
    throw OpenAiException(
      OpenAiErrorKind.badRequest,
      'The model "$model" rejected the request. Try a different model in '
      'Settings.',
    );
  }

  /// [messages] in Claude's shape: the system messages joined into one
  /// instruction, the rest as turns that alternate between the user and
  /// Claude, starting with the user.
  static (String, List<Map<String, Object?>>) claudeMessages(
    List<ChatMessageJson> messages,
  ) {
    final system = <String>[];
    final turns = <Map<String, Object?>>[];
    for (final message in messages) {
      final role = message['role'];
      final content = message['content'];
      if (role == 'system' || role == 'developer') {
        final text = _textOf(content);
        if (text.trim().isNotEmpty) system.add(text);
        continue;
      }
      final who = role == 'assistant' ? 'assistant' : 'user';
      final blocks = _claudeBlocks(content);
      if (blocks.isEmpty) continue;
      if (turns.isNotEmpty && turns.last['role'] == who) {
        (turns.last['content']! as List).addAll(blocks);
      } else {
        turns.add({'role': who, 'content': blocks});
      }
    }
    if (turns.isEmpty || turns.first['role'] != 'user') {
      turns.insert(0, {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '(The conversation starts here.)'},
        ],
      });
    }
    return (system.join('\n\n'), turns);
  }

  static List<Map<String, Object?>> _claudeBlocks(Object? content) {
    if (content is String) {
      return [
        if (content.trim().isNotEmpty) {'type': 'text', 'text': content},
      ];
    }
    if (content is! List) return const [];
    final blocks = <Map<String, Object?>>[];
    for (final part in content.whereType<Map<String, Object?>>()) {
      final text = part['text'];
      if (part['type'] == 'text' && text is String && text.trim().isNotEmpty) {
        blocks.add({'type': 'text', 'text': text});
      }
      final image = _imageOf(part);
      if (image != null) {
        blocks.add({
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': image.$1,
            'data': image.$2,
          },
        });
      }
    }
    return blocks;
  }

  /// The text of Claude's answer, leaving out its thinking.
  static String claudeTextOf(Map<String, Object?> json) {
    if (json['stop_reason'] == 'refusal') {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'Claude declined to answer this one. Try again, or pick a different '
        'model in Settings.',
      );
    }
    final content = json['content'];
    if (content is! List) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'The response contained no message.',
      );
    }
    return content
        .whereType<Map<String, Object?>>()
        .where((block) => block['type'] == 'text')
        .map((block) => block['text'])
        .whereType<String>()
        .join();
  }

  // ------------------------------------------------------------------- gemini

  Future<String> _geminiText({
    required String model,
    required List<ChatMessageJson> messages,
    required double? temperature,
    required bool jsonMode,
    required Duration timeout,
    required UsageKind usageKind,
  }) async {
    final (system, contents) = geminiContents(messages);
    // No output limit: Gemini counts its thinking against it, and a limit
    // that suits OpenAI can leave no room for the answer.
    final body = <String, Object?>{
      if (system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
      'contents': contents,
      'generationConfig': {
        'temperature': ?temperature,
        if (jsonMode) 'responseMimeType': 'application/json',
      },
    };
    final json = await _postJson(
      '/${_geminiName(model)}:generateContent',
      body,
      provider: AiProvider.gemini,
      timeout: timeout > thinkingTimeout ? timeout : thinkingTimeout,
    );
    _report(json, kind: usageKind, model: model);
    return geminiTextOf(json);
  }

  static String _geminiName(String model) =>
      model.startsWith('models/') ? model : 'models/$model';

  /// [messages] in Gemini's shape: the system messages joined into one
  /// instruction, the rest as turns between the user and the model.
  static (String, List<Map<String, Object?>>) geminiContents(
    List<ChatMessageJson> messages,
  ) {
    final system = <String>[];
    final contents = <Map<String, Object?>>[];
    for (final message in messages) {
      final role = message['role'];
      final content = message['content'];
      if (role == 'system' || role == 'developer') {
        final text = _textOf(content);
        if (text.trim().isNotEmpty) system.add(text);
        continue;
      }
      final who = role == 'assistant' ? 'model' : 'user';
      final parts = <Map<String, Object?>>[];
      if (content is String) {
        if (content.trim().isNotEmpty) parts.add({'text': content});
      } else if (content is List) {
        for (final part in content.whereType<Map<String, Object?>>()) {
          final text = part['text'];
          if (part['type'] == 'text' &&
              text is String &&
              text.trim().isNotEmpty) {
            parts.add({'text': text});
          }
          final image = _imageOf(part);
          if (image != null) {
            parts.add({
              'inlineData': {'mimeType': image.$1, 'data': image.$2},
            });
          }
        }
      }
      if (parts.isEmpty) continue;
      if (contents.isNotEmpty && contents.last['role'] == who) {
        (contents.last['parts']! as List).addAll(parts);
      } else {
        contents.add({'role': who, 'parts': parts});
      }
    }
    return (system.join('\n\n'), contents);
  }

  /// The text of Gemini's first answer, leaving out its thinking.
  static String geminiTextOf(Map<String, Object?> json) {
    final candidates = json['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      final feedback = json['promptFeedback'];
      final reason = feedback is Map ? feedback['blockReason'] : null;
      throw OpenAiException(
        OpenAiErrorKind.badResponse,
        reason == null
            ? 'Gemini returned no answer. Try again.'
            : 'Gemini declined to answer this one ($reason). Try again, or '
                  'pick a different model in Settings.',
      );
    }
    final first = candidates.first;
    final content = first is Map ? first['content'] : null;
    final parts = content is Map ? content['parts'] : null;
    final text = parts is List
        ? parts
              .whereType<Map<String, Object?>>()
              .where((p) => p['thought'] != true)
              .map((p) => p['text'])
              .whereType<String>()
              .join()
        : '';
    final finish = first is Map ? first['finishReason'] : null;
    if (text.trim().isEmpty && finish is String && finish != 'STOP') {
      throw OpenAiException(
        OpenAiErrorKind.badResponse,
        'Gemini stopped without answering ($finish). Try again, or pick a '
        'different model in Settings.',
      );
    }
    return text;
  }

  Future<List<List<double>>> _geminiEmbed(
    List<String> inputs, {
    required String model,
    required int? dimensions,
  }) async {
    final name = _geminiName(model);
    final json = await _postJson(
      '/$name:batchEmbedContents',
      {
        'requests': [
          for (final input in inputs)
            {
              'model': name,
              'content': {
                'parts': [
                  {'text': input},
                ],
              },
              'outputDimensionality': ?dimensions,
            },
        ],
      },
      provider: AiProvider.gemini,
      timeout: requestTimeout,
    );
    final data = json['embeddings'];
    if (data is! List || data.length != inputs.length) {
      throw OpenAiException(
        OpenAiErrorKind.badResponse,
        'The embeddings response had ${data is List ? data.length : 0} vectors '
        'for ${inputs.length} inputs.',
      );
    }
    final vectors = [
      for (final entry in data)
        entry is Map && entry['values'] is List
            ? (entry['values'] as List)
                  .whereType<num>()
                  .map((n) => n.toDouble())
                  .toList(growable: false)
            : const <double>[],
    ];
    if (vectors.any((v) => v.isEmpty)) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'The embeddings response was missing vectors.',
      );
    }
    // Gemini doesn't say how many tokens it read; estimate, for the tally.
    onUsage?.call(
      ApiUsage(
        kind: UsageKind.embedding,
        model: model,
        inputTokens: Pricing.estimateTokensForAll(inputs),
      ),
    );
    return vectors;
  }

  // ------------------------------------------------------------ message parts

  /// The text of a message's content, whichever shape it is in.
  static String _textOf(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    return content
        .whereType<Map<String, Object?>>()
        .map((part) => part['text'])
        .whereType<String>()
        .join('\n');
  }

  /// The media type and base64 data of an inline image part.
  static (String, String)? _imageOf(Map<String, Object?> part) {
    if (part['type'] != 'image_url') return null;
    final image = part['image_url'];
    final url = image is Map ? image['url'] : image;
    if (url is! String) return null;
    final match = RegExp(
      r'^data:([^;,]+);base64,(.*)$',
      dotAll: true,
    ).firstMatch(url);
    if (match == null) return null;
    return (match.group(1)!, match.group(2)!);
  }

  // ------------------------------------------------------------------- vision

  /// Reads a WhatsApp conversation off a screenshot.
  ///
  /// Asks for strict JSON and validates it, so a model that free-associates
  /// produces a clear error rather than garbage messages.
  Future<List<ExtractedMessage>> extractConversation({
    required Uint8List imageBytes,
    required String model,
    String imageMimeType = 'image/jpeg',
  }) async {
    if (imageBytes.isEmpty) {
      throw const OpenAiException(
        OpenAiErrorKind.badRequest,
        'That screenshot is empty.',
      );
    }
    final dataUri = 'data:$imageMimeType;base64,${base64Encode(imageBytes)}';

    final raw = await _chat(
      model: model,
      messages: [
        {'role': 'system', 'content': _visionSystemPrompt},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': _visionUserPrompt},
            {
              'type': 'image_url',
              'image_url': {'url': dataUri, 'detail': 'high'},
            },
          ],
        },
      ],
      temperature: 0,
      maxOutputTokens: 4000,
      jsonMode: true,
      timeout: visionTimeout,
      usageKind: UsageKind.vision,
    );

    return parseExtractedConversation(raw);
  }

  static const String _visionSystemPrompt =
      'You transcribe screenshots of a chat: WhatsApp, or Instagram direct '
      "messages. The user's own messages are the coloured bubbles: WhatsApp's "
      'green (light green, or dark teal in dark mode) with tick marks, and '
      "Instagram's purple, blue or gradient. The other person's are the white "
      'or grey bubbles, on Instagram often with their small profile picture '
      'beside them. Normally the user\'s bubbles sit on the RIGHT and the '
      'other person\'s on the LEFT, but when the app is in a right-to-left '
      'language (its interface in Hebrew, Arabic, Persian or Urdu: the header, '
      'dates and "typing" text read right to left) the whole screen is '
      'mirrored and the user\'s bubbles are on the LEFT. So decide the sender '
      'by bubble colour and tick marks first, and use the side only together '
      'with the interface\'s language, never by the wording. Transcribe the '
      'visible messages in top-to-bottom order, exactly as written, keeping '
      'emoji, capitalisation, spelling, language and the order of words in '
      'right-to-left text as they appear. Ignore date separators, timestamps, '
      'read receipts ("Seen"), reactions under a bubble, the contact header '
      'and the input box.\n\n'
      'Replies: a bubble that replies to an earlier message has a small quoted '
      'box at its top, with a coloured bar down one side, the quoted '
      "sender's name, and the quoted text (often cut short with \u2026). That "
      'box is NOT part of the message. Put only the text typed below it in '
      '"text", and the quoted text, without the name, in "quoted". Never put '
      'the quoted text in "text", and never output the quoted box as a '
      'message of its own. On Instagram a reply is shown as "Replied to you" '
      'or "You replied" above a faded copy of the message it answers: that '
      'faded copy is the quoted text.\n\n'
      'Group chats: each of the other people\'s bubbles shows the sender\'s '
      'name at its top, often in colour (a run of bubbles from one person '
      'may show it only on the first). Put that name in "name" for every '
      'one of their bubbles — repeat it down a run — and never in "text". '
      'Leave "name" out in a one-to-one chat and for the user\'s own '
      'bubbles.\n\n'
      'Reply with JSON only.';

  static const String _visionUserPrompt =
      'Transcribe this conversation. Respond with a JSON object of the form '
      '{"messages": [{"sender": "me" | "them", "text": "...", '
      '"quoted": "...", "name": "..."}]} where "me" is one of the user\'s own '
      'bubbles and "them" is one of the other side\'s. Include "quoted" only '
      'for a bubble that replies to another message, and "name" only for the '
      "other side's bubbles in a group chat. If a bubble is only an image, "
      'sticker or voice note, use its text as an empty string. Output nothing '
      'but the JSON object.';

  /// Validates and parses the vision model's JSON.
  ///
  /// Accepts either `{"messages": [...]}` or a bare array, and tolerates the
  /// model wrapping its answer in a Markdown code fence. Quoted messages the
  /// model left inside a reply are taken back out: see [QuotedReplies].
  static List<ExtractedMessage> parseExtractedConversation(String raw) {
    final cleaned = _stripCodeFence(raw);
    final Object? decoded;
    try {
      decoded = jsonDecode(cleaned);
    } on FormatException {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        "Couldn't read that screenshot — the model didn't return valid JSON. "
        'Try a clearer screenshot, or a different vision model in Settings.',
      );
    }

    final Object? list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map) {
      list = decoded['messages'] ?? decoded['conversation'] ?? decoded['data'];
    } else {
      list = null;
    }
    if (list is! List) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        "Couldn't read that screenshot — the model's JSON had no message list.",
      );
    }

    final messages = <ExtractedMessage>[];
    for (final entry in list) {
      try {
        final message = ExtractedMessage.fromJson(entry);
        if (message.text.isNotEmpty) messages.add(message);
      } on FormatException {
        // Skip the one bad entry rather than losing the whole transcription.
        continue;
      }
    }
    if (messages.isEmpty) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        "Couldn't find any messages in that screenshot. Make sure the "
        'conversation itself is visible and try again.',
      );
    }
    return QuotedReplies.clean(messages);
  }

  static String _stripCodeFence(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final firstNewline = trimmed.indexOf('\n');
    if (firstNewline == -1) return trimmed;
    var inner = trimmed.substring(firstNewline + 1);
    final closing = inner.lastIndexOf('```');
    if (closing != -1) inner = inner.substring(0, closing);
    return inner.trim();
  }

  // -------------------------------------------------------------------- models

  /// Model ids the saved keys can actually use, so Settings never has to
  /// guess at anyone's current naming. A provider that can't be reached is
  /// left out, unless none can.
  Future<List<String>> listModels() async {
    final ids = <String>[];
    Object? failure;
    for (final provider in _keys.providers) {
      try {
        ids.addAll(await listModelsFor(provider));
      } on OpenAiException catch (error) {
        failure = error;
      }
    }
    if (ids.isEmpty && failure != null) throw failure;
    return ids..sort();
  }

  /// The models one provider's key can use. Also how a key is checked
  /// before it is saved.
  Future<List<String>> listModelsFor(AiProvider provider) async {
    final json = switch (provider) {
      AiProvider.openai => await _getJson('/models'),
      AiProvider.anthropic => await _getJson(
        '/models?limit=1000',
        provider: provider,
      ),
      AiProvider.gemini => await _getJson(
        '/models?pageSize=1000',
        provider: provider,
      ),
    };
    final data = json['data'] ?? json['models'];
    if (data is! List) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'The model list came back in an unexpected shape.',
      );
    }
    final ids = <String>[];
    for (final m in data.whereType<Map<String, Object?>>()) {
      final id = m['id'] ?? m['name'];
      if (id is! String) continue;
      if (provider == AiProvider.gemini) {
        // Only the models that write or fingerprint.
        final methods = m['supportedGenerationMethods'];
        if (methods is List &&
            !methods.contains('generateContent') &&
            !methods.contains('batchEmbedContents')) {
          continue;
        }
        ids.add(id.startsWith('models/') ? id.substring(7) : id);
      } else {
        ids.add(id);
      }
    }
    return ids..sort();
  }

  // --------------------------------------------------------------------- files

  /// Uploads a training file and returns its file id.
  Future<String> uploadTrainingFile({
    required String filename,
    required List<int> bytes,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/files'))
      ..headers['Authorization'] = 'Bearer ${_keys[AiProvider.openai] ?? ''}'
      ..fields['purpose'] = 'fine-tune'
      ..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );

    final response = await _send(
      () async => http.Response.fromStream(await _client.send(request)),
      // Uploads are not safe to replay as a MultipartRequest can only be sent
      // once, so no retries here.
      retries: 0,
      timeout: const Duration(minutes: 5),
    );
    final json = _decodeBody(response);
    final id = json['id'];
    if (id is! String) {
      throw const OpenAiException(
        OpenAiErrorKind.badResponse,
        'The upload succeeded but returned no file id.',
      );
    }
    return id;
  }

  // ---------------------------------------------------------------- fine-tunes

  Future<FineTuneJob> createFineTuneJob({
    required String trainingFileId,
    required String baseModel,
    String? suffix,
    int? epochs,
  }) async {
    final body = <String, Object?>{
      'training_file': trainingFileId,
      'model': baseModel,
      if (suffix != null && suffix.isNotEmpty) 'suffix': suffix,
      if (epochs != null)
        'method': {
          'type': 'supervised',
          'supervised': {
            'hyperparameters': {'n_epochs': epochs},
          },
        },
    };
    final json = await _postJson('/fine_tuning/jobs', body);
    return FineTuneJob.fromJson(json);
  }

  Future<FineTuneJob> getFineTuneJob(String jobId) async {
    final json = await _getJson('/fine_tuning/jobs/$jobId');
    return FineTuneJob.fromJson(json);
  }

  Future<FineTuneJob> cancelFineTuneJob(String jobId) async {
    final json = await _postJson('/fine_tuning/jobs/$jobId/cancel', const {});
    return FineTuneJob.fromJson(json);
  }

  // ----------------------------------------------------------------- transport

  Uri _uri(String path, [AiProvider provider = AiProvider.openai]) =>
      Uri.parse(switch (provider) {
        AiProvider.openai => '$baseUrl$path',
        AiProvider.anthropic => '$anthropicBaseUrl$path',
        AiProvider.gemini => '$geminiBaseUrl$path',
      });

  Map<String, String> _jsonHeaders(AiProvider provider) {
    final key = _keys[provider] ?? '';
    return {
      ...switch (provider) {
        AiProvider.openai => {'Authorization': 'Bearer $key'},
        AiProvider.anthropic => {
          'x-api-key': key,
          'anthropic-version': '2023-06-01',
          if (_claudeFallbacks)
            'anthropic-beta': 'server-side-fallback-2026-07-01',
        },
        AiProvider.gemini => {'x-goog-api-key': key},
      },
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
  }

  Future<Map<String, Object?>> _postJson(
    String path,
    Map<String, Object?> body, {
    Duration? timeout,
    AiProvider provider = AiProvider.openai,
  }) async {
    final response = await _send(
      () => _client.post(
        _uri(path, provider),
        headers: _jsonHeaders(provider),
        body: jsonEncode(body),
      ),
      timeout: timeout ?? requestTimeout,
      provider: provider,
    );
    return _decodeBody(response, provider);
  }

  Future<Map<String, Object?>> _getJson(
    String path, {
    Duration? timeout,
    AiProvider provider = AiProvider.openai,
  }) async {
    final response = await _send(
      () => _client.get(_uri(path, provider), headers: _jsonHeaders(provider)),
      timeout: timeout ?? requestTimeout,
      provider: provider,
    );
    return _decodeBody(response, provider);
  }

  /// Sends a request, retrying transient failures with exponential backoff and
  /// honouring `Retry-After`, then converts any failure into an
  /// [OpenAiException] the UI can present.
  Future<http.Response> _send(
    Future<http.Response> Function() send, {
    required Duration timeout,
    int? retries,
    AiProvider provider = AiProvider.openai,
  }) {
    final guard = keepAlive;
    Future<http.Response> run() =>
        _sendNow(send, timeout: timeout, retries: retries, provider: provider);
    return guard == null ? run() : guard(run);
  }

  Future<http.Response> _sendNow(
    Future<http.Response> Function() send, {
    required Duration timeout,
    required int? retries,
    required AiProvider provider,
  }) async {
    if (!_keys.has(provider)) {
      throw OpenAiException(
        OpenAiErrorKind.missingKey,
        'No ${provider.label} API key saved. Add one in Settings, or pick a '
        'model from a provider you have a key for.',
      );
    }
    final name = provider.label;
    final attempts = (retries ?? maxRetries) + 1;
    OpenAiException? last;
    var resumes = 0;

    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) {
        final backoff =
            last?.retryAfter ??
            Duration(milliseconds: 500 * math.pow(2, attempt - 1).toInt());
        await Future<void>.delayed(backoff);
      }
      final before = interruptions?.call();

      /// A connection that died because the app was sent away: wait until it
      /// is back in front, then try again as if nothing happened.
      Future<bool> resumed() async {
        final wait = whenActive;
        if (wait == null || before == null || resumes >= maxResumes) {
          return false;
        }
        if (interruptions!() == before) return false;
        resumes++;
        await wait();
        return true;
      }

      try {
        final response = await send().timeout(timeout);
        if (response.statusCode < 400) return response;
        final failure = _failureFor(response, provider);
        if (!failure.isTransient || attempt == attempts - 1) throw failure;
        last = failure;
      } on OpenAiException {
        rethrow;
      } on TimeoutException {
        if (await resumed()) {
          attempt--; // Not the connection's fault: this try doesn't count.
          continue;
        }
        last = OpenAiException(
          OpenAiErrorKind.timeout,
          '$name took too long to answer. Check your connection and try '
          'again.',
        );
        if (attempt == attempts - 1) throw last;
      } on Exception catch (error) {
        // Sockets, TLS, HTTP: however the connection broke, a phone that
        // froze the app is the likelier cause if it was sent away meanwhile.
        if (await resumed()) {
          attempt--; // Not the connection's fault: this try doesn't count.
          continue;
        }
        if (error is! IOException && error is! http.ClientException) rethrow;
        last = OpenAiException(
          OpenAiErrorKind.network,
          "Couldn't reach $name. Check your internet connection.",
        );
        if (attempt == attempts - 1) throw last;
      }
    }
    throw last ??
        OpenAiException(
          OpenAiErrorKind.network,
          'The request to $name failed.',
        );
  }

  static Map<String, Object?> _decodeBody(
    http.Response response, [
    AiProvider provider = AiProvider.openai,
  ]) {
    if (response.statusCode >= 400) throw _failureFor(response, provider);
    if (response.body.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, Object?>) return decoded;
      return {'data': decoded};
    } on FormatException {
      throw OpenAiException(
        OpenAiErrorKind.badResponse,
        '${provider.label} returned a response that was not JSON.',
      );
    }
  }

  /// Turns an error response into a message worth showing a person. Only the
  /// response body is read — request headers, and therefore the key, never are.
  static OpenAiException _failureFor(
    http.Response response, [
    AiProvider provider = AiProvider.openai,
  ]) {
    final status = response.statusCode;
    final name = provider.label;
    String? apiMessage;
    String? apiType;
    try {
      // All three put an `error` object with a `message` in the body.
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          if (error['message'] is String) {
            apiMessage = error['message'] as String;
          }
          if (error['type'] is String) apiType = error['type'] as String;
          if (error['status'] is String) apiType ??= error['status'] as String;
        }
      }
    } on FormatException {
      // Non-JSON error body; fall back to the generic messages below.
    }
    final complaint = (apiMessage ?? '').toLowerCase();

    final retryAfterHeader = response.headers['retry-after'];
    final retryAfterSeconds = double.tryParse(retryAfterHeader ?? '');
    final retryAfter = retryAfterSeconds == null
        ? null
        : Duration(milliseconds: (retryAfterSeconds * 1000).round());

    // Gemini answers a bad key with a 400, and Claude an empty account with
    // one.
    final badKey =
        status == 401 ||
        (provider == AiProvider.gemini &&
            complaint.contains('api key not valid'));
    final noCredit =
        apiType == 'insufficient_quota' ||
        complaint.contains('credit balance is too low');

    if (badKey) {
      return OpenAiException(
        OpenAiErrorKind.badKey,
        '$name rejected that API key. Check it in Settings, or create a new '
        'one at ${provider.keysPage}.',
        statusCode: status,
      );
    }
    if (noCredit) {
      return OpenAiException(
        OpenAiErrorKind.insufficientQuota,
        apiMessage ??
            'Your $name account has no credit left. Add billing and try '
                'again.',
        statusCode: status,
      );
    }
    return switch (status) {
      403 || 404 => OpenAiException(
        OpenAiErrorKind.notAvailable,
        apiMessage ??
            'Your $name account cannot use that model or endpoint. Try a '
                'different model in Settings.',
        statusCode: status,
      ),
      429 => OpenAiException(
        OpenAiErrorKind.rateLimited,
        '$name is rate-limiting this key. Waiting a moment and retrying.',
        statusCode: 429,
        retryAfter: retryAfter,
      ),
      >= 500 => OpenAiException(
        OpenAiErrorKind.serverError,
        apiMessage ?? '$name had a server error ($status).',
        statusCode: status,
        retryAfter: retryAfter,
      ),
      _ => OpenAiException(
        OpenAiErrorKind.badRequest,
        apiMessage ?? '$name rejected the request ($status).',
        statusCode: status,
      ),
    };
  }
}
