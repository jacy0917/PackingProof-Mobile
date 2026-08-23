import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/run_android_integration_test.dart';

void main() {
  final Directory repositoryRoot = Directory.current;

  test('真机集成测试固定使用隔离包且禁止测试后卸载', () {
    final AndroidIntegrationTestInvocation invocation =
        AndroidIntegrationTestInvocation.parse(<String>[
          '--device',
          'safe-test-device',
          '--target',
          'integration_test/continuous_segment_camera_test.dart',
        ], repositoryRoot: repositoryRoot);

    expect(integrationTestApplicationId, isNot(productionApplicationId));
    expect(invocation.flutterArguments, contains('--no-uninstall'));
    expect(invocation.flutterArguments, contains('--device-id'));
    expect(invocation.flutterArguments, isNot(contains('--device')));
    expect(invocation.flutterArguments, contains('safe-test-device'));
  });

  test('未明确设备、非集成测试目标和额外 Flutter 参数均安全拒绝', () {
    expect(
      () => AndroidIntegrationTestInvocation.parse(<String>[
        '--target',
        'integration_test/continuous_segment_camera_test.dart',
      ], repositoryRoot: repositoryRoot),
      throwsFormatException,
    );
    expect(
      () => AndroidIntegrationTestInvocation.parse(<String>[
        '--device',
        'device',
        '--target',
        'test/recording_session_test.dart',
      ], repositoryRoot: repositoryRoot),
      throwsFormatException,
    );
    expect(
      () => AndroidIntegrationTestInvocation.parse(<String>[
        '--device',
        'device',
        '--target',
        'integration_test/continuous_segment_camera_test.dart',
        '--uninstall',
      ], repositoryRoot: repositoryRoot),
      throwsFormatException,
    );
  });

  test('Android 构建按 integration_test 目标或守门环境切换测试包名', () {
    final String gradle = File(
      'android/app/build.gradle.kts',
    ).readAsStringSync();

    expect(
      gradle,
      contains('System.getenv("$integrationTestPackageEnvironment") == "1"'),
    );
    expect(gradle, contains('providers.gradleProperty("target")'));
    expect(gradle, contains('flutterTarget.contains("/integration_test/")'));
    expect(gradle, contains('"$integrationTestApplicationId"'));
    expect(gradle, contains('"$productionApplicationId"'));
  });
}
