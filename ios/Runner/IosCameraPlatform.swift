import AVFoundation
import Flutter
import os.log
import UIKit

/// 单次录像生命周期操作的聚合计时。
///
/// 只接受调用点定义的阶段名和毫秒数，不保存路径、条码或错误文本。
final class IosCameraOperationTiming: @unchecked Sendable {
  let operation: String

  private let startedAtNs: UInt64
  private let lock = NSLock()
  private var stagesMs: [String: Int64] = [:]
  private var isFinished = false

  init(
    operation: String,
    startedAtNs: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    self.operation = operation
    self.startedAtNs = startedAtNs
  }

  func record(stage: String, durationMs: Int64) {
    lock.lock()
    stagesMs[stage] = max(0, durationMs)
    lock.unlock()
  }

  func record(stage: String, since startedAtNs: UInt64) {
    record(
      stage: stage,
      durationMs: Self.elapsedMilliseconds(
        from: startedAtNs,
        to: DispatchTime.now().uptimeNanoseconds
      )
    )
  }

  /// 原子地结束计时；重复结束返回 nil，避免取消与完成竞态重复关闭 signpost。
  func finish(
    succeeded: Bool,
    endedAtNs: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) -> [String: Any]? {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return nil
    }
    isFinished = true
    let stageSnapshot = stagesMs
    lock.unlock()
    return [
      "operation": operation,
      "succeeded": succeeded,
      "totalMs": Self.elapsedMilliseconds(from: startedAtNs, to: endedAtNs),
      "stagesMs": stageSnapshot,
    ]
  }

  static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int64 {
    guard end >= start else { return 0 }
    return Int64((end - start) / 1_000_000)
  }
}

private struct IosCameraPendingFirstWrittenFrame {
  let operation: String
  let writerReadyAtNs: UInt64
  let signpostID: OSSignpostID
}

/// writer 就绪到首个视频帧真正 append 成功的计时。
///
/// 独立持有 signpost 生命周期，销毁时也会幂等收口，不依赖 Flutter registry。
final class IosCameraFirstWrittenFrameTiming: @unchecked Sendable {
  private static let log = OSLog(
    subsystem: "app.packingproof.mobile",
    category: "CameraPerformance"
  )

  private let lock = NSLock()
  private let onFinished: (@Sendable (Bool) -> Void)?
  private var pending: IosCameraPendingFirstWrittenFrame?
  private var lastSnapshot: [String: Any]?

  init(onFinished: (@Sendable (Bool) -> Void)? = nil) {
    self.onFinished = onFinished
  }

  deinit {
    cancelIfNeeded()
  }

  func begin(
    operation: String,
    startedAtNs: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    let signpostID = OSSignpostID(log: Self.log)
    os_signpost(
      .begin,
      log: Self.log,
      name: "CameraFirstWrittenVideoFrame",
      signpostID: signpostID,
      "operation=%{public}@",
      operation as NSString
    )
    let next = IosCameraPendingFirstWrittenFrame(
      operation: operation,
      writerReadyAtNs: startedAtNs,
      signpostID: signpostID
    )
    lock.lock()
    let replaced = pending
    pending = next
    lastSnapshot = nil
    lock.unlock()
    if let replaced {
      finishCancelled(replaced)
    }
  }

  @discardableResult
  func recordWrittenFrameIfNeeded(
    endedAtNs: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) -> Bool {
    lock.lock()
    guard let pending else {
      lock.unlock()
      return false
    }
    let durationMs = IosCameraOperationTiming.elapsedMilliseconds(
      from: pending.writerReadyAtNs,
      to: endedAtNs
    )
    let snapshot: [String: Any] = [
      "operation": pending.operation,
      "writerReadyToFirstWrittenFrameMs": durationMs,
    ]
    self.pending = nil
    lastSnapshot = snapshot
    lock.unlock()
    os_signpost(
      .end,
      log: Self.log,
      name: "CameraFirstWrittenVideoFrame",
      signpostID: pending.signpostID,
      "operation=%{public}@ duration_ms=%{public}lld written=1",
      pending.operation as NSString,
      durationMs
    )
    onFinished?(true)
    return true
  }

  @discardableResult
  func cancelIfNeeded() -> Bool {
    lock.lock()
    guard let pending else {
      lock.unlock()
      return false
    }
    self.pending = nil
    lock.unlock()
    finishCancelled(pending)
    return true
  }

  func snapshot() -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    return lastSnapshot
  }

  private func finishCancelled(_ pending: IosCameraPendingFirstWrittenFrame) {
    os_signpost(
      .end,
      log: Self.log,
      name: "CameraFirstWrittenVideoFrame",
      signpostID: pending.signpostID,
      "operation=%{public}@ written=0",
      pending.operation as NSString
    )
    onFinished?(false)
  }
}

enum IosCameraVideoAppendPolicy {
  @discardableResult
  static func appendWhenReady(
    isReady: Bool,
    append: () -> Bool,
    onWritten: () -> Void
  ) -> Bool {
    guard isReady, append() else { return false }
    onWritten()
    return true
  }
}

enum IosAudioSampleEnergyProbe {
  private static let maximumSamplesPerProbe = 256

  static func normalizedPeak(in sampleBuffer: CMSampleBuffer) -> Double? {
    guard
      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
      let description = CMAudioFormatDescriptionGetStreamBasicDescription(
        formatDescription
      )?.pointee,
      description.mFormatID == kAudioFormatLinearPCM
    else {
      return nil
    }

    var requiredSize = 0
    let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &requiredSize,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: nil
    )
    guard sizeStatus == noErr, requiredSize >= MemoryLayout<AudioBufferList>.size else {
      return nil
    }

    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: requiredSize,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }
    let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
    var retainedBlockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: bufferList,
      bufferListSize: requiredSize,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &retainedBlockBuffer
    )
    guard status == noErr else { return nil }

    let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let isSignedInteger = description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
    let bits = Int(description.mBitsPerChannel)
    var remaining = maximumSamplesPerProbe
    var peak = 0.0
    for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
      guard remaining > 0, let data = buffer.mData else { continue }
      let bytes = Int(buffer.mDataByteSize)
      if isFloat && bits == 32 {
        let values = data.assumingMemoryBound(to: Float.self)
        let count = min(bytes / MemoryLayout<Float>.stride, remaining)
        for index in 0..<count {
          peak = max(peak, min(1, abs(Double(values[index]))))
        }
        remaining -= count
      } else if isFloat && bits == 64 {
        let values = data.assumingMemoryBound(to: Double.self)
        let count = min(bytes / MemoryLayout<Double>.stride, remaining)
        for index in 0..<count {
          peak = max(peak, min(1, abs(values[index])))
        }
        remaining -= count
      } else if isSignedInteger && bits == 16 {
        let values = data.assumingMemoryBound(to: Int16.self)
        let count = min(bytes / MemoryLayout<Int16>.stride, remaining)
        for index in 0..<count {
          peak = max(peak, abs(Double(values[index])) / 32_768)
        }
        remaining -= count
      } else if isSignedInteger && bits == 32 {
        let values = data.assumingMemoryBound(to: Int32.self)
        let count = min(bytes / MemoryLayout<Int32>.stride, remaining)
        for index in 0..<count {
          peak = max(peak, abs(Double(values[index])) / 2_147_483_648)
        }
        remaining -= count
      }
    }
    return remaining == maximumSamplesPerProbe ? nil : peak
  }
}

/// iOS 始终使用同一个 AVFoundation 完整管线，不提供 Android 的三档
/// surface 组合探测或运行时模式切换。
enum IosCameraCapabilityPolicy {
  static func validateInitializationMode(_ mode: String) throws {
    guard mode == "unverified" || mode == "full" else {
      throw pigeonError(
        "iOS 相机不支持能力模式 \(mode)",
        code: "camera_capability_mode_unsupported"
      )
    }
  }

  static func probeUnsupportedError(sequence: String) -> PigeonError {
    pigeonError(
      "iOS 相机使用固定完整管线，不支持能力序列探测：\(sequence)",
      code: "camera_capability_probe_unsupported"
    )
  }

  static func modeSwitchUnsupportedError(mode: String) -> PigeonError {
    pigeonError(
      "iOS 相机使用固定完整管线，不支持能力模式切换：\(mode)",
      code: "camera_capability_mode_unsupported"
    )
  }
}

enum IosCameraWriterFinishPolicy {
  static func result(
    status: AVAssetWriter.Status,
    writerError: String?
  ) -> Result<Void, Error> {
    switch status {
    case .completed:
      return .success(())
    case .failed:
      return .failure(pigeonError(
        writerError ?? "录像文件写入失败",
        code: "camera_recording_finish_failed"
      ))
    case .cancelled:
      return .failure(pigeonError(
        writerError ?? "录像文件写入已取消",
        code: "camera_recording_finish_cancelled"
      ))
    case .unknown, .writing:
      return .failure(pigeonError(
        writerError ?? "录像文件尚未完成写入",
        code: "camera_recording_finish_incomplete"
      ))
    @unknown default:
      return .failure(pigeonError(
        writerError ?? "录像文件写入状态未知",
        code: "camera_recording_finish_incomplete"
      ))
    }
  }

  static func timeoutError() -> PigeonError {
    pigeonError(
      "录像写入超时",
      code: "camera_recording_finish_timeout"
    )
  }

  static func missingWriterError() -> PigeonError {
    pigeonError(
      "录像写入器不存在",
      code: "camera_recording_writer_missing"
    )
  }
}

