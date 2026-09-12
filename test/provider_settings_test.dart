import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/llm_provider.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/services/text_processor.dart';
import 'package:phrayo/ui/settings_page.dart';

class _Native extends PhrayoNative {
  final secrets = <String, String>{};
  @override
  Future<String?> readSecret(String service) async => secrets[service];
  @override
  Future<void> saveSecret(String service, String value) async {
    secrets[service] = value;
  }

  @override
  Future<void> configure(
    String source,
    String target,
    bool localOnly,
    String sttProvider,
    List<String> transcriptionTerms,
  ) async {}
}

class _Adapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) handler;
  _Adapter(this.handler);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

class _Harness {
  final api = _Native();
  final db = AppDatabase(NativeDatabase.memory());
  final requests = <RequestOptions>[];
  late final native = NativeBridge(api: api);
  late final dio = Dio()
    ..httpClientAdapter = _Adapter((request) {
      requests.add(request);
      return respond(request);
    });
  late final processor = TextProcessor(native, dio: dio);
  late final container = ProviderContainer(
    overrides: [
      nativeProvider.overrideWithValue(native),
      databaseProvider.overrideWithValue(db),
      textProcessorProvider.overrideWithValue(processor),
      sttClientProvider.overrideWithValue(dio),
    ],
  );
  FutureOr<ResponseBody> Function(RequestOptions) respond = (_) => _json({
    'data': [
      {'id': 'model-b'},
      {'id': 'model-a'},
    ],
  });

