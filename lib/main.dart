import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers.dart';
import 'ui/apple_colors.dart';
import 'ui/common.dart';
import 'ui/speak_page.dart';
import 'ui/library_page.dart';
import 'ui/recordings_page.dart';
import 'ui/settings_page.dart';
import 'ui/strings.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android) {
    LicenseRegistry.addLicense(() async* {
      final licenses = await const MethodChannel('app.capyvibe.phrayo/android')
          .invokeMapMethod<String, String>('licenses');
      for (final entry in (licenses ?? <String, String>{}).entries) {
        yield LicenseEntryWithLineBreaks([entry.key], entry.value);
      }
    });
  }
  runApp(const ProviderScope(child: PhrayoApp()));
}

final routerProvider = Provider(
  (ref) => GoRouter(
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(child: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/', builder: (_, _) => const SpeakPage())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/library', builder: (_, _) => const LibraryPage()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/recordings',
                builder: (_, _) => const RecordingsPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (_, _) => const SettingsPage(),
              ),
            ],
          ),
        ],
      ),
    ],
  ),
);

class PhrayoApp extends ConsumerWidget {
  const PhrayoApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    ref.watch(bootstrapProvider);
    ref.listen(sessionProvider, (_, next) {
      next.whenData((session) {
        final bridge = ref.read(nativeProvider);
        if (session.kind == 'shortcut' &&
            session.state == 'recording' &&
            bridge.navigatedShortcutId != session.id) {
          bridge.navigatedShortcutId = session.id;
          ref.read(routerProvider).go('/');
        }
      });
    });
    Locale? locale;
    switch (settings.locale) {
      case 'en':
        locale = const Locale('en');
      case 'zh-Hans':
        locale = const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
        );
      case 'zh-Hant':
        locale = const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
        );
    }
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Phrayo',
      locale: locale,
      supportedLocales: const [
        Locale('en'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      builder: (context, child) => Actions(
        actions: <Type, Action<Intent>>{
          EditableTextTapOutsideIntent:
              CallbackAction<EditableTextTapOutsideIntent>(
                onInvoke: (intent) {
                  intent.focusNode.unfocus();
                  return null;
                },
              ),
        },
        child: child!,
      ),
      routerConfig: ref.watch(routerProvider),
    );
  }
}

