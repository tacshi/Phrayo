import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/main.dart' show appTheme;
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/speak_page.dart';

import 'support/ready_speech_native.dart';

SessionMessage recordingSession(String id, String state) => SessionMessage(
  id: id,
  kind: 'speaking',
  state: state,
  seconds: 2,
  level: 0.2,
  transcript: 'Current recording',
  translation: state == 'saved' ? 'Finished translation' : '',
  sourceLanguage: 'zh-CN',
  targetLanguage: 'en-US',
  path: state == 'saved' ? '$id/recording.m4a' : null,
  segments: [],
);

class RecordingNative extends ReadySpeechNative {
  late NativeBridge bridge;
  SessionMessage? current;
  int starts = 0, stops = 0, cancels = 0;
  bool failStart = false, failCancel = false;
  bool publishEvents = true;
  Completer<void>? startGate, startReplyGate, cancelGate;

  void emit(SessionMessage session) {
    current = session;
    if (publishEvents) bridge.sessionChanged(session);
  }

  @override
  Future<SessionMessage> start(
    String kind,
    String source,
    String target,
    bool localOnly,
    String sttProvider,
    List<String> transcriptionTerms,
  ) async {
    final id = 'attempt-${++starts}';
    await startGate?.future;
    if (failStart) throw StateError('microphone_denied');
    final session = recordingSession(id, 'recording');
    emit(session);
    await startReplyGate?.future;
    return session;
  }

  @override
  Future<SessionMessage> stop() async {
    stops++;
    final result = recordingSession(current!.id, 'saved');
    emit(result);
    return result;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    await cancelGate?.future;
    if (failCancel) throw StateError('error');
    // Deliberately retain transcript data, as older native implementations did.
    emit(recordingSession(current!.id, 'cancelled'));
  }

  @override
  Future<SessionMessage?> snapshot() async => current;
}

class GestureSettings extends SettingsController {
  GestureSettings(this.settings);
  final AppSettings settings;
  @override
  AppSettings build() => settings;
}

class Harness {
  final api = RecordingNative();
  late final bridge = NativeBridge(api: api);

  Future<void> open(
    WidgetTester tester, {
    String locale = 'en',
    double scale = 1,
    Size size = const Size(390, 844),
  }) async {
    api.bridge = bridge;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nativeProvider.overrideWithValue(bridge),
          settingsProvider.overrideWith(
            () => GestureSettings(AppSettings(locale: locale)),
          ),
          expressionsProvider.overrideWith((ref) => Stream.value([])),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.light),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('en'), Locale('zh')],
          locale: Locale(locale.split('-').first),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(body: SafeArea(child: SpeakPage())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<TestGesture> hold(WidgetTester tester, {int pointer = 1}) async {
    final gesture = await tester.startGesture(
      tester.getCenter(microphone),
      pointer: pointer,
    );
    await tester.pumpAndSettle();
    return gesture;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await bridge.dispose();
  }
}

final microphone = find.byKey(const ValueKey('speak-control'));
final cancelButton = find.byKey(const ValueKey('speak-cancel'));

void semanticTap(WidgetTester tester, Finder finder) {
  final node = tester.getSemantics(finder);
  expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
  node.owner!.performAction(node.id, SemanticsAction.tap);
}

