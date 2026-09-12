import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../services/platform.dart';
import '../services/text_processor.dart';
import '../services/transcription.dart';
import 'transcription_terms.dart';
import 'models.dart';
import 'native.g.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
final nativeProvider = Provider<NativeBridge>((ref) {
  final bridge = NativeBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});
final sttClientProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: false,
    ),
  );
  ref.onDispose(dio.close);
  return dio;
});
final textProcessorProvider = Provider((ref) {
  final processor = TextProcessor(ref.watch(nativeProvider));
  ref.onDispose(processor.dio.close);
  return processor;
});
final transcriptionProvider = Provider(
  (ref) => TranscriptionService(
    ref.watch(databaseProvider),
    ref.watch(nativeProvider),
  ),
);
final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    return const AppSettings();
  }

  Future<void> load() async {
    final j = await ref.read(databaseProvider).get('settings');
    if (j != null) {
      final settings = AppSettings.fromJson(j);
      if (!j.containsKey('provider') && settings.provider != null) {
        await ref
            .read(textProcessorProvider)
            .credentials
            .migrateLegacy(settings.provider!);
      }
      state = settings;
    }
  }

  Future<void> save(AppSettings value) async {
    value = AppSettings.fromJson({
      ...value.toJson(),
      'transcriptionTerms': normalizeTranscriptionTerms(
        value.transcriptionTerms,
      ),
    });
    await ref
        .read(nativeProvider)
        .api
        .configure(
          value.source,
          value.target,
          value.localOnly,
          value.sttProvider.name,
          value.transcriptionTerms,
        );
    await ref
        .read(databaseProvider)
        .put('settings', 'settings', value.toJson());
    state = value;
  }
}

final expressionsProvider = StreamProvider<List<Expression>>(
  (ref) => ref
      .watch(databaseProvider)
      .watch('expression')
      .map(
        (rows) =>
            rows.map(Expression.fromJson).toList()
              ..sort((a, b) => b.created.compareTo(a.created)),
      ),
);
final recordingsProvider = StreamProvider<List<Recording>>(
  (ref) => ref
      .watch(databaseProvider)
      .watch('recording')
      .map(
        (rows) =>
            rows.map(Recording.fromJson).toList()
              ..sort((a, b) => b.created.compareTo(a.created)),
      ),
);
final jobsProvider = StreamProvider(
  (ref) => ref.watch(databaseProvider).watch('job'),
);
final sessionProvider = StreamProvider<SessionMessage>(
  (ref) => ref.watch(nativeProvider).sessions.stream,
);
final recoveryErrorProvider = NotifierProvider<RecoveryError, Object?>(
  RecoveryError.new,
);

class RecoveryError extends Notifier<Object?> {
  @override
  Object? build() => null;
  void set(Object? error) {
    state = error;
  }
}

final bootstrapProvider = FutureProvider<void>((ref) async {
  await ref.read(settingsProvider.notifier).load();
  final bridge = ref.read(nativeProvider);
  final db = ref.read(databaseProvider);
  Future<void> importSession(SessionMessage s) async {
    if (s.path == null || !['saved', 'interrupted'].contains(s.state)) return;
    await db.transaction(() async {
      final alreadyImported = await db.get(s.id) != null;
      await db.insertRecording(
        Recording(
          id: s.id,
          title: s.transcript.isEmpty ? '' : s.transcript,
          path: s.path!,
          seconds: s.seconds,
          sourceLanguage: s.sourceLanguage ?? "zh-CN",
          targetLanguage: s.targetLanguage ?? "en-US",
          state: s.state,
          translation: s.translation,
          segments: s.segments
              .map(
                (x) => Segment(
                  id: x.id,
                  text: x.text,
                  start: x.start,
                  end: x.end,
                  speaker: x.speaker,
                ),
              )
              .toList(),
        ),
      );
      if (!alreadyImported &&
          s.sttJobJson != null &&
          await db.get('job:${s.id}') == null &&
          await db.get(s.id) != null &&
          await db.get('deleted:${s.id}') == null) {
        await db.put('job:${s.id}', 'job', {
          ...Map<String, dynamic>.from(jsonDecode(s.sttJobJson!) as Map),
          'recordingId': s.id,
          'revision': 0,
        });
      }
    });
    await bridge.api.acknowledge(s.id);
  }

  final recovered = await bridge.api.recover();
  for (final s in recovered) {
    await importSession(s);
  }
  final errors = ref.read(recoveryErrorProvider.notifier);
  errors.set(null);
  // Older deletions removed the row before native cleanup. Their tombstones
  // still identify precisely which audio folders should be removed on retry.
  for (final deleted in await db.list('tombstone')) {
    try {
      await bridge.api.deleteAudio('${deleted['id']}/recording.m4a');
    } catch (error) {
      errors.set(error);
    }
  }
  final subscription = bridge.sessions.stream
      .asyncMap(importSession)
      .listen(
        (_) {},
        onError: (Object error, StackTrace stack) {
          errors.set(error);
        },
      );
  ref.onDispose(subscription.cancel);
  final current = await bridge.api.snapshot();
  if (current != null) bridge.sessionChanged(current);
});
