import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/order_info.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/platform/contracts/camera_platform.dart';
import 'package:packing_proof_mobile/platform/contracts/backup_platform.dart';
import 'package:packing_proof_mobile/platform/generated/platform_api.g.dart';
import 'package:packing_proof_mobile/platform/platform_capabilities.dart';
import 'package:packing_proof_mobile/services/camera_capability_policy.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';
import 'package:packing_proof_mobile/services/lan_backup_service.dart';
import 'package:packing_proof_mobile/services/max_volume_service.dart';
import 'package:packing_proof_mobile/services/order_info_receiver_service.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';
import 'package:packing_proof_mobile/services/video_watermark_service.dart';
import 'package:wakelock_plus_platform_interface/src/method_channel_wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'test_repository.dart';

class _FakeCameraPlatform implements CameraPlatform {
  bool fullSupported = false;
  int startWorkCalls = 0;
  int splitCalls = 0;
  int stopWorkCalls = 0;
  Completer<NativeRecordingStop>? pendingStop;
  String lastMode = 'unverified';
  String? lastPath;

  @override
  void Function(List<NativeBarcodeCandidate> candidates)? onBarcodeBatch;
  @override
  void Function(String message)? onError;
  @override
  void Function()? onStorageCritical;
  @override
  void Function(Map<Object?, Object?> results)? onProbeFinished;
  @override
  void Function(Map<Object?, Object?> info)? onRecordingFallback;

  @override
  Future<ContinuousCameraInitialization> initialize({
    String videoCodec = 'hevc',
    String recordingSpec = 'hd1080p30',
    String capabilityMode = 'unverified',
  }) async {
    return const ContinuousCameraInitialization(
      textureId: 1,
      previewWidth: 1920,
      previewHeight: 1080,
      sensorOrientation: 90,
      fps: 30,
      videoMime: 'video/hevc',
      flashAvailable: false,
      lensDirection: 'back',
      canSwitchCamera: false,
      cameraId: 'back0',
    );
  }

  @override
  Future<bool> ensurePermissions({required bool recordAudio}) async => true;

  @override
  Future<NativeRecordingStart> startWork(
    String path, {
    required bool recordAudio,
    required String trackingNumber,
  }) async {
    startWorkCalls++;
    lastPath = path;
    File(path).createSync(recursive: true);
    return NativeRecordingStart(path: path, startedAt: DateTime.now());
  }

  @override
  Future<NativeRecordingSplit> split(
    String nextPath, {
    required String trackingNumber,
  }) async {
    splitCalls++;
    final String completedPath = lastPath ?? '';
    await File(nextPath).create(recursive: true);
    lastPath = nextPath;
    final DateTime now = DateTime.now();
    return NativeRecordingSplit(
      completedPath: completedPath,
      nextPath: nextPath,
      completedStartedAt: now.subtract(const Duration(seconds: 1)),
      boundaryAt: now,
      watermarkDisposition: NativeWatermarkDisposition.completed,
    );
  }

  @override
  Future<NativeRecordingStop> stopWork() async {
    stopWorkCalls++;
    final Completer<NativeRecordingStop>? pending = pendingStop;
    if (pending != null) return pending.future;
    return NativeRecordingStop(
      path: lastPath ?? '',
      startedAt: DateTime.now(),
      endedAt: DateTime.now(),
      watermarkDisposition: NativeWatermarkDisposition.completed,
    );
  }

  @override
  Future<CameraDiagnosticsSnapshot?> getDiagnostics() async {
    return CameraDiagnosticsSnapshot(
      device: const <String, Object?>{},
      camera: const <String, Object?>{
        'cameraId': 'back0',
        'videoWidth': 1920,
        'videoHeight': 1080,
        'analysisWidth': 1280,
        'analysisHeight': 720,
        'videoMime': 'video/hevc',
        'recordingSpec': 'hd1080p30',
      },
    );
  }

  Map<String, Object?> _identity() => const <String, Object?>{
    'cameraId': 'back0',
    'videoSize': '1920x1080',
    'analysisSize': '1280x720',
    'codec': 'hevc',
    'spec': 'hd1080p30',
    'probeSchemaVersion': 1,
    'cameraPipelineVersion': 1,
  };

  Map<String, Object?> _phase(String phase, String outcome) =>
      <String, Object?>{
        'phase': phase,
        'outcome': outcome,
        'previewFrames': 30,
        'analysisFrames': 30,
        'encoderBuffers': 30,
      };