  Future<void> dispose() async {
    container.dispose();
    dio.close();
    await native.dispose();
    await db.close();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Text model'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await _tap(tester, find.text('Text model'));
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _chooseProvider(WidgetTester tester, String label) async {
  await _tap(tester, find.byKey(const ValueKey('provider-select')));
  await _tap(tester, find.text(label).last);
}

Future<void> _key(WidgetTester tester, String key) async {
  final field = find.byKey(const ValueKey('provider-key-llm'));
  await tester.ensureVisible(field);
  await tester.enterText(field, key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'STT selection isolates credentials and validates MOSS model access',
    (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.secrets['soniox'] = 'saved-soniox';
      await h.open(tester);
      await _tap(tester, find.text('STT model'));
      final sonioxField = find.byKey(const ValueKey('provider-key-soniox'));
      await tester.ensureVisible(sonioxField);
      await tester.enterText(sonioxField, 'unsaved-soniox');
      await _tap(tester, find.byKey(const ValueKey('stt-provider-select')));
      await _tap(tester, find.text('MOSS Pro').last);
      expect(
        h.container.read(settingsProvider).sttProvider,
        SttProvider.mossPro,
      );
      expect(
        find.text('Results appear after recording stops.'),
        findsOneWidget,
      );
      final mossField = find.byKey(const ValueKey('provider-key-moss'));
      expect(tester.widget<TextField>(mossField).controller!.text, isEmpty);
      await tester.ensureVisible(mossField);
      await tester.enterText(mossField, 'candidate-moss');
      await _tap(tester, find.byKey(const ValueKey('test-moss')));
      expect(h.api.secrets['moss'], isNull);
      h.respond = (_) => _json({
        'data': [
          {'id': 'moss-transcribe-diarize-pro'},
        ],
      });
      await _tap(tester, find.byKey(const ValueKey('test-moss')));
      expect(h.api.secrets['moss'], 'candidate-moss');
      expect(h.api.secrets['soniox'], 'saved-soniox');
      expect(h.requests.last.uri.toString(), 'https://api.mosi.cn/v1/models');
      await _tap(tester, find.byKey(const ValueKey('stt-provider-select')));
      await _tap(tester, find.text('Soniox').last);
      expect(
        h.container.read(settingsProvider).sttProvider,
        SttProvider.soniox,
      );
      expect(h.api.secrets['moss'], 'candidate-moss');
      expect(tester.widget<TextField>(sonioxField).controller!.text, isEmpty);
      await _tap(tester, find.byKey(const ValueKey('test-soniox')));
      await _tap(tester, find.byType(PopupMenuButton<String>).hitTestable());
      await _tap(tester, find.text('Remove saved key'));
      expect(h.api.secrets['soniox'], '');
      expect(h.api.secrets['moss'], 'candidate-moss');
    },
  );

  for (final script in ['Hans', 'Hant']) {
    testWidgets('STT settings supports Chinese $script at 200% text size', (
      tester,
    ) async {
      final h = _Harness();
      addTearDown(h.dispose);
      final locale = Locale.fromSubtags(languageCode: 'zh', scriptCode: script);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            locale: locale,
            supportedLocales: [locale],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const SettingsPage(),
          ),
        ),
      );
      final title = script == 'Hans' ? '语音转文字模型' : '語音轉文字模型';
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(title),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _tap(tester, find.text(title));
      await _tap(tester, find.byKey(const ValueKey('stt-provider-select')));
      await _tap(tester, find.text('MOSS Pro').last);
      expect(
        h.container.read(settingsProvider).sttProvider,
        SttProvider.mossPro,
      );
      await _tap(tester, find.byKey(const ValueKey('custom-vocabulary')));
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(script == 'Hans' ? '自定义词汇' : '自訂詞彙'),
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-input')),
        '洗漱台',
      );
      await _tap(tester, find.byKey(const ValueKey('save-vocabulary')));
      expect(h.container.read(settingsProvider).transcriptionTerms, ['洗漱台']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mode changes persist without Save', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.open(tester);
    await tester.scrollUntilVisible(
      find.text('On device only'),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    await _tap(tester, find.text('On device only'));
    expect(h.container.read(settingsProvider).localOnly, isTrue);
    final stored = await tester.runAsync(() => h.db.get('settings'));
    expect(AppSettings.fromJson(stored!).localOnly, isTrue);
    expect(find.text('Save'), findsNothing);
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy settings only map known cloud endpoints and retain languages',
    () {
      final known = AppSettings.fromJson({
        'baseUrl': 'https://openrouter.ai/api/v1/',
        'model': 'vendor/model',
        'source': 'ja-JP',
      });
      expect(known.provider, LlmProvider.openRouter);
      expect(known.model, 'vendor/model');
      expect(AppSettings.fromJson(known.toJson()).toJson(), known.toJson());
      expect(known.toJson().containsKey('baseUrl'), isFalse);
      for (final url in [
        'http://localhost:11434/v1',
        'https://custom.test/v1',
      ]) {
        final unknown = AppSettings.fromJson({'baseUrl': url, 'model': 'old'});
        expect(unknown.provider, isNull);
        expect(unknown.model, isEmpty);
        expect(unknown.baseUrl, isEmpty);
      }
    },
  );

  test(
    'startup migrates legacy keys once without sharing them across providers',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.secrets['llm'] = 'legacy-key';
      await h.db.put('settings', 'settings', {
        'baseUrl': LlmProvider.deepSeek.baseUrl,
        'model': 'saved-model',
      });
      await h.container.read(settingsProvider.notifier).load();
      expect(
        await h.processor.credentials.read(LlmProvider.deepSeek),
        'legacy-key',
      );
      expect(await h.processor.credentials.read(LlmProvider.groq), isNull);
      await h.processor.credentials.save(LlmProvider.groq, 'groq-key');
      await h.container.read(settingsProvider.notifier).load();
      expect(await h.processor.credentials.read(LlmProvider.groq), 'groq-key');
      await h.processor.credentials.save(LlmProvider.deepSeek, '');
      await h.container.read(settingsProvider.notifier).load();
      expect(await h.processor.credentials.read(LlmProvider.deepSeek), isNull);
      expect(await h.processor.credentials.read(LlmProvider.groq), 'groq-key');
    },
  );

  test('discovery authenticates presets, normalizes lists and does not save drafts', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.respond = (request) => _json(
      request.path.endsWith('/key')
          ? {
              'data': {'limit_remaining': 10},
            }
          : {
              'data': [
                {'id': ' model-b '},
                {'id': 'model-a'},
                {'id': 'model-a'},
                {'id': ''},
                {'id': 42},
                {'id': 'inactive', 'active': false},
                {
                  'id': 'embed',
                  'capabilities': {'completion_chat': false},
                },
              ],
            },
    );
    for (final provider in LlmProvider.values) {
      h.requests.clear();
      expect(
        await h.processor.listModels(
          AppSettings(provider: provider),
          candidateApiKey: ' candidate ',
        ),
        ['model-a', 'model-b'],
      );
      expect(h.requests.last.uri.toString(), '${provider.baseUrl}/models');
      expect(h.requests.every((r) => r.method == 'GET'), isTrue);
      expect(
        h.requests.every(
          (r) => r.headers['Authorization'] == 'Bearer candidate',
        ),
        isTrue,
      );
      expect(h.requests.every((r) => !r.followRedirects), isTrue);
      expect(h.requests.length, provider == LlmProvider.openRouter ? 2 : 1);
      if (provider == LlmProvider.openRouter) {
        expect(h.requests.first.uri.toString(), '${provider.baseUrl}/key');
      }
    }
    expect(h.api.secrets, isEmpty);
    expect(await h.db.get('settings'), isNull);
  });

