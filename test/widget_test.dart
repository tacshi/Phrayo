import 'dart:async';

import 'package:dio/dio.dart';
import 'package:phrayo/core/llm_provider.dart';
import 'package:phrayo/services/text_processor.dart';
import 'package:phrayo/ui/common.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phrayo/main.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/ui/strings.dart';

import 'support/ready_speech_native.dart';

class ChineseSettings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(locale: 'zh-Hant');
}

class LayoutNative extends ReadySpeechNative {
  @override
  Future<String> ttsStatus(String language) async => 'unsupported';
}

class DelayedTranslation extends ReadySpeechNative {
  final pending = Completer<String>();
  @override
  Future<String> translate(String text, String source, String target) =>
      pending.future;
}

class OnlineSettings extends SettingsController {
  @override
  AppSettings build() =>
      AppSettings(provider: LlmProvider.values.first, model: 'test');
}

class DelayedProcessor extends TextProcessor {
  DelayedProcessor(super.native, this.pending);
  final Completer<String> pending;
  @override
  Future<String> translate(
    String text,
    AppSettings settings, {
    TranslationStyle style = TranslationStyle.standard,
    CancelToken? cancel,
  }) => pending.future;
}

void main() {
  test('navigation surfaces match the page in both themes', () {
    for (final brightness in Brightness.values) {
      final theme = appTheme(brightness);
      expect(theme.appBarTheme.backgroundColor, theme.scaffoldBackgroundColor);
      expect(
        theme.navigationBarTheme.backgroundColor,
        theme.scaffoldBackgroundColor,
      );
      expect(
        theme.navigationRailTheme.backgroundColor,
        theme.scaffoldBackgroundColor,
      );
      expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
    }
  });

  testWidgets(
    'translation controls share a row and system translation needs no model',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bootstrapProvider.overrideWith((ref) async {})],
          child: const PhrayoApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pumpAndSettle();
      final button = find.widgetWithText(TextButton, 'Translate');
      final picker = find.byType(TranslationStylePicker);
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      expect(
        tester
            .widget<DropdownButtonFormField<TranslationStyle>>(
              find.byType(DropdownButtonFormField<TranslationStyle>),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester.getCenter(button).dy,
        closeTo(tester.getCenter(picker).dy, 1),
      );
      expect(find.text(words['style_requires_model']!.first), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  test('all user-visible strings have three translations', () {
    for (final entry in words.entries) {
      expect(entry.value.length, 3, reason: entry.key);
      expect(entry.value.every((s) => s.isNotEmpty), true, reason: entry.key);
    }
  });
  testWidgets('first use gives a speak action without model credentials', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bootstrapProvider.overrideWith((ref) async {})],
        child: const PhrayoApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hold to speak. Release to translate.'), findsNothing);
    expect(find.byKey(const ValueKey('speak-control')), findsOneWidget);
    final bottom = tester
        .getBottomLeft(find.byKey(const ValueKey('speak-control')))
        .dy;
    final navigationTop = tester.getTopLeft(find.byType(NavigationBar)).dy;
    expect(navigationTop - bottom, inInclusiveRange(12, 48));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Phrayo'), findsOneWidget);
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'wide layout switches navigation without duplicate primary actions',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bootstrapProvider.overrideWith((ref) async {})],
          child: const PhrayoApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'traditional Chinese and large text remain usable on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final bridge = NativeBridge(api: LayoutNative());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapProvider.overrideWith((ref) async {}),
            settingsProvider.overrideWith(ChineseSettings.new),
            nativeProvider.overrideWithValue(bridge),
          ],
          child: const PhrayoApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('句芽'), findsOneWidget);
      expect(find.text('按住說話，鬆開看翻譯'), findsNothing);
      expect(find.byKey(const ValueKey('speak-control')), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('設定'), findsNWidgets(2));
      final navigation = tester.widget<NavigationBar>(
        find.byType(NavigationBar),
      );
      expect(navigation.destinations, hasLength(4));
      expect(navigation.selectedIndex, 3);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await bridge.dispose();
    },
  );
  testWidgets('switching tabs preserves the speaking draft and translation', (
    tester,
  ) async {
    final api = DelayedTranslation();
    final bridge = NativeBridge(api: api);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bootstrapProvider.overrideWith((ref) async {}),
          nativeProvider.overrideWithValue(bridge),
          settingsProvider.overrideWith(OnlineSettings.new),
          expressionsProvider.overrideWith((ref) => Stream.value([])),
          recordingsProvider.overrideWith((ref) => Stream.value([])),
          textProcessorProvider.overrideWith((ref) {
            final processor = DelayedProcessor(bridge, api.pending);
            ref.onDispose(processor.dio.close);
            return processor;
          }),
        ],
        child: const PhrayoApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'Keep my last transcription',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<TranslationStyle>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Professional').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Translate'));
    await tester.pump();
    api.pending.complete('Keep my translation');
    await tester.pumpAndSettle();
    for (final destination in ['Expressions', 'Recordings']) {
      await tester.tap(find.text(destination));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speak'));
      await tester.pumpAndSettle();
      expect(find.text('Keep my last transcription'), findsOneWidget);
      expect(find.text('Keep my translation'), findsOneWidget);
      expect(
        tester
            .widget<TranslationStylePicker>(find.byType(TranslationStylePicker))
            .value,
        TranslationStyle.professional,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await bridge.dispose();
  });
  testWidgets('editing the source rejects a late translation result', (
    tester,
  ) async {
    final api = DelayedTranslation();
    final active = NativeBridge(api: api);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bootstrapProvider.overrideWith((ref) async {}),
          nativeProvider.overrideWithValue(active),
          settingsProvider.overrideWith(OnlineSettings.new),
          textProcessorProvider.overrideWith((ref) {
            final processor = DelayedProcessor(active, api.pending);
            ref.onDispose(processor.dio.close);
            return processor;
          }),
        ],
        child: const PhrayoApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Original input');
    await tester.pump();
    await tester.tap(find.text('Translate'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Updated input');
    api.pending.complete('Stale result');
    await tester.pumpAndSettle();
    expect(find.text('Stale result'), findsNothing);
    expect(find.text('Updated input'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await active.dispose();
  });
  testWidgets(
    'long translations scroll independently of the bottom microphone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = DelayedTranslation();
      final bridge = NativeBridge(api: api);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapProvider.overrideWith((ref) async {}),
            nativeProvider.overrideWithValue(bridge),
            settingsProvider.overrideWith(OnlineSettings.new),
            textProcessorProvider.overrideWith((ref) {
              final processor = DelayedProcessor(bridge, api.pending);
              ref.onDispose(processor.dio.close);
              return processor;
            }),
          ],
          child: const PhrayoApp(),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('speak-control'));
      final before = tester.getRect(button);
      await tester.enterText(find.byType(TextField), 'A long expression');
      await tester.pump();
      await tester.tap(find.text('Translate'));
      await tester.pump();
      api.pending.complete(List.filled(80, 'A translated sentence.').join(' '));
      await tester.pumpAndSettle();
      expect(tester.getRect(button), before);
      await tester.drag(find.byType(ListView).first, const Offset(0, -350));
      await tester.pumpAndSettle();
      expect(tester.getRect(button), before);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await bridge.dispose();
    },
  );
}
