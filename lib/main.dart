import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers.dart';
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

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff70cba5),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xff70cba5) : const Color(0xff28694e),
        surface: dark ? const Color(0xff142720) : const Color(0xfffaf7ef),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: '.SF Pro Text',
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleSpacing: 24,
      titleTextStyle: TextStyle(
        fontFamily: '.SF Pro Text',
        color: scheme.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xff1f362c) : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.all(20),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xff1f362c) : Colors.white,
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
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
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
                    NavigationRail(
                      selectedIndex: index,
                      onDestinationSelected: navigate,
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        NavigationRailDestination(
                          icon: const Icon(Icons.mic_none_rounded),
                          label: Text(tr(context, 'speak')),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.bookmark_border_rounded),
                          label: Text(tr(context, 'library')),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.graphic_eq_rounded),
                          label: Text(tr(context, 'recordings')),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.settings_outlined),
                          selectedIcon: const Icon(Icons.settings_rounded),
                          label: Text(tr(context, 'settings')),
                        ),
                      ],
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
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: navigate,
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.mic_none_rounded),
                  selectedIcon: const Icon(Icons.mic_rounded),
                  label: tr(context, 'speak'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.bookmark_border_rounded),
                  selectedIcon: const Icon(Icons.bookmark_rounded),
                  label: tr(context, 'library'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.graphic_eq_rounded),
                  label: tr(context, 'recordings'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.settings_outlined),
                  selectedIcon: const Icon(Icons.settings_rounded),
                  label: tr(context, 'settings'),
                ),
              ],
            ),
    );
  }
}
