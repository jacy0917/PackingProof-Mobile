import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String databasePath;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'packing-proof-recording-local-history-scale-',
    );
    databasePath = '${root.path}/recordings.db';
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    '10000 条本地历史可用 keyset 到达深页并反向返回且命中时间索引',
    () async {
      final RecordingDatabase created = RecordingDatabase(path: databasePath);
      await created.initialize();
      await created.close();
      await _seedHistoryRows(databasePath, count: 10000);

      final RecordingDatabase database = RecordingDatabase(path: databasePath);
      addTearDown(database.close);
      await database.initialize();
      LocalRecordingPage page = await database.queryActiveSessions(
        page: 1,
        pageSize: 100,
      );
      expect(page.total, 10000);
      final List<String> plan = await database
          .explainActiveSessionCursorQueryForTesting(cursor: page.lastCursor!);
      expect(plan.join('\n'), contains('idx_recording_active_time'));

      for (var pageNumber = 2; pageNumber <= 100; pageNumber++) {
        page = await database.queryAdjacentActiveSessions(
          page: pageNumber,
          pageSize: 100,
          cursor: page.lastCursor!,
          direction: LocalRecordingPageDirection.older,
          knownTotal: page.total,
        );
      }
      expect(page.page, 100);
      expect(page.data.first.id, 'history-000099');
      expect(page.data.last.id, 'history-000000');

      final LocalRecordingPage previous = await database
          .queryAdjacentActiveSessions(
            page: 99,
            pageSize: 100,
            cursor: page.firstCursor!,
            direction: LocalRecordingPageDirection.newer,
            knownTotal: page.total,
          );
      expect(previous.data.first.id, 'history-000199');
      expect(previous.data.last.id, 'history-000100');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('50000 条本地历史 keyset 全量遍历无重复遗漏', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    await _seedHistoryRows(databasePath, count: 50000);

    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    await database.initialize();
    LocalRecordingPage page = await database.queryActiveSessions(
      page: 1,
      pageSize: 1000,
    );
    final Set<String> ids = <String>{};
    var pageNumber = 1;
    while (page.data.isNotEmpty) {
      for (final RecordingSession session in page.data) {
        expect(ids.add(session.id), isTrue);
      }
      if (page.lastCursor == null) break;
      pageNumber++;
      page = await database.queryAdjacentActiveSessions(
        page: pageNumber,
        pageSize: 1000,
        cursor: page.lastCursor!,
        direction: LocalRecordingPageDirection.older,
        knownTotal: page.total,
      );
    }

    expect(ids, hasLength(50000));
    expect(ids, containsAll(<String>['history-000000', 'history-049999']));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> _seedHistoryRows(String path, {required int count}) async {
  final Database db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  final DateTime base = DateTime.utc(2026, 1, 1);
  for (var start = 0; start < count; start += 5000) {
    final Batch batch = db.batch();
    final int end = (start + 5000).clamp(0, count);
    for (var index = start; index < end; index++) {
      final String id = 'history-${index.toString().padLeft(6, '0')}';
      final RecordingSession session = RecordingSession(
        id: id,
        filePath: '/recordings/$id.mp4',
        // 每 5 条共享同一时间戳，覆盖复合游标的 id 次序与页边界。
        startedAt: base.add(Duration(seconds: index ~/ 5)),
        endedAt: base.add(Duration(seconds: index ~/ 5 + 1)),
        markers: const <Never>[],
      );
      batch.rawInsert(
        'INSERT INTO recording_sessions('
        'id,file_path,started_at,ended_at,payload_json,created_at,updated_at'
        ') VALUES(?,?,?,?,?,?,?)',
        <Object?>[
          id,
          session.filePath,
          session.startedAt.millisecondsSinceEpoch,
          session.endedAt.millisecondsSinceEpoch,
          jsonEncode(session.toJson()),
          index,
          index,
        ],
      );
    }
    await batch.commit(noResult: true);
  }
  await db.close();
}
