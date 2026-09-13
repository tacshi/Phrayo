import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/llm_provider.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/services/text_processor.dart';
import 'package:phrayo/ui/speak_page.dart';

import 'support/ready_speech_native.dart';

class RetranslationNative extends ReadySpeechNative {
  final requests = <String>[];
  Completer<String>? pending;
  @override
  Future<String> translate(String text, String source, String target) async {
    requests.add(text);
    expect(source, 'zh-CN');
    expect(target, 'en-US');
    return pending == null ? 'Corrected translation' : pending!.future;
  }
}

class RetranslationModel extends TextProcessor {
  final requests = <String>[];
  RetranslationModel(super.native);
  @override
  Stream<String> rewrite(
    String task,
    String text,
    AppSettings settings, {
    CancelToken? cancel,
  }) async* {
    requests.add(text);
    yield 'Model translation';
  }
}

void main() {
  for (final model in [false, true]) {
    testWidgets(
      'edited speech uses ${model ? 'text model' : 'Apple translation'} and retains its draft across tabs',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        final api = RetranslationNative();
        final bridge = NativeBridge(api: api);
        final processor = RetranslationModel(bridge);
        await tester.runAsync(
          () => db.put(
            'settings',
            'settings',
            AppSettings(
              provider: model ? LlmProvider.openAi : null,
              model: model ? 'model' : '',
            ).toJson(),
          ),
        );
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            nativeProvider.overrideWithValue(bridge),
            textProcessorProvider.overrideWithValue(processor),
          ],
        );
        await tester.runAsync(
          () => container.read(settingsProvider.notifier).load(),
        );
        final index = ValueNotifier(0);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: ValueListenableBuilder<int>(
                  valueListenable: index,
                  builder: (_, value, _) => IndexedStack(
                    index: value,
                    children: const [SpeakPage(), Text('Other tab')],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final session = SessionMessage(
          id: 'one',
          kind: 'shortcut',
          state: 'saved',
          seconds: 1,
          level: 0,
          transcript: '识别错误',
          translation: 'Old translation',
          sourceLanguage: 'zh-CN',
          targetLanguage: 'en-US',
          segments: [],
        );
        bridge.sessionChanged(session);
        await tester.pumpAndSettle();
        final input = find.byType(TextField);
        await tester.enterText(input, '修正后的文字');
        await tester.pumpAndSettle();
        expect(find.text('Old translation'), findsNothing);
        bridge.sessionChanged(session);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).controller!.text, '修正后的文字');
        index.value = 1;
        await tester.pumpAndSettle();
        index.value = 0;
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).controller!.text, '修正后的文字');
        final translate = find.byKey(const ValueKey('translate-speech'));
        await tester.ensureVisible(translate);
        await tester.tap(translate);
        await tester.pumpAndSettle();
        expect(
          find.text(model ? 'Model translation' : 'Corrected translation'),
          findsOneWidget,
        );
        expect(model ? processor.requests : api.requests, ['修正后的文字']);
        expect(model ? api.requests : processor.requests, isEmpty);
        await tester.ensureVisible(input);
        await tester.enterText(input, '   ');
        await tester.pumpAndSettle();
        expect(tester.widget<TextButton>(translate).onPressed, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        index.dispose();
        container.dispose();
        await tester.pumpAndSettle();
        await bridge.dispose();
        await tester.runAsync(db.close);
      },
    );
  }

  testWidgets(
    'editing pending translation discards late results and failures preserve corrected input',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = RetranslationNative()..pending = Completer<String>();
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
      final input = find.byType(TextField);
      final translate = find.byKey(const ValueKey('translate-speech'));
      await tester.enterText(input, 'First edit');
      await tester.pump();
      await tester.tap(translate);
      await tester.pump();
      expect(tester.widget<TextButton>(translate).onPressed, isNull);
      await tester.enterText(input, 'Second edit');
      await tester.pump();
      api.pending!.complete('Stale translation');
      await tester.pumpAndSettle();
      expect(find.text('Stale translation'), findsNothing);
      expect(tester.widget<TextField>(input).controller!.text, 'Second edit');
      api.pending = Completer<String>();
      await tester.tap(translate);
      await tester.pump();
      api.pending!.completeError(StateError('resources_missing'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, 'Second edit');
      expect(tester.widget<TextButton>(translate).onPressed, isNotNull);
      api.pending = null;
      await tester.tap(translate);
      await tester.pumpAndSettle();
      expect(find.text('Corrected translation'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await bridge.dispose();
      await db.close();
    },
  );
}
