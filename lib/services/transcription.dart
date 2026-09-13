import 'dart:async';

import 'package:dio/dio.dart';

import '../core/models.dart';
import '../core/languages.dart';
import '../data/database.dart';
import 'platform.dart';
import 'moss.dart';

List<Segment> sonioxSegments(List<dynamic> tokens) {
  final result = <Segment>[];
  var text = '';
  double? start;
  double end = 0;
  String? speaker;
  void flush() {
    if (text.trim().isNotEmpty && start != null) {
      result.add(
        Segment(
          id: 'segment-${result.length}',
          text: text.trim(),
          start: start!,
          end: end,
          speaker: speaker,
        ),
      );
    }
    text = '';
    start = null;
  }

  for (final raw in tokens) {
    final token = Map<String, dynamic>.from(raw as Map);
    final word = token['text'] as String? ?? '';
    if (word.startsWith('<') || token['translation_status'] == 'translation') {
      continue;
    }
    if (token['start_ms'] is! num || token['end_ms'] is! num) continue;
    final who = token['speaker']?.toString();
    if (start != null &&
        (who != speaker ||
            ((token['start_ms'] as num).toDouble() / 1000 - end) > 1.5)) {
      flush();
    }
    speaker = who;
    start ??= (token['start_ms'] as num).toDouble() / 1000;
    end = (token['end_ms'] as num).toDouble() / 1000;
    text += word;
    if (RegExp(r'[。！？.!?]\s*$').hasMatch(word)) flush();
  }
  flush();
  return result;
}

class TranscriptionService {
  final AppDatabase db;
  final NativeBridge native;
  final Dio Function() createClient;
  final _active = <String, CancelToken>{};
  final _finished = <String, Completer<void>>{};
  TranscriptionService(this.db, this.native, {Dio Function()? createClient})
    : createClient =
          createClient ??
          (() => Dio(
            BaseOptions(
              baseUrl: 'https://api.soniox.com/v1',
              connectTimeout: const Duration(seconds: 25),
              receiveTimeout: const Duration(minutes: 2),
              followRedirects: false,
            ),
          ));
  void cancel(String id) => _active[id]?.cancel();

  Future<List<String>> matchingTasks(Dio dio, Map<String, dynamic> job) async {
    final matches = <String>[];
    String? cursor;
    final visited = <String>{};
    do {
      final response = await dio.get(
        '/transcriptions',
        queryParameters: {'limit': 100, 'cursor': ?cursor},
      );
      final rows = response.data['transcriptions'];
      if (rows is! List) throw StateError('invalid_response');
      for (final item in rows) {
        if (item['client_reference_id'] == job['reference'] &&
            job['reference'] != null) {
          if (item['id'] is! String) throw StateError('invalid_response');
          matches.add(item['id']);
        }
      }
      cursor = response.data['next_page_cursor'];
      if (cursor != null && !visited.add(cursor)) {
        throw StateError('invalid_response');
      }
    } while (cursor != null);
    return matches;
  }

  Future<void> cleanup(Dio dio, Map<String, dynamic> job) async {
    if (SttProvider.fromName(job['provider']) == SttProvider.mossPro) {
      if (job['fileId'] is String) {
        await dio.delete(
          '/files/${Uri.encodeComponent(job['fileId'])}',
          options: Options(
            validateStatus: (s) =>
                s != null && ((s >= 200 && s < 300) || s == 404),
          ),
        );
      }
      return;
    }
    final ids = <String>{if (job['remoteId'] is String) job['remoteId']};
    if (job['stage'] == 'submission_unknown') {
      ids.addAll(await matchingTasks(dio, job));
    }
    for (final id in ids) {
      await dio.delete(
        '/transcriptions/${Uri.encodeComponent(id)}',
        options: Options(
          validateStatus: (s) =>
              s != null && ((s >= 200 && s < 300) || s == 404),
        ),
      );
    }
    if (job['fileId'] is String) {
      await dio.delete(
        '/files/${Uri.encodeComponent(job['fileId'])}',
        options: Options(
          validateStatus: (s) =>
              s != null && ((s >= 200 && s < 300) || s == 404),
        ),
      );
    }
  }

