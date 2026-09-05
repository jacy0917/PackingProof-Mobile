import Foundation
import Flutter
import AVFoundation
import UIKit
import Vision

// ⭐ ========== IosCameraPlatform.swift 缺失的类型 ==========

class IosCameraActivityState {
    func setActive(_ active: Bool, owner: String) {}
}

class IosAudioSessionCoordinator {
    func acquire(_ reason: Any) throws {}
    func release(_ reason: Any) throws {}
    func abandon(_ reason: Any) {}
}

class IosLastSegmentDiagnostics {
    func currentState() -> IosLastSegmentDiagnosticsState {
        return IosLastSegmentDiagnosticsState()
    }
    func recordWriterResult(
        serial: Int64,
        writerStatus: String,
        writerError: String?,
        hasCompletedFile: Bool,
        inspectionError: String?
    ) -> Bool {
        return true
    }
    func recordTrackResult(
        serial: Int64,
        trackCount: Int64?,
        inspectionError: String?
    ) {}
}

struct IosLastSegmentDiagnosticsState {}

class IosFirstWrittenFrameTiming {
    func begin(operation: String) {}
    func recordWrittenFrameIfNeeded() {}
    func cancelIfNeeded() {}
    func snapshot() -> [String: Any]? { return nil }
}

class IosLatestPendingGate<T> {
    enum Action {
        case none
        case send(T)
        case schedule(TimeInterval)
    }
    func submit(_ value: T, now: TimeInterval) -> Action {
        return .send(value)
    }
    func complete(now: TimeInterval) -> Action {
        return .none
    }
    func wake(now: TimeInterval) -> Action {
        return .none
    }
    func reset() {}
}

class IosCameraEventApiImplementation {
    func segmentStarted(path: String, segmentId: String, startedAtMs: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    func segmentEnded(stopDto: CameraRecordingStopDto, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    func barcodesDetected(candidates: [BarcodeCandidateDto], completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}

struct IosCameraOperationTiming {
    let operation: String
    func finish(succeeded: Bool) -> [String: Any]? {
        return ["operation": operation, "succeeded": succeeded]
    }
}

class IosLiveWatermarkRenderer {
    func updateText(_ text: String) {}
}

struct IosRecordingSpecEncodingPolicy {
    static func averageBitRate(spec: String, codec: String) -> Int {
        return 2000000 // 2 Mbps default
    }
}

enum IosCameraWriterFinishPolicy {
    static func missingWriterError() -> Error {
        return NSError(domain: "IosCamera", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writer missing"])
    }
    static func result(status: AVAssetWriter.Status, writerError: String?) -> Result<Void, Error> {
        if status == .completed {
            return .success(())
        } else if let error = writerError {
            return .failure(NSError(domain: "IosCamera", code: -1, userInfo: [NSLocalizedDescriptionKey: error]))
        } else {
            return .failure(NSError(domain: "IosCamera", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writer failed"]))
        }
    }
}

enum IosCameraVideoAppendPolicy {
    static func appendWhenReady(
        isReady: Bool,
        append: () -> Void,
        onWritten: (() -> Void)?
    ) {
        if isReady {
            append()
            onWritten?()
        }
    }
}

enum IosAudioSampleEnergyProbe {
    static func normalizedPeak(in sampleBuffer: CMSampleBuffer) -> Float? {
        return 0.5
    }
}

enum IosBarcodeVisionFallbackPolicy {
    static func shouldSchedule(
        now: TimeInterval,
        lastCandidateAt: TimeInterval,
        lastSubmittedAt: TimeInterval,
        inFlight: Bool,
        scanningEnabled: Bool
    ) -> Bool {
        return scanningEnabled && !inFlight
    }
}

enum IosCameraRecordingLifecycle {
    enum Operation {
        case stop, split
    }
    enum Rejection {
        case busy
        case alreadyStarted
        case notStarted
        case unknown
    }
    class Request {
        func complete() {}
        func cancel() {}
    }
    func begin(
        _ operation: Operation,
        onCancelled: @escaping () -> Void,
        completion: (Result<Request, Rejection>) -> Void
    ) {
        completion(.success(Request()))
    }
    func dispose() {}
}

class IosSharedAudioSessionCoordinator {
    static let shared = IosSharedAudioSessionCoordinator()
    func acquire(_ reason: Any) throws {}
    func release(_ reason: Any) throws {}
    func abandon(_ reason: Any) {}
}

// ⭐ ========== PigeonPlatform.swift 需要的类型 ==========

// 注意：IosCameraHostApi 实际由 Pigeon 生成，但为了编译通过，提供存根类
// 在 PigeonPlatform.swift 中会使用 IosCameraHostApi(eventApi:textures:audioSessionCoordinator:)
class IosCameraHostApi {
    init(
        eventApi: Any,
        textures: FlutterTextureRegistry,
        audioSessionCoordinator: IosSharedAudioSessionCoordinator
    ) {}
    func prepareForTermination() {}
}

class IosBackupHostApi {
    init(eventApi: Any, hostForeground: Bool) {}
    func onHostForeground() {}
    func onHostBackground() {}
}

class IosPromptAudioHost: NSObject {
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {}
}

// 注意：CameraHostApiSetup 应改为 IosCameraHostApiSetup（在 PigeonPlatform.swift 中修改）
// 存根定义，实际由 Pigeon 生成
class IosCameraHostApiSetup {
    static func setUp(
        binaryMessenger: FlutterBinaryMessenger,
        api: IosCameraHostApi
    ) {}
}

// ⭐ ========== 其他可能缺失的类型 ==========
// CameraRecordingStopDto 可能在其他地方定义，但我们只在存根中使用，所以提供一个空结构体
struct CameraRecordingStopDto {
    let segmentId: String
    let startedAtMs: Int64
    let stoppedAtMs: Int64
    let recordingPath: String
    let audioPeak: Double
}

// BarcodeCandidateDto 由 Pigeon 生成，不需要在这里定义，但我们需要确保使用正确的参数
// 这里不重复定义，以免冲突。

// 如果还有缺失，请参考此模式添加。
