import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/llm_provider.dart';
import '../core/models.dart';
import '../core/native.g.dart';
import '../core/providers.dart';
import '../services/moss.dart';
import 'common.dart';
import 'settings_widgets.dart';
import 'strings.dart';

/// API key field that sits inside a settings card.
class _KeyField extends StatelessWidget {
  final Key fieldKey;
  final TextEditingController controller;
  final bool enabled, saved;
  final ValueChanged<String>? onChanged;
  const _KeyField({
    required this.fieldKey,
    required this.controller,
    required this.enabled,
    required this.saved,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => TextField(
    key: fieldKey,
    controller: controller,
    enabled: enabled,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    onChanged: onChanged,
    decoration: InputDecoration(
      hintText: tr(context, saved ? 'key_saved' : 'api_key'),
      filled: false,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
  );
}

/// Full-width primary action under a card, with a spinner while it runs.
class _TestButton extends StatelessWidget {
  final Key buttonKey;
  final VoidCallback? onPressed;
  final bool running;
  final String? footer;
  const _TestButton({
    required this.buttonKey,
    required this.onPressed,
    required this.running,
    this.footer,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          key: buttonKey,
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: running
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr(context, 'test')),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              footer!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ),
  );
}

class SttSettingsPage extends ConsumerStatefulWidget {
  const SttSettingsPage({super.key});
  @override
  ConsumerState<SttSettingsPage> createState() => _SttSettingsPageState();
}

class _SttSettingsPageState extends ConsumerState<SttSettingsPage> {
  final apiKey = TextEditingController();
  bool busy = false;
  bool? keySaved;

  @override
  void initState() {
    super.initState();
    loadKey();
  }

  @override
  void dispose() {
    apiKey.dispose();
    super.dispose();
  }

  Future<void> loadKey() async {
    final provider = ref.read(settingsProvider).sttProvider;
    bool saved;
    try {
      final value = await ref
          .read(nativeProvider)
          .api
          .readSecret(provider.secret);
      saved = value != null && value.isNotEmpty;
    } catch (_) {
      saved = false;
    }
    if (mounted && ref.read(settingsProvider).sttProvider == provider) {
      setState(() => keySaved = saved);
    }
  }

  Future<void> run(Future<void> Function() body) async {
    setState(() => busy = true);
    await action(context, body);
    if (mounted) setState(() => busy = false);
    await loadKey();
  }

  Future<void> choose(SttProvider provider) async {
    final current = ref.read(settingsProvider);
    if (provider == current.sttProvider) return;
    setState(() {
      apiKey.clear();
      keySaved = null;
    });
    await run(
      () => ref
          .read(settingsProvider.notifier)
          .save(
            AppSettings.fromJson({
              ...current.toJson(),
              'sttProvider': provider.name,
            }),
          ),
    );
  }

  Future<void> test() => run(() async {
    final settings = ref.read(settingsProvider);
    if (settings.localOnly) throw StateError('online_required');
    final provider = settings.sttProvider;
    final api = ref.read(nativeProvider).api;
    final candidate = apiKey.text.trim();
    final value = candidate.isNotEmpty
        ? candidate
        : await api.readSecret(provider.secret);
    if (value == null || value.isEmpty) {
      throw StateError('${provider.secret}_missing');
    }
    await validateSttKey(ref.read(sttClientProvider), provider, value);
    if (candidate.isNotEmpty) {
      await api.saveSecret(provider.secret, candidate);
      apiKey.clear();
    }
    if (mounted) notice(context, 'connected');
  });

  Future<void> removeKey() => run(() async {
    final provider = ref.read(settingsProvider).sttProvider;
    await ref.read(nativeProvider).api.saveSecret(provider.secret, '');
    apiKey.clear();
    if (mounted) notice(context, 'key_removed');
  });

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final provider = settings.sttProvider;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'stt'))),
      body: PageBody(
        children: [
          SettingsGroup(
            key: const ValueKey('stt-provider-select'),
            title: tr(context, 'llm_provider'),
            footer: provider == SttProvider.mossPro
                ? tr(context, 'moss_after_stop')
                : null,
            children: [
              for (final value in SttProvider.values)
                SettingsTile(
                  key: ValueKey('stt-provider-${value.name}'),
                  title: value.label,
                  selected: value == provider,
                  enabled: !busy,
                  onTap: () => choose(value),
                ),
            ],
          ),
          SettingsGroup(
            title: tr(context, 'api_key'),
            footer: keySaved == true ? tr(context, 'keep_key') : null,
            children: [
              _KeyField(
                fieldKey: ValueKey('provider-key-${provider.secret}'),
                controller: apiKey,
                enabled: !busy,
                saved: keySaved == true,
              ),
            ],
          ),
          _TestButton(
            buttonKey: ValueKey('test-${provider.secret}'),
            onPressed: busy || settings.localOnly ? null : test,
            running: busy,
            footer: settings.localOnly ? tr(context, 'local_only_on') : null,
          ),
          if (keySaved == true)
            SettingsGroup(
              children: [
                SettingsTile(
                  title: tr(context, 'remove_key'),
                  destructive: true,
                  enabled: !busy,
                  onTap: removeKey,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class TextModelSettingsPage extends ConsumerStatefulWidget {
  const TextModelSettingsPage({super.key});
  @override
  ConsumerState<TextModelSettingsPage> createState() =>
      _TextModelSettingsPageState();
}

class _TextModelSettingsPageState extends ConsumerState<TextModelSettingsPage> {
  final apiKey = TextEditingController();
  late LlmProvider? provider = ref.read(settingsProvider).provider;
  late String selectedModel = ref.read(settingsProvider).model;
  List<String> models = const [];
  bool connectionTested = false, busy = false;
  bool? keySaved;

  @override
  void initState() {
    super.initState();
    loadKey();
  }

  @override
  void dispose() {
    apiKey.dispose();
    super.dispose();
  }

  AppSettings get draft => AppSettings.fromJson({
    ...ref.read(settingsProvider).toJson(),
    'provider': provider?.name,
    'model': selectedModel,
  });

  Future<void> loadKey() async {
    final current = provider;
    bool saved = false;
    if (current != null) {
      try {
        final value = await ref
            .read(textProcessorProvider)
            .credentials
            .read(current);
        saved = value != null && value.isNotEmpty;
      } catch (_) {}
    }
    if (mounted && provider == current) setState(() => keySaved = saved);
  }

  void invalidateModels() {
    connectionTested = false;
    models = const [];
    selectedModel = '';
  }

  /// Saving a provider, model or key change requires a passing connection test.
  Future<void> save() async {
    final saved = ref.read(settingsProvider);
    final candidate = apiKey.text.trim();
    if (provider != saved.provider ||
        selectedModel != saved.model ||
        candidate.isNotEmpty) {
      if (!connectionTested) throw StateError('test_before_model');
      if (!models.contains(selectedModel)) throw StateError('model_missing');
    }
    if (candidate.isNotEmpty) {
      await ref
          .read(textProcessorProvider)
          .credentials
          .save(provider!, candidate);
    }
    await ref.read(settingsProvider.notifier).save(draft);
    apiKey.clear();
  }

  Future<void> run(Future<void> Function() body) async {
    setState(() => busy = true);
    await action(context, body);
    if (mounted) setState(() => busy = false);
    await loadKey();
  }

  void choose(LlmProvider value) {
    if (value == provider) return;
    setState(() {
      provider = value;
      keySaved = null;
      apiKey.clear();
      invalidateModels();
    });
    loadKey();
  }

  Future<void> test() async {
    setState(() {
      connectionTested = false;
      models = const [];
    });
    await run(() async {
      if (ref.read(settingsProvider).localOnly) {
        throw StateError('online_required');
      }
      final available = await ref
          .read(textProcessorProvider)
          .listModels(draft, candidateApiKey: apiKey.text);
      if (!mounted) return;
      setState(() {
        models = available;
        connectionTested = true;
        if (!models.contains(selectedModel)) selectedModel = '';
      });
      if (selectedModel.isNotEmpty) await save();
      if (mounted) notice(context, 'models_loaded');
    });
  }

  Future<void> pickModel(String? value) async {
    setState(() => selectedModel = value ?? '');
    await run(save);
  }

  Future<void> removeKey() => run(() async {
    await ref.read(textProcessorProvider).credentials.save(provider!, '');
    if (!mounted) return;
    setState(() {
      apiKey.clear();
      connectionTested = false;
      models = const [];
    });
    notice(context, 'key_removed');
  });

  Widget modelField(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (!connectionTested) {
      return Padding(
        key: const ValueKey('provider-model-locked'),
        padding: const EdgeInsets.all(16),
        child: Text(
          selectedModel.isEmpty
              ? tr(context, 'test_before_model')
              : selectedModel,
          style: TextStyle(color: muted),
        ),
      );
    }
    return DropdownButtonFormField<String>(
      key: const ValueKey('provider-model'),
      initialValue: models.contains(selectedModel) ? selectedModel : null,
      isExpanded: true,
      menuMaxHeight: 360,
      borderRadius: BorderRadius.circular(12),
      decoration: const InputDecoration(
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      hint: Text(tr(context, 'select_model')),
      items: [
        for (final model in models)
          DropdownMenuItem(
            value: model,
            child: Text(model, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: busy ? null : pickModel,
    );
  }

  @override
  Widget build(BuildContext context) {
    final localOnly = ref.watch(settingsProvider).localOnly;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'llm'))),
      body: PageBody(
        children: [
          SettingsGroup(
            key: const ValueKey('provider-select'),
            title: tr(context, 'llm_provider'),
            footer: tr(context, 'text_actions'),
            children: [
              for (final value in LlmProvider.values)
                SettingsTile(
                  key: ValueKey('llm-provider-${value.name}'),
                  title: value.label,
                  selected: value == provider,
                  enabled: !busy,
                  onTap: () => choose(value),
                ),
            ],
          ),
          SettingsGroup(
            title: tr(context, 'api_key'),
            footer: keySaved == true ? tr(context, 'keep_provider_key') : null,
            children: [
              _KeyField(
                fieldKey: const ValueKey('provider-key-llm'),
                controller: apiKey,
                enabled: !busy && provider != null,
                saved: keySaved == true,
                onChanged: (_) => setState(invalidateModels),
              ),
            ],
          ),
          _TestButton(
            buttonKey: const ValueKey('test-llm'),
            onPressed: busy || localOnly || provider == null ? null : test,
            running: busy,
            footer: localOnly ? tr(context, 'local_only_on') : null,
          ),
          SettingsGroup(
            title: tr(context, 'model'),
            footer: connectionTested || selectedModel.isEmpty
                ? null
                : tr(context, 'test_before_model'),
            children: [modelField(context)],
          ),
          if (keySaved == true)
            SettingsGroup(
              children: [
                SettingsTile(
                  title: tr(context, 'remove_key'),
                  destructive: true,
                  enabled: !busy,
                  onTap: removeKey,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class OfflineResourcesPage extends ConsumerStatefulWidget {
  const OfflineResourcesPage({super.key});
  @override
  ConsumerState<OfflineResourcesPage> createState() =>
      _OfflineResourcesPageState();
}

class _OfflineResourcesPageState extends ConsumerState<OfflineResourcesPage> {
  CapabilityMessage? capabilities;
  String? operation;

  Future<void> check({bool prepare = false}) async {
    setState(() => operation = prepare ? 'prepare' : 'check');
    await action(context, () async {
      final s = ref.read(settingsProvider);
      final api = ref.read(nativeProvider).api;
      if (prepare) {
        await api.prepareLanguages(s.source, s.target, s.transcriptionTerms);
      }
      final c = await api.capabilities(
        s.source,
        s.target,
        s.transcriptionTerms,
      );
      if (mounted) setState(() => capabilities = c);
    });
    if (mounted) setState(() => operation = null);
  }

  Widget resourceAction(String label, IconData icon, {required bool prepare}) =>
      SettingsTile(
        title: tr(context, label),
        // The running row stays at full strength next to its spinner.
        enabled: operation == null || operation == label,
        trailing: operation == label
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, color: Theme.of(context).colorScheme.primary),
        onTap: operation == null ? () => check(prepare: prepare) : null,
      );

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final c = capabilities;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'resources'))),
      body: PageBody(
        children: [
          if (c != null)
            SettingsGroup(
              footer:
                  s.transcriptionTerms.isNotEmpty &&
                      c.vocabularySupported == false
                  ? tr(context, 'vocabulary_unavailable')
                  : null,
              children: [
                SettingsTile(
                  title: tr(context, 'transcript'),
                  subtitle: tr(context, c.speechStatus ?? 'unsupported'),
                ),
                SettingsTile(
                  title: tr(context, 'translation'),
                  subtitle: tr(
                    context,
                    c.translationStatus == 'installed'
                        ? 'ready'
                        : c.translationStatus,
                  ),
                ),
              ],
            ),
          SettingsGroup(
            children: [
              resourceAction('check', Icons.refresh, prepare: false),
              resourceAction('prepare', Icons.download_outlined, prepare: true),
            ],
          ),
        ],
      ),
    );
  }
}
