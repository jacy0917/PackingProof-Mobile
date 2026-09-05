import Foundation
import Flutter
import AVFoundation

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
    ) -> Bool { return true }
    func recordTrackResult(serial: Int64, trackCount: Int64?, inspectionError: String?) {}
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
    func submit(_ value: T, now: TimeInterval) -> Action { return .send(value) }
    func complete(now: TimeInterval) -> Action { return .none }
    func wake(now: TimeInterval) -> Action { return .none }
    func reset() {}
}

class IosCameraEventApiImplementation {
    func segmentStarted(path: String, segmentId: String, startedAtMs: Int64, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func segmentEnded(stopDto: Any, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func barcodesDetected(candidates: [Any], completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}

struct IosCameraOperationTiming {
    let operation: String
    init(operation: String) { self.operation = operation }
    func finish(succeeded: Bool) -> [String: Any]? { return ["operation": operation, "succeeded": succeeded] }
}

class IosLiveWatermarkRenderer {
    func updateText(_ text: String) {}
}

struct IosRecordingSpecEncodingPolicy {
    static func averageBitRate(spec: String, codec: String) -> Int { return 2000000 }
}

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

enum IosCameraVideoAppendPolicy {
    static func appendWhenReady(isReady: Bool, append: () -> Void, onWritten: (() -> Void)?) {
        if isReady { append(); onWritten?() }
    }
}

enum IosAudioSampleEnergyProbe {
    static func normalizedPeak(in sampleBuffer: CMSampleBuffer) -> Float? { return 0.5 }
}

enum IosBarcodeVisionFallbackPolicy {
    static func shouldSchedule(now: TimeInterval, lastCandidateAt: TimeInterval, lastSubmittedAt: TimeInterval, inFlight: Bool, scanningEnabled: Bool) -> Bool {
        return scanningEnabled && !inFlight
    }
}

enum IosCameraRecordingLifecycle {
    enum Operation { case stop, split }
    enum Rejection { case busy, alreadyStarted, notStarted, unknown }
    class Request { func complete() {}; func cancel() {} }
    func begin(_ operation: Operation, onCancelled: @escaping () -> Void, completion: (Result<Request, Rejection>) -> Void) { completion(.success(Request())) }
    func dispose() {}
}

class IosSharedAudioSessionCoordinator {
    static let shared = IosSharedAudioSessionCoordinator()
    func acquire(_ reason: Any) throws {}
    func release(_ reason: Any) throws {}
    func abandon(_ reason: Any) {}
}

class IosBackupHostApi {
    init(eventApi: Any, hostForeground: Bool) {}
    func onHostForeground() {}
    func onHostBackground() {}
}

class IosPromptAudioHost: NSObject {
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {}
}

// ⭐ ========== 关键修改 ==========
// 实现 IosCameraHostApi 协议的具体类，而不是定义同名类
// 注意：此类需要实现 IosCameraHostApi 协议中的所有方法
// 由于 Pigeon 生成的协议方法很多，这里提供一个最小化实现
class IosCameraHostApiImpl: NSObject, IosCameraHostApi {
    // 实现所有协议方法（空实现）
    func initialize(request: CameraInitializeRequest, completion: @escaping (Result<CameraInitializationDto, Error>) -> Void) {
        completion(.success(CameraInitializationDto(textureId: 0, previewWidth: 0, previewHeight: 0, sensorOrientation: 0, fps: 0, videoMime: "", codecFallbackReason: nil, flashAvailable: false, lensDirection: "", canSwitchCamera: false, cameraId: nil, zoomRatio: 1.0)))
    }
    func ensurePermissions(recordAudio: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }
    func startWork(path: String, recordAudio: Bool, trackingNumber: String, completion: @escaping (Result<CameraRecordingStartDto, Error>) -> Void) {
        completion(.success(CameraRecordingStartDto(segmentId: "", startedAtMs: 0, recordingPath: "")))
    }
    func split(nextPath: String, trackingNumber: String, completion: @escaping (Result<CameraRecordingSplitDto, Error>) -> Void) {
        completion(.failure(NSError(domain: "IosCamera", code: -1)))
    }
    func stopWork(completion: @escaping (Result<CameraRecordingStopDto, Error>) -> Void) {
        completion(.failure(NSError(domain: "IosCamera", code: -1)))
    }
    func getDiagnostics(completion: @escaping (Result<[String: Any]?, Error>) -> Void) {
        completion(.success(nil))
    }
    func setPairingScanEnabled(enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    func setWorkScanEnabled(enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    func setPreviewActive(active: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    func setTorchEnabled(enabled: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }
    func switchCamera(completion: @escaping (Result<CameraInitializationDto, Error>) -> Void) {
        completion(.success(CameraInitializationDto(textureId: 0, previewWidth: 0, previewHeight: 0, sensorOrientation: 0, fps: 0, videoMime: "", codecFallbackReason: nil, flashAvailable: false, lensDirection: "", canSwitchCamera: false, cameraId: nil, zoomRatio: 1.0)))
    }
    func listCameras(completion: @escaping (Result<[CameraLensDto], Error>) -> Void) {
        completion(.success([]))
    }
    func switchToCamera(cameraId: String, completion: @escaping (Result<CameraInitializationDto, Error>) -> Void) {
        completion(.success(CameraInitializationDto(textureId: 0, previewWidth: 0, previewHeight: 0, sensorOrientation: 0, fps: 0, videoMime: "", codecFallbackReason: nil, flashAvailable: false, lensDirection: "", canSwitchCamera: false, cameraId: nil, zoomRatio: 1.0)))
    }
    func probeSequence(sequence: String, budgetMs: Int64, completion: @escaping (Result<[String: Any]?, Error>) -> Void) {
        completion(.success(nil))
    }
    func setCapabilityMode(mode: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    func dispose(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    func prepareForTermination() {}
}

// ⭐ 修正：IosCameraHostApiSetup 是 Pigeon 生成的，用于注册上面的实现类
// 它期望的参数是 (binaryMessenger: FlutterBinaryMessenger, api: IosCameraHostApi)
// 所以我们传入 IosCameraHostApiImpl 实例

// ⭐ 注意：IosCameraHostApi 协议由 Pigeon 生成，不要在这里定义
// ⭐ 注意：CameraRecordingStopDto 由 Pigeon 生成，不要在这里定义
// ⭐ 注意：BarcodeCandidateDto 由 Pigeon 生成，不要在这里定义