  @override
  Future<Map<Object?, Object?>?> probeSequence(
    String sequence, {
    required int budgetMs,
  }) async {
    final List<Map<String, Object?>> phases;
    if (sequence == 'alternating' || fullSupported) {
      phases = <Map<String, Object?>>[
        _phase('idle', 'configured'),
        _phase('record', 'configured'),
        _phase('idle', 'configured'),
        _phase('record', 'configured'),
        _phase('idle', 'configured'),
      ];
    } else {
      phases = <Map<String, Object?>>[
        _phase('idle', 'configured'),
        _phase('record', 'configure_failed'),
        _phase('idle', 'configured'),
        _phase('record', 'configure_failed'),
        _phase('idle', 'configured'),
      ];
    }
    return <Object?, Object?>{
      'sequence': sequence,
      'status': 'ok',
      'phases': phases,
      'identity': _identity(),
    };
  }

  @override
  Future<void> setCapabilityMode(String mode) async {
    lastMode = mode;
  }

  @override
  Future<void> setPairingScanEnabled(bool enabled) async {}
  @override
  Future<void> setWorkScanEnabled(bool enabled) async {}
  @override
  Future<void> setPreviewActive(bool active) async {}
  @override
  Future<bool> setTorchEnabled(bool enabled) async => false;
  @override
  Future<ContinuousCameraInitialization> switchCamera() => initialize();
  @override
  Future<List<NativeCameraLens>> listCameras() async => const [];
  @override
  Future<ContinuousCameraInitialization> switchToCamera(String cameraId) =>
      initialize();
  @override
  Future<void> dispose() async {}
}

class _FakeBackupPlatform implements BackupNativePlatform {
  int storageCheckCalls = 0;
  Completer<Map<Object?, Object?>?>? pendingStorageCheck;
  final BackupSummaryDto backupSummary = BackupSummaryDto(
    schemaVersion: 1,
    revision: 0,
    completedRevision: 0,
    cleanupHighWatermark: 0,
    deviceId: 'test-device',
    deviceName: '测试设备',
    totalCount: 0,
    pendingCount: 0,
    uploadingCount: 0,
    pausedCount: 0,
    completedCount: 0,
    failedCount: 0,
    waitingCleanupCount: 0,
    localDeletedCount: 0,
    unfinishedUploadedBytes: 0,
    unfinishedTotalBytes: 0,
  );

  @override
  void setSummaryListener(void Function(BackupSummaryDto summary)? listener) {}

  @override
  Future<BackupSummaryDto> summary() async => backupSummary;

  @override
  Future<BackupSummaryDto> initialize(Map<Object?, Object?> request) async =>
      backupSummary;

  @override
  Future<BackupJobsByPathsDto> jobsForPaths(List<String> paths) async =>
      BackupJobsByPathsDto(
        revision: backupSummary.revision,
        jobs: <BackupJobDto>[],
        missingPaths: paths,
      );

  @override
  Future<BackupCleanupPageDto> cleanupEvents({
    required int afterRevision,
    required int limit,
  }) async => BackupCleanupPageDto(
    latestRevision: afterRevision,
    nextAfterRevision: afterRevision,
    hasMore: false,
    events: <BackupCleanupEventDto>[],
  );

  @override
  Future<void> acknowledgeCleanupEvents(int throughRevision) async {}

  @override
  Future<bool> hasPendingJobsOutsideDestination(String computerId) async =>
      false;

  @override
  Future<String?> loadAccessKey() async => null;

  @override
  Future<bool> isWifiConnected() async => true;

  @override
  Future<void> saveConnection(Map<Object?, Object?> connection) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> enqueueJob(Map<Object?, Object?> request) async {}

  @override
  Future<void> requeueJob(String jobId) async {}

  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<void> updateRetentionSchedule(Map<Object?, Object?> request) async {}

  @override
  Future<Map<Object?, Object?>?> reclaimStorageIfNeeded() async {
    storageCheckCalls++;
    final Completer<Map<Object?, Object?>?>? pending = pendingStorageCheck;
    if (pending != null) return pending.future;
    return <Object?, Object?>{
      'availableBytes': 4 * 1024 * 1024 * 1024,
      'availableBytesBefore': 4 * 1024 * 1024 * 1024,
      'freedBytes': 0,
      'deletedCount': 0,
      'warning': false,
      'insufficient': false,
    };
  }

