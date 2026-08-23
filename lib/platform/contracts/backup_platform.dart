import '../generated/platform_api.g.dart';

abstract interface class BackupNativePlatform {
  void setSummaryListener(void Function(BackupSummaryDto summary)? listener);

  Future<BackupSummaryDto> summary();

  Future<BackupSummaryDto> initialize(Map<Object?, Object?> request);

  Future<void> setAutoEnabled(bool enabled);

  Future<BackupJobsByPathsDto> jobsForPaths(List<String> paths);

  Future<BackupCleanupPageDto> cleanupEvents({
    required int afterRevision,
    required int limit,
  });

  Future<void> acknowledgeCleanupEvents(int throughRevision);

  Future<bool> hasPendingJobsOutsideDestination(String computerId);

  Future<String?> loadAccessKey();

  Future<bool> isWifiConnected();

  Future<void> saveConnection(Map<Object?, Object?> connection);

  Future<void> disconnect();

  Future<void> enqueueJob(Map<Object?, Object?> request);

  Future<void> enqueueJobs(List<Map<Object?, Object?>> requests);

  Future<void> requeueJob(String jobId);

  Future<void> cancelJob(String jobId);

  Future<void> updateRetentionSchedule(Map<Object?, Object?> request);

  Future<int?> availableRecordingStorageBytes();

  Future<Map<Object?, Object?>?> reclaimStorageIfNeeded();

  Future<Map<Object?, Object?>?> getNetworkDiagnostics();

  Future<void> dispose();
}