void main() {
  testWidgets('ordinary release processes once without moving the microphone', (
    tester,
  ) async {
    final h = Harness();
    await h.open(tester);
    final before = tester.getRect(microphone);
    final gesture = await h.hold(tester);
    expect(tester.getRect(microphone), before);
    expect(tester.getSize(cancelButton).height, greaterThanOrEqualTo(48));
    expect(tester.getBottomLeft(cancelButton).dy, lessThan(before.top));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.api.stops, 1);
    expect(h.api.cancels, 0);
    expect(find.text('Finished translation'), findsOneWidget);
    await h.close(tester);
  });

  testWidgets(
    'release over Cancel discards and rejects late data before the next recording',
    (tester) async {
      final h = Harness();
      await h.open(tester);
      final gesture = await h.hold(tester);
      final target = tester.getCenter(cancelButton);
      await gesture.moveTo(target);
      await tester.pumpAndSettle();
      expect(find.text('Release to cancel'), findsOneWidget);
      final button = tester.widget<TextButton>(cancelButton);
      expect(
        button.style!.backgroundColor!.resolve({}),
        appTheme(Brightness.light).colorScheme.errorContainer,
      );
      expect(h.api.cancels, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(h.api.cancels, 1);
      expect(h.api.stops, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      h.bridge.sessionChanged(recordingSession('attempt-1', 'saved'));
      await tester.pumpAndSettle();
      expect(find.text('Finished translation'), findsNothing);
      final next = await h.hold(tester);
      h.bridge.sessionChanged(recordingSession('attempt-1', 'recording'));
      await tester.pumpAndSettle();
      expect(h.bridge.current!.id, 'attempt-2');
      await next.up();
      await tester.pumpAndSettle();
      expect(h.api.starts, 2);
      expect(h.api.stops, 1);
      await h.close(tester);
    },
  );

  testWidgets(
    'sliding back disarms cancellation and haptics occur only on entry',
    (tester) async {
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
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
      final h = Harness();
      await h.open(tester);
      final gesture = await h.hold(tester);
      final target = tester.getCenter(cancelButton);
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.moveTo(target + const Offset(1, 1));
      await tester.pump();
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      await gesture.moveTo(tester.getCenter(microphone));
      await tester.pumpAndSettle();
      expect(find.text('Slide up to cancel'), findsOneWidget);
      await gesture.moveTo(target);
      await tester.pump();
      expect(haptics.length, 2);
      await gesture.moveTo(tester.getCenter(microphone));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(h.api.stops, 1);
      expect(h.api.cancels, 0);
      await h.close(tester);
    },
  );

  for (final discard in [false, true]) {
    testWidgets(
      'release during startup remembers ${discard ? 'discard' : 'finish'} exactly once',
      (tester) async {
        final h = Harness();
        h.api.startGate = Completer<void>();
        await h.open(tester);
        final before = tester.getRect(microphone);
        final gesture = await h.hold(tester);
        expect(tester.getRect(microphone), before);
        if (discard) await gesture.moveTo(tester.getCenter(cancelButton));
        await gesture.up();
        await tester.pump();
        expect(h.api.stops + h.api.cancels, 0);
        await tester.tap(microphone);
        expect(h.api.starts, 1);
        h.api.startGate!.complete();
        await tester.pumpAndSettle();
        expect(h.api.cancels, discard ? 1 : 0);
        expect(h.api.stops, discard ? 0 : 1);
        await h.close(tester);
      },
    );
  }

  testWidgets(
    'system pointer cancellation discards and additional fingers cannot finish',
    (tester) async {
      final h = Harness();
      await h.open(tester);
      final gesture = await h.hold(tester);
      final other = await h.hold(tester, pointer: 2);
      await other.moveTo(tester.getCenter(cancelButton));
      await other.up();
      await tester.pumpAndSettle();
      expect(h.api.starts, 1);
      expect(h.api.stops + h.api.cancels, 0);
      await tester.tap(cancelButton, pointer: 3);
      expect(h.api.cancels, 0);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(h.api.cancels, 1);
      expect(h.api.stops, 0);
      await h.close(tester);
    },
  );

  testWidgets('startup failure resets ownership and permits retry', (
    tester,
  ) async {
    final h = Harness();
    h.api.failStart = true;
    await h.open(tester);
    final gesture = await h.hold(tester);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(cancelButton, findsNothing);
    expect(h.api.stops + h.api.cancels, 0);
    h.api.failStart = false;
    final retry = await h.hold(tester);
    await retry.up();
    await tester.pumpAndSettle();
    expect(h.api.starts, 2);
    expect(h.api.stops, 1);
    await h.close(tester);
  });

  testWidgets(
    'cancellation blocks another start until cleanup and failed cancellation can retry',
    (tester) async {
      final h = Harness();
      h.api.cancelGate = Completer<void>();
      h.api.failCancel = true;
      await h.open(tester);
      final gesture = await h.hold(tester);
      await gesture.moveTo(tester.getCenter(cancelButton));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(microphone);
      expect(h.api.starts, 1);
      h.api.cancelGate!.complete();
      await tester.pumpAndSettle();
      expect(cancelButton, findsOneWidget);
      h.api.failCancel = false;
      await tester.tap(cancelButton);
      await tester.pumpAndSettle();
      expect(h.api.cancels, 2);
      expect(cancelButton, findsNothing);
      await h.close(tester);
    },
  );

  testWidgets('VoiceOver can start, stop and cancel without holding', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final h = Harness();
    await h.open(tester);
    semanticTap(tester, microphone);
    await tester.pumpAndSettle();
    expect(h.api.starts, 1);
    expect(h.api.stops, 0);
    semanticTap(tester, microphone);
    await tester.pumpAndSettle();
    expect(h.api.stops, 1);
    semanticTap(tester, microphone);
    await tester.pumpAndSettle();
    semanticTap(tester, find.bySemanticsLabel('Cancel'));
    await tester.pumpAndSettle();
    expect(h.api.cancels, 1);
    await h.close(tester);
    semantics.dispose();
  });

  for (final state in ['processing', 'interrupted', 'cancelled']) {
    testWidgets('native $state disarms the held gesture', (tester) async {
      final h = Harness();
      await h.open(tester);
      final gesture = await h.hold(tester);
      h.api.emit(recordingSession('attempt-1', state));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(h.api.stops + h.api.cancels, 0);
      expect(cancelButton, findsNothing);
      await h.close(tester);
    });
  }

  for (final delayed in [false, true]) {
    testWidgets(
      'disposal cancels its ${delayed ? 'pending' : 'active'} recording',
      (tester) async {
        final h = Harness();
        if (delayed) h.api.startGate = Completer<void>();
        await h.open(tester);
        await h.hold(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        if (delayed) h.api.startGate!.complete();
        await tester.pumpAndSettle();
        expect(h.api.cancels, 1);
        expect(tester.takeException(), isNull);
        await h.bridge.dispose();
      },
    );
  }

  testWidgets('disposal does not cancel a replacement native session', (
    tester,
  ) async {
    final h = Harness();
    await h.open(tester);
    await h.hold(tester);
    h.api.current = recordingSession('replacement', 'recording');
    await h.close(tester);
    expect(h.api.cancels, 0);
  });

  testWidgets('a delayed start reply cannot reclaim a replacement session', (
    tester,
  ) async {
    final h = Harness();
    h.api.startReplyGate = Completer<void>();
    await h.open(tester);
    final gesture = await h.hold(tester);
    h.api.emit(recordingSession('replacement', 'recording'));
    await tester.pumpAndSettle();
    h.api.startReplyGate!.complete();
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.bridge.current!.id, 'replacement');
    expect(h.api.stops + h.api.cancels, 0);
    await h.close(tester);
    expect(h.api.cancels, 0);
  });

  testWidgets('the cancel hit margin works without including the microphone', (
    tester,
  ) async {
    final h = Harness();
    await h.open(tester);
    final gesture = await h.hold(tester);
    final target = tester.getRect(cancelButton);
    await gesture.moveTo(Offset(target.left - 4, target.center.dy));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.api.cancels, 1);
    final next = await h.hold(tester);
    await next.moveTo(tester.getTopLeft(microphone) + const Offset(0, 1));
    await next.up();
    await tester.pumpAndSettle();
    expect(h.api.cancels, 1);
    expect(h.api.stops, 1);
    await h.close(tester);
  });

  for (final locale in ['en', 'zh-Hans', 'zh-Hant']) {
    for (final size in [const Size(320, 844), const Size(568, 320)]) {
      testWidgets('$locale gesture fits $size at 200% text', (tester) async {
        final h = Harness();
        await h.open(tester, locale: locale, scale: 2, size: size);
        final before = tester.getRect(microphone);
        final gesture = await h.hold(tester);
        final targetBefore = tester.getRect(cancelButton);
        expect(tester.getRect(microphone), before);
        await gesture.moveTo(tester.getCenter(cancelButton));
        await tester.pumpAndSettle();
        expect(tester.getRect(cancelButton), targetBefore);
        expect(tester.takeException(), isNull);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(h.api.cancels, 1);
        await h.close(tester);
      });
    }
  }
}
