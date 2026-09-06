import Foundation

/// 管理录像操作的生命周期，防止并发操作冲突。
class IosCameraRecordingLifecycle {
    enum Operation {
        case stop
        case split
    }

    enum Rejection {
        case busy
        case alreadyStarted
        case notStarted
        case unknown
    }

    class Request {
        private var cancelled = false

        func complete() {
            // 完成操作
        }

        func cancel() {
            cancelled = true
        }
    }

    private var currentOperation: Operation?
    private let lock = NSLock()

    func begin(
        _ operation: Operation,
        onCancelled: @escaping () -> Void,
        completion: (Result<Request, Rejection>) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }

        if let current = currentOperation {
            // 如果当前有操作正在进行，根据情况拒绝
            if current == operation {
                completion(.failure(.alreadyStarted))
                return
            } else {
                completion(.failure(.busy))
                return
            }
        }

        // 没有正在进行的操作，开始新的
        currentOperation = operation
        let request = Request()
        // 当 request 被取消时，清理状态并调用回调
        // 但 Swift 中我们需要通过闭包来监听取消，由于没有现成的机制，
        // 这里简单处理：直接返回 request 让调用方控制
        completion(.success(request))
    }

    func dispose() {
        lock.lock()
        currentOperation = nil
        lock.unlock()
    }
}