/// SwiftUI's colours: Apple's iOS system palette in light and dark, with
/// Phrayo's shapes, sizes and type.
ThemeData appTheme(Brightness brightness) {
  final apple = AppleColors.of(brightness);
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: apple.blue,
    onPrimary: const Color(0xFFFFFFFF),
    primaryContainer: apple.blueFill,
    onPrimaryContainer: apple.blueText,
    secondary: apple.gray,
    onSecondary: const Color(0xFFFFFFFF),
    // Tonal buttons are tinted like iOS's tinted button style.
    secondaryContainer: apple.blueFill,
    onSecondaryContainer: apple.blue,
    tertiary: apple.indigo,
    onTertiary: const Color(0xFFFFFFFF),
    tertiaryContainer: apple.indigoFill,
    onTertiaryContainer: apple.indigoText,
    error: apple.red,
    onError: const Color(0xFFFFFFFF),
    errorContainer: apple.redFill,
    onErrorContainer: apple.redText,
    surface: apple.groupedBackground,
    onSurface: apple.label,
    onSurfaceVariant: apple.secondaryLabel,
    surfaceDim: dark ? apple.groupedBackground : apple.control,
    surfaceBright: apple.elevated,
    surfaceContainerLowest: dark
        ? apple.groupedBackground
        : apple.secondaryGroupedBackground,
    surfaceContainerLow: apple.secondaryGroupedBackground,
    surfaceContainer: apple.chrome,
    surfaceContainerHigh: apple.elevated,
    surfaceContainerHighest: apple.control,
    outline: apple.opaqueSeparator,
    outlineVariant: apple.separator,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    inverseSurface: apple.toast,
    onInverseSurface: const Color(0xFFFFFFFF),
    inversePrimary: AppleColors.dark.blue,
    surfaceTint: Colors.transparent,
  );
  final rounded12 = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
  );
  // Tab items are tinted when selected and grey otherwise, without a pill.
  Color tab(Set<WidgetState> states) =>
      states.contains(WidgetState.selected) ? apple.blue : apple.gray;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: apple.groupedBackground,
    fontFamily: '.SF Pro Text',
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: rounded12,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: apple.elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    popupMenuTheme: PopupMenuThemeData(color: apple.elevated, shape: rounded12),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(apple.elevated),
        shape: WidgetStatePropertyAll(rounded12),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      borderRadius: BorderRadius.circular(2),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
    ),
    // Navigation bar buttons such as Back are tinted, as in SwiftUI.
    appBarTheme: AppBarTheme(
      centerTitle: false,
      titleSpacing: 24,
      iconTheme: IconThemeData(color: apple.blue),
      actionsIconTheme: IconThemeData(color: apple.blue),
      titleTextStyle: TextStyle(
        fontFamily: '.SF Pro Text',
        color: apple.label,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
    // Image buttons take the accent colour, as SwiftUI buttons do.
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: apple.blue),
    ),
    // Field glyphs such as the search magnifier and clear button are grey.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: apple.tertiaryFill,
      prefixIconColor: apple.secondaryLabel,
      suffixIconColor: apple.secondaryLabel,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.all(20),
    ),
    // Grouped cards sit flat on the grouped background, as in iOS lists.
    cardTheme: CardThemeData(
      elevation: 0,
      color: apple.secondaryGroupedBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: apple.chrome,
      elevation: 0,
      indicatorColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(color: tab(states)),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: tab(states),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: apple.groupedBackground,
      indicatorColor: Colors.transparent,
      selectedIconTheme: IconThemeData(color: apple.blue),
      unselectedIconTheme: IconThemeData(color: apple.gray),
      selectedLabelTextStyle: TextStyle(
        color: apple.blue,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: apple.gray,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

class AppShell extends ConsumerWidget {
  final Widget child;
  const AppShell({super.key, required this.child});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = GoRouterState.of(context).uri.path;
    final index = path == '/library'
        ? 1
        : path == '/recordings'
        ? 2
        : path == '/settings'
        ? 3
        : 0;
    final wide = MediaQuery.sizeOf(context).width >= 760;
    void navigate(int index) {
      FocusManager.instance.primaryFocus?.unfocus();
      context.go(['/', '/library', '/recordings', '/settings'][index]);
    }

    final boot = ref.watch(bootstrapProvider);
    final recoveryError = ref.watch(recoveryErrorProvider);
    final now = DateTime.now();
    final due = (ref.watch(expressionsProvider).asData?.value ?? const [])
        .where((e) => !e.due.isAfter(now))
        .length;
    // Due reviews show on the Expressions tab, so they are visible from
    // anywhere in the app.
    Widget libraryIcon(IconData icon) => Badge(
      isLabelVisible: due > 0 && index != 1,
      label: Text(due > 99 ? '99+' : '$due'),
      child: Icon(icon),
    );
    // A long recording keeps running on other tabs; a dot marks where it is.
    final capturing = ref.watch(
      sessionProvider.select((value) {
        final s = value.asData?.value;
        return s?.kind == 'recording' &&
            (s?.state == 'recording' || s?.state == 'paused');
      }),
    );
    Widget recordingsIcon() => Badge(
      isLabelVisible: capturing && index != 2,
      child: const Icon(Icons.graphic_eq_rounded),
    );
    return Scaffold(
      appBar: index >= 2
          ? null
          : AppBar(
              title: index != 0
                  ? Text(
                      tr(context, index == 1 ? 'library' : 'recordings'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SproutLogo(size: 38),
                        const SizedBox(width: 8),
                        Text(
                          Localizations.localeOf(context).languageCode == 'zh'
                              ? '句芽'
                              : 'Phrayo',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
            ),
      body: SafeArea(
        child: Column(
          children: [
            if (boot.hasError || recoveryError != null)
              MaterialBanner(
                content: Text(
                  tr(context, errorKey(recoveryError ?? boot.error!)),
                ),
                actions: [
                  TextButton(
                    onPressed: () => ref.invalidate(bootstrapProvider),
                    child: Text(tr(context, 'retry')),
                  ),
                ],
              ),
            Expanded(
              child: Row(
                children: [
                  if (wide)
                    // Tab labels keep their size, as system tab bars do, so
                    // large text never breaks them mid-word.
                    MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1,
                      child: NavigationRail(
                        selectedIndex: index,
                        onDestinationSelected: navigate,
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          NavigationRailDestination(
                            icon: const Icon(Icons.mic_none_rounded),
                            label: Text(tr(context, 'speak')),
                          ),
                          NavigationRailDestination(
                            icon: libraryIcon(Icons.bookmark_border_rounded),
                            selectedIcon: libraryIcon(Icons.bookmark_rounded),
                            label: Text(tr(context, 'library')),
                          ),
                          NavigationRailDestination(
                            icon: recordingsIcon(),
                            label: Text(tr(context, 'recordings')),
                          ),
                          NavigationRailDestination(
                            icon: const Icon(Icons.settings_outlined),
                            selectedIcon: const Icon(Icons.settings_rounded),
                            label: Text(tr(context, 'settings')),
                          ),
                        ],
                      ),
                    ),
                  Expanded(child: child),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          // A hairline separates the tab bar from the page, as on iOS.
          : DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    width: 0.5,
                  ),
                ),
              ),
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1,
                child: NavigationBar(
                  selectedIndex: index,
                  onDestinationSelected: navigate,
                  destinations: [
                    NavigationDestination(
                      icon: const Icon(Icons.mic_none_rounded),
                      selectedIcon: const Icon(Icons.mic_rounded),
                      label: tr(context, 'speak'),
                    ),
                    NavigationDestination(
                      icon: libraryIcon(Icons.bookmark_border_rounded),
                      selectedIcon: libraryIcon(Icons.bookmark_rounded),
                      label: tr(context, 'library'),
                    ),
                    NavigationDestination(
                      icon: recordingsIcon(),
                      label: tr(context, 'recordings'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.settings_outlined),
                      selectedIcon: const Icon(Icons.settings_rounded),
                      label: tr(context, 'settings'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
