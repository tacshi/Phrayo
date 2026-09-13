// Explicit Profile fixture for Settings entry using isolated UI settings.
// No downloads/playback or requests for recordings/credentials. Restore lib/main.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/settings_page.dart';

class StatusSettings extends SettingsController {
  StatusSettings(this.language);
  final String language;
  @override
  AppSettings build() => AppSettings(target: language);
  @override
  Future<void> save(AppSettings value) async => state = value;
}

class StatusNative extends PhrayoNative {
  final completed = Completer<String>();
  int milliseconds = 0;
  @override
  Future<String> ttsStatus(String language) async {
    final watch = Stopwatch()..start();
    try {
      final status = await super.ttsStatus(language);
      milliseconds = watch.elapsedMilliseconds;
      completed.complete(status);
      return status;
    } catch (error, stack) {
      completed.completeError(error, stack);
      rethrow;
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final report = File('${Directory.systemTemp.path}/phrayo-voice-status.json');
  final events = <Map<String, Object?>>[];
  Future<void> record(Map<String, Object?> value) async {
    events.add(value);
    await report.writeAsString(jsonEncode(events), flush: true);
  }

  try {
    await record({'event': 'started'});
    for (final language in ['en-US', 'zh-CN', 'ja-JP', 'yue-HK', 'en-US']) {
      final api = StatusNative();
      final bridge = NativeBridge(api: api);
      final pageWatch = Stopwatch()..start();
      runApp(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            nativeProvider.overrideWithValue(bridge),
            settingsProvider.overrideWith(() => StatusSettings(language)),
          ],
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      final status = await api.completed.future.timeout(
        const Duration(seconds: 5),
      );
      await WidgetsBinding.instance.endOfFrame;
      await record({
        'event': 'settings_ready',
        'language': language,
        'status': status,
        'nativeMilliseconds': api.milliseconds,
        'pageMilliseconds': pageWatch.elapsedMilliseconds,
      });
      if (status != 'ready' || api.milliseconds > 1000) {
        throw StateError('Voice availability was not immediately ready.');
      }
      runApp(
        const MaterialApp(home: Scaffold(body: Text('Voice status verified'))),
      );
      await WidgetsBinding.instance.endOfFrame;
      await bridge.dispose();
    }
    await record({'event': 'passed'});
  } catch (error) {
    await record({'event': 'failed', 'error': error.toString()});
  }
}
