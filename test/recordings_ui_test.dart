import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:phrayo/main.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/platform.dart';

class RecordingNative extends PhrayoNative {
  final deleted = <String>[];
  bool failDeletion = false;
  @override
  Future<void> deleteAudio(String path) async {
    if (failDeletion) throw StateError('audio_delete_failed');
    deleted.add(path);
  }
}

void main() {
  testWidgets(
    'Chinese recording titles preserve recognition fragment spacing',
    (tester) async {
      final recording = Recording(
        id: 'fragments',
        title: '',
        path: '/fixture',
        seconds: 5,
        sourceLanguage: 'zh-CN',
        segments: [
          for (final (index, text) in [
            '现',
            '在',
            '这',
            '个',
            'A',
            'pp',
            '支持',
            '粤',
            '语',
            '了',
            '，',
            '你',
            '看',
            '效',
            '果',
            '怎',
            '么',
            '样',
            '。',
          ].indexed)
            Segment(
              id: '$index',
              text: text,
              start: index / 4,
              end: (index + 1) / 4,
            ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapProvider.overrideWith((ref) async {}),
            expressionsProvider.overrideWith((ref) => Stream.value([])),
            recordingsProvider.overrideWith((ref) => Stream.value([recording])),
          ],
          child: const PhrayoApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recordings'));
      await tester.pumpAndSettle();
      expect(find.text('现在这个App支持粤语了，你看效果怎么样。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'recording titles use current transcripts without duplicate dates',
    (tester) async {
      final rows = [
        Recording(
          id: 'transcribed',
          title: '',
          path: '/one',
          seconds: 7,
          segments: [Segment(id: 's', text: '今天早上摔倒了。', start: 0, end: 7)],
        ),
        Recording(
          id: 'updated',
          title: '旧转写',
          path: '/two',
          seconds: 3,
          segments: [Segment(id: 's', text: '最新转写', start: 0, end: 3)],
        ),
        Recording(
          id: 'empty',
          title: '',
          path: '/three',
          seconds: 1,
          created: DateTime(2026, 9, 9),
        ),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapProvider.overrideWith((ref) async {}),
            recordingsProvider.overrideWith((ref) => Stream.value(rows)),
          ],
          child: const PhrayoApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recordings'));
      await tester.pumpAndSettle();
      String title(String id) =>
          (tester.widget<ListTile>(find.byKey(ValueKey('recording-$id'))).title!
                  as Text)
              .data!;
      expect(title('transcribed'), '今天早上摔倒了。');
      expect(title('updated'), '最新转写');
      expect(title('empty'), 'Recording');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final failDeletion in [false, true]) {
    testWidgets(
      failDeletion
          ? 'failed audio cleanup keeps the recording available for retry'
          : 'recording list deletion can be cancelled, then removes audio and preserves saved text',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase(NativeDatabase.memory());
        final api = RecordingNative()..failDeletion = failDeletion;
        final native = NativeBridge(api: api);
        const id = 'recording-one';
        final recording = Recording(
          id: id,
          title: 'Meeting',
          path: '/recording.m4a',
          seconds: 42,
        );
        await tester.runAsync(() => db.insertRecording(recording));
        final expression = Expression(
          id: 'saved',
          source: '谢谢',
          target: 'Thank you',
          recordingId: id,
          audioPath: recording.path,
        );
        await tester.runAsync(
          () => db.put(expression.id, 'expression', expression.toJson()),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              bootstrapProvider.overrideWith((ref) async {}),
              databaseProvider.overrideWithValue(db),
              nativeProvider.overrideWithValue(native),
            ],
            child: const PhrayoApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Recordings'));
        await tester.pumpAndSettle();
        expect(find.text('Meeting'), findsOneWidget);
        await tester.tap(find.byTooltip('Delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Meeting'), findsOneWidget);
        expect(api.deleted, isEmpty);
        await tester.tap(find.byTooltip('Delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(
          find.text('Meeting'),
          failDeletion ? findsOneWidget : findsNothing,
        );
        expect(api.deleted, failDeletion ? isEmpty : [recording.path]);
        final saved = await tester.runAsync(() => db.get(expression.id));
        expect(saved!['target'], 'Thank you');
        expect(saved['audioPath'], failDeletion ? recording.path : null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await native.dispose();
        final closing = db.close();
        await tester.pumpAndSettle();
        await closing;
      },
    );
  }
}
