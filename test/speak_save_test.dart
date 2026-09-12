import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/speak_page.dart';

void main() {
  testWidgets(
    'bookmark reflects saved expression and resets for new content or deletion',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final native = NativeBridge();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            nativeProvider.overrideWithValue(native),
          ],
          child: const MaterialApp(home: Scaffold(body: SpeakPage())),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> result(String id, String translation) async {
        native.sessionChanged(
          SessionMessage(
            id: id,
            kind: 'shortcut',
            state: 'saved',
            seconds: 1,
            level: 0,
            transcript: '你好',
            translation: translation,
            sourceLanguage: 'zh-CN',
            targetLanguage: 'en-US',
            segments: [],
          ),
        );
        await tester.pumpAndSettle();
      }

      await result('one', 'Hello.');
      final save = find.byIcon(Icons.bookmark_add_outlined);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.bookmark_added), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.bookmark_added),
            )
            .onPressed,
        isNull,
      );
      final rows = (await tester.runAsync(() => db.list('expression')))!;
      expect(rows, hasLength(1));

      await result('two', 'Hi there.');
      expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
      await result('three', 'Hello.');
      expect(find.byIcon(Icons.bookmark_added), findsOneWidget);

      await tester.runAsync(() => db.remove(rows.single['id']));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await native.dispose();
      await db.close();
    },
  );

  testWidgets('a new recording clears the previous result', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final native = NativeBridge();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          nativeProvider.overrideWithValue(native),
        ],
        child: const MaterialApp(home: Scaffold(body: SpeakPage())),
      ),
    );
    await tester.pumpAndSettle();

    SessionMessage session(
      String id,
      String kind,
      String state, {
      String transcript = '',
      String translation = '',
    }) => SessionMessage(
      id: id,
      kind: kind,
      state: state,
      seconds: 1,
      level: 0,
      transcript: transcript,
      translation: translation,
      sourceLanguage: 'zh-CN',
      targetLanguage: 'en-US',
      segments: [],
    );

    Future<void> emit(SessionMessage s) async {
      native.sessionChanged(s);
      await tester.pumpAndSettle();
    }

    await emit(
      session('one', 'shortcut', 'saved', transcript: '你好', translation: 'Hello.'),
    );
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('Hello.'), findsOneWidget);

    await emit(session('two', 'shortcut', 'recording'));
    expect(find.text('你好'), findsNothing);
    expect(find.text('Hello.'), findsNothing);

    await emit(
      session('two', 'shortcut', 'saved', transcript: '你好', translation: 'Hello.'),
    );
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('Hello.'), findsOneWidget);

    await emit(session('three', 'speaking', 'recording'));
    expect(find.text('你好'), findsNothing);
    expect(find.text('Hello.'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await native.dispose();
    await db.close();
  });
}
