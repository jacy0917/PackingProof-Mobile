import Foundation
import Flutter
import AVFoundation

// ⭐ ========== IosCameraPlatform.swift 缺失的类型 ==========

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

enum IosCameraRecordingLifecycle {
    enum Rejection {
        case busy
        case alreadyStarted
        case notStarted
        case unknown
    }
}

// ⭐ ========== PigeonPlatform.swift 需要的类型 ==========

// 这个类需要与 Pigeon 生成的 IosCameraHostApi 协议兼容
// 存根只需让编译器通过，运行时实际使用 Pigeon 生成的类
class IosCameraHostApi {
    // ⭐ 关键：构造方法需要匹配 PigeonPlatform.swift 中的调用
    init(
        eventApi: Any,
        textures: FlutterTextureRegistry,
        audioSessionCoordinator: IosSharedAudioSessionCoordinator
    ) {}
    
    func prepareForTermination() {}
}

// IosBackupHostApi 的存根
class IosBackupHostApi {
    init(eventApi: Any, hostForeground: Bool) {}
    func onHostForeground() {}
    func onHostBackground() {}
}

// IosSharedAudioSessionCoordinator 的存根
class IosSharedAudioSessionCoordinator {
    static let shared = IosSharedAudioSessionCoordinator()
    
    func acquire(_ reason: Any) throws {}
    func release(_ reason: Any) throws {}
}

// IosPromptAudioHost 的存根（实际已在 PigeonPlatform.swift 中定义，但为了编译顺序，提供空声明）
// 实际上不需要，因为它在 PigeonPlatform.swift 底部已定义

// 注意：CameraHostApiSetup 应该由 Pigeon 生成，但名称是 IosCameraHostApiSetup
// 所以我们在 PigeonPlatform.swift 中会修改调用
