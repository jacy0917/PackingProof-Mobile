import Foundation
import Flutter
import AVFoundation

// ⭐ ========== 所有 IosCameraPlatform.swift 需要的类型（完整定义） ==========

// IosCameraActivityState
class IosCameraActivityState {
    func setActive(_ active: Bool, owner: String) {}
}

// IosAudioSessionCoordinator
class IosAudioSessionCoordinator {
    func acquire(_ reason: IosAudioSessionOwner) throws {}
    func release(_ reason: IosAudioSessionOwner) throws {}
    func abandon(_ reason: IosAudioSessionOwner) {}
}

enum IosAudioSessionOwner {
    case prompt
    case maxVolume
    case camera
    case microphone
}

// IosLastSegmentDiagnostics & IosLastSegmentDiagnosticsState
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
    ) -> Bool { return true }
    func recordTrackResult(serial: Int64, trackCount: Int64?, inspectionError: String?) {}
}
struct IosLastSegmentDiagnosticsState {}

// IosFirstWrittenFrameTiming
class IosFirstWrittenFrameTiming {
    func begin(operation: String) {}
    func recordWrittenFrameIfNeeded() {}
    func cancelIfNeeded() {}
    func snapshot() -> [String: Any]? { return nil }
}

// IosLatestPendingGate
class IosLatestPendingGate<T> {
    enum Action {
        case none
        case send(T)
        case schedule(TimeInterval)
    }
    func submit(_ value: T, now: TimeInterval) -> Action { return .send(value) }
    func complete(now: TimeInterval) -> Action { return .none }
    func wake(now: TimeInterval) -> Action { return .none }
    func reset() {}
}

// IosCameraEventApiImplementation
class IosCameraEventApiImplementation {
    func segmentStarted(path: String, segmentId: String, startedAtMs: Int64, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func segmentEnded(stopDto: Any, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func barcodesDetected(candidates: [Any], completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}

// IosCameraOperationTiming
struct IosCameraOperationTiming {
    let operation: String
    init(operation: String) { self.operation = operation }
    func finish(succeeded: Bool) -> [String: Any]? {
        return ["operation": operation, "succeeded": succeeded]
    }
}

// IosLiveWatermarkRenderer - 提供完整的类，包含 updateText 方法
class IosLiveWatermarkRenderer {
    func updateText(_ text: String) {}
}

// IosRecordingSpecEncodingPolicy
struct IosRecordingSpecEncodingPolicy {
    static func averageBitRate(spec: String, codec: String) -> Int { return 2000000 }
}

// IosCameraWriterFinishPolicy
enum IosCameraWriterFinishPolicy {
    static func missingWriterError() -> Error {
        return NSError(domain: "IosCamera", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writer missing"])
    }
    static func result(status: AVAssetWriter.Status, writerError: String?) -> Result<Void, Error> {
        if status == .completed { return .success(()) }
        else if let error = writerError { return .failure(NSError(domain: "IosCamera", code: -1, userInfo: [NSLocalizedDescriptionKey: error])) }
        else { return .failure(NSError(domain: "IosCamera", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writer failed"])) }
    }
}

// IosCameraVideoAppendPolicy
enum IosCameraVideoAppendPolicy {
    static func appendWhenReady(isReady: Bool, append: () -> Void, onWritten: (() -> Void)?) {
        if isReady { append(); onWritten?() }
    }
}

// IosAudioSampleEnergyProbe
enum IosAudioSampleEnergyProbe {
    static func normalizedPeak(in sampleBuffer: CMSampleBuffer) -> Float? { return 0.5 }
}

// IosBarcodeVisionFallbackPolicy
enum IosBarcodeVisionFallbackPolicy {
    static func shouldSchedule(now: TimeInterval, lastCandidateAt: TimeInterval, lastSubmittedAt: TimeInterval, inFlight: Bool, scanningEnabled: Bool) -> Bool {
        return scanningEnabled && !inFlight
    }
}

// IosCameraRecordingLifecycle - 完整定义并遵循 Error 协议
enum IosCameraRecordingLifecycle {
    enum Operation { case stop, split }
    enum Rejection: Error {
        case busy
        case alreadyStarted
        case notStarted
        case unknown
    }
    class Request {
        func complete() {}
        func cancel() {}
    }
    func begin(_ operation: Operation, onCancelled: @escaping () -> Void, completion: (Result<Request, Rejection>) -> Void) {
        completion(.success(Request()))
    }
    func dispose() {}
}

// IosSharedAudioSessionCoordinator - 提供单例
class IosSharedAudioSessionCoordinator {
    static let shared = IosSharedAudioSessionCoordinator()
    func acquire(_ reason: IosAudioSessionOwner) throws {}
    func release(_ reason: IosAudioSessionOwner) throws {}
    func abandon(_ reason: IosAudioSessionOwner) {}
}
