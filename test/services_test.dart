import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phrayo/core/providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/core/native.g.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/services/platform.dart';
import 'package:phrayo/services/text_processor.dart';
import 'package:phrayo/services/transcription.dart';

class FakeNative extends PhrayoNative {
  String? key;
  final transcription = Completer<List<SegmentMessage>>();
  final requested = Completer<void>();
  @override
  Future<String?> readSecret(String service) async => key;
  @override
  Future<List<SegmentMessage>> transcribe(
    String path,
    String source,
    List<String> transcriptionTerms,
  ) {
    requested.complete();
    return transcription.future;
  }
}

class RecoveryNative extends PhrayoNative {
  final removed = <String>[];
  @override
  Future<List<SessionMessage>> recover() async => [];
  @override
  Future<SessionMessage?> snapshot() async => null;
  @override
  Future<void> deleteAudio(String path) async {
    removed.add(path);
  }
}

class FakeAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) handler;
  FakeAdapter(this.handler);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object value, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'SSE handles fragmented UTF-8 and terminal event without final blank line',
    () async {
      final data = utf8.encode(
        'data: {"choices":[{"delta":{"content":"你好"}}]}\n\ndata: [DONE]',
      );
      final output = await chatText(Stream.fromIterable(data.map((b) => [b])))
          .toList();
      expect(output, ['你好']);
    },
  );
  test(
    'SSE rejects an interrupted stream instead of committing truncated text',
    () async {
      final stream = chatText(
        Stream.value(
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
          ),
        ),
      );
      await expectLater(
        stream,
        emitsInOrder(['partial', emitsError(isA<StateError>())]),
      );
    },
  );
  test(
    'deleted recording is not recreated by local transcription completion',
    () async {
      final db = AppDatabase(NativeDatabase.memory()),
          api = FakeNative(),
          bridge = NativeBridge(api: FakeNative());
      final realBridge = NativeBridge(api: api);
      final service = TranscriptionService(db, realBridge);
      final r = Recording(id: 'r', title: '', path: '/audio', seconds: 1);
      await db.insertRecording(r);
      final work = service.run(r, const AppSettings(localOnly: true));
      await api.requested.future;
      await db.deleteRecording('r');
      api.transcription.complete([
        SegmentMessage(id: 's', text: 'Hi', start: 0, end: 1),
      ]);
      await work;
      expect(await db.get('r'), null);
      expect(await db.get('source:r:0'), null);
      await bridge.dispose();
      await realBridge.dispose();
      await db.close();
    },
  );
  test('cleanup failure resumes cleanup without rerunning or overwriting a transcript', () async {
    final db = AppDatabase(NativeDatabase.memory()),
        api = FakeNative()..key = 'test-key';
    final bridge = NativeBridge(api: api);
    final paths = <String>[];
    var fail = true;
    Dio client() {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      dio.httpClientAdapter = FakeAdapter((request) {
        paths.add('${request.method} ${request.path}');
        if (request.method == 'DELETE') {
          if (fail) {
            fail = false;
            return jsonBody({}, 503);
          }
          return jsonBody({});
        }
        if (request.path.endsWith('/transcript')) {
          return jsonBody({
            'tokens': [
              {'text': 'Hello.', 'start_ms': 0, 'end_ms': 1000},
            ],
          });
        }
        return jsonBody({'status': 'completed'});
      });
      return dio;
    }

    final service = TranscriptionService(db, bridge, createClient: client),
        r = Recording(id: 'r', title: '', path: '/unused', seconds: 1);
    await db.insertRecording(r);
    await db.put('job:r', 'job', {
      'recordingId': 'r',
      'revision': 0,
      'remoteId': 'remote',
      'fileId': 'file',
      'stage': 'processing',
    });
    await expectLater(
      service.run(r, const AppSettings()),
      throwsA(isA<DioException>()),
    );
    expect((await db.get('job:r'))!['stage'], 'cleanup');
    final updated = Recording.fromJson((await db.get('r'))!);
    expect(updated.segments.single.text, 'Hello.');
    paths.clear();
    await service.run(updated, const AppSettings());
    expect(paths.every((p) => p.startsWith('DELETE')), true);
    expect(await db.get('job:r'), null);
    expect((await db.get('r'))!['revision'], 1);
    await bridge.dispose();
    await db.close();
  });
  test(
    'startup retries audio cleanup for previously deleted records only',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = RecoveryNative();
      final native = NativeBridge(api: api);
      const deleted = 'AE82117A-24DB-4C2E-9721-7A59A812D634';
      await db.put('deleted:$deleted', 'tombstone', {'id': deleted});
      await db.insertRecording(
        Recording(id: 'retained', title: '', path: '/retained', seconds: 1),
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          nativeProvider.overrideWithValue(native),
        ],
      );
      await container.read(bootstrapProvider.future);
      expect(api.removed, ['$deleted/recording.m4a']);
      expect(await db.get('deleted:$deleted'), isNotNull);
      expect(await db.get('retained'), isNotNull);
      container.dispose();
      await native.dispose();
      await db.close();
    },
  );
}
