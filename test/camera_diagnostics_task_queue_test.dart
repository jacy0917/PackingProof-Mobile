import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android 和 iOS 诊断接口使用 Pigeon 后台任务队列', () {
    final String android = File(
      'android/app/src/main/kotlin/app/packingproof/mobile/generated/'
      'PlatformApi.kt',
    ).readAsStringSync();
    final String ios = File(
      'ios/Runner/Generated/PlatformApi.swift',
    ).readAsStringSync();

    expect(
      android,
      contains(
        'CameraHostApi.getDiagnostics\$separatedMessageChannelSuffix", '
        'codec, taskQueue)',
      ),
    );
    expect(
      ios,
      contains(
        'CameraHostApi.getDiagnostics\\(channelSuffix)", binaryMessenger: '
        'binaryMessenger, codec: codec, taskQueue: taskQueue)',
      ),
    );
  });
}