  @override
  Future<Map<Object?, Object?>?> getNetworkDiagnostics() async => null;

  @override
  Future<void> dispose() async {}
}

class _FakeSpeechSink implements SpeechPromptSink {
  bool _enabled = true;

  @override
  bool get enabled => _enabled;
  @override
  Future<void> setEnabled(bool value) async => _enabled = value;
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

class _FakeMaxVolumeSink implements MaxVolumeSink {
  @override
  Future<void> beginSession() async {}
  @override
  Future<void> endSession() async {}
  @override
  Future<void> disable() async {}
  @override
  Future<void> boost() async {}
  @override
  Future<void> dispose() async {}
}

class _FakeOrderReceiverSink implements OrderInfoReceiverSink {
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  OrderInfoReceiverSnapshot get snapshot => const OrderInfoReceiverSnapshot();
  @override
  Stream<OrderInfo> get received => const Stream<OrderInfo>.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> retry() async {}
  @override
  Future<OrderInfo?> lookup(String trackingNumber) async => null;
  @override
  Future<void> setBackgroundKeepAlive(bool enabled) async {}
  @override
  Future<void> dispose() async {}
}

class _FakeWatermarkSink implements VideoWatermarkSink {
  @override
  Future<String> apply({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
  }) async => inputPath;
}

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FakeCameraPlatform camera;
  late _FakeBackupPlatform backupPlatform;
  late PackingSessionController controller;