  Future<void> run(Recording recording, AppSettings settings) async {
    if (_active.containsKey(recording.id)) return;
    final cancellation = CancelToken(), done = Completer<void>();
    _active[recording.id] = cancellation;
    _finished[recording.id] = done;
    final jobId = 'job:${recording.id}', dio = createClient();
    Map<String, dynamic>? job;
    Future<bool> alive() async {
      final current = await db.get(recording.id);
      return !cancellation.isCancelled &&
          current != null &&
          current['revision'] == recording.revision;
    }

    Future<void> persist() async {
      await db.put(jobId, 'job', job!);
    }

    try {
      job =
          await db.get(jobId) ??
          {
            'recordingId': recording.id,
            'provider': settings.sttProvider.name,
            'transcriptionTerms': List<String>.of(settings.transcriptionTerms),
            if (settings.sttProvider == SttProvider.mossPro) 'model': mossModel,
            'revision': recording.revision,
            'stage': 'pending',
            'reference': 'phrayo:${recording.id}:${recording.revision}',
          };
      if (!await alive()) return;
      await persist();
      final provider = SttProvider.fromName(job['provider']);
      dio.options.baseUrl = provider.baseUrl;
      final key = settings.localOnly
          ? null
          : await native.api.readSecret(provider.secret);
      if (job['stage'] == 'cleanup') {
        if (settings.localOnly) throw StateError('online_required');
        if (key == null || key.isEmpty) {
          throw StateError('${provider.secret}_missing');
        }
        dio.options.headers['Authorization'] = 'Bearer $key';
        await cleanup(dio, job);
        await db.remove(jobId);
        return;
      }
      if (job['revision'] != recording.revision) {
        throw StateError('submission_unknown');
      }
      List<Segment> segments;
      if (settings.localOnly &&
          (job['fileId'] != null ||
              job['remoteId'] != null ||
              [
                'submission_unknown',
                'upload_unknown',
              ].contains(job['stage']))) {
        throw StateError('online_required');
      }
      if (!settings.localOnly && provider == SttProvider.mossPro) {
        if (key == null || key.isEmpty) throw StateError('moss_missing');
        dio.options.headers['Authorization'] = 'Bearer $key';
        segments = await runMoss(
          dio: dio,
          job: job,
          persist: persist,
          prepareAudio: () => native.api.prepareAudio(recording.path),
          cancellation: cancellation,
        );
      } else if (key == null || key.isEmpty) {
        if (job['remoteId'] != null ||
            job['fileId'] != null ||
            ['submission_unknown', 'upload_unknown'].contains(job['stage'])) {
          throw StateError('online_required');
        }
        final result = await native.api.transcribe(
          recording.path,
          recording.sourceLanguage,
          (job['transcriptionTerms'] as List? ?? const []).cast<String>(),
        );
        segments = result
            .map(
              (s) => Segment(
                id: s.id,
                text: s.text,
                start: s.start,
                end: s.end,
                speaker: s.speaker,
              ),
            )
            .toList();
      } else {
        dio.options.headers['Authorization'] = 'Bearer $key';
        if (job['stage'] == 'submission_unknown') {
          final matches = await matchingTasks(dio, job);
          if (matches.length != 1) throw StateError('submission_unknown');
          job['remoteId'] = matches.single;
          job['stage'] = 'processing';
          await persist();
        }
        if (job['fileId'] == null) {
          job['stage'] = 'uploading';
          await persist();
          // Upload filename is unique to this app record. Never use a display title.
          final audioPath = await native.api.prepareAudio(recording.path);
          final upload = await dio.post(
            '/files',
            data: FormData.fromMap({
              'file': await MultipartFile.fromFile(
                audioPath,
                filename: 'phrayo-${recording.id}.m4a',
              ),
            }),
            cancelToken: cancellation,
          );
          job['fileId'] = upload.data['id'];
          if (job['fileId'] is! String) throw StateError('invalid_response');
          job['stage'] = 'uploaded';
          await persist();
        }
        if (!await alive()) return;
        if (job['remoteId'] == null) {
          job['stage'] = 'submission_unknown';
          await persist();
          final response = await dio.post(
            '/transcriptions',
            data: {
              'model': 'stt-async-v5',
              'file_id': job['fileId'],
              'client_reference_id': job['reference'],
              'enable_speaker_diarization': true,
              'enable_language_identification': true,
              'language_hints': [sonioxLanguageCode(recording.sourceLanguage)],
              if (sonioxContext(
                recording.sourceLanguage,
                (job['transcriptionTerms'] as List? ?? const []).cast<String>(),
              ).isNotEmpty)
                'context': sonioxContext(
                  recording.sourceLanguage,
                  (job['transcriptionTerms'] as List? ?? const [])
                      .cast<String>(),
                ),
            },
            cancelToken: cancellation,
          );
          job['remoteId'] = response.data['id'];
          if (job['remoteId'] is! String) throw StateError('invalid_response');
          job['stage'] = 'processing';
          await persist();
        }
        while (await alive()) {
          final response = await dio.get(
            '/transcriptions/${Uri.encodeComponent(job['remoteId'])}',
            cancelToken: cancellation,
          );
          if (response.data['status'] == 'completed') break;
          if (response.data['status'] == 'error') {
            throw StateError('transcription_failed');
          }
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        if (!await alive()) return;
        final response = await dio.get(
          '/transcriptions/${Uri.encodeComponent(job['remoteId'])}/transcript',
          cancelToken: cancellation,
        );
        segments = sonioxSegments(response.data['tokens'] as List);
      }
      if (!await alive()) return;
      if (segments.isEmpty) throw StateError('no_speech');
      final body = {
        ...recording.toJson(),
        'segments': segments.map((s) => s.toJson()).toList(),
        'revision': recording.revision + 1,
        'state': 'transcribed',
        'summary': <dynamic>[],
        'translation': '',
        'translationStyle': TranslationStyle.standard.name,
      };
      await db.transaction(() async {
        if (!await alive()) return;
        await db.put(
          'source:${recording.id}:${recording.revision}',
          'source',
          recording.toJson(),
        );
        await db.replaceIfCurrent(recording.id, recording.revision, body);
        if (job!['fileId'] != null) {
          job['stage'] = 'cleanup';
          await persist();
        }
      });
      if (job['fileId'] != null) await cleanup(dio, job);
      await db.remove(jobId);
    } catch (error) {
      if (job != null) {
        job['error'] = 'processing_failed';
        await persist();
      }
      if (!cancellation.isCancelled) rethrow;
    } finally {
      _active.remove(recording.id);
      _finished.remove(recording.id);
      done.complete();
      dio.close();
    }
  }

  Future<void> discardJob(String id, AppSettings settings) async {
    cancel(id);
    await _finished[id]?.future;
    final job = await db.get('job:$id');
    if (job == null) return;
    if (job['fileId'] == null &&
        !['submission_unknown', 'upload_unknown'].contains(job['stage'])) {
      await db.remove('job:$id');
      return;
    }
    if (settings.localOnly) throw StateError('online_required');
    final provider = SttProvider.fromName(job['provider']);
    final key = await native.api.readSecret(provider.secret);
    if (key == null || key.isEmpty) {
      throw StateError('${provider.secret}_missing');
    }
    final dio = createClient();
    dio.options.baseUrl = provider.baseUrl;
    dio.options.headers['Authorization'] = 'Bearer $key';
    try {
      await cleanup(dio, job);
      await db.remove('job:$id');
    } finally {
      dio.close();
    }
  }
}
