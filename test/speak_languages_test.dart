import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/main.dart';
import 'package:phrayo/services/platform.dart';

import 'support/ready_speech_native.dart';

class LanguageNative extends ReadySpeechNative {
  final configurations = <(String, String)>[];
  final translations = <(String, String, String)>[];
  final voiceChecks = <String>[];
  bool failSave = false;
  Completer<String>? pendingTranslation;
  @override
  Future<void> configure(
    String source,
    String target,
    bool localOnly,
    String sttProvider,
    List<String> transcriptionTerms,
  ) async {
    if (failSave) throw StateError('error');
    configurations.add((source, target));
  }

  @override
  Future<String> ttsStatus(String language) async {
    voiceChecks.add(language);
    return 'unsupported';
  }

  @override
  Future<String> translate(String text, String source, String target) async {
    translations.add((text, source, target));
    return pendingTranslation == null
        ? 'New translation'
        : pendingTranslation!.future;
  }
}

class Harness {
  final api = LanguageNative();
  final db = AppDatabase(NativeDatabase.memory());
  late final native = NativeBridge(api: api);
  late final container = ProviderContainer(
    overrides: [
      bootstrapProvider.overrideWith((ref) async {}),
      nativeProvider.overrideWithValue(native),
      databaseProvider.overrideWithValue(db),
      expressionsProvider.overrideWith((ref) => Stream.value([])),
      recordingsProvider.overrideWith((ref) => Stream.value([])),
    ],
  );

  Future<void> open(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(),
  }) async {
    await tester.runAsync(() async {
      await db.put('settings', 'settings', settings.toJson());
      await container.read(settingsProvider.notifier).load();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const PhrayoApp()),
    );
    await tester.pumpAndSettle();
  }

  void session(String state) => native.sessionChanged(
    SessionMessage(
      id: 'session',
      kind: 'shortcut',
      state: state,
      seconds: 1,
      level: 0,
      transcript: 'Keep this input',
      translation: state == 'saved' ? 'Old translation' : '',
      sourceLanguage: 'zh-CN',
      targetLanguage: 'en-US',
      segments: [],
    ),
  );

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    container.dispose();
    await native.dispose();
    await tester.runAsync(db.close);
  }
}

Finder dropdown(String side) => find.descendant(
  of: find.byKey(ValueKey('speak-$side-language')),
  matching: find.byType(DropdownButton<String>),
);

Future<void> choose(WidgetTester tester, String side, String language) async {
  await tester.ensureVisible(dropdown(side));
  await tester.tap(dropdown(side));
  await tester.pumpAndSettle();
  await tester.tap(find.text(language).last);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('DESIGN_PREVIEWS')) {
      for (final font in {
        '.SF Pro Text': '/System/Library/Fonts/STHeiti Light.ttc',
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
    }
  });

  testWidgets(
    'both language dropdowns persist and update an already opened Settings page',
    (tester) async {
      final h = Harness();
      await h.open(
        tester,
        settings: const AppSettings(transcriptionTerms: ['Phrayo']),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speak'));
      await tester.pumpAndSettle();
      h.session('saved');
      await tester.pumpAndSettle();
      await choose(tester, 'target', '日本語');
      expect(find.text('Keep this input'), findsOneWidget);
      expect(find.text('Old translation'), findsNothing);
      expect(
        h.api.translations,
        isEmpty,
        reason: 'Language selection must not auto-translate',
      );
      await choose(tester, 'source', 'English (UK)');
      expect(h.api.configurations, [('zh-CN', 'ja-JP'), ('en-GB', 'ja-JP')]);
      final saved = (await tester.runAsync(() => h.db.get('settings')))!;
      expect(saved['source'], 'en-GB');
      expect(saved['target'], 'ja-JP');
      expect(saved['transcriptionTerms'], ['Phrayo']);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      // The Speak tab is offstage here, so these are the Settings rows.
      expect(find.text('English (UK)'), findsOneWidget);
      expect(find.text('日本語'), findsOneWidget);
      expect(h.api.voiceChecks.last, 'ja-JP');
      await tester.tap(find.text('Speak'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('translate-speech')),
      );
      await tester.tap(find.byKey(const ValueKey('translate-speech')));
      await tester.pumpAndSettle();
      expect(h.api.translations, [('Keep this input', 'en-GB', 'ja-JP')]);
      expect(find.text('New translation'), findsOneWidget);
      await h.close(tester);
    },
  );

  testWidgets(
    'language selection discards a pending old translation and failed saves retain the selection',
    (tester) async {
      final h = Harness();
      await h.open(tester);
      await tester.enterText(find.byType(TextField), 'Draft');
      await tester.pumpAndSettle();
      h.api.pendingTranslation = Completer<String>();
      await tester.tap(find.byKey(const ValueKey('translate-speech')));
      await tester.pump();
      // Open the menu without settling the pending translation's progress bar.
      await tester.tap(dropdown('target'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('日本語').last);
      await tester.pumpAndSettle();
      h.api.pendingTranslation!.complete('Stale translation');
      await tester.pumpAndSettle();
      expect(find.text('Stale translation'), findsNothing);
      expect(find.text('Draft'), findsOneWidget);
      h.api.failSave = true;
      await choose(tester, 'source', 'English (UK)');
      expect(
        tester.widget<DropdownButton<String>>(dropdown('source')).value,
        'zh-CN',
      );
      expect(h.container.read(settingsProvider).source, 'zh-CN');
      expect(
        (await tester.runAsync(() => h.db.get('settings')))!['source'],
        'zh-CN',
      );
      await h.close(tester);
    },
  );

  testWidgets(
    'language dropdowns fit large Chinese text and lock during capture',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = Harness();
      await h.open(
        tester,
        settings: const AppSettings(locale: 'zh-Hans', target: 'yue-HK'),
      );
      if (const bool.fromEnvironment('DESIGN_PREVIEWS')) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('/tmp/phrayo-language-dropdowns.png'),
        );
      }
      await tester.tap(dropdown('target'));
      await tester.pumpAndSettle();
      expect(find.text('日本語').last, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('日本語').last);
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('DESIGN_PREVIEWS')) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('/tmp/phrayo-language-menu.png'),
        );
      }
      await tester.tap(find.text('日本語').last);
      await tester.pumpAndSettle();
      expect(h.container.read(settingsProvider).target, 'ja-JP');
      for (final state in ['recording', 'paused', 'processing']) {
        h.session(state);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        for (final side in ['source', 'target']) {
          expect(
            tester.widget<DropdownButton<String>>(dropdown(side)).onChanged,
            isNull,
          );
        }
        expect(tester.takeException(), isNull);
      }
      await h.close(tester);
    },
  );
}
