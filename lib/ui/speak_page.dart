import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../core/languages.dart';
import '../core/providers.dart';
import 'common.dart';
import 'library_page.dart';
import 'strings.dart';
import 'speech_button.dart';

class SpeakPage extends ConsumerStatefulWidget {
  const SpeakPage({super.key});
  @override
  ConsumerState<SpeakPage> createState() => _SpeakPageState();
}

class _SpeakPageState extends ConsumerState<SpeakPage> {
  final input = TextEditingController();
  String output = '', explanation = '';
  TranslationStyle style = TranslationStyle.standard;
  String? sessionId, audioPath, finalAppliedId, editedSessionId;
  int revision = 0;
  bool busy = false, starting = false, pressed = false, saving = false;
  bool changingLanguage = false;
  CancelToken? cancellation;
  @override
  void dispose() {
    cancellation?.cancel();
    input.dispose();
    super.dispose();
  }

  void changed() {
    finalAppliedId = sessionId;
    editedSessionId = sessionId;
    revision++;
    cancellation?.cancel();
    setState(() {
      output = '';
      explanation = '';
      busy = false;
    });
  }

  Future<void> start() async {
    if (starting || changingLanguage) return;
    setState(() => starting = true);
    revision++;
    cancellation?.cancel();
    final settings = ref.read(settingsProvider);
    try {
      final session = await ref
          .read(nativeProvider)
          .api
          .start(
            'speaking',
            settings.source,
            settings.target,
            settings.localOnly,
            settings.sttProvider.name,
            settings.transcriptionTerms,
          );
      if (!mounted) return;
      setState(() {
        sessionId = session.id;
        finalAppliedId = null;
        editedSessionId = null;
        audioPath = null;
        input.text = '';
        output = '';
        explanation = '';
      });
      ref.read(nativeProvider).sessionChanged(session);
      if (!pressed) await stop();
    } catch (e) {
      if (mounted) notice(context, errorKey(e));
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  Future<void> stop() async {
    await action(context, () async {
      final session = await ref.read(nativeProvider).api.stop();
      ref.read(nativeProvider).sessionChanged(session);
    });
  }

  Future<void> translate() async {
    final text = input.text.trim();
    if (text.isEmpty || busy || starting || changingLanguage) return;
    final generation = ++revision;
    cancellation?.cancel();
    final token = CancelToken();
    cancellation = token;
    setState(() => busy = true);
    final settings = ref.read(settingsProvider);
    try {
      final result = await ref
          .read(textProcessorProvider)
          .translate(
            text,
            settings,
            style: settings.usesTextModel ? style : TranslationStyle.standard,
            cancel: token,
          );
      if (mounted && generation == revision) setState(() => output = result);
    } catch (e) {
      if (mounted && generation == revision && !token.isCancelled) {
        notice(context, errorKey(e));
      }
    } finally {
      if (mounted && generation == revision) setState(() => busy = false);
    }
  }

  Future<void> changeLanguage(String field, String value) async {
    if (changingLanguage) return;
    final settings = ref.read(settingsProvider);
    if (settings.toJson()[field] == value) return;
    setState(() => changingLanguage = true);
    await action(context, () async {
      await ref
          .read(settingsProvider.notifier)
          .save(AppSettings.fromJson({...settings.toJson(), field: value}));
    });
    if (mounted) setState(() => changingLanguage = false);
  }

  Future<void> process(String key) async {
    final generation = ++revision;
    cancellation?.cancel();
    final token = CancelToken();
    cancellation = token;
    final task = switch (key) {
      'natural' => 'Rewrite as one natural everyday expression.',
      'polite' => 'Rewrite politely without changing the meaning.',
      'shorter' => 'Make this concise while preserving all meaning.',
      _ => 'Explain one useful phrase briefly, in the learner source language.',
    };
    setState(() => busy = true);
    try {
      await for (final result
          in ref
              .read(textProcessorProvider)
              .rewrite(
                task,
                'Source: ${input.text}\nExpression: $output',
                ref.read(settingsProvider),
                cancel: token,
              )) {
        if (!mounted || generation != revision) return;
        setState(() {
          if (key == 'explain') {
            explanation = result;
          } else {
            output = result;
          }
        });
      }
    } catch (e) {
      if (mounted && !token.isCancelled) notice(context, errorKey(e));
    } finally {
      if (mounted && generation == revision) setState(() => busy = false);
    }
  }

  Expression expression() {
    final settings = ref.read(settingsProvider);
    return Expression(
      id: const Uuid().v4(),
      source: input.text.trim(),
      target: output.trim(),
      sourceLanguage: settings.source,
      targetLanguage: settings.target,
      recordingId: sessionId,
      audioPath: audioPath,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settingsForSave = ref.watch(settingsProvider);
    final expressions = ref.watch(expressionsProvider).asData?.value;
    final saved =
        expressions?.any(
          (phrase) =>
              phrase.source == input.text.trim() &&
              phrase.target == output.trim() &&
              phrase.sourceLanguage == settingsForSave.source &&
              phrase.targetLanguage == settingsForSave.target,
        ) ??
        false;
    ref.listen(sessionProvider, (_, next) {
      next.whenData((s) {
        if (s.kind == 'recording') return;
        final fresh = s.id != sessionId;
        if (!fresh && editedSessionId == s.id) return;
        if (fresh &&
            s.kind != 'shortcut' &&
            !(s.kind == 'speaking' &&
                ['recording', 'paused', 'processing'].contains(s.state))) {
          return;
        }
        if (finalAppliedId == s.id &&
            ['saved', 'interrupted'].contains(s.state)) {
          return;
        }
        if (['saved', 'interrupted'].contains(s.state)) finalAppliedId = s.id;
        if (!mounted) return;
        setState(() {
          if (fresh) {
            editedSessionId = null;
            revision++;
            cancellation?.cancel();
            input.text = '';
            output = '';
            explanation = '';
            busy = false;
          }
          sessionId = s.id;
          audioPath = s.path;
          if (s.transcript.isNotEmpty) input.text = s.transcript;
          final current = ref.read(settingsProvider);
          if (style == TranslationStyle.standard &&
              s.translation.isNotEmpty &&
              s.sourceLanguage == current.source &&
              s.targetLanguage == current.target) {
            output = s.translation;
          }
        });
        if (s.state == 'saved' &&
            s.translation.isEmpty &&
            s.transcript.isNotEmpty) {
          final settings = ref.read(settingsProvider);
          if (s.sourceLanguage == settings.source &&
              s.targetLanguage == settings.target &&
              (isCantonese(settings.source) || isCantonese(settings.target))) {
            unawaited(translate());
          }
        }
        if (s.error != null) notice(context, errorKey(StateError(s.error!)));
      });
    });
    ref.listen(settingsProvider, (previous, next) {
      if (previous != null &&
          (previous.target != next.target ||
              previous.source != next.source ||
              previous.localOnly != next.localOnly ||
              previous.provider != next.provider ||
              previous.model != next.model)) {
        if (!next.usesTextModel) style = TranslationStyle.standard;
        changed();
      }
    });
    final session =
        ref.watch(sessionProvider).asData?.value ??
        ref.read(nativeProvider).current;
    final recording =
        session != null &&
        session.kind != 'recording' &&
        session.state == 'recording';
    final processing = session?.state == 'processing';
    final languagesLocked =
        starting ||
        changingLanguage ||
        ['recording', 'paused', 'processing'].contains(session?.state);
    final settings = ref.watch(settingsProvider);
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 360;
        final controlSize = compact ? 64.0 : 96.0;
        return Column(
          children: [
            Expanded(
              child: PageBody(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _LanguageDropdown(
                          key: const ValueKey('speak-source-language'),
                          label: tr(context, 'source_language'),
                          value: settings.source,
                          onChanged: languagesLocked
                              ? null
                              : (value) => changeLanguage('source', value),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Icon(Icons.arrow_forward_rounded, size: 18),
                      ),
                      Expanded(
                        child: _LanguageDropdown(
                          key: const ValueKey('speak-target-language'),
                          label: tr(context, 'target_language'),
                          value: settings.target,
                          onChanged: languagesLocked
                              ? null
                              : (value) => changeLanguage('target', value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: input,
                    minLines: 2,
                    maxLines: 6,
                    enabled: !recording && !processing && !starting,
                    decoration: InputDecoration(
                      labelText: tr(context, 'original'),
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
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
                    ),
                    onChanged: (_) => changed(),
                  ),
                  if (input.text.isNotEmpty &&
                      !recording &&
                      !processing &&
                      !starting) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TranslationStylePicker(
                            value: style,
                            settings: settings,
                            onChanged: busy
                                ? null
                                : (value) {
                                    changed();
                                    setState(() => style = value);
                                  },
                          ),
                        ),
                        const SizedBox(width: 12),
                        TextButton(
                          key: const ValueKey('translate-speech'),
                          onPressed:
                              busy ||
                                  changingLanguage ||
                                  input.text.trim().isEmpty
                              ? null
                              : translate,
                          child: Text(tr(context, 'translate')),
                        ),
                      ],
                    ),
                  ],
                  if (busy) const LinearProgressIndicator(),
                  if (output.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(context, 'translation'),
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 14),
                          SelectableText(
                            output,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(height: 1.4),
                          ),
                          const SizedBox(height: 20),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              SpeechButton(
                                text: output,
                                language: settings.target,
                                enabled: !busy && !recording && !starting,
                              ),
                              IconButton(
                                tooltip: tr(context, saved ? 'saved' : 'save'),
                                onPressed:
                                    busy ||
                                        saving ||
                                        saved ||
                                        expressions == null
                                    ? null
                                    : () => action(context, () async {
                                        setState(() => saving = true);
                                        try {
                                          final phrase = expression();
                                          await ref
                                              .read(databaseProvider)
                                              .put(
                                                phrase.id,
                                                'expression',
                                                phrase.toJson(),
                                              );
                                        } finally {
                                          if (mounted) {
                                            setState(() => saving = false);
                                          }
                                        }
                                      }),
                                icon: Icon(
                                  saved
                                      ? Icons.bookmark_added
                                      : Icons.bookmark_add_outlined,
                                ),
                              ),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () =>
                                          Navigator.of(
                                            context,
                                            rootNavigator: true,
                                          ).push(
                                            MaterialPageRoute<void>(
                                              builder: (_) => PracticePage(
                                                expression: expression(),
                                              ),
                                            ),
                                          ),
                                child: Text(tr(context, 'practice')),
                              ),
                              PopupMenuButton<String>(
                                tooltip: tr(context, 'more'),
                                enabled: !busy && settings.usesTextModel,
                                onSelected: process,
                                itemBuilder: (_) =>
                                    ['natural', 'polite', 'shorter', 'explain']
                                        .map(
                                          (key) => PopupMenuItem(
                                            value: key,
                                            child: Text(tr(context, key)),
                                          ),
                                        )
                                        .toList(),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (explanation.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: SelectableText(explanation),
                    ),
                ],
              ),
            ),
            Padding(
              key: const ValueKey('speak-footer'),
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (recording || processing || starting)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          '${tr(context, processing
                              ? 'processing'
                              : recording
                              ? 'listening'
                              : 'preparing_audio')} ${recording ? durationText(session.seconds) : ''}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  Center(
                    child: Semantics(
                      key: const ValueKey("speak-control"),
                      enabled: !busy && !processing && !changingLanguage,
                      button: true,
                      label: tr(context, recording ? 'stop' : 'start'),
                      onTap: busy || processing || changingLanguage
                          ? null
                          : () {
                              pressed = true;
                              if (recording) {
                                pressed = false;
                                stop();
                              } else {
                                start();
                              }
                            },
                      child: ExcludeSemantics(
                        child: Listener(
                          onPointerDown: busy || processing || changingLanguage
                              ? null
                              : (_) {
                                  pressed = true;
                                  start();
                                },
                          onPointerUp: (_) {
                            if (!pressed) return;
                            pressed = false;
                            if (!starting) stop();
                          },
                          onPointerCancel: (_) {
                            if (!pressed) return;
                            pressed = false;
                            if (!starting) stop();
                          },
                          child: AnimatedContainer(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 120),
                            width: controlSize,
                            height: controlSize,
                            decoration: BoxDecoration(
                              color: recording
                                  ? colors.primaryContainer
                                  : colors.primary,
                              shape: BoxShape.circle,
                              boxShadow: [
                                if (recording)
                                  BoxShadow(
                                    color: colors.primary.withValues(
                                      alpha: 0.25,
                                    ),
                                    spreadRadius: 6 + (session.level * 8),
                                    blurRadius: 0,
                                  ),
                              ],
                            ),
                            child: Icon(
                              recording
                                  ? Icons.stop_rounded
                                  : Icons.mic_rounded,
                              size: 36,
                              color: recording
                                  ? colors.onPrimaryContainer
                                  : colors.onPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!recording && !processing && !starting)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ExcludeSemantics(
                        child: Text(
                          tr(context, 'hold_to_speak'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LanguageDropdown extends StatelessWidget {
  final String label, value;
  final ValueChanged<String>? onChanged;
  const _LanguageDropdown({
    super.key,
    required this.label,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final choices = {
      ...languages,
      if (!languages.containsKey(value)) value: value,
    };
    return Semantics(
      label: label,
      child: Tooltip(
        message: label,
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          itemHeight: null,
          menuWidth: 280,
          menuMaxHeight: 400,
          borderRadius: BorderRadius.circular(12),
          underline: const SizedBox.shrink(),
          style: Theme.of(context).textTheme.labelLarge,
          selectedItemBuilder: (_) => [
            for (final name in choices.values)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
          items: [
            for (final entry in choices.entries)
              DropdownMenuItem(
                value: entry.key,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(entry.value),
                ),
              ),
          ],
          onChanged: onChanged == null
              ? null
              : (value) {
                  if (value != null) onChanged!(value);
                },
        ),
      ),
    );
  }
}
