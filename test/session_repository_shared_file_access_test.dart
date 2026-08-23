import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File source;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'packing-proof-shared-access-',
    );
    source = File('${root.path}/recordings/legacy.mp4');
    await source.create(recursive: true);
    await source.writeAsBytes(<int>[2, 3, 5, 7]);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('迁移暂停时删除规范化路径别名记录仍保留唯一原片', () async {
    await _seedSharedSessions(root, <String>[
      source.path,
      '${source.parent.path}/./legacy.mp4',
    ]);
    final SessionRepository repository = SessionRepository(
      rootDirectory: root,
      availableRecordingStorageBytes: () async => 1 << 50,
    );
    addTearDown(repository.dispose);

    await repository.deleteSessions(<String>{'legacy-0'});

    expect(await source.exists(), isTrue);
    expect(await source.readAsBytes(), <int>[2, 3, 5, 7]);
    expect(
      (await repository.findActiveSessionsByIds(<String>{
        'legacy-1',
      })).single.id,
      'legacy-1',
    );
  });

  test('备份增量入口先把旧共享记录物化为独立文件', () async {
    await _seedSharedSessions(root, <String>[source.path, source.path]);
    final SessionRepository repository = SessionRepository(
      rootDirectory: root,
      availableRecordingStorageBytes: () async => 1 << 50,
    );
    addTearDown(repository.dispose);
    await repository.resumeSharedFileMigration();
    final BackupRegistrationCursor highWatermark = (await repository
        .loadBackupRegistrationHighWatermark())!;

    final BackupIncrementPage page = (await repository.loadBackupIncrement(
      after: null,
      highWatermark: highWatermark,
    ))!;

    expect(page.sessions, hasLength(2));
    expect(
      page.sessions.map((RecordingSession value) => value.filePath).toSet(),
      hasLength(2),
    );
    for (final RecordingSession session in page.sessions) {
      expect(await File(session.filePath).readAsBytes(), <int>[2, 3, 5, 7]);
    }
  });

  test('备份物化空间不足时类型化失败且不推进为共享路径任务', () async {
    await _seedSharedSessions(root, <String>[source.path, source.path]);
    final SessionRepository repository = SessionRepository(
      rootDirectory: root,
      availableRecordingStorageBytes: () async => 2 * 1024 * 1024 * 1024,
    );
    addTearDown(repository.dispose);
    await repository.resumeSharedFileMigration();
    final BackupRegistrationCursor highWatermark = (await repository
        .loadBackupRegistrationHighWatermark())!;

    await expectLater(
      repository.loadBackupIncrement(after: null, highWatermark: highWatermark),
      throwsA(
        isA<RecordingFilePreparationException>().having(
          (RecordingFilePreparationException value) => value.failure,
          'failure',
          RecordingFilePreparationFailure.storageUnavailable,
        ),
      ),
    );
    expect(await source.readAsBytes(), <int>[2, 3, 5, 7]);
    expect(
      await source.parent
          .list()
          .where((FileSystemEntity value) => value.path.contains('_独立_'))
          .isEmpty,
      isTrue,
    );
  });
}

Future<void> _seedSharedSessions(Directory root, List<String> paths) async {
  final SessionRepository created = SessionRepository(
    rootDirectory: root,
    sharedFileMigrationAllowed: () => false,
  );
  await created.initialize();
  await created.dispose();
  final Database database = await databaseFactory.openDatabase(
    '${root.path}/recordings.db',
    options: OpenDatabaseOptions(singleInstance: false),
  );
  final DateTime startedAt = DateTime.utc(2026, 8, 23, 8);
  await database.transaction((Transaction txn) async {
    await txn.delete(
      'recording_metadata',
      where: 'key IN (?, ?, ?)',
      whereArgs: const <Object?>[
        'shared_file_materialization_v1',
        'shared_file_materialization_cursor_v1',
        'recording_file_owners_ready_v1',
      ],
    );
    await txn.delete('recording_file_owners');
    for (var index = 0; index < paths.length; index++) {
      final RecordingSession session = RecordingSession(
        id: 'legacy-$index',
        filePath: paths[index],
        startedAt: startedAt.add(Duration(seconds: index)),
        endedAt: startedAt.add(Duration(seconds: index + 1)),
        markers: const <Never>[],
      );
      await txn.insert('recording_sessions', <String, Object?>{
        'id': session.id,
        'file_path': session.filePath,
        'started_at': session.startedAt.millisecondsSinceEpoch,
        'ended_at': session.endedAt.millisecondsSinceEpoch,
        'payload_json': jsonEncode(session.toJson()),
        'created_at': index + 1,
        'updated_at': index + 1,
      });
    }
  });
  await database.close();
}
