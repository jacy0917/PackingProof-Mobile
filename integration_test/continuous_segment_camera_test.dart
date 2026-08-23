import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';

const MethodChannel _mediaTrackProbe = MethodChannel(
  'app.packingproof.mobile.integration_test/media_track_probe',
);

Future<List<Map<Object?, Object?>>> _inspectMediaTracks(File file) async {
  final List<Object?> tracks =
      await _mediaTrackProbe.invokeListMethod<Object?>(
        'inspect',
        <String, Object?>{'path': file.path},
      ) ??
      <Object?>[];
  return tracks.cast<Map<Object?, Object?>>();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('原生录像分片与音轨开关', (WidgetTester tester) async {
    if (!Platform.isAndroid) {
      return;
    }
    final Directory root = await getApplicationDocumentsDirectory();
    final Directory output = Directory(p.join(root.path, 'integration-test'));
    await output.create(recursive: true);
    final File first = File(p.join(output.path, 'segment-1.mp4'));
    final File second = File(p.join(output.path, 'segment-2.mp4'));
    final File withAudio = File(p.join(output.path, 'with-audio.mp4'));
    final File withoutAudio = File(p.join(output.path, 'without-audio.mp4'));
    for (final File file in <File>[first, second, withAudio, withoutAudio]) {
      if (await file.exists()) {
        await file.delete();
      }
    }

    final ContinuousCameraService camera = ContinuousCameraService();
    addTearDown(camera.dispose);
    final ContinuousCameraInitialization initialization = await camera
        .initialize();
    expect(initialization.textureId, greaterThanOrEqualTo(0));
    expect(initialization.fps, 30);

    final CameraDiagnosticsSnapshot initialDiagnostics = (await camera
        .getDiagnostics())!;
    expect(initialDiagnostics.initialized, isTrue);
    await Future<void>.delayed(const Duration(seconds: 1));
    final CameraDiagnosticsSnapshot previewAlive = (await camera
        .getDiagnostics())!;
    expect(
      previewAlive.previewFrameCount,
      greaterThan(initialDiagnostics.previewFrameCount),
    );

    // 工作扫描开启后预览帧必须继续前进；此步可捕获“开始工作后预览冻结”。
    await camera.setWorkScanEnabled(true);
    final CameraDiagnosticsSnapshot beforeScan = (await camera
        .getDiagnostics())!;
    await Future<void>.delayed(const Duration(seconds: 2));
    final CameraDiagnosticsSnapshot afterScan = (await camera
        .getDiagnostics())!;
    expect(
      afterScan.previewFrameCount,
      greaterThan(beforeScan.previewFrameCount),
    );
    expect(afterScan.previewFrameAgeMs, lessThan(3000));
    await camera.setWorkScanEnabled(false);

    final NativeRecordingStart started = await camera.startWork(
      first.path,
      recordAudio: true,
      trackingNumber: 'TRACK-001',
    );
    expect(started.path, first.path);
    await Future<void>.delayed(const Duration(seconds: 4));

    final NativeRecordingSplit split = await camera.split(
      second.path,
      trackingNumber: 'TRACK-002',
    );
    expect(split.completedPath, first.path);
    expect(split.nextPath, second.path);
    expect(split.boundaryAt.isAfter(started.startedAt), isTrue);
    expect(
      split.watermarkDisposition,
      NativeWatermarkDisposition.completed,
      reason: '第一段必须由实时合成管线确认至少写入过水印帧且全程未降级',
    );
    await Future<void>.delayed(const Duration(seconds: 4));

    final CameraDiagnosticsSnapshot beforeStop = (await camera
        .getDiagnostics())!;
    expect(beforeStop.surfacePipeline, 'gl_compositor');
    expect(beforeStop.surfaceFallbackReason, isNull);
    final NativeRecordingStop stopped = await camera.stopWork();
    expect(stopped.path, second.path);
    expect(
      stopped.watermarkDisposition,
      NativeWatermarkDisposition.completed,
      reason: '第二段必须由实时合成管线确认至少写入过水印帧且全程未降级',
    );
    expect(await first.length(), greaterThan(100000));
    expect(await second.length(), greaterThan(100000));
    // 停止后预览帧必须继续前进；此步可捕获“按结束后仍卡住”。
    await Future<void>.delayed(const Duration(seconds: 3));
    final CameraDiagnosticsSnapshot previewAfterStop = (await camera
        .getDiagnostics())!;
    expect(
      previewAfterStop.previewFrameCount,
      greaterThan(beforeStop.previewFrameCount),
    );
    expect(previewAfterStop.previewFrameAgeMs, lessThan(4000));

    final NativeRecordingStart audioStart = await camera.startWork(
      withAudio.path,
      recordAudio: true,
      trackingNumber: 'TRACK-AUDIO',
    );
    expect(audioStart.path, withAudio.path);
    await Future<void>.delayed(const Duration(seconds: 5));
    final NativeRecordingStop audioStopped = await camera.stopWork();
    expect(
      audioStopped.watermarkDisposition,
      NativeWatermarkDisposition.completed,
    );

    final NativeRecordingStart silentStart = await camera.startWork(
      withoutAudio.path,
      recordAudio: false,
      trackingNumber: 'TRACK-SILENT',
    );
    expect(silentStart.path, withoutAudio.path);
    await Future<void>.delayed(const Duration(seconds: 5));
    final NativeRecordingStop silentStopped = await camera.stopWork();
    expect(
      silentStopped.watermarkDisposition,
      NativeWatermarkDisposition.completed,
    );

    expect(await withAudio.length(), greaterThan(100000));
    expect(await withoutAudio.length(), greaterThan(100000));
    final List<Map<Object?, Object?>> withAudioTracks =
        await _inspectMediaTracks(withAudio);
    final List<Map<Object?, Object?>> silentTracks = await _inspectMediaTracks(
      withoutAudio,
    );
    final List<Map<Object?, Object?>> audioTracks = withAudioTracks.where((
      Map<Object?, Object?> track,
    ) {
      return (track['mime'] as String?)?.startsWith('audio/') == true;
    }).toList();
    expect(
      withAudioTracks.any(
        (Map<Object?, Object?> track) =>
            (track['mime'] as String?)?.startsWith('video/') == true,
      ),
      isTrue,
    );
    expect(audioTracks, hasLength(1));
    expect(audioTracks.single['durationUs'], greaterThan(0));
    expect(audioTracks.single['sampleCount'], greaterThan(0));
    expect(
      silentTracks.any(
        (Map<Object?, Object?> track) =>
            (track['mime'] as String?)?.startsWith('video/') == true,
      ),
      isTrue,
    );
    expect(
      silentTracks.where(
        (Map<Object?, Object?> track) =>
            (track['mime'] as String?)?.startsWith('audio/') == true,
      ),
      isEmpty,
    );
  });
}
