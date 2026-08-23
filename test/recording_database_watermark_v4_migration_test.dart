import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  test('备份 keyset 兼容 Android API 24 且保留索引范围锚点', () async {
    final String source = await File(
      'lib/services/recording_database.dart',
    ).readAsString();
    expect(source, isNot(contains('(updated_at, id) >')));
    expect(source, isNot(contains('(updated_at, id) <')));
    expect(source, contains('updated_at >= ?'));
    expect(source, contains('(updated_at > ? OR id > ?)'));
    expect(source, contains('updated_at <= ?'));
    expect(source, contains('(updated_at < ? OR id <= ?)'));
  });

  test('schema v3 的五万行数据库升级后补齐索引并有界恢复水印', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-watermark-v4-upgrade-',
    );
    final String path = '${root.path}/recordings.db';
    final File interruptedSource = File('${root.path}/session-49999.mp4');
    const List<int> interruptedBytes = <int>[9, 8, 7, 6, 5];
    await interruptedSource.writeAsBytes(interruptedBytes);
    final Database legacy = await openDatabase(
      path,
      version: 3,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE recording_sessions (
            id TEXT PRIMARY KEY,
            file_path TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            ended_at INTEGER NOT NULL,
            tracking_number TEXT NOT NULL DEFAULT '',
            order_id TEXT NOT NULL DEFAULT '',
            search_text TEXT NOT NULL DEFAULT '',
            payload_json TEXT NOT NULL,
            file_size_bytes INTEGER NOT NULL DEFAULT 0,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            deleted_at INTEGER,
            delete_reason TEXT NOT NULL DEFAULT '',
            missing_at INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            recording_orientation TEXT NOT NULL DEFAULT 'portrait',
            watermark_status TEXT NOT NULL DEFAULT 'completed',
            watermark_attempt_count INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE recording_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
    const int rowCount = 50000;
    for (var start = 0; start < rowCount; start += 1000) {
      final Batch batch = legacy.batch();
      for (var index = start; index < start + 1000; index++) {
        final String id = 'session-${index.toString().padLeft(5, '0')}';
        final String status = index == rowCount - 1
            ? 'processing'
            : switch (index % 3) {
                0 => 'completed',
                1 => 'failed',
                _ => 'pending',
              };
        final int timestamp = 1700000000000 + index;
        batch.insert('recording_sessions', <String, Object?>{
          'id': id,
          'file_path': '${root.path}/$id.mp4',
          'started_at': timestamp,
          'ended_at': timestamp + 1000,
          'payload_json': jsonEncode(<String, Object?>{
            'id': id,
            'filePath': '${root.path}/$id.mp4',
            'startedAt': DateTime.fromMillisecondsSinceEpoch(
              timestamp,
              isUtc: true,
            ).toIso8601String(),
            'endedAt': DateTime.fromMillisecondsSinceEpoch(
              timestamp + 1000,
              isUtc: true,
            ).toIso8601String(),
            'markers': <Object?>[],
            'watermarkStatus': status,
          }),
          'created_at': timestamp,
          'updated_at': timestamp,
          'watermark_status': status,
          'watermark_attempt_count': status == 'processing' ? 1 : 0,
        });
      }
      await batch.commit(noResult: true);
    }
    await legacy.close();

    var indexesExistedBeforeRecovery = false;
    final RecordingDatabase database = RecordingDatabase(
      path: path,
      watermarkOwnerIdForTesting: 'new-process',
      startSharedFileMigrationWorker: false,
      beforeInterruptedWatermarkRecoveryForTesting: (Database db) async {
        final List<Map<String, Object?>> rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name IN ('idx_recording_backup_cursor', "
          "'idx_recording_pending_watermark')",
        );
        indexesExistedBeforeRecovery = rows.length == 2;
      },
    );
    addTearDown(() async {
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    await database.initialize();
    expect(indexesExistedBeforeRecovery, isTrue);

    final Database inspected = await openDatabase(
      path,
      readOnly: true,
      singleInstance: false,
    );
    final List<Map<String, Object?>> indexes = await inspected.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND name IN ('idx_recording_backup_cursor', "
      "'idx_recording_pending_watermark') ORDER BY name",
    );
    final Set<String> columns = (await inspected.rawQuery(
      'PRAGMA table_info(recording_sessions)',
    )).map((Map<String, Object?> row) => row['name']! as String).toSet();
    final int retainedRows =
        Sqflite.firstIntValue(
          await inspected.rawQuery('SELECT COUNT(*) FROM recording_sessions'),
        ) ??
        0;
    await inspected.close();
    expect(indexes.map((Map<String, Object?> row) => row['name']), <String>[
      'idx_recording_backup_cursor',
      'idx_recording_pending_watermark',
    ]);
    expect(
      columns,
      containsAll(<String>{
        'watermark_owner_id',
        'watermark_operation_id',
        'watermark_claimed_at',
      }),
    );
    expect(retainedRows, rowCount);

    final List<RecordingBackupRow> backup = await database.queryBackupRows(
      afterUpdatedAt: null,
      afterId: null,
      highUpdatedAt: null,
      highId: null,
      pageSize: 2,
    );
    expect(backup, hasLength(2));
    final String backupPlan =
        (await database.explainBackupCursorQueryForTesting(
          afterUpdatedAt: backup.first.updatedAt,
          afterId: backup.first.id,
        )).join('\n');
    expect(backupPlan, contains('idx_recording_backup_cursor'));
    expect(backupPlan, isNot(contains('SCAN recording_sessions')));

    final String pendingPlan =
        (await database.explainPendingWatermarkQueryForTesting()).join('\n');
    expect(pendingPlan, contains('idx_recording_pending_watermark'));
    expect(pendingPlan, isNot(contains('SCAN recording_sessions')));

    final String recoveryPlan =
        (await database.explainWatermarkRecoveryQueryForTesting()).join('\n');
    expect(recoveryPlan, contains('idx_recording_pending_watermark'));
    expect(recoveryPlan, isNot(contains('SCAN recording_sessions')));
    expect(
      (await database.findActiveByIds(<String>{
        'session-49999',
      })).single.watermarkStatus.name,
      'failed',
    );
    expect(
      (await database.findActiveByIds(<String>{
        'session-49999',
      })).single.filePath,
      interruptedSource.path,
    );
    expect(await interruptedSource.readAsBytes(), interruptedBytes);
    final List<RecordingBackupRow> recovered = await database.queryBackupRows(
      afterUpdatedAt: 1700000050000,
      afterId: '',
      highUpdatedAt: null,
      highId: null,
      pageSize: 2,
    );
    expect(
      recovered.any((RecordingBackupRow row) => row.id == 'session-49999'),
      isTrue,
    );
  });

  test('schema v4 同版本数据库缺失索引时初始化会在恢复前自修复', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-watermark-v4-repair-',
    );
    final String path = '${root.path}/recordings.db';
    final RecordingDatabase created = RecordingDatabase(
      path: path,
      startSharedFileMigrationWorker: false,
    );
    await created.initialize();
    await created.close();
    final Database damaged = await openDatabase(path, singleInstance: false);
    await damaged.execute('DROP INDEX idx_recording_backup_cursor');
    await damaged.execute('DROP INDEX idx_recording_pending_watermark');
    await damaged.close();

    var repairedBeforeRecovery = false;
    final RecordingDatabase reopened = RecordingDatabase(
      path: path,
      startSharedFileMigrationWorker: false,
      beforeInterruptedWatermarkRecoveryForTesting: (Database db) async {
        final List<Map<String, Object?>> rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name IN ('idx_recording_backup_cursor', "
          "'idx_recording_pending_watermark')",
        );
        repairedBeforeRecovery = rows.length == 2;
      },
    );
    addTearDown(() async {
      await reopened.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    await reopened.initialize();
    expect(repairedBeforeRecovery, isTrue);
  });
}