struct IosLastSegmentDiagnosticsState {
  let writerStatus: String?
  let writerError: String?
  let trackCheckSucceeded: Bool?
  let trackCount: Int64?
  let trackPresent: Bool?
  let trackInspectionError: String?
}

/// 保存最近完成片段的诊断，并拒绝旧片段迟到的异步音轨结果。
final class IosLastSegmentDiagnostics {
  private let lock = NSLock()
  private var latestSerial: Int64 = -1
  private var writerStatus: String?
  private var writerError: String?
  private var trackCheckSucceeded: Bool?
  private var trackCount: Int64?
  private var trackPresent: Bool?
  private var trackInspectionError: String?

  /// 返回 true 表示 writer 已完成，可在关键路径之外开始音轨检查。
  func recordWriterResult(
    serial: Int64,
    writerStatus: String,
    writerError: String?,
    hasCompletedFile: Bool,
    inspectionError: String?
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard serial >= latestSerial else { return false }
    latestSerial = serial
    self.writerStatus = writerStatus
    self.writerError = writerError
    if hasCompletedFile {
      trackCheckSucceeded = nil
      trackCount = nil
      trackPresent = nil
      trackInspectionError = nil
      return true
    }
    trackCheckSucceeded = false
    trackCount = nil
    trackPresent = nil
    trackInspectionError = inspectionError
    return false
  }

  func recordTrackResult(
    serial: Int64,
    trackCount: Int64?,
    inspectionError: String?
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard serial == latestSerial else { return }
    guard let trackCount, inspectionError == nil else {
      trackCheckSucceeded = false
      self.trackCount = nil
      trackPresent = nil
      trackInspectionError = inspectionError ?? "无法读取录像声音轨道"
      return
    }
    trackCheckSucceeded = true
    self.trackCount = trackCount
    trackPresent = trackCount > 0
    trackInspectionError = nil
  }

  func currentState() -> IosLastSegmentDiagnosticsState {
    lock.lock()
    defer { lock.unlock() }
    return IosLastSegmentDiagnosticsState(
      writerStatus: writerStatus,
      writerError: writerError,
      trackCheckSucceeded: trackCheckSucceeded,
      trackCount: trackCount,
      trackPresent: trackPresent,
      trackInspectionError: trackInspectionError
    )
  }
}

/// 将高频事件限制为一个在途请求，并在忙碌或限速期间只保留最新值。
/// 调用方必须在同一个串行队列上驱动所有状态转换。
struct IosLatestPendingGate<Payload> {
  enum Action {
    case none
    case send(Payload)
    case schedule(TimeInterval)
  }

  private let minimumInterval: TimeInterval
  private var inFlight = false
  private var pending: Payload?
  private var nextSendTime: TimeInterval = 0
  private var wakeScheduled = false

  init(minimumInterval: TimeInterval) {
    self.minimumInterval = max(0, minimumInterval)
  }

  mutating func submit(_ payload: Payload, now: TimeInterval) -> Action {
    pending = payload
    return drain(now: now)
  }

  mutating func complete(now: TimeInterval) -> Action {
    inFlight = false
    return drain(now: now)
  }

  mutating func wake(now: TimeInterval) -> Action {
    wakeScheduled = false
    return drain(now: now)
  }

  mutating func discardPending() {
    pending = nil
  }

  mutating func reset() {
    inFlight = false
    pending = nil
    nextSendTime = 0
    wakeScheduled = false
  }

  private mutating func drain(now: TimeInterval) -> Action {
    guard !inFlight, pending != nil else { return .none }
    if now < nextSendTime {
      guard !wakeScheduled else { return .none }
      wakeScheduled = true
      return .schedule(nextSendTime - now)
    }
    let payload = pending!
    pending = nil
    inFlight = true
    nextSendTime = now + minimumInterval
    return .send(payload)
  }
}

