part of 'packing_session_controller.dart';

final class _WatermarkFinalizationPersistenceException implements Exception {
  const _WatermarkFinalizationPersistenceException();
}

final class _WatermarkFinalizationStateUnknownException implements Exception {
  const _WatermarkFinalizationStateUnknownException();
}

/// 发布水印成片并将最终可用文件衔接到备份队列。
mixin _PackingSessionWatermarkCoordinator on _PackingSessionStorageCoordinator {
  static const int _maximumWatermarkAttempts = 1;
  static const Duration _watermarkCancellationTimeout = Duration(seconds: 2);

  VideoWatermarkSink get _videoWatermarkService;
  ContinuousCameraInitialization? get _nativeInitialization;
  RecordingVideoCodec get _preferredVideoCodec;
  String _firstTrackingNumber(List<RecordingSession> sessions);
  @override
  Future<void> _backupAllRepositorySessions(String reason);
  final Set<String> _activeWatermarkSessionIds = <String>{};
  Future<void>? _pendingWatermarkDispatcher;
  bool _pendingWatermarkDrainRequested = false;
  final Completer<void> _watermarkShutdown = Completer<void>();

  Future<bool> _watermarkAndBackup(
    String savedPath,
    RecordingSession session,
    RecordingOrientation recordingOrientation,
  ) async {
    if (!_activeWatermarkSessionIds.add(session.id)) return false;
    final Stopwatch stopwatch = Stopwatch()..start();
    var processingSession = session;
    String? claimOwnerId;
    String? claimOperationId;
    var inputBytes = 0;
    var continueDrain = true;
    try {
      try {
        if (session.watermarkStatus == WatermarkProcessingStatus.pending) {
          final WatermarkAttemptClaim? claim = await _repository
              .claimPendingWatermarkAttempt(
                sessionId: session.id,
                expectedAttempt: session.watermarkAttemptCount,
                maximumAttempts: _maximumWatermarkAttempts,
              );
          if (claim == null || !claim.claimed) {
            _sessions = await _repository.loadRecentSessions();
            await _logWatermarkEvent(
              kind: 'watermark_claim_skipped',
              extra: <String, Object?>{
                'sessionId': session.id,
                'attempt':
                    claim?.session.watermarkAttemptCount ??
                    session.watermarkAttemptCount,
                'exhausted': claim?.exhausted ?? false,
              },
            );
            if (claim?.exhausted ?? false) {
              await _enqueueBackupIfNeeded(
                claim!.session.filePath,
                <RecordingSession>[claim.session],
              );
            }
            if (!_disposed) notifyListeners();
            return claim?.exhausted ?? false;
          }
          processingSession = claim.session;
          claimOwnerId = claim.ownerId;
          claimOperationId = claim.operationId;
          _sessions = await _repository.loadRecentSessions();
        }
        inputBytes = await _watermarkFileBytes(savedPath);
        await _logWatermarkEvent(
          kind: 'watermark_started',
          extra: <String, Object?>{
            'sessionId': session.id,
            'orientation': recordingOrientation.storageValue,
            'inputBytes': inputBytes,
            'outputBytes': 0,
            'elapsedMs': 0,
            'attempt': processingSession.watermarkAttemptCount,
          },
        );
        final String trackingNumber = _firstTrackingNumber(<RecordingSession>[
          processingSession,
        ]);
        final Future<String> watermarkOperation =
            _videoWatermarkService is OrientedVideoWatermarkSink
            ? (_videoWatermarkService as OrientedVideoWatermarkSink)
                  .applyWithOrientation(
                    inputPath: savedPath,
                    startedAt: processingSession.startedAt,
                    trackingNumber: trackingNumber,
                    // 相机可能因设备不支持偏好编码而回退，水印必须跟随实际录制的编码。
                    videoCodec: recordingVideoCodecFromMime(
                      _nativeInitialization?.videoMime,
                      fallback: _preferredVideoCodec,
                    ),
                    recordingOrientation: recordingOrientation,
                  )
            : _videoWatermarkService.apply(
                inputPath: savedPath,
                startedAt: processingSession.startedAt,
                trackingNumber: trackingNumber,
                videoCodec: recordingVideoCodecFromMime(
                  _nativeInitialization?.videoMime,
                  fallback: _preferredVideoCodec,
                ),
              );
        final String watermarkedPath =
            await Future.any<String>(<Future<String>>[
              watermarkOperation,
              _watermarkShutdown.future.then<String>((_) {
                throw PlatformException(
                  code: 'watermark_cancelled',
                  message: '控制器关闭，水印导出已取消',
                );
              }),
            ]);
        final String finalPath = await _repository.finalizeVideo(
          sourcePath: watermarkedPath,
          sessionId: processingSession.id,
          startedAt: processingSession.startedAt,
          trackingNumber: trackingNumber,
          operationMode: processingSession.operationMode,
        );
        final RecordingSession finalized = processingSession.copyWith(
          filePath: finalPath,
          watermarkStatus: WatermarkProcessingStatus.completed,
        );
        if (processingSession.watermarkStatus ==
            WatermarkProcessingStatus.processing) {
          final String ownerId = claimOwnerId ?? '';
          final String operationId = claimOperationId ?? '';
          if (ownerId.isEmpty || operationId.isEmpty) {
            throw const _WatermarkFinalizationPersistenceException();
          }
          try {
            final RecordingSession? persisted = await _repository
                .finalizeWatermarkClaim(
                  session: finalized,
                  ownerId: ownerId,
                  operationId: operationId,
                );
            if (persisted == null) {
              if (finalPath != savedPath) {
                await _repository.deleteFileIfUnreferenced(finalPath);
              }
              throw const _WatermarkFinalizationPersistenceException();
            }
            await _refreshRecentSessionsAfterWatermark(persisted);
          } on Object {
            // 条件提交可能已成功、仅后续 recent reload 失败；先按 ID
            // 重读，绝不使用通用 upsert 复活并发删除的记录。
            late final List<RecordingSession> latestSessions;
            try {
              latestSessions = await _repository.findActiveSessionsByIds(
                <String>{finalized.id},
              );
            } on Object {
              throw const _WatermarkFinalizationStateUnknownException();
            }
            final bool completedWasPersisted = latestSessions.any(
              (RecordingSession current) =>
                  current.id == finalized.id &&
                  current.filePath == finalPath &&
                  current.watermarkStatus ==
                      WatermarkProcessingStatus.completed,
            );
            if (completedWasPersisted) {
              await _refreshRecentSessionsAfterWatermark(finalized);
            } else if (finalPath != savedPath) {
              // 只有确认 DB 未指向新成片时才清理，绝不删原片或状态不明的成片。
              try {
                await _repository.deleteFileIfUnreferenced(finalPath);
              } on Object {
                // 清理失败不覆盖“状态未落库”这一主故障，后续维护仍可识别孤立文件。
              }
            }
            if (!completedWasPersisted) {
              throw const _WatermarkFinalizationPersistenceException();
            }
          }
        }
        if (finalized.filePath != processingSession.filePath) {
          try {
            await _repository.deleteFileIfUnreferenced(savedPath);
          } on Object {
            await _logWatermarkEvent(
              kind: 'watermark_source_cleanup_failed',
              extra: <String, Object?>{
                'sessionId': finalized.id,
                'attempt': finalized.watermarkAttemptCount,
              },
            );
          }
        }
        stopwatch.stop();
        await _logWatermarkEvent(
          kind: 'watermark_completed',
          extra: <String, Object?>{
            'sessionId': session.id,
            'orientation': recordingOrientation.storageValue,
            'inputBytes': inputBytes,
            'outputBytes': await _watermarkFileBytes(finalPath),
            'elapsedMs': stopwatch.elapsedMilliseconds,
            'attempt': finalized.watermarkAttemptCount,
          },
        );
        await _enqueueBackupIfNeeded(finalPath, <RecordingSession>[finalized]);
      } on Object catch (error) {
        stopwatch.stop();
        if (error is _WatermarkFinalizationStateUnknownException) {
          await _logWatermarkEvent(
            kind: 'watermark_state_unknown',
            extra: <String, Object?>{
              'sessionId': session.id,
              'orientation': recordingOrientation.storageValue,
              'inputBytes': inputBytes,
              'outputBytes': 0,
              'elapsedMs': stopwatch.elapsedMilliseconds,
              'errorType': error.runtimeType.toString(),
              'attempt': processingSession.watermarkAttemptCount,
            },
          );
          if (!_disposed) notifyListeners();
          if (!_disposed) {
            _runInBackground(
              _backupAllRepositorySessions('watermark_state_unknown'),
            );
          }
          return false;
        }
        final bool retryable = _isRetryableWatermarkError(error);
        var statusPersisted =
            processingSession.watermarkStatus !=
            WatermarkProcessingStatus.processing;
        RecordingSession? backupSession =
            processingSession.watermarkStatus ==
                WatermarkProcessingStatus.failed
            ? processingSession
            : null;
        if (processingSession.watermarkStatus ==
            WatermarkProcessingStatus.processing) {
          final String ownerId = claimOwnerId ?? '';
          final String operationId = claimOperationId ?? '';
          try {
            final RecordingSession? persisted =
                ownerId.isEmpty || operationId.isEmpty
                ? null
                : await _repository.failProcessingWatermark(
                    sessionId: processingSession.id,
                    ownerId: ownerId,
                    operationId: operationId,
                  );
            statusPersisted = persisted != null;
            if (persisted != null) {
              backupSession = persisted;
              await _refreshRecentSessionsAfterWatermark(persisted);
            }
          } on Object {
            try {
              final List<RecordingSession> latest = await _repository
                  .findActiveSessionsByIds(<String>{processingSession.id});
              RecordingSession? persisted = latest.isEmpty
                  ? null
                  : latest.single;
              if (persisted?.watermarkStatus ==
                      WatermarkProcessingStatus.processing &&
                  ownerId.isNotEmpty &&
                  operationId.isNotEmpty) {
                persisted = await _repository.failProcessingWatermark(
                  sessionId: processingSession.id,
                  ownerId: ownerId,
                  operationId: operationId,
                );
              }
              statusPersisted =
                  persisted != null &&
                  persisted.watermarkStatus !=
                      WatermarkProcessingStatus.pending &&
                  persisted.watermarkStatus !=
                      WatermarkProcessingStatus.processing;
              if (statusPersisted) {
                backupSession = persisted;
                await _refreshRecentSessionsAfterWatermark(persisted);
              }
            } on Object {
              // broad-catch: 持久化失败只降低状态可信度，录像文件仍须保留
              statusPersisted = false;
            }
          }
        }
        // 任意导出异常都终结为 failed 并备份原片；同一 sessionId 不再
        // 自动生成另一个版本，保持一条录像一个不可变备份事实。
        await _logWatermarkEvent(
          kind: 'watermark_failed',
          extra: <String, Object?>{
            'sessionId': session.id,
            'orientation': recordingOrientation.storageValue,
            'inputBytes': inputBytes,
            'outputBytes': 0,
            'elapsedMs': stopwatch.elapsedMilliseconds,
            'errorType': error.runtimeType.toString(),
            'attempt': processingSession.watermarkAttemptCount,
            'retryable': retryable,
            'statusPersisted': statusPersisted,
          },
        );
        if (statusPersisted && backupSession != null) {
          await _enqueueBackupIfNeeded(
            backupSession.filePath,
            <RecordingSession>[backupSession],
          );
        }
      }
      if (!_disposed) notifyListeners();
    } finally {
      _activeWatermarkSessionIds.remove(session.id);
      if (_pendingWatermarkDrainRequested) {
        await _resumePendingWatermarks();
      }
    }
    return continueDrain;
  }

  bool _isRetryableWatermarkError(Object error) =>
      error is _WatermarkFinalizationPersistenceException ||
      (error is PlatformException && error.code == 'watermark_interrupted');

  Future<void> _cancelWatermarkForShutdown() async {
    if (!_watermarkShutdown.isCompleted) _watermarkShutdown.complete();
    final VideoWatermarkSink service = _videoWatermarkService;
    if (service is! CancellableVideoWatermarkSink) return;
    try {
      await (service as CancellableVideoWatermarkSink).cancel().timeout(
        _watermarkCancellationTimeout,
      );
    } on Object {
      // broad-catch: Dart 关闭信号已保证迟到回调不再发布到数据库；
      // 原生取消失败或无响应不得让控制器关闭无界等待。
    }
  }

  Future<void> _refreshRecentSessionsAfterWatermark(
    RecordingSession persisted,
  ) async {
    try {
      _sessions = await _repository.loadRecentSessions();
    } on Object {
      // broad-catch: 数据库刷新失败时用已持久化结果更新当前有界缓存
      final int index = _sessions.indexWhere(
        (RecordingSession current) => current.id == persisted.id,
      );
      if (index < 0) return;
      final List<RecordingSession> updated = List<RecordingSession>.of(
        _sessions,
      );
      updated[index] = persisted;
      _sessions = updated;
    }
  }

  Future<int> _watermarkFileBytes(String path) async {
    try {
      final File file = File(path);
      return await file.exists() ? await file.length() : 0;
    } on FileSystemException {
      return 0;
    }
  }

  Future<void> _logWatermarkEvent({
    required String kind,
    required Map<String, Object?> extra,
  }) async {
    try {
      await _runtimeLog.log(kind: kind, extra: extra);
    } on Object {
      // 诊断写入不得改变水印状态机或阻断最终成片。
    }
  }

  Future<void> _resumePendingWatermarks() async {
    if (_disposed) return;
    _pendingWatermarkDrainRequested = true;
    if (_pendingWatermarkDispatcher != null) return;
    late final Future<void> dispatcher;
    dispatcher = _drainPendingWatermarks().whenComplete(() {
      if (identical(_pendingWatermarkDispatcher, dispatcher)) {
        _pendingWatermarkDispatcher = null;
        if (_pendingWatermarkDrainRequested &&
            _activeWatermarkSessionIds.isEmpty &&
            !_disposed) {
          unawaited(_resumePendingWatermarks());
        }
      }
    });
    _pendingWatermarkDispatcher = dispatcher;
    _runInBackground(dispatcher);
  }

  Future<void> _drainPendingWatermarks() async {
    int? afterStartedAt;
    String? afterId;
    // 活跃的直接导出退出时负责重新唤醒；此处不能提前清掉请求，
    // 否则 dispatcher 先返回、直接导出后返回时会丢失这次 wakeup。
    if (_activeWatermarkSessionIds.isNotEmpty) return;
    _pendingWatermarkDrainRequested = false;
    while (!_disposed) {
      // Native and startup recovery share one CPU/disk-heavy exporter. A
      // direct export already in flight will request another drain on exit.
      if (_activeWatermarkSessionIds.isNotEmpty) return;
      final List<RecordingSession> pending = await _repository
          .loadPendingWatermarkSessions(
            limit: 1,
            afterStartedAt: afterStartedAt,
            afterId: afterId,
          );
      if (pending.isEmpty) return;
      final RecordingSession session = pending.single;
      final bool continueDrain = await _watermarkAndBackup(
        session.filePath,
        session,
        session.recordingOrientation,
      );
      if (!continueDrain) {
        // 本轮跳过被系统中断或已由其他实例领取的任务，继续处理后续
        // 录像；下次前台恢复从队首重新尝试，既不热循环也不饿死队尾。
        afterStartedAt = session.startedAt.millisecondsSinceEpoch;
        afterId = session.id;
      }
    }
  }

  @visibleForTesting
  Future<void> watermarkAndBackupForTesting(
    String savedPath,
    RecordingSession session, [
    RecordingOrientation recordingOrientation = RecordingOrientation.portrait,
  ]) async {
    await _watermarkAndBackup(savedPath, session, recordingOrientation);
  }

  @visibleForTesting
  Future<void> resumePendingWatermarksForTesting() =>
      _resumePendingWatermarks();
}
