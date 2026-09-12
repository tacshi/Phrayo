import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phrayo/main.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/providers.dart';

class PreviewSettings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(source: 'en-US');
}

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('DESIGN_PREVIEWS')) {
      for (final font in {
        '.SF Pro Text': '/System/Library/Fonts/SFNS.ttf',
        'MaterialIcons': '/Users/shibang/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final loader = FontLoader(font.key);
        loader.addFont(
          Future.value(
            ByteData.sublistView(await File(font.value).readAsBytes()),
          ),
        );
        await loader.load();
      }
    }
  });
  for (final brightness in Brightness.values) {
    testWidgets('design preview ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapProvider.overrideWith((ref) async {}),
            settingsProvider.overrideWith(PreviewSettings.new),
            recordingsProvider.overrideWith(
              (ref) => Stream.value([
                Recording(
                  id: 'one',
                  title:
                      'Thank you for this opportunity. I will give it my best.',
                  path: 'one/recording.m4a',
                  seconds: 6,
                  created: DateTime(2026, 9, 9),
                ),
              ]),
            ),
            expressionsProvider.overrideWith((ref) => Stream.value([])),
          ],
          child: const PhrayoApp(),
        ),
      );
      await tester.pumpAndSettle();
      for (final tab in ['Speak', 'Expressions', 'Recordings', 'Settings']) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(tab),
          ),
        );
        await tester.pumpAndSettle();
        if (tab == 'Recordings') {
          expect(
            tester.getCenter(find.text('Select')).dy,
            closeTo(
              tester
                  .getCenter(
                    find.descendant(
                      of: find.byType(AppBar),
                      matching: find.text('Recordings'),
                    ),
                  )
                  .dy,
              1,
            ),
          );
        }
        if (const bool.fromEnvironment('DESIGN_PREVIEWS')) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('/tmp/phrayo-design-${brightness.name}-$tab.png'),
          );
        }
        expect(tester.takeException(), isNull);
      }
    });
  }
}
