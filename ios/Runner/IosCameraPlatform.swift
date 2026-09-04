import AVFoundation
import Vision
import os.signpost
import Flutter

class IosCameraPlatform: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate {

  // MARK: - Safe Performance Operations
  
  private func finishPerformanceOperation(
    _ timing: IosCameraOperationTiming,
    signpostID: OSSignpostID,
    signpostName: StaticString,
    succeeded: Bool
  ) {
    if let result = timing.finish(succeeded: succeeded) {
      performanceLock.lock()
      lastOperationTiming = result
      performanceLock.unlock()
      os_signpost(
        .end,
        log: Self.performanceLog,
        name: signpostName,
        signpostID: signpostID,
        "operation=%{public}@ succeeded=%{public}d",
        timing.operation,
        succeeded ? 1 : 0
      )
    }
  }

  private static func finishDetachedPerformanceOperation(
    _ timing: IosCameraOperationTiming,
    signpostID: OSSignpostID,
    signpostName: StaticString,
    succeeded: Bool
  ) {
    _ = timing.finish(succeeded: succeeded)
    os_signpost(
      .end,
      log: Self.performanceLog,
      name: signpostName,
      signpostID: signpostID,
      "operation=%{public}@ succeeded=%{public}d",
      timing.operation,
      succeeded ? 1 : 0
    )
  }

  // MARK: - Recording Actions

  func stopWork(
    completion: @escaping (Result<CameraRecordingStopDto, Error>) -> Void
  ) {
    let timing = IosCameraOperationTiming(operation: "stop")
    let signpostID = OSSignpostID(log: Self.performanceLog)
    os_signpost(
      .begin,
      log: Self.performanceLog,
      name: "CameraRecordingStop",
      signpostID: signpostID
    )
    sessionQueue.async { [weak self] in
      guard let self = self, !self.isDisposed else {
        if let self = self {
          self.finishPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingStop",
            succeeded: false
          )
        } else {
          Self.finishDetachedPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingStop",
            succeeded: false
          )
        }
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      let request: IosCameraRecordingLifecycle.Request
      switch self.recordingLifecycle.begin(
        .stop,
        onCancelled: { [weak self] in
          if let self = self {
            self.finishPerformanceOperation(
              timing,
              signpostID: signpostID,
              signpostName: "CameraRecordingStop",
              succeeded: false
            )
          } else {
            Self.finishDetachedPerformanceOperation(
              timing,
              signpostID: signpostID,
              signpostName: "CameraRecordingStop",
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
          signpostName: "CameraRecordingStop",
          succeeded: false
        )
        completion(.failure(self.recordingRequestError(rejection, for: .stop)))
        return
      }
      self.recordingActivityState.setActive(
        false, owner: self.recordingActivityOwner
      )
      self.finishWriter(timing: timing) { result in
        switch result {
        case .success(let stopDto):
          request.complete()
          self.finishPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingStop",
            succeeded: true
          )
          completion(.success(stopDto))
        case .failure(let error):
          request.cancel()
          self.finishPerformanceOperation(
            timing,
            signpostID: signpostID,
            signpostName: "CameraRecordingStop",
            succeeded: false
          )
          completion(.failure(error))
        }
      }
    }
  }

