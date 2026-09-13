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
import 'package:phrayo/services/transcription.dart';
import 'package:phrayo/ui/recordings_page.dart';

import 'support/ready_speech_native.dart';

class TranslationNative extends ReadySpeechNative {
  final requests = <(String, String, String)>[];
  Completer<String>? pending;
  List<SessionMessage> recovered = [];
  @override
  Future<List<SessionMessage>> recover() async => recovered;
  @override
  Future<SessionMessage?> snapshot() async => null;
  @override
  Future<void> acknowledge(String id) async {}
  @override
  Future<List<SegmentMessage>> transcribe(
    String path,
    String source,
    List<String> transcriptionTerms,
  ) async => [
    SegmentMessage(id: 'new', text: 'New transcript', start: 0, end: 1),
  ];
  @override
  Future<String> translate(String text, String source, String target) async {
    requests.add((text, source, target));
    return pending == null ? 'Translated text' : await pending!.future;
  }
}

class ModelTranslation extends TextProcessor {
  ModelTranslation(super.native);
  String? task;
  @override
  Stream<String> rewrite(
    String task,
    String text,
    AppSettings settings, {
    CancelToken? cancel,
  }) async* {
    this.task = task;
    yield 'Model translation';
  }
}

void main() {
  test('session import preserves its existing translation', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = TranslationNative()
      ..recovered = [
        SessionMessage(
          id: 'imported',
          kind: 'speaking',
          state: 'saved',
          seconds: 1,
          level: 0,
          transcript: 'Hello',
          translation: '你好',
          path: 'imported/audio.m4a',
          segments: [],
        ),
      ];
    final bridge = NativeBridge(api: api);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        nativeProvider.overrideWithValue(bridge),
      ],
    );
    await container.read(bootstrapProvider.future);
    expect((await db.get('imported'))!['translation'], '你好');
    container.dispose();
    await bridge.dispose();
    await db.close();
  });

  test(
    'retranscribing invalidates the previous translation and style',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final bridge = NativeBridge(api: TranslationNative());
      final recording = Recording(
        id: 'r',
        title: '',
        path: 'r/audio.m4a',
        seconds: 1,
        translation: 'Old translation',
        translationStyle: TranslationStyle.polite,
      );
      await db.insertRecording(recording);
      await TranscriptionService(
        db,
        bridge,
      ).run(recording, const AppSettings(localOnly: true));
      final updated = Recording.fromJson((await db.get('r'))!);
      expect(updated.segments.single.text, 'New transcript');
      expect(updated.translation, isEmpty);
      expect(updated.translationStyle, TranslationStyle.standard);
      await bridge.dispose();
      await db.close();
    },
  );

  test(
    'configured model translates with the requested style and languages',
    () async {
      final native = TranslationNative();
      final bridge = NativeBridge(api: native);
      final processor = ModelTranslation(bridge);
      addTearDown(bridge.dispose);
      addTearDown(processor.dio.close);
      final result = await processor.translate(
        '你好',
        AppSettings(
          provider: LlmProvider.values.first,
          model: 'chat',
          source: 'zh-CN',
          target: 'en-US',
        ),
        style: TranslationStyle.professional,
      );
      expect(result, 'Model translation');
      expect(processor.task, contains('zh-CN to en-US'));
      expect(processor.task, contains('professional'));
      expect(native.requests, isEmpty);
    },
  );

  test(
    'local-only mode uses the system and rejects unsupported styles',
    () async {
      final native = TranslationNative();
      final bridge = NativeBridge(api: native);
      final processor = ModelTranslation(bridge);
      addTearDown(bridge.dispose);
      addTearDown(processor.dio.close);
      final settings = AppSettings(
        localOnly: true,
        provider: LlmProvider.values.first,
        model: 'chat',
      );
      expect(await processor.translate('你好', settings), 'Translated text');
      expect(processor.task, isNull);
      await expectLater(
        processor.translate('你好', settings, style: TranslationStyle.polite),
        throwsStateError,
      );
      expect(native.requests, hasLength(1));
    },
  );

  test('cancelling system translation rejects its eventual result', () async {
    final native = TranslationNative()..pending = Completer<String>();
    final bridge = NativeBridge(api: native);
    final processor = TextProcessor(bridge);
    addTearDown(bridge.dispose);
    addTearDown(processor.dio.close);
    final token = CancelToken();
    final result = processor.translate(
      '你好',
      const AppSettings(),
      cancel: token,
    );
    final expectation = expectLater(result, throwsA(isA<DioException>()));
    token.cancel();
    native.pending!.complete('Late translation');
    await expectation;
  });

  for (final deleted in [false, true]) {
    testWidgets(
      deleted
          ? 'deleting a recording rejects a late translation'
          : 'recording translation saves and survives reopening',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        final native = TranslationNative()..pending = Completer<String>();
        final bridge = NativeBridge(api: native);
        final recording = Recording(
          id: 'r',
          title: 'Original',
          path: 'r/audio.m4a',
          seconds: 2,
          sourceLanguage: 'en-US',
          targetLanguage: 'zh-CN',
          segments: [Segment(id: 's', text: 'Original', start: 0, end: 2)],
        );
        await db.insertRecording(recording);
        addTearDown(db.close);
        addTearDown(bridge.dispose);
        Widget app() => ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            nativeProvider.overrideWithValue(bridge),
          ],
          child: const MaterialApp(home: RecordingDetail(id: 'r')),
        );
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, 'Translation'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('translate-recording')));
        await tester.pump();
        expect(native.requests.single, ('Original', 'en-US', 'zh-CN'));
        if (deleted) await db.deleteRecording('r');
        native.pending!.complete('已翻译');
        await tester.pumpAndSettle();
        if (deleted) {
          expect(await db.get('r'), isNull);
        } else {
          expect((await db.get('r'))!['translation'], '已翻译');
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.pumpWidget(app());
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(Tab, 'Translation'));
          await tester.pumpAndSettle();
          expect(find.text('已翻译'), findsOneWidget);
          expect(find.text('Translate again'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  test('legacy recordings load without translation metadata', () {
    final json = Recording(id: 'r', title: '', path: '', seconds: 0).toJson()
      ..remove('translation')
      ..remove('translationStyle');
    final recording = Recording.fromJson(json);
    expect(recording.translation, isEmpty);
    expect(recording.translationStyle, TranslationStyle.standard);
  });
}
