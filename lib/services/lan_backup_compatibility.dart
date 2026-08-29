const String backupProtocol = 'mobile-backup-v2';
const int backupEnrollmentVersion = 2;
const int backupAuthenticationVersion = 3;
const String minimumBackupHostVersion = '0.0.55';
const String currentMobileCompatibilityVersion = '0.5.25';
const int currentMobileCompatibilityBuildNumber = 11040;

enum LanBackupCompatibilityFailure {
  hostVersionTooOld,
  mobileTooOld,
  protocolMismatch,
  malformed,
}

class LanBackupCompatibilityResult {
  const LanBackupCompatibilityResult.compatible(this.compatibility)
    : failure = null;

  const LanBackupCompatibilityResult.incompatible(this.failure)
    : compatibility = null;

  final LanBackupHostCompatibility? compatibility;
  final LanBackupCompatibilityFailure? failure;

  bool get isCompatible => failure == null;

  String get message => switch (failure) {
    null => '',
    LanBackupCompatibilityFailure.hostVersionTooOld =>
      '保存主机版本过低，请在电脑端更新 PackingProof',
    LanBackupCompatibilityFailure.mobileTooOld => '当前手机 App 版本过低，请更新后重新连接',
    LanBackupCompatibilityFailure.protocolMismatch =>
      '电脑端与手机的备份协议不兼容，请更新 PackingProof',
    LanBackupCompatibilityFailure.malformed =>
      '电脑端未提供完整的备份兼容信息，请更新 PackingProof',
  };
}

class LanBackupHostCompatibility {
  const LanBackupHostCompatibility({
    required this.hostVersion,
    required this.protocol,
    required this.enrollmentVersion,
    required this.authVersion,
    required this.minimumMobileVersion,
    required this.minimumMobileBuildNumber,
  });

  final String hostVersion;
  final String protocol;
  final int enrollmentVersion;
  final int authVersion;
  final String minimumMobileVersion;
  final int minimumMobileBuildNumber;

  bool get supportsCurrentMobile =>
      evaluateLanBackupHostCompatibility(this).isCompatible;
}

LanBackupCompatibilityResult evaluateLanBackupHostCompatibility(
  LanBackupHostCompatibility compatibility,
) {
  if (compareBackupVersions(
        compatibility.hostVersion,
        minimumBackupHostVersion,
      ) <
      0) {
    return const LanBackupCompatibilityResult.incompatible(
      LanBackupCompatibilityFailure.hostVersionTooOld,
    );
  }
  if (compatibility.protocol != backupProtocol ||
      compatibility.enrollmentVersion != backupEnrollmentVersion ||
      compatibility.authVersion != backupAuthenticationVersion) {
    return const LanBackupCompatibilityResult.incompatible(
      LanBackupCompatibilityFailure.protocolMismatch,
    );
  }
  if (compareBackupVersions(
            currentMobileCompatibilityVersion,
            compatibility.minimumMobileVersion,
          ) <
          0 ||
      currentMobileCompatibilityBuildNumber <
          compatibility.minimumMobileBuildNumber) {
    return const LanBackupCompatibilityResult.incompatible(
      LanBackupCompatibilityFailure.mobileTooOld,
    );
  }
  return LanBackupCompatibilityResult.compatible(compatibility);
}

LanBackupCompatibilityResult parseLanBackupCompatibilityResult(Object? value) {
  final LanBackupHostCompatibility? compatibility =
      parseLanBackupHostCompatibility(value);
  if (compatibility == null) {
    return const LanBackupCompatibilityResult.incompatible(
      LanBackupCompatibilityFailure.malformed,
    );
  }
  return evaluateLanBackupHostCompatibility(compatibility);
}

LanBackupHostCompatibility? parseLanBackupHostCompatibility(Object? value) {
  if (value is! Map) return null;
  final Map<Object?, Object?> map = Map<Object?, Object?>.from(value);
  final String hostVersion = '${map['hostVersion'] ?? ''}'.trim();
  final String protocol = '${map['protocol'] ?? ''}'.trim();
  final int enrollmentVersion =
      (map['enrollmentVersion'] as num?)?.toInt() ?? 0;
  final int authVersion = (map['authVersion'] as num?)?.toInt() ?? 0;
  final String minimumMobileVersion = '${map['minimumMobileVersion'] ?? ''}'
      .trim();
  final int minimumMobileBuildNumber =
      (map['minimumMobileBuildNumber'] as num?)?.toInt() ?? 0;
  if (hostVersion.isEmpty ||
      protocol.isEmpty ||
      minimumMobileVersion.isEmpty ||
      minimumMobileBuildNumber <= 0) {
    return null;
  }
  return LanBackupHostCompatibility(
    hostVersion: hostVersion,
    protocol: protocol,
    enrollmentVersion: enrollmentVersion,
    authVersion: authVersion,
    minimumMobileVersion: minimumMobileVersion,
    minimumMobileBuildNumber: minimumMobileBuildNumber,
  );
}

int compareBackupVersions(String left, String right) {
  List<int>? parse(String value) {
    String normalized = value.trim();
    if (normalized.startsWith('v') || normalized.startsWith('V')) {
      normalized = normalized.substring(1);
    }
    final int suffix = normalized.indexOf(RegExp(r'[+-]'));
    if (suffix >= 0) normalized = normalized.substring(0, suffix);
    final List<int?> parts = normalized.split('.').map(int.tryParse).toList();
    if (parts.isEmpty || parts.any((int? part) => part == null)) return null;
    return parts.cast<int>();
  }

  final List<int>? leftParts = parse(left);
  final List<int>? rightParts = parse(right);
  if (leftParts == null) return -1;
  if (rightParts == null) return 1;
  final int count = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (int index = 0; index < count; index++) {
    final int leftPart = index < leftParts.length ? leftParts[index] : 0;
    final int rightPart = index < rightParts.length ? rightParts[index] : 0;
    final int comparison = leftPart.compareTo(rightPart);
    if (comparison != 0) return comparison;
  }
  return 0;
}