/// iOS 连续相机原生实现：
/// 保持一个 `AVCaptureSession` 常开，用 `AVAssetWriter` 按单号轮换输出文件，
/// 不重启预览，达到接近 Android 连续录像的体验。
final class IosCameraHostApi:
  NSObject,
  CameraHostApi,
  FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate,
  AVCaptureMetadataOutputObjectsDelegate
{
  private static let performanceLog = OSLog(
    subsystem: "app.packingproof.mobile",
    category: "CameraPerformance"
  )

  private let eventApi: CameraEventApi
  private let textures: FlutterTextureRegistry
  private let audioSessionCoordinator: IosSharedAudioSessionCoordinator
  private let recordingActivityState: IosRecordingActivityState
  private let recordingActivityOwner = UUID()
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "packingproof.camera.session")
  private let metadataQueue = DispatchQueue(label: "packingproof.camera.metadata")
  private let bufferLock = NSLock()
  private let stateLock = NSLock()
  private let performanceLock = NSLock()
  private let recordingLifecycle = IosCameraRecordingLifecycle()
  private var barcodeBatchGate =
    IosLatestPendingGate<[BarcodeCandidateDto]>(minimumInterval: 0.1)
  private var barcodeGeneration: UInt64 = 0

  private var textureId: Int64 = -1
  private var latestPixelBuffer: CVPixelBuffer?
  private var videoDeviceInput: AVCaptureDeviceInput?
  private var audioDeviceInput: AVCaptureDeviceInput?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var audioOutput: AVCaptureAudioDataOutput?
  private var metadataOutput: AVCaptureMetadataOutput?

  private var recordingSpecName = "hd1080p30"
  private var preferredVideoCodec = "hevc"
  private var codecFallbackReason: String?
  private var recordingOrientationName = "portrait"
  private var recordAudio = true
  private var pairingScanEnabled = false
  private var workScanEnabled = false
  private var previewActive = true
  private var disposed = false
  private var recoveryRuntimeError = false
  private var runtimeErrorObserver: NSObjectProtocol?
  private var cameraAudioSessionHeld = false

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private let liveWatermarkRenderer = IosLiveWatermarkRenderer()
  private var currentPath: String?
  private var currentTrackingNumber = ""
  private var currentWatermarkFailed = false
  private var currentWatermarkError: String?
  private var watermarkPreparationPending = false
  private var preservesWatermarkDuringSplit = false
  private var currentSegmentId = ""
  private var currentStartedAtMs: Int64 = 0
  private var currentSegmentSerial: Int64 = 0
  private var writerSessionStarted = false
  private var sessionId = UUID().uuidString
  private var recordingAudioActive = false
  private var currentAudioSampleCount: Int64 = 0
  private var currentAudioAppendFailedCount: Int64 = 0
  private var currentAudioLastError: String?
  private var currentAudioEnergyProbeCount: Int64 = 0
  private var currentAudioLowEnergyProbeCount: Int64 = 0
  private var currentAudioPeak: Double = 0
  private var lastAudioSampleCount: Int64 = 0
  private var lastAudioAppendFailedCount: Int64 = 0
  private var lastAudioLastError: String?
  private var lastAudioEnergyProbeCount: Int64 = 0
  private var lastAudioLowEnergyProbeCount: Int64 = 0
  private var lastAudioPeak: Double = 0
  private let lastSegmentDiagnostics = IosLastSegmentDiagnostics()
  private let firstWrittenFrameTiming = IosCameraFirstWrittenFrameTiming()
  private var lastOperationTiming: [String: Any]?

  /// 固定 sessionPreset .hd1920x1080，竖屏预览与录像输出 1080x1920。
  private var portraitSize: (width: Int, height: Int) { (1080, 1920) }

  init(
    eventApi: CameraEventApi,
    textures: FlutterTextureRegistry,
    audioSessionCoordinator: IosSharedAudioSessionCoordinator = .shared,
    recordingActivityState: IosRecordingActivityState = .shared
  ) {
    self.eventApi = eventApi
    self.textures = textures
    self.audioSessionCoordinator = audioSessionCoordinator
    self.recordingActivityState = recordingActivityState
    super.init()
    updateTextureId(textures.register(self))
    runtimeErrorObserver = NotificationCenter.default.addObserver(
      forName: .AVCaptureSessionRuntimeError,
      object: session,
      queue: .main
    ) { [weak self] _ in
      self?.recoveryRuntimeError = true
    }
    configureSession()
  }

  deinit {
    recordingActivityState.setActive(false, owner: recordingActivityOwner)
    markDisposed()
    recordingLifecycle.dispose()
    firstWrittenFrameTiming.cancelIfNeeded()
    clearOutputDelegates()
    let session = self.session
    let audioSessionCoordinator = self.audioSessionCoordinator
    let shouldReleaseAudioSession = cameraAudioSessionHeld
    sessionQueue.async {
      if session.isRunning {
        session.stopRunning()
      }
      if shouldReleaseAudioSession {
        do {
          try audioSessionCoordinator.release(.camera)
        } catch {
          audioSessionCoordinator.abandon(.camera)
          NSLog(
            "PackingProof failed to release camera audio session: %@",
            error.localizedDescription
          )
        }
      }
    }
    if let observer = runtimeErrorObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    runtimeErrorObserver = nil
    // 不在此处触碰 textures：引擎销毁阶段调用 FlutterTextureRegistry 会 SIGSEGV。
  }

  // MARK: - CameraHostApi

  func initialize(
    request: CameraInitializeRequest,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    do {
      try IosCameraCapabilityPolicy.validateInitializationMode(
        request.capabilityMode
      )
    } catch {
      completion(.failure(error))
      return
    }
    let requestedCodec = request.videoCodec.lowercased()
    let hasHevcEncoder = IosVideoCodecCapabilities.hasHevcEncoder
    let hasHevcDecoder = IosVideoCodecCapabilities.hasHevcDecoder
    if requestedCodec == "hevc" && (!hasHevcEncoder || !hasHevcDecoder) {
      preferredVideoCodec = "h264"
      codecFallbackReason = hasHevcEncoder
        ? "no_hevc_decoder" : "hevc_encoder_unavailable"
    } else {
      preferredVideoCodec = requestedCodec
      codecFallbackReason = nil
    }
    recordingSpecName = request.recordingSpec
    recordingOrientationName = ["landscapeLeft", "landscapeRight"].contains(request.recordingOrientation)
      ? request.recordingOrientation : "portrait"
    sessionQueue.async { [weak self] in
      guard let self else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      do {
        try self.acquireRecordingAudioSessionIfNeeded()
        try self.addAudioInputIfNeeded()
      } catch {
        completion(.failure(error))
        return
      }
      if self.isDisposed {
        self.recoverCamera { recovered in
          if recovered {
            self.markNotDisposed()
            self.finishInitialize(completion)
          } else {
            completion(.failure(pigeonError("摄像头恢复失败")))
          }
        }
      } else {
        if !self.session.isRunning {
          self.session.startRunning()
        }
        self.finishInitialize(completion)
      }
    }
  }

  func ensurePermissions(
    recordAudio: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    self.recordAudio = recordAudio
    requestVideoAndAudioPermissions(recordAudio: recordAudio) { granted in
      completion(.success(granted))
    }
  }

  func startWork(
    path: String,
    recordAudio: Bool,
    trackingNumber: String,
    completion: @escaping (Result<CameraRecordingStartDto, Error>) -> Void
  ) {
    let timing = IosCameraOperationTiming(operation: "start")
    let signpostID = OSSignpostID(log: Self.performanceLog)
    os_signpost(
      .begin,
      log: Self.performanceLog,
      name: "CameraRecordingStart",
      signpostID: signpostID
    )
    sessionQueue.async { [weak self] in
      guard let self, !self.isDisposed else {
        if let self {
          self.finishPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingStart",
            succeeded: false
          )
        } else {
          Self.finishDetachedPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingStart",
            succeeded: false
          )
        }
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      let request: IosCameraRecordingLifecycle.Request
      switch self.recordingLifecycle.begin(
        .start,
        onCancelled: { [weak self] in
          if let self {
            self.finishPerformanceOperation(
              timing,
              signpostID: signpostID,
              signpostName: "CameraRecordingStart",
              succeeded: false
            )
          } else {
            Self.finishDetachedPerformanceOperation(
              timing,
              signpostID: signpostID,
              signpostName: "CameraRecordingStart",
              succeeded: false
            )
          }
          completion(.failure(pigeonError("摄像头已经关闭")))
        }
      ) {
      case .success(let value):
        request = value
      case .failure(let rejection):
        self.finishPerformanceOperation(
          timing,
          signpostID: signpostID,
          signpostName: "CameraRecordingStart",
          succeeded: false
        )
        completion(.failure(self.recordingRequestError(rejection, for: .start)))
        return
      }
      // Publish work activity before session/writer preparation so cleanup
      // cannot contend with the first recording startup path.
      self.recordingActivityState.setActive(
        true, owner: self.recordingActivityOwner
      )
      self.recordAudio = recordAudio
      do {
        try self.recordPerformanceStage(
          "ensureSession",
          operation: "start",
          signpostName: "CameraEnsureSession",
          timing: timing,
          action: self.ensureRunningForWork
        )
        try self.startWriter(
          path: path,
          trackingNumber: trackingNumber,
          operation: "start",
          timing: timing
        )
        let startedAt = self.currentStartedAtMs
        self.eventApi.segmentStarted(
          event: CameraSegmentStartedDto(
            sessionId: self.sessionId,
            segmentId: self.currentSegmentId,
            startedAtMs: startedAt
          ),
          completion: { _ in }
        )
        if self.recordingLifecycle.complete(request, succeeded: true) {
          self.finishPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingStart",
            succeeded: true
          )
          completion(.success(CameraRecordingStartDto(
            path: path,
            startedAtMs: startedAt
          )))
        } else {
          self.recordingActivityState.setActive(
            false, owner: self.recordingActivityOwner
          )
        }
      } catch {
        self.recordingActivityState.setActive(
          false, owner: self.recordingActivityOwner
        )
        if self.recordingLifecycle.complete(request, succeeded: false) {
          self.finishPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingStart",
            succeeded: false
          )
          completion(.failure(error))
        }
      }
    }
  }

  func split(
    nextPath: String,
    trackingNumber: String,
    completion: @escaping (Result<CameraRecordingSplitDto, Error>) -> Void
  ) {
    let timing = IosCameraOperationTiming(operation: "split")
    let signpostID = OSSignpostID(log: Self.performanceLog)
    os_signpost(
      .begin,
      log: Self.performanceLog,
      name: "CameraRecordingSplit",
      signpostID: signpostID
    )
    sessionQueue.async { [weak self] in
      guard let self, !self.isDisposed else {
        if let self {
          self.finishPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingSplit",
            succeeded: false
          )
        } else {
          Self.finishDetachedPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingSplit",
            succeeded: false
          )
        }
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      let request: IosCameraRecordingLifecycle.Request
      switch self.recordingLifecycle.begin(
        .split,
        onCancelled: { [weak self] in
          if let self {
            self.finishPerformanceOperation(
              timing,
              signpostID: signpostID,
              signpostName: "CameraRecordingSplit",
              succeeded: false
            )
          } else {
            Self.finishDetachedPerformanceOperation(
              timing,
              signpostID: signpostID,
              signpostName: "CameraRecordingSplit",
              succeeded: false
            )
          }
          completion(.failure(pigeonError("摄像头已经关闭")))
        }
      ) {
      case .success(let value):
        request = value
      case .failure(let rejection):
        self.finishPerformanceOperation(
          timing,
          signpostID: signpostID,
          signpostName: "CameraRecordingSplit",
          succeeded: false
        )
        completion(.failure(self.recordingRequestError(rejection, for: .split)))
        return
      }
      guard self.currentPath != nil else {
        if self.recordingLifecycle.complete(request, succeeded: false) {
          self.finishPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingSplit",
            succeeded: false
          )
          completion(.failure(pigeonError("当前没有正在录制的视频")))
        }
        return
      }
      let completedPath = self.currentPath ?? ""
      let completedStartedAt = self.currentStartedAtMs
      let boundaryAt = Int64(Date().timeIntervalSince1970 * 1000)
      let finishStartedAtNs = DispatchTime.now().uptimeNanoseconds
      let finishSignpostID = OSSignpostID(log: Self.performanceLog)
      os_signpost(
        .begin,
        log: Self.performanceLog,
        name: "CameraWriterFinish",
        signpostID: finishSignpostID,
        "operation=%{public}@",
        timing.operation as NSString
      )
      self.finishCurrentWriter(preserveWatermarkPreview: true) { [weak self] finishResult in
        let finishMs = IosCameraOperationTiming.elapsedMilliseconds(
          from: finishStartedAtNs,
          to: DispatchTime.now().uptimeNanoseconds
        )
        timing.record(stage: "writerFinish", durationMs: finishMs)
        os_signpost(
          .end,
          log: Self.performanceLog,
          name: "CameraWriterFinish",
          signpostID: finishSignpostID,
          "operation=%{public}@ duration_ms=%{public}lld",
          timing.operation as NSString,
          finishMs
        )
        guard let self else {
          Self.finishDetachedPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingSplit",
            succeeded: false
          )
          return
        }
        self.sessionQueue.async {
          guard !self.isDisposed else {
            self.recordingLifecycle.dispose()
            return
          }
          guard self.recordingLifecycle.isPending(request) else { return }
          if case .failure(let error) = finishResult {
            self.clearPreservedWatermarkPreview()
            if self.recordingLifecycle.complete(request, succeeded: false) {
              self.finishPerformanceOperation(
                timing,
                signpostID: signpostID,
                signpostName: "CameraRecordingSplit",
                succeeded: false
              )
              completion(.failure(error))
            }
            return
          }
          do {
            let completedDisposition = try finishResult.get()
            try self.startWriter(
              path: nextPath,
              trackingNumber: trackingNumber,
              operation: "split",
              timing: timing
            )
            if self.recordingLifecycle.complete(request, succeeded: true) {
              self.finishPerformanceOperation(
                timing,
                signpostID: signpostID,
                signpostName: "CameraRecordingSplit",
                succeeded: true
              )
              completion(.success(CameraRecordingSplitDto(
                completedPath: completedPath,
                nextPath: nextPath,
                completedStartedAtMs: completedStartedAt,
                boundaryAtMs: boundaryAt,
                watermarkDisposition: completedDisposition
              )))
            }
          } catch {
            self.clearPreservedWatermarkPreview()
            self.eventApi.nativeError(
              message: "切换录像文件失败：\(error.localizedDescription)",
              completion: { _ in }
            )
            if self.recordingLifecycle.complete(request, succeeded: false) {
              self.finishPerformanceOperation(
                timing,
                signpostID: signpostID,
                signpostName: "CameraRecordingSplit",
                succeeded: false
              )
              completion(.failure(error))
            }
          }
        }
      }
    }
  }

  func stopWork(
    completion: @escaping (Result<CameraRecordingStopDto, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, !self.isDisposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      let request: IosCameraRecordingLifecycle.Request
      switch self.recordingLifecycle.begin(
        .stop,
        onCancelled: {
          completion(.failure(pigeonError("摄像头已经关闭")))
        }
      ) {
      case .success(let value):
        request = value
      case .failure(let rejection):
        completion(.failure(self.recordingRequestError(rejection, for: .stop)))
        return
      }
      let path = self.currentPath ?? ""
      let startedAt = self.currentStartedAtMs
      let endedAt = Int64(Date().timeIntervalSince1970 * 1000)
      self.finishCurrentWriter { [weak self] finishResult in
        guard let self else {
          return
        }
        self.recordingActivityState.setActive(
          false, owner: self.recordingActivityOwner
        )
        switch finishResult {
        case .success(let watermarkDisposition):
          guard self.recordingLifecycle.complete(request, succeeded: true) else {
            return
          }
          completion(.success(CameraRecordingStopDto(
            path: path,
            startedAtMs: startedAt,
            endedAtMs: endedAt,
            watermarkDisposition: watermarkDisposition
          )))
        case .failure(let error):
          guard self.recordingLifecycle.complete(request, succeeded: false) else {
            return
          }
          completion(.failure(error))
        }
      }
    }
  }

  private func recordingRequestError(
    _ rejection: IosCameraRecordingLifecycle.Rejection,
    for operation: IosCameraRecordingLifecycle.Operation
  ) -> Error {
    switch rejection {
    case .disposed:
      return pigeonError("摄像头已经关闭")
    case .alreadyRecording:
      return pigeonError("当前已有正在录制的视频", code: "camera_busy")
    case .notRecording:
      return pigeonError("当前没有正在录制的视频", code: "camera_not_recording")
    case .transitionInProgress:
      let message = switch operation {
      case .start: "录像状态正在切换"
      case .split: "上一段录像正在保存"
      case .stop: "请等待当前分段保存完成"
      }
      return pigeonError(message, code: "camera_busy")
    }
  }

  func getDiagnostics(
    completion: @escaping (Result<[String?: Any?]?, Error>) -> Void
  ) {
    let device = videoDeviceInput?.device
    let size = portraitSize
    let usesHevc = preferredVideoCodec.lowercased() == "hevc"
    let scanState = metadataQueue.sync { (pairingScanEnabled, workScanEnabled) }
    let audioSession = AVAudioSession.sharedInstance()
    let audioOptions = audioSession.categoryOptions
    let audioOptionNames = Self.audioSessionCategoryOptionNames(audioOptions)
    let audioRoute = audioSession.currentRoute
    let lastSegment = lastSegmentDiagnosticsSnapshot()
    let performance = performanceDiagnosticsSnapshot()
    completion(.success([
      "device": [
        "manufacturer": "Apple",
        "model": UIDevice.current.model,
        "sdkInt": 0,
        "release": UIDevice.current.systemVersion,
      ],
      "camera": [
        "initialized": true,
        "sessionRunning": session.isRunning,
        "previewActive": previewActive,
        "disposed": isDisposed,
        "workScanEnabled": scanState.1,
        "pairingScanEnabled": scanState.0,
        "metadataOutputAttached": metadataOutput != nil,
        "videoOutputAttached": videoOutput != nil,
        "audioOutputAttached": audioOutput != nil,
        "recordingAudioActive": recordingAudioActive,
        "currentAudioSampleCount": currentAudioSampleCount,
        "currentAudioAppendFailedCount": currentAudioAppendFailedCount,
        "currentAudioLastError": currentAudioLastError,
        "currentAudioEnergyProbeCount": currentAudioEnergyProbeCount,
        "currentAudioLowEnergyProbeCount": currentAudioLowEnergyProbeCount,
        "currentAudioPeak": currentAudioPeak,
        "liveWatermarkFailed": currentWatermarkFailed,
        "liveWatermarkError": currentWatermarkError,
        "lastAudioSampleCount": lastAudioSampleCount,
        "lastAudioAppendFailedCount": lastAudioAppendFailedCount,
        "lastAudioLastError": lastAudioLastError,
        "lastAudioEnergyProbeCount": lastAudioEnergyProbeCount,
        "lastAudioLowEnergyProbeCount": lastAudioLowEnergyProbeCount,
        "lastAudioPeak": lastAudioPeak,
        "audioSessionCategory": audioSession.category.rawValue,
        "audioSessionMode": audioSession.mode.rawValue,
        "audioSessionCategoryOptions": audioOptionNames,
        "audioSessionCategoryOptionsRawValue": Int64(audioOptions.rawValue),
        "audioSessionRouteInputs": audioRoute.inputs.map(Self.audioPortSnapshot),
        "audioSessionRouteOutputs": audioRoute.outputs.map(Self.audioPortSnapshot),
        "lastSegmentWriterStatus": lastSegment.writerStatus,
        "lastSegmentWriterError": lastSegment.writerError,
        "lastSegmentAudioTrackCheckSucceeded": lastSegment.trackCheckSucceeded,
        "lastSegmentAudioTrackCount": lastSegment.trackCount,
        "lastSegmentAudioTrackPresent": lastSegment.trackPresent,
        "lastSegmentAudioTrackInspectionError": lastSegment.trackInspectionError,
        "lastCameraOperationTiming": performance.operation,
        "lastFirstWrittenVideoFrameTiming": performance.firstWrittenFrame,
        "cameraPipelineVersion": 1,
        "recordingSpec": recordingSpecName,
        "cameraId": device?.uniqueID ?? "",
        "videoWidth": size.width,
        "videoHeight": size.height,
        "analysisWidth": size.width,
        "analysisHeight": size.height,
        "videoMime": usesHevc ? "video/hevc" : "video/avc",
      ],
    ]))
  }

  private static func audioSessionCategoryOptionNames(
    _ options: AVAudioSession.CategoryOptions
  ) -> [String] {
    var names: [String] = []
    if options.contains(.mixWithOthers) {
      names.append("mixWithOthers")
    }
    if options.contains(.duckOthers) {
      names.append("duckOthers")
    }
    if options.contains(.interruptSpokenAudioAndMixWithOthers) {
      names.append("interruptSpokenAudioAndMixWithOthers")
    }
    if options.contains(.allowBluetooth) {
      names.append("allowBluetooth")
    }
    if options.contains(.allowBluetoothA2DP) {
      names.append("allowBluetoothA2DP")
    }
    if options.contains(.allowAirPlay) {
      names.append("allowAirPlay")
    }
    if options.contains(.defaultToSpeaker) {
      names.append("defaultToSpeaker")
    }
    if options.contains(.overrideMutedMicrophoneInterruption) {
      names.append("overrideMutedMicrophoneInterruption")
    }
    return names
  }

  private static func audioPortSnapshot(
    _ port: AVAudioSessionPortDescription
  ) -> [String: Any] {
    [
      "type": port.portType.rawValue,
    ]
  }

  private func lastSegmentDiagnosticsSnapshot() -> (
    writerStatus: String?,
    writerError: String?,
    trackCheckSucceeded: Bool?,
    trackCount: Int64?,
    trackPresent: Bool?,
    trackInspectionError: String?
  ) {
    let state = lastSegmentDiagnostics.currentState()
    return (
      state.writerStatus,
      state.writerError,
      state.trackCheckSucceeded,
      state.trackCount,
      state.trackPresent,
      state.trackInspectionError
    )
  }

  private func performanceDiagnosticsSnapshot() -> (
    operation: [String: Any]?,
    firstWrittenFrame: [String: Any]?
  ) {
    performanceLock.lock()
    let operation = lastOperationTiming
    performanceLock.unlock()
    return (operation, firstWrittenFrameTiming.snapshot())
  }

  private func finishPerformanceOperation(
    _ timing: IosCameraOperationTiming,
    signpostID: OSSignpostID,
    signpostName: StaticString,
    succeeded: Bool
  ) {
    guard let snapshot = timing.finish(succeeded: succeeded) else { return }
    performanceLock.lock()
    lastOperationTiming = snapshot
    performanceLock.unlock()
    os_signpost(
      .end,
      log: Self.performanceLog,
      name: signpostName,
      signpostID: signpostID,
      "operation=%{public}@ succeeded=%{public}d total_ms=%{public}lld",
      timing.operation as NSString,
      succeeded ? 1 : 0,
      snapshot["totalMs"] as? Int64 ?? 0
    )
  }

  private static func finishDetachedPerformanceOperation(
    _ timing: IosCameraOperationTiming,
    signpostID: OSSignpostID,
    signpostName: StaticString,
    succeeded: Bool
  ) {
    guard let snapshot = timing.finish(succeeded: succeeded) else { return }
    os_signpost(
      .end,
      log: performanceLog,
      name: signpostName,
      signpostID: signpostID,
      "operation=%{public}@ succeeded=%{public}d total_ms=%{public}lld",
      timing.operation as NSString,
      succeeded ? 1 : 0,
      snapshot["totalMs"] as? Int64 ?? 0
    )
  }

  private func recordPerformanceStage<T>(
    _ stage: String,
    operation: String,
    signpostName: StaticString,
    timing: IosCameraOperationTiming,
    action: () throws -> T
  ) rethrows -> T {
    let signpostID = OSSignpostID(log: Self.performanceLog)
    let startedAtNs = DispatchTime.now().uptimeNanoseconds
    os_signpost(
      .begin,
      log: Self.performanceLog,
      name: signpostName,
      signpostID: signpostID,
      "operation=%{public}@",
      operation as NSString
    )
    defer {
      let durationMs = IosCameraOperationTiming.elapsedMilliseconds(
        from: startedAtNs,
        to: DispatchTime.now().uptimeNanoseconds
      )
      timing.record(stage: stage, durationMs: durationMs)
      os_signpost(
        .end,
        log: Self.performanceLog,
        name: signpostName,
        signpostID: signpostID,
        "operation=%{public}@ duration_ms=%{public}lld",
        operation as NSString,
        durationMs
      )
    }
    return try action()
  }

  func setPairingScanEnabled(
    enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    metadataQueue.async { [weak self] in
      guard let self else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      self.pairingScanEnabled = enabled
      if !self.pairingScanEnabled && !self.workScanEnabled {
        self.barcodeBatchGate.discardPending()
      }
      completion(.success(()))
    }
  }

  func setWorkScanEnabled(
    enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    metadataQueue.async { [weak self] in
      guard let self else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      self.workScanEnabled = enabled
      if !self.pairingScanEnabled && !self.workScanEnabled {
        self.barcodeBatchGate.discardPending()
      }
      completion(.success(()))
    }
  }

  func setPreviewActive(
    active: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, !self.isDisposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      guard self.currentPath == nil else {
        completion(.failure(pigeonError(
          "录像期间不能暂停摄像头",
          code: "camera_busy"
        )))
        return
      }
      self.previewActive = active
      if active {
        self.configureOutputDelegates()
        if !self.session.isRunning {
          self.session.startRunning()
        }
        guard self.session.isRunning else {
          completion(.failure(pigeonError(
            "摄像头恢复失败",
            code: "preview_resume_failed"
          )))
          return
        }
      } else {
        self.metadataQueue.sync {
          self.barcodeGeneration &+= 1
          self.barcodeBatchGate.reset()
        }
        if self.session.isRunning {
          self.session.stopRunning()
        }
      }
      completion(.success(()))
    }
  }

  func setTorchEnabled(
    enabled: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, let device = self.videoDeviceInput?.device, device.hasTorch else {
        completion(.success(false))
        return
      }
      do {
        try device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
        completion(.success(true))
      } catch {
        completion(.success(false))
      }
    }
  }

  func switchCamera(
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    let targetPosition: AVCaptureDevice.Position =
      videoDeviceInput?.device.position == .back ? .front : .back
    switchToPosition(targetPosition, completion: completion)
  }

  func listCameras(
    completion: @escaping (Result<[CameraLensDto], Error>) -> Void
  ) {
    completion(.success(backCameraLenses()))
  }

  func switchToCamera(
    cameraId: String,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    guard let device = AVCaptureDevice(uniqueID: cameraId) else {
      completion(.failure(pigeonError("找不到指定的摄像头")))
      return
    }
    replaceVideoDevice(device, completion: completion)
  }

  func probeSequence(
    sequence: String,
    budgetMs: Int64,
    completion: @escaping (Result<[String?: Any?]?, Error>) -> Void
  ) {
    completion(.failure(
      IosCameraCapabilityPolicy.probeUnsupportedError(sequence: sequence)
    ))
  }

  func setCapabilityMode(mode: String) throws {
    throw IosCameraCapabilityPolicy.modeSwitchUnsupportedError(mode: mode)
  }

  func dispose(completion: @escaping (Result<Void, Error>) -> Void) {
    recordingActivityState.setActive(false, owner: recordingActivityOwner)
    markDisposed()
    recordingLifecycle.dispose()
    firstWrittenFrameTiming.cancelIfNeeded()
    // 先移除采样回调，避免 App 终止时 AVCaptureSession 再回调到已释放的
    // self，触发 use-after-free（SIGSEGV）。
    clearOutputDelegates()
    sessionQueue.async { [weak self] in
      guard let self else {
        completion(.success(()))
        return
      }
      self.finishCurrentWriter { _ in }
      if self.session.isRunning {
        self.session.stopRunning()
      }
      let textureId = self.currentTextureId
      if textureId >= 0 {
        self.textures.unregisterTexture(textureId)
        self.updateTextureId(-1)
      }
      do {
        try self.releaseRecordingAudioSession()
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  /// 终止前同步停止相机并解除纹理注册，保证之后 Flutter 引擎可安全销毁。
  func prepareForTermination() {
    recordingActivityState.setActive(false, owner: recordingActivityOwner)
    markDisposed()
    recordingLifecycle.dispose()
    firstWrittenFrameTiming.cancelIfNeeded()
    clearOutputDelegates()
    if let observer = runtimeErrorObserver {
      NotificationCenter.default.removeObserver(observer)
      runtimeErrorObserver = nil
    }
    sessionQueue.sync { [weak self] in
      guard let self else { return }
      self.finishCurrentWriter(false) { _ in }
      if self.session.isRunning {
        self.session.stopRunning()
      }
      do {
        try self.releaseRecordingAudioSession()
      } catch {
        NSLog(
          "PackingProof failed to release camera audio session during termination: %@",
          error.localizedDescription
        )
      }
      let textureId = self.currentTextureId
      if textureId >= 0 {
        self.textures.unregisterTexture(textureId)
        self.updateTextureId(-1)
      }
    }
    metadataQueue.sync {}
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard let latestPixelBuffer else { return nil }
    return Unmanaged.passRetained(latestPixelBuffer)
  }

  // MARK: - AVCapture delegates

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !isDisposed else { return }
    if output === videoOutput {
      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        return
      }
      var shouldAppendVideo = true
      var transientWatermarkFailure = false
      let watermarkRequired = IosLiveWatermarkHostPolicy.canMaintainPreview(
        writerActive: writer != nil,
        preservingSplit: preservesWatermarkDuringSplit
      )
        && !currentTrackingNumber.isEmpty
        && !currentWatermarkFailed
      if watermarkRequired {
        do {
          try liveWatermarkRenderer.apply(
            to: pixelBuffer,
            orientation: recordingOrientationName,
            trackingNumber: currentTrackingNumber
          )
        } catch let error where iosLiveWatermarkErrorIsTransient(error) {
          transientWatermarkFailure = true
          if writer != nil {
            shouldAppendVideo = false
          }
          prepareInitialWatermarkPlanIfNeeded(from: pixelBuffer)
        } catch {
          if writer != nil {
            currentWatermarkFailed = true
            currentWatermarkError = String(describing: error)
            eventApi.nativeError(
              message: "录像继续保存，但实时水印写入失败",
              completion: { _ in }
            )
          }
        }
      }
      if IosLiveWatermarkHostPolicy.shouldPublishPreviewFrame(
        watermarkRequired: watermarkRequired,
        transientPreparationFailure: transientWatermarkFailure
      ) {
        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()
        let textureId = currentTextureId
        if textureId >= 0 && !isDisposed {
          textures.textureFrameAvailable(textureId)
        }
      }
      if shouldAppendVideo {
        appendVideo(sampleBuffer, pixelBuffer: pixelBuffer)
      }
    } else if output === audioOutput {
      appendAudio(sampleBuffer)
    }
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard !isDisposed else { return }
    guard pairingScanEnabled || workScanEnabled else { return }
    let detectedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    var candidates: [BarcodeCandidateDto] = []
    for object in metadataObjects {
      guard let machineReadable = object as? AVMetadataMachineReadableCodeObject,
            let value = machineReadable.stringValue else {
        continue
      }
      let bounds = machineReadable.bounds
      let area = Int64(max(1, Int(bounds.width * bounds.height * 1_000_000)))
      candidates.append(BarcodeCandidateDto(
        value: value,
        area: area,
        format: metadataTypeName(machineReadable.type),
        detectedAtMs: detectedAtMs
      ))
    }
    if !candidates.isEmpty {
      handleBarcodeBatchAction(barcodeBatchGate.submit(
        candidates,
        now: ProcessInfo.processInfo.systemUptime
      ), generation: barcodeGeneration)
    }
  }

  private func handleBarcodeBatchAction(
    _ action: IosLatestPendingGate<[BarcodeCandidateDto]>.Action,
    generation: UInt64
  ) {
    switch action {
    case .none:
      return
    case .send(let candidates):
      eventApi.barcodeBatch(candidates: candidates) { [weak self] _ in
        guard let self else { return }
        self.metadataQueue.async { [weak self] in
          guard let self else { return }
          guard generation == self.barcodeGeneration else { return }
          guard !self.isDisposed,
                self.pairingScanEnabled || self.workScanEnabled else {
            self.barcodeBatchGate.discardPending()
            _ = self.barcodeBatchGate.complete(
              now: ProcessInfo.processInfo.systemUptime
            )
            return
          }
          self.handleBarcodeBatchAction(self.barcodeBatchGate.complete(
            now: ProcessInfo.processInfo.systemUptime
          ), generation: generation)
        }
      }
    case .schedule(let delay):
      metadataQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self else { return }
        guard generation == self.barcodeGeneration else { return }
        guard !self.isDisposed,
              self.pairingScanEnabled || self.workScanEnabled else {
          self.barcodeBatchGate.discardPending()
          _ = self.barcodeBatchGate.wake(
            now: ProcessInfo.processInfo.systemUptime
          )
          return
        }
        self.handleBarcodeBatchAction(self.barcodeBatchGate.wake(
          now: ProcessInfo.processInfo.systemUptime
        ), generation: generation)
      }
    }
  }

  // MARK: - Session configuration

  private func configureSession() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.session.beginConfiguration()
      self.session.sessionPreset = .hd1920x1080

      if let videoDevice = Self.defaultVideoDevice(position: .back) {
        do {
          let input = try AVCaptureDeviceInput(device: videoDevice)
          if self.session.canAddInput(input) {
            self.session.addInput(input)
            self.videoDeviceInput = input
          }
        } catch {
          self.eventApi.nativeError(
            message: "打开摄像头失败：\(error.localizedDescription)",
            completion: { _ in }
          )
        }
      }

      let videoOutput = AVCaptureVideoDataOutput()
      // 保持系统缺省的丢弃迟到帧语义，避免视频帧在串行 sessionQueue 上堆积，
      // 进而把 metadata 回调（扫码）长时间排挤掉，导致「偶尔能扫上、大部分扫不上」。
      videoOutput.alwaysDiscardsLateVideoFrames = true
      videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      if self.session.canAddOutput(videoOutput) {
        self.session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
          // Flutter 纹理和写入器都使用固定 1080x1920 缓冲；最终方向只写入
          // AVAssetWriterInput.transform，避免横屏设置物理旋转采集帧。
          connection.videoOrientation = .portrait
          connection.automaticallyAdjustsVideoMirroring = false
          connection.isVideoMirrored = iosRecordingCaptureShouldMirror(
            frontCamera: self.videoDeviceInput?.device.position == .front
          )
        }
        self.videoOutput = videoOutput
      }

      let audioOutput = AVCaptureAudioDataOutput()
      if self.session.canAddOutput(audioOutput) {
        self.session.addOutput(audioOutput)
        self.audioOutput = audioOutput
      }

      let metadataOutput = AVCaptureMetadataOutput()
      if self.session.canAddOutput(metadataOutput) {
        self.session.addOutput(metadataOutput)
        let availableTypes = metadataOutput.availableMetadataObjectTypes
        metadataOutput.metadataObjectTypes = Self.supportedMetadataTypes.filter {
          availableTypes.contains($0)
        }
        self.metadataOutput = metadataOutput
      }

      self.session.commitConfiguration()
      self.configureOutputDelegates()
    }
  }

  /// 幂等地重挂 video/audio/metadata 的 delegate：只覆盖 delegate 与 queue，
  /// 不创建新 output、不创建新 queue、不改变 output 数量。
  private func configureOutputDelegates() {
    videoOutput?.setSampleBufferDelegate(self, queue: sessionQueue)
    audioOutput?.setSampleBufferDelegate(self, queue: sessionQueue)
    // 扫码回调走独立队列，避免与视频帧写入 / AVAssetWriter 在 sessionQueue 上排队。
    metadataOutput?.setMetadataObjectsDelegate(self, queue: metadataQueue)
  }

  /// 摘除全部 delegate，避免已释放对象再收到回调。
  private func clearOutputDelegates() {
    videoOutput?.setSampleBufferDelegate(nil, queue: nil)
    audioOutput?.setSampleBufferDelegate(nil, queue: nil)
    metadataOutput?.setMetadataObjectsDelegate(nil, queue: nil)
  }

  /// 录像期音频会话：同时支持录音与播放提示音，避免被 .playback 降级。
  private func acquireRecordingAudioSessionIfNeeded() throws {
    guard !cameraAudioSessionHeld else { return }
    try audioSessionCoordinator.acquire(.camera)
    cameraAudioSessionHeld = true
  }

  private func restoreRecordingAudioSession() throws {
    if !cameraAudioSessionHeld {
      try acquireRecordingAudioSessionIfNeeded()
      return
    }
    try audioSessionCoordinator.ensureActive(for: .camera)
  }

  private func releaseRecordingAudioSession() throws {
    guard cameraAudioSessionHeld else { return }
    try audioSessionCoordinator.release(.camera)
    cameraAudioSessionHeld = false
  }

  /// 工作开始前只负责让会话可运行，不重注册纹理、不处理 dispose 恢复。
  private func ensureRunningForWork() throws {
    if recordAudio {
      try restoreRecordingAudioSession()
    }
    try addAudioInputIfNeeded()
    configureOutputDelegates()
    try restoreMetadataOutputForWork()
    guard outputsAreValidForWork() else {
      throw pigeonError(
        "摄像头输出状态异常",
        code: "camera_outputs_invalid"
      )
    }
    if !session.isRunning {
      session.startRunning()
    }
    guard session.isRunning else {
      throw pigeonError(
        "摄像头会话未运行",
        code: "camera_session_not_running"
      )
    }
  }

  /// 恢复扫码输出配置。`AVCaptureOutput.connections` 本身只包含该 output
  /// 的 connection，因此从其中取出的首个 connection 即为当前 metadata output
  /// 的有效 connection；这里不遍历 session 中其他 output 的 connection。
  private func restoreMetadataOutputForWork() throws {
    guard let metadataOutput else {
      throw pigeonError(
        "摄像头输出状态异常",
        code: "camera_outputs_invalid"
      )
    }
    let availableTypes = metadataOutput.availableMetadataObjectTypes
    let configuredTypes = Self.supportedMetadataTypes.filter {
      availableTypes.contains($0)
    }
    guard !configuredTypes.isEmpty else {
      throw pigeonError(
        "当前设备不支持扫码类型",
        code: "metadata_types_unavailable"
      )
    }
    metadataOutput.metadataObjectTypes = configuredTypes
    guard !metadataOutput.metadataObjectTypes.isEmpty else {
      throw pigeonError(
        "扫码输出配置失败",
        code: "metadata_types_unavailable"
      )
    }
    guard let connection = metadataOutput.connections.first else {
      throw pigeonError(
        "扫码输出连接不可用",
        code: "metadata_connection_unavailable"
      )
    }
    connection.isEnabled = true
  }

  /// 校验三个 output 均仍挂载在当前 session 上。
  private func outputsAreValid() -> Bool {
    let outputs = session.outputs
    let videoValid = videoOutput.map { outputs.contains($0) } ?? false
    let audioValid = audioOutput.map { outputs.contains($0) } ?? false
    let metadataValid = metadataOutput.map { outputs.contains($0) } ?? false
    return videoValid && audioValid && metadataValid
  }

  private func outputsAreValidForWork() -> Bool {
    let outputs = session.outputs
    let videoValid = videoOutput.map { outputs.contains($0) } ?? false
    let metadataValid = metadataOutput.map { outputs.contains($0) } ?? false
    let audioValid = !recordAudio || (audioOutput.map { outputs.contains($0) } ?? false)
    return videoValid && metadataValid && audioValid
  }

  private func addAudioInputIfNeeded() throws {
    guard recordAudio else { return }
    if let audioDeviceInput, session.inputs.contains(audioDeviceInput) {
      return
    }
    let wasRunning = session.isRunning
    if wasRunning {
      session.stopRunning()
    }
    guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
      throw pigeonError("未找到麦克风输入", code: "audio_input_missing")
    }
    do {
      let input = try AVCaptureDeviceInput(device: audioDevice)
      guard session.canAddInput(input) else {
        throw pigeonError("无法添加麦克风输入", code: "audio_input_missing")
      }
      session.addInput(input)
      audioDeviceInput = input
    } catch {
      if wasRunning {
        session.startRunning()
      }
      throw error
    }
  }

  /// 恢复已 dispose 的相机：校验 outputs → 重注册纹理 → 重挂 delegate →
  /// 重启 session，并在短时间内有界确认运行状态。
  private func recoverCamera(completion: @escaping (Bool) -> Void) {
    recoveryRuntimeError = false
    guard outputsAreValid() else {
      completion(false)
      return
    }
    if currentTextureId < 0 {
      let newId = textures.register(self)
      guard newId >= 0 else {
        completion(false)
        return
      }
      updateTextureId(newId)
    }
    configureOutputDelegates()
    if !session.isRunning {
      session.startRunning()
    }
    sessionQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
      guard let self else {
        completion(false)
        return
      }
      if self.session.isRunning && !self.recoveryRuntimeError {
        completion(true)
      } else {
        self.rollbackRecovery()
        completion(false)
      }
    }
  }

  /// 恢复失败时回滚纹理与 delegate，保持 disposed 状态干净。
  private func rollbackRecovery() {
    clearOutputDelegates()
    let textureId = currentTextureId
    if textureId >= 0 {
      textures.unregisterTexture(textureId)
      updateTextureId(-1)
    }
  }

  /// 初始化完成：发 sessionStarted 事件并返回初始化结果。
  private func finishInitialize(
    _ completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    eventApi.sessionStarted(
      event: CameraSessionStartedDto(
        sessionId: sessionId,
        startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
      ),
      completion: { _ in }
    )
    completion(.success(initializationDto()))
  }

  private func replaceVideoDevice(
    _ device: AVCaptureDevice,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, !self.isDisposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      do {
        let input = try AVCaptureDeviceInput(device: device)
        self.session.beginConfiguration()
        if let oldInput = self.videoDeviceInput {
          self.session.removeInput(oldInput)
        }
        guard self.session.canAddInput(input) else {
          self.session.commitConfiguration()
          completion(.failure(pigeonError("无法切换到该摄像头")))
          return
        }
        self.session.addInput(input)
        self.videoDeviceInput = input
        self.session.commitConfiguration()
        if let connection = self.videoOutput?.connection(with: .video) {
          // 切换镜头后仍保持竖屏采集，并显式固定前摄镜像语义。
          connection.videoOrientation = .portrait
          connection.automaticallyAdjustsVideoMirroring = false
          connection.isVideoMirrored = iosRecordingCaptureShouldMirror(
            frontCamera: device.position == .front
          )
        }
        completion(.success(self.initializationDto()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  private func switchToPosition(
    _ position: AVCaptureDevice.Position,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    guard let device = Self.defaultVideoDevice(position: position) else {
      completion(.failure(pigeonError("找不到可切换的摄像头")))
      return
    }
    replaceVideoDevice(device, completion: completion)
  }

  private func initializationDto() -> CameraInitializationDto {
    let device = videoDeviceInput?.device
    let size = portraitSize
    let usesHevc = preferredVideoCodec.lowercased() == "hevc"
    return CameraInitializationDto(
      textureId: currentTextureId,
      previewWidth: Int64(size.width),
      previewHeight: Int64(size.height),
      sensorOrientation: 0,
      fps: 30,
      videoMime: usesHevc ? "video/hevc" : "video/avc",
      codecFallbackReason: codecFallbackReason,
      flashAvailable: device?.hasTorch == true,
      lensDirection: device?.position == .front ? "front" : "back",
      canSwitchCamera: Self.hasFrontCamera && Self.hasBackCamera,
      cameraId: device?.uniqueID,
      zoomRatio: Double(device?.videoZoomFactor ?? 1)
    )
  }

  // MARK: - Recording

  private func startWriter(
    path: String,
    trackingNumber: String,
    operation: String,
    timing: IosCameraOperationTiming
  ) throws {
    let stagePrefix = operation == "split" ? "next" : ""
    if recordAudio {
      try recordPerformanceStage(
        stagePrefix.isEmpty ? "audioSession" : "nextAudioSession",
        operation: operation,
        signpostName: "CameraAudioSession",
        timing: timing,
        action: acquireRecordingAudioSessionIfNeeded
      )
    }
    let setup = try recordPerformanceStage(
      stagePrefix.isEmpty ? "writerSetup" : "nextWriterSetup",
      operation: operation,
      signpostName: "CameraWriterSetup",
      timing: timing
    ) { () throws -> (
      writer: AVAssetWriter,
      videoInput: AVAssetWriterInput,
      audioInput: AVAssetWriterInput?,
      adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) in
      let url = URL(fileURLWithPath: path)
      try? FileManager.default.removeItem(at: url)
      let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
      let codec: AVVideoCodecType =
        preferredVideoCodec.lowercased() == "hevc" ? .hevc : .h264
      let size = portraitSize
      let videoSettings: [String: Any] = [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 8_000_000,
          AVVideoExpectedSourceFrameRateKey: 30,
        ],
      ]
      let videoInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: videoSettings
      )
      videoInput.expectsMediaDataInRealTime = true
      videoInput.transform = iosRecordingTransform(for: recordingOrientationName)
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: size.width,
          kCVPixelBufferHeightKey as String: size.height,
        ]
      )

      var audioInput: AVAssetWriterInput?
      if recordAudio {
        guard audioOutput != nil else {
          throw pigeonError(
            "未找到麦克风输入",
            code: "audio_input_missing"
          )
        }
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: 48_000,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 96_000,
        ]
        audioInput = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: settings
        )
        audioInput?.expectsMediaDataInRealTime = true
      }

      if writer.canAdd(videoInput) {
        writer.add(videoInput)
      } else {
        throw pigeonError("无法创建录像视频轨道")
      }
      if let audioInput {
        guard writer.canAdd(audioInput) else {
          throw pigeonError(
            "无法创建录像声音轨道",
            code: "audio_track_creation_failed"
          )
        }
        writer.add(audioInput)
      }
      return (writer, videoInput, audioInput, adaptor)
    }
    let writer = setup.writer
    let videoInput = setup.videoInput
    let audioInput = setup.audioInput
    let adaptor = setup.adaptor

    var watermarkPrepared = false
    let watermarkSourceBuffer: CVPixelBuffer? = recordPerformanceStage(
      stagePrefix.isEmpty ? "watermarkPrepare" : "nextWatermarkPrepare",
      operation: operation,
      signpostName: "CameraWatermarkPrepare",
      timing: timing
    ) {
      bufferLock.lock()
      let source = latestPixelBuffer
      bufferLock.unlock()
      if let source {
        do {
          try liveWatermarkRenderer.prepare(
            to: source,
            orientation: recordingOrientationName,
            trackingNumber: trackingNumber
          )
          watermarkPrepared = true
        } catch {
          currentWatermarkError = String(describing: error)
        }
      } else {
        liveWatermarkRenderer.reset()
      }
      return source
    }
    watermarkPreparationPending = false

    try recordPerformanceStage(
      stagePrefix.isEmpty ? "startWriting" : "nextStartWriting",
      operation: operation,
      signpostName: "CameraWriterStartWriting",
      timing: timing
    ) {
      guard writer.startWriting() else {
        throw writer.error ?? pigeonError("开始录像失败")
      }
    }
    self.writer = writer
    self.videoInput = videoInput
    self.audioInput = audioInput
    self.pixelBufferAdaptor = adaptor
    self.currentPath = path
    self.currentTrackingNumber = trackingNumber
    // 同步首帧准备失败时仍允许专用队列重试；只有异步准备也失败才把本段
    // 标记为 partial，避免一次瞬时栅格化失败让整段永久失去水印。
    self.currentWatermarkFailed = false
    if watermarkPrepared || watermarkSourceBuffer == nil {
      self.currentWatermarkError = nil
    }
    self.preservesWatermarkDuringSplit = false
    self.currentSegmentId = UUID().uuidString
    self.currentStartedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    self.currentSegmentSerial += 1
    self.writerSessionStarted = false
    firstWrittenFrameTiming.begin(operation: operation)
    self.recordingAudioActive = recordAudio && audioInput != nil
    self.currentAudioSampleCount = 0
    self.currentAudioAppendFailedCount = 0
    self.currentAudioLastError = nil
    self.currentAudioEnergyProbeCount = 0
    self.currentAudioLowEnergyProbeCount = 0
    self.currentAudioPeak = 0
    // 常规路径已在 writer 对外可见前准备好首份完整水印。没有预览帧或
    // 同步准备瞬时失败时才走后台重试；就绪前不写入无水印视频帧。
    if !watermarkPrepared, let watermarkSourceBuffer {
      prepareInitialWatermarkPlanIfNeeded(from: watermarkSourceBuffer)
    }
  }

  private func prepareInitialWatermarkPlanIfNeeded(from pixelBuffer: CVPixelBuffer) {
    guard !watermarkPreparationPending,
          IosLiveWatermarkHostPolicy.canMaintainPreview(
            writerActive: writer != nil,
            preservingSplit: preservesWatermarkDuringSplit
          ),
          !currentWatermarkFailed else {
      return
    }
    watermarkPreparationPending = true
    let segmentSerial = currentSegmentSerial
    let orientation = recordingOrientationName
    let trackingNumber = currentTrackingNumber
    liveWatermarkRenderer.prepareAsynchronously(
      to: pixelBuffer,
      orientation: orientation,
      trackingNumber: trackingNumber
    ) { [weak self] result in
      guard let self else { return }
      self.sessionQueue.async {
        guard IosLiveWatermarkHostPolicy.canMaintainPreview(
                writerActive: self.writer != nil,
                preservingSplit: self.preservesWatermarkDuringSplit
              ),
              self.currentSegmentSerial == segmentSerial else {
          return
        }
        self.watermarkPreparationPending = false
        if case .failure(let error) = result {
          if !IosLiveWatermarkHostPolicy.preparationFailureIsFatal(error) {
            return
          }
          self.currentWatermarkFailed = true
          self.currentWatermarkError = String(describing: error)
          self.eventApi.nativeError(
            message: "录像继续保存，但实时水印准备失败",
            completion: { _ in }
          )
        }
      }
    }
  }

  private func clearPreservedWatermarkPreview() {
    guard IosLiveWatermarkHostPolicy.shouldClearPreservedPreview(
      writerActive: writer != nil,
      preservingSplit: preservesWatermarkDuringSplit
    ) else { return }
    preservesWatermarkDuringSplit = false
    currentTrackingNumber = ""
    currentWatermarkFailed = false
    currentWatermarkError = nil
    liveWatermarkRenderer.reset()
    watermarkPreparationPending = false
  }

  private func appendVideo(_ sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) {
    guard let writer, let videoInput, writer.status == .writing else { return }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if !writerSessionStarted {
      writer.startSession(atSourceTime: timestamp)
      writerSessionStarted = true
    }
    IosCameraVideoAppendPolicy.appendWhenReady(
      isReady: videoInput.isReadyForMoreMediaData,
      append: { [pixelBufferAdaptor] in
        pixelBufferAdaptor?.append(
          pixelBuffer,
          withPresentationTime: timestamp
        ) == true
      },
      onWritten: { [firstWrittenFrameTiming] in
        firstWrittenFrameTiming.recordWrittenFrameIfNeeded()
      }
    )
  }

  private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    guard let writer, let audioInput, writer.status == .writing,
          writerSessionStarted, audioInput.isReadyForMoreMediaData else {
      return
    }
    currentAudioSampleCount += 1
    if currentAudioSampleCount.isMultiple(of: 30),
       let peak = IosAudioSampleEnergyProbe.normalizedPeak(in: sampleBuffer) {
      currentAudioEnergyProbeCount += 1
      currentAudioPeak = max(currentAudioPeak, peak)
      if peak < 0.0005 {
        currentAudioLowEnergyProbeCount += 1
      }
    }
    if !audioInput.append(sampleBuffer) {
      currentAudioAppendFailedCount += 1
      if currentAudioLastError == nil {
        currentAudioLastError =
          writer.error?.localizedDescription ?? "声音样本写入失败"
      }
    }
  }

  private func finishCurrentWriter(
    _ sendEvents: Bool = true,
    preserveWatermarkPreview: Bool = false,
    timeout: TimeInterval = 5,
    completion: @escaping (Result<CameraWatermarkDisposition, Error>) -> Void
  ) {
    guard let writer else {
      completion(.failure(IosCameraWriterFinishPolicy.missingWriterError()))
      return
    }
    firstWrittenFrameTiming.cancelIfNeeded()
    let completedPath = currentPath
    let completedStartedAt = currentStartedAtMs
    let completedSegmentId = currentSegmentId
    let completedSegmentSerial = currentSegmentSerial
    let completedWatermarkDisposition: CameraWatermarkDisposition =
      currentWatermarkFailed ? .failedPartial : .completed
    let endedAt = Int64(Date().timeIntervalSince1970 * 1000)
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()
    self.writer = nil
    self.videoInput = nil
    self.audioInput = nil
    self.pixelBufferAdaptor = nil
    self.currentPath = nil
    self.preservesWatermarkDuringSplit = preserveWatermarkPreview
    if !preserveWatermarkPreview {
      self.currentTrackingNumber = ""
      self.currentWatermarkFailed = false
      self.currentWatermarkError = nil
      self.liveWatermarkRenderer.reset()
    }
    self.watermarkPreparationPending = false
    writerSessionStarted = false
    lastAudioSampleCount = currentAudioSampleCount
    lastAudioAppendFailedCount = currentAudioAppendFailedCount
    lastAudioLastError = currentAudioLastError
    lastAudioEnergyProbeCount = currentAudioEnergyProbeCount
    lastAudioLowEnergyProbeCount = currentAudioLowEnergyProbeCount
    lastAudioPeak = currentAudioPeak
    currentAudioSampleCount = 0
    currentAudioAppendFailedCount = 0
    currentAudioLastError = nil
    currentAudioEnergyProbeCount = 0
    currentAudioLowEnergyProbeCount = 0
    currentAudioPeak = 0
    recordingAudioActive = false

    let finishLock = NSLock()
    var didFinish = false
    let timeoutItem = DispatchWorkItem { [weak self] in
      finishLock.lock()
      guard !didFinish else {
        finishLock.unlock()
        return
      }
      didFinish = true
      finishLock.unlock()
      writer.cancelWriting()
      self?.recordLastSegmentResult(
        serial: completedSegmentSerial,
        writerStatus: "cancelled",
        writerError: "录像写入超时",
        path: nil,
        inspectionError: "录像写入超时"
      )
      if sendEvents, let completedPath {
        self?.eventApi.segmentFailed(
          event: CameraSegmentFailedDto(
            sessionId: self?.sessionId ?? "",
            segmentId: completedSegmentId,
            reason: "录像写入超时"
          ),
          completion: { _ in }
        )
      }
      completion(.failure(IosCameraWriterFinishPolicy.timeoutError()))
    }
    sessionQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

    writer.finishWriting { [weak self] in
      finishLock.lock()
      guard !didFinish else {
        finishLock.unlock()
        return
      }
      didFinish = true
      finishLock.unlock()
      timeoutItem.cancel()
      let writerStatus = writer.status
      let writerError = writer.error?.localizedDescription
      let finishResult = IosCameraWriterFinishPolicy.result(
        status: writerStatus,
        writerError: writerError
      )
      self?.recordLastSegmentResult(
        serial: completedSegmentSerial,
        writerStatus: Self.writerStatusName(writerStatus),
        writerError: writerError,
        path: writerStatus == .completed ? completedPath : nil,
        inspectionError: writerStatus == .completed
          ? nil
          : writerError ?? "录像文件写入失败"
      )
      if sendEvents {
        guard let self else {
          completion(finishResult.map { completedWatermarkDisposition })
          return
        }
        if writerStatus == .completed, let completedPath, !completedSegmentId.isEmpty {
          self.eventApi.segmentCompleted(
            event: CameraSegmentCompletedDto(
              sessionId: self.sessionId,
              segmentId: completedSegmentId,
              path: completedPath,
              startedAtMs: completedStartedAt,
              endedAtMs: endedAt
            ),
            completion: { _ in }
          )
        } else if let completedPath {
          self.eventApi.segmentFailed(
            event: CameraSegmentFailedDto(
              sessionId: self.sessionId,
              segmentId: completedSegmentId,
              reason: writer.error?.localizedDescription ?? "录像文件写入失败"
            ),
            completion: { _ in }
          )
        }
      }
      completion(finishResult.map { completedWatermarkDisposition })
    }
  }

  private static func writerStatusName(_ status: AVAssetWriter.Status) -> String {
    switch status {
    case .unknown:
      return "unknown"
    case .writing:
      return "writing"
    case .completed:
      return "completed"
    case .failed:
      return "failed"
    case .cancelled:
      return "cancelled"
    @unknown default:
      return "unknown"
    }
  }

  private func recordLastSegmentResult(
    serial: Int64,
    writerStatus: String,
    writerError: String?,
    path: String?,
    inspectionError: String?
  ) {
    let hasCompletedFile = path?.isEmpty == false
    guard lastSegmentDiagnostics.recordWriterResult(
      serial: serial,
      writerStatus: writerStatus,
      writerError: writerError,
      hasCompletedFile: hasCompletedFile,
      inspectionError: inspectionError
    ), let path else { return }

    // 音轨检查只用于诊断。同步读取 AVURLAsset tracks 会解析刚写完的 MP4，
    // 不能阻塞 split completion 和下一段 writer 的启动。
    inspectLastSegmentAudioTrack(serial: serial, path: path)
  }

  private func inspectLastSegmentAudioTrack(serial: Int64, path: String) {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    asset.loadTracks(withMediaType: .audio) { [weak self] tracks, error in
      guard let self else { return }
      if let error {
        self.lastSegmentDiagnostics.recordTrackResult(
          serial: serial,
          trackCount: nil,
          inspectionError: error.localizedDescription
        )
        return
      }
      self.lastSegmentDiagnostics.recordTrackResult(
        serial: serial,
        trackCount: tracks.map { Int64($0.count) },
        inspectionError: tracks == nil ? "无法读取录像声音轨道" : nil
      )
    }
  }

  private var isDisposed: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return disposed
  }

  private func markDisposed() {
    stateLock.lock()
    disposed = true
    stateLock.unlock()
  }

  private func markNotDisposed() {
    stateLock.lock()
    disposed = false
    stateLock.unlock()
    recordingLifecycle.resetAfterDispose()
  }

  private var currentTextureId: Int64 {
    stateLock.lock()
    defer { stateLock.unlock() }
    return textureId
  }

  private func updateTextureId(_ newValue: Int64) {
    stateLock.lock()
    textureId = newValue
    stateLock.unlock()
  }

  // MARK: - Helpers

  private func requestVideoAndAudioPermissions(
    recordAudio: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    AVCaptureDevice.requestAccess(for: .video) { videoGranted in
      guard videoGranted else {
        completion(false)
        return
      }
      guard recordAudio else {
        completion(true)
        return
      }
      AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
        completion(audioGranted)
      }
    }
  }

  private func backCameraLenses() -> [CameraLensDto] {
    Self.backDevices.map { device in
      CameraLensDto(
        cameraId: device.uniqueID,
        focalLength: 0,
        zoomRatio: Self.zoomRatio(for: device),
        isMain: device.deviceType == .builtInWideAngleCamera
      )
    }
  }

  private func metadataTypeName(_ type: AVMetadataObject.ObjectType) -> String {
    switch type {
    case .ean13: return "ean13"
    case .ean8: return "ean8"
    case .code128: return "code128"
    case .qr: return "qr"
    default: return type.rawValue
    }
  }

  private static let supportedMetadataTypes: [AVMetadataObject.ObjectType] = [
    .ean13,
    .ean8,
    .code128,
    .code39,
    .code93,
    .qr,
    .pdf417,
    .upce,
  ]

  private static let backDevices: [AVCaptureDevice] = {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [
        .builtInWideAngleCamera,
        .builtInUltraWideCamera,
        .builtInTelephotoCamera,
      ],
      mediaType: .video,
      position: .back
    ).devices
  }()

  private static let frontDevices: [AVCaptureDevice] = {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera],
      mediaType: .video,
      position: .front
    ).devices
  }()

  private static var hasBackCamera: Bool { !backDevices.isEmpty }
  private static var hasFrontCamera: Bool { !frontDevices.isEmpty }

  private static func defaultVideoDevice(
    position: AVCaptureDevice.Position
  ) -> AVCaptureDevice? {
    if position == .front {
      return frontDevices.first
    }
    // 显式优先主摄（广角）：DiscoverySession 的设备顺序没有文档保证，
    // 若把超广角排到首位，初始化或翻转回后置会落在 0.5x，导致条码过小扫不上。
    return backDevices.first(where: {
      $0.deviceType == .builtInWideAngleCamera
    }) ?? backDevices.first
  }

  private static func zoomRatio(for device: AVCaptureDevice) -> Double {
    switch device.deviceType {
    case .builtInUltraWideCamera: return 0.5
    case .builtInTelephotoCamera: return 2.0
    default: return 1.0
    }
  }

}
