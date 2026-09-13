// Explicit on-device fixture: flutter build ios --profile --no-pub
// -t scripts/speech_latency_smoke.dart. Restore lib/main.dart after the run.
// Uses the already installed local voice; never reads recordings or credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/speech_button.dart';

final events = <Map<String, Object?>>[];
Future<void> record(
  String event, [
  Map<String, Object?> details = const {},
]) async {
  events.add({'event': event, ...details});
  await File('${Directory.systemTemp.path}/phrayo-speech-latency.json')
      .writeAsString(jsonEncode(events), flush: true);
  debugPrint('SPEECH_LATENCY: $event $details');
}

class MeasuredSpeech extends PhrayoNative {
  final prepared = Completer<void>();
  @override
  Future<void> prepareSpeech(String text, String language) async {
    final watch = Stopwatch()..start();
    await record('preparation_started');
    try {
      await super.prepareSpeech(text, language);
      await record('prepared', {'milliseconds': watch.elapsedMilliseconds});
      prepared.complete();
    } catch (error, stack) {
      prepared.completeError(error, stack);
      rethrow;
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = MeasuredSpeech();
  final bridge = NativeBridge(api: api);
  final phrase = ValueNotifier('');
  runApp(
    ProviderScope(
      overrides: [nativeProvider.overrideWithValue(bridge)],
      child: MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ValueListenableBuilder<String>(
                valueListenable: phrase,
                builder: (_, text, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Cantonese playback timing'),
                    const SizedBox(height: 24),
                    Text(text),
                    if (text.isNotEmpty)
                      SpeechButton(text: text, language: 'yue-HK'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  try {
    await record('started');
    if (await api.ttsStatus('yue-HK') != 'ready') {
      throw StateError('Install the local Cantonese voice before this probe.');
    }
    final watch = Stopwatch()..start();
    await api.speak('今日晚飯食咩好呢？', 'yue-HK');
    await record('unprepared_player_started', {
      'milliseconds': watch.elapsedMilliseconds,
    });
    await Future<void>.delayed(const Duration(seconds: 4));
    await api.stopPlayback();
    phrase.value = '不如我哋聽晚再去食飯。';
    await api.prepared.future;
    watch.reset();
    await api.speak(phrase.value, 'yue-HK');
    await record('prepared_player_started', {
      'milliseconds': watch.elapsedMilliseconds,
    });
    await Future<void>.delayed(const Duration(seconds: 5));
    await api.stopPlayback();
    await record('passed');
  } catch (error) {
    await record('failed', {'error': error.toString()});
  }
}
