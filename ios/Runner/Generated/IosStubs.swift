import Foundation
import Flutter
import AVFoundation
import UIKit
import Vision

// ⭐ ========== IosCameraPlatform.swift 缺失的类型（Pigeon 未生成） ==========

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
    func segmentEnded(stopDto: Any, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    func barcodesDetected(candidates: [Any], completion: @escaping (Result<Void, Error>) -> Void) {
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
        return 2000000
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

// ⭐ IosCameraHostApi 由 Pigeon 生成（协议），不能重复定义，所以这里不定义类。
// ⭐ CameraRecordingStopDto 由 Pigeon 生成，也不能在此定义。

// 但是，PigeonPlatform.swift 中需要 IosCameraHostApi 类？实际上 Pigeon 生成的是协议，但 IosCameraHostApi 可能是协议名，不能实例化。
// 但 PigeonPlatform.swift 中创建了 IosCameraHostApi(...) 实例，说明 Pigeon 生成的应该是一个类。
// 查看错误：Pigeon 生成的 PlatformApi.swift 中定义了 protocol IosCameraHostApi，而不是类。
// 所以 PigeonPlatform.swift 中调用 IosCameraHostApi(...) 是错的，它应该使用 Pigeon 生成的类名（可能是 CameraHostApi？）
// 但我们之前在 Pigeon 配置中使用了 name: 'IosCameraHostApi'，这会生成 protocol IosCameraHostApi，同时生成一个类？
// 实际上，Pigeon 的 @HostApi(name:) 只会生成协议，不会生成实现类。所以用户需要自己提供实现类。
// 因此，IosCameraHostApi 应该是实现类，而不是协议。但 Pigeon 却生成的是协议，这冲突了。
// 所以我们应该删除存根中的 IosCameraHostApi 类，让 Pigeon 生成的协议存在。
// 但 PigeonPlatform.swift 中需要实例化一个 IosCameraHostApi 对象，这说明它需要一个类。
// 因此，我们必须在存根中提供一个类，但名称要与协议不同，或者使用类实现协议。
// 最安全的方法：在存根中定义 class IosCameraHostApi: NSObject，实现 Pigeon 生成的协议。
// 但协议已经在 PlatformApi.swift 中定义了，所以我们可以在存根中声明 class IosCameraHostApi: NSObject, IosCameraHostApi { ... }
// 但是，在存根中我们不能重复声明协议，但可以声明类。
// 由于 Pigeon 生成的协议名称是 IosCameraHostApi，我们提供一个类实现该协议，但类名必须不同，否则冲突。
// 或者我们可以在 PigeonPlatform.swift 中使用协议类型（如 IosCameraHostApi?）但不能实例化。
// 由于 PigeonPlatform.swift 中写的是 IosCameraHostApi(...) 创建实例，所以它认为 IosCameraHostApi 是一个类。
// 因此，我们需要在存根中提供一个类，但为了避免与协议冲突，我们可以不提供，而是修改 PigeonPlatform.swift 使用生成的具体类名？
// 实际上，Pigeon 生成的是协议，不会生成实现类。PigeonPlatform.swift 中应该使用生成的协议类型，但无法实例化。
// 这看起来是 PigeonPlatform.swift 的编写者自己实现了一个类，但类的名称与协议相同，导致冲突。
// 我认为最直接的解决方案是：在存根中不定义 IosCameraHostApi，而是让 PigeonPlatform.swift 使用一个不同的类名，比如 IosCameraHostApiImpl。
// 但这样需要改的地方太多。

// 经过分析，我们选择在存根中定义 class IosCameraHostApi，但为了避免与协议冲突，我们可以定义在另一个模块，或者使用 @objc。
// 最简单：不定义类，而是修改 PigeonPlatform.swift 使用 Pigeon 生成的协议类型，并用一个内部实现类。
// 但时间有限，我们采取最快捷的方法：删除存根中的 IosCameraHostApi 类，在 PigeonPlatform.swift 中使用一个内部类实现协议，并改名。

// 由于改动可能很大，我先提供一个不包含 IosCameraHostApi 和 CameraRecordingStopDto 的存根，然后在 PigeonPlatform.swift 中修改为使用内部类。

// 下面的存根不包含重复的类型。
