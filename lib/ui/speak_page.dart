import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../core/languages.dart';
import '../core/providers.dart';
import '../services/platform.dart';
import 'common.dart';
import 'library_page.dart';
import 'strings.dart';
import 'speech_button.dart';
import 'translation_attribution.dart';

import 'package:flutter/foundation.dart';

class SpeakPage extends ConsumerStatefulWidget {
  const SpeakPage({super.key});
  @override
  ConsumerState<SpeakPage> createState() => _SpeakPageState();
}

enum _RecordingEnd { finish, discard }

class _SpeakPageState extends ConsumerState<SpeakPage> {
  final input = TextEditingController();
  String output = '', explanation = '';
  bool googleTranslation = false;
  TranslationStyle style = TranslationStyle.preferred;
  String? sessionId, audioPath, finalAppliedId, editedSessionId;
  int revision = 0;
  bool busy = false, starting = false, saving = false, finishing = false;
  bool changingLanguage = false;
  final cancelTarget = GlobalKey();
  final microphoneTarget = GlobalKey();
  final discardedSessions = <String>{};
  late final NativeBridge native;
  int? recordingPointer;
  String? heldSessionId;
  bool cancelArmed = false;
  _RecordingEnd? pendingEnd;
  CancelToken? cancellation;

  @override
  void initState() {
    super.initState();
    native = ref.read(nativeProvider);
  }

  @override
  void dispose() {
    cancellation?.cancel();
    // A pending start handles its own cleanup once its session ID is known.
    if (!starting && !finishing && heldSessionId != null) {
      unawaited(discardOwnedSession(heldSessionId!));
    }
    resetGesture();
    input.dispose();
    super.dispose();
  }

  Future<void> discardOwnedSession(String id) async {
    try {
      final current = await native.api.snapshot();
      if (current?.id == id && current?.state == 'recording') {
        await native.api.cancel();
      }
    } catch (_) {
      // The page is gone; native recovery retains any unfinished capture.
    }
  }

  void resetGesture() {
    recordingPointer = null;
    cancelArmed = false;
    pendingEnd = null;
  }

  bool overCancel(Offset position) {
    final target = cancelTarget.currentContext?.findRenderObject();
    final microphone = microphoneTarget.currentContext?.findRenderObject();
    if (target is! RenderBox || microphone is! RenderBox) return false;
    final bounds = (target.localToGlobal(Offset.zero) & target.size).inflate(8);
    final microphoneTop = microphone.localToGlobal(Offset.zero).dy;
    return position.dy < microphoneTop && bounds.contains(position);
  }

  void moveRecordingPointer(PointerEvent event) {
    if (event.pointer != recordingPointer || pendingEnd != null || finishing) {
      return;
    }
    final armed = overCancel(event.position);
    if (armed == cancelArmed) return;
    setState(() => cancelArmed = armed);
    if (armed) unawaited(HapticFeedback.lightImpact());
  }

  void releaseRecordingPointer(PointerEvent event, {bool cancelled = false}) {
    if (event.pointer != recordingPointer) return;
    final discard = cancelled || overCancel(event.position);
    unawaited(
      endRecording(discard ? _RecordingEnd.discard : _RecordingEnd.finish),
    );
  }

  void changed() {
    finalAppliedId = sessionId;
    editedSessionId = sessionId;
    revision++;
    cancellation?.cancel();
    setState(() {
      output = '';
      googleTranslation = false;
      explanation = '';
      busy = false;
    });
  }

