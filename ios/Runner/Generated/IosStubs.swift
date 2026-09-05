import Foundation

// ⭐ 临时 stub：补充 Pigeon 缺失的类型
// 这些定义只为了让编译通过，实际运行时如果调用了会崩溃

enum IosCameraVideoAppendPolicy {
    case appendWhenReady(_ callback: () -> Void)
}

enum IosAudioSampleEnergyProbe {
    static func normalizedPeak(in sampleBuffer: Any) -> Float? {
        return nil
    }
}

enum IosBarcodeVisionFallbackPolicy {
    static func shouldSchedule(_ callback: @escaping () -> Void) -> Bool {
        return false
    }
}

enum IosCameraRecordingLifecycle {
    enum Rejection {
        case busy
        case alreadyStarted
        case notStarted
        case unknown
    }
}

// 其他可能缺失的类型
extension IosCameraPlatform {
    var firstWrittenFrameTiming: FirstWrittenFrameTiming {
        return FirstWrittenFrameTiming()
    }
}

class FirstWrittenFrameTiming {
    func recordWrittenFrameIfNeeded() {}
}
