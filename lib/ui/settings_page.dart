import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/transcription_terms.dart';
import '../services/moss.dart';
import '../core/llm_provider.dart';
import '../core/languages.dart';
import '../core/native.g.dart';
import '../core/providers.dart';
import 'common.dart';
import 'strings.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late String source, target, locale;
  late bool localOnly;
  late SttProvider sttProvider;
  late List<String> transcriptionTerms;
  bool busy = false;
  String? operation;
  CapabilityMessage? capabilities;
  LlmProvider? provider;
  String selectedModel = '';
  List<String> models = const [];
  bool connectionTested = false;
  final soniox = TextEditingController(), llm = TextEditingController();
  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    source = s.source;
    target = s.target;
    locale = s.locale;
    localOnly = s.localOnly;
    sttProvider = s.sttProvider;
    transcriptionTerms = s.transcriptionTerms;
    provider = s.provider;
    selectedModel = s.model;
  }

  @override
  void dispose() {
    soniox.dispose();
    llm.dispose();
    super.dispose();
  }

  AppSettings get settings => AppSettings(
    source: source,
    target: target,
    locale: locale,
    localOnly: localOnly,
    sttProvider: sttProvider,
    transcriptionTerms: transcriptionTerms,
    provider: provider,
    model: selectedModel,
  );
  Future<void> save({bool includeLlm = true}) async {
    final saved = ref.read(settingsProvider);
    final llmChanged =
        provider != saved.provider ||
        selectedModel != saved.model ||
        llm.text.trim().isNotEmpty;
    if (includeLlm && llmChanged) {
      if (!connectionTested) throw StateError('test_before_model');
      if (!models.contains(selectedModel)) throw StateError('model_missing');
    }
    if (includeLlm && llm.text.trim().isNotEmpty) {
      await ref
          .read(textProcessorProvider)
          .credentials
          .save(provider!, llm.text.trim());
    }
    await ref
        .read(settingsProvider.notifier)
        .save(
          includeLlm
              ? settings
              : AppSettings(
                  source: source,
                  target: target,
                  locale: locale,
                  localOnly: localOnly,
                  sttProvider: sttProvider,
                  transcriptionTerms: transcriptionTerms,
                  provider: saved.provider,
                  model: saved.model,
                ),
        );
    if (includeLlm) llm.clear();
  }

  Future<void> editVocabulary() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _VocabularyDialog(
        terms: transcriptionTerms,
        onSave: (terms) async {
          final current = ref.read(settingsProvider);
          await ref
              .read(settingsProvider.notifier)
              .save(
                AppSettings.fromJson({
                  ...current.toJson(),
                  'transcriptionTerms': terms,
                }),
              );
          if (mounted) {
            setState(() {
              transcriptionTerms = terms;
              capabilities = null;
            });
          }
        },
      ),
    );
  }

  Future<void> check({bool prepare = false}) async {
    setState(() {
      busy = true;
      operation = 'resources';
    });
    await action(context, () async {
      await save(includeLlm: false);
      final api = ref.read(nativeProvider).api;
      if (prepare) {
        await api.prepareLanguages(source, target, transcriptionTerms);
      }
      final c = await api.capabilities(source, target, transcriptionTerms);
      if (mounted) setState(() => capabilities = c);
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> test(bool cloud) async {
    setState(() {
      busy = true;
      operation = cloud ? sttProvider.secret : 'llm';
      if (!cloud) {
        connectionTested = false;
        models = const [];
      }
    });
    await action(context, () async {
      if (localOnly) throw StateError('online_required');
      if (cloud) {
        final candidate = soniox.text.trim();
        final key = candidate.isNotEmpty
            ? candidate
            : await ref.read(nativeProvider).api.readSecret(sttProvider.secret);
        if (key == null || key.isEmpty) {
          throw StateError('${sttProvider.secret}_missing');
        }
        await validateSttKey(ref.read(sttClientProvider), sttProvider, key);
        if (candidate.isNotEmpty) {
          await ref
              .read(nativeProvider)
              .api
              .saveSecret(sttProvider.secret, candidate);
          soniox.clear();
        }
      } else {
        final available = await ref
            .read(textProcessorProvider)
            .listModels(settings, candidateApiKey: llm.text);
        if (!mounted) return;
        setState(() {
          models = available;
          connectionTested = true;
          if (!models.contains(selectedModel)) selectedModel = '';
        });
        if (selectedModel.isNotEmpty) await save();
      }
      if (mounted) notice(context, cloud ? 'connected' : 'models_loaded');
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> commit({bool includeLlm = false}) async {
    setState(() {
      busy = true;
      operation = 'save';
    });
    await action(context, () async {
      await save(includeLlm: includeLlm);
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> clearData() async {
    await action(context, () async {
      if (!await confirm(context, 'clear_confirm') || !mounted) return;
      setState(() {
        busy = true;
        operation = 'data';
      });
      try {
        await ref.read(bootstrapProvider.future);
        final current = await ref.read(nativeProvider).api.snapshot();
        if (current != null &&
            ['recording', 'paused', 'processing'].contains(current.state)) {
          throw StateError('recording_active');
        }
        final jobs = await ref.read(databaseProvider).list('job');
        for (final j in jobs) {
          await ref
              .read(transcriptionProvider)
              .discardJob(j['recordingId'], settings);
        }
        final recordings = (await ref.read(databaseProvider).list('recording'))
            .map(Recording.fromJson);
        for (final r in recordings) {
          await ref.read(nativeProvider).api.deleteAudio(r.path);
          await ref.read(databaseProvider).deleteRecording(r.id);
        }
        await ref.read(databaseProvider).clear();
        await ref.read(nativeProvider).api.saveSecret('soniox', '');
        await ref.read(nativeProvider).api.saveSecret('moss', '');
        await ref.read(nativeProvider).api.saveSecret('llm', '');
        await ref.read(settingsProvider.notifier).save(const AppSettings());
        if (mounted) Navigator.pop(context);
      } finally {
        if (mounted) setState(() => busy = false);
      }
    });
  }

  InputDecoration settingDecoration(String label) => InputDecoration(
    labelText: tr(context, label),
    filled: false,
    border: UnderlineInputBorder(
      borderSide: BorderSide(
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    ),
    enabledBorder: UnderlineInputBorder(
      borderSide: BorderSide(
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    ),
    contentPadding: const EdgeInsets.symmetric(vertical: 12),
  );

  Widget language(String label, String value, void Function(String) update) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          initialValue: value,
          isExpanded: true,
          decoration: settingDecoration(label),
          items: languages.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: busy
              ? null
              : (value) {
                  if (value != null) {
                    setState(() {
                      update(value);
                      capabilities = null;
                    });
                    commit();
                  }
                },
        ),
      );

  Widget connectionForm(String service) {
    final controller = service != 'llm' ? soniox : llm;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Column(
        children: [
          if (service != 'llm') ...[
            DropdownButtonFormField<SttProvider>(
              key: const ValueKey('stt-provider-select'),
              initialValue: sttProvider,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr(context, 'model')),
              items: [
                for (final value in SttProvider.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value == null || value == sttProvider) return;
                      setState(() {
                        sttProvider = value;
                        soniox.clear();
                      });
                      commit();
                    },
            ),
            if (sttProvider == SttProvider.mossPro)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr(context, 'moss_after_stop')),
              ),
            const SizedBox(height: 16),
          ],
          if (service == 'llm') ...[
            DropdownButtonFormField<LlmProvider>(
              key: const ValueKey('provider-select'),
              initialValue: provider,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: tr(context, 'llm_provider'),
              ),
              hint: Text(tr(context, 'select_provider')),
              items: [
                for (final value in LlmProvider.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value == provider) return;
                      setState(() {
                        provider = value;
                        llm.clear();
                        invalidateModels();
                      });
                    },
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            key: ValueKey('provider-key-$service'),
            controller: controller,
            enabled: !busy && (service != 'llm' || provider != null),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: service == 'llm'
                ? (_) => setState(invalidateModels)
                : null,
            decoration: InputDecoration(
              labelText: tr(context, 'api_key'),
              helperText: tr(
                context,
                service == 'llm' ? 'keep_provider_key' : 'keep_key',
              ),
              helperMaxLines: 3,
            ),
          ),
          if (busy && operation == service)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(),
            ),
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: ValueKey('test-$service'),
                    onPressed:
                        busy ||
                            localOnly ||
                            (service == 'llm' && provider == null)
                        ? null
                        : () => test(service != 'llm'),
                    child: Text(tr(context, 'test')),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: tr(context, 'more'),
                enabled: !busy && (service != 'llm' || provider != null),
                onSelected: (_) => removeKey(service),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'remove',
                    child: Text(tr(context, 'remove_key')),
                  ),
                ],
              ),
            ],
          ),
          if (service == 'llm') ...[
            const SizedBox(height: 8),
            if (connectionTested)
              DropdownButtonFormField<String>(
                key: const ValueKey('provider-model'),
                initialValue: models.contains(selectedModel)
                    ? selectedModel
                    : null,
                isExpanded: true,
                menuMaxHeight: 360,
                decoration: InputDecoration(labelText: tr(context, 'model')),
                hint: Text(tr(context, 'select_model')),
                items: [
                  for (final model in models)
                    DropdownMenuItem(
                      value: model,
                      child: Text(
                        model,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) {
                        setState(() => selectedModel = value ?? '');
                        commit(includeLlm: true);
                      },
              )
            else
              InputDecorator(
                key: const ValueKey('provider-model-locked'),
                decoration: InputDecoration(
                  labelText: tr(context, 'model'),
                  helperText: selectedModel.isEmpty
                      ? null
                      : tr(context, 'test_before_model'),
                  helperMaxLines: 3,
                ),
                child: Text(
                  selectedModel.isEmpty
                      ? tr(context, 'test_before_model')
                      : selectedModel,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  void invalidateModels() {
    connectionTested = false;
    models = const [];
    selectedModel = '';
  }

  Future<void> removeKey(String service) async {
    setState(() => busy = true);
    await action(context, () async {
      if (service == 'llm') {
        await ref.read(textProcessorProvider).credentials.save(provider!, '');
        if (!mounted) return;
        setState(() {
          llm.clear();
          connectionTested = false;
          models = const [];
        });
      } else {
        await ref.read(nativeProvider).api.saveSecret(service, '');
        soniox.clear();
      }
      if (mounted) notice(context, 'key_removed');
    });
    if (mounted) setState(() => busy = false);
  }

  Widget capabilityRow(String label, String status) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(child: Text(tr(context, label))),
        Flexible(
          child: Text(
            tr(context, status),
            textAlign: TextAlign.end,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'settings'))),
    body: PageBody(
      children: [
        Text(
          tr(context, 'languages'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        language('source_language', source, (s) => source = s),
        language('target_language', target, (s) => target = s),
        DropdownButtonFormField<String>(
          initialValue: locale,
          isExpanded: true,
          decoration: settingDecoration('app_language'),
          items: [
            DropdownMenuItem(value: '', child: Text(tr(context, 'system'))),
            const DropdownMenuItem(value: 'en', child: Text('English')),
            const DropdownMenuItem(value: 'zh-Hans', child: Text('简体中文')),
            const DropdownMenuItem(value: 'zh-Hant', child: Text('繁體中文')),
          ],
          onChanged: busy
              ? null
              : (value) {
                  setState(() => locale = value ?? '');
                  commit();
                },
        ),
        SectionLabel(tr(context, 'mode')),
        RadioGroup<bool>(
          groupValue: localOnly,
          onChanged: (value) {
            if (!busy && value != null) {
              setState(() => localOnly = value);
              commit();
            }
          },
          child: Column(
            children: [
              RadioListTile<bool>(
                value: false,
                title: Text(tr(context, 'automatic')),
                contentPadding: EdgeInsets.zero,
                enabled: !busy,
              ),
              RadioListTile<bool>(
                value: true,
                title: Text(tr(context, 'local')),
                subtitle: Text(tr(context, 'local_services')),
                contentPadding: EdgeInsets.zero,
                enabled: !busy,
              ),
            ],
          ),
        ),
        SectionLabel(tr(context, 'connections')),
        ExpansionPanelList.radio(
          elevation: 0,
          expandedHeaderPadding: EdgeInsets.zero,
          materialGapSize: 0,
          children: [
            for (final service in ['stt', 'llm'])
              ExpansionPanelRadio(
                value: service,
                canTapOnHeader: true,
                backgroundColor: Theme.of(context).colorScheme.surface,
                headerBuilder: (context, expanded) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr(context, service)),
                  subtitle: Text(
                    service == 'stt'
                        ? sttProvider.label
                        : tr(context, 'text_actions'),
                  ),
                ),
                body: connectionForm(
                  service == 'stt' ? sttProvider.secret : service,
                ),
              ),
          ],
        ),
        ListTile(
          key: const ValueKey('custom-vocabulary'),
          contentPadding: EdgeInsets.zero,
          title: Text(tr(context, 'custom_vocabulary')),
          trailing: const Icon(Icons.chevron_right),
          onTap: busy ? null : editVocabulary,
        ),
        SectionLabel(tr(context, 'resources')),
        if (capabilities != null) ...[
          if (transcriptionTerms.isNotEmpty &&
              capabilities!.vocabularySupported == false)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(tr(context, 'vocabulary_unavailable')),
            ),
          capabilityRow(
            'transcript',
            capabilities!.speechStatus ?? 'unsupported',
          ),
          capabilityRow(
            'translation',
            capabilities!.translationStatus == 'installed'
                ? 'ready'
                : capabilities!.translationStatus,
          ),
          capabilityRow(
            'listen',
            capabilities!.voices.any(
                  (s) => s.startsWith(target.split('-').first),
                )
                ? 'ready'
                : 'download',
          ),
        ],
        if (busy && operation == 'resources')
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: busy ? null : () => check(),
              child: Text(tr(context, 'check')),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => check(prepare: true),
              child: Text(tr(context, 'prepare')),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 16),
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text(tr(context, 'action_button')),
          children: [
            Text(tr(context, 'action_help')),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => action(
                  context,
                  () => ref.read(nativeProvider).api.openSettings(),
                ),
                child: Text(tr(context, 'open_settings')),
              ),
            ),
          ],
        ),
        SectionLabel(tr(context, 'data')),
        if (busy && operation == 'data') const LinearProgressIndicator(),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: busy ? null : clearData,
            child: Text(
              tr(context, 'clear'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      ],
    ),
  );
}

class _VocabularyDialog extends StatefulWidget {
  final List<String> terms;
  final Future<void> Function(List<String>) onSave;
  const _VocabularyDialog({required this.terms, required this.onSave});
  @override
  State<_VocabularyDialog> createState() => _VocabularyDialogState();
}

class _VocabularyDialogState extends State<_VocabularyDialog> {
  late final input = TextEditingController(text: widget.terms.join('\n'));
  String? error;
  bool saving = false;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final terms = normalizeTranscriptionTerms(input.text.split('\n'));
      await widget.onSave(terms);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = errorKey(e);
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(tr(context, 'custom_vocabulary')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: TextField(
            key: const ValueKey('vocabulary-input'),
            controller: input,
            enabled: !saving,
            minLines: 5,
            maxLines: 10,
            decoration: InputDecoration(
              helperText: tr(context, 'vocabulary_help'),
              helperMaxLines: 4,
              errorText: error == null ? null : tr(context, error!),
              errorMaxLines: 4,
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(tr(context, 'cancel')),
        ),
        TextButton(
          key: const ValueKey('save-vocabulary'),
          onPressed: saving ? null : save,
          child: Text(tr(context, 'save')),
        ),
      ],
    ),
  );
}
