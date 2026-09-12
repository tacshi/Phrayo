import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/main.dart';
import 'package:phrayo/services/platform.dart';

class DetailNative extends PhrayoNative {
  final plays = <(String, double, double?)>[];
  @override
  Future<void> play(String path, double start, double? end) async {
    plays.add((path, start, end));
  }
}

void main() {
  final recording = Recording(
    id: 'sample',
    title: 'Could we move the meeting?',
    path: 'sample/recording.m4a',
    seconds: 6,
    created: DateTime(2026, 9, 9, 14, 30),
    segments: [
      Segment(
        id: 'one',
        text: 'Could we move the meeting?',
        start: 0,
        end: 3,
        speaker: '1',
      ),
      Segment(
        id: 'two',
        text: 'Half an hour later would work.',
        start: 3,
        end: 6,
        speaker: '2',
      ),
    ],
  );
  for (final layout in ['phone', 'tablet', 'large_text']) {
    final wide = layout == 'tablet';
    testWidgets(
      wide
          ? 'tablet detail preserves one app bar and split view'
          : '$layout detail has one navigation bar and progressive selection',
      (tester) async {
        tester.view.physicalSize = wide
            ? const Size(1200, 900)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        if (layout == 'large_text') {
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        }
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = DetailNative();
        final native = NativeBridge(api: api);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              bootstrapProvider.overrideWith((ref) async {}),
              recordingsProvider.overrideWith(
                (ref) => Stream.value([recording]),
              ),
              jobsProvider.overrideWith((ref) => Stream.value([])),
              nativeProvider.overrideWithValue(native),
            ],
            child: const PhrayoApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Recordings'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('recording-sample')));
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.text('Recording details'), findsOneWidget);
        expect(find.byType(Checkbox), findsNothing);
        expect(find.text('Make practice expressions'), findsNothing);
        expect(
          find.text(recording.title),
          findsOneWidget,
        );
        expect(find.byTooltip('Listen'), findsNothing);
        await tester.tap(find.byTooltip('Play recording'));
        await tester.pump();
        expect(api.plays.last, (recording.path, 0.0, null));
        await tester.ensureVisible(find.byKey(const ValueKey('passage-two')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('passage-two')));
        await tester.pump();
        expect(api.plays.last, (recording.path, 3.0, 6.0));
        await tester.tap(find.text('Select passages'));
        await tester.pumpAndSettle();
        expect(find.byType(Checkbox), findsWidgets);
        await tester.ensureVisible(find.byType(Checkbox).first);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Checkbox).first);
        await tester.pumpAndSettle();
        expect(find.text('1 selected'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Make practice expressions'),
              )
              .onPressed,
          isNotNull,
        );
        await tester.ensureVisible(find.widgetWithText(Tab, 'Key points'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, 'Key points'));
        await tester.pumpAndSettle();
        expect(find.byType(Checkbox), findsNothing);
        expect(
          find.byKey(const ValueKey('practice-selection-bar')),
          findsNothing,
        );
        expect(find.text('Extract key points'), findsOneWidget);
        expect(tester.takeException(), null);
        if (!wide) {
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.byType(NavigationBar), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await native.dispose();
      },
    );
  }
}
