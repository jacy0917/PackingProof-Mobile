import AVFoundation
import Flutter
import CryptoKit
import SQLite3
import UIKit
import XCTest
@testable import Runner

private final class FakeIosAudioSession: IosAudioSessionProtocol {
  enum Failure: Error {
    case activation
    case deactivation
  }

  var categoryCalls: [(
    AVAudioSession.Category,
    AVAudioSession.Mode,
    AVAudioSession.CategoryOptions
  )] = []
  var activeCalls: [Bool] = []
  var isActive = false
  var failNextActivation = false
  var failNextDeactivation = false

  func setCategory(
    _ category: AVAudioSession.Category,
    mode: AVAudioSession.Mode,
    options: AVAudioSession.CategoryOptions
  ) throws {
    categoryCalls.append((category, mode, options))
  }

  func setActive(
    _ active: Bool,
    options: AVAudioSession.SetActiveOptions
  ) throws {
    activeCalls.append(active)
    if active && failNextActivation {
      failNextActivation = false
      throw Failure.activation
    }
    if !active && failNextDeactivation {
      failNextDeactivation = false
      throw Failure.deactivation
    }
    isActive = active
  }
}

class RunnerTests: XCTestCase {

  func testEndingMaxVolumeKeepsRunningCameraAudioSessionActive() throws {
    let session = FakeIosAudioSession()
    let coordinator = IosSharedAudioSessionCoordinator(session: session)
    let maxVolume = IosAlertAudioSessionHostApi(
      audioSessionCoordinator: coordinator
    )

    // 相机初始化后持续持有共享录音会话，即使当前工作段已经停止。
    try coordinator.acquire(.camera)
    var firstBegin: Result<Void, Error>?
    maxVolume.beginSession { firstBegin = $0 }
    try XCTUnwrap(firstBegin).get()
    var duplicateBegin: Result<Void, Error>?
    maxVolume.beginSession { duplicateBegin = $0 }
    try XCTUnwrap(duplicateBegin).get()
    var firstEnd: Result<Void, Error>?
    maxVolume.endSession { firstEnd = $0 }
    try XCTUnwrap(firstEnd).get()

    XCTAssertTrue(session.isActive)
    XCTAssertFalse(session.activeCalls.contains(false))
    XCTAssertEqual(session.activeCalls.filter { $0 }.count, 1)
    XCTAssertEqual(session.categoryCalls.count, 1)
    XCTAssertEqual(coordinator.ownerCount(.camera), 1)
    XCTAssertEqual(coordinator.ownerCount(.maxVolume), 0)

    // 第二轮工作开始前再次确保 active，不需要重建 AVCaptureSession。
    try coordinator.ensureActive(for: .camera)
    var secondBegin: Result<Void, Error>?
    maxVolume.beginSession { secondBegin = $0 }
    try XCTUnwrap(secondBegin).get()
    var secondEnd: Result<Void, Error>?
    maxVolume.endSession { secondEnd = $0 }
    try XCTUnwrap(secondEnd).get()

    XCTAssertTrue(session.isActive)
    XCTAssertFalse(session.activeCalls.contains(false))
    XCTAssertEqual(session.activeCalls.filter { $0 }.count, 2)
    XCTAssertEqual(session.categoryCalls.count, 2)
    XCTAssertTrue(session.categoryCalls.allSatisfy {
      $0.0 == .playAndRecord &&
        $0.1 == .videoRecording &&
        $0.2.contains(.defaultToSpeaker)
    })

    try coordinator.release(.camera)
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(session.activeCalls.filter { !$0 }.count, 1)
  }

  func testAudioSessionActivationFailureIsNotReportedAsSuccess() {
    let session = FakeIosAudioSession()
    session.failNextActivation = true
    let coordinator = IosSharedAudioSessionCoordinator(session: session)
    let maxVolume = IosAlertAudioSessionHostApi(
      audioSessionCoordinator: coordinator
    )
    var result: Result<Void, Error>?

    maxVolume.beginSession { result = $0 }

    XCTAssertThrowsError(try XCTUnwrap(result).get())
    XCTAssertEqual(coordinator.ownerCount(.maxVolume), 0)
    XCTAssertFalse(session.isActive)
  }

  func testIndependentCameraOwnersDoNotDeactivateEachOther() throws {
    let session = FakeIosAudioSession()
    let coordinator = IosSharedAudioSessionCoordinator(session: session)

    try coordinator.acquire(.camera)
    try coordinator.acquire(.camera)
    XCTAssertEqual(coordinator.ownerCount(.camera), 2)
    XCTAssertEqual(session.activeCalls.filter { $0 }.count, 1)
    XCTAssertEqual(session.categoryCalls.count, 1)

    try coordinator.release(.camera)
    XCTAssertEqual(coordinator.ownerCount(.camera), 1)
    XCTAssertTrue(session.isActive)
    XCTAssertFalse(session.activeCalls.contains(false))

    try coordinator.release(.camera)
    XCTAssertEqual(coordinator.ownerCount(.camera), 0)
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(session.activeCalls.filter { !$0 }.count, 1)
  }

  func testAudioSessionDeactivationFailureIsReturnedToCaller() throws {
    let session = FakeIosAudioSession()
    let coordinator = IosSharedAudioSessionCoordinator(session: session)
    let maxVolume = IosAlertAudioSessionHostApi(
      audioSessionCoordinator: coordinator
    )
    var beginResult: Result<Void, Error>?
    maxVolume.beginSession { beginResult = $0 }
    try XCTUnwrap(beginResult).get()
    session.failNextDeactivation = true
    var endResult: Result<Void, Error>?

    maxVolume.endSession { endResult = $0 }

    XCTAssertThrowsError(try XCTUnwrap(endResult).get())
    XCTAssertEqual(coordinator.ownerCount(.maxVolume), 1)
    XCTAssertTrue(session.isActive)
  }

  func testAbandonRemovesUnretryableOwnerAfterDeactivationFailure() throws {
    let session = FakeIosAudioSession()
    let coordinator = IosSharedAudioSessionCoordinator(session: session)
    try coordinator.acquire(.camera)
    session.failNextDeactivation = true

    XCTAssertThrowsError(try coordinator.release(.camera))
    XCTAssertEqual(coordinator.ownerCount(.camera), 1)

    coordinator.abandon(.camera)
    XCTAssertEqual(coordinator.ownerCount(.camera), 0)

    try coordinator.acquire(.prompt)
    XCTAssertEqual(coordinator.ownerCount(.prompt), 1)
    XCTAssertEqual(session.activeCalls.filter { $0 }.count, 2)
  }

  func testAudioEnergyProbeReadsSigned16BitPcmSampleBuffer() throws {
    var streamDescription = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    XCTAssertEqual(
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &streamDescription,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
      ),
      noErr
    )

