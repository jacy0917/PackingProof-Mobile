import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app_build_config.dart';

/// 统一运行日志：低频事件写入 `diagnostics/runtime.jsonl`。
///
/// 与相机心跳（camera.jsonl）、路径/播放诊断（path_fix.jsonl）分开，
/// 导出时合并。所有追加通过 future 链串行化，避免并发写坏文件。
class DiagnosticsLogService {
  DiagnosticsLogService({
    Future<Directory> Function()? rootProvider,
    this.maximumEntries = 500,
    // Named parameters cannot use a private initializing formal.
    // ignore: prefer_initializing_formals
    Future<Map<String, Object?>> Function()? runtimeMetadataLoader,
  }) : _rootProvider = rootProvider ?? getApplicationDocumentsDirectory,
       // ignore: prefer_initializing_formals
       _runtimeMetadataLoader =
           runtimeMetadataLoader ?? _defaultRuntimeMetadataLoader,
       assert(maximumEntries > 0);

  static final Map<String, _RuntimeLogCoordinator> _coordinators =
      <String, _RuntimeLogCoordinator>{};

  final Future<Directory> Function() _rootProvider;
  final int maximumEntries;
  final Future<Map<String, Object?>> Function()? _runtimeMetadataLoader;
  Future<void>? _pending;
  int _pendingWrites = 0;
  Future<Map<String, Object?>>? _runtimeMetadata;
  Future<File>? _logFile;

  Future<File> logFile() {
    final Future<File>? existing = _logFile;
    if (existing != null) return existing;
    late final Future<File> tracked;
    tracked = _resolveLogFile().onError((Object error, StackTrace stackTrace) {
      if (identical(_logFile, tracked)) {
        _logFile = null;
      }
      Error.throwWithStackTrace(error, stackTrace);
    });
    _logFile = tracked;
    return tracked;
  }

  Future<File> _resolveLogFile() async {
    final Directory root = await _rootProvider();
    final Directory directory = Directory(p.join(root.path, 'diagnostics'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'runtime.jsonl'));
  }

  Future<void> log({
    required String kind,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    _pendingWrites++;
    final Future<void>? previous = _pending;
    final Future<void> next = previous == null
        ? Future<void>.sync(() => _append(kind, extra))
        : previous.then((_) => _append(kind, extra));
    final Future<void> tracked = next.whenComplete(() => _pendingWrites--);
    _pending = tracked.catchError((Object _) {});
    return tracked;
  }

  Future<void> flush() async {
    if (_pendingWrites > 0) await _pending;
  }

  Future<void> _append(String kind, Map<String, Object?> extra) async {
    try {
      final File file = await logFile();
      final Map<String, Object?> metadata = await _loadRuntimeMetadata();
      final String line = jsonEncode(<String, Object?>{
        ...metadata,
        'ts': DateTime.now().toIso8601String(),
        'kind': kind,
        ...extra,
      });
      final int maxEntries = maximumEntries;
      final String filePath = file.path;
      final int keepWhenFull = maxEntries <= 1
          ? 0
          : maxEntries - (maxEntries ~/ 5).clamp(1, maxEntries);
      final _RuntimeLogCoordinator coordinator = _coordinators.putIfAbsent(
        filePath,
        () => _RuntimeLogCoordinator(filePath),
      );
      await coordinator.append(
        line,
        maximumEntries: maxEntries,
        keepWhenFull: keepWhenFull,
      );
    } on Object {
      // 日志失败绝不影响业务。
    }
  }

  Future<Map<String, Object?>> _loadRuntimeMetadata() {
    final Future<Map<String, Object?>>? existing = _runtimeMetadata;
    if (existing != null) {
      return existing;
    }
    final Future<Map<String, Object?>> loaded =
        (_runtimeMetadataLoader?.call() ??
                Future<Map<String, Object?>>.value(_fallbackRuntimeMetadata()))
            .then<Map<String, Object?>>(
              (Map<String, Object?> value) => Map<String, Object?>.from(value),
              onError: (Object _, StackTrace _) => _fallbackRuntimeMetadata(),
            );
    _runtimeMetadata = loaded;
    return loaded;
  }

  Map<String, Object?> _fallbackRuntimeMetadata() => const <String, Object?>{
    'appVersion': null,
    'appBuildNumber': null,
    'buildRevision': null,
    'buildTimestamp': null,
  };
}

/// 同一日志文件可能被多个临时 service 实例同时使用，必须共享写入链和计数。
class _RuntimeLogCoordinator {
  _RuntimeLogCoordinator(this.path);

  final String path;
  Future<void>? _tail;
  int? _entryCount;

  Future<void> append(
    String line, {
    required int maximumEntries,
    required int keepWhenFull,
  }) {
    final Future<void>? previous = _tail;
    final Future<void> operation = previous == null
        ? _append(
            line,
            maximumEntries: maximumEntries,
            keepWhenFull: keepWhenFull,
          )
        : previous.then(
            (_) => _append(
              line,
              maximumEntries: maximumEntries,
              keepWhenFull: keepWhenFull,
            ),
          );
    _tail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _append(
    String line, {
    required int maximumEntries,
    required int keepWhenFull,
  }) async {
    final String filePath = path;
    _entryCount ??= await Isolate.run(
      () => _prepareRuntimeLogFile(
        filePath,
        maximumEntries: maximumEntries,
        keepWhenFull: keepWhenFull,
      ),
    );
    if (_entryCount! >= maximumEntries) {
      _entryCount = await Isolate.run(
        () => _compactRuntimeLogFile(filePath, keepWhenFull),
      );
    }
    await File(filePath).writeAsString('$line\n', mode: FileMode.append);
    _entryCount = _entryCount! + 1;
  }
}

int _prepareRuntimeLogFile(
  String path, {
  required int maximumEntries,
  required int keepWhenFull,
}) {
  final File file = File(path);
  if (!file.existsSync()) return 0;
  final List<String> lines = file.readAsLinesSync();
  if (lines.length < maximumEntries) return lines.length;
  final List<String> retained = keepWhenFull == 0
      ? const <String>[]
      : lines.sublist(lines.length - keepWhenFull);
  file.writeAsStringSync(
    retained.isEmpty ? '' : '${retained.join('\n')}\n',
    mode: FileMode.write,
  );
  return retained.length;
}

int _compactRuntimeLogFile(String path, int keepCount) {
  final File file = File(path);
  if (!file.existsSync()) return 0;
  final List<String> lines = file.readAsLinesSync();
  final int retainedCount = keepCount.clamp(0, lines.length);
  final List<String> retained = retainedCount == 0
      ? const <String>[]
      : lines.sublist(lines.length - retainedCount);
  file.writeAsStringSync(
    retained.isEmpty ? '' : '${retained.join('\n')}\n',
    mode: FileMode.write,
  );
  return retained.length;
}

Future<Map<String, Object?>> _defaultRuntimeMetadataLoader() async {
  String? appVersion;
  int? appBuildNumber;
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    appVersion = info.version;
    appBuildNumber = int.tryParse(info.buildNumber);
  } on Object {
    // 版本信息失败时仍返回稳定空字段，不能阻塞业务日志。
  }
  const AppBuildConfig build = AppBuildConfig.environment;
  return <String, Object?>{
    'appVersion': appVersion,
    'appBuildNumber': appBuildNumber,
    'buildRevision': build.buildRevision.isEmpty ? null : build.buildRevision,
    'buildTimestamp': build.buildTimestamp.isEmpty
        ? null
        : build.buildTimestamp,
  };
}
