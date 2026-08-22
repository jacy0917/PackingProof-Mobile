import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/diagnostics_log_service.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('runtime_log_test_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('并发写入串行落盘且每行都是合法 JSON', () async {
    final DiagnosticsLogService service = DiagnosticsLogService(
      rootProvider: () async => temp,
      maximumEntries: 100,
    );
    await Future.wait(
      List<Future<void>>.generate(
        30,
        (int index) => service.log(
          kind: 'event',
          extra: <String, Object?>{'index': index},
        ),
      ),
    );

    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    final List<String> lines = await file.readAsLines();
    expect(lines, hasLength(30));
    final List<int> indexes = lines.map((String line) {
      final Map<String, Object?> entry =
          jsonDecode(line) as Map<String, Object?>;
      expect(entry['kind'], 'event');
      return entry['index']! as int;
    }).toList();
    expect(indexes, List<int>.generate(30, (int index) => index));
  });

  test('超过上限只保留最近条目', () async {
    final DiagnosticsLogService service = DiagnosticsLogService(
      rootProvider: () async => temp,
      maximumEntries: 3,
    );
    for (int index = 0; index < 5; index++) {
      await service.log(
        kind: 'event',
        extra: <String, Object?>{'index': index},
      );
    }

    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    final List<String> lines = await file.readAsLines();
    expect(lines, hasLength(3));
    final Map<String, Object?> last =
        jsonDecode(lines.last) as Map<String, Object?>;
    expect(last['index'], 4);
  });

  test('日志文件路径只解析一次且批量追加后仍保持有界', () async {
    int rootProviderCalls = 0;
    final DiagnosticsLogService service = DiagnosticsLogService(
      rootProvider: () async {
        rootProviderCalls++;
        return temp;
      },
      maximumEntries: 100,
    );

    for (int index = 0; index < 125; index++) {
      await service.log(
        kind: 'event',
        extra: <String, Object?>{'index': index},
      );
    }

    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    final List<String> lines = await file.readAsLines();
    expect(rootProviderCalls, 1);
    expect(lines.length, lessThanOrEqualTo(100));
    expect(lines.length, greaterThanOrEqualTo(80));
    expect((jsonDecode(lines.last) as Map<String, Object?>)['index'], 124);
  });

  test('多个服务实例跨压缩边界并发写入时不会竞争或写坏文件', () async {
    final DiagnosticsLogService first = DiagnosticsLogService(
      rootProvider: () async => temp,
      maximumEntries: 20,
    );
    final DiagnosticsLogService second = DiagnosticsLogService(
      rootProvider: () async => temp,
      maximumEntries: 20,
    );

    for (int index = 0; index < 19; index++) {
      await first.log(kind: 'seed', extra: <String, Object?>{'index': index});
    }
    await Future.wait(<Future<void>>[
      first.log(kind: 'concurrent', extra: const <String, Object?>{'id': 'a'}),
      second.log(kind: 'concurrent', extra: const <String, Object?>{'id': 'b'}),
    ]);

    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    final List<String> lines = await file.readAsLines();
    expect(lines.length, lessThanOrEqualTo(20));
    final List<Map<String, Object?>> entries = lines
        .map((String line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
    expect(
      entries
          .where((Map<String, Object?> entry) => entry['kind'] == 'concurrent')
          .map((Map<String, Object?> entry) => entry['id']),
      <Object?>['a', 'b'],
    );
  });

  test('运行时元数据只加载一次且缺失字段稳定为 null', () async {
    int loadCount = 0;
    final DiagnosticsLogService service = DiagnosticsLogService(
      rootProvider: () async => temp,
      maximumEntries: 10,
      runtimeMetadataLoader: () async {
        loadCount++;
        return <String, Object?>{
          'appVersion': '0.5.22',
          'appBuildNumber': 11029,
          'buildRevision': 'abc1234',
          'buildTimestamp': null,
        };
      },
    );
    await service.log(kind: 'first');
    await service.log(kind: 'second');

    expect(loadCount, 1);
    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    for (final String line in await file.readAsLines()) {
      final Map<String, Object?> entry =
          jsonDecode(line) as Map<String, Object?>;
      expect(entry['appVersion'], '0.5.22');
      expect(entry['appBuildNumber'], 11029);
      expect(entry['buildRevision'], 'abc1234');
      expect(entry.containsKey('buildTimestamp'), isTrue);
      expect(entry['buildTimestamp'], isNull);
    }
  });

  test('元数据加载失败时仍写入稳定空字段', () async {
    final DiagnosticsLogService service = DiagnosticsLogService(
      rootProvider: () async => temp,
      maximumEntries: 10,
      runtimeMetadataLoader: () async => throw StateError('missing'),
    );
    await service.log(kind: 'event');

    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    final Map<String, Object?> entry =
        jsonDecode((await file.readAsLines()).single) as Map<String, Object?>;
    expect(entry['appVersion'], isNull);
    expect(entry['appBuildNumber'], isNull);
    expect(entry['buildRevision'], isNull);
    expect(entry['buildTimestamp'], isNull);
  });

  test('首次日志路径解析失败后下一次写入会重试', () async {
    int attempts = 0;
    final DiagnosticsLogService service = DiagnosticsLogService(
      rootProvider: () async {
        attempts++;
        if (attempts == 1) throw FileSystemException('temporary');
        return temp;
      },
    );

    await service.log(kind: 'first');
    await service.log(kind: 'second');

    expect(attempts, 2);
    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    final List<String> lines = await file.readAsLines();
    expect(lines, hasLength(1));
    expect(
      (jsonDecode(lines.single) as Map<String, Object?>)['kind'],
      'second',
    );
  });
}