    let samples: [Int16] = [0, 8_192, 16_384, -32_768]
    var blockBuffer: CMBlockBuffer?
    XCTAssertEqual(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: samples.count * MemoryLayout<Int16>.stride,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: samples.count * MemoryLayout<Int16>.stride,
        flags: 0,
        blockBufferOut: &blockBuffer
      ),
      kCMBlockBufferNoErr
    )
    let copyStatus = samples.withUnsafeBytes { bytes in
      CMBlockBufferReplaceDataBytes(
        with: bytes.baseAddress!,
        blockBuffer: blockBuffer!,
        offsetIntoDestination: 0,
        dataLength: bytes.count
      )
    }
    XCTAssertEqual(copyStatus, kCMBlockBufferNoErr)

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000),
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    var sampleSize = MemoryLayout<Int16>.stride
    var sampleBuffer: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: samples.count,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
      ),
      noErr
    )

    let peak = try XCTUnwrap(
      IosAudioSampleEnergyProbe.normalizedPeak(in: try XCTUnwrap(sampleBuffer))
    )
    XCTAssertEqual(peak, 1, accuracy: 0.000_001)
  }

  func testWatermarkCancellationBeforeSessionCreationCompletesOnceAndDeletesOutput() throws {
    let queue = DispatchQueue(label: "watermark-cancel-before-session")
    queue.suspend()
    defer { queue.resume() }
    let core = IosMediaProcessingCore(processingQueue: queue)
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("watermark-cancel-\(UUID().uuidString).mp4")
    try Data([1, 2, 3]).write(to: output)
    defer { try? FileManager.default.removeItem(at: output) }
    let cancelled = expectation(description: "watermark cancellation returned")
    cancelled.assertForOverFulfill = true
    let workerDrained = expectation(description: "cancelled worker drained")
    var completionCount = 0
    var cancellationCode: String?

    core.applyWatermark(
      request: IosWatermarkExportRequest(
        inputPath: "/missing/input.mp4",
        outputPath: output.path,
        startedAtMs: 0,
        trackingNumber: ""
      )
    ) { result in
      completionCount += 1
      if case .failure(let error) = result {
        cancellationCode = (error as? IosMediaProcessingCoreError)?.code
      }
      cancelled.fulfill()
    }

    core.cancelWatermark()
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    queue.resume()
    queue.async { workerDrained.fulfill() }
    wait(for: [cancelled, workerDrained], timeout: 1)
    queue.suspend()

    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(cancellationCode, "watermark_cancelled")
  }

  func testWatermarkCancellationArrivingBeforeApplyCancelsNextExportOnly() {
    let core = IosMediaProcessingCore()
    let firstCancelled = expectation(description: "early cancellation consumed")

    core.cancelWatermark()
    core.applyWatermark(
      request: IosWatermarkExportRequest(
        inputPath: "/missing/input.mp4",
        outputPath: "/missing/output.mp4",
        startedAtMs: 0,
        trackingNumber: ""
      )
    ) { result in
      if case .failure(let error) = result {
        XCTAssertEqual(
          (error as? IosMediaProcessingCoreError)?.code,
          "watermark_cancelled"
        )
      } else {
        XCTFail("预先到达的取消必须拒绝下一次水印导出")
      }
      firstCancelled.fulfill()
    }

    wait(for: [firstCancelled], timeout: 1)
  }

  func testIosCameraCapabilityPolicyAcceptsOnlyFixedPipelineInitialization() {
    XCTAssertNoThrow(
      try IosCameraCapabilityPolicy.validateInitializationMode("unverified")
    )
    XCTAssertNoThrow(
      try IosCameraCapabilityPolicy.validateInitializationMode("full")
    )

    for mode in ["encoder_analysis", "alternating", "unknown"] {
      XCTAssertThrowsError(
        try IosCameraCapabilityPolicy.validateInitializationMode(mode)
      ) { error in
        XCTAssertEqual(
          (error as? PigeonError)?.code,
          "camera_capability_mode_unsupported"
        )
      }
    }
  }

  func testIosCameraCapabilityOperationsFailWithTypedErrors() {
    let probeError = IosCameraCapabilityPolicy.probeUnsupportedError(
      sequence: "full"
    )
    XCTAssertEqual(probeError.code, "camera_capability_probe_unsupported")

    for mode in ["full", "encoder_analysis", "alternating", "unknown"] {
      XCTAssertEqual(
        IosCameraCapabilityPolicy.modeSwitchUnsupportedError(mode: mode).code,
        "camera_capability_mode_unsupported"
      )
    }
  }

  func testLanBackupVersionComparison() {
    XCTAssertEqual(compareLanBackupVersions("v0.5.11+11011", "0.5.11"), 0)
    XCTAssertGreaterThan(compareLanBackupVersions("0.5.12", "0.5.11"), 0)
    XCTAssertLessThan(compareLanBackupVersions("0.5.10", "0.5.11"), 0)
    XCTAssertLessThan(compareLanBackupVersions("invalid", "0.5.11"), 0)
  }

  func testSharedFixtureMatchesIosCompletionContract() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fixtureURL = testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("protocol-fixtures/mobile-backup-v2-complete.json")
    let fixture = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
        as? [String: Any]
    )
    let request = try XCTUnwrap(fixture["request"] as? [String: Any])
    let expectedSessions = try XCTUnwrap(request["sessions"] as? [Any])
    let expectedSession = try XCTUnwrap(expectedSessions.first as? [String: Any])
    let actualSession = try XCTUnwrap(
      IosBackupHostApi.backupCompletionSession(expectedSession)
    )
    let response = try XCTUnwrap(fixture["response"] as? [String: Any])

    XCTAssertEqual(expectedSessions.count, 1)
    XCTAssertEqual(request["videoCodec"] as? String, "h265")
    XCTAssertEqual(actualSession as NSDictionary, expectedSession as NSDictionary)
    XCTAssertEqual((response["recordId"] as? NSNumber)?.int64Value, 42)
    XCTAssertNil(response["recordIds"])
  }

  func testUploadedVideoCodecAcceptsDocumentedValuesAndNormalizesAliases() {
    XCTAssertEqual(IosBackupHostApi.normalizedVideoCodec("AVC"), "h264")
    XCTAssertEqual(IosBackupHostApi.normalizedVideoCodec("hevc"), "h265")
    XCTAssertEqual(IosBackupHostApi.normalizedVideoCodec("av1"), "av1")
    XCTAssertNil(IosBackupHostApi.normalizedVideoCodec("vp9"))
    XCTAssertNil(IosBackupHostApi.normalizedVideoCodec(nil))
  }

  func testRequiredUsageDescriptionsPresent() {
    let requiredKeys = [
      "NSCameraUsageDescription",
      "NSMicrophoneUsageDescription",
      "NSLocalNetworkUsageDescription",
    ]
    for key in requiredKeys {
      let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
      XCTAssertFalse(
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
        "Info.plist 缺少非空权限说明：\(key)"
      )
    }
  }

  func testLocalNetworkingATSIsEnabled() {
    let settings =
      Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity")
      as? [String: Any]
    XCTAssertEqual(
      settings?["NSAllowsLocalNetworking"] as? Bool,
      true,
      "Info.plist 必须允许局域网明文 HTTP，否则备份与订单接收会被 ATS 拦截"
    )
  }

  func testWatermarkTimelineAdvancesWithCompositionTime() {
    let timeline = IosWatermarkTimeline(
      startedAtMs: 1_767_268_800_000,
      trackingNumber: "TRACK-001",
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    XCTAssertEqual(
      timeline.text(at: 0),
      "2026/01/01 12:00:00\nTRACK-001"
    )
    XCTAssertEqual(
      timeline.text(at: 2.9),
      "2026/01/01 12:00:02\nTRACK-001"
    )
    XCTAssertEqual(timeline.keyframeSeconds(duration: 2.5), [0, 1, 2, 2.5])
  }

  func testWatermarkLayoutUsesFinalVideoCoordinatesForAllOrientations() {
    let naturalSize = CGSize(width: 1080, height: 1920)
    let transforms = [
      CGAffineTransform.identity,
      CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1920, ty: 0),
      CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1080),
    ]

    for transform in transforms {
      let layout = IosWatermarkLayout.make(
        naturalSize: naturalSize,
        preferredTransform: transform,
        textSize: CGSize(width: 300, height: 80)
      )
      XCTAssertEqual(layout.textFrame.midX, layout.renderSize.width / 2)
      XCTAssertEqual(
        layout.renderSize.height - layout.textFrame.maxY,
        layout.renderSize.height
          * iosWatermarkTopFraction(forOutputSize: layout.renderSize),
        accuracy: 0.0001
      )
    }
    XCTAssertEqual(
      IosWatermarkLayout.make(
        naturalSize: naturalSize,
        preferredTransform: transforms[0],
        textSize: CGSize(width: 300, height: 80)
      ).renderSize,
      CGSize(width: 1080, height: 1920)
    )
    for transform in transforms.dropFirst() {
      XCTAssertEqual(
        IosWatermarkLayout.make(
          naturalSize: naturalSize,
          preferredTransform: transform,
          textSize: CGSize(width: 300, height: 80)
        ).renderSize,
        CGSize(width: 1920, height: 1080)
      )
    }
  }

  func testBackupReceiptVerifierAcceptsValidReceipt() {
    let fixture = makeReceiptFixture()
    XCTAssertTrue(verifyReceipt(fixture.response, fixture: fixture))
  }

  func testBackupReceiptVerifierRejectsMismatchedBoundFields() {
    let fixture = makeReceiptFixture()
    let mutations: [(String, Any)] = [
      ("fileSha256", String(repeating: "b", count: 64)),
      ("hostNodeId", "other-host"),
      ("sourceDeviceId", "other-device"),
      ("sourceSessionId", "other-session"),
      ("fileSizeBytes", fixture.fileSize + 1),
      ("recordId", fixture.recordId + 1),
    ]
    for (key, value) in mutations {
      var response = fixture.response
      response[key] = value
      XCTAssertFalse(verifyReceipt(response, fixture: fixture), key)
    }
  }

  func testBackupReceiptVerifierRejectsExpiredInvalidOrMissingSignature() {
    let fixture = makeReceiptFixture()

    var expired = fixture.response
    expired["verifiedAtUnixSeconds"] = fixture.now - 301
    XCTAssertFalse(verifyReceipt(expired, fixture: fixture))

    var invalid = fixture.response
    invalid["receiptSignature"] = String(repeating: "0", count: 64)
    XCTAssertFalse(verifyReceipt(invalid, fixture: fixture))

    var mixedContract = fixture.response
    mixedContract["recordIds"] = [fixture.recordId]
    XCTAssertFalse(verifyReceipt(mixedContract, fixture: fixture))

    for key in [
      "authVersion", "verifiedAtUnixSeconds", "hostNodeId", "sourceDeviceId",
      "sourceSessionId", "fileSha256", "fileSizeBytes", "recordId",
      "receiptSignature",
    ] {
      var missing = fixture.response
      missing.removeValue(forKey: key)
      XCTAssertFalse(verifyReceipt(missing, fixture: fixture), key)
    }
  }

  func testBackupFileReaderHashesAndReadsBoundedChunks() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("backup-reader-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let sourceLength = 2 * 1024 * 1024 + 17
    let sourceBytes: [UInt8] = (0..<sourceLength).map { index in
      UInt8(index % 251)
    }
    let source = Data(sourceBytes)
    try source.write(to: url)

    let reader = try IosBackupFileReader(url: url)
    let expectedHash = SHA256.hash(data: source)
      .map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(try reader.sha256(bufferSize: 64 * 1024), expectedHash)
    XCTAssertEqual(
      try reader.read(offset: 1024 * 1024 - 7, count: 32),
      source.subdata(in: (1024 * 1024 - 7)..<(1024 * 1024 + 25))
    )
    XCTAssertEqual(
      try reader.read(offset: Int64(source.count - 9), count: 64).count,
      9
    )
  }

  func testBackupFileReaderRejectsReplacedSource() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("backup-reader-replaced-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 1, count: 1024).write(to: url)
    let reader = try IosBackupFileReader(url: url)
    try Data(repeating: 2, count: 2048).write(to: url)
    XCTAssertThrowsError(try reader.read(offset: 0, count: 32))
  }

  func testBackupJobStorePersistsCrudAcrossRestart() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let job = makeBackupJob(id: "job-1")

    do {
      let store = try IosBackupJobStore(
        databaseURL: fixture.databaseURL, defaults: fixture.defaults
      )
      try store.upsert(job)
      XCTAssertEqual(try store.summaryValues()["totalCount"] as? Int64, 1)
      XCTAssertTrue(try store.updateJob(id: "job-1") { current in
        current["state"] = "paused"
        current["uploadedBytes"] = 512
      })
      XCTAssertFalse(try store.updateJob(id: "missing") { _ in })
    }

    let reopened = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let restored = try XCTUnwrap(reopened.readJob(id: "job-1"))
    XCTAssertEqual(restored["state"] as? String, "paused")
    XCTAssertEqual((restored["uploadedBytes"] as? NSNumber)?.int64Value, 512)
    XCTAssertEqual((restored["sessions"] as? [Any])?.count, 1)
    let pausedSummary = try reopened.summaryValues()
    XCTAssertEqual(pausedSummary["totalCount"] as? Int64, 1)
    XCTAssertEqual(pausedSummary["pausedCount"] as? Int64, 1)
    XCTAssertEqual(pausedSummary["unfinishedUploadedBytes"] as? Int64, 512)
    try reopened.deleteJob(id: "job-1")
    XCTAssertNil(try reopened.readJob(id: "job-1"))
    XCTAssertEqual(try reopened.summaryValues()["totalCount"] as? Int64, 0)
  }

  func testBackupSummaryQuerySkipsMalformedSessions() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let id = "snapshot-with-corrupt-sessions"
    try store.upsert(makeBackupJob(id: id))
    try executeBackupStoreSql(
      "UPDATE backup_jobs SET sessions = '{invalid-json' WHERE id = '\(id)'",
      databaseURL: fixture.databaseURL
    )

    XCTAssertThrowsError(try store.readJob(id: id))
    let summary = try store.summaryValues()
    let activeJob = try XCTUnwrap(summary["activeJob"] as? [String: Any])
    XCTAssertEqual(activeJob["id"] as? String, id)
    XCTAssertEqual(activeJob["filePath"] as? String, "/recordings/\(id).mp4")
    XCTAssertNil(activeJob["sessions"])
  }

  func testBackupSummaryCountersRecoverFromInterruptedSeedWithoutRewritingJobs() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    do {
      _ = try IosBackupJobStore(
        databaseURL: fixture.databaseURL, defaults: fixture.defaults
      )
    }
    try executeBackupStoreSql(
      """
      INSERT INTO backup_jobs(
        id, generation, file_path, state, total_bytes, sessions, revision
      ) VALUES('seed-recovery', 'generation-seed', '/recordings/seed.mp4',
               'pending', 123, '[]', 1);
      UPDATE backup_meta SET int_value = 999 WHERE key = 'summary_total_count';
      DELETE FROM backup_meta WHERE key = 'summary_counters_initialized';
      """,
      databaseURL: fixture.databaseURL
    )

    let reopened = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let summary = try reopened.summaryValues()
    XCTAssertEqual(summary["totalCount"] as? Int64, 1)
    XCTAssertEqual(summary["pendingCount"] as? Int64, 1)
    XCTAssertEqual(summary["unfinishedTotalBytes"] as? Int64, 123)
    XCTAssertEqual(try reopened.readJob(id: "seed-recovery")?["state"] as? String, "pending")
  }

  func testBackupJobStoreAtomicallyRejectsStaleGenerationUpdate() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    try store.upsert(makeBackupJob(id: "generation-guard"))

    XCTAssertTrue(
      try store.updateJob(
        id: "generation-guard",
        expectedGeneration: "generation-generation-guard"
      ) { job in
        job["uploadedBytes"] = Int64(512)
      }
    )
    XCTAssertTrue(
      try store.updateJob(id: "generation-guard") { job in
        job["generation"] = "replacement-generation"
        job["state"] = "pending"
      }
    )
    var staleMutationRan = false
    XCTAssertFalse(
      try store.updateJob(
        id: "generation-guard",
        expectedGeneration: "generation-generation-guard"
      ) { job in
        staleMutationRan = true
        job["state"] = "completed"
      }
    )

    XCTAssertFalse(staleMutationRan)
    let current = try XCTUnwrap(store.readJob(id: "generation-guard"))
    XCTAssertEqual(current["generation"] as? String, "replacement-generation")
    XCTAssertEqual(current["state"] as? String, "pending")
    XCTAssertEqual((current["uploadedBytes"] as? NSNumber)?.int64Value, 512)
  }

  func testBackupJobRevisionsAreMonotonicAndStaleUpdateDoesNotAdvance() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let id = "revision-guard"
    try store.upsert(makeBackupJob(id: id))
    let first = try XCTUnwrap(store.readJob(id: id)?["revision"] as? Int64)
    XCTAssertTrue(try store.updateJob(id: id) { $0["uploadedBytes"] = 10 })
    let second = try XCTUnwrap(store.readJob(id: id)?["revision"] as? Int64)
    XCTAssertGreaterThan(second, first)

    XCTAssertFalse(
      try store.updateJob(id: id, expectedGeneration: "stale") {
        $0["state"] = "completed"
      }
    )
    XCTAssertEqual(try store.readJob(id: id)?["revision"] as? Int64, second)
    XCTAssertEqual(try store.summaryValues()["revision"] as? Int64, second)
  }

  func testBackupSummaryUsesSharedDominantFailurePriority() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    var credential = makeBackupJob(id: "failure-credential")
    credential["state"] = "failed"
    credential["failureKind"] = "credential_invalid"
    try store.upsert(credential)
    var offline = makeBackupJob(id: "failure-offline")
    offline["state"] = "failed"
    offline["failureKind"] = "offline_or_timeout"
    try store.upsert(offline)

    let summary = try store.summaryValues()
    XCTAssertEqual(summary["dominantFailureKind"] as? String, "credential_invalid")
    XCTAssertEqual(
      (summary["problemJob"] as? [String: Any])?["id"] as? String,
      "failure-credential"
    )
  }

  func testBackupCleanupEventIsCreatedAndAcknowledgedTransactionally() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let id = "cleanup-event"
    try store.upsert(makeBackupJob(id: id))
    XCTAssertTrue(try store.updateJob(id: id) { job in
      job["localDeletedAt"] = "2026-08-23T01:02:03Z"
      job["cleanupReason"] = "已备份录像保留策略清理"
    })

    let page = try store.cleanupEvents(afterRevision: 0, limit: 1)
    let event = try XCTUnwrap(page.events.first)
    XCTAssertEqual(event["jobId"] as? String, id)
    XCTAssertEqual(event["filePath"] as? String, "/recordings/\(id).mp4")
    XCTAssertEqual(event["reason"] as? String, "已备份录像保留策略清理")
    let revision = try XCTUnwrap(event["revision"] as? Int64)
    XCTAssertEqual(page.latest, revision)

    try store.acknowledgeCleanupEvents(throughRevision: revision)
    XCTAssertTrue(try store.cleanupEvents(afterRevision: 0, limit: 10).events.isEmpty)
  }

  func testBackupJobsForPathsReturnsOnlyRequestedJobs() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    try store.upsert(makeBackupJob(id: "path-a"))
    try store.upsert(makeBackupJob(id: "path-b"))

    let result = try store.jobsForPaths([
      "/recordings/path-b.mp4", "/recordings/missing.mp4",
    ])
    XCTAssertEqual(result.jobs.count, 1)
    XCTAssertEqual(result.jobs.first?["id"] as? String, "path-b")
    XCTAssertGreaterThan(result.revision, 0)
  }

  func testClaimNextUploadJobUsesSqliteQueueAndSkipsPausedJobs() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    var paused = makeBackupJob(id: "paused")
    paused["state"] = "paused"
    try store.upsert(paused)
    try store.upsert(makeBackupJob(id: "pending"))

    let claimed = try XCTUnwrap(store.claimNextUploadJob())
    XCTAssertEqual(claimed["id"] as? String, "pending")
    XCTAssertEqual(claimed["state"] as? String, "uploading")
    XCTAssertEqual(
      try store.readJob(id: "pending")?["state"] as? String,
      "uploading"
    )

    _ = try store.updateJob(id: "pending") { $0["state"] = "completed" }
    XCTAssertNil(try store.claimNextUploadJob())
    XCTAssertEqual(try store.readJob(id: "paused")?["state"] as? String, "paused")
  }

  func testTenThousandCleanupCandidatesAreReadInPagesOfAtMostOneHundred() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    try executeBackupStoreSql(
      """
      WITH RECURSIVE counter(value) AS (
        SELECT 0
        UNION ALL
        SELECT value + 1 FROM counter WHERE value < 9999
      )
      INSERT INTO backup_jobs(
        id, generation, file_path, state, uploaded_bytes, total_bytes,
        last_modified, file_created_at, backup_completed_at, waiting_cleanup,
        content_sha256, verification_version, last_attested_at, sessions, revision
      )
      SELECT
        printf('scale-%05d', value),
        printf('generation-%05d', value),
        printf('/recordings/scale-%05d.mp4', value),
        CASE value % 4
          WHEN 0 THEN 'pending'
          WHEN 1 THEN 'paused'
          WHEN 2 THEN 'uploading'
          ELSE 'completed'
        END,
        0, 1, value, '2026-08-23T00:00:00Z',
        CASE WHEN value % 4 = 3 THEN '2026-08-23T00:01:00Z' ELSE NULL END,
        0,
        CASE WHEN value % 4 = 3 THEN printf('%064d', value) ELSE NULL END,
        CASE WHEN value % 4 = 3 THEN \(IosBackupReceiptVerifier.version) ELSE 0 END,
        CASE WHEN value % 4 = 3 THEN '2026-08-23T00:02:00Z' ELSE NULL END,
        '[]', value
      FROM counter;
      """,
      databaseURL: fixture.databaseURL
    )

    var afterId: String?
    var cleanupCount = 0
    var page: [[String: Any]]
    repeat {
      page = try store.cleanupCandidateJobsPage(afterId: afterId)
      XCTAssertLessThanOrEqual(page.count, 100)
      cleanupCount += page.count
      afterId = page.last?["id"] as? String
    } while page.count == 100
    XCTAssertEqual(cleanupCount, 5_000)

    var createdAt: String?
    afterId = nil
    var storageCount = 0
    var storagePage: (jobs: [[String: Any]], nextCreatedAtKey: String?, nextId: String?)
    repeat {
      storagePage = try store.storageRecoveryJobsPage(
        afterCreatedAtKey: createdAt,
        afterId: afterId,
        minimumVerificationVersion: IosBackupReceiptVerifier.version
      )
      XCTAssertLessThanOrEqual(storagePage.jobs.count, 100)
      storageCount += storagePage.jobs.count
      createdAt = storagePage.nextCreatedAtKey
      afterId = storagePage.nextId
    } while storagePage.jobs.count == 100
    XCTAssertEqual(storageCount, 2_500)
  }

  func testBackupJobStoreRejectsUnopenableAndCorruptDatabases() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let directoryURL = fixture.root.appendingPathComponent("database-directory")
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true
    )
    XCTAssertThrowsError(
      try IosBackupJobStore(databaseURL: directoryURL, defaults: fixture.defaults)
    ) { error in
      XCTAssertTrue(error is IosBackupStoreError)
    }

    try Data("not-a-sqlite-database".utf8).write(to: fixture.databaseURL)
    XCTAssertThrowsError(
      try IosBackupJobStore(databaseURL: fixture.databaseURL, defaults: fixture.defaults)
    ) { error in
      XCTAssertTrue(error is IosBackupStoreError)
    }
  }

  func testBackupJobStoreCommitsLegacyMigrationBeforeDeletingSource() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    fixture.defaults.set(
      [makeBackupJob(id: "legacy-1")], forKey: "ios_backup_jobs"
    )

    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    XCTAssertEqual(try store.readJob(id: "legacy-1")?["id"] as? String, "legacy-1")
    XCTAssertNil(fixture.defaults.object(forKey: "ios_backup_jobs"))
  }

  func testBackupJobStoreRollsBackInterruptedLegacyMigration() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    var invalid = makeBackupJob(id: "legacy-invalid")
    invalid["sessions"] = [Date()]
    fixture.defaults.set(
      [makeBackupJob(id: "legacy-valid"), invalid],
      forKey: "ios_backup_jobs"
    )

    XCTAssertThrowsError(
      try IosBackupJobStore(databaseURL: fixture.databaseURL, defaults: fixture.defaults)
    ) { error in
      XCTAssertTrue(error is IosBackupStoreError)
    }
    XCTAssertNotNil(fixture.defaults.object(forKey: "ios_backup_jobs"))

    fixture.defaults.removeObject(forKey: "ios_backup_jobs")
    let reopened = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    XCTAssertEqual(try reopened.summaryValues()["totalCount"] as? Int64, 0)
  }

  func testBackupCredentialStoreMigratesAndScrubsLegacyCopies() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let keychain = FakeIosKeychainClient()
    fixture.defaults.set("legacy-access-key", forKey: "ios_backup_access_key")
    fixture.defaults.set(
      [
        "baseUrl": "http://192.168.1.2:3000",
        "computerId": "computer-1",
        "accessKey": "embedded-access-key",
      ],
      forKey: "ios_backup_connection"
    )
    let store = IosBackupCredentialStore(
      defaults: fixture.defaults,
      keychain: keychain,
      service: "RunnerTests.\(UUID().uuidString)",
      account: "access-key"
    )

    XCTAssertEqual(try store.load(), "legacy-access-key")
    XCTAssertEqual(keychain.data, Data("legacy-access-key".utf8))
    XCTAssertNil(fixture.defaults.object(forKey: "ios_backup_access_key"))
    let connection = try XCTUnwrap(
      fixture.defaults.dictionary(forKey: "ios_backup_connection")
    )
    XCTAssertNil(connection["accessKey"])
    XCTAssertEqual(connection["computerId"] as? String, "computer-1")
  }

  func testBackupCredentialStorePreservesLegacyCopiesWhenMigrationFails() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let keychain = FakeIosKeychainClient()
    keychain.saveError = IosBackupCredentialError(operation: "保存", status: -1)
    fixture.defaults.set("legacy-access-key", forKey: "ios_backup_access_key")
    fixture.defaults.set(
      ["computerId": "computer-1", "accessKey": "embedded-access-key"],
      forKey: "ios_backup_connection"
    )
    let store = IosBackupCredentialStore(
      defaults: fixture.defaults,
      keychain: keychain,
      service: "RunnerTests.\(UUID().uuidString)",
      account: "access-key"
    )

    XCTAssertThrowsError(try store.load())
    XCTAssertEqual(
      fixture.defaults.string(forKey: "ios_backup_access_key"),
      "legacy-access-key"
    )
    XCTAssertEqual(
      fixture.defaults.dictionary(forKey: "ios_backup_connection")?["accessKey"]
        as? String,
      "embedded-access-key"
    )
  }

  func testBackupCredentialStoreSavesLoadsAndDeletesSecureValue() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let keychain = FakeIosKeychainClient()
    let store = IosBackupCredentialStore(
      defaults: fixture.defaults,
      keychain: keychain,
      service: "RunnerTests.\(UUID().uuidString)",
      account: "access-key"
    )

    try store.save("secure-access-key")
    XCTAssertEqual(try store.load(), "secure-access-key")
    try store.delete()
    XCTAssertNil(try store.load())
  }

  func testBackupCleanupGateRequiresExactlyOneSession() {
    var job = makeBackupJob(id: "cleanup-cardinality")
    XCTAssertTrue(IosBackupCleanupGate.hasSingleSession(job))
    job["sessions"] = []
    XCTAssertFalse(IosBackupCleanupGate.hasSingleSession(job))
    job["sessions"] = [["id": "first"], ["id": "second"]]
    XCTAssertFalse(IosBackupCleanupGate.hasSingleSession(job))
    job.removeValue(forKey: "sessions")
    XCTAssertFalse(IosBackupCleanupGate.hasSingleSession(job))
  }

  func testBackupRetentionEvidenceRequiresLocallyVerifiedReceipt() {
    var job = makeBackupJob(id: "retention-receipt")
    job["contentSha256"] = String(repeating: "a", count: 64)
    job["verificationVersion"] = 3
    job["remoteRecordId"] = NSNumber(value: 42)
    job["totalBytes"] = Int64(1_024)

    XCTAssertFalse(
      IosBackupCleanupGate.hasVerifiedRetentionEvidence(job, minimumVersion: 3)
    )
    job["verificationReceipt"] = "verified-receipt"
    XCTAssertTrue(
      IosBackupCleanupGate.hasVerifiedRetentionEvidence(job, minimumVersion: 3)
    )
    for key in [
      "contentSha256", "verificationVersion", "remoteRecordId", "totalBytes",
      "verificationReceipt", "sessions",
    ] {
      var missing = job
      missing.removeValue(forKey: key)
      XCTAssertFalse(
        IosBackupCleanupGate.hasVerifiedRetentionEvidence(missing, minimumVersion: 3),
        key
      )
    }
    job["sessions"] = []
    XCTAssertFalse(
      IosBackupCleanupGate.hasVerifiedRetentionEvidence(job, minimumVersion: 3)
    )
  }

  func testRetentionCleanupKeepsLegacyPseudoVerifiedFileWithoutReceipt()
    async throws
  {
    let fixture = try makeRetentionCleanupFixture(id: "legacy-pseudo-verified")
    defer { removeRetentionCleanupFixture(fixture) }
    var job = fixture.job
    job["verificationVersion"] = 3
    job["remoteRecordId"] = NSNumber(value: 42)
    try fixture.store.upsert(job)

    try await fixture.api.performCleanup()

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    let updated = try XCTUnwrap(fixture.store.readJob(id: "legacy-pseudo-verified"))
    XCTAssertEqual(updated["waitingCleanup"] as? Bool, true)
    XCTAssertNil(updated["localDeletedAt"])
    XCTAssertEqual(
      updated["errorMessage"] as? String,
      "备份记录缺少安全校验信息，需重新备份后才能自动清理"
    )
  }

  func testRetentionCleanupKeepsVerifiedFileWhenRemoteIsUnreachable()
    async throws
  {
    let fixture = try makeRetentionCleanupFixture(id: "remote-unreachable")
    defer { removeRetentionCleanupFixture(fixture) }
    var job = fixture.job
    job["verificationVersion"] = 3
    job["verificationReceipt"] = "locally-verified-receipt"
    job["remoteRecordId"] = NSNumber(value: 42)
    try fixture.store.upsert(job)

    try await fixture.api.performCleanup()

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    let updated = try XCTUnwrap(fixture.store.readJob(id: "remote-unreachable"))
    XCTAssertEqual(updated["waitingCleanup"] as? Bool, true)
    XCTAssertNil(updated["localDeletedAt"])
    XCTAssertEqual(
      updated["errorMessage"] as? String,
      "暂时无法向电脑确认备份，已保留本地录像"
    )
  }

  func testStorageReclaimKeepsLegacyJobWithoutContentSha256() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-missing-sha",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "unexpected-receipt" }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job.removeValue(forKey: "contentSha256")
    try fixture.store.upsert(job)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    XCTAssertNil(
      try fixture.store.readJob(id: "storage-reclaim-missing-sha")?["localDeletedAt"]
    )
  }

  func testStorageReclaimDoesNotEmitSnapshotWhenJobsStayUnchanged() async throws {
    let emitted = expectation(description: "未变更任务不推送快照")
    emitted.isInverted = true
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-no-change",
      availableStorageBytesOverride: { 4 * 1024 * 1024 * 1024 },
      onSnapshot: { _ in emitted.fulfill() }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedStorageReclaimJob(fixture.job))

    _ = try await awaitStorageReclaim(fixture.api)

    await fulfillment(of: [emitted], timeout: 0.5)
  }

  func testAvailableRecordingStorageBytesReadsRecordingVolumeWithoutReclaim() async throws {
    let expected: Int64 = 3 * 1024 * 1024 * 1024
    let fixture = try makeRetentionCleanupFixture(
      id: "available-recording-storage",
      availableStorageBytesOverride: { expected }
    )
    defer { removeRetentionCleanupFixture(fixture) }

    let available = try await awaitAvailableRecordingStorageBytes(fixture.api)

    XCTAssertEqual(available, expected)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
  }

  func testStorageReclaimEmitsSnapshotWhenJobErrorChanges() async throws {
    let emitted = expectation(description: "任务错误变化后推送快照")
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-error-change",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "unexpected-receipt" },
      onSnapshot: { _ in emitted.fulfill() }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["contentSha256"] = String(repeating: "f", count: 64)
    try fixture.store.upsert(job)

    _ = try await awaitStorageReclaim(fixture.api)

    await fulfillment(of: [emitted], timeout: 2)
  }

  func testStorageReclaimKeepsFileWhenContentSha256Mismatches() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-sha-mismatch",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "unexpected-receipt" }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["contentSha256"] = String(repeating: "f", count: 64)
    try fixture.store.upsert(job)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    let updated = try XCTUnwrap(fixture.store.readJob(id: "storage-reclaim-sha-mismatch"))
    XCTAssertNil(updated["localDeletedAt"])
    XCTAssertEqual(
      updated["errorMessage"] as? String,
      "录像文件已被替换，已取消空间清理"
    )
  }

  func testStorageReclaimKeepsMixedSessionJob() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-mixed-sessions",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "unexpected-receipt" }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["sessions"] = [["id": "first"], ["id": "second"]]
    try fixture.store.upsert(job)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    XCTAssertNil(
      try fixture.store.readJob(id: "storage-reclaim-mixed-sessions")?["localDeletedAt"]
    )
  }

  func testStorageReclaimKeepsFileWhenRemoteEvidenceIsInvalid() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-invalid-evidence",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in nil }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["verificationReceipt"] = "forged-receipt"
    try fixture.store.upsert(job)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    let updated = try XCTUnwrap(fixture.store.readJob(id: "storage-reclaim-invalid-evidence"))
    XCTAssertNil(updated["localDeletedAt"])
    XCTAssertEqual(
      updated["errorMessage"] as? String,
      "暂时无法向电脑确认备份，已保留本地录像"
    )
  }

  func testStorageReclaimDeletesOnlyAfterFreshRemoteAttestation() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-confirmed",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "fresh-signed-receipt" }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedStorageReclaimJob(fixture.job))

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(result["deletedCount"] as? Int, 1)
    let updated = try XCTUnwrap(fixture.store.readJob(id: "storage-reclaim-confirmed"))
    XCTAssertNotNil(updated["localDeletedAt"])
    XCTAssertEqual(updated["verificationReceipt"] as? String, "fresh-signed-receipt")
  }

  func testStorageReclaimReconcilesDeletionCommittedBeforeJobTransaction()
    async throws
  {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-interrupted-after-delete",
      availableStorageBytesOverride: { 0 }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedStorageReclaimJob(fixture.job))
    try FileManager.default.removeItem(at: fixture.file)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    XCTAssertEqual(result["freedBytes"] as? Int64, 0)
    let updated = try XCTUnwrap(
      fixture.store.readJob(id: "storage-reclaim-interrupted-after-delete")
    )
    XCTAssertNotNil(updated["localDeletedAt"])
    XCTAssertEqual(updated["cleanupReason"] as? String, "存储空间不足提前清理")
    let events = try fixture.store.cleanupEvents(afterRevision: 0, limit: 10).events
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?["jobId"] as? String, updated["id"] as? String)
  }

  func testMaintenanceCoordinatorSerializesOneThousandMixedOperations()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      storageReclaimOperationOverride: {
        let invocation = await tracker.begin()
        await Task.yield()
        await tracker.finish()
        return ["invocation": invocation]
      },
      cleanupOperationOverride: {
        _ = await tracker.begin()
        await Task.yield()
        await tracker.finish()
      }
    )

    let completed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      for index in 0..<1_000 {
        group.addTask {
          do {
            if index.isMultiple(of: 2) {
              let result: [String?: Any?] = try await withCheckedThrowingContinuation {
                continuation in
                api.reclaimStorageIfNeeded { continuation.resume(with: $0) }
              }
              return result["invocation"] is Int
            }
            try await api.performCleanup()
            return true
          } catch {
            return false
          }
        }
      }
      var count = 0
      for await succeeded in group where succeeded { count += 1 }
      return count
    }
    let counts = await tracker.counts()

    XCTAssertEqual(completed, 1_000)
    XCTAssertEqual(counts.started, 1_000)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testMaintenanceCoordinatorPropagatesReclaimAndCleanupErrors()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      storageReclaimOperationOverride: {
        throw MaintenanceTestError.expected
      },
      cleanupOperationOverride: {
        throw MaintenanceTestError.expected
      }
    )

    do {
      _ = try await awaitStorageReclaim(api)
      XCTFail("空间回收错误不得伪装成功")
    } catch {
      XCTAssertTrue(error is MaintenanceTestError)
    }
    do {
      try await api.performCleanup()
      XCTFail("保留策略清理错误不得伪装成功")
    } catch {
      XCTAssertTrue(error is MaintenanceTestError)
    }
  }

  func testCancelledMaintenanceWaiterReleasesQueueForFollowingOperation()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let hold = AsyncTestGate()
    let firstStarted = expectation(description: "首个维护任务占用协调器")
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      cleanupOperationOverride: {
        let invocation = await tracker.begin()
        if invocation == 1 {
          firstStarted.fulfill()
          await hold.wait()
        }
        await tracker.finish()
      }
    )

    let first = Task { try await api.performCleanup() }
    await fulfillment(of: [firstStarted], timeout: 2)
    let cancelled = Task { try await api.performCleanup() }
    cancelled.cancel()
    await hold.open()
    try await first.value
    do {
      try await cancelled.value
      XCTFail("取消的等待任务不应执行维护操作")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }

    try await api.performCleanup()
    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 2)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCancelAndRequeueRejectOldUploadStateWrites() async throws {
    let fixture = try makeRetentionCleanupFixture(id: "generation-lifecycle")
    defer { removeRetentionCleanupFixture(fixture) }
    var job = fixture.job
    job["state"] = "uploading"
    let initialGeneration = try XCTUnwrap(job["generation"] as? String)
    try fixture.store.upsert(job)

    try await awaitVoidResult { completion in
      fixture.api.cancelJob(jobId: "generation-lifecycle", completion: completion)
    }
    let cancelled = try XCTUnwrap(fixture.store.readJob(id: "generation-lifecycle"))
    let cancelledGeneration = try XCTUnwrap(cancelled["generation"] as? String)
    XCTAssertNotEqual(cancelledGeneration, initialGeneration)
    XCTAssertEqual(cancelled["state"] as? String, "paused")
    XCTAssertFalse(
      try fixture.api.updateUploadJob(
        "generation-lifecycle",
        expectedGeneration: initialGeneration
      ) { current in
        current["state"] = "completed"
      }
    )
    let afterStaleCompletion = try fixture.store.readJob(id: "generation-lifecycle")
    XCTAssertEqual(
      afterStaleCompletion?["state"] as? String,
      "paused"
    )

    try await awaitVoidResult { completion in
      fixture.api.requeueJob(jobId: "generation-lifecycle", completion: completion)
    }
    let requeued = try XCTUnwrap(fixture.store.readJob(id: "generation-lifecycle"))
    let requeuedGeneration = try XCTUnwrap(requeued["generation"] as? String)
    XCTAssertNotEqual(requeuedGeneration, cancelledGeneration)
    XCTAssertEqual(requeued["state"] as? String, "pending")
    XCTAssertFalse(
      try fixture.api.updateUploadJob(
        "generation-lifecycle",
        expectedGeneration: cancelledGeneration
      ) { current in
        current["state"] = "paused"
        current["errorMessage"] = "旧任务失败"
      }
    )
    let current = try XCTUnwrap(fixture.store.readJob(id: "generation-lifecycle"))
    XCTAssertEqual(current["generation"] as? String, requeuedGeneration)
    XCTAssertEqual(current["state"] as? String, "pending")
    XCTAssertNil(current["errorMessage"])
  }

  func testEnqueueReplacesCallerProvidedGeneration() async throws {
    let fixture = try makeRetentionCleanupFixture(id: "generation-enqueue")
    defer { removeRetentionCleanupFixture(fixture) }
    let request: [String?: Any?] = [
      "id": "generation-enqueue",
      "generation": "caller-provided-generation",
      "filePath": fixture.file.path,
      "lastModified": fixture.job["lastModified"],
      "sessions": fixture.job["sessions"],
    ]

    try await awaitVoidResult { completion in
      fixture.api.enqueueJob(request: request, completion: completion)
    }

    let current = try XCTUnwrap(fixture.store.readJob(id: "generation-enqueue"))
    XCTAssertNotEqual(
      current["generation"] as? String,
      "caller-provided-generation"
    )
    XCTAssertFalse((current["generation"] as? String)?.isEmpty ?? true)
    XCTAssertEqual(current["state"] as? String, "pending")
  }

  func testRetentionRegistrationDoesNotStartUploadAndEmitsSummary() async throws {
    let emitted = expectation(description: "登记后推送固定摘要")
    let fixture = try makeRetentionCleanupFixture(
      id: "retention-registration",
      onSnapshot: { _ in emitted.fulfill() }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    let request: [String?: Any?] = [
      "id": "retention-registration",
      "filePath": fixture.file.path,
      "lastModified": fixture.job["lastModified"],
      "sessions": fixture.job["sessions"],
      "startUpload": false,
    ]

    try await awaitVoidResult { completion in
      fixture.api.enqueueJob(request: request, completion: completion)
    }

    await fulfillment(of: [emitted], timeout: 0.5)
    let current = try XCTUnwrap(fixture.store.readJob(id: "retention-registration"))
    XCTAssertEqual(current["state"] as? String, "pending")
  }

  func testBackupSourceFailuresPersistStorageUnavailableState() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let api = makeBackupApi(defaults: fixture.defaults, store: store)

    func assertPersistedSourceFailure(
      id: String,
      error: Error,
      message: String
    ) throws {
      try store.upsert(makeBackupJob(id: id))
      XCTAssertEqual(
        api.handleUploadFailure(
          jobId: id,
          expectedGeneration: "generation-\(id)",
          error: error
        ),
        .persisted
      )
      let current = try XCTUnwrap(store.readJob(id: id))
      XCTAssertEqual(current["state"] as? String, "paused")
      XCTAssertEqual(current["failureKind"] as? String, "storage_unavailable")
      XCTAssertEqual(current["errorMessage"] as? String, message)
    }

    let missing = fixture.root.appendingPathComponent("missing.mp4")
    var missingError: Error?
    XCTAssertThrowsError(try IosBackupFileReader(url: missing)) {
      missingError = $0
    }
    try assertPersistedSourceFailure(
      id: "source-missing",
      error: try XCTUnwrap(missingError),
      message: "无法读取录像文件信息"
    )

    let replaced = fixture.root.appendingPathComponent("replaced.mp4")
    try Data(repeating: 1, count: 32).write(to: replaced)
    let replacedReader = try IosBackupFileReader(url: replaced)
    try Data(repeating: 2, count: 64).write(to: replaced)
    var replacedError: Error?
    XCTAssertThrowsError(try replacedReader.read(offset: 0, count: 8)) {
      replacedError = $0
    }
    try assertPersistedSourceFailure(
      id: "source-replaced",
      error: try XCTUnwrap(replacedError),
      message: "录像文件已被替换，已停止备份"
    )

    let unreadable = fixture.root.appendingPathComponent("unreadable.mp4")
    try Data(repeating: 3, count: 32).write(to: unreadable)
    let closedHandle = try FileHandle(forReadingFrom: unreadable)
    let unreadableReader = try IosBackupFileReader(
      url: unreadable,
      handleOverride: closedHandle
    )
    try closedHandle.close()
    var readError: Error?
    XCTAssertThrowsError(try unreadableReader.sha256()) {
      readError = $0
    }
    try assertPersistedSourceFailure(
      id: "source-read-failed",
      error: try XCTUnwrap(readError),
      message: "无法读取录像文件"
    )
  }

  func testUploadFailurePersistenceErrorIsReportedAndVisibleInSnapshot()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "failure-persistence"
    try store.upsert(makeBackupJob(id: id))
    var reportedJobId: String?
    var reportedGeneration: String?
    var reportedError: Error?
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadFailureUpdateOverride: { _, _ in
        throw IosBackupStoreError(
          operation: "测试写入",
          code: 10,
          message: "只读数据库"
        )
      },
      uploadPersistenceFailureReporter: { jobId, generation, error in
        reportedJobId = jobId
        reportedGeneration = generation
        reportedError = error
      }
    )

    XCTAssertEqual(
      api.handleUploadFailure(
        jobId: id,
        expectedGeneration: "generation-\(id)",
        error: BackupSourceError(message: "录像文件不存在或为空")
      ),
      .persistenceFailed
    )
    XCTAssertEqual(reportedJobId, id)
    XCTAssertEqual(reportedGeneration, "generation-\(id)")
    XCTAssertTrue(reportedError is IosBackupStoreError)
    XCTAssertEqual(try store.readJob(id: id)?["state"] as? String, "pending")

    let summary = try await awaitSummaryResult(api)
    let visible = try XCTUnwrap(summary.problemJob)
    XCTAssertEqual(visible.state, "paused")
    XCTAssertEqual(visible.failureKind, "storage_unavailable")
    XCTAssertTrue(
      visible.errorMessage?.contains("任务状态写入失败") ?? false
    )
  }

  func testBackupSnapshotDoesNotReadCredentials() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let keychain = FakeIosKeychainClient()
    keychain.readError = IosBackupCredentialError(operation: "测试读取", status: -1)
    let api = IosBackupHostApi(
      eventApi: FakeBackupNativeEventApi(),
      defaults: fixture.defaults,
      credentialStore: IosBackupCredentialStore(
        defaults: fixture.defaults,
        keychain: keychain,
        service: "RunnerTests.snapshot-no-credential.\(UUID().uuidString)",
        account: "access-key"
      ),
      jobStore: .success(store),
      recordingsRoot: FileManager.default.temporaryDirectory
    )

    _ = try await awaitSummaryResult(api)
    XCTAssertEqual(keychain.readCount, 0)
  }

  func testBackupSnapshotCompletesOffMainThread() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let api = makeBackupApi(defaults: fixture.defaults, store: store)
    let completed = expectation(description: "后台生成备份快照")

    api.summary { result in
      if case .failure(let error) = result {
        XCTFail("生成备份快照失败：\(error)")
      }
      XCTAssertFalse(Thread.isMainThread)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 10)
  }

  func testBackupSnapshotEventIsBuiltAndSentOffMainThread() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "background-snapshot-event"
    try store.upsert(makeBackupJob(id: id))
    let emitted = expectation(description: "后台推送备份快照")
    let eventApi = FakeBackupNativeEventApi { summary in
      XCTAssertFalse(Thread.isMainThread)
      XCTAssertEqual(summary.problemJob?.id, id)
      emitted.fulfill()
    }
    let api = IosBackupHostApi(
      eventApi: eventApi,
      defaults: fixture.defaults,
      credentialStore: IosBackupCredentialStore(
        defaults: fixture.defaults,
        keychain: FakeIosKeychainClient(),
        service: "RunnerTests.background-snapshot.\(UUID().uuidString)",
        account: "access-key"
      ),
      jobStore: .success(store),
      recordingsRoot: FileManager.default.temporaryDirectory
    )

    XCTAssertEqual(
      api.handleUploadFailure(
        jobId: id,
        expectedGeneration: "generation-\(id)",
        error: BackupSourceError(message: "测试失败")
      ),
      .persisted
    )
    wait(for: [emitted], timeout: 10)
  }

  func testTenThousandProgressEventsAreCoalescedLatestWins() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let emitted = expectation(description: "合并后的进度摘要")
    let countLock = NSLock()
    var count = 0
    let eventApi = FakeBackupNativeEventApi { _ in
      countLock.lock()
      count += 1
      let first = count == 1
      countLock.unlock()
      if first { emitted.fulfill() }
    }
    let api = IosBackupHostApi(
      eventApi: eventApi,
      defaults: fixture.defaults,
      credentialStore: IosBackupCredentialStore(
        defaults: fixture.defaults,
        keychain: FakeIosKeychainClient(),
        service: "RunnerTests.progress-summary.\(UUID().uuidString)",
        account: "access-key"
      ),
      jobStore: .success(store),
      recordingsRoot: FileManager.default.temporaryDirectory
    )

    for _ in 0..<10_000 { api.emitProgressSummaryForTesting() }
    wait(for: [emitted], timeout: 2)
    Thread.sleep(forTimeInterval: 1.2)

    countLock.lock()
    let delivered = count
    countLock.unlock()
    XCTAssertLessThanOrEqual(delivered, 2)
  }

  func testOldWorkerFailureCannotOverrideReplacementGeneration() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "stale-failure-worker"
    var replacement = makeBackupJob(id: id)
    replacement["generation"] = "replacement-generation"
    try store.upsert(replacement)
    let api = makeBackupApi(defaults: fixture.defaults, store: store)

    XCTAssertEqual(
      api.handleUploadFailure(
        jobId: id,
        expectedGeneration: "old-generation",
        error: BackupSourceError(message: "录像文件已被替换，已停止备份")
      ),
      .staleGeneration
    )
    let stored = try XCTUnwrap(store.readJob(id: id))
    XCTAssertEqual(stored["generation"] as? String, "replacement-generation")
    XCTAssertEqual(stored["state"] as? String, "pending")
    XCTAssertNil(stored["errorMessage"])

    let summary = try await awaitSummaryResult(api)
    let visible = try XCTUnwrap(summary.activeJob)
    XCTAssertEqual(visible.id, id)
    XCTAssertEqual(visible.state, "pending")
    XCTAssertNil(visible.errorMessage)
  }

  func testFinishedUploadIdentityCannotRemoveReplacement() {
    let old = IosBackupUploadIdentity(
      generation: "old-generation",
      token: UUID()
    )
    let replacement = IosBackupUploadIdentity(
      generation: "new-generation",
      token: UUID()
    )

    XCTAssertFalse(
      IosBackupActiveUploadGate.shouldRemove(active: replacement, finished: old)
    )
    XCTAssertTrue(
      IosBackupActiveUploadGate.shouldRemove(
        active: replacement,
        finished: replacement
      )
    )
  }

  func testTenThousandQueuedUploadsAndWakeupsKeepTasksBounded() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    try executeBackupStoreSql(
      """
      WITH RECURSIVE counter(value) AS (
        SELECT 0
        UNION ALL
        SELECT value + 1 FROM counter WHERE value < 9999
      )
      INSERT INTO backup_jobs(
        id, generation, file_path, state, sessions, revision
      )
      SELECT
        printf('bounded-%05d', value),
        printf('generation-%05d', value),
        printf('/recordings/bounded-%05d.mp4', value),
        'pending', '[]', value
      FROM counter;
      """,
      databaseURL: fixture.databaseURL
    )
    let started = expectation(description: "唯一上传 worker 已启动")
    let gate = AsyncTestGate()
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { _, _ in
        started.fulfill()
        await gate.wait()
      }
    )

    for _ in 0..<10_000 { api.requestUploadDispatchForTesting() }
    await fulfillment(of: [started], timeout: 5)
    let running = api.uploadTaskCountsForTesting()
    XCTAssertEqual(running.dispatcher, 1)
    XCTAssertEqual(running.active, 1)

    await gate.open()
    await api.waitForUploadDispatcherForTesting()
    let finished = api.uploadTaskCountsForTesting()
    XCTAssertEqual(finished.dispatcher, 0)
    XCTAssertEqual(finished.active, 0)
  }

  func testUploadDispatcherRecoversInterruptedAndContinuesClaiming() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    var interrupted = makeBackupJob(id: "interrupted")
    interrupted["state"] = "uploading"
    try store.upsert(interrupted)
    try store.upsert(makeBackupJob(id: "pending-after-restart"))
    let completed = expectation(description: "恢复并继续领取后续任务")
    completed.expectedFulfillmentCount = 2
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { job, identity in
        _ = try? store.updateJob(
          id: job["id"] as? String ?? "",
          expectedGeneration: identity.generation
        ) { $0["state"] = "completed" }
        completed.fulfill()
      }
    )

    _ = try await awaitInitializeResult(api)
    await fulfillment(of: [completed], timeout: 5)
    await api.waitForUploadDispatcherForTesting()

    XCTAssertEqual(try store.summaryValues()["completedCount"] as? Int64, 2)
    XCTAssertEqual(api.uploadTaskCountsForTesting().active, 0)
  }

  func testUploadDispatcherCancelsAndRunsReplacementGeneration() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "dispatcher-replacement"
    let original = makeBackupJob(id: id)
    try store.upsert(original)
    let originalStarted = expectation(description: "旧代次已启动")
    let replacementCompleted = expectation(description: "新代次已完成")
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { job, identity in
        if identity.generation == original["generation"] as? String {
          originalStarted.fulfill()
          while !Task.isCancelled { await Task.yield() }
          return
        }
        _ = try? store.updateJob(
          id: job["id"] as? String ?? "",
          expectedGeneration: identity.generation
        ) { $0["state"] = "completed" }
        replacementCompleted.fulfill()
      }
    )

    api.requestUploadDispatchForTesting()
    await fulfillment(of: [originalStarted], timeout: 5)
    try await awaitVoidResult { api.requeueJob(jobId: id, completion: $0) }
    await fulfillment(of: [replacementCompleted], timeout: 5)
    await api.waitForUploadDispatcherForTesting()

    let stored = try XCTUnwrap(store.readJob(id: id))
    XCTAssertNotEqual(stored["generation"] as? String, original["generation"] as? String)
    XCTAssertEqual(stored["state"] as? String, "completed")
    XCTAssertEqual(api.uploadTaskCountsForTesting().active, 0)
  }

  func testUploadDispatcherCancelLeavesJobPausedAndStopsWorker() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "dispatcher-cancel"
    try store.upsert(makeBackupJob(id: id))
    let started = expectation(description: "待取消上传已启动")
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { _, _ in
        started.fulfill()
        while !Task.isCancelled { await Task.yield() }
      }
    )

    api.requestUploadDispatchForTesting()
    await fulfillment(of: [started], timeout: 5)
    try await awaitVoidResult { api.cancelJob(jobId: id, completion: $0) }
    await api.waitForUploadDispatcherForTesting()

    XCTAssertEqual(try store.readJob(id: id)?["state"] as? String, "paused")
    XCTAssertEqual(api.uploadTaskCountsForTesting().active, 0)
  }

  func testLanBackupHostResolverKeepsLargeProbeSetAtFourConcurrentTasks()
    async
  {
    let candidates = (0..<1_000).map { "http://candidate-\($0):5280" }
    let tracker = AsyncProbeTracker()
    let resolver = IosLanBackupHostResolver(
      candidateProvider: { candidates },
      probeOperation: { baseUrl, _ in
        guard baseUrl != "http://current:5280" else { return nil }
        await tracker.begin()
        try? await Task.sleep(nanoseconds: 100_000)
        await tracker.finish()
        return nil
      }
    )

    let result = await resolver.resolve(
      currentBaseUrl: "http://current:5280",
      expectedNodeId: "expected-node"
    )
    let counts = await tracker.counts()

    XCTAssertNil(result)
    XCTAssertEqual(counts.started, candidates.count)
    XCTAssertEqual(counts.active, 0)
    XCTAssertLessThanOrEqual(counts.maximumActive, 4)
  }

  func testLanBackupHostResolverCancelsRemainingProbesAfterMatch() async {
    let candidates = ["slow-0", "match", "slow-1", "slow-2"]
      + (3..<1_000).map { "slow-\($0)" }
    let tracker = AsyncProbeTracker()
    let resolver = IosLanBackupHostResolver(
      candidateProvider: { candidates },
      probeOperation: { baseUrl, _ in
        guard baseUrl != "current" else { return nil }
        await tracker.begin()
        if baseUrl == "match" {
          await tracker.waitUntilStarted(4)
          await tracker.finish()
          return baseUrl
        }
        do {
          try await Task.sleep(nanoseconds: 5_000_000_000)
          await tracker.finish()
          return nil
        } catch {
          await tracker.cancelAndFinish()
          return nil
        }
      }
    )

    let result = await resolver.resolve(
      currentBaseUrl: "current",
      expectedNodeId: "expected-node"
    )
    let counts = await tracker.counts()

    XCTAssertEqual(result, "match")
    XCTAssertEqual(counts.active, 0)
    XCTAssertGreaterThan(counts.cancelled, 0)
    XCTAssertLessThanOrEqual(counts.started, 4)
    XCTAssertLessThanOrEqual(counts.maximumActive, 4)
  }

  func testLanBackupHostResolverCompletesAllCandidatesWhenNothingMatches()
    async
  {
    let candidates = (0..<257).map { "candidate-\($0)" }
    let tracker = AsyncProbeTracker()
    let resolver = IosLanBackupHostResolver(
      candidateProvider: { candidates },
      probeOperation: { baseUrl, _ in
        guard baseUrl != "current" else { return nil }
        await tracker.begin()
        await Task.yield()
        await tracker.finish()
        return nil
      }
    )

    let result = await resolver.resolve(
      currentBaseUrl: "current",
      expectedNodeId: "expected-node"
    )
    let counts = await tracker.counts()

    XCTAssertNil(result)
    XCTAssertEqual(counts.started, candidates.count)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.cancelled, 0)
    XCTAssertLessThanOrEqual(counts.maximumActive, 4)
  }

  func testSystemIosKeychainClientRoundTrip() throws {
    let client = SystemIosKeychainClient()
    let service = "RunnerTests.keychain.\(UUID().uuidString)"
    let account = "access-key"
    defer { try? client.delete(service: service, account: account) }

    do {
      try client.save(
        Data("system-keychain-value".utf8), service: service, account: account
      )
    } catch let error as IosBackupCredentialError where error.status == -34_018 {
      throw XCTSkip("未签名测试包没有 Keychain entitlement")
    }
    XCTAssertEqual(
      try client.read(service: service, account: account),
      Data("system-keychain-value".utf8)
    )
    try client.delete(service: service, account: account)
    XCTAssertNil(try client.read(service: service, account: account))
  }

  private typealias ReceiptFixture = (
    response: [String: Any], accessKey: String, host: String, device: String,
    session: String, sha256: String, fileSize: Int64, recordId: Int64, now: Int64
  )

  private func makeReceiptFixture() -> ReceiptFixture {
    let accessKey = "test-backup-access-key"
    let host = "HOST-123"
    let device = "DEVICE-456"
    let session = "session-789"
    let sha256 = String(repeating: "a", count: 64)
    let fileSize: Int64 = 12_345
    let recordId: Int64 = 678
    let now: Int64 = 1_800_000_000
    let canonical = [
      "packingproof-verified-receipt-v3", host.lowercased(), device.lowercased(),
      session, sha256, String(fileSize), String(recordId), String(now),
    ].joined(separator: "\n")
    let key = SymmetricKey(data: Data(accessKey.utf8))
    let signature = HMAC<SHA256>.authenticationCode(
      for: Data(canonical.utf8), using: key
    ).map { String(format: "%02x", $0) }.joined()
    return (
      [
        "status": "verified",
        "authVersion": 3,
        "verifiedAtUnixSeconds": now,
        "hostNodeId": host,
        "sourceDeviceId": device,
        "sourceSessionId": session,
        "fileSha256": sha256,
        "fileSizeBytes": fileSize,
        "recordId": recordId,
        "receiptSignature": signature,
      ],
      accessKey, host, device, session, sha256, fileSize, recordId, now
    )
  }

  private func verifyReceipt(
    _ response: [String: Any], fixture: ReceiptFixture
  ) -> Bool {
    IosBackupReceiptVerifier.verify(
      response,
      accessKey: fixture.accessKey,
      hostNodeId: fixture.host,
      sourceDeviceId: fixture.device,
      sourceSessionId: fixture.session,
      fileSha256: fixture.sha256,
      fileSizeBytes: fixture.fileSize,
      recordId: fixture.recordId,
      now: Date(timeIntervalSince1970: TimeInterval(fixture.now))
    )
  }

  private typealias BackupStoreFixture = (
    root: URL, databaseURL: URL, defaults: UserDefaults, suiteName: String
  )

  private func makeBackupStoreFixture() throws -> BackupStoreFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("backup-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "RunnerTests.backup-store.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (root, root.appendingPathComponent("lan_backup.db"), defaults, suiteName)
  }

  private func removeBackupStoreFixture(_ fixture: BackupStoreFixture) {
    fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    try? FileManager.default.removeItem(at: fixture.root)
  }

  private func executeBackupStoreSql(_ sql: String, databaseURL: URL) throws {
    var database: OpaquePointer?
    let openCode = sqlite3_open_v2(
      databaseURL.path,
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openCode == SQLITE_OK else {
      sqlite3_close(database)
      throw IosBackupStoreError(
        operation: "测试打开", code: openCode, message: "无法打开测试数据库"
      )
    }
    defer { sqlite3_close(database) }
    let executeCode = sqlite3_exec(database, sql, nil, nil, nil)
    guard executeCode == SQLITE_OK else {
      throw IosBackupStoreError(
        operation: "测试写入", code: executeCode, message: "无法修改测试数据库"
      )
    }
  }

  private func makeBackupApi(
    defaults: UserDefaults,
    store: IosBackupJobStore,
    uploadFailureUpdateOverride: ((String, String) throws -> Bool)? = nil,
    uploadPersistenceFailureReporter:
      ((String, String, Error) -> Void)? = nil,
    uploadOperationOverride:
      (([String: Any], IosBackupUploadIdentity) async -> Void)? = nil,
    storageReclaimOperationOverride:
      (() async throws -> [String?: Any?])? = nil,
    cleanupOperationOverride: (() async throws -> Void)? = nil
  ) -> IosBackupHostApi {
    IosBackupHostApi(
      eventApi: FakeBackupNativeEventApi(),
      defaults: defaults,
      credentialStore: IosBackupCredentialStore(
        defaults: defaults,
        keychain: FakeIosKeychainClient(),
        service: "RunnerTests.backup-api.\(UUID().uuidString)",
        account: "access-key"
      ),
      jobStore: .success(store),
      recordingsRoot: FileManager.default.temporaryDirectory,
      uploadFailureUpdateOverride: uploadFailureUpdateOverride,
      uploadPersistenceFailureReporter: uploadPersistenceFailureReporter,
      uploadOperationOverride: uploadOperationOverride,
      storageReclaimOperationOverride: storageReclaimOperationOverride,
      cleanupOperationOverride: cleanupOperationOverride
    )
  }

  private typealias RetentionCleanupFixture = (
    root: URL, defaults: UserDefaults, suiteName: String, store: IosBackupJobStore,
    api: IosBackupHostApi, file: URL, job: [String: Any]
  )

  private func makeRetentionCleanupFixture(
    id: String,
    availableStorageBytesOverride: (() -> Int64)? = nil,
    storageAttestationOverride:
      (([String: Any], String, Int64) async -> String?)? = nil,
    onSnapshot: ((BackupSummaryDto) -> Void)? = nil
  ) throws -> RetentionCleanupFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "retention-cleanup-\(UUID().uuidString)", isDirectory: true
      )
    let recordings = root.appendingPathComponent("recordings", isDirectory: true)
    try FileManager.default.createDirectory(
      at: recordings, withIntermediateDirectories: true
    )
    let file = recordings.appendingPathComponent("\(id).mp4")
    let contents = Data("retention-cleanup-fixture".utf8)
    try contents.write(to: file)
    let snapshot = try IosBackupFileSnapshot.read(from: file)
    let suiteName = "RunnerTests.retention-cleanup.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let store = try IosBackupJobStore(
      databaseURL: root.appendingPathComponent("lan_backup.db"), defaults: defaults
    )
    let credentialStore = IosBackupCredentialStore(
      defaults: defaults,
      keychain: FakeIosKeychainClient(),
      service: suiteName,
      account: "access-key"
    )
    let api = IosBackupHostApi(
      eventApi: FakeBackupNativeEventApi(onSnapshot: onSnapshot),
      defaults: defaults,
      credentialStore: credentialStore,
      jobStore: .success(store),
      recordingsRoot: recordings,
      availableStorageBytesOverride: availableStorageBytesOverride,
      storageAttestationOverride: storageAttestationOverride
    )
    var job = makeBackupJob(id: id)
    job["filePath"] = file.path
    job["state"] = "completed"
    job["totalBytes"] = snapshot.byteCount
    job["lastModified"] = snapshot.modifiedAtMilliseconds
    job["contentSha256"] = SHA256.hash(data: contents)
      .map { String(format: "%02x", $0) }.joined()
    job["backupCompletedAt"] = "2020-01-01T00:00:00Z"
    return (root, defaults, suiteName, store, api, file, job)
  }

  private func makeVerifiedStorageReclaimJob(
    _ source: [String: Any]
  ) -> [String: Any] {
    var job = source
    job["verificationVersion"] = 3
    job["verificationReceipt"] = "stored-signed-receipt"
    job["remoteRecordId"] = NSNumber(value: 42)
    job["lastAttestedAt"] = ISO8601DateFormatter().string(from: Date())
    return job
  }

  private func removeRetentionCleanupFixture(_ fixture: RetentionCleanupFixture) {
    fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    try? FileManager.default.removeItem(at: fixture.root)
  }

  private func awaitVoidResult(
    _ operation: (@escaping (Result<Void, Error>) -> Void) -> Void
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      operation { result in
        continuation.resume(with: result)
      }
    }
  }

  private func awaitSummaryResult(
    _ api: IosBackupHostApi
  ) async throws -> BackupSummaryDto {
    try await withCheckedThrowingContinuation { continuation in
      api.summary { result in
        continuation.resume(with: result)
      }
    }
  }

  private func awaitInitializeResult(
    _ api: IosBackupHostApi
  ) async throws -> BackupSummaryDto {
    try await withCheckedThrowingContinuation { continuation in
      api.initialize(request: [:]) { result in
        continuation.resume(with: result)
      }
    }
  }

  private func awaitStorageReclaim(
    _ api: IosBackupHostApi
  ) async throws -> [String?: Any?] {
    try await withCheckedThrowingContinuation { continuation in
      api.reclaimStorageIfNeeded { result in
        continuation.resume(with: result)
      }
    }
  }

  private func awaitAvailableRecordingStorageBytes(
    _ api: IosBackupHostApi
  ) async throws -> Int64? {
    try await withCheckedThrowingContinuation { continuation in
      api.availableRecordingStorageBytes { result in
        continuation.resume(with: result)
      }
    }
  }

  private func makeBackupJob(id: String) -> [String: Any] {
    [
      "id": id,
      "generation": "generation-\(id)",
      "filePath": "/recordings/\(id).mp4",
      "state": "pending",
      "uploadedBytes": 0,
      "totalBytes": 1024,
      "lastModified": 1_800_000_000_000,
      "sessions": [["id": "session-\(id)", "trackingNumber": "tracking-\(id)"]],
    ]
  }

}

