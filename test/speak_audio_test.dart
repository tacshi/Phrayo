import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/speak_page.dart';
import 'package:phrayo/ui/speech_button.dart';
import 'package:phrayo/main.dart' show appTheme;

class PreparingNative extends PhrayoNative {
  final prepared = <(String, String)>[];
  final spoken = <(String, String)>[];
  final pending = <Completer<void>>[];
  int cancellations = 0;
  int stops = 0;
  Completer<void>? pendingPlayback;

  @override
  Future<void> prepareSpeech(String text, String language) async {
    prepared.add((text, language));
    final completion = Completer<void>();
    pending.add(completion);
    await completion.future;
  }

  @override
  Future<void> cancelSpeechPreparation() async => cancellations++;

  @override
  Future<void> speak(String text, String language) async {
    spoken.add((text, language));
    await pendingPlayback?.future;
  }

  @override
  Future<void> stopPlayback() async => stops++;
}

void main() {
  testWidgets('preparation waits for final text and a failure offers retry', (
    tester,
  ) async {
    final api = PreparingNative();
    final bridge = NativeBridge(api: api);
    final enabled = ValueNotifier(false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nativeProvider.overrideWithValue(bridge)],
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: enabled,
              builder: (_, ready, _) => SpeechButton(
                text: 'Hello.',
                language: 'en-US',
                enabled: ready,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.prepared, isEmpty);
    enabled.value = true;
    await tester.pump();
    expect(api.prepared, [('Hello.', 'en-US')]);
    api.pending.single.completeError(StateError('tts_failure'));
    await tester.pumpAndSettle();
    expect(find.text('Retry audio'), findsOneWidget);
    api.pendingPlayback = Completer<void>();
    await tester.tap(find.text('Retry audio'));
    await tester.pump();
    expect(api.spoken, [('Hello.', 'en-US')]);
    expect(find.text('Preparing audio…'), findsOneWidget);
    enabled.value = false;
    await tester.pump();
    expect(
      api.stops,
      1,
      reason: 'Editing must cancel a pending playback retry',
    );
    api.pendingPlayback!.complete();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Listen'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    enabled.dispose();
    await bridge.dispose();
  });

  testWidgets('Chinese preparation status fits a small phone at 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = PreparingNative();
    final bridge = NativeBridge(api: api);
    if (const bool.fromEnvironment('DESIGN_PREVIEWS')) {
      await tester.runAsync(() async {
        for (final font in {
          '.SF Pro Text': '/System/Library/Fonts/SFNS.ttf',
          'Heiti': '/System/Library/Fonts/STHeiti Light.ttc',
          'MaterialIcons': '/Users/shibang/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          final loader = FontLoader(font.key);
          loader.addFont(
            Future.value(
              ByteData.sublistView(await File(font.value).readAsBytes()),
            ),
          );
          await loader.load();
        }
      });
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nativeProvider.overrideWithValue(bridge),
          expressionsProvider.overrideWith((ref) => Stream.value([])),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('zh')],
          theme: appTheme(Brightness.light).copyWith(
            textTheme: appTheme(Brightness.light).textTheme
                .apply(fontFamilyFallback: const ['Heiti']),
          ),
          builder: (_, child) => MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(body: SpeakPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    bridge.sessionChanged(
      SessionMessage(
        id: 'fixture',
        kind: 'shortcut',
        state: 'saved',
        seconds: 1,
        level: 0,
        transcript: '今天晚饭吃什么呢？',
        translation: '今日晚飯食咩好呢？',
        sourceLanguage: 'zh-CN',
        targetLanguage: 'en-US',
        segments: [],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在准备语音…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('正在准备语音…'));
    await tester.pump();
    if (const bool.fromEnvironment('DESIGN_PREVIEWS')) {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('/tmp/phrayo-preparing-speech.png'),
      );
    }
    api.pending.single.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await bridge.dispose();
  });

  testWidgets(
    'translation prepares its audio visibly before Listen is tapped',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = PreparingNative();
      final bridge = NativeBridge(api: api);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            nativeProvider.overrideWithValue(bridge),
          ],
          child: const MaterialApp(home: Scaffold(body: SpeakPage())),
        ),
      );
      await tester.pumpAndSettle();
      void result(String id, String text) => bridge.sessionChanged(
        SessionMessage(
          id: id,
          kind: 'shortcut',
          state: 'saved',
          seconds: 1,
          level: 0,
          transcript: '你好',
          translation: text,
          sourceLanguage: 'zh-CN',
          targetLanguage: 'en-US',
          segments: [],
        ),
      );
      result('one', 'Hello.');
      await tester.pump();
      await tester.pump();
      expect(api.prepared, [('Hello.', 'en-US')]);
      expect(api.spoken, isEmpty);
      expect(find.text('Preparing audio…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(
        api.prepared,
        hasLength(1),
        reason: 'Rebuilds must not restart synthesis',
      );
      result('two', 'Hi there.');
      await tester.pump();
      await tester.pump();
      expect(api.prepared.last, ('Hi there.', 'en-US'));
      api.pending.first.complete();
      await tester.pump();
      expect(
        find.text('Preparing audio…'),
        findsOneWidget,
        reason: 'The old phrase must not clear the new preparation state',
      );
      api.pending.last.complete();
      await tester.pumpAndSettle();
      expect(find.text('Preparing audio…'), findsNothing);
      await tester.ensureVisible(find.byTooltip('Listen'));
      await tester.tap(find.byTooltip('Listen'));
      await tester.pumpAndSettle();
      expect(api.spoken, [('Hi there.', 'en-US')]);
      expect(api.prepared, hasLength(2));
      result('three', 'Thanks.');
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byType(TextField), '修改');
      await tester.pump();
      expect(find.text('Preparing audio…'), findsNothing);
      expect(api.cancellations, greaterThan(0));
      api.pending.last.complete();
      await tester.pumpAndSettle();
      expect(
        api.spoken,
        hasLength(1),
        reason: 'Preparation must never play automatically',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await bridge.dispose();
      await tester.runAsync(db.close);
    },
  );
}