  Future<void> start() async {
    if (starting || finishing || changingLanguage) return;
    setState(() => starting = true);
    revision++;
    cancellation?.cancel();
    final settings = ref.read(settingsProvider);
    final previousSessionId = native.current?.id;
    try {
      final session = await native.api.start(
        'speaking',
        settings.source,
        settings.target,
        settings.localOnly,
        settings.sttProvider.name,
        settings.transcriptionTerms,
      );
      if (!mounted) {
        await discardOwnedSession(session.id);
        return;
      }
      final latest = native.current;
      if (latest != null &&
          latest.id != session.id &&
          latest.id != previousSessionId) {
        resetGesture();
        heldSessionId = null;
        return;
      }
      heldSessionId = session.id;
      // Native events can arrive before the start reply.
      final current = latest?.id == session.id ? latest! : session;
      setState(() {
        sessionId = session.id;
        finalAppliedId = null;
        editedSessionId = null;
        audioPath = null;
        input.text = '';
        output = '';
        googleTranslation = false;
        explanation = '';
      });
      native.sessionChanged(current);
      if (current.state != 'recording') {
        resetGesture();
        heldSessionId = null;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          resetGesture();
          heldSessionId = null;
        });
        notice(context, errorKey(e));
      }
    } finally {
      if (mounted) setState(() => starting = false);
    }
    if (mounted && pendingEnd != null) await endRecording(pendingEnd!);
  }

  Future<void> endRecording(_RecordingEnd end) async {
    if (finishing) return;
    setState(() {
      recordingPointer = null;
      cancelArmed = false;
      pendingEnd = end;
    });
    if (starting) return;
    final current = native.current;
    final id = heldSessionId ?? current?.id;
    if (id == null ||
        current?.id != id ||
        current?.kind == 'recording' ||
        current?.state != 'recording') {
      setState(resetGesture);
      return;
    }
    setState(() {
      finishing = true;
      pendingEnd = null;
      if (end == _RecordingEnd.discard) {
        discardedSessions.add(id);
        clearRecordingDraft();
      }
    });
    try {
      if (end == _RecordingEnd.discard) {
        await native.api.cancel();
        final result = await native.api.snapshot();
        if (!mounted) return;
        if (result?.id == id) {
          // Processing may have won the race and retained a recoverable job.
          if (result!.state != 'cancelled') discardedSessions.remove(id);
          native.sessionChanged(result);
        }
      } else {
        final result = await native.api.stop();
        if (mounted && native.current?.id == id) native.sessionChanged(result);
      }
    } catch (e) {
      if (mounted) {
        discardedSessions.remove(id);
        final latest = native.current;
        if (latest?.id == id) native.sessionChanged(latest!);
        notice(
          context,
          end == _RecordingEnd.discard
              ? 'cancel_recording_failed'
              : errorKey(e),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          finishing = false;
          heldSessionId =
              native.current?.id == id && native.current?.state == 'recording'
              ? id
              : null;
          resetGesture();
        });
      }
    }
  }

  void clearRecordingDraft() {
    revision++;
    cancellation?.cancel();
    input.clear();
    output = '';
    googleTranslation = false;
    explanation = '';
    audioPath = null;
    finalAppliedId = null;
    editedSessionId = null;
    busy = false;
  }

  /// Styles need a text model; system translation is always standard.
  TranslationStyle effectiveStyle(AppSettings settings) =>
      settings.usesTextModel ? style : TranslationStyle.standard;

  Future<void> translate() async {
    final text = input.text.trim();
    if (text.isEmpty || busy || starting || finishing || changingLanguage) {
      return;
    }
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
            style: effectiveStyle(settings),
            cancel: token,
          );
      if (mounted && generation == revision) {
        setState(() {
          output = result;
          googleTranslation = usesGoogleTranslation(settings);
        });
      }
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
            googleTranslation = false;
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
      googleTranslation: googleTranslation,
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
        if (s.kind == 'recording' || discardedSessions.contains(s.id)) return;
        if (s.state == 'cancelled') {
          discardedSessions.add(s.id);
          if (s.id == sessionId) {
            setState(() {
              clearRecordingDraft();
              resetGesture();
              heldSessionId = null;
            });
          }
          return;
        }
        if (heldSessionId != null &&
            (s.id != heldSessionId || s.state != 'recording')) {
          resetGesture();
          heldSessionId = null;
        }
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
            googleTranslation = false;
            explanation = '';
            busy = false;
          }
          sessionId = s.id;
          audioPath = s.path;
          if (s.transcript.isNotEmpty) input.text = s.transcript;
          final current = ref.read(settingsProvider);
          if (effectiveStyle(current) == TranslationStyle.standard &&
              s.translation.isNotEmpty &&
              s.sourceLanguage == current.source &&
              s.targetLanguage == current.target) {
            output = s.translation;
            googleTranslation = false;
          }
        });
        if (s.state == 'saved' && s.transcript.isNotEmpty) {
          final settings = ref.read(settingsProvider);
          // A styled translation comes from the text model, so it replaces
          // the plain live translation without waiting for Translate.
          final styled = effectiveStyle(settings) != TranslationStyle.standard;
          if (s.sourceLanguage == settings.source &&
              s.targetLanguage == settings.target &&
              (styled ||
                  (s.translation.isEmpty &&
                      (defaultTargetPlatform == TargetPlatform.android ||
                          isCantonese(settings.source) ||
                          isCantonese(settings.target))))) {
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
        if (!next.usesTextModel) style = TranslationStyle.preferred;
        changed();
      }
    });
    final session =
        ref.watch(sessionProvider).asData?.value ??
        ref.read(nativeProvider).current;
    final recording =
        session != null &&
        !discardedSessions.contains(session.id) &&
        session.kind != 'recording' &&
        session.state == 'recording';
    final processing =
        session?.state == 'processing' &&
        !discardedSessions.contains(session?.id);
    final languagesLocked =
        starting ||
        finishing ||
        changingLanguage ||
        ['recording', 'paused', 'processing'].contains(session?.state);
    final controlEnabled =
        !busy &&
        !finishing &&
        !processing &&
        !changingLanguage &&
        !(session?.kind == 'recording' &&
            ['recording', 'paused', 'processing'].contains(session?.state));
    final showCancel = (recording || starting) && !finishing;
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
                    enabled:
                        !recording && !processing && !starting && !finishing,
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
                        Flexible(
                          child: TextButton(
                            key: const ValueKey('translate-speech'),
                            onPressed:
                                busy ||
                                    changingLanguage ||
                                    input.text.trim().isEmpty
                                ? null
                                : translate,
                            child: Text(
                              tr(
                                context,
                                usesGoogleTranslation(settings)
                                    ? 'translate_google'
                                    : 'translate',
                              ),
                            ),
                          ),
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
                          if (googleTranslation) const TranslationAttribution(),
                          const SizedBox(height: 20),
                          Row(
                            spacing: 8,
                            children: [
                              // Audio controls carry the longest labels.
                              Flexible(
                                flex: 3,
                                child: SpeechButton(
                                  text: output,
                                  language: settings.target,
                                  enabled: !busy && !recording && !starting,
                                ),
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
                              Flexible(
                                flex: 2,
                                child: TextButton(
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
                  if (showCancel)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: SizedBox(
                        key: cancelTarget,
                        width: 240,
                        child: Semantics(
                          liveRegion: true,
                          label: tr(
                            context,
                            cancelArmed ? 'release_to_cancel' : 'cancel',
                          ),
                          button: true,
                          onTap: pendingEnd != null
                              ? null
                              : () => endRecording(_RecordingEnd.discard),
                          child: ExcludeSemantics(
                            child: TextButton(
                              key: const ValueKey('speak-cancel'),
                              onPressed: pendingEnd != null
                                  ? null
                                  : () {
                                      if (recordingPointer == null) {
                                        unawaited(
                                          endRecording(_RecordingEnd.discard),
                                        );
                                      }
                                    },
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                foregroundColor: cancelArmed
                                    ? colors.onErrorContainer
                                    : colors.onSurfaceVariant,
                                backgroundColor: cancelArmed
                                    ? colors.errorContainer
                                    : colors.surfaceContainerHighest,
                              ),
                              child: IndexedStack(
                                index: cancelArmed ? 1 : 0,
                                alignment: Alignment.center,
                                children: [
                                  Text(
                                    tr(context, 'slide_up_to_cancel'),
                                    textAlign: TextAlign.center,
                                  ),
                                  Text(
                                    tr(context, 'release_to_cancel'),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Center(
                    child: Semantics(
                      key: const ValueKey("speak-control"),
                      enabled: controlEnabled && !starting,
                      button: true,
                      label: tr(context, recording ? 'stop' : 'start'),
                      onTap:
                          !controlEnabled ||
                              starting ||
                              recordingPointer != null
                          ? null
                          : () {
                              if (recording) {
                                endRecording(_RecordingEnd.finish);
                              } else {
                                resetGesture();
                                start();
                              }
                            },
                      child: ExcludeSemantics(
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: !controlEnabled
                              ? null
                              : (event) {
                                  if (starting ||
                                      finishing ||
                                      recordingPointer != null ||
                                      pendingEnd != null) {
                                    return;
                                  }
                                  setState(() {
                                    recordingPointer = event.pointer;
                                    cancelArmed = false;
                                  });
                                  if (recording) {
                                    heldSessionId = session.id;
                                  } else {
                                    start();
                                  }
                                },
                          onPointerMove: moveRecordingPointer,
                          onPointerUp: releaseRecordingPointer,
                          onPointerCancel: (event) =>
                              releaseRecordingPointer(event, cancelled: true),
                          child: AnimatedContainer(
                            key: microphoneTarget,
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
                  Visibility(
                    visible:
                        !recording && !processing && !starting && !finishing,
                    maintainSize: true,
                    maintainState: true,
                    maintainAnimation: true,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ExcludeSemantics(
                        child: Text(
                          tr(context, 'hold_to_speak'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
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