private final class FakeBackupNativeEventApi: BackupNativeEventApiProtocol {
  private let onSnapshot: ((BackupSummaryDto) -> Void)?

  init(onSnapshot: ((BackupSummaryDto) -> Void)? = nil) {
    self.onSnapshot = onSnapshot
  }

  func summaryChanged(
    summary: BackupSummaryDto,
    completion: @escaping (Result<Void, PigeonError>) -> Void
  ) {
    onSnapshot?(summary)
    completion(.success(()))
  }
}

private final class FakeIosKeychainClient: IosKeychainClient {
  var data: Data?
  var readCount = 0
  var readError: Error?
  var saveError: Error?
  var deleteError: Error?

  func read(service: String, account: String) throws -> Data? {
    readCount += 1
    if let readError { throw readError }
    return data
  }

  func save(_ data: Data, service: String, account: String) throws {
    if let saveError { throw saveError }
    self.data = data
  }

  func delete(service: String, account: String) throws {
    if let deleteError { throw deleteError }
    data = nil
  }
}

private actor AsyncTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

private actor AsyncProbeTracker {
  private var started = 0
  private var active = 0
  private var maximumActive = 0
  private var cancelled = 0
  private var startWaiters: [(
    count: Int, continuation: CheckedContinuation<Void, Never>
  )] = []

  func begin() {
    started += 1
    active += 1
    maximumActive = max(maximumActive, active)
    let ready = startWaiters.filter { started >= $0.count }
    startWaiters.removeAll { started >= $0.count }
    for waiter in ready { waiter.continuation.resume() }
  }

  func waitUntilStarted(_ count: Int) async {
    if started >= count { return }
    await withCheckedContinuation { continuation in
      startWaiters.append((count, continuation))
    }
  }

  func finish() {
    active -= 1
  }

  func cancelAndFinish() {
    cancelled += 1
    active -= 1
  }

  func counts() -> (
    started: Int, active: Int, maximumActive: Int, cancelled: Int
  ) {
    (started, active, maximumActive, cancelled)
  }
}

private enum MaintenanceTestError: Error {
  case expected
}

private actor AsyncMaintenanceTracker {
  private var started = 0
  private var active = 0
  private var maximumActive = 0

  func begin() -> Int {
    started += 1
    active += 1
    maximumActive = max(maximumActive, active)
    return started
  }

  func finish() {
    active -= 1
  }

  func counts() -> (started: Int, active: Int, maximumActive: Int) {
    (started, active, maximumActive)
  }
}
