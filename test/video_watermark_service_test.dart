import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/services/video_watermark_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('水印输出发布前始终保留原录像', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_watermark_test',
    );
    addTearDown(() => root.delete(recursive: true));
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/video_watermark_test',
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          final Map<Object?, Object?> arguments =
              call.arguments! as Map<Object?, Object?>;
          final File output = File(arguments['outputPath']! as String);
          await output.writeAsBytes(<int>[9, 8, 7], flush: true);
          return output.path;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final File input = File('${root.path}${Platform.pathSeparator}source.mp4');
    await input.writeAsBytes(<int>[1, 2, 3], flush: true);

    final String outputPath =
        await VideoWatermarkService(channel: channel, isAndroid: true).apply(
          inputPath: input.path,
          startedAt: DateTime(2026, 7, 22, 10),
          trackingNumber: 'DEMO',
          videoCodec: RecordingVideoCodec.h264,
        );

    expect(File(outputPath).existsSync(), isTrue);
    expect(input.existsSync(), isTrue);
    expect(await input.readAsBytes(), <int>[1, 2, 3]);
    expect(calls.single.arguments, containsPair('videoCodec', 'h264'));
  });

  test('水印输出为空文件时拒绝发布并保留原录像', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_watermark_empty_test',
    );
    addTearDown(() => root.delete(recursive: true));
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/video_watermark_empty_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          final Map<Object?, Object?> arguments =
              call.arguments! as Map<Object?, Object?>;
          final File output = File(arguments['outputPath']! as String);
          await output.create();
          return output.path;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final File input = File('${root.path}${Platform.pathSeparator}source.mp4');
    await input.writeAsBytes(<int>[1, 2, 3], flush: true);

    await expectLater(
      VideoWatermarkService(channel: channel, isIOS: true).apply(
        inputPath: input.path,
        startedAt: DateTime(2026, 8, 21, 10),
        trackingNumber: 'DEMO',
      ),
      throwsStateError,
    );
    expect(await input.readAsBytes(), <int>[1, 2, 3]);
  });

  test('取消后拒绝迟到成片且不启动已排队导出', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_watermark_cancel_test',
    );
    addTearDown(() => root.delete(recursive: true));
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/video_watermark_cancel_test',
    );
    final Completer<void> applyStarted = Completer<void>();
    final Completer<void> releaseApply = Completer<void>();
    var applyCalls = 0;
    var cancelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'cancel') {
            cancelCalls++;
            return null;
          }
          applyCalls++;
          if (!applyStarted.isCompleted) applyStarted.complete();
          await releaseApply.future;
          final Map<Object?, Object?> arguments =
              call.arguments! as Map<Object?, Object?>;
          final File output = File(arguments['outputPath']! as String);
          await output.writeAsBytes(<int>[9, 8, 7], flush: true);
          return output.path;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final File input = File('${root.path}${Platform.pathSeparator}source.mp4');
    await input.writeAsBytes(<int>[1, 2, 3], flush: true);
    final VideoWatermarkService service = VideoWatermarkService(
      channel: channel,
      isAndroid: true,
    );

    final Future<String> active = service.apply(
      inputPath: input.path,
      startedAt: DateTime(2026, 8, 23, 10),
      trackingNumber: 'ACTIVE',
    );
    final Future<String> queued = service.apply(
      inputPath: input.path,
      startedAt: DateTime(2026, 8, 23, 10),
      trackingNumber: 'QUEUED',
    );
    final Future<void> activeExpectation = expectLater(
      active,
      throwsA(
        isA<PlatformException>().having(
          (PlatformException error) => error.code,
          'code',
          'watermark_cancelled',
        ),
      ),
    );
    final Future<void> queuedExpectation = expectLater(
      queued,
      throwsA(
        isA<PlatformException>().having(
          (PlatformException error) => error.code,
          'code',
          'watermark_cancelled',
        ),
      ),
    );
    await applyStarted.future;
    await service.cancel();
    releaseApply.complete();
    await Future.wait<void>(<Future<void>>[
      activeExpectation,
      queuedExpectation,
    ]);

    expect(applyCalls, 1);
    expect(cancelCalls, 1);
    expect(await input.exists(), isTrue);
    expect(await File('${root.path}/source_watermarked.mp4').exists(), isFalse);
  });
}
