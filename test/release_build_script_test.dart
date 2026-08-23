import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android 发布构建刷新 Flutter 产物并保留原生增量缓存', () {
    final script = File('Tools/Build-Android.ps1').readAsStringSync();

    expect(script, contains('Get-ReleaseBuildInputFingerprint'));
    expect(script, contains(r'[switch]$ForceClean'));
    expect(script, contains("build/app/intermediates/flutter/release"));
    expect(script, contains('flutter analyze --no-pub --no-fatal-infos'));
    expect(script, contains('flutter test --no-pub'));
    expect(script, contains('flutter build apk --release'));
    expect(
      script,
      isNot(contains('flutter build apk --release `\n        --no-pub')),
    );
    expect(script, isNot(contains('\n    flutter clean\n')));
    expect(script, contains('Assert-ApkMetadata -ApkPath \$source'));
    expect(
      script,
      contains('Assert-ApkContainsDartBuildIdentity -ApkPath \$source'),
    );
    expect(script, contains('lib/arm64-v8a/libapp.so'));
  });

  test('正式发布和 Release 调试入口均支持强制完整清理', () {
    final publishScript = File('Tools/Publish-Android.ps1').readAsStringSync();
    final diagnosticScript = File(
      'Tools/Build-Release-Diagnostic.ps1',
    ).readAsStringSync();

    expect(publishScript, contains(r'[switch]$ForceClean'));
    expect(publishScript, contains(r'-ForceClean:$ForceClean'));
    expect(diagnosticScript, contains(r'[switch]$ForceClean'));
    expect(diagnosticScript, contains(r'-ForceClean:$ForceClean'));
  });

  test('iOS 发布构建把可审计的源码版本和构建时间注入 App', () {
    final script = File('Tools/Build-iOS.sh').readAsStringSync();

    final revisionIndex = script.indexOf('REVISION="\$(git rev-parse');
    final timestampIndex = script.indexOf('BUILT_AT="\$(date -u');
    final buildIndex = script.indexOf('flutter build ipa --release');
    expect(revisionIndex, greaterThanOrEqualTo(0));
    expect(timestampIndex, greaterThan(revisionIndex));
    expect(buildIndex, greaterThan(timestampIndex));
    expect(script, contains('--dart-define="BUILD_REVISION=\$REVISION"'));
    expect(script, contains('--dart-define="BUILD_TIMESTAMP=\$BUILT_AT"'));
    expect(script, contains('"revision": "\$REVISION"'));
    expect(script, contains('"builtAtUtc": "\$BUILT_AT"'));
  });

  test('Android 清单配置系统播放器内容提供者', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('.SystemVideoPlayerProvider'));
    expect(manifest, contains(r'${applicationId}.system_player_provider'));
    expect(manifest, contains('grantUriPermissions'));
  });
}
