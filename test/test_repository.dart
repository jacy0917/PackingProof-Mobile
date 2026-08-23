import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';

SessionRepository testRepository(Directory root) {
  final SessionRepository repository = SessionRepository(rootDirectory: root);
  addTearDown(repository.dispose);
  return repository;
}

extension SessionRepositoryTestQueries on SessionRepository {
  Future<List<RecordingSession>> loadSessions({
    bool includeMissingFiles = false,
  }) async {
    final LocalRecordingPage first = await querySessions(
      page: 1,
      pageSize: 100,
    );
    final List<RecordingSession> sessions = <RecordingSession>[...first.data];
    LocalRecordingPage current = first;
    while (sessions.length < first.total && current.lastCursor != null) {
      current = await queryAdjacentSessions(
        page: current.page + 1,
        pageSize: 100,
        cursor: current.lastCursor!,
        direction: LocalRecordingPageDirection.older,
        knownTotal: first.total,
      );
      if (current.data.isEmpty) break;
      sessions.addAll(current.data);
    }
    if (includeMissingFiles) return sessions;
    return sessions
        .where(
          (RecordingSession session) => File(session.filePath).existsSync(),
        )
        .toList(growable: false);
  }
}

extension RecordingDatabaseTestQueries on RecordingDatabase {
  Future<List<RecordingSession>> loadActiveSessions() async {
    final LocalRecordingPage first = await queryActiveSessions(
      page: 1,
      pageSize: 100,
    );
    final List<RecordingSession> sessions = <RecordingSession>[...first.data];
    LocalRecordingPage current = first;
    while (sessions.length < first.total && current.lastCursor != null) {
      current = await queryAdjacentActiveSessions(
        page: current.page + 1,
        pageSize: 100,
        cursor: current.lastCursor!,
        direction: LocalRecordingPageDirection.older,
        knownTotal: first.total,
      );
      if (current.data.isEmpty) break;
      sessions.addAll(current.data);
    }
    return sessions;
  }
}
