import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/transcription_terms.dart';
import '../core/languages.dart';
import '../core/providers.dart';
import 'common.dart';
import 'settings_services.dart';
import 'settings_widgets.dart';
import 'strings.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool busy = false;
  String? operation;
  double? ttsFraction;
  StreamSubscription<double?>? ttsSub;
  String voiceStatus = 'checking';
  int voiceRevision = 0;
  bool? sttKeySaved, llmKeySaved;
  bool get android => defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    ref.listenManual(settingsProvider.select((s) => s.target), (
      previous,
      next,
    ) {
      if (previous == next) return;
      setState(() => voiceStatus = 'checking');
      unawaited(refreshVoice());
    });
    ref.listenManual(
      settingsProvider.select((s) => (s.sttProvider, s.provider)),
      (previous, next) {
        if (previous != next) unawaited(loadKeys());
      },
    );
    ttsSub = ref.read(nativeProvider).ttsDownloadProgress.listen((f) {
      if (!mounted) return;
      setState(() => ttsFraction = f);
      if (f == null) unawaited(refreshVoice());
    });
    unawaited(refreshVoice());
    unawaited(loadKeys());
  }

  @override
  void dispose() {
    ttsSub?.cancel();
    super.dispose();
  }

  Future<void> update(Map<String, Object?> changes) => action(
    context,
    () => ref
        .read(settingsProvider.notifier)
        .save(
          AppSettings.fromJson({
            ...ref.read(settingsProvider).toJson(),
            ...changes,
          }),
        ),
  );

  /// Row values only need to know whether a key exists, never its value.
  Future<void> loadKeys() async {
    final s = ref.read(settingsProvider);
    Future<bool> saved(Future<String?> Function() read) async {
      try {
        final value = await read();
        return value != null && value.isNotEmpty;
      } catch (_) {
        return false;
      }
    }

    final stt = await saved(
      () => ref.read(nativeProvider).api.readSecret(s.sttProvider.secret),
    );
    final llm =
        s.provider != null &&
        await saved(
          () => ref.read(textProcessorProvider).credentials.read(s.provider!),
        );
    if (mounted) {
      setState(() {
        sttKeySaved = stt;
        llmKeySaved = llm;
      });
    }
  }

  Future<void> openPage(Widget page) async {
    await pushSettingsPage<void>(context, page);
    if (mounted) await loadKeys();
  }

  Future<void> pickLanguage(String label, String field, String current) async {
    final choices = {
      ...languages,
      if (!languages.containsKey(current)) current: current,
    };
    final picked = await pushSettingsPage<String>(
      context,
      SettingsChoicePage<String>(
        title: tr(context, label),
        options: [for (final e in choices.entries) (e.key, e.value)],
        selected: current,
      ),
    );
    if (picked != null && picked != current && mounted) {
      await update({field: picked});
    }
  }

  List<(String, String)> appLanguages(BuildContext context) => [
    ('', tr(context, 'system')),
    ('en', 'English'),
    ('zh-Hans', '简体中文'),
    ('zh-Hant', '繁體中文'),
  ];

  Future<void> pickAppLanguage(String current) async {
    final picked = await pushSettingsPage<String>(
      context,
      SettingsChoicePage<String>(
        title: tr(context, 'app_language'),
        options: appLanguages(context),
        selected: current,
      ),
    );
    if (picked != null && picked != current && mounted) {
      await update({'locale': picked});
    }
  }

  Future<void> editVocabulary() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _VocabularyDialog(
        terms: ref.read(settingsProvider).transcriptionTerms,
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
        },
      ),
    );
  }

  Future<void> showShortcutHelp() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        tr(dialogContext, android ? 'android_shortcut' : 'action_button'),
      ),
      content: Text(
        tr(dialogContext, android ? 'android_shortcut_help' : 'action_help'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(tr(dialogContext, 'done')),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(dialogContext);
            action(context, () => ref.read(nativeProvider).api.openSettings());
          },
          child: Text(tr(dialogContext, 'open_settings')),
        ),
      ],
    ),
  );

  Future<void> refreshVoice() async {
    final revision = ++voiceRevision;
    final language = ref.read(settingsProvider).target;
    String status;
    try {
      status = await ref
          .read(nativeProvider)
          .api
          .ttsStatus(language)
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      status = 'unavailable';
    }
    if (mounted &&
        revision == voiceRevision &&
        language == ref.read(settingsProvider).target) {
      setState(() => voiceStatus = status);
    }
  }

  Future<void> downloadNeural() async {
    setState(() {
      busy = true;
      operation = 'voice';
      ttsFraction = 0;
    });
    await action(
      context,
      () => ref.read(nativeProvider).api.prepareTts([
        ref.read(settingsProvider).target,
      ]),
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      ttsFraction = null;
    });
    await refreshVoice();
  }

  Future<void> previewVoice() async {
    setState(() {
      busy = true;
      operation = 'preview';
    });
    await action(
      context,
      () => ref
          .read(nativeProvider)
          .api
          .previewTts(
            ref.read(settingsProvider).target,
            voiceStatus == 'ready',
          ),
    );
    if (!mounted) return;
    setState(() => busy = false);
    await refreshVoice();
  }

  /// A full-width action row inside the voice card, aligned with its title.
  Widget voiceAction({
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) => TextButton(
    key: key,
    onPressed: onPressed,
    style: TextButton.styleFrom(
      alignment: AlignmentDirectional.centerStart,
      minimumSize: const Size.fromHeight(52),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 12),
      shape: const RoundedRectangleBorder(),
    ),
    child: Row(
      children: [
        SizedBox(width: SettingsIcon.width, child: Icon(icon, size: 22)),
        const SizedBox(width: 12),
        Flexible(child: Text(label)),
      ],
    ),
  );

  Widget voiceGroup(AppSettings s) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final downloading = voiceStatus == 'downloading' || ttsFraction != null;
    final checking = voiceStatus == 'checking';
    final status = switch (voiceStatus) {
      'ready' => 'neural_ready',
      'repair' => 'voice_repair',
      'unavailable' => 'voice_unavailable',
      'downloading' => 'downloading',
      _ => 'system_voice',
    };
    return SettingsGroup(
      key: const ValueKey('listening-voice'),
      title: tr(context, 'listening_voice'),
      dividerIndent: SettingsTile.iconIndent,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const SettingsIcon(Icons.volume_up_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A quiet placeholder while the status loads, never a
                    // visible "checking" step.
                    checking
                        ? Container(
                            width: 120,
                            height: 12,
                            decoration: BoxDecoration(
                              color: colors.onSurface.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(6),
                            ),
                          )
                        : Text(
                            tr(context, status),
                            style: theme.textTheme.bodyLarge,
                          ),
                    if (downloading || (busy && operation == 'preview'))
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: LinearProgressIndicator(
                          value: downloading ? ttsFraction : null,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        voiceAction(
          key: const ValueKey('preview-voice'),
          icon: Icons.play_arrow_rounded,
          label: tr(context, 'preview_voice'),
          onPressed:
              busy ||
                  downloading ||
                  checking ||
                  voiceStatus == 'repair' ||
                  voiceStatus == 'unavailable'
              ? null
              : previewVoice,
        ),
        if (voiceStatus == 'download' || voiceStatus == 'repair')
          voiceAction(
            key: const ValueKey('download-voice'),
            icon: Icons.download_outlined,
            label: tr(
              context,
              voiceStatus == 'repair' ? 'repair_voice' : 'neural_download',
            ),
            onPressed: busy || downloading ? null : downloadNeural,
          ),
        if (downloading)
          voiceAction(
            icon: Icons.close_rounded,
            label: tr(context, 'cancel'),
            onPressed: () =>
                action(context, () => ref.read(nativeProvider).api.cancelTts()),
          ),
        if (voiceStatus == 'unavailable')
          voiceAction(
            icon: Icons.refresh,
            label: tr(context, 'retry'),
            onPressed: busy ? null : refreshVoice,
          ),
        SettingsTile(
          key: const ValueKey('auto-speech'),
          icon: Icons.auto_mode_outlined,
          title: tr(context, 'auto_speech'),
          subtitle: tr(context, 'auto_speech_help'),
          enabled: !busy,
          trailing: Switch(
            value: s.autoGenerateVoice,
            onChanged: busy
                ? null
                : (value) => update({'autoGenerateVoice': value}),
          ),
          onTap: () => update({'autoGenerateVoice': !s.autoGenerateVoice}),
        ),
      ],
    );
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
        final settings = ref.read(settingsProvider);
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
        unawaited(loadKeys());
      }
    });
  }

  String? sttValue(AppSettings s) => switch (sttKeySaved) {
    null => null,
    true => s.sttProvider.label,
    false => tr(context, 'not_set_up'),
  };

  String? textModelValue(AppSettings s) {
    if (llmKeySaved == null) return null;
    if (llmKeySaved! && s.provider != null && s.model.trim().isNotEmpty) {
      return '${s.provider!.label} · ${s.model}';
    }
    return tr(context, 'not_set_up');
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final terms = s.transcriptionTerms;
    const indent = SettingsTile.iconIndent;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'settings'))),
      body: PageBody(
        children: [
          SettingsGroup(
            title: tr(context, 'languages'),
            dividerIndent: indent,
            children: [
              SettingsTile(
                icon: Icons.record_voice_over_outlined,
                title: tr(context, 'source_language'),
                value: languages[s.source] ?? s.source,
                enabled: !busy,
                onTap: () =>
                    pickLanguage('source_language', 'source', s.source),
              ),
              SettingsTile(
                icon: Icons.translate,
                title: tr(context, 'target_language'),
                value: languages[s.target] ?? s.target,
                enabled: !busy,
                onTap: () =>
                    pickLanguage('target_language', 'target', s.target),
              ),
              SettingsTile(
                icon: Icons.language,
                title: tr(context, 'app_language'),
                value: appLanguages(context)
                    .firstWhere(
                      (e) => e.$1 == s.locale,
                      orElse: () => appLanguages(context).first,
                    )
                    .$2,
                enabled: !busy,
                onTap: () => pickAppLanguage(s.locale),
              ),
            ],
          ),
          voiceGroup(s),
          SettingsGroup(
            title: tr(context, 'mode'),
            dividerIndent: indent,
            children: [
              SettingsTile(
                icon: Icons.cloud_off_outlined,
                title: tr(context, 'local'),
                subtitle: tr(
                  context,
                  android ? 'android_local_services' : 'local_services',
                ),
                enabled: !busy,
                trailing: Switch(
                  value: s.localOnly,
                  onChanged: busy
                      ? null
                      : (value) => update({'localOnly': value}),
                ),
                onTap: () => update({'localOnly': !s.localOnly}),
              ),
              SettingsTile(
                icon: Icons.graphic_eq,
                title: tr(context, 'stt'),
                value: sttValue(s),
                enabled: !busy,
                onTap: () => openPage(const SttSettingsPage()),
              ),
              SettingsTile(
                icon: Icons.auto_awesome_outlined,
                title: tr(context, 'llm'),
                value: textModelValue(s),
                enabled: !busy,
                onTap: () => openPage(const TextModelSettingsPage()),
              ),
              SettingsTile(
                key: const ValueKey('custom-vocabulary'),
                icon: Icons.spellcheck,
                title: tr(context, 'custom_vocabulary'),
                value: terms.isEmpty
                    ? tr(context, 'none')
                    : tr(
                        context,
                        'term_count',
                      ).replaceAll('{count}', '${terms.length}'),
                enabled: !busy,
                onTap: editVocabulary,
              ),
              SettingsTile(
                icon: Icons.download_for_offline_outlined,
                title: tr(context, 'resources'),
                enabled: !busy,
                onTap: () => openPage(const OfflineResourcesPage()),
              ),
            ],
          ),
          SettingsGroup(
            dividerIndent: indent,
            children: [
              SettingsTile(
                icon: Icons.touch_app_outlined,
                title: tr(
                  context,
                  android ? 'android_shortcut' : 'action_button',
                ),
                onTap: showShortcutHelp,
              ),
              if (android)
                SettingsTile(
                  icon: Icons.description_outlined,
                  title: MaterialLocalizations.of(context).licensesPageTitle,
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'Phrayo',
                  ),
                ),
            ],
          ),
          SettingsGroup(
            title: tr(context, 'data'),
            children: [
              SettingsTile(
                icon: Icons.delete_outline,
                title: tr(context, 'clear'),
                destructive: true,
                enabled: !busy,
                trailing: busy && operation == 'data'
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: clearData,
              ),
            ],
          ),
        ],
      ),
    );
  }
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