  func splitWork(
    nextPath: String,
    nextTrackingNumber: String,
    preservesWatermark: Bool,
    completion: @escaping (Result<CameraRecordingStartDto, Error>) -> Void
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
      guard let self = self, !self.isDisposed else {
        if let self = self {
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
          if let self = self {
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
      self.preservesWatermarkDuringSplit = preservesWatermark
      self.finishWriter(timing: timing) { result in
        switch result {
        case .success(let stopDto):
          self.eventApi.segmentEnded(
            stopDto: stopDto,
            completion: { _ in }
          )
          do {
            try self.startWriter(
              path: nextPath,
              trackingNumber: nextTrackingNumber,
              operation: "split",
              timing: timing
            )
            let startedAt = self.currentStartedAtMs
            self.eventApi.segmentStarted(
              path: nextPath,
              segmentId: self.currentSegmentId,
              startedAtMs: startedAt,
              completion: { _ in }
            )
            request.complete()
            self.finishPerformanceOperation(
              timing,
              signpostID: signpostID,
              signpostName: "CameraRecordingSplit",
              succeeded: true
            )
            completion(.success(CameraRecordingStartDto(
              segmentId: self.currentSegmentId,
              startedAtMs: startedAt,
              recordingPath: nextPath
            )))
          } catch {
            self.recordingActivityState.setActive(
              false, owner: self.recordingActivityOwner
            )
            request.cancel()
            self.finishPerformanceOperation(
              timing,
              signpostID: signpostID,
              signpostName: "CameraRecordingSplit",
              succeeded: false
            )
            completion(.failure(error))
          }
        case .failure(let error):
          self.recordingActivityState.setActive(
            false, owner: self.recordingActivityOwner
          )
          request.cancel()
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

  func setScanningEnabled(pairing: Bool, work: Bool) {
    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      self.pairingScanEnabled = pairing
      self.workScanEnabled = work
      let enabled = pairing || work
      if !enabled {
        self.visionStateLock.lock()
        self.barcodeBatchGate.reset()
        self.visionStateLock.unlock()
      }
    }
  }

  func setPreviewActive(active: Bool) {
    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      self.previewActive = active
      if active && !self.session.isRunning && !self.isDisposed {
        self.session.startRunning()
      }
    }
  }

  func updateWatermark(text: String, completion: @escaping (Result<Void, Error>) -> Void) {
    sessionQueue.async { [weak self] in
      guard let self = self else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      self.currentWatermarkFailed = false
      self.currentWatermarkError = nil
      self.liveWatermarkRenderer.updateText(text)
      completion(.success(()))
    }
  }

  func getLastSegmentDiagnostics() -> IosLastSegmentDiagnosticsState {
    return lastSegmentDiagnostics.currentState()
  }

  func getPerformanceTiming() -> [String: Any]? {
    performanceLock.lock()
    defer { performanceLock.unlock() }
    return lastOperationTiming
  }

  func getFirstWrittenFrameTiming() -> [String: Any]? {
    return firstWrittenFrameTiming.snapshot()
  }

  func dispose() {
    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      self.markDisposed()
      self.recordingActivityState.setActive(false, owner: self.recordingActivityOwner)
      self.recordingLifecycle.dispose()
      self.firstWrittenFrameTiming.cancelIfNeeded()
      self.clearOutputDelegates()
      if self.session.isRunning {
        self.session.stopRunning()
      }
      if self.cameraAudioSessionHeld {
        do {
          try self.audioSessionCoordinator.release(.camera)
          self.cameraAudioSessionHeld = false
        } catch {
          self.audioSessionCoordinator.abandon(.camera)
          self.cameraAudioSessionHeld = false
        }
      }
    }
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard previewActive, let pixelBuffer = latestPixelBuffer else { return nil }
    return Unmanaged.passRetained(pixelBuffer)
  }

  // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if let vOutput = self.videoOutput, output == vOutput {
      handleVideoBuffer(sampleBuffer, connection: connection)
    } else if let aOutput = self.audioOutput, output == aOutput {
      handleAudioBuffer(sampleBuffer)
    }
  }

  // MARK: - AVCaptureMetadataOutputObjectsDelegate

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    visionStateLock.lock()
    metadataCallbackCount += 1
    metadataLastCallbackAt = now
    visionStateLock.unlock()

    guard pairingScanEnabled || workScanEnabled else { return }

    var candidates: [BarcodeCandidateDto] = []
    for object in metadataObjects {
      guard let codeObject = object as? AVMetadataMachineReadableCodeObject,
            let value = codeObject.stringValue, !value.isEmpty else { continue }
      candidates.append(BarcodeCandidateDto(
        rawValue: value,
        formatName: codeObject.type.rawValue,
        source: "metadata"
      ))
    }

    if !candidates.isEmpty {
      visionStateLock.lock()
      metadataCandidateCount += Int64(candidates.count)
      metadataLastCandidateAt = now
      let action = barcodeBatchGate.submit(candidates, now: now)
      visionStateLock.unlock()
      processBarcodeAction(action)
    }
  }

