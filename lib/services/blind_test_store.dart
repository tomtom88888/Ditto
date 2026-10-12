import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/blind_test.dart';

/// Each chat's blind test — its moments' seed, the prompt being tried, and
/// past runs — kept on the device.
class BlindTestStore {
  const BlindTestStore();

  static const String _prefsKey = 'ditto_blind_test_v1';

  Future<Map<int, BlindTestState>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return decode(prefs.getString(_prefsKey));
  }

  Future<BlindTestState?> forChat(int chatId) async => (await load())[chatId];

  Future<void> save(int chatId, BlindTestState state) async {
    final all = await load();
    all[chatId] = state;
    await _write(all);
  }

  Future<void> remove(int chatId) async {
    final all = await load();
    if (all.remove(chatId) != null) await _write(all);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  Future<void> _write(Map<int, BlindTestState> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({for (final e in all.entries) '${e.key}': e.value.toJson()}),
    );
  }

  static Map<int, BlindTestState> decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          ?int.tryParse('${e.key}'): ?BlindTestState.fromJson(e.value),
      };
    } on FormatException {
      return {};
    }
  }
}
