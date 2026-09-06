func stopWork(
    completion: @escaping (Result<CameraRecordingStopDto, Error>) -> Void
) {
    let timing = IosCameraOperationTiming(operation: "stop")
    let signpostID = OSSignpostID(log: Self.performanceLog)
    os_signpost(.begin, log: Self.performanceLog, name: "CameraRecordingStop", signpostID: signpostID)
    
    sessionQueue.async { [weak self] in
        guard let self = self, !self.isDisposed else {
            if let self = self {
                self.finishPerformanceOperation(timing, signpostID: signpostID, signpostName: "CameraRecordingStop", succeeded: false)
            } else {
                Self.finishDetachedPerformanceOperation(timing, signpostID: signpostID, signpostName: "CameraRecordingStop", succeeded: false)
            }
            completion(.failure(pigeonError("摄像头已经关闭")))
            return
        }
        
        // ⭐ 正确调用 begin，传入 completion 闭包
        self.recordingLifecycle.begin(
            IosCameraRecordingLifecycle.Operation.stop,
            onCancelled: { [weak self] in
                if let self = self {
                    self.finishPerformanceOperation(timing, signpostID: signpostID, signpostName: "CameraRecordingStop", succeeded: false)
                } else {
                    Self.finishDetachedPerformanceOperation(timing, signpostID: signpostID, signpostName: "CameraRecordingStop", succeeded: false)
                }
                completion(.failure(pigeonError("操作被取消")))
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let request):
                    // 成功获得生命周期请求，继续停止录像
                    self.recordingActivityState.setActive(false, owner: self.recordingActivityOwner)
                    self.finishWriter(timing: timing) { writerResult in
                        switch writerResult {
                        case .success(let stopDto):
                            request.complete()
                            self.finishPerformanceOperation(timing, signpostID: signpostID, signpostName: "CameraRecordingStop", succeeded: true)
                            completion(.success(stopDto))
                        case .failure(let error):
                            request.cancel()
                            self.finishPerformanceOperation(timing, signpostID: signpostID, signpostName: "CameraRecordingStop", succeeded: false)
                            completion(.failure(error))
                        }
                    }
                case .failure(let rejection):
                    // 生命周期拒绝
                    self.finishPerformanceOperation(timing, signpostID: signpostID, signpostName: "CameraRecordingStop", succeeded: false)
                    completion(.failure(self.recordingRequestError(rejection, for: IosCameraRecordingLifecycle.Operation.stop)))
                }
            }
        )
    }
}