  setUp(() async {
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    root = await Directory.systemTemp.createTemp('packing-proof-alternating-');
    camera = _FakeCameraPlatform();
    backupPlatform = _FakeBackupPlatform();
    controller = PackingSessionController(
      repository: SessionRepository(rootDirectory: root),
      speechService: _FakeSpeechSink(),
      maxVolumeService: _FakeMaxVolumeSink(),
      lanBackupService: LanBackupService(platform: backupPlatform),
      orderInfoReceiver: _FakeOrderReceiverSink(),
      videoWatermarkService: _FakeWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
        PlatformCapability.cameraCapabilityNegotiation,
      }),
      cameraService: ContinuousCameraService(platform: camera),
    );
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    WakelockPlusPlatformInterface.instance = MethodChannelWakelockPlus();
    if (await root.exists()) {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // 临时目录清理失败不阻塞测试。
      }
    }
  });

  test('首次探测锁定轮换模式并下发原生模式与一次性说明', () async {
    await controller.initialize();
    expect(controller.capabilityMode, CameraCapabilityMode.unverified);

    await controller.retryCapabilityProbe();

    expect(controller.capabilityMode, CameraCapabilityMode.alternating);
    expect(controller.phase, PackingSessionPhase.ready);
    expect(camera.lastMode, 'alternating');
    expect(controller.takeCapabilityNoticeForDisplay(), isNotNull);
    expect(controller.capabilityStatusText, contains('扫码录像轮换'));
    expect(controller.capabilityProbedAtMs, greaterThan(0));

    // 未工作时完成本单是安全的空操作。
    await controller.finishCurrentOrder();
    expect(controller.phase, PackingSessionPhase.ready);
    expect(controller.isWorking, isFalse);
  });

  test('缓存命中时不再重复探测', () async {
    await controller.initialize();
    await controller.retryCapabilityProbe();
    expect(controller.capabilityMode, CameraCapabilityMode.alternating);
    final int firstProbedAtMs = controller.capabilityProbedAtMs;

    final PackingSessionController second = PackingSessionController(
      repository: testRepository(root),
      speechService: _FakeSpeechSink(),
      maxVolumeService: _FakeMaxVolumeSink(),
      orderInfoReceiver: _FakeOrderReceiverSink(),
      videoWatermarkService: _FakeWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
        PlatformCapability.cameraCapabilityNegotiation,
      }),
      cameraService: ContinuousCameraService(platform: camera),
    );
    addTearDown(() async {
      await second.shutdown();
      second.dispose();
    });
    await second.initialize();
    expect(second.capabilityMode, CameraCapabilityMode.alternating);
    expect(second.capabilityProbedAtMs, firstProbedAtMs);
  });

  test('开始工作后忽略二维码并从同帧选择 Code128', () async {
    await controller.initialize();
    await controller.startWork();

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(
        value: 'QR12345678901',
        area: 300,
        format: 'qr',
      ),
    ]);
    expect(controller.candidateCode, isEmpty);

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(
        value: 'QR12345678901',
        area: 300,
        format: 'qr',
      ),
      const NativeBarcodeCandidate(
        value: 'YT123456789012',
        area: 200,
        format: 'code128',
      ),
    ]);
    expect(controller.candidateCode, 'YT123456789012');
  });

  testWidgets('切换条码不等待慢速存储回收', (WidgetTester tester) async {
    camera.fullSupported = true;
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        await controller.startWork();
      });
      await _confirmBarcode(tester, controller, 'YT123456789011');
      await _waitUntil(
        tester,
        () => controller.currentCode == 'YT123456789011',
        reason: 'first barcode should start the native recording',
      );
      final int checksBeforeSplit = backupPlatform.storageCheckCalls;
      backupPlatform.pendingStorageCheck = Completer<Map<Object?, Object?>?>();

      await _confirmBarcode(tester, controller, 'YT123456789012');
      await _waitUntil(
        tester,
        () => camera.splitCalls == 1,
        reason: 'native split must not await storage reclaim',
      );

      expect(backupPlatform.storageCheckCalls, checksBeforeSplit);
    } finally {
      backupPlatform.pendingStorageCheck = null;
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  testWidgets('原生存储严重告警只停录一次且关闭不等待挂起任务', (WidgetTester tester) async {
    camera.fullSupported = true;
    await tester.runAsync(() async {
      await controller.initialize();
      await controller.retryCapabilityProbe();
      await controller.startWork();
    });
    await _confirmBarcode(tester, controller, 'YT123456789021');
    await _waitUntil(
      tester,
      () => controller.currentCode == 'YT123456789021',
      reason: 'recording should start before storage critical',
    );
    backupPlatform.pendingStorageCheck = Completer<Map<Object?, Object?>?>();
    camera.pendingStop = Completer<NativeRecordingStop>();
    final int checksBeforeCritical = backupPlatform.storageCheckCalls;

    camera.onStorageCritical!.call();
    camera.onStorageCritical!.call();
    await _waitUntil(
      tester,
      () => camera.stopWorkCalls == 1,
      reason: 'duplicate native callbacks must share one stop operation',
    );

    final Stopwatch shutdownTime = Stopwatch()..start();
    try {
      await tester.runAsync(
        () => controller.shutdown().timeout(const Duration(seconds: 3)),
      );
      shutdownTime.stop();

      expect(camera.stopWorkCalls, 1);
      expect(backupPlatform.storageCheckCalls - checksBeforeCritical, 1);
      expect(shutdownTime.elapsed, lessThan(const Duration(seconds: 3)));
    } finally {
      if (!camera.pendingStop!.isCompleted) {
        camera.pendingStop!.complete(
          NativeRecordingStop(
            path: camera.lastPath ?? '',
            startedAt: DateTime.now(),
            endedAt: DateTime.now(),
            watermarkDisposition: NativeWatermarkDisposition.completed,
          ),
        );
      }
      if (!backupPlatform.pendingStorageCheck!.isCompleted) {
        backupPlatform.pendingStorageCheck!.complete(<Object?, Object?>{
          'availableBytes': 4 * 1024 * 1024 * 1024,
          'availableBytesBefore': 4 * 1024 * 1024 * 1024,
          'freedBytes': 0,
          'deletedCount': 0,
          'warning': false,
          'insufficient': false,
        });
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
  });
}

Future<void> _confirmBarcode(
  WidgetTester tester,
  PackingSessionController controller,
  String value,
) async {
  final List<NativeBarcodeCandidate> candidates = <NativeBarcodeCandidate>[
    NativeBarcodeCandidate(value: value, area: 200, format: 'code128'),
  ];
  controller.handleNativeBarcodeFrameForTesting(candidates);
  controller.handleNativeBarcodeFrameForTesting(candidates);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
  String? reason,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: reason);
}

Future<void> _stopWorkIfNeeded(
  WidgetTester tester,
  PackingSessionController controller,
) async {
  if (!controller.isWorking) return;
  bool completed = false;
  final Future<Object?> stopped = controller.stopWork().whenComplete(() {
    completed = true;
  });
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!completed && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(completed, isTrue, reason: 'test cleanup should stop recording');
  await stopped;
}
