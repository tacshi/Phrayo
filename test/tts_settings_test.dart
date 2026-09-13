import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/settings_page.dart';

class VoiceSettings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(target: 'en-US');
  @override
  Future<void> save(AppSettings value) async => state = value;
}

class VoiceNative extends PhrayoNative {
  final checks = <String>[];
  final downloads = <List<String>>[];
  final previews = <(String, bool)>[];
  String status = 'download';
  Completer<void>? pendingDownload;
  bool cancelled = false;
  bool previewFails = false;
  bool downloadFails = false;
  Future<String> Function(String)? statusHandler;
  @override
  Future<String> ttsStatus(String language) async {
    checks.add(language);
    return statusHandler != null ? statusHandler!(language) : status;
  }

  @override
  Future<void> prepareTts(List<String> languages) async {
    downloads.add(languages);
    if (downloadFails) throw PlatformException(code: 'tts_install_failed');
    if (pendingDownload != null) await pendingDownload!.future;
    if (!cancelled) status = 'ready';
  }

  @override
  Future<void> cancelTts() async {
    cancelled = true;
    pendingDownload?.complete();
  }

  @override
  Future<void> previewTts(String language, bool neural) async {
    previews.add((language, neural));
    if (previewFails) {
      status = 'repair';
      throw PlatformException(code: 'tts_failure');
    }
  }
}

Future<NativeBridge> open(WidgetTester tester, VoiceNative api) async {
  final bridge = NativeBridge(api: api);
  addTearDown(bridge.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        nativeProvider.overrideWithValue(bridge),
        settingsProvider.overrideWith(VoiceSettings.new),
      ],
      child: const MaterialApp(home: SettingsPage()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('preview-voice')),
    150,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  return bridge;
}

Future<void> tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opening Settings does not show a voice synthesis check', (
    tester,
  ) async {
    final pending = Completer<String>();
    final api = VoiceNative()..statusHandler = (_) => pending.future;
    final bridge = NativeBridge(api: api);
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nativeProvider.overrideWithValue(bridge),
          settingsProvider.overrideWith(VoiceSettings.new),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pump();
    expect(find.text('Checking voice…'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(api.downloads, isEmpty);
    expect(api.previews, isEmpty);
    pending.complete('ready');
    await tester.pumpAndSettle();
    expect(find.text('CosyVoice 3 ready'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'voice is discoverable on entry without an Apple capability check',
    (tester) async {
      final api = VoiceNative();
      await open(tester, api);
      expect(api.checks, ['en-US']);
      expect(find.text('Listening voice'), findsOneWidget);
      expect(find.text('System voice'), findsOneWidget);
      expect(find.byKey(const ValueKey('download-voice')), findsOneWidget);
      await tap(tester, 'preview-voice');
      expect(api.previews, [('en-US', false)]);
    },
  );

  testWidgets('download enables a preview of the actual neural voice', (
    tester,
  ) async {
    final api = VoiceNative();
    await open(tester, api);
    await tap(tester, 'download-voice');
    expect(api.downloads, [
      ['en-US'],
    ]);
    expect(find.text('CosyVoice 3 ready'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-voice')), findsNothing);
    await tap(tester, 'preview-voice');
    expect(api.previews, [('en-US', true)]);
  });

  testWidgets('failed neural preview offers repair without a system fallback', (
    tester,
  ) async {
    final api = VoiceNative()
      ..status = 'ready'
      ..previewFails = true;
    await open(tester, api);
    await tap(tester, 'preview-voice');
    expect(api.previews, [('en-US', true)]);
    expect(
      find.text('Neural voice could not play. Download it again in Settings.'),
      findsOneWidget,
    );
    expect(find.text('Download again'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('preview-voice')))
          .onPressed,
      isNull,
    );
    api.previewFails = false;
    await tap(tester, 'download-voice');
    expect(find.text('CosyVoice 3 ready'), findsOneWidget);
  });

  testWidgets('failed download leaves a retry and clears progress', (
    tester,
  ) async {
    final api = VoiceNative()..downloadFails = true;
    await open(tester, api);
    await tap(tester, 'download-voice');
    expect(
      find.text('Voice preparation failed. Check your connection and retry.'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('download-voice')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('an unsupported neural language keeps system preview usable', (
    tester,
  ) async {
    final api = VoiceNative()..status = 'unsupported';
    await open(tester, api);
    expect(find.byKey(const ValueKey('download-voice')), findsNothing);
    await tap(tester, 'preview-voice');
    expect(api.previews.single.$2, isFalse);
  });

  testWidgets('late voice status cannot replace the current target language', (
    tester,
  ) async {
    final pending = Completer<String>();
    final api = VoiceNative()
      ..statusHandler = (language) =>
          language == 'en-US' ? pending.future : Future.value('unsupported');
    final bridge = NativeBridge(api: api);
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nativeProvider.overrideWithValue(bridge),
          settingsProvider.overrideWith(VoiceSettings.new),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('English (US)'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Deutsch').last);
    await tester.tap(find.text('Deutsch').last);
    await tester.pumpAndSettle();
    pending.complete('ready');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('preview-voice')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('System voice'), findsOneWidget);
    expect(find.text('CosyVoice 3 ready'), findsNothing);
    expect(api.checks, ['en-US', 'de-DE']);
  });
  testWidgets('an active voice download can be cancelled and retried', (
    tester,
  ) async {
    final api = VoiceNative()..pendingDownload = Completer<void>();
    await open(tester, api);
    final download = find.byKey(const ValueKey('download-voice'));
    await Scrollable.ensureVisible(tester.element(download), alignment: 0.5);
    await tester.tap(download);
    await tester.pump();
    final cancel = find.widgetWithText(TextButton, 'Cancel');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(api.cancelled, isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<TextButton>(download).onPressed, isNotNull);
  });
}
