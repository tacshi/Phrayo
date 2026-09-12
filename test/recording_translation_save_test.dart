import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/common.dart';
import 'package:phrayo/ui/recordings_page.dart';

import 'transcript_edit_test.dart' show sample, EditNative;

void main() {
  for (final layout in ['phone', 'tablet', 'Hans', 'Hant']) {
    testWidgets('translation controls stay in one padded row on $layout', (
      tester,
    ) async {
      final chinese = layout == 'Hans' || layout == 'Hant';
      tester.view.physicalSize = Size(
        layout == 'tablet'
            ? 1200
            : chinese
            ? 320
            : 390,
        900,
      );
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final locale = chinese
          ? Locale.fromSubtags(languageCode: 'zh', scriptCode: layout)
          : const Locale('en');
      final db = AppDatabase(NativeDatabase.memory());
      final native = NativeBridge(api: EditNative());
      await tester.runAsync(() => db.insertRecording(sample()));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            nativeProvider.overrideWithValue(native),
          ],
          child: MaterialApp(
            locale: locale,
            supportedLocales: [locale],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(chinese ? 2 : 1)),
              child: child!,
            ),
            home: const RecordingDetail(id: 'sample'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Tab).at(1));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('recording-translation-controls'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      final picker = tester.getRect(find.byType(TranslationStylePicker));
      final button = tester.getRect(
        find.byKey(const ValueKey('translate-recording')),
      );
      expect(picker.center.dy, closeTo(button.center.dy, 1));
      expect(button.left - picker.right, closeTo(12, 1));
      expect(picker.left, greaterThanOrEqualTo(24));
      expect(
        button.right,
        lessThanOrEqualTo(tester.view.physicalSize.width - 24),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await native.dispose();
      await tester.runAsync(db.close);
    });
  }

  testWidgets(
    'save translation retains source/audio, prevents duplicates and follows deletion and retranslation',
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
      await tester.tap(find.byType(Tab).at(1));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('save-recording-translation'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      var rows = (await tester.runAsync(() => db.list('expression')))!;
      expect(rows, hasLength(1));
      final phrase = Expression.fromJson(rows.single);
      expect(phrase.source, 'First passage\nSecond passage');
      expect(phrase.target, r.translation);
      expect(phrase.sourceLanguage, r.sourceLanguage);
      expect(phrase.targetLanguage, r.targetLanguage);
      expect(phrase.recordingId, r.id);
      expect(phrase.audioPath, r.path);
      expect(phrase.sourceIds, ['one', 'two']);
      expect((phrase.audioStart, phrase.audioEnd), (1.0, 6.0));
      expect(tester.widget<OutlinedButton>(save).onPressed, isNull);
      expect(find.byIcon(Icons.bookmark_added), findsOneWidget);
      await tester.runAsync(() => db.removeExpression(phrase.id));
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(save).onPressed, isNotNull);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final translate = find.byKey(const ValueKey('translate-recording'));
      await tester.ensureVisible(translate);
      await tester.pumpAndSettle();
      await tester.tap(translate);
      await tester.pumpAndSettle();
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(save).onPressed, isNotNull);
      await tester.tap(save);
      await tester.pumpAndSettle();
      rows = (await tester.runAsync(() => db.list('expression')))!;
      expect(rows, hasLength(2));
      expect(
        rows.map((row) => row['target']),
        containsAll(['Old translation', 'Updated translation']),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await native.dispose();
      await tester.runAsync(db.close);
    },
  );
}
