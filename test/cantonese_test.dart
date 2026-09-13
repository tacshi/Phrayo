import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/ui/speak_page.dart';

import 'speak_retranslation_test.dart' show RetranslationModel;

import 'package:phrayo/core/languages.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/llm_provider.dart';
import 'package:phrayo/services/platform.dart';

import 'translation_test.dart' show TranslationNative, ModelTranslation;

class CantoneseSettings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(
    source: 'en-US',
    target: 'yue-HK',
    provider: LlmProvider.openAi,
    model: 'test',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Cantonese stays distinct in settings and recording language metadata',
    () {
      expect(languages['yue-HK'], '粵語（香港）');
      final settings = AppSettings.fromJson(
        const AppSettings(source: 'yue-HK', target: 'en-US').toJson(),
      );
      expect(settings.source, 'yue-HK');
      for (final code in ['yue-HK', 'yue_CN', 'zh-HK', 'zh-Hant-HK']) {
        expect(isCantonese(code), isTrue);
        expect(sonioxLanguageCode(code), 'zh');
      }
      for (final code in ['zh-CN', 'zh-TW', 'en-US']) {
        expect(isCantonese(code), isFalse);
      }
    },
  );
  test(
    'Cantonese Soniox hints preserve both dialect context and vocabulary',
    () {
      expect(sonioxContext('en-US', []), isEmpty);
      expect(sonioxContext('zh-CN', ['Phrayo']), {
        'terms': ['Phrayo'],
      });
      final context = sonioxContext('yue-HK', ['唔該']);
      expect(context['terms'], ['唔該']);
      expect(context['general'].toString(), contains('Cantonese'));
      expect(context['general'].toString(), contains('Traditional Chinese'));
    },
  );
  test(
    'text translation requests Cantonese grammar rather than Mandarin output',
    () async {
      final native = TranslationNative();
      final bridge = NativeBridge(api: native);
      final processor = ModelTranslation(bridge);
      addTearDown(bridge.dispose);
      addTearDown(processor.dio.close);
      final settings = AppSettings(
        source: 'en-US',
        target: 'yue-HK',
        provider: LlmProvider.values.first,
        model: 'test',
      );
      await processor.translate('I would like a table for two.', settings);
      expect(
        processor.task,
        contains('colloquial Cantonese vocabulary and grammar'),
      );
      expect(processor.task, contains('Traditional Chinese'));
      expect(native.requests, isEmpty);
    },
  );
  testWidgets(
    'a completed Cantonese session uses the text model once and preserves later edits',
    (tester) async {
      final bridge = NativeBridge(api: TranslationNative());
      final db = AppDatabase(NativeDatabase.memory());
      final processor = RetranslationModel(bridge);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            nativeProvider.overrideWithValue(bridge),
            settingsProvider.overrideWith(CantoneseSettings.new),
            textProcessorProvider.overrideWithValue(processor),
          ],
          child: const MaterialApp(home: Scaffold(body: SpeakPage())),
        ),
      );
      await tester.pumpAndSettle();
      final session = SessionMessage(
        id: 'cantonese-session',
        kind: 'shortcut',
        state: 'saved',
        seconds: 1,
        level: 0,
        transcript: 'A table for two, please.',
        translation: '',
        sourceLanguage: 'en-US',
        targetLanguage: 'yue-HK',
        segments: [],
      );
      bridge.sessionChanged(session);
      await tester.pumpAndSettle();
      expect(processor.requests, ['A table for two, please.']);
      expect(find.text('Model translation'), findsOneWidget);
      bridge.sessionChanged(session);
      await tester.pumpAndSettle();
      expect(processor.requests, hasLength(1));
      await tester.enterText(find.byType(TextField), 'A table for three.');
      bridge.sessionChanged(session);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'A table for three.',
      );
      expect(processor.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      processor.dio.close();
      await bridge.dispose();
      await tester.runAsync(db.close);
    },
  );
}
