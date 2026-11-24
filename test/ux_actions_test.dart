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
import 'package:phrayo/ui/library_page.dart';
import 'package:phrayo/ui/speak_page.dart';

import 'support/ready_speech_native.dart';

class _QuietNative extends ReadySpeechNative {
  @override
  Future<void> configure(
    String source,
    String target,
    bool localOnly,
    String sttProvider,
    List<String> transcriptionTerms,
  ) async {}
  @override
  Future<String> ttsStatus(String language) async => 'unsupported';
}

SessionMessage _result(String id) => SessionMessage(
  id: id,
  kind: 'shortcut',
  state: 'saved',
  seconds: 1,
  level: 0,
  path: '$id/recording.m4a',
  transcript: '你好',
  translation: 'Hello.',
  sourceLanguage: 'zh-CN',
  targetLanguage: 'en-US',
  segments: [],
);

void main() {
  late AppDatabase db;
  late NativeBridge native;

  Future<ProviderContainer> openSpeak(WidgetTester tester) async {
    db = AppDatabase(NativeDatabase.memory());
    native = NativeBridge(api: _QuietNative());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        nativeProvider.overrideWithValue(native),
      ],
    );
    // Open the database outside the fake clock, as the other harnesses do.
    await tester.runAsync(() async {
      await db.put('settings', 'settings', const AppSettings().toJson());
      await container.read(settingsProvider.notifier).load();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SpeakPage())),
      ),
    );
    await tester.pumpAndSettle();
    native.sessionChanged(_result('one'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> closeSpeak(WidgetTester tester, ProviderContainer c) async {
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    await native.dispose();
    // Lets the database finish closing its watched queries on the fake
    // clock before it is closed for real.
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  }

  testWidgets('swap turns the expression into the text to translate back', (
    tester,
  ) async {
    final container = await openSpeak(tester);
    expect(find.text('Hello.'), findsOneWidget);
    await tester.tap(find.byTooltip('Swap languages'));
    await tester.pumpAndSettle();
    final settings = container.read(settingsProvider);
    expect((settings.source, settings.target), ('en-US', 'zh-CN'));
    final saved = (await tester.runAsync(() => db.get('settings')))!;
    expect((saved['source'], saved['target']), ('en-US', 'zh-CN'));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('speak-input')))
          .controller!
          .text,
      'Hello.',
    );
    // The old expression is cleared until it is translated back.
    expect(find.byTooltip('Copy'), findsNothing);
    await closeSpeak(tester, container);
  });

  testWidgets('swap is unavailable while capturing', (tester) async {
    final container = await openSpeak(tester);
    native.sessionChanged(
      SessionMessage(
        id: 'two',
        kind: 'speaking',
        state: 'recording',
        seconds: 1,
        level: 0,
        transcript: '',
        translation: '',
        segments: [],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final swap = find.byKey(const ValueKey('speak-swap-languages'));
    expect(tester.widget<IconButton>(swap).onPressed, isNull);
    await closeSpeak(tester, container);
  });

  testWidgets('copy puts the expression on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final container = await openSpeak(tester);
    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    expect(copied, 'Hello.');
    expect(find.text('Copied'), findsOneWidget);
    await closeSpeak(tester, container);
  });

  testWidgets('clearing the text removes the draft and its result', (
    tester,
  ) async {
    final container = await openSpeak(tester);
    await tester.tap(find.byTooltip('Clear text'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('speak-input')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('Hello.'), findsNothing);
    await closeSpeak(tester, container);
  });

  testWidgets('rewrites without a text model offer its setup page', (
    tester,
  ) async {
    final container = await openSpeak(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More natural'));
    await tester.pumpAndSettle();
    expect(
      find.text('This needs a text model. Set one up in Settings.'),
      findsOneWidget,
    );
    expect(find.text('Hello.'), findsOneWidget);
    await tester.tap(find.text('Set up'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Text model'), findsOneWidget);
    await closeSpeak(tester, container);
  });

  testWidgets('deleting an expression can be undone with its history', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final bridge = NativeBridge(api: _QuietNative());
    final expression = Expression(
      id: 'saved',
      source: '谢谢',
      target: 'Thank you',
      due: DateTime(2100),
    );
    await tester.runAsync(() async {
      await db.put(expression.id, 'expression', expression.toJson());
      await db.put('practice:1', 'practice', {
        'id': 'practice:1',
        'expressionId': expression.id,
        'known': true,
        'answer': 'Thank you',
        'created': DateTime(2026).toIso8601String(),
      });
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bootstrapProvider.overrideWith((ref) async {}),
          databaseProvider.overrideWithValue(db),
          nativeProvider.overrideWithValue(bridge),
        ],
        child: const PhrayoApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expressions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Thank you'), findsNothing);
    expect(await tester.runAsync(() => db.get('practice:1')), isNull);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Thank you'), findsOneWidget);
    expect(await tester.runAsync(() => db.get('practice:1')), isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await bridge.dispose();
    await tester.runAsync(db.close);
  });

  testWidgets(
    'a review session shows progress and what each answer schedules',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final bridge = NativeBridge(api: _QuietNative());
      Expression phrase(String id, int interval) => Expression(
        id: id,
        source: '原意 $id',
        target: 'Meaning $id',
        interval: interval,
        due: DateTime(2000),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            nativeProvider.overrideWithValue(bridge),
          ],
          child: MaterialApp(
            home: PracticePage(
              expression: phrase('a', 1),
              queue: [phrase('b', 0)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 of 2'), findsOneWidget);
      expect(find.text('Say it in English (US)'), findsOneWidget);
      await tester.tap(find.text('Show expression'));
      await tester.pumpAndSettle();
      expect(find.text('Review tomorrow'), findsOneWidget);
      expect(find.text('Review in 3 days'), findsOneWidget);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.text('2 of 2'), findsOneWidget);
      await tester.tap(find.text('Show expression'));
      await tester.pumpAndSettle();
      // A new expression comes back tomorrow either way, so no hint is shown.
      expect(find.text('Review tomorrow'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await bridge.dispose();
      await tester.runAsync(db.close);
    },
  );
}
