import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';

import 'test_repository.dart';

RecordingSession _session(String id, String filePath, DateTime startedAt) =>
    RecordingSession(
      id: id,
      filePath: filePath,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(minutes: 1)),
      markers: const <BarcodeMarker>[],
    );

void main() {
  test('历史查询会解析失效路径并修复数据库', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'path_repair_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final File file = File(
      '${root.path}${Platform.pathSeparator}recordings'
      '${Platform.pathSeparator}2026-08-06${Platform.pathSeparator}abc.mp4',
    );
    await file.create(recursive: true);
    final SessionRepository repository = testRepository(root);
    await repository.addSession(
      _session(
        's1',
        '/data/data/pkg/app_flutter/recordings/2026-08-06/abc.mp4',
        DateTime(2026, 8, 6, 9),
      ),
    );

    final List<RecordingSession> startupMetadata = await repository
        .loadRecentSessionMetadata();
    expect(startupMetadata, hasLength(1));
    expect(
      startupMetadata.single.filePath,
      '/data/data/pkg/app_flutter/recordings/2026-08-06/abc.mp4',
      reason: '摄像头启动不得逐文件探测或提前修复路径',
    );

    final LocalRecordingPage result = await repository.querySessions(
      page: 1,
      pageSize: 10,
    );

    expect(result.data, hasLength(1));
    expect(result.data.single.filePath, file.path);

    // 数据库已修复，再次查询直接命中。
    final LocalRecordingPage second = await repository.querySessions(
      page: 1,
      pageSize: 10,
    );
    expect(second.data.single.filePath, file.path);

    // 直接读取数据库文件，确认 file_path 已持久化修复。
    final Database database = await openDatabase(
      p.join(root.path, 'recordings.db'),
    );
    final List<Map<String, Object?>> rows = await database.query(
      'recording_sessions',
      columns: <String>['file_path'],
      where: 'id = ?',
      whereArgs: <Object?>['s1'],
    );
    await database.close();
    expect(rows.single['file_path'], file.path);
  });

  test('文件真实缺失时保留原路径且不进入可播放列表', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'path_repair_missing_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);
    await repository.addSession(
      _session(
        's2',
        '/data/user/0/pkg/app_flutter/recordings/2026-08-06/gone.mp4',
        DateTime(2026, 8, 6, 10),
      ),
    );

    final LocalRecordingPage result = await repository.querySessions(
      page: 1,
      pageSize: 10,
    );
    expect(
      result.data.single.filePath,
      '/data/user/0/pkg/app_flutter/recordings/2026-08-06/gone.mp4',
    );

    final List<RecordingSession> loaded = await repository.loadSessions();
    expect(loaded, isEmpty);
  });
}
