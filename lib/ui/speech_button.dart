import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/native.g.dart';
import '../core/providers.dart';
import 'common.dart';
import 'strings.dart';

/// Prepares only the completed, visible translation. The native preparation
/// fills the same bounded local cache used by Listen, without playing audio.
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

  @override
  void initState() {
    super.initState();
    api = ref.read(nativeProvider).api;
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

  Future<void> prepare() async {
    final request = ++generation;
    if (startingPlayback) {
      startingPlayback = false;
      unawaited(api.stopPlayback().catchError((Object _) {}));
    }
    if (!widget.enabled || widget.text.trim().isEmpty) {
      preparing = false;
      failed = false;
      await api.cancelSpeechPreparation().catchError((Object _) {});
      return;
    }
    preparing = true;
    failed = false;
    try {
      await api.prepareSpeech(widget.text, widget.language);
    } catch (_) {
      if (mounted && request == generation) failed = true;
    } finally {
      if (mounted && request == generation) {
        setState(() => preparing = false);
      }
    }
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            Semantics(
              liveRegion: true,
              child: Text(tr(context, 'preparing_speech')),
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
    return IconButton(
      tooltip: tr(context, 'listen'),
      onPressed: widget.enabled ? listen : null,
      icon: const Icon(Icons.volume_up_rounded),
    );
  }
}
