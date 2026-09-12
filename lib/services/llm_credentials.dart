import 'dart:convert';

import '../core/llm_provider.dart';
import 'platform.dart';

// Keep provider keys inside the existing Keychain item, never in settings JSON.
class LlmCredentials {
  const LlmCredentials(this.native);
  final NativeBridge native;

  Map<String, String> _decode(String? value) {
    if (value == null || value.isEmpty) return {};
    try {
      final data = jsonDecode(value);
      if (data is Map && data.values.every((key) => key is String)) {
        return Map<String, String>.from(data);
      }
    } on FormatException {
      // Legacy keys are bound once to the saved, recognized endpoint on load.
    }
    return {};
  }

  Future<String?> read(LlmProvider provider) async =>
      _decode(await native.api.readSecret('llm'))[provider.name];

  Future<void> save(LlmProvider provider, String key) async {
    final keys = _decode(await native.api.readSecret('llm'));
    if (key.trim().isEmpty) {
      keys.remove(provider.name);
    } else {
      keys[provider.name] = key.trim();
    }
    await native.api.saveSecret('llm', keys.isEmpty ? '' : jsonEncode(keys));
  }

  Future<void> migrateLegacy(LlmProvider provider) async {
    final value = await native.api.readSecret('llm');
    if (value == null || value.isEmpty || _decode(value).isNotEmpty) return;
    // JSON-shaped data must never be mistaken for a raw API key.
    if (value.trimLeft().startsWith('{')) return;
    await native.api.saveSecret('llm', jsonEncode({provider.name: value}));
  }
}
