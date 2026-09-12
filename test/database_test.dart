import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:phrayo/data/database.dart';
import 'package:phrayo/core/models.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());
  test(
    'stale result cannot overwrite a newer revision or resurrect deletion',
    () async {
      await db.put('a', 'recording', {'revision': 0, 'title': 'old'});
      expect(
        await db.replaceIfCurrent('a', 0, {'revision': 1, 'title': 'new'}),
        true,
      );
      expect(
        await db.replaceIfCurrent('a', 0, {'revision': 1, 'title': 'stale'}),
        false,
      );
      await db.remove('a');
      expect(
        await db.replaceIfCurrent('a', 1, {'title': 'resurrected'}),
        false,
      );
      expect(await db.get('a'), null);
    },
  );
  test(
    'native recovery is idempotent and does not overwrite processed content',
    () async {
      final r = Recording(
        id: 'r',
        title: 'recording',
        path: '/audio',
        seconds: 2,
      );
      await db.insertRecording(r);
      await db.replaceIfCurrent('r', 0, {
        ...r.toJson(),
        'title': 'edited',
        'revision': 1,
      });
      await db.insertRecording(r);
      expect((await db.get('r'))!['title'], 'edited');
    },
  );
  test(
    'recording deletion preserves saved text while unlinking audio',
    () async {
      final r = Recording(id: 'r', title: 'test', path: '/audio', seconds: 5);
      final phrase = Expression(
        id: 'p',
        source: '你好',
        target: 'Hello',
        recordingId: 'r',
        audioPath: '/audio',
      );
      await db.insertRecording(r);
      await db.put('p', 'expression', phrase.toJson());
      await db.deleteRecording('r');
      final saved = await db.get('p');
      expect(saved!['source'], '你好');
      expect(saved['recordingId'], null);
      expect(saved['audioPath'], null);
    },
  );
  test(
    'delayed native recovery cannot resurrect a deleted recording',
    () async {
      final r = Recording(id: 'r', title: '', path: '/audio', seconds: 1);
      await db.insertRecording(r);
      await db.deleteRecording(r.id);
      await db.insertRecording(r);
      expect(await db.get(r.id), null);
    },
  );
}
