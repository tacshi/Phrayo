import 'dart:convert';
import 'dart:io';

// Run explicitly with: flutter run -d <simulator-id> -t scripts/voice_smoke.dart
// Downloads real voice resources in that simulator and exercises the native
// bridge, inference, and audio-player start. Does not access recordings or keys.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/main.dart' as app;
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/settings_page.dart';

class SmokeSettings extends SettingsController {
  @override
  AppSettings build() => const AppSettings();
  @override
  Future<void> save(AppSettings value) async => state = value;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = NativeBridge();
  final records = <Map<String, Object?>>[];
  final report = File('${Directory.systemTemp.path}/phrayo-voice-smoke.json');
  Future<void> record(
    String state, [
    Map<String, Object?> details = const {},
  ]) async {
    records.add({
      'state': state,
      'time': DateTime.now().toUtc().toIso8601String(),
      ...details,
    });
    await report.writeAsString(jsonEncode({'events': records}), flush: true);
    try {
      stdout.writeln('VOICE_SMOKE: $state $details');
    } catch (_) {}
  }

  await record('started');
  runApp(
    ProviderScope(
      overrides: [
        nativeProvider.overrideWithValue(bridge),
        settingsProvider.overrideWith(SmokeSettings.new),
      ],
      child: MaterialApp(
        theme: app.appTheme(Brightness.light),
        home: const SettingsPage(),
      ),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  try {
    for (final language in ['en-US', 'zh-CN', 'ja-JP', 'yue-HK']) {
      await record('preparing', {'language': language});
      final preparation = Stopwatch()..start();
      await bridge.api.prepareTts([language]);
      preparation.stop();
      await record('prepared', {
        'language': language,
        'milliseconds': preparation.elapsedMilliseconds,
      });
      final status = await bridge.api.ttsStatus(language);
      if (status != 'ready') throw StateError('$language status=$status');
      final watch = Stopwatch()..start();
      await bridge.api.previewTts(language, true);
      watch.stop();
      await record('played', {
        'language': language,
        'milliseconds': watch.elapsedMilliseconds,
      });
      debugPrint(
        'VOICE_SMOKE: $language ready; native player started in ${watch.elapsedMilliseconds} ms',
      );
      await Future<void>.delayed(const Duration(seconds: 6));
      await bridge.api.stopPlayback();
    }
    const fixtureID = String.fromEnvironment('VOICE_TEST_AUDIO_ID');
    if (fixtureID.isNotEmpty) {
      final path = '$fixtureID/recording.m4a';
      try {
        await record('preparing_cantonese_recognition');
        await bridge.api.prepareLanguages('yue-HK', 'yue-HK', []);
        final segments = await bridge.api.transcribe(path, 'yue-HK', []);
        final transcript = segments.map((s) => s.text).join();
        if (transcript.trim().isEmpty) {
          throw StateError('Cantonese transcription was empty');
        }
        await record('cantonese_transcribed', {'transcript': transcript});
      } finally {
        await bridge.api.deleteAudio(path);
      }
    }
    final cantonese = await bridge.api.capabilities('yue-HK', 'en-US', []);
    debugPrint(
      'VOICE_SMOKE: Cantonese recognition=${cantonese.speechStatus}; Apple translation=${cantonese.translationStatus}',
    );
    await record('passed', {
      'cantoneseSpeech': cantonese.speechStatus,
      'appleTranslation': cantonese.translationStatus,
    });
    debugPrint('VOICE_SMOKE: PASS');
  } catch (error, stack) {
    await record('failed', {'error': error.toString()});
    debugPrint('VOICE_SMOKE: FAIL $error\n$stack');
  }
}
