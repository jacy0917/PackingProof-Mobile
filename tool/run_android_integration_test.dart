import 'dart:io';

const String productionApplicationId = 'app.packingproof.mobile';
const String integrationTestApplicationId =
    'app.packingproof.mobile.integration_test';
const String integrationTestPackageEnvironment =
    'PACKING_PROOF_INTEGRATION_TEST_PACKAGE';

final class AndroidIntegrationTestInvocation {
  AndroidIntegrationTestInvocation({
    required this.deviceId,
    required this.target,
  });

  final String deviceId;
  final String target;

  static AndroidIntegrationTestInvocation parse(
    List<String> arguments, {
    required Directory repositoryRoot,
  }) {
    String? deviceId;
    String? target;
    for (int index = 0; index < arguments.length; index += 1) {
      final String argument = arguments[index];
      if (argument != '--device' && argument != '--target') {
        throw FormatException('不支持的参数：$argument');
      }
      if (index + 1 >= arguments.length ||
          arguments[index + 1].startsWith('-')) {
        throw FormatException('$argument 缺少参数值');
      }
      final String value = arguments[index += 1].trim();
      if (argument == '--device') {
        if (deviceId != null) throw const FormatException('--device 只能指定一次');
        deviceId = value;
      } else {
        if (target != null) throw const FormatException('--target 只能指定一次');
        target = value;
      }
    }

    if (deviceId == null || deviceId.isEmpty) {
      throw const FormatException('必须用 --device 明确指定测试设备');
    }
    if (target == null || target.isEmpty) {
      throw const FormatException('必须用 --target 指定一个 integration_test 测试文件');
    }

    final String root = repositoryRoot.resolveSymbolicLinksSync();
    final File targetFile = File(target).absolute;
    final String resolvedTarget = targetFile.resolveSymbolicLinksSync();
    final String integrationRoot = Directory(
      '$root${Platform.pathSeparator}integration_test',
    ).resolveSymbolicLinksSync();
    final String requiredPrefix = '$integrationRoot${Platform.pathSeparator}';
    if (!resolvedTarget.startsWith(requiredPrefix) ||
        !resolvedTarget.endsWith('_test.dart')) {
      throw const FormatException(
        '--target 必须是仓库 integration_test/ 下的 *_test.dart 文件',
      );
    }

    return AndroidIntegrationTestInvocation(
      deviceId: deviceId,
      target: resolvedTarget.substring(root.length + 1),
    );
  }

  List<String> get flutterArguments => <String>[
    'test',
    '--no-pub',
    '--no-uninstall',
    '--device',
    deviceId,
    target,
  ];
}

Future<void> main(List<String> arguments) async {
  final Directory repositoryRoot = File.fromUri(Platform.script).parent.parent;
  late final AndroidIntegrationTestInvocation invocation;
  try {
    invocation = AndroidIntegrationTestInvocation.parse(
      arguments,
      repositoryRoot: repositoryRoot,
    );
  } on FileSystemException catch (error) {
    stderr.writeln('安全拒绝：测试文件不存在或无法解析：${error.path ?? ''}');
    exitCode = 64;
    return;
  } on FormatException catch (error) {
    stderr.writeln('安全拒绝：${error.message}');
    stderr.writeln(
      '用法：dart run tool/run_android_integration_test.dart '
      '--device <设备 ID> --target integration_test/<名称>_test.dart',
    );
    exitCode = 64;
    return;
  }

  stdout.writeln(
    '安全模式：测试包 $integrationTestApplicationId；正式包 '
    '$productionApplicationId 不会被安装、覆盖或卸载',
  );
  final Map<String, String> environment = Map<String, String>.of(
    Platform.environment,
  )..[integrationTestPackageEnvironment] = '1';
  final Process process = await Process.start(
    'flutter',
    invocation.flutterArguments,
    workingDirectory: repositoryRoot.path,
    environment: environment,
    runInShell: Platform.isWindows,
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