  // MARK: - Private Helpers

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
  }

  private func updateTextureId(_ newId: Int64) {
    bufferLock.lock()
    textureId = newId
    bufferLock.unlock()
  }

  private func configureSession() {
    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      self.session.beginConfiguration()
      self.session.sessionPreset = .hd1920x1080
      
      guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
            self.session.canAddInput(videoInput) else {
        self.session.commitConfiguration()
        return
      }
      self.session.addInput(videoInput)
      self.videoDeviceInput = videoInput

      let videoOutput = AVCaptureVideoDataOutput()
      videoOutput.alwaysDiscardsLateVideoFrames = true
      videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
      if self.session.canAddOutput(videoOutput) {
        self.session.addOutput(videoOutput)
        self.videoOutput = videoOutput
      }

      let metadataOutput = AVCaptureMetadataOutput()
      if self.session.canAddOutput(metadataOutput) {
        self.session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: self.metadataQueue)
        metadataOutput.metadataObjectTypes = metadataOutput.availableMetadataObjectTypes
        self.metadataOutput = metadataOutput
      }

      self.session.commitConfiguration()
    }
  }

  private func applyCapturePreset(requestedSpec: String) {
    let selection = IosCapturePresetSelection.select(
      requestedSpec: requestedSpec,
      supports4K: session.canSetSessionPreset(.hd4K3840x2160),
      supportsHd1080: session.canSetSessionPreset(.hd1920x1080),
      supportsHd720: session.canSetSessionPreset(.hd1280x720),
      supportsHigh: session.canSetSessionPreset(.high),
      supportsMedium: session.canSetSessionPreset(.medium),
      supportsLow: session.canSetSessionPreset(.low)
    )
    if let selection = selection {
      session.beginConfiguration()
      switch selection.name {
      case "hd4K3840x2160": session.sessionPreset = .hd4K3840x2160
      case "hd1280x720": session.sessionPreset = .hd1280x720
      case "high": session.sessionPreset = .high
      case "medium": session.sessionPreset = .medium
      case "low": session.sessionPreset = .low
      default: session.sessionPreset = .hd1920x1080
      }
      session.commitConfiguration()
      sessionPresetName = selection.name
      captureSize = (width: selection.portraitWidth, height: selection.portraitHeight)
      recordingSpecName = selection.recordingSpecName
    }
  }

  private func acquireRecordingAudioSessionIfNeeded() throws {
    guard recordAudio, !cameraAudioSessionHeld else { return }
    try audioSessionCoordinator.acquire(.camera)
    cameraAudioSessionHeld = true
  }

  private func addAudioInputIfNeeded() throws {
    guard recordAudio, audioDeviceInput == nil else { return }
    guard let audioDevice = AVCaptureDevice.default(for: .audio),
          let audioInput = try? AVCaptureDeviceInput(device: audioDevice) else { return }
    session.beginConfiguration()
    if session.canAddInput(audioInput) {
      session.addInput(audioInput)
      self.audioDeviceInput = audioInput
    }
    let audioOutput = AVCaptureAudioDataOutput()
    audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    if session.canAddOutput(audioOutput) {
      session.addOutput(audioOutput)
      self.audioOutput = audioOutput
    }
    session.commitConfiguration()
  }

  private func startSessionWithRetry(completion: @escaping (Bool) -> Void) {
    if !session.isRunning {
      session.startRunning()
    }
    completion(session.isRunning)
  }

  private func recoverCamera(completion: @escaping (Bool) -> Void) {
    startSessionWithRetry(completion: completion)
  }

  private func finishInitialize(_ completion: @escaping (Result<CameraInitializationDto, Error>) -> Void) {
    completion(.success(CameraInitializationDto(
      textureId: textureId,
      previewWidth: Int64(portraitSize.width),
      previewHeight: Int64(portraitSize.height),
      recordingSpec: recordingSpecName,
      videoCodec: preferredVideoCodec,
      codecFallbackReason: codecFallbackReason,
      capabilities: CameraCapabilitiesDto(
        supportsSmooth720p30: session.canSetSessionPreset(.hd1280x720),
        supportsHd1080p30: session.canSetSessionPreset(.hd1920x1080),
        supportsUhd4k30: session.canSetSessionPreset(.hd4K3840x2160)
      )
    )))
  }

  private func ensureRunningForWork() throws {
    if !session.isRunning {
      session.startRunning()
    }
  }

  private func startWriter(
    path: String,
    trackingNumber: String,
    operation: String,
    timing: IosCameraOperationTiming
  ) throws {
    let url = URL(fileURLWithPath: path)
    let newWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
    
    let isHevc = preferredVideoCodec.lowercased() == "hevc"
    let codecType: AVVideoCodecType = isHevc ? .hevc : .h264
    let bitRate = IosRecordingSpecEncodingPolicy.averageBitRate(spec: recordingSpecName, codec: preferredVideoCodec)
    
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: codecType,
      AVVideoWidthKey: portraitSize.width,
      AVVideoHeightKey: portraitSize.height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitRate
      ]
    ]
    let newVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    newVideoInput.expectsMediaDataInRealTime = true
    
    if newWriter.canAdd(newVideoInput) {
      newWriter.add(newVideoInput)
    }
    
    if recordAudio {
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 2,
        AVSampleRateKey: 44100.0,
        AVEncoderBitRateKey: 64000
      ]
      let newAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      newAudioInput.expectsMediaDataInRealTime = true
      if newWriter.canAdd(newAudioInput) {
        newWriter.add(newAudioInput)
        self.audioInput = newAudioInput
      }
    }

    self.writer = newWriter
    self.videoInput = newVideoInput
    self.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: newVideoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: portraitSize.width,
        kCVPixelBufferHeightKey as String: portraitSize.height
      ]
    )

    currentPath = path
    currentTrackingNumber = trackingNumber
    currentSegmentId = UUID().uuidString
    currentStartedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    currentSegmentSerial += 1
    writerSessionStarted = false

    firstWrittenFrameTiming.begin(operation: operation)
  }

  private func finishWriter(
    timing: IosCameraOperationTiming,
    completion: @escaping (Result<CameraRecordingStopDto, Error>) -> Void
  ) {
    guard let writer = self.writer else {
      completion(.failure(IosCameraWriterFinishPolicy.missingWriterError()))
      return
    }

    let path = currentPath ?? ""
    let segmentId = currentSegmentId
    let startedAt = currentStartedAtMs
    let serial = currentSegmentSerial

    videoInput?.markAsFinished()
    audioInput?.markAsFinished()

    let stoppedAt = Int64(Date().timeIntervalSince1970 * 1000)

    writer.finishWriting { [weak self] in
      guard let self = self else { return }
      let result = IosCameraWriterFinishPolicy.result(
        status: writer.status,
        writerError: writer.error?.localizedDescription
      )
      switch result {
      case .success:
        let hasFile = self.lastSegmentDiagnostics.recordWriterResult(
          serial: serial,
          writerStatus: "completed",
          writerError: nil,
          hasCompletedFile: true,
          inspectionError: nil
        )
        if hasFile {
          self.inspectAudioTrack(path: path, serial: serial)
        }
        completion(.success(CameraRecordingStopDto(
          segmentId: segmentId,
          startedAtMs: startedAt,
          stoppedAtMs: stoppedAt,
          recordingPath: path,
          audioPeak: self.currentAudioPeak
        )))
      case .failure(let error):
        self.lastSegmentDiagnostics.recordWriterResult(
          serial: serial,
          writerStatus: "failed",
          writerError: writer.error?.localizedDescription,
          hasCompletedFile: false,
          inspectionError: error.localizedDescription
        )
        completion(.failure(error))
      }
    }
  }

  private func handleVideoBuffer(_ sampleBuffer: CMSampleBuffer, connection: AVCaptureConnection) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    bufferLock.lock()
    latestPixelBuffer = pixelBuffer
    bufferLock.unlock()

    if textureId >= 0, let registry = self.textures {
      registry.textureFrameAvailable(textureId)
    }

    guard let writer = self.writer, let videoInput = self.videoInput else { return }
    
    if !writerSessionStarted {
      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      writer.startWriting()
      writer.startSession(atSourceTime: presentationTime)
      writerSessionStarted = true
    }

    IosCameraVideoAppendPolicy.appendWhenReady(
      isReady: videoInput.isReadyForMoreMediaData,
      append: { videoInput.append(sampleBuffer) },
      onWritten: { [weak self] in
        self?.firstWrittenFrameTiming.recordWrittenFrameIfNeeded()
      }
    )

    scheduleVisionFallbackIfNeeded(sampleBuffer: sampleBuffer)
  }

  private func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard recordAudio,
          writerSessionStarted,
          let writer = self.writer,
          writer.status == .writing,
          let audioInput = self.audioInput,
          audioInput.isReadyForMoreMediaData else { return }

    audioInput.append(sampleBuffer)
    currentAudioSampleCount += 1

    if let peak = IosAudioSampleEnergyProbe.normalizedPeak(in: sampleBuffer) {
      currentAudioEnergyProbeCount += 1
      currentAudioPeak = max(currentAudioPeak, peak)
      if peak < 0.01 {
        currentAudioLowEnergyProbeCount += 1
      }
    }
  }

  private func scheduleVisionFallbackIfNeeded(sampleBuffer: CMSampleBuffer) {
    let now = ProcessInfo.processInfo.systemUptime
    visionStateLock.lock()
    let shouldSchedule = IosBarcodeVisionFallbackPolicy.shouldSchedule(
      now: now,
      lastCandidateAt: visionLastCandidateAt,
      lastSubmittedAt: visionLastSubmittedAt,
      inFlight: visionScanInFlight,
      scanningEnabled: pairingScanEnabled || workScanEnabled
    )
    if shouldSchedule {
      visionScanInFlight = true
      visionLastSubmittedAt = now
    }
    visionStateLock.unlock()

    guard shouldSchedule, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    visionQueue.async { [weak self] in
      guard let self = self else { return }
      let startTime = ProcessInfo.processInfo.systemUptime
      
      let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
      let request = VNDetectBarcodesRequest { [weak self] request, error in
        guard let self = self else { return }
        let durationMs = Int64((ProcessInfo.processInfo.systemUptime - startTime) * 1000)
        
        self.visionStateLock.lock()
        self.visionScanInFlight = false
        self.visionFrameCount += 1
        self.visionLastDurationMs = durationMs
        self.visionTotalDurationMs += durationMs
        self.visionMaxDurationMs = max(self.visionMaxDurationMs, durationMs)
        if let error = error {
          self.visionLastError = error.localizedDescription
        }
        self.visionStateLock.unlock()

        guard let results = request.results as? [VNBarcodeObservation], !results.isEmpty else { return }

        var candidates: [BarcodeCandidateDto] = []
        for result in results {
          if let value = result.payloadStringValue, !value.isEmpty {
            candidates.append(BarcodeCandidateDto(
              rawValue: value,
              formatName: result.symbology.rawValue,
              source: "vision"
            ))
          }
        }

        if !candidates.isEmpty {
          let now = ProcessInfo.processInfo.systemUptime
          self.visionStateLock.lock()
          self.visionCandidateCount += Int64(candidates.count)
          self.visionLastCandidateAt = now
          let action = self.barcodeBatchGate.submit(candidates, now: now)
          self.visionStateLock.unlock()
          self.processBarcodeAction(action)
        }
      }

      try? requestHandler.perform([request])
    }
  }

  private func processBarcodeAction(_ action: IosLatestPendingGate<[BarcodeCandidateDto]>.Action) {
    switch action {
    case .none:
      break
    case .send(let candidates):
      eventApi.barcodesDetected(
        candidates: candidates,
        completion: { [weak self] _ in
          guard let self = self else { return }
          let now = ProcessInfo.processInfo.systemUptime
          self.visionStateLock.lock()
          let nextAction = self.barcodeBatchGate.complete(now: now)
          self.visionStateLock.unlock()
          self.processBarcodeAction(nextAction)
        }
      )
    case .schedule(let delay):
      sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self = self else { return }
        let now = ProcessInfo.processInfo.systemUptime
        self.visionStateLock.lock()
        let nextAction = self.barcodeBatchGate.wake(now: now)
        self.visionStateLock.unlock()
        self.processBarcodeAction(nextAction)
      }
    }
  }

  private func inspectAudioTrack(path: String, serial: Int64) {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self] in
      guard let self = self else { return }
      var error: NSError?
      let status = asset.statusOfValue(forKey: "tracks", error: &error)
      if status == .loaded {
        let audioTracks = asset.tracks(withMediaType: .audio)
        self.lastSegmentDiagnostics.recordTrackResult(
          serial: serial,
          trackCount: Int64(audioTracks.count),
          inspectionError: nil
        )
      } else {
        let optionalTrackCount: Int64? = nil
        self.lastSegmentDiagnostics.recordTrackResult(
          serial: serial,
          trackCount: optionalTrackCount,
          inspectionError: error?.localizedDescription ?? "未知轨迹加载错误"
        )
      }
    }
  }

  private func recordingRequestError(
    _ rejection: IosCameraRecordingLifecycle.Rejection,
    for operation: IosCameraRecordingLifecycle.Operation
  ) -> FlutterError {
    switch rejection {
    case .inFlight:
      return pigeonError("录像操作正在进行中", code: "camera_recording_busy")
    case .alreadyStarted:
      return pigeonError("录像已经开始", code: "camera_recording_already_started")
    case .notStarted:
      return pigeonError("录像尚未开始", code: "camera_recording_not_started")
    }
  }

  private func clearOutputDelegates() {
    let nilVideoDelegate: AVCaptureVideoDataOutputSampleBufferDelegate? = nil
    let nilAudioDelegate: AVCaptureAudioDataOutputSampleBufferDelegate? = nil
    let nilMetadataDelegate: AVCaptureMetadataOutputObjectsDelegate? = nil

    videoOutput?.setSampleBufferDelegate(nilVideoDelegate, queue: nil)
    audioOutput?.setSampleBufferDelegate(nilAudioDelegate, queue: nil)
    metadataOutput?.setMetadataObjectsDelegate(nilMetadataDelegate, queue: nil)
  }

  // MARK: - Stored Properties Declaration
  
  private static let performanceLog = OSLog(subsystem: "com.camera", category: "Performance")
  private let performanceLock = NSLock()
  private let stateLock = NSLock()
  private let bufferLock = NSLock()
  private let visionStateLock = NSLock()
  
  private var disposed = false
  private var textureId: Int64 = -1
  private var previewActive = false
  private var pairingScanEnabled = false
  private var workScanEnabled = false
  private var recordAudio = true
  private var cameraAudioSessionHeld = false
  
  private var sessionPresetName = "hd1920x1080"
  private var portraitSize = CGSize(width: 1080, height: 1920)
  private var captureSize = (width: 1080, height: 1920)
  private var recordingSpecName = "1080p"
  private var preferredVideoCodec = "h264"
  private var codecFallbackReason: String? = nil
  
  private var currentPath: String?
  private var currentTrackingNumber: String?
  private var currentSegmentId = ""
  private var currentStartedAtMs: Int64 = 0
  private var currentSegmentSerial: Int64 = 0
  private var writerSessionStarted = false
  private var preservesWatermarkDuringSplit = false
  private var currentWatermarkFailed = false
  private var currentWatermarkError: String?
  
  private var currentAudioSampleCount: Int64 = 0
  private var currentAudioEnergyProbeCount: Int64 = 0
  private var currentAudioLowEnergyProbeCount: Int64 = 0
  private var currentAudioPeak: Double = 0.0
  
  private var metadataCallbackCount: Int64 = 0
  private var metadataLastCallbackAt: Double = 0.0
  private var metadataCandidateCount: Int64 = 0
  private var metadataLastCandidateAt: Double = 0.0
  
  private var visionScanInFlight = false
  private var visionLastCandidateAt: Double = 0.0
  private var visionLastSubmittedAt: Double = 0.0
  private var visionFrameCount: Int64 = 0
  private var visionLastDurationMs: Int64 = 0
  private var visionTotalDurationMs: Int64 = 0
  private var visionMaxDurationMs: Int64 = 0
  private var visionLastError: String?
  private var visionCandidateCount: Int64 = 0
  
  private var lastOperationTiming: [String: Any]?
  private var latestPixelBuffer: CVPixelBuffer?
  
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "com.camera.sessionQueue")
  private let metadataQueue = DispatchQueue(label: "com.camera.metadataQueue")
  private let visionQueue = DispatchQueue(label: "com.camera.visionQueue")
  
  private var videoDeviceInput: AVCaptureDeviceInput?
  private var audioDeviceInput: AVCaptureDeviceInput?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var audioOutput: AVCaptureAudioDataOutput?
  private var metadataOutput: AVCaptureMetadataOutput?
  
  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  
  weak var textures: FlutterTextureRegistry?
  
  private let recordingLifecycle = IosCameraRecordingLifecycle()
  private let recordingActivityState = IosCameraActivityState()
  private let recordingActivityOwner = "CameraOwner"
  private let audioSessionCoordinator = IosAudioSessionCoordinator()
  private let lastSegmentDiagnostics = IosLastSegmentDiagnostics()
  private let firstWrittenFrameTiming = IosFirstWrittenFrameTiming()
  private let liveWatermarkRenderer = IosLiveWatermarkRenderer()
  private let barcodeBatchGate = IosLatestPendingGate<[BarcodeCandidateDto]>()
  private let eventApi = IosCameraEventApiImplementation()
}

private func pigeonError(_ message: String, code: String = "camera_error") -> FlutterError {
  return FlutterError(code: code, message: message, details: nil)
}
