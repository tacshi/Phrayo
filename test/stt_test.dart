import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phrayo/core/providers.dart';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/moss.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/services/transcription.dart';

import 'services_test.dart' show FakeAdapter, jsonBody;

class SttNative extends PhrayoNative {
  final reads = <String>[];
  final secrets = {'soniox': 'soniox-test', 'moss': 'moss-test'};
  @override
  Future<String?> readSecret(String service) async {
    reads.add(service);
    return secrets[service];
  }

  @override
  Future<List<SegmentMessage>> transcribe(
    String path,
    String source,
    List<String> transcriptionTerms,
  ) async => [SegmentMessage(id: 'local', text: 'Local.', start: 0, end: 1)];
}

class RecoveredMossNative extends SttNative {
  final SessionMessage recovered;
  final acknowledgements = <String>[];
  RecoveredMossNative(this.recovered);
  @override
  Future<List<SessionMessage>> recover() async => [recovered];
  @override
  Future<SessionMessage?> snapshot() async => null;
  @override
  Future<void> acknowledge(String id) async {
    acknowledgements.add(id);
  }
}

const transcript = {
  'status': 'SUCCESS',
  'segments': [
    {'start': 0.25, 'end': 1.5, 'text': ' Hello. ', 'speaker': 'speaker-1'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native MOSS job import is atomic and repeated recovery cannot revive a reset job', () async {
    final session = SessionMessage(
      id: 'r',
      kind: 'speaking',
      state: 'interrupted',
      seconds: 2,
      level: 0,
      transcript: '',
      translation: '',
      path: 'r/recording.m4a',
      segments: [],
      sttJobJson: jsonEncode({
        'provider': 'mossPro',
        'stage': 'processing',
        'fileId': 'file',
        'remoteId': 'task',
      }),
    );
    final db = AppDatabase(NativeDatabase.memory());
    final api = RecoveredMossNative(session);
    final bridge = NativeBridge(api: api);
    addTearDown(() async {
      await bridge.dispose();
      await db.close();
    });
    ProviderContainer container() => ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        nativeProvider.overrideWithValue(bridge),
      ],
    );
    final first = container();
    await first.read(bootstrapProvider.future);
    expect((await db.get('job:r'))!['provider'], 'mossPro');
    expect((await db.get('job:r'))!['remoteId'], 'task');
    expect((await db.get('job:r'))!['revision'], 0);
    expect(await db.get('r'), isNotNull);
    expect(api.acknowledgements, ['r']);
    first.dispose();
    await db.remove('job:r');
    final second = container();
    await second.read(bootstrapProvider.future);
    expect(await db.get('job:r'), isNull);
    second.dispose();
  });

  test('STT settings migrate to Soniox and round-trip MOSS independently', () {
    expect(AppSettings.fromJson({}).sttProvider, SttProvider.soniox);
    final settings = AppSettings.fromJson(
      const AppSettings(sttProvider: SttProvider.mossPro).toJson(),
    );
    expect(settings.sttProvider, SttProvider.mossPro);
    expect(settings.provider, isNull);
    expect(settings.model, isEmpty);
  });

  test(
    'MOSS parsing preserves seconds and speakers and rejects invalid timing',
    () {
      final result = mossSegments(transcript).single;
      expect(result.start, .25);
      expect(result.end, 1.5);
      expect(result.speaker, 'speaker-1');
      expect(result.text, 'Hello.');
      for (final end in [null, double.nan, -1, .1]) {
        expect(
          () => mossSegments({
            'segments': [
              {'text': 'Hi', 'start': .25, 'end': end},
            ],
          }),
          throwsStateError,
        );
      }
      expect(mossSegments({'text': 'Hi', 'duration': 2}).single.end, 2);
      expect(() => mossSegments({'segments': 'bad'}), throwsStateError);
    },
  );

  test('MOSS key validation requires the transcription model and propagates auth failures', () async {
    final dio = Dio();
    addTearDown(dio.close);
    var status = 200;
    var model = 'other';
    dio.httpClientAdapter = FakeAdapter((r) {
      expect(r.uri.toString(), 'https://api.mosi.cn/v1/models');
      expect(r.headers['Authorization'], 'Bearer candidate');
      expect(r.followRedirects, isFalse);
      return jsonBody({
        'data': [
          {'id': model},
        ],
      }, status);
    });
    await expectLater(
      validateSttKey(dio, SttProvider.mossPro, 'candidate'),
      throwsStateError,
    );
    model = mossModel;
    await validateSttKey(dio, SttProvider.mossPro, 'candidate');
    status = 401;
    await expectLater(
      validateSttKey(dio, SttProvider.mossPro, 'candidate'),
      throwsA(isA<DioException>()),
    );
  });

  test(
    'MOSS uploads, journals before submission, polls and honors retry timing',
    () async {
      final folder = await Directory.systemTemp.createTemp('phrayo-moss-test');
      addTearDown(() => folder.delete(recursive: true));
      final file = await File('${folder.path}/audio.m4a').writeAsBytes([1, 2]);
      final dio = Dio();
      addTearDown(dio.close);
      final job = <String, dynamic>{'recordingId': 'r', 'stage': 'pending'};
      final stages = <String>[];
      final waits = <Duration>[];
      var polls = 0;
      dio.httpClientAdapter = FakeAdapter((r) {
        if (r.path == '/files') {
          expect(job['stage'], 'upload_unknown');
          expect(Map.fromEntries((r.data as FormData).fields), {
            'purpose': 'audio',
          });
          return jsonBody({'id': 'file'});
        }
        if (r.path == '/audio/transcriptions') {
          expect(job['stage'], 'submission_unknown');
          expect(r.data, {
            'model': legacyMossModel,
            'version': mossVersion,
            'file_id': 'file',
            'diarize': true,
            'response_format': 'json',
            'async': true,
          });
          return jsonBody({'task_id': 'task'});
        }
        expect(r.path, '/audio/tasks/task');
        return jsonBody(
          polls++ == 0 ? {'status': 'RUNNING', 'retry_after': 80} : transcript,
        );
      });
      final result = await runMoss(
        dio: dio,
        job: job,
        persist: () async {
          stages.add(job['stage']);
        },
        prepareAudio: () async => file.path,
        cancellation: CancelToken(),
        delay: (d) async {
          waits.add(d);
        },
      );
      expect(result.single.text, 'Hello.');
      expect(stages, [
        'upload_unknown',
        'uploaded',
        'submission_unknown',
        'processing',
      ]);
      expect(waits, [const Duration(seconds: 30)]);
    },
  );

  test('ambiguous MOSS submissions and uploads never resubmit', () async {
    final dio = Dio();
    addTearDown(dio.close);
    var calls = 0;
    dio.httpClientAdapter = FakeAdapter((_) {
      calls++;
      return jsonBody({});
    });
    for (final stage in ['submission_unknown', 'upload_unknown']) {
      await expectLater(
        runMoss(
          dio: dio,
          job: {'stage': stage},
          persist: () async {},
          prepareAudio: () async => '/unused',
          cancellation: CancelToken(),
        ),
        throwsStateError,
      );
    }
    expect(calls, 0);
  });

  test('poll cancellation retains identifiers and failure cannot silently resubmit', () async {
    final dio = Dio();
    addTearDown(dio.close);
    final token = CancelToken();
    final job = <String, dynamic>{
      'stage': 'processing',
      'fileId': 'file',
      'remoteId': 'task',
    };
    dio.httpClientAdapter = FakeAdapter((_) => jsonBody({'status': 'RUNNING'}));
    await expectLater(
      runMoss(
        dio: dio,
        job: job,
        persist: () async {},
        prepareAudio: () async => '/unused',
        cancellation: token,
        delay: (_) async {
          token.cancel();
        },
      ),
      throwsA(isA<DioException>()),
    );
    expect(job['remoteId'], 'task');
    dio.httpClientAdapter = FakeAdapter((_) => jsonBody({'status': 'FAILED'}));
    await expectLater(
      runMoss(
        dio: dio,
        job: job,
        persist: () async {},
        prepareAudio: () async => '/unused',
        cancellation: CancelToken(),
      ),
      throwsStateError,
    );
    expect(job['stage'], 'remote_failed');
  });

  for (final provider in SttProvider.values) {
    test(
      '${provider.name} jobs retain provider across settings changes and cleanup retry',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final api = SttNative();
        final bridge = NativeBridge(api: api);
        addTearDown(() async {
          await bridge.dispose();
          await db.close();
        });
        final requests = <String>[];
        var cleanupFails = true;
        final service = TranscriptionService(
          db,
          bridge,
          createClient: () {
            final dio = Dio();
            dio.httpClientAdapter = FakeAdapter((r) {
              expect(r.uri.toString().startsWith(provider.baseUrl), isTrue);
              expect(
                r.headers['Authorization'],
                'Bearer ${api.secrets[provider.secret]}',
              );
              requests.add('${r.method} ${r.path}');
              if (r.method == 'DELETE') {
                if (cleanupFails) {
                  cleanupFails = false;
                  return jsonBody({}, 503);
                }
                return jsonBody({}, 404);
              }
              if (provider == SttProvider.mossPro) return jsonBody(transcript);
              if (r.path.endsWith('/transcript')) {
                return jsonBody({
                  'tokens': [
                    {'text': 'Hello.', 'start_ms': 250, 'end_ms': 1500},
                  ],
                });
              }
              return jsonBody({'status': 'completed'});
            });
            return dio;
          },
        );
        final recording = Recording(
          id: 'r',
          title: '',
          path: '/unused',
          seconds: 2,
        );
        await db.insertRecording(recording);
        await db.put('job:r', 'job', {
          'recordingId': 'r',
          'revision': 0,
          'stage': 'processing',
          if (provider == SttProvider.mossPro) 'provider': provider.name,
          'fileId': 'file',
          'remoteId': 'task',
        });
        final settings = AppSettings(
          sttProvider: provider == SttProvider.soniox
              ? SttProvider.mossPro
              : SttProvider.soniox,
        );
        await expectLater(
          service.run(recording, settings),
          throwsA(isA<DioException>()),
        );
        final updated = Recording.fromJson((await db.get('r'))!);
        expect(updated.segments.single.text, 'Hello.');
        expect((await db.get('job:r'))!['stage'], 'cleanup');
        requests.clear();
        await service.run(updated, settings);
        expect(requests.every((r) => r.startsWith('DELETE')), isTrue);
        if (provider == SttProvider.mossPro) {
          expect(requests, ['DELETE /files/file']);
        }
        expect(api.reads.toSet(), {provider.secret});
        expect(await db.get('job:r'), isNull);
      },
    );
  }

  test(
    'MOSS cleanup requires its own key and never accesses the network offline',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = SttNative()..secrets.remove('moss');
      final bridge = NativeBridge(api: api);
      addTearDown(() async {
        await bridge.dispose();
        await db.close();
      });
      final service = TranscriptionService(
        db,
        bridge,
        createClient: () => Dio()
          ..httpClientAdapter = FakeAdapter(
            (_) => throw StateError('unexpected_network'),
          ),
      );
      final r = Recording(id: 'r', title: '', path: '/unused', seconds: 1);
      await db.insertRecording(r);
      await db.put('job:r', 'job', {
        'recordingId': 'r',
        'revision': 0,
        'provider': 'mossPro',
        'stage': 'cleanup',
        'fileId': 'file',
        'remoteId': 'task',
      });
      await expectLater(
        service.run(r, const AppSettings()),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'moss_missing'),
        ),
      );
      api.reads.clear();
      await expectLater(
        service.run(r, const AppSettings(localOnly: true)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'online_required',
          ),
        ),
      );
      expect(api.reads, isEmpty);
      expect((await db.get('job:r'))!['stage'], 'cleanup');
    },
  );

  test(
    'MOSS respects local-only mode and never uses Soniox without its own key',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = SttNative()..secrets.remove('moss');
      final bridge = NativeBridge(api: api);
      addTearDown(() async {
        await bridge.dispose();
        await db.close();
      });
      final service = TranscriptionService(db, bridge);
      final r = Recording(id: 'r', title: '', path: '/unused', seconds: 1);
      await db.insertRecording(r);
      await expectLater(
        service.run(r, const AppSettings(sttProvider: SttProvider.mossPro)),
        throwsStateError,
      );
      expect(api.reads, ['moss']);
      api.reads.clear();
      await service.run(
        r,
        const AppSettings(sttProvider: SttProvider.mossPro, localOnly: true),
      );
      expect(api.reads, isEmpty);
      expect(
        Recording.fromJson((await db.get('r'))!).segments.single.text,
        'Local.',
      );
    },
  );

  test('MOSS completion cannot overwrite a revised recording', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = SttNative();
    final bridge = NativeBridge(api: api);
    addTearDown(() async {
      await bridge.dispose();
      await db.close();
    });
    final received = Completer<void>(), response = Completer<ResponseBody>();
    final service = TranscriptionService(
      db,
      bridge,
      createClient: () => Dio()
        ..httpClientAdapter = FakeAdapter((_) {
          received.complete();
          return response.future;
        }),
    );
    final r = Recording(id: 'r', title: '', path: '/unused', seconds: 1);
    await db.insertRecording(r);
    await db.put('job:r', 'job', {
      'recordingId': 'r',
      'revision': 0,
      'provider': 'mossPro',
      'stage': 'processing',
      'fileId': 'file',
      'remoteId': 'task',
    });
    final work = service.run(r, const AppSettings());
    await received.future;
    await db.replaceIfCurrent('r', 0, {
      ...r.toJson(),
      'revision': 1,
      'title': 'edited',
    });
    response.complete(jsonBody(transcript));
    await work;
    expect((await db.get('r'))!['title'], 'edited');
    expect((await db.get('r'))!['segments'], isEmpty);
    expect(await db.get('source:r:0'), isNull);
  });
}
