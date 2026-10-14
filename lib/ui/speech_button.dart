import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/native.g.dart';
import '../core/providers.dart';
import 'common.dart';
import 'strings.dart';

/// Prepares only the completed, visible translation. The native preparation
/// fills the same bounded local cache used by Listen, without playing audio.
/// Unless automatic generation is on, preparation waits for Generate audio.
class SpeechButton extends ConsumerStatefulWidget {
  final String text, language;
  final bool enabled;
  const SpeechButton({
    super.key,
    required this.text,
    required this.language,
    this.enabled = true,
  });

  @override
  ConsumerState<SpeechButton> createState() => _SpeechButtonState();
}

class _SpeechButtonState extends ConsumerState<SpeechButton> {
  late final PhrayoNative api;
  int generation = 0;
  bool preparing = false, failed = false, startingPlayback = false;

  /// Audio for the current text and language is ready in the cache.
  bool prepared = false;
  bool get automatic => ref.read(settingsProvider).autoGenerateVoice;

  @override
  void initState() {
    super.initState();
    api = ref.read(nativeProvider).api;
    ref.listenManual(settingsProvider.select((s) => s.autoGenerateVoice), (
      previous,
      next,
    ) {
      if (next && !prepared && !preparing) generate();
    });
    unawaited(prepare());
  }

  @override
  void didUpdateWidget(SpeechButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text ||
        widget.language != oldWidget.language ||
        widget.enabled != oldWidget.enabled) {
      unawaited(prepare());
    }
  }

  @override
  void dispose() {
    generation++;
    if (startingPlayback) {
      unawaited(api.stopPlayback().catchError((Object _) {}));
    }
    unawaited(api.cancelSpeechPreparation().catchError((Object _) {}));
    super.dispose();
  }

  /// Without [requested], audio is only prepared when generation is automatic.
  Future<void> prepare({bool requested = false}) async {
    final request = ++generation;
    if (startingPlayback) {
      startingPlayback = false;
      unawaited(api.stopPlayback().catchError((Object _) {}));
    }
    prepared = false;
    if (!widget.enabled ||
        widget.text.trim().isEmpty ||
        !(requested || automatic)) {
      preparing = false;
      failed = false;
      await api.cancelSpeechPreparation().catchError((Object _) {});
      return;
    }
    preparing = true;
    failed = false;
    try {
      await api.prepareSpeech(widget.text, widget.language);
      if (mounted && request == generation) prepared = true;
    } catch (_) {
      if (mounted && request == generation) failed = true;
    } finally {
      if (mounted && request == generation) {
        setState(() => preparing = false);
      }
    }
  }

  void generate() {
    if (!widget.enabled || widget.text.trim().isEmpty) return;
    setState(() {
      preparing = true;
      failed = false;
    });
    unawaited(prepare(requested: true));
  }

  Future<void> listen() async {
    final request = ++generation;
    setState(() {
      preparing = true;
      failed = false;
      startingPlayback = true;
    });
    try {
      await api.speak(widget.text, widget.language);
      // Speaking fills the same cache that preparation does.
      if (mounted && request == generation) prepared = true;
    } catch (error) {
      if (mounted && request == generation) {
        failed = true;
        notice(context, errorKey(error));
      }
    } finally {
      if (mounted && request == generation) {
        setState(() {
          preparing = false;
          startingPlayback = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (preparing) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            Flexible(
              child: Semantics(
                liveRegion: true,
                child: Tooltip(
                  message: tr(context, 'preparing_speech'),
                  child: Text(
                    tr(context, 'preparing_speech'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (failed) {
      return TextButton.icon(
        onPressed: widget.enabled ? listen : null,
        icon: const Icon(Icons.refresh_rounded),
        label: Text(tr(context, 'retry_speech')),
      );
    }
    final automatic = ref.watch(
      settingsProvider.select((s) => s.autoGenerateVoice),
    );
    if (!prepared && !automatic) {
      return TextButton.icon(
        key: const ValueKey('generate-speech'),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        onPressed: widget.enabled ? generate : null,
        icon: const Icon(Icons.graphic_eq_rounded),
        // Wraps like "Translate with Google" rather than truncating.
        label: Text(
          tr(context, 'generate_speech'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    return IconButton(
      tooltip: tr(context, 'listen'),
      onPressed: widget.enabled ? listen : null,
      icon: const Icon(Icons.volume_up_rounded),
    );
  }
}
