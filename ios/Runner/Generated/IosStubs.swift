import Foundation
import Flutter

// ⭐ 为 IosCameraPlatform.swift 缺失的类型提供存根

class IosCameraActivityState {}
class IosAudioSessionCoordinator {}
class IosLastSegmentDiagnostics {
    func snapshot() -> IosLastSegmentDiagnosticsState {
        return IosLastSegmentDiagnosticsState()
    }
}
class IosFirstWrittenFrameTiming {
    func recordWrittenFrameIfNeeded() {}
}

class IosLatestPendingGate<T> {
    func process(_ action: IosLatestPendingGate<T>.Action) {}
    enum Action {}
}

class IosCameraEventApiImplementation {}

struct IosCameraOperationTiming {
    init(operation: String) {}
}

struct IosLastSegmentDiagnosticsState {}

struct IosRecordingSpecEncodingPolicy {
    static func averageBitRate(spec: String, codec: String) -> Int { return 0 }
}

enum IosCameraWriterFinishPolicy {
    static func missingWriterError() -> Error {
        return NSError(domain: "IosCamera", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writer missing"])
    }
    static func result(completion: @escaping (Result<Void, Error>) -> Void) -> Any? {
        return nil
    }
}

enum IosCameraVideoAppendPolicy {
    static func appendWhenReady(_ closure: @escaping () -> Void) {}
}

enum IosAudioSampleEnergyProbe {
    static func normalizedPeak(in sampleBuffer: Any) -> Float? { return nil }
}

enum IosBarcodeVisionFallbackPolicy {
    static func shouldSchedule(_ closure: @escaping () -> Void) -> Bool { return false }
}

// ⭐ IosCameraRecordingLifecycle 补充 Rejection 成员
enum IosCameraRecordingLifecycle {
    enum Rejection {
        case busy
        case alreadyStarted
        case notStarted
        case unknown
    }
}

// ⭐ PigeonPlatform 需要的类型（如果生成的代码里已有，这里会冲突）
// 但实际上生成的 PlatformApi.swift 中并没有定义这些，所以我们提供存根
class IosCameraHostApi {
    init(binaryMessenger: FlutterBinaryMessenger) {}
    func prepareForTermination() {}
}

// 注意：CameraHostApiSetup 实际上由 Pigeon 生成，但 Pigeon 生成的是 IosCameraHostApiSetup
// 所以我们需要在 PigeonPlatform.swift 中修改调用
