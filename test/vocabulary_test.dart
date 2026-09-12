import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/core/providers.dart';
import 'package:phrayo/core/transcription_terms.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/moss.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/services/transcription.dart';
import 'package:phrayo/ui/settings_page.dart';

import 'services_test.dart' show FakeAdapter, jsonBody;

class VocabularyNative extends PhrayoNative {
  List<String> configured = [], received = [];
  int secretReads = 0;
  @override
  Future<void> configure(
    String source,
    String target,
    bool localOnly,
    String provider,
    List<String> terms,
  ) async {
    configured = List.of(terms);
  }

  @override
  Future<String?> readSecret(String service) async {
    secretReads++;
    return 'test';
  }

  @override
  Future<String> prepareAudio(String path) async => path;
  @override
  Future<List<SegmentMessage>> transcribe(
    String path,
    String source,
    List<String> terms,
  ) async {
    received = List.of(terms);
    return [SegmentMessage(id: 'one', text: 'Phrayo', start: 0, end: 1)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'vocabulary normalizes exact duplicates and validates Unicode boundaries',
    () {
      expect(
        normalizeTranscriptionTerms([
          ' Phrayo ',
          '',
          'Phrayo',
          'phrayo',
          '洗漱台',
        ]),
        ['Phrayo', 'phrayo', '洗漱台'],
      );
      expect(normalizeTranscriptionTerms(['😀' * 30]).single.runes.length, 30);
      expect(() => normalizeTranscriptionTerms(['😀' * 31]), throwsStateError);
      expect(
        normalizeTranscriptionTerms(List.generate(20, (i) => '$i')).length,
        20,
      );
      expect(
        () => normalizeTranscriptionTerms(List.generate(21, (i) => '$i')),
        throwsStateError,
      );
      expect(AppSettings.fromJson({}).transcriptionTerms, isEmpty);
    },
  );

  test(
    'saved vocabulary survives reload, provider changes, and resets',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = VocabularyNative();
      final bridge = NativeBridge(api: api);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          nativeProvider.overrideWithValue(bridge),
        ],
      );
      final controller = container.read(settingsProvider.notifier);
      await controller.save(
        const AppSettings(transcriptionTerms: [' Phrayo ', 'Phrayo']),
      );
      expect(api.configured, ['Phrayo']);
      await controller.load();
      expect(container.read(settingsProvider).transcriptionTerms, ['Phrayo']);
      await controller.save(
        AppSettings.fromJson({
          ...container.read(settingsProvider).toJson(),
          'sttProvider': 'mossPro',
          'localOnly': true,
        }),
      );
      expect((await db.get('settings'))!['transcriptionTerms'], ['Phrayo']);
      await controller.save(const AppSettings());
      expect(api.configured, isEmpty);
      container.dispose();
      await bridge.dispose();
      await db.close();
    },
  );

  testWidgets('vocabulary editor validates, saves, reopens and cancels', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = VocabularyNative();
    final bridge = NativeBridge(api: api);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        nativeProvider.overrideWithValue(bridge),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('custom-vocabulary'));
    await tester.scrollUntilVisible(
      entry,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('vocabulary-input'));
    final save = find.byKey(const ValueKey('save-vocabulary'));
    await tester.enterText(input, 'a' * 31);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      find.text('Shorten each term to 30 characters or fewer.'),
      findsOneWidget,
    );
    expect(api.configured, isEmpty);
    await tester.enterText(input, ' Phrayo \n\n洗漱台\nPhrayo');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(api.configured, ['Phrayo', '洗漱台']);
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, 'Phrayo\n洗漱台');
    await tester.enterText(input, 'Discard this');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).transcriptionTerms, [
      'Phrayo',
      '洗漱台',
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    container.dispose();
    await bridge.dispose();
    await db.close();
  });

  for (final provider in SttProvider.values) {
    for (final terms in <List<String>>[
      [],
      ['洗漱台', 'Phrayo'],
    ]) {
      test(
        '${provider.name} snapshots new vocabulary before upload and sends only supported fields ($terms)',
        () async {
          final folder = await Directory.systemTemp.createTemp(
            'phrayo-vocabulary',
          );
          final audio = await File('${folder.path}/audio.m4a')
              .writeAsBytes([1, 2]);
          final db = AppDatabase(NativeDatabase.memory());
          final api = VocabularyNative();
          final bridge = NativeBridge(api: api);
          final r = Recording(id: 'r', title: '', path: audio.path, seconds: 1);
          await db.insertRecording(r);
          var submitted = false;
          final service = TranscriptionService(
            db,
            bridge,
            createClient: () =>
                Dio()
                  ..httpClientAdapter = FakeAdapter((request) async {
                    if (request.method == 'DELETE') return jsonBody({});
                    if (request.path == '/files') {
                      final job = (await db.get('job:r'))!;
                      expect(job['transcriptionTerms'], terms);
                      if (provider == SttProvider.mossPro) {
                        expect(job['model'], mossModel);
                      }
                      return jsonBody({'id': 'file'});
                    }
                    if (request.method == 'POST') {
                      submitted = true;
                      final data = request.data as Map;
                      if (provider == SttProvider.mossPro) {
                        expect(data['model'], mossModel);
                        expect(data.containsKey('version'), isFalse);
                        expect(data['keyterms'], terms.isEmpty ? null : terms);
                        expect(data.containsKey('context'), isFalse);
                        return jsonBody({'task_id': 'remote'});
                      }
                      expect(
                        data['context'],
                        terms.isEmpty ? null : {'terms': terms},
                      );
                      expect(data.containsKey('keyterms'), isFalse);
                      return jsonBody({'id': 'remote'});
                    }
                    if (provider == SttProvider.mossPro) {
                      return jsonBody({
                        'status': 'SUCCESS',
                        'segments': [
                          {'text': 'Phrayo', 'start': 0, 'end': 1},
                        ],
                      });
                    }
                    if (request.path.endsWith('/transcript')) {
                      return jsonBody({
                        'tokens': [
                          {'text': 'Phrayo', 'start_ms': 0, 'end_ms': 1000},
                        ],
                      });
                    }
                    return jsonBody({'status': 'completed'});
                  }),
          );
          await service.run(
            r,
            AppSettings(sttProvider: provider, transcriptionTerms: terms),
          );
          expect(submitted, isTrue);
          expect(await db.get('job:r'), isNull);
          await bridge.dispose();
          await db.close();
          await folder.delete(recursive: true);
        },
      );
    }
  }

  for (final provider in SttProvider.values) {
    test(
      '${provider.name} resumed submission uses original vocabulary after settings change',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final bridge = NativeBridge(api: VocabularyNative());
        final r = Recording(id: 'r', title: '', path: 'unused', seconds: 1);
        await db.insertRecording(r);
        await db.put('job:r', 'job', {
          'provider': provider.name,
          'revision': 0,
          'stage': 'uploaded',
          'fileId': 'file',
          'transcriptionTerms': ['Original'],
          if (provider == SttProvider.mossPro) 'model': mossModel,
        });
        var submitted = false;
        final service = TranscriptionService(
          db,
          bridge,
          createClient: () => Dio()
            ..httpClientAdapter = FakeAdapter((request) {
              if (request.method == 'DELETE') return jsonBody({});
              if (request.method == 'POST') {
                submitted = true;
                final data = request.data as Map;
                expect(
                  provider == SttProvider.mossPro
                      ? data['keyterms']
                      : data['context']['terms'],
                  ['Original'],
                );
                return jsonBody({'id': 'remote', 'task_id': 'remote'});
              }
              if (provider == SttProvider.mossPro) {
                return jsonBody({
                  'status': 'SUCCESS',
                  'segments': [
                    {'text': 'Original', 'start': 0, 'end': 1},
                  ],
                });
              }
              if (request.path.endsWith('/transcript')) {
                return jsonBody({
                  'tokens': [
                    {'text': 'Original', 'start_ms': 0, 'end_ms': 1000},
                  ],
                });
              }
              return jsonBody({'status': 'completed'});
            }),
        );
        await service.run(
          r,
          AppSettings(
            sttProvider: provider,
            transcriptionTerms: const ['Changed'],
          ),
        );
        expect(submitted, isTrue);
        await bridge.dispose();
        await db.close();
      },
    );
  }

  for (final storedTerms in <List<String>?>[
    null,
    ['Original'],
  ]) {
    test(
      'local retry preserves job vocabulary ($storedTerms) without cloud access',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final api = VocabularyNative();
        final bridge = NativeBridge(api: api);
        final r = Recording(id: 'r', title: '', path: 'unused', seconds: 1);
        await db.insertRecording(r);
        await db.put('job:r', 'job', {
          'revision': 0,
          'stage': 'pending',
          'transcriptionTerms': ?storedTerms,
        });
        await TranscriptionService(
          db,
          bridge,
          createClient: () => Dio()
            ..httpClientAdapter = FakeAdapter((_) {
              fail('No cloud calls in local mode');
            }),
        ).run(
          r,
          const AppSettings(localOnly: true, transcriptionTerms: ['Changed']),
        );
        expect(api.received, storedTerms ?? []);
        expect(api.secretReads, 0);
        await bridge.dispose();
        await db.close();
      },
    );
  }
}
