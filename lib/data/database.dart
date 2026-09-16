import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/models.dart' show Recording, encode;
part 'database.g.dart';

class Documents extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()();
  TextColumn get body => text()();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Documents])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(
        executor ??
            LazyDatabase(() async {
              final dir = await getApplicationSupportDirectory();
              return NativeDatabase.createInBackground(
                File(p.join(dir.path, 'phrayo.sqlite')),
              );
            }),
      );
  @override
  int get schemaVersion => 1;
  Future<void> put(
    String id,
    String kind,
    Map<String, dynamic> value, {
    int revision = 0,
  }) => into(documents).insertOnConflictUpdate(
    DocumentsCompanion.insert(
      id: id,
      kind: kind,
      body: jsonEncode(value),
      revision: Value(revision),
    ),
  );
  Future<void> insertRecording(Recording r) => transaction(() async {
    if (await get("deleted:${r.id}") != null) return;
    await into(documents).insert(
      DocumentsCompanion.insert(
        id: r.id,
        kind: 'recording',
        body: encode(r.toJson()),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  });

  Stream<List<Map<String, dynamic>>> watch(String kind) =>
      (select(documents)..where((t) => t.kind.equals(kind))).watch().map(
        (rows) => rows
            .map((r) => jsonDecode(r.body) as Map<String, dynamic>)
            .toList(),
      );
  Future<List<Map<String, dynamic>>> list(String kind) async {
    final rows = await (select(
      documents,
    )..where((t) => t.kind.equals(kind))).get();
    return rows.map((r) => jsonDecode(r.body) as Map<String, dynamic>).toList();
  }

  Future<void> removeExpression(String id) async => transaction(() async {
    await remove(id);
    for (final row in await list('practice')) {
      if (row['expressionId'] == id) await remove(row['id']);
    }
  });
  Future<Map<String, dynamic>?> get(String id) async {
    final row = await (select(
      documents,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : jsonDecode(row.body) as Map<String, dynamic>;
  }

  Future<bool> replaceIfCurrent(
    String id,
    int revision,
    Map<String, dynamic> body,
  ) async {
    return await (update(
          documents,
        )..where((t) => t.id.equals(id) & t.revision.equals(revision))).write(
          DocumentsCompanion(
            body: Value(encode(body)),
            revision: Value(revision + 1),
          ),
        ) ==
        1;
  }

  Future<void> editRecordingTranscript(Recording original, List<String> text) =>
      transaction(() async {
        if (text.length != original.segments.length ||
            text.isEmpty ||
            text.any((value) => value.trim().isEmpty)) {
          throw StateError('transcript_empty_passage');
        }
        final current = await get(original.id);
        if (current == null || current['revision'] != original.revision) {
          throw StateError('transcript_changed');
        }
        if (await get('job:${original.id}') != null) {
          throw StateError('transcript_job_pending');
        }
        final trimmed = text.map((value) => value.trim()).toList();
        if (List.generate(
          text.length,
          (i) => trimmed[i] == original.segments[i].text,
        ).every((same) => same)) {
          return;
        }
        final segments = List.generate(
          text.length,
          (i) => {...original.segments[i].toJson(), 'text': trimmed[i]},
        );
        final replaced = await replaceIfCurrent(
          original.id,
          original.revision,
          {
            ...original.toJson(),
            'title': trimmed.join(' '),
            'segments': segments,
            'translation': '',
            'googleTranslation': false,
            'summary': <dynamic>[],
            'revision': original.revision + 1,
          },
        );
        if (!replaced) throw StateError('transcript_changed');
        await put(
          'source:${original.id}:${original.revision}',
          'source',
          original.toJson(),
        );
      });

  Future<void> remove(String id) async {
    await (delete(documents)..where((t) => t.id.equals(id))).go();
  }

  Future<void> deleteRecording(String id) async => transaction(() async {
    await remove(id);
    await put("deleted:$id", "tombstone", {"id": id});
    await (delete(
      documents,
    )..where((t) => t.kind.equals("source") & t.id.like("source:$id:%"))).go();
    final phrases = await (select(
      documents,
    )..where((t) => t.kind.equals('expression'))).get();
    for (final row in phrases) {
      final data = jsonDecode(row.body) as Map<String, dynamic>;
      if (data['recordingId'] == id) {
        data['recordingId'] = null;
        data['audioPath'] = null;
        data.remove('sourceIds');
        data.remove('audioStart');
        data.remove('audioEnd');
        data['revision'] = row.revision + 1;
        await put(row.id, 'expression', data, revision: row.revision + 1);
      }
    }
    await remove('job:$id');
  });
  Future<void> clear() async {
    await (delete(
      documents,
    )..where((t) => t.kind.isNotValue("tombstone"))).go();
  }
}