  test(
    'discovery fails closed for auth, malformed, empty and offline results',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      const settings = AppSettings(provider: LlmProvider.openRouter);
      h.respond = (_) => _json({'error': 'unauthorized'}, 401);
      await expectLater(
        h.processor.listModels(settings, candidateApiKey: 'bad'),
        throwsA(isA<DioException>()),
      );
      expect(h.requests.single.path, endsWith('/key'));
      for (final body in [
        {'data': []},
        {'data': 'bad'},
        {
          'data': [
            {'id': null},
          ],
        },
      ]) {
        h.respond = (_) => _json(body);
        await expectLater(
          h.processor.listModels(
            const AppSettings(provider: LlmProvider.deepSeek),
            candidateApiKey: 'key',
          ),
          throwsStateError,
        );
      }
      h.requests.clear();
      await expectLater(
        h.processor.listModels(
          const AppSettings(provider: LlmProvider.deepSeek, localOnly: true),
          candidateApiKey: 'key',
        ),
        throwsStateError,
      );
      await expectLater(
        h.processor.listModels(const AppSettings()),
        throwsStateError,
      );
      await h.processor.credentials.save(LlmProvider.deepSeek, 'saved');
      await expectLater(
        h.processor.listModels(const AppSettings(provider: LlmProvider.groq)),
        throwsStateError,
      );
      expect(h.requests, isEmpty);
    },
  );

  test('generation uses the chosen provider key and selected model', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.processor.credentials.save(LlmProvider.deepSeek, 'deepseek-key');
    await h.processor.credentials.save(LlmProvider.groq, 'groq-key');
    h.respond = (_) => ResponseBody.fromString(
      'data: {"choices":[{"delta":{"content":"OK"}}]}\n\ndata: [DONE]\n\n',
      200,
    );
    expect(
      await h.processor
          .rewrite(
            'Rewrite',
            'hello',
            const AppSettings(
              provider: LlmProvider.groq,
              model: 'selected-model',
            ),
          )
          .toList(),
      ['OK'],
    );
    final request = h.requests.single;
    expect(
      request.uri.toString(),
      '${LlmProvider.groq.baseUrl}/chat/completions',
    );
    expect(request.headers['Authorization'], 'Bearer groq-key');
    expect(request.data['model'], 'selected-model');
  });

  testWidgets(
    'provider and model save automatically after connection test and selection',
    (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.open(tester);
      expect(find.byKey(const ValueKey('provider-base')), findsNothing);
      expect(find.byKey(const ValueKey('provider-model')), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('provider-select')));
      for (final label in [
        'OpenAI',
        'OpenRouter',
        'DeepSeek',
        'Groq',
        'Mistral',
      ]) {
        expect(find.text(label).hitTestable(), findsOneWidget);
      }
      for (final label in ['Custom', 'Ollama', 'LM Studio']) {
        expect(find.text(label), findsNothing);
      }
      await _tap(tester, find.text('DeepSeek').last);
      await _key(tester, 'draft-key');
      expect(find.text('Save'), findsNothing);
      expect(h.container.read(settingsProvider).provider, isNull);
      expect(h.api.secrets, isEmpty);
      await _tap(tester, find.byKey(const ValueKey('test-llm')));
      expect(h.api.secrets, isEmpty);
      expect(h.container.read(settingsProvider).provider, isNull);
      expect(
        tester.widget(find.byKey(const ValueKey('provider-model'))),
        isA<DropdownButtonFormField<String>>(),
      );
      expect(find.text('Save'), findsNothing);
      expect(h.api.secrets, isEmpty);
      await _tap(tester, find.byKey(const ValueKey('provider-model')));
      await _tap(tester, find.text('model-b').last);
      expect(find.text('Save'), findsNothing);
      expect(h.container.read(settingsProvider).provider, LlmProvider.deepSeek);
      expect(h.container.read(settingsProvider).model, 'model-b');
      expect(
        await h.processor.credentials.read(LlmProvider.deepSeek),
        'draft-key',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await h.open(tester);
      expect(find.byKey(const ValueKey('provider-model')), findsNothing);
      expect(find.text('model-b'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('test-llm')));
      expect(h.requests.last.headers['Authorization'], 'Bearer draft-key');
      await _key(tester, 'replacement');
      expect(find.byKey(const ValueKey('provider-model')), findsNothing);
      expect(find.text('Save'), findsNothing);
      expect(
        await h.processor.credentials.read(LlmProvider.deepSeek),
        'draft-key',
      );
      await _chooseProvider(tester, 'Groq');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('provider-key-llm')))
            .controller!
            .text,
        isEmpty,
      );
      final count = h.requests.length;
      await _tap(tester, find.byKey(const ValueKey('test-llm')));
      expect(h.requests.length, count);
      expect(find.byKey(const ValueKey('provider-model')), findsNothing);
      expect(h.container.read(settingsProvider).provider, LlmProvider.deepSeek);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed and empty retests revoke selection without changing saved settings',
    (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.open(tester);
      await _chooseProvider(tester, 'DeepSeek');
      await _key(tester, 'key');
      await _tap(tester, find.byKey(const ValueKey('test-llm')));
      expect(find.byKey(const ValueKey('provider-model')), findsOneWidget);
      for (final status in [401, 200]) {
        h.respond = (_) => _json({'data': []}, status);
        await _tap(tester, find.byKey(const ValueKey('test-llm')));
        expect(find.byKey(const ValueKey('provider-model')), findsNothing);
        expect(
          find.byKey(const ValueKey('provider-model-locked')),
          findsOneWidget,
        );
        expect(h.api.secrets, isEmpty);
        expect(h.container.read(settingsProvider).provider, isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('removing a key locks models and preserves other provider keys', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.processor.credentials.save(LlmProvider.deepSeek, 'deepseek-key');
    await h.processor.credentials.save(LlmProvider.groq, 'groq-key');
    await h.container
        .read(settingsProvider.notifier)
        .save(
          const AppSettings(provider: LlmProvider.deepSeek, model: 'model-a'),
        );
    await h.open(tester);
    await _tap(tester, find.byKey(const ValueKey('test-llm')));
    expect(find.byKey(const ValueKey('provider-model')), findsOneWidget);
    await _tap(tester, find.byType(PopupMenuButton<String>).last);
    await _tap(tester, find.text('Remove saved key'));
    expect(find.byKey(const ValueKey('provider-model')), findsNothing);
    expect(await h.processor.credentials.read(LlmProvider.deepSeek), isNull);
    expect(await h.processor.credentials.read(LlmProvider.groq), 'groq-key');
    h.requests.clear();
    await _tap(tester, find.byKey(const ValueKey('test-llm')));
    expect(h.requests, isEmpty);
    expect(find.byKey(const ValueKey('provider-model')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
