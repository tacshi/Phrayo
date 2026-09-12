import 'dart:io';

import 'package:dio/dio.dart';

import '../core/models.dart';

const mossModel = 'moss-transcribe-diarize-pro';
const legacyMossModel = 'moss-transcribe-diarize';
const mossVersion = 'v20260410-streamparam-20260703';
const mossMaxUploadBytes = 512 * 1024 * 1024;

List<Segment> mossSegments(Map<String, dynamic> payload) {
  double seconds(Object? value) {
    if (value is! num || !value.isFinite || value < 0) {
      throw StateError('invalid_response');
    }
    return value.toDouble();
  }

  final result = <Segment>[];
  final rows = payload['segments'];
  if (rows != null && rows is! List) throw StateError('invalid_response');
  for (final raw in (rows as List? ?? const [])) {
    if (raw is! Map || raw['text'] is! String) {
      throw StateError('invalid_response');
    }
    final text = (raw['text'] as String).trim();
    if (text.isEmpty) continue;
    final start = seconds(raw['start']), end = seconds(raw['end']);
    if (end < start) throw StateError('invalid_response');
    result.add(
      Segment(
        id: 'moss-${result.length}',
        text: text,
        start: start,
        end: end,
        speaker: raw['speaker']?.toString(),
      ),
    );
  }
  if (result.isEmpty &&
      payload['text'] is String &&
      (payload['text'] as String).trim().isNotEmpty) {
    result.add(
      Segment(
        id: 'moss-0',
        text: (payload['text'] as String).trim(),
        start: 0,
        end: seconds(payload['duration']),
      ),
    );
  }
  return result;
}

Future<void> validateSttKey(Dio dio, SttProvider provider, String key) async {
  final response = await dio.get(
    '${provider.baseUrl}/${provider == SttProvider.soniox ? 'files?limit=1' : 'models'}',
    options: Options(
      headers: {'Authorization': 'Bearer $key'},
      followRedirects: false,
    ),
  );
  if (provider == SttProvider.mossPro) {
    final data = response.data;
    if (data is! Map || data['data'] is! List) {
      throw StateError('invalid_response');
    }
    if (!(data['data'] as List).any((m) => m is Map && m['id'] == mossModel)) {
      throw StateError('moss_model_unavailable');
    }
  }
}

/// Mutates the durable job only at resumable boundaries. MOSS has no task-list
/// reconciliation API: an ambiguous submission must never be resubmitted.
Future<List<Segment>> runMoss({
  required Dio dio,
  required Map<String, dynamic> job,
  required Future<void> Function() persist,
  required Future<String> Function() prepareAudio,
  required CancelToken cancellation,
  Future<void> Function(Duration)? delay,
}) async {
  String id(Object? value) {
    if (value is! String || value.isEmpty) throw StateError('invalid_response');
    return value;
  }

  if (job['stage'] == 'submission_unknown' ||
      job['stage'] == 'upload_unknown') {
    throw StateError('moss_submission_unknown');
  }
  if (job['stage'] == 'remote_failed') {
    throw StateError('moss_transcription_failed');
  }
  if (job['fileId'] == null) {
    final path = await prepareAudio();
    if (await File(path).length() > mossMaxUploadBytes) {
      throw StateError('moss_file_too_large');
    }
    final form = FormData.fromMap({
      'purpose': 'audio',
      'file': await MultipartFile.fromFile(
        path,
        filename: 'phrayo-${job['recordingId']}.m4a',
      ),
    });
    if (cancellation.isCancelled) throw cancellation.cancelError!;
    job['stage'] = 'upload_unknown';
    await persist();
    final response = await dio.post(
      '/files',
      data: form,
      cancelToken: cancellation,
    );
    job['fileId'] = id(response.data['id']);
    job['stage'] = 'uploaded';
    await persist();
  }
  if (job['remoteId'] == null) {
    if (cancellation.isCancelled) throw cancellation.cancelError!;
    job['stage'] = 'submission_unknown';
    await persist();
    final response = await dio.post(
      '/audio/transcriptions',
      data: {
        'model': job['model'] ?? legacyMossModel,
        if (!job.containsKey('model')) 'version': mossVersion,
        if (job['version'] != null) 'version': job['version'],
        if ((job['transcriptionTerms'] as List? ?? const []).isNotEmpty)
          'keyterms': job['transcriptionTerms'],
        'file_id': job['fileId'],
        'diarize': true,
        'response_format': 'json',
        'async': true,
      },
      cancelToken: cancellation,
    );
    job['remoteId'] = id(response.data['task_id'] ?? response.data['id']);
    job['stage'] = 'processing';
    await persist();
  }
  while (true) {
    if (cancellation.isCancelled) throw cancellation.cancelError!;
    final response = await dio.get(
      '/audio/tasks/${Uri.encodeComponent(id(job['remoteId']))}',
      cancelToken: cancellation,
    );
    if (response.data is! Map) throw StateError('invalid_response');
    final data = Map<String, dynamic>.from(response.data as Map);
    final status = data['status']?.toString().toUpperCase();
    if (status == 'SUCCESS' || status == 'COMPLETED') return mossSegments(data);
    if (['FAILED', 'FAILURE', 'ERROR'].contains(status)) {
      job['stage'] = 'remote_failed';
      await persist();
      throw StateError('moss_transcription_failed');
    }
    if (!['PENDING', 'QUEUED', 'PROCESSING', 'RUNNING'].contains(status)) {
      throw StateError('invalid_response');
    }
    final retry = data['retry_after'];
    final duration = Duration(
      seconds: retry is num ? retry.toInt().clamp(1, 30) : 3,
    );
    await Future.any([
      (delay ?? Future<void>.delayed)(duration),
      cancellation.whenCancel,
    ]);
  }
}
