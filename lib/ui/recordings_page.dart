import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:dio/dio.dart';

import '../core/models.dart';
import '../core/languages.dart';
import '../core/providers.dart';
import 'apple_colors.dart';
import 'common.dart';
import 'settings_services.dart';
import 'strings.dart';
import 'translation_attribution.dart';
import 'transcript_editor.dart';

Future<bool> deleteRecording(
  BuildContext context,
  WidgetRef ref,
  Recording recording,
) async {
  if (!await confirm(context, 'delete_recording')) return false;
  if (!context.mounted) return false;
  await eraseRecording(ref, recording);
  return true;
}

Future<void> eraseRecording(WidgetRef ref, Recording recording) async {
  final service = ref.read(transcriptionProvider);
  final database = ref.read(databaseProvider);
  final native = ref.read(nativeProvider);
  final settings = ref.read(settingsProvider);
  await service.discardJob(recording.id, settings);
  await native.api.deleteAudio(recording.path);
  await database.deleteRecording(recording.id);
}

class RecordingsPage extends ConsumerStatefulWidget {
  const RecordingsPage({super.key});
  @override
  ConsumerState<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends ConsumerState<RecordingsPage> {
  String? selected;
  bool busy = false;
  final deleting = <String>{};
  final batchSelection = <String>{};
  bool selecting = false;
  bool batchBusy = false;

  bool eligible(Recording r) {
    final session = ref.read(nativeProvider).current;
    return !deleting.contains(r.id) &&
        !(session?.id == r.id &&
            ['recording', 'paused', 'processing'].contains(session?.state));
  }

  String countText(String key, int count) =>
      tr(context, key).replaceAll('{count}', '$count');

  Future<void> runBatch(List<Recording> rows, {required bool export}) async {
    if (batchBusy) return;
    final targets = rows
        .where((r) => batchSelection.contains(r.id) && eligible(r))
        .toList();
    if (targets.isEmpty) return;
    setState(() => batchBusy = true);
    try {
      if (export) {
        await ref
            .read(nativeProvider)
            .api
            .shareRecordings(targets.map((r) => r.path).toList());
      } else {
        final approved = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            content: Text(countText('delete_recordings', targets.length)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr(context, 'cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr(context, 'delete')),
              ),
            ],
          ),
        );
        if (approved != true || !mounted) return;
        var deleted = 0;
        final failed = <String>{};
        for (final r in targets) {
          try {
            if (!eligible(r)) throw StateError('recording_active');
            await eraseRecording(ref, r);
            deleted++;
            if (selected == r.id) selected = null;
          } catch (_) {
            failed.add(r.id);
          }
        }
        if (!mounted) return;
        setState(() {
          batchSelection
            ..clear()
            ..addAll(failed);
          selecting = failed.isNotEmpty;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              countText('recordings_deleted', deleted) +
                  (failed.isEmpty
                      ? ''
                      : ' ${countText('recordings_delete_failed', failed.length)}'),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        notice(context, export ? 'batch_export_failed' : errorKey(e));
      }
    } finally {
      if (mounted) setState(() => batchBusy = false);
    }
  }

  Future<void> remove(Recording recording) async {
    if (!deleting.add(recording.id)) return;
    setState(() {});
    await action(context, () async {
      if (await deleteRecording(context, ref, recording) &&
          mounted &&
          selected == recording.id) {
        setState(() => selected = null);
      }
    });
    if (mounted) setState(() => deleting.remove(recording.id));
  }

  Future<void> start() async {
    setState(() => busy = true);
    await action(context, () async {
      final s = ref.read(settingsProvider);
      final result = await ref
          .read(nativeProvider)
          .api
          .start(
            'recording',
            s.source,
            s.target,
            s.localOnly,
            s.sttProvider.name,
            s.transcriptionTerms,
          );
      ref.read(nativeProvider).sessionChanged(result);
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final collection = ref.watch(recordingsProvider);
    final recordings = collection.asData?.value ?? [];
    final current =
        ref.watch(sessionProvider).asData?.value ??
        ref.read(nativeProvider).current;
    final active =
        current?.kind == 'recording' &&
        ['recording', 'paused', 'processing'].contains(current?.state);
    final eligibleIds = recordings
        .where((r) => eligible(r) && !(active && current?.id == r.id))
        .map((r) => r.id)
        .toSet();
    if (collection.hasValue) batchSelection.retainAll(eligibleIds);
    final wide = MediaQuery.sizeOf(context).width > 1000;
    final list = Column(
      children: [
        Expanded(
          child: PageBody(
            width: 600,
            children: [
              if (collection.isLoading)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (collection.hasError)
                EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: tr(context, errorKey(collection.error!)),
                  action: TextButton(
                    onPressed: () => ref.invalidate(recordingsProvider),
                    child: Text(tr(context, 'retry')),
                  ),
                ),
              if (!active &&
                  !collection.isLoading &&
                  !collection.hasError &&
                  recordings.isEmpty)
                EmptyState(
                  icon: Icons.graphic_eq_rounded,
                  title: tr(context, 'no_recordings'),
                  message: tr(context, 'empty_recordings'),
                ),
              ...recordings.map(
                (r) => Column(
                  children: [
                    ListTile(
                      key: ValueKey("recording-${r.id}"),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      minLeadingWidth: 40,
                      horizontalTitleGap: 14,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      trailing: selecting
                          ? null
                          : IconButton(
                              tooltip: tr(context, "delete"),
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              onPressed:
                                  deleting.contains(r.id) ||
                                      (active && current?.id == r.id)
                                  ? null
                                  : () => remove(r),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                      selected: selecting
                          ? batchSelection.contains(r.id)
                          : r.id == selected,
                      leading: selecting
                          ? Checkbox(
                              value: batchSelection.contains(r.id),
                              onChanged:
                                  batchBusy || !eligibleIds.contains(r.id)
                                  ? null
                                  : (_) => setState(() {
                                      if (!batchSelection.add(r.id)) {
                                        batchSelection.remove(r.id);
                                      }
                                    }),
                            )
                          : _RecordingAvatar(
                              live: active && current?.id == r.id,
                              interrupted: r.state == 'interrupted',
                              // Marks the recording open beside the list.
                              selected: wide && r.id == selected,
                            ),
                      title: Text(
                        r.displayTitle.isEmpty
                            ? tr(context, 'untitled')
                            : r.displayTitle,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                              color: r.displayTitle.isEmpty
                                  ? Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                  : null,
                            ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text:
                                    '${durationText(r.seconds)} · ${relativeDateTime(context, r.created)}',
                              ),
                              if (r.state == 'interrupted')
                                TextSpan(
                                  text: ' · ${tr(context, 'interrupted')}',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                            ],
                          ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                height: 1.5,
                                fontFeatures: tabularFigures,
                              ),
                        ),
                      ),
                      onTap:
                          batchBusy ||
                              (selecting && !eligibleIds.contains(r.id))
                          ? null
                          : () {
                              if (selecting) {
                                setState(() {
                                  if (!batchSelection.add(r.id)) {
                                    batchSelection.remove(r.id);
                                  }
                                });
                                return;
                              }
                              if (wide) {
                                setState(() => selected = r.id);
                              } else {
                                Navigator.of(context, rootNavigator: true).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => RecordingDetail(id: r.id),
                                  ),
                                );
                              }
                            },
                    ),
                    const Divider(height: 1),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (selecting)
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: batchBusy || batchSelection.isEmpty
                          ? null
                          : () => runBatch(recordings, export: true),
                      icon: const Icon(Icons.ios_share_rounded),
                      label: Text(tr(context, 'batch_export')),
                    ),
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: batchBusy || batchSelection.isEmpty
                          ? null
                          : () => runBatch(recordings, export: false),
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: Text(tr(context, 'delete')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (!selecting || active)
          Container(
            key: const ValueKey('recording-controls'),
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            child: Align(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (active) ...[
                        // The timer drops below the status at large text
                        // sizes instead of squeezing it.
                        SizedBox(
                          width: double.infinity,
                          child: Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 12,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  LevelDot(
                                    level: current!.level,
                                    live: current.state == 'recording',
                                  ),
                                  const SizedBox(width: 10),
                                  Flexible(
                                    child: Semantics(
                                      liveRegion: true,
                                      child: Text(
                                        tr(
                                          context,
                                          current.state == 'paused'
                                              ? 'paused'
                                              : current.state == 'processing'
                                              ? 'processing'
                                              : 'recording',
                                        ),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                durationText(current.seconds),
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      fontFeatures: tabularFigures,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.tonalIcon(
                                onPressed: current.state == 'processing'
                                    ? null
                                    : () => action(context, () async {
                                        if (current.state == 'paused') {
                                          await ref
                                              .read(nativeProvider)
                                              .api
                                              .resume();
                                        } else {
                                          await ref
                                              .read(nativeProvider)
                                              .api
                                              .pause();
                                        }
                                      }),
                                icon: Icon(
                                  current.state == 'paused'
                                      ? Icons.play_arrow_rounded
                                      : Icons.pause_rounded,
                                ),
                                label: Text(
                                  tr(
                                    context,
                                    current.state == 'paused'
                                        ? 'resume'
                                        : 'pause',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: current.state == 'processing'
                                    ? null
                                    : () => action(context, () async {
                                        final result = await ref
                                            .read(nativeProvider)
                                            .api
                                            .stop();
                                        ref
                                            .read(nativeProvider)
                                            .sessionChanged(result);
                                        if (context.mounted) {
                                          notice(
                                            context,
                                            result.state == 'saved'
                                                ? 'recording_saved'
                                                : 'interrupted',
                                          );
                                        }
                                      }),
                                icon: const Icon(Icons.stop_rounded),
                                label: Text(tr(context, 'stop')),
                              ),
                            ),
                          ],
                        ),
                      ] else
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: busy ? null : start,
                            icon: const Icon(Icons.mic_rounded),
                            label: Text(tr(context, 'new_recording')),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          selecting
              ? countText('batch_selected_count', batchSelection.length)
              : tr(context, 'recordings'),
        ),
        actions: [
          if (selecting)
            TextButton(
              key: const ValueKey('recordings-select-all'),
              onPressed: batchBusy
                  ? null
                  : () => setState(() {
                      if (batchSelection.containsAll(eligibleIds)) {
                        batchSelection.clear();
                      } else {
                        batchSelection.addAll(eligibleIds);
                      }
                    }),
              child: Text(
                tr(
                  context,
                  batchSelection.containsAll(eligibleIds)
                      ? 'deselect_all'
                      : 'select_all',
                ),
              ),
            ),
          if (selecting)
            TextButton(
              key: const ValueKey('recordings-selection-done'),
              onPressed: batchBusy
                  ? null
                  : () => setState(() {
                      selecting = false;
                      batchSelection.clear();
                    }),
              child: Text(tr(context, 'batch_done')),
            )
          else if (eligibleIds.isNotEmpty)
            TextButton(
              key: const ValueKey('recordings-enter-selection'),
              onPressed: deleting.isNotEmpty
                  ? null
                  : () => setState(() => selecting = true),
              child: Text(tr(context, 'batch_select')),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: wide
          ? Row(
              children: [
                Expanded(child: list),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selected == null
                      ? Center(
                          child: EmptyState(
                            icon: Icons.touch_app_outlined,
                            title: tr(context, 'select_recording'),
                          ),
                        )
                      : AbsorbPointer(
                          absorbing: batchBusy,
                          child: ExcludeFocus(
                            excluding: batchBusy,
                            child: RecordingDetail(
                              key: ValueKey(selected),
                              id: selected!,
                              embedded: true,
                            ),
                          ),
                        ),
                ),
              ],
            )
          : list,
    );
  }
}

/// The leading mark of a recording row: live capture, an interrupted
/// recording, or an ordinary saved one.
class _RecordingAvatar extends StatelessWidget {
  final bool live, interrupted, selected;
  const _RecordingAvatar({
    required this.live,
    required this.interrupted,
    this.selected = false,
  });
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tone = live || interrupted ? colors.error : colors.primary;
    final color = selected ? colors.onPrimary : tone;
    return ExcludeSemantics(
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: selected ? tone : tone.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(
          live
              ? Icons.mic_rounded
              : interrupted
              ? Icons.warning_amber_rounded
              : Icons.graphic_eq_rounded,
          size: 20,
          color: color,
        ),
      ),
    );
  }
}

/// Tells speakers apart with Apple system colours, starting with the accent.
Color speakerColor(ColorScheme colors, String speaker) {
  final apple = AppleColors.of(colors.brightness);
  final palette = [apple.blue, apple.orange, apple.green, apple.indigo];
  final index = int.tryParse(speaker) ?? speaker.hashCode.abs();
  return palette[(index - 1) % palette.length];
}

class RecordingDetail extends ConsumerStatefulWidget {
  final String id;
  final bool embedded;
  const RecordingDetail({super.key, required this.id, this.embedded = false});
  @override
  ConsumerState<RecordingDetail> createState() => _RecordingDetailState();
}

class _RecordingDetailState extends ConsumerState<RecordingDetail> {
  bool savingTranslation = false;
  final selected = <String>{};
  String? speaker;
  TranslationStyle? translationStyle;

  /// A plain translation suggests the preferred style for the next one; a
  /// style picked for this recording before is kept.
  TranslationStyle styleFor(Recording r) =>
      translationStyle ??
      (r.translationStyle == TranslationStyle.standard
          ? TranslationStyle.preferred
          : r.translationStyle);
  bool busy = false;
  bool selecting = false;
  int tab = 0;
  CancelToken? cancellation;
  @override
  void dispose() {
    cancellation?.cancel();
    super.dispose();
  }

  Future<void> transcribe(Recording r) async {
    setState(() => busy = true);
    await action(
      context,
      () => ref.read(transcriptionProvider).run(r, ref.read(settingsProvider)),
    );
    if (mounted) setState(() => busy = false);
  }

  Future<void> translate(Recording r) async {
    if (busy || r.segments.isEmpty) return;
    final settings = AppSettings.fromJson({
      ...ref.read(settingsProvider).toJson(),
      'source': r.sourceLanguage,
      'target': r.targetLanguage,
    });
    final style = settings.usesTextModel
        ? styleFor(r)
        : TranslationStyle.standard;
    final token = CancelToken();
    cancellation = token;
    final processor = ref.read(textProcessorProvider);
    final db = ref.read(databaseProvider);
    setState(() => busy = true);
    await action(context, () async {
      final result = await processor.translate(
        r.segments.map((s) => s.text).join('\n'),
        settings,
        style: style,
        cancel: token,
      );
      if (!mounted || token.isCancelled) return;
      await db.replaceIfCurrent(r.id, r.revision, {
        ...r.toJson(),
        'translation': result,
        'googleTranslation': usesGoogleTranslation(settings),
        'translationStyle': style.name,
        'revision': r.revision + 1,
      });
    });
    if (mounted) setState(() => busy = false);
  }

  String translationSource(Recording r) =>
      r.segments.map((s) => s.text).join('\n').trim();

  bool matchesTranslation(Expression phrase, Recording r) =>
      phrase.source == translationSource(r) &&
      phrase.target == r.translation.trim() &&
      phrase.sourceLanguage == r.sourceLanguage &&
      phrase.targetLanguage == r.targetLanguage;

  Future<void> saveTranslation(Recording r) async {
    if (busy ||
        savingTranslation ||
        r.translation.trim().isEmpty ||
        r.segments.isEmpty) {
      return;
    }
    setState(() => savingTranslation = true);
    await action(context, () async {
      final db = ref.read(databaseProvider);
      await db.transaction(() async {
        final current = await db.get(r.id);
        if (current == null || current['revision'] != r.revision) {
          throw StateError('recording_changed');
        }
        final existing = (await db.list('expression')).map(Expression.fromJson);
        if (existing.any((phrase) => matchesTranslation(phrase, r))) return;
        final phrase = Expression(
          id: const Uuid().v4(),
          source: translationSource(r),
          target: r.translation.trim(),
          googleTranslation: r.googleTranslation,
          sourceLanguage: r.sourceLanguage,
          targetLanguage: r.targetLanguage,
          recordingId: r.id,
          audioPath: r.path,
          sourceIds: r.segments.map((s) => s.id).toList(),
          audioStart: r.segments
              .map((s) => s.start)
              .reduce((a, b) => a < b ? a : b),
          audioEnd: r.segments
              .map((s) => s.end)
              .reduce((a, b) => a > b ? a : b),
        );
        await db.put(phrase.id, 'expression', phrase.toJson());
      });
    });
    if (mounted) setState(() => savingTranslation = false);
  }

  Future<void> generate(Recording r, bool summary) async {
    if (!requireTextModel(context, ref)) return;
    final segments = summary
        ? r.segments
        : r.segments.where((s) => selected.contains(s.id)).toList();
    if (segments.isEmpty) return;
    setState(() => busy = true);
    cancellation = CancelToken();
    await action(context, () async {
      final selectedSettings = ref.read(settingsProvider);
      final settings = AppSettings.fromJson({
        ...selectedSettings.toJson(),
        'source': r.sourceLanguage,
        'target': r.targetLanguage,
      });
      final result = await ref
          .read(textProcessorProvider)
          .structured(
            summary
                ? 'Extract up to 8 important points. Each object has text (a string in ${settings.source}) and sourceIds.'
                : 'Create up to 5 useful practice expressions from these passages. Each object has source (a string in ${settings.source}), target (a natural expression in ${settings.target}), and sourceIds.',
            segments,
            settings,
            cancel: cancellation,
          );
      final db = ref.read(databaseProvider);
      final current = await db.get(r.id);
      if (current == null ||
          current['revision'] != r.revision ||
          cancellation!.isCancelled) {
        return;
      }
      if (summary) {
        if (result.any(
          (s) => s['text'] is! String || s['text'].trim().isEmpty,
        )) {
          throw StateError('invalid_response');
        }
        await db.replaceIfCurrent(r.id, r.revision, {
          ...r.toJson(),
          'summary': result,
          'revision': r.revision + 1,
        });
      } else {
        if (result.any(
          (s) =>
              s['source'] is! String ||
              s['target'] is! String ||
              s['source'].trim().isEmpty ||
              s['target'].trim().isEmpty,
        )) {
          throw StateError('invalid_response');
        }
        await db.transaction(() async {
          final latest = await db.get(r.id);
          if (latest == null || latest['revision'] != r.revision) return;
          for (final item in result) {
            final sourceIds = (item['sourceIds'] as List).cast<String>();
            final origin =
                r.segments.where((s) => sourceIds.contains(s.id)).toList()
                  ..sort((a, b) => a.start.compareTo(b.start));
            final expression = Expression(
              id: const Uuid().v4(),
              source: item['source'],
              target: item['target'],
              sourceLanguage: settings.source,
              targetLanguage: settings.target,
              recordingId: r.id,
              audioPath: r.path,
              sourceIds: sourceIds,
              audioStart: origin.first.start,
              audioEnd: origin.last.end,
            );
            await db.put(expression.id, 'expression', {
              ...expression.toJson(),
              'sourceIds': item['sourceIds'],
            });
          }
        });
        if (mounted) notice(context, 'saved');
      }
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> editTranscript(Recording r) async {
    final db = ref.read(databaseProvider);
    final saved = await Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute(
        builder: (_) => TranscriptEditor(
          recording: r,
          onSave: (text) => db.editRecordingTranscript(r, text),
        ),
      ),
    );
    if (mounted && saved == true) {
      setState(() {
        selected.clear();
        selecting = false;
        speaker = null;
      });
    }
  }

  Widget menu(Recording r, bool hasJob) => PopupMenuButton<String>(
    tooltip: tr(context, 'more'),
    enabled: !busy,
    onSelected: (value) => action(context, () async {
      switch (value) {
        case 'edit_transcript':
          await editTranscript(r);
        case 'share':
          await ref
              .read(nativeProvider)
              .api
              .share(r.segments.map((s) => s.text).join('\n'), r.path);
        case 'retranscribe':
          await transcribe(r);
        case 'discard_job':
          await ref
              .read(transcriptionProvider)
              .discardJob(r.id, ref.read(settingsProvider));
        case 'delete':
          if (!await deleteRecording(context, ref, r)) return;
          if (mounted && !widget.embedded) Navigator.pop(context);
      }
    }),
    itemBuilder: (_) => [
      if (r.segments.isNotEmpty)
        PopupMenuItem(
          value: 'edit_transcript',
          enabled: !hasJob,
          child: Text(tr(context, 'edit_transcript')),
        ),
      PopupMenuItem(value: 'share', child: Text(tr(context, 'share'))),
      if (r.segments.isNotEmpty)
        PopupMenuItem(
          value: 'retranscribe',
          child: Text(tr(context, 'retranscribe')),
        ),
      if (hasJob)
        PopupMenuItem(
          value: 'discard_job',
          child: Text(tr(context, 'discard_job')),
        ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'delete',
        child: Text(
          tr(context, 'delete'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    ],
  );

  void toggleSelection(String id) => setState(() {
    if (!selected.add(id)) selected.remove(id);
  });

  Widget passage(Recording r, Segment segment) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: !selecting,
      child: InkWell(
        key: ValueKey('passage-${segment.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: busy
            ? null
            : () {
                if (selecting) {
                  toggleSelection(segment.id);
                } else {
                  action(
                    context,
                    () => ref
                        .read(nativeProvider)
                        .api
                        .play(r.path, segment.start, segment.end),
                  );
                }
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selecting)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Checkbox(
                    value: selected.contains(segment.id),
                    onChanged: busy ? null : (_) => toggleSelection(segment.id),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (!selecting) ...[
                          Icon(
                            Icons.play_arrow_rounded,
                            size: 16,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 2),
                        ],
                        Text(
                          durationText(segment.start),
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: selecting
                                    ? colors.onSurfaceVariant
                                    : colors.primary,
                                fontFeatures: tabularFigures,
                              ),
                        ),
                        if (segment.speaker != null) ...[
                          const SizedBox(width: 12),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: speakerColor(colors, segment.speaker!),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '${tr(context, 'speaker')} ${segment.speaker}',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      segment.text,
                      style: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(fontSize: 18, height: 1.65),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(recordingsProvider).asData?.value ?? [];
    final r = rows.where((r) => r.id == widget.id).firstOrNull;
    if (r == null) {
      return widget.embedded
          ? const SizedBox.shrink()
          : Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
    }
    final expressions = ref.watch(expressionsProvider).asData?.value;
    final translationSaved =
        expressions?.any((phrase) => matchesTranslation(phrase, r)) ?? false;
    final job = (ref.watch(jobsProvider).asData?.value ?? [])
        .where((j) => j['recordingId'] == r.id)
        .firstOrNull;
    final speakers = r.segments
        .map((s) => s.speaker)
        .whereType<String>()
        .toSet();
    final visible = r.segments
        .where((s) => speaker == null || s.speaker == speaker)
        .toList();
    final validSelected = r.segments
        .where((s) => selected.contains(s.id))
        .length;
    final colors = Theme.of(context).colorScheme;
    final date = relativeDateTime(context, r.created);
    final body = Column(
      children: [
        if (widget.embedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr(context, 'recording_detail'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                menu(r, job != null),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Panel(
            key: const ValueKey('recording-player'),
            child: Row(
              children: [
                IconButton.filled(
                  tooltip: tr(context, 'play_audio'),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(52, 52),
                    backgroundColor: colors.primary,
                    foregroundColor: colors.onPrimary,
                  ),
                  onPressed: () => action(
                    context,
                    () => ref.read(nativeProvider).api.play(r.path, 0, null),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        durationText(r.seconds),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        date,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: tr(context, 'stop_playback'),
                  onPressed: () => action(
                    context,
                    () => ref.read(nativeProvider).api.stopPlayback(),
                  ),
                  icon: const Icon(Icons.stop_rounded),
                ),
              ],
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
            final stacked = constraints.maxWidth < 760 || largeText;
            final scrollableTabs = constraints.maxWidth < 360 || largeText;
            final tabs = TabBar(
              isScrollable: scrollableTabs,
              tabAlignment: scrollableTabs
                  ? TabAlignment.start
                  : TabAlignment.fill,
              labelPadding: EdgeInsets.symmetric(
                horizontal: scrollableTabs ? 16 : 8,
              ),
              dividerColor: Colors.transparent,
              onTap: (value) => setState(() {
                tab = value;
                if (value != 0) {
                  selecting = false;
                  selected.clear();
                  speaker = null;
                }
              }),
              tabs: [
                Tab(text: tr(context, 'transcript')),
                Tab(text: tr(context, 'translated_text')),
                Tab(text: tr(context, 'summary')),
              ],
            );
            final selection = Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton(
                style: TextButton.styleFrom(
                  maximumSize: const Size(160, double.infinity),
                ),
                onPressed: busy
                    ? null
                    : () => setState(() {
                        selecting = !selecting;
                        selected.clear();
                        speaker = null;
                      }),
                child: Text(
                  tr(context, selecting ? 'cancel' : 'select_passages'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
            final hasSelection = tab == 0 && r.segments.isNotEmpty;
            if (stacked) {
              return Column(
                children: [
                  tabs,
                  if (hasSelection)
                    Align(alignment: Alignment.centerRight, child: selection),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: tabs),
                if (hasSelection) selection,
              ],
            );
          },
        ),
        const Divider(height: 1),
        if (selecting)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 16, 0),
            child: Row(
              children: [
                if (speakers.length > 1)
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: speaker ?? '',
                      underline: const SizedBox.shrink(),
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(tr(context, 'all_speakers')),
                        ),
                        ...speakers.map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text('${tr(context, 'speaker')} $s'),
                          ),
                        ),
                      ],
                      onChanged: busy
                          ? null
                          : (value) => setState(() {
                              speaker = value == '' ? null : value;
                              selected.clear();
                            }),
                    ),
                  )
                else
                  const Spacer(),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(
                          () => selected.addAll(visible.map((s) => s.id)),
                        ),
                  child: Text(tr(context, 'select_all')),
                ),
              ],
            ),
          ),
        if (busy) ...[
          const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Expanded(child: Text(tr(context, 'processing'))),
                TextButton(
                  onPressed: () {
                    ref.read(transcriptionProvider).cancel(r.id);
                    cancellation?.cancel();
                  },
                  child: Text(tr(context, 'stop_processing')),
                ),
              ],
            ),
          ),
        ],
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [
              if (r.state == 'interrupted')
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    tr(context, 'interrupted'),
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              if ([
                'submission_unknown',
                'upload_unknown',
              ].contains(job?['stage']))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    tr(
                      context,
                      job?['provider'] == 'mossPro'
                          ? 'moss_submission_unknown'
                          : 'submission_unknown',
                    ),
                  ),
                ),
              if (r.segments.isEmpty) ...[
                if (r.title.isEmpty)
                  EmptyState(
                    compact: true,
                    icon: Icons.notes_rounded,
                    title: tr(context, 'no_transcript'),
                    action: FilledButton.icon(
                      onPressed: busy ? null : () => transcribe(r),
                      icon: const Icon(Icons.subtitles_outlined),
                      label: Text(tr(context, 'transcribe')),
                    ),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      r.title,
                      style: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(height: 1.6),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: busy ? null : () => transcribe(r),
                      icon: const Icon(Icons.subtitles_outlined),
                      label: Text(tr(context, 'transcribe')),
                    ),
                  ),
                ],
              ] else if (tab == 0) ...[
                for (var i = 0; i < visible.length; i++) ...[
                  passage(r, visible[i]),
                  if (i < visible.length - 1) const Divider(height: 1),
                ],
              ] else if (tab == 1) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(
                      Icons.translate_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '${languages[r.sourceLanguage] ?? r.sourceLanguage} → ${languages[r.targetLanguage] ?? r.targetLanguage}',
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: LayoutBuilder(
                    builder: (context, constraints) => Row(
                      key: const ValueKey('recording-translation-controls'),
                      children: [
                        // Styles need a text model; without one the picker
                        // would only ever show Standard.
                        if (ref.watch(settingsProvider).usesTextModel) ...[
                          Expanded(
                            child: TranslationStylePicker(
                              value: styleFor(r),
                              settings: ref.watch(settingsProvider),
                              onChanged: busy
                                  ? null
                                  : (value) => setState(
                                      () => translationStyle = value,
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: ref.watch(settingsProvider).usesTextModel
                                ? constraints.maxWidth * .42
                                : constraints.maxWidth,
                          ),
                          child: FilledButton(
                            key: const ValueKey('translate-recording'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            onPressed: busy ? null : () => translate(r),
                            child: Text(
                              tr(
                                context,
                                usesGoogleTranslation(
                                      AppSettings.fromJson({
                                        ...ref.watch(settingsProvider).toJson(),
                                        'source': r.sourceLanguage,
                                        'target': r.targetLanguage,
                                      }),
                                    )
                                    ? 'translate_google'
                                    : r.translation.isEmpty
                                    ? 'translate'
                                    : 'retranslate',
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (r.translation.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Panel(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        EyebrowLabel(
                          tr(context, 'style_${r.translationStyle.name}'),
                          color: colors.primary,
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          r.translation,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(height: 1.65),
                        ),
                        if (r.googleTranslation) const TranslationAttribution(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('save-recording-translation'),
                      onPressed:
                          busy ||
                              savingTranslation ||
                              translationSaved ||
                              expressions == null
                          ? null
                          : () => saveTranslation(r),
                      icon: Icon(
                        translationSaved
                            ? Icons.bookmark_added
                            : Icons.bookmark_add_outlined,
                      ),
                      label: Text(
                        tr(
                          context,
                          translationSaved ? 'saved' : 'save_to_expressions',
                        ),
                      ),
                    ),
                  ),
                ],
              ] else if (r.summary.isEmpty) ...[
                EmptyState(
                  compact: true,
                  icon: Icons.lightbulb_outline_rounded,
                  title: tr(context, 'summary_empty'),
                  action: FilledButton.icon(
                    onPressed: busy ? null : () => generate(r, true),
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: Text(tr(context, 'summarize')),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                ...r.summary.map(
                  (point) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      minLeadingWidth: 12,
                      leading: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: colors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      title: Text(
                        point['text'] as String,
                        style: Theme.of(context).textTheme.bodyLarge
                            ?.copyWith(height: 1.6),
                      ),
                      trailing: Icon(
                        Icons.play_circle_outline_rounded,
                        color: colors.primary,
                        semanticLabel: tr(context, 'play_passage'),
                      ),
                      onTap: () {
                        final ids = (point['sourceIds'] as List).cast<String>();
                        final origin = r.segments
                            .where((s) => ids.contains(s.id))
                            .firstOrNull;
                        if (origin != null) {
                          action(
                            context,
                            () => ref
                                .read(nativeProvider)
                                .api
                                .play(r.path, origin.start, origin.end),
                          );
                        }
                      },
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: busy ? null : () => generate(r, true),
                    child: Text(tr(context, 'regenerate')),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (selecting)
          Container(
            key: const ValueKey('practice-selection-bar'),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 8,
              children: [
                Text(
                  tr(
                    context,
                    'selected_count',
                  ).replaceAll('{count}', '$validSelected'),
                ),
                FilledButton(
                  onPressed: busy || validSelected == 0
                      ? null
                      : () => generate(r, false),
                  child: Text(tr(context, 'generate')),
                ),
              ],
            ),
          ),
      ],
    );
    final content = DefaultTabController(length: 3, child: body);
    return widget.embedded
        ? content
        : Scaffold(
            appBar: AppBar(
              title: Text(tr(context, 'recording_detail')),
              actions: [menu(r, job != null), const SizedBox(width: 8)],
            ),
            body: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: content,
                ),
              ),
            ),
          );
  }
}
