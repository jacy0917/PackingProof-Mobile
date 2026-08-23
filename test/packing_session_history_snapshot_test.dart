import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/platform/platform_capabilities.dart';
import 'package:packing_proof_mobile/services/diagnostics_log_service.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';

import 'test_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('最近录像快照在无数据变化的五万次界面读取中保持同一实例', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-session-snapshot-',
    );
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 10);
    final RecordingSession original = RecordingSession(
      id: 'stable-session',
      filePath: '${root.path}/stable-session.mp4',
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 1)),
      markers: const <Never>[],
    );
    await repository.addSession(original);
    final PackingSessionController controller = _controller(root, repository);
    addTearDown(() async {
      await controller.shutdown();
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await controller.updateSession(original);
    final List<RecordingSession> stable = controller.sessions;
    for (var iteration = 0; iteration < 50000; iteration++) {
      expect(identical(controller.sessions, stable), isTrue);
    }
    expect(() => stable.add(original), throwsA(isA<UnsupportedError>()));

    final String updatedPath = '${root.path}/stable-session-updated.mp4';
    await controller.updateSession(original.copyWith(filePath: updatedPath));

    expect(identical(controller.sessions, stable), isFalse);
    expect(controller.sessions.single.filePath, updatedPath);
  });

  test('隐藏录像 ID 在一万和五万规模下仅于真实变更时生成新快照', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-hidden-recording-snapshot-',
    );
    final SessionRepository repository = testRepository(root);
    final PackingSessionController controller = _controller(root, repository);
    addTearDown(() async {
      await controller.shutdown();
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await controller.hideRemoteRecordings(<int>{
      for (var id = 0; id < 10000; id++) id,
    });
    final Set<int> tenThousand = controller.hiddenRemoteRecordingIds;
    for (var iteration = 0; iteration < 10000; iteration++) {
      expect(
        identical(controller.hiddenRemoteRecordingIds, tenThousand),
        isTrue,
      );
    }

    await controller.hideRemoteRecordings(<int>{
      for (var id = 10000; id < 50000; id++) id,
    });
    final Set<int> fiftyThousand = controller.hiddenRemoteRecordingIds;
    expect(identical(fiftyThousand, tenThousand), isFalse);
    expect(fiftyThousand, hasLength(50000));
    for (var iteration = 0; iteration < 50000; iteration++) {
      expect(
        identical(controller.hiddenRemoteRecordingIds, fiftyThousand),
        isTrue,
      );
    }
    expect(() => fiftyThousand.add(50000), throwsA(isA<UnsupportedError>()));
  });
}

PackingSessionController _controller(
  Directory root,
  SessionRepository repository,
) => PackingSessionController(
  repository: repository,
  speechService: _NoopSpeechSink(),
  capabilities: const PlatformCapabilities(<PlatformCapability>{}),
  runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
);

class _NoopSpeechSink implements SpeechPromptSink {
  @override
  bool get enabled => true;

  @override
  Future<void> setEnabled(bool value) async {}

  @override
  void enqueue(SpeechPrompt prompt, {String? incidentKey}) {}

  @override
  Future<void> preview() async {}

  @override
  void playShortBeep() {}

  @override
  void resetIncidents() {}

  @override
  void resolveIncident(String incidentKey) {}

  @override
  Future<void> clear() async {}

  @override
  Future<void> dispose() async {}
}
