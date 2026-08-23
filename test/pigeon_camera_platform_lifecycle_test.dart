import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/platform/adapters/pigeon_camera_platform.dart';
import 'package:packing_proof_mobile/platform/generated/platform_api.g.dart';

class _FakeCameraHostApi extends CameraHostApi {
  int disposeCalls = 0;

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('相机重建后保留进程级条码事件接收器', () async {
    final _FakeCameraHostApi hostApi = _FakeCameraHostApi();
    final PigeonCameraPlatform platform = PigeonCameraPlatform(
      hostApi: hostApi,
    );
    final List<String> received = <String>[];
    platform.onBarcodeBatch = (candidates) {
      received.addAll(candidates.map((candidate) => candidate.value));
    };

    await platform.dispose();
    await _sendBarcodeBatch('AFTER-REBUILD');

    expect(hostApi.disposeCalls, 1);
    expect(received, <String>['AFTER-REBUILD']);
    CameraEventApi.setUp(null);
  });
}

Future<void> _sendBarcodeBatch(String value) async {
  final Completer<void> response = Completer<void>();
  final ByteData? message = CameraEventApi.pigeonChannelCodec.encodeMessage(
    <Object?>[
      <BarcodeCandidateDto>[
        BarcodeCandidateDto(
          value: value,
          area: 100,
          format: 'qr',
          detectedAtMs: 1,
        ),
      ],
    ],
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'dev.flutter.pigeon.packing_proof_mobile.CameraEventApi.barcodeBatch',
        message,
        (_) => response.complete(),
      );
  await response.future;
}
