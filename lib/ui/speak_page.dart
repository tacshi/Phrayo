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
import 'settings_services.dart';
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
  final inputFocus = FocusNode();
  String output = '', explanation = '';

  /// Clearing the field ends the recording draft: text typed afterwards is
  /// saved without the previous recording's audio.
  bool recordingDetached = false;
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
    inputFocus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  void startTyping() {
    inputFocus.requestFocus();
    // Reopen the keyboard when the field kept focus but it was dismissed.
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  Future<void> submitTyped() async {
    inputFocus.unfocus();
    await translate();
  }

  @override
  void dispose() {
    cancellation?.cancel();
    // A pending start handles its own cleanup once its session ID is known.
    if (!starting && !finishing && heldSessionId != null) {
      unawaited(discardOwnedSession(heldSessionId!));
    }
    resetGesture();
    inputFocus.dispose();
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
      if (input.text.trim().isEmpty) recordingDetached = true;
      output = '';
      googleTranslation = false;
      explanation = '';
      busy = false;
    });
  }

  Future<void> start() async {
    if (starting || finishing || changingLanguage) return;
    inputFocus.unfocus();
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
        recordingDetached = false;
        input.text = '';
        output = '';
        googleTranslation = false;
        explanation = '';
      });
      native.sessionChanged(current);
      if (current.state != 'recording') {
        resetGesture();
        heldSessionId = null;
      } else {
        unawaited(HapticFeedback.mediumImpact());
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
        unawaited(HapticFeedback.selectionClick());
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
    recordingDetached = false;
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
    if (!requireTextModel(context, ref)) return;
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

  /// Swaps spoken and target languages. Like a translator's swap, an
  /// expression on screen becomes the text to translate back.
  Future<void> swapLanguages() async {
    if (changingLanguage) return;
    final settings = ref.read(settingsProvider);
    if (settings.source == settings.target) return;
    final expression = output.trim();
    unawaited(HapticFeedback.selectionClick());
    setState(() => changingLanguage = true);
    var swapped = false;
    await action(context, () async {
      await ref
          .read(settingsProvider.notifier)
          .save(
            AppSettings.fromJson({
              ...settings.toJson(),
              'source': settings.target,
              'target': settings.source,
            }),
          );
      swapped = true;
    });
    if (!mounted) return;
    setState(() {
      changingLanguage = false;
      if (swapped && expression.isNotEmpty) {
        input.text = expression;
        // The recording was spoken in the previous language.
        recordingDetached = true;
      }
    });
  }

  Future<void> copyOutput() async {
    await Clipboard.setData(ClipboardData(text: output.trim()));
    unawaited(HapticFeedback.lightImpact());
    if (mounted) notice(context, 'copied_toast');
  }

  void clearInput() {
    input.clear();
    changed();
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
      recordingId: recordingDetached ? null : sessionId,
      audioPath: recordingDetached ? null : audioPath,
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
            recordingDetached = false;
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
    final typing = inputFocus.hasFocus;
    final idle = !recording && !processing && !starting && !finishing;
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final inputEnabled = !recording && !processing && !starting && !finishing;
    final showIntro =
        idle &&
        !typing &&
        !busy &&
        input.text.isEmpty &&
        output.isEmpty &&
        expressions != null &&
        expressions.isEmpty;
    // The expression is the page's answer, so it sits on a tinted panel.
    final resultColor = Color.alphaBlend(
      colors.primary.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.1 : 0.07,
      ),
      surfaceCard(context),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 360;
        final controlSize = compact ? 64.0 : 96.0;
        return Column(
          children: [
            Expanded(
              child: PageBody(
                children: [
                  _LanguageBar(
                    source: settings.source,
                    target: settings.target,
                    onSource: languagesLocked
                        ? null
                        : (value) => changeLanguage('source', value),
                    onTarget: languagesLocked
                        ? null
                        : (value) => changeLanguage('target', value),
                    onSwap:
                        languagesLocked || settings.source == settings.target
                        ? null
                        : swapLanguages,
                  ),
                  const SizedBox(height: 12),
                  Panel(
                    padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Row(
                            children: [
                              Expanded(
                                child: EyebrowLabel(tr(context, 'original')),
                              ),
                              if (input.text.isNotEmpty && inputEnabled)
                                // Part of the field, so clearing while typing
                                // keeps the keyboard up.
                                TextFieldTapRegion(
                                  child: IconButton(
                                    key: const ValueKey('speak-clear'),
                                    tooltip: tr(context, 'clear_input'),
                                    onPressed: clearInput,
                                    color: colors.onSurfaceVariant,
                                    icon: const Icon(
                                      Icons.cancel_rounded,
                                      size: 20,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: TextField(
                            key: const ValueKey('speak-input'),
                            controller: input,
                            focusNode: inputFocus,
                            minLines: 2,
                            maxLines: 6,
                            enabled: inputEnabled,
                            // Return translates; long phrases still wrap.
                            keyboardType: TextInputType.text,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => submitTyped(),
                            onTapOutside: (_) => inputFocus.unfocus(),
                            // A live transcript stays legible while the field
                            // is locked for capture.
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: colors.onSurface,
                              height: 1.45,
                            ),
                            decoration: InputDecoration(
                              // No typing hint while the microphone fills it.
                              hintText: inputEnabled
                                  ? tr(
                                      context,
                                      typing
                                          ? 'type_hint'
                                          : 'speak_or_type_hint',
                                    )
                                  : null,
                              hintMaxLines: 2,
                              hintStyle: theme.textTheme.titleMedium?.copyWith(
                                color: colors.onSurfaceVariant.withValues(
                                  alpha: 0.7,
                                ),
                                height: 1.45,
                              ),
                              filled: false,
                              isCollapsed: true,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.only(bottom: 12),
                            ),
                            onChanged: (_) => changed(),
                          ),
                        ),
                        // Once the expression is showing, Translate has done
                        // its job; editing or a new style brings it back.
                        if (input.text.isNotEmpty &&
                            !recording &&
                            !processing &&
                            !starting &&
                            (output.isEmpty || settings.usesTextModel))
                          Padding(
                            padding: const EdgeInsets.fromLTRB(0, 4, 12, 12),
                            child: LayoutBuilder(
                              builder: (context, row) {
                                final translateButton = FilledButton.tonalIcon(
                                  key: const ValueKey('translate-speech'),
                                  onPressed:
                                      busy ||
                                          changingLanguage ||
                                          input.text.trim().isEmpty
                                      ? null
                                      : translate,
                                  icon: const Icon(
                                    Icons.translate_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    tr(
                                      context,
                                      usesGoogleTranslation(settings)
                                          ? 'translate_google'
                                          : 'translate',
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                );
                                // Styles need a text model; without one the
                                // picker would only ever show Standard.
                                if (!settings.usesTextModel) {
                                  return Align(
                                    alignment: AlignmentDirectional.centerEnd,
                                    child: translateButton,
                                  );
                                }
                                final picker = TranslationStylePicker(
                                  value: style,
                                  settings: settings,
                                  onChanged: busy
                                      ? null
                                      : (value) {
                                          changed();
                                          setState(() => style = value);
                                        },
                                );
                                if (output.isNotEmpty) return picker;
                                return Row(
                                  children: [
                                    Expanded(child: picker),
                                    const SizedBox(width: 12),
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: row.maxWidth * 0.5,
                                      ),
                                      child: translateButton,
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (busy && output.isEmpty) ...[
                    const SizedBox(height: 12),
                    Panel(
                      color: resultColor,
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            liveRegion: true,
                            child: EyebrowLabel(
                              tr(context, 'translating_status'),
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const LinearProgressIndicator(),
                        ],
                      ),
                    ),
                  ],
                  if (output.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Panel(
                      color: resultColor,
                      padding: const EdgeInsets.fromLTRB(20, 4, 8, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Actions move under the label when they would
                          // otherwise squeeze it.
                          SizedBox(
                            width: double.infinity,
                            child: Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  child: EyebrowLabel(
                                    tr(context, 'translation'),
                                    color: colors.primary,
                                  ),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: tr(
                                        context,
                                        saved ? 'saved' : 'save',
                                      ),
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
                                                unawaited(
                                                  HapticFeedback.lightImpact(),
                                                );
                                              } finally {
                                                if (mounted) {
                                                  setState(
                                                    () => saving = false,
                                                  );
                                                }
                                              }
                                            }),
                                      // A saved expression stays clearly marked,
                                      // not greyed out like an unavailable action.
                                      color: colors.primary,
                                      disabledColor: saved
                                          ? colors.primary
                                          : null,
                                      icon: Icon(
                                        saved
                                            ? Icons.bookmark_added
                                            : Icons.bookmark_add_outlined,
                                      ),
                                    ),
                                    IconButton(
                                      key: const ValueKey('copy-expression'),
                                      tooltip: tr(context, 'copy'),
                                      // A rewrite in progress is incomplete.
                                      onPressed: busy ? null : copyOutput,
                                      icon: const Icon(
                                        Icons.copy_rounded,
                                        size: 20,
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: tr(context, 'more'),
                                      enabled: !busy,
                                      icon: const Icon(
                                        Icons.more_horiz_rounded,
                                      ),
                                      onSelected: process,
                                      itemBuilder: (_) => [
                                        for (final (key, icon) in [
                                          (
                                            'natural',
                                            Icons.auto_awesome_outlined,
                                          ),
                                          (
                                            'polite',
                                            Icons.favorite_border_rounded,
                                          ),
                                          ('shorter', Icons.short_text_rounded),
                                        ])
                                          _menuItem(key, icon),
                                        const PopupMenuDivider(),
                                        _menuItem(
                                          'explain',
                                          Icons.lightbulb_outline_rounded,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: SelectableText(
                              output,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                height: 1.35,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (googleTranslation) const TranslationAttribution(),
                          if (busy)
                            const Padding(
                              padding: EdgeInsets.fromLTRB(0, 16, 12, 0),
                              child: LinearProgressIndicator(),
                            ),
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.only(right: 12),
                            child: Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                SpeechButton(
                                  text: output,
                                  language: settings.target,
                                  enabled: !busy && !recording && !starting,
                                ),
                                FilledButton.icon(
                                  key: const ValueKey('practise-expression'),
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
                                  icon: const Icon(
                                    Icons.record_voice_over_rounded,
                                    size: 18,
                                  ),
                                  label: Text(tr(context, 'practice')),
                                ),
                              ],
                            ),
                          ),
                          if (explanation.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.fromLTRB(0, 16, 12, 16),
                              child: Divider(height: 1),
                            ),
                            EyebrowLabel(tr(context, 'explanation_title')),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: SelectableText(
                                explanation,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  height: 1.55,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (showIntro)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 40, 16, 0),
                      child: Column(
                        children: [
                          const SproutLogo(size: 52),
                          const SizedBox(height: 16),
                          Text(
                            tr(context, 'speak_intro_title'),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            trFill(context, 'speak_intro_body', {
                              'source':
                                  languages[settings.source] ?? settings.source,
                              'target':
                                  languages[settings.target] ?? settings.target,
                            }),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                              height: 1.55,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (typing)
              Padding(
                key: const ValueKey('speak-footer'),
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: Center(
                  child: TextButton.icon(
                    key: const ValueKey('speak-instead'),
                    onPressed: inputFocus.unfocus,
                    icon: const Icon(Icons.mic_none_rounded),
                    label: Text(tr(context, 'speak_instead')),
                  ),
                ),
              )
            else
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
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (recording) ...[
                                LevelDot(level: session.level),
                                const SizedBox(width: 10),
                              ],
                              Flexible(
                                child: Text(
                                  '${tr(context, processing
                                          ? 'processing'
                                          : recording
                                          ? 'listening'
                                          : 'preparing_audio')} ${recording ? durationText(session.seconds) : ''}'
                                      .trim(),
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w500,
                                    fontFeatures: tabularFigures,
                                  ),
                                ),
                              ),
                            ],
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
                                  shape: const StadiumBorder(),
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Visibility(
                          visible: idle,
                          maintainSize: true,
                          maintainState: true,
                          maintainAnimation: true,
                          child: IconButton(
                            key: const ValueKey('type-instead'),
                            tooltip: tr(context, 'type_instead'),
                            style: IconButton.styleFrom(
                              backgroundColor: colors.surfaceContainerHighest,
                              fixedSize: const Size.square(48),
                            ),
                            onPressed: idle && controlEnabled
                                ? startTyping
                                : null,
                            icon: const Icon(Icons.keyboard_alt_outlined),
                          ),
                        ),
                        SizedBox(width: compact ? 16 : 24),
                        Semantics(
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
                                  releaseRecordingPointer(
                                    event,
                                    cancelled: true,
                                  ),
                              child: AnimatedContainer(
                                key: microphoneTarget,
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 120),
                                width: controlSize,
                                height: controlSize,
                                decoration: BoxDecoration(
                                  color: recording
                                      ? colors.primaryContainer
                                      : controlEnabled
                                      ? colors.primary
                                      : colors.primary.withValues(alpha: 0.4),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    if (recording)
                                      BoxShadow(
                                        color: colors.primary.withValues(
                                          alpha: 0.25,
                                        ),
                                        spreadRadius: 6 + (session.level * 8),
                                        blurRadius: 0,
                                      )
                                    else if (controlEnabled)
                                      BoxShadow(
                                        color: colors.primary.withValues(
                                          alpha: 0.22,
                                        ),
                                        blurRadius: 24,
                                        spreadRadius: -2,
                                        offset: const Offset(0, 8),
                                      ),
                                  ],
                                ),
                                child: Icon(
                                  recording
                                      ? Icons.stop_rounded
                                      : Icons.mic_rounded,
                                  size: compact ? 30 : 38,
                                  color: recording
                                      ? colors.onPrimaryContainer
                                      : colors.onPrimary,
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: compact ? 16 : 24),
                        // Mirrors the keyboard button so the microphone stays
                        // centred.
                        const SizedBox(width: 48),
                      ],
                    ),
                    Visibility(
                      visible: idle,
                      maintainSize: true,
                      maintainState: true,
                      maintainAnimation: true,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: ExcludeSemantics(
                          child: Text(
                            tr(context, 'hold_to_speak'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
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

  PopupMenuItem<String> _menuItem(String key, IconData icon) => PopupMenuItem(
    value: key,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Flexible(child: Text(tr(context, key))),
      ],
    ),
  );
}

/// Spoken and target languages, with a swap between them.
class _LanguageBar extends StatelessWidget {
  final String source, target;
  final ValueChanged<String>? onSource, onTarget;
  final VoidCallback? onSwap;
  const _LanguageBar({
    required this.source,
    required this.target,
    required this.onSource,
    required this.onTarget,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final stacked = largeText(context);
    final from = _LanguageDropdown(
      key: const ValueKey('speak-source-language'),
      label: tr(context, 'source_language'),
      value: source,
      onChanged: onSource,
      centered: !stacked,
    );
    final to = _LanguageDropdown(
      key: const ValueKey('speak-target-language'),
      label: tr(context, 'target_language'),
      value: target,
      onChanged: onTarget,
      centered: !stacked,
    );
    // Large text gives each language its own line, like a vertical
    // translator, so names never break mid-word.
    if (stacked) {
      return Panel(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: Column(children: [from, const Divider(height: 1), to]),
            ),
            _SwapButton(onPressed: onSwap, vertical: true),
          ],
        ),
      );
    }
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(child: from),
          _SwapButton(onPressed: onSwap),
          Expanded(child: to),
        ],
      ),
    );
  }
}

class _SwapButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final bool vertical;
  const _SwapButton({required this.onPressed, this.vertical = false});
  @override
  State<_SwapButton> createState() => _SwapButtonState();
}

class _SwapButtonState extends State<_SwapButton> {
  double turns = 0;
  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('speak-swap-languages'),
    tooltip: tr(context, 'swap_languages'),
    onPressed: widget.onPressed == null
        ? null
        : () {
            setState(() => turns += 0.5);
            widget.onPressed!();
          },
    icon: AnimatedRotation(
      turns: turns,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      child: Icon(
        widget.vertical ? Icons.swap_vert_rounded : Icons.swap_horiz_rounded,
      ),
    ),
  );
}

class _LanguageDropdown extends StatelessWidget {
  final String label, value;
  final ValueChanged<String>? onChanged;
  final bool centered;
  const _LanguageDropdown({
    super.key,
    required this.label,
    required this.value,
    this.onChanged,
    this.centered = true,
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
          // Large text fits fewer languages per screen, so the menu grows.
          menuMaxHeight: largeText(context)
              ? MediaQuery.sizeOf(context).height * 0.7
              : 400,
          borderRadius: BorderRadius.circular(12),
          underline: const SizedBox.shrink(),
          // The arrow sits beside the centred name instead.
          icon: const SizedBox.shrink(),
          alignment: centered
              ? AlignmentDirectional.center
              : AlignmentDirectional.centerStart,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
          selectedItemBuilder: (_) => [
            for (final name in choices.values)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Align(
                  alignment: centered
                      ? Alignment.center
                      : AlignmentDirectional.centerStart,
                  child: Builder(
                    builder: (context) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: centered
                                ? TextAlign.center
                                : TextAlign.start,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.expand_more_rounded,
                          size: 18,
                          color: DefaultTextStyle.of(context).style.color,
                        ),
                      ],
                    ),
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
