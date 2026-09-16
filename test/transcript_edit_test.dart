import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/recordings_page.dart';
import 'package:phrayo/ui/transcript_editor.dart';

class EditNative extends PhrayoNative {
  final translations = <String>[];
  @override
  Future<String> translate(String text, String source, String target) async {
    translations.add(text);
    return 'Updated translation';
  }
}

Recording sample() => Recording(
  id: 'sample',
  title: 'Original title',
  path: 'sample/audio.m4a',
  seconds: 6,
  sourceLanguage: 'en-US',
  targetLanguage: 'zh-CN',
  translation: 'Old translation',
  translationStyle: TranslationStyle.polite,
  summary: [
    {
      'text': 'Old summary',
      'sourceIds': ['one'],
    },
  ],
  segments: [
    Segment(id: 'one', text: 'First passage', start: 1, end: 3, speaker: '1'),
    Segment(id: 'two', text: 'Second passage', start: 3, end: 6, speaker: '2'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('editing preserves timing and saved expressions, archives source and invalidates derivatives', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final r = sample();
    await db.insertRecording(r);
    final phrase = Expression(
      id: 'phrase',
      source: 'First passage',
      target: 'Saved expression',
      recordingId: r.id,
      sourceIds: ['one'],
    );
    await db.put(phrase.id, 'expression', phrase.toJson());
    await db.editRecordingTranscript(r, [
      ' Corrected passage ',
      'Second passage',
    ]);
    final updated = Recording.fromJson((await db.get(r.id))!);
    expect(updated.revision, 1);
    expect(updated.displayTitle, 'Corrected passage Second passage');
    expect(updated.translation, isEmpty);
    expect(updated.summary, isEmpty);
    expect(updated.translationStyle, TranslationStyle.polite);
    expect(updated.path, r.path);
    expect(updated.created, r.created);
    expect(
      updated.segments.map((s) => (s.id, s.start, s.end, s.speaker)),
      r.segments.map((s) => (s.id, s.start, s.end, s.speaker)),
    );
    expect(await db.get('source:${r.id}:0'), r.toJson());
    expect(await db.get(phrase.id), phrase.toJson());
    expect(
      await db.replaceIfCurrent(r.id, r.revision, {
        ...r.toJson(),
        'translation': 'Late result',
      }),
      isFalse,
    );
  });

  test('unchanged edits do not invalidate translation; blank, stale, deleted and pending-job edits are rejected', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final r = sample();
    await db.insertRecording(r);
    await db.editRecordingTranscript(r, ['First passage', 'Second passage']);
    expect(await db.get(r.id), r.toJson());
    expect(await db.get('source:${r.id}:0'), isNull);
    await expectLater(
      db.editRecordingTranscript(r, ['', 'Second passage']),
      throwsStateError,
    );
    await db.put('job:${r.id}', 'job', {
      'recordingId': r.id,
      'stage': 'processing',
    });
    await expectLater(
      db.editRecordingTranscript(r, ['Corrected', 'Second passage']),
      throwsStateError,
    );
    expect(await db.get(r.id), r.toJson());
    await db.remove('job:${r.id}');
    await db.editRecordingTranscript(r, ['Corrected', 'Second passage']);
    await expectLater(
      db.editRecordingTranscript(r, ['Stale', 'Second passage']),
      throwsStateError,
    );
    await db.deleteRecording(r.id);
    await expectLater(
      db.editRecordingTranscript(r, ['Deleted', 'Second passage']),
      throwsStateError,
    );
    expect(await db.get(r.id), isNull);
  });

  testWidgets(
    'recording menu edits transcript and translated tab uses corrected passages',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = EditNative();
      final native = NativeBridge(api: api);
      final r = sample();
      await tester.runAsync(() => db.insertRecording(r));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            nativeProvider.overrideWithValue(native),
          ],
          child: const MaterialApp(home: RecordingDetail(id: 'sample')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit transcript'));
      await tester.pumpAndSettle();
      expect(find.byType(TranscriptEditor), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('edit-passage-one')),
        'Corrected passage',
      );
      await tester.tap(find.byKey(const ValueKey('save-transcript')));
      await tester.pumpAndSettle();
      expect(find.byType(TranscriptEditor), findsNothing);
      expect(find.text('Corrected passage'), findsOneWidget);
      await tester.tap(find.widgetWithText(Tab, 'Translation'));
      await tester.pumpAndSettle();
      expect(find.text('Old translation'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('translate-recording')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('translate-recording')));
      await tester.pumpAndSettle();
      expect(api.translations, ['Corrected passage\nSecond passage']);
      expect(find.text('Updated translation'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await native.dispose();
      await tester.runAsync(db.close);
    },
  );

  testWidgets(
    'cancel discards draft; validation and revision conflicts retain typed text',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final r = sample();
      await tester.runAsync(() => db.insertRecording(r));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => TranscriptEditor(
                      recording: r,
                      onSave: (text) => db.editRecordingTranscript(r, text),
                    ),
                  ),
                ),
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('edit-passage-one'));
      final save = find.byKey(const ValueKey('save-transcript'));
      await tester.enterText(input, 'Discard this');
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => db.get(r.id)), r.toJson());
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, 'First passage');
      await tester.enterText(input, ' ');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Enter text for every passage.'), findsOneWidget);
      await tester.enterText(input, 'Keep this correction');
      await tester.runAsync(
        () => db.editRecordingTranscript(r, ['Another edit', 'Second passage']),
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This recording changed. Reopen the editor to load its latest transcript.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Keep this correction',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(db.close);
    },
  );

  for (final script in ['Hans', 'Hant']) {
    testWidgets(
      'Chinese $script transcript editor fits narrow screens at 200% text',
      (tester) async {
        tester.view.physicalSize = const Size(320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final locale = Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: script,
        );
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: [locale],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: TranscriptEditor(recording: sample(), onSave: (_) async {}),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(script == 'Hans' ? '编辑转写' : '編輯轉寫'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('edit-passage-one')),
          '我会擦干洗漱台。',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
