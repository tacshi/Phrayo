import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/recordings_page.dart';

class BatchNative extends PhrayoNative {
  final shared = <List<String>>[];
  final deleted = <String>[];
  String? failure;
  Completer<void>? sharing;
  @override
  Future<void> shareRecordings(List<String> paths) async {
    shared.add(paths);
    await sharing?.future;
    if (failure == 'export') throw StateError('no_audio');
  }

  @override
  Future<void> deleteAudio(String path) async {
    if (failure == path) throw StateError('audio_delete_failed');
    deleted.add(path);
  }
}

void main() {
  testWidgets('selection toolbar does not reuse the pressed entry button', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingsProvider.overrideWith(
            (ref) => Stream.value([
              Recording(id: 'one', title: 'One', path: 'one', seconds: 1),
            ]),
          ),
        ],
        child: const MaterialApp(home: RecordingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    Finder ink(String label) => find.descendant(
      of: find.widgetWithText(TextButton, label),
      matching: find.byType(InkWell),
    );
    final previousInk = tester.element(ink('Select'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Select')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    final pressedInk = tester.widget<InkWell>(ink('Select'));
    expect(
      pressedInk.overlayColor!.resolve({WidgetState.pressed})!.a,
      greaterThan(0),
    );
    await gesture.up();
    await tester.pump();
    expect(tester.element(ink('Select all')), isNot(same(previousInk)));
    expect(find.text('0 selected'), findsOneWidget);
    final selectAll = tester.widget<InkWell>(ink('Select all'));
    expect(
      selectAll.statesController!.value.contains(WidgetState.pressed),
      isFalse,
    );
    expect(
      selectAll.statesController!.value.contains(WidgetState.focused),
      isFalse,
    );
    expect(
      selectAll.overlayColor!.resolve({WidgetState.pressed})!.a,
      greaterThan(0),
    );
    await tester.pumpAndSettle();
  });

  testWidgets(
    'active recordings excluded and selection follows collection changes',
    (tester) async {
      final api = BatchNative();
      final bridge = NativeBridge(api: api);
      final changes = StreamController<List<Recording>>.broadcast();
      Recording row(String id) =>
          Recording(id: id, title: id, path: id, seconds: 1);
      bridge.current = SessionMessage(
        id: 'active',
        kind: 'recording',
        state: 'paused',
        seconds: 1,
        level: 0,
        transcript: '',
        translation: '',
        segments: [],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recordingsProvider.overrideWith((ref) => changes.stream),
            nativeProvider.overrideWithValue(bridge),
          ],
          child: const MaterialApp(home: Scaffold(body: RecordingsPage())),
        ),
      );
      changes.add([row('active'), row('one'), row('two')]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      final activeCheckbox = find.descendant(
        of: find.byKey(const ValueKey('recording-active')),
        matching: find.byType(Checkbox),
      );
      expect(tester.widget<Checkbox>(activeCheckbox).onChanged, isNull);
      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      changes.add([row('active'), row('two'), row('new')]);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      expect(api.shared.single, ['two']);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => changes.close());
      await bridge.dispose();
    },
  );
  for (final width in [390.0, 1200.0]) {
    testWidgets('batch selection, export and partial deletion at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      final api = BatchNative();
      final bridge = NativeBridge(api: api);
      for (final id in ['one', 'two']) {
        await tester.runAsync(
          () => db.insertRecording(
            Recording(id: id, title: id, path: id, seconds: 1),
          ),
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            nativeProvider.overrideWithValue(bridge),
          ],
          child: const MaterialApp(home: Scaffold(body: RecordingsPage())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Export'))
            .onPressed,
        isNull,
      );
      expect(find.text('New recording'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('recording-one')));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.text('Deselect all'));
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      api.sharing = Completer<void>();
      await tester.tap(find.text('Export'));
      await tester.pump();
      await tester.tap(find.text('Export'));
      expect(api.shared, hasLength(1));
      expect(api.shared.single, unorderedEquals(['one', 'two']));
      api.sharing!.complete();
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      api.failure = 'export';
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      api.failure = 'two';
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.deleted, isEmpty);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Delete'),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.deleted, ['one']);
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byKey(const ValueKey('recording-two')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      api.failure = null;
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Delete'),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.deleted, ['one', 'two']);
      expect(find.text('Select'), findsNothing);
      expect(find.text('New recording'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await bridge.dispose();
      final closing = db.close();
      await tester.pumpAndSettle();
      await closing;
    });
  }
}
