import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/main.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/services/platform.dart';

class DesignNative extends PhrayoNative {
  @override
  Future<SessionMessage> start(
    String kind,
    String source,
    String target,
    bool localOnly,
    String sttProvider,
    List<String> transcriptionTerms,
  ) async => SessionMessage(
    id: 'attempt',
    kind: kind,
    state: 'recording',
    seconds: 0,
    level: 0,
    transcript: '',
    translation: '',
    segments: [],
  );
  @override
  Future<SessionMessage> stop() async => SessionMessage(
    id: 'attempt',
    kind: 'practice',
    state: 'saved',
    seconds: 3,
    level: 0,
    transcript: 'Could we move the meeting?',
    translation: '',
    path: 'attempt/recording.m4a',
    segments: [],
  );
}

void main() {
  final expression = Expression(
    id: 'one',
    source: '能把会议改到下午吗？',
    target: 'Could we move the meeting?',
    due: DateTime(2100),
  );
  testWidgets(
    'library distinguishes empty searches and opens practice without a second navigation bar',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final native = NativeBridge(api: DesignNative());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapProvider.overrideWith((ref) async {}),
            expressionsProvider.overrideWith(
              (ref) => Stream.value([expression]),
            ),
            nativeProvider.overrideWithValue(native),
          ],
          child: const PhrayoApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expressions'));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'unmatched',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matching expressions'), findsOneWidget);
      expect(find.text('Save something you want to say again.'), findsNothing);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(expression.target));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text(expression.target), findsNothing);
      final footer = find.byKey(const ValueKey('practice-controls'));
      expect(tester.getBottomLeft(footer).dy, greaterThan(780));
      await tester.tap(find.text('Say it yourself'));
      await tester.pumpAndSettle();
      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('Show expression'), findsNothing);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(find.text('Got it'), findsOneWidget);
      expect(find.text('Still learning'), findsOneWidget);
      expect(find.text('Say it again'), findsOneWidget);
      expect(tester.getBottomLeft(footer).dy, greaterThan(780));
      await tester.pumpWidget(const SizedBox.shrink());
      await native.dispose();
    },
  );
  testWidgets('recording controls stay at the bottom while history scrolls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rows = List.generate(
      30,
      (i) => Recording(
        id: '$i',
        title: 'Recording $i',
        path: '$i/recording.m4a',
        seconds: 60,
      ),
    );
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
    final footer = find.byKey(const ValueKey('recording-controls'));
    final rect = tester.getRect(footer);
    expect(rect.bottom, tester.getTopLeft(find.byType(NavigationBar)).dy);
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.getRect(footer), rect);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    container
        .read(nativeProvider)
        .sessionChanged(
          SessionMessage(
            id: 'active',
            kind: 'recording',
            state: 'paused',
            seconds: 61,
            level: 0,
            transcript: '',
            translation: '',
            segments: [],
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('01:01'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(
      tester.getRect(footer).bottom,
      tester.getTopLeft(find.byType(NavigationBar)).dy,
    );
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'settings expands one provider form at a time and keeps Action Button help collapsed',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bootstrapProvider.overrideWith((ref) async {})],
          child: const PhrayoApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(
        find.byKey(const ValueKey('provider-key-soniox')).hitTestable(),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.text('STT model'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('STT model'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('provider-key-soniox')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('provider-key-soniox')).hitTestable(),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Text model'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Text model'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('provider-select')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('provider-select')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('provider-key-soniox')).hitTestable(),
        findsNothing,
      );
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
