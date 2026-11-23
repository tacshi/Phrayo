import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/speak_page.dart';

import 'support/ready_speech_native.dart';

class TypingNative extends ReadySpeechNative {
  final requests = <String>[];
  @override
  Future<String> translate(String text, String source, String target) async {
    requests.add(text);
    return 'Typed translation';
  }
}

void main() {
  late AppDatabase db;
  late TypingNative api;
  late NativeBridge native;

  Future<void> open(WidgetTester tester) async {
    db = AppDatabase(NativeDatabase.memory());
    api = TypingNative();
    native = NativeBridge(api: api);
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
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await native.dispose();
    await db.close();
  }

  final input = find.byKey(const ValueKey('speak-input'));
  final typeInstead = find.byKey(const ValueKey('type-instead'));
  final speakInstead = find.byKey(const ValueKey('speak-instead'));
  final microphone = find.byKey(const ValueKey('speak-control'));

  testWidgets('the keyboard button switches to typing and Done translates', (
    tester,
  ) async {
    await open(tester);
    expect(microphone, findsOneWidget);

    await tester.tap(typeInstead);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    expect(microphone, findsNothing);
    expect(speakInstead, findsOneWidget);
    expect(find.text('Type a word or sentence'), findsOneWidget);

    await tester.enterText(input, 'Where is the station?');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(api.requests, ['Where is the station?']);
    expect(find.text('Typed translation'), findsOneWidget);
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isFalse);
    expect(microphone, findsOneWidget);
    await close(tester);
  });

  testWidgets('Speak instead returns to the microphone', (tester) async {
    await open(tester);
    await tester.tap(typeInstead);
    await tester.pumpAndSettle();
    await tester.tap(speakInstead);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isFalse);
    expect(microphone, findsOneWidget);
    expect(typeInstead, findsOneWidget);
    await close(tester);
  });

  testWidgets('typed text after clearing a recording is saved without its '
      'audio, while a corrected transcript keeps it', (tester) async {
    await open(tester);
    Future<void> record(String id) async {
      native.sessionChanged(
        SessionMessage(
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
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<Map<String, dynamic>> typeAndSave(List<String> edits) async {
      for (final text in edits) {
        await tester.enterText(input, text);
        await tester.pump();
      }
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final save = find.byIcon(Icons.bookmark_add_outlined);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final rows = (await tester.runAsync(() => db.list('expression')))!;
      return rows.firstWhere((row) => row['source'] == edits.last);
    }

    await record('one');
    final corrected = await typeAndSave(['你好啊']);
    expect(corrected['recordingId'], 'one');
    expect(corrected['audioPath'], 'one/recording.m4a');

    await record('two');
    final typed = await typeAndSave(['', '谢谢']);
    expect(typed['recordingId'], isNull);
    expect(typed['audioPath'], isNull);
    await close(tester);
  });
}
