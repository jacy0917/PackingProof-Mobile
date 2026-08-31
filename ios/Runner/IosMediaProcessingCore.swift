import AVFoundation
import Foundation
import QuartzCore

struct IosVideoExportPolicy {
  let presetName: String
  let optimizeForNetworkUse: Bool
  let appliesRequestedTimeRange: Bool
}

func iosVideoExportPolicy(passthrough: Bool) -> IosVideoExportPolicy {
  IosVideoExportPolicy(
    presetName: passthrough
      ? AVAssetExportPresetPassthrough
      : AVAssetExportPresetHighestQuality,
    optimizeForNetworkUse: passthrough,
    appliesRequestedTimeRange: !passthrough
  )
}

struct IosWatermarkExportRequest {
  let inputPath: String
  let outputPath: String
  let startedAtMs: Int64
  let trackingNumber: String
}

struct IosMediaProcessingCoreError: Error {
  let message: String
  let code: String?

  init(message: String, code: String? = nil) {
    self.message = message
    self.code = code
  }
}

func iosWatermarkErrorIsInterrupted(_ error: Error?) -> Bool {
  guard let error else { return false }
  var pending: [NSError] = [error as NSError]
  var visited = Set<ObjectIdentifier>()
  while let current = pending.popLast() {
    let identity = ObjectIdentifier(current)
    if !visited.insert(identity).inserted { continue }
    if current.domain == AVFoundationErrorDomain,
      current.code == AVError.Code.operationInterrupted.rawValue
    {
      return true
    }
    if let underlying = current.userInfo[NSUnderlyingErrorKey] as? Error {
      pending.append(underlying as NSError)
    }
  }
  return false
}

final class IosMediaProcessingCore {
  private final class WatermarkOperation {
    let output: URL
    let completion: (Result<URL, Error>) -> Void
    var session: AVAssetExportSession?

    init(
      output: URL,
      completion: @escaping (Result<URL, Error>) -> Void
    ) {
      self.output = output
      self.completion = completion
    }
  }

  private let operationLock = NSLock()
  private let processingQueue: DispatchQueue
  private var activeWatermarkOperation: WatermarkOperation?
  private var cancelNextWatermark = false

  init(
    processingQueue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)
  ) {
    self.processingQueue = processingQueue
  }

  func applyWatermark(
    request: IosWatermarkExportRequest,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    let output = URL(fileURLWithPath: request.outputPath)
    operationLock.lock()
    if activeWatermarkOperation != nil {
      operationLock.unlock()
      completion(
        .failure(
          IosMediaProcessingCoreError(
            message: "正在保存上一段录像",
            code: "watermark_busy"
          )
        )
      )
      return
    }
    if cancelNextWatermark {
      cancelNextWatermark = false
      operationLock.unlock()
      try? FileManager.default.removeItem(at: output)
      completion(.failure(Self.cancelledError()))
      return
    }
    let operation = WatermarkOperation(output: output, completion: completion)
    activeWatermarkOperation = operation
    operationLock.unlock()

    processingQueue.async {
      guard self.isActive(operation) else { return }
      do {
        let input = URL(fileURLWithPath: request.inputPath)
        try? FileManager.default.removeItem(at: output)
        let asset = AVAsset(url: input)
        let composition = AVMutableComposition()
        guard
          let sourceVideo = asset.tracks(withMediaType: .video).first,
          let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
          )
        else {
          throw IosMediaProcessingCoreError(message: "无法读取录像视频轨道")
        }
        try compositionVideo.insertTimeRange(
          CMTimeRange(start: .zero, duration: asset.duration),
          of: sourceVideo,
          at: .zero
        )
        compositionVideo.preferredTransform = sourceVideo.preferredTransform

        if let sourceAudio = asset.tracks(withMediaType: .audio).first,
          let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
          )
        {
          try compositionAudio.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: sourceAudio,
            at: .zero
          )
        }

        let renderSize = IosWatermarkLayout.resolvedRenderSize(
          naturalSize: sourceVideo.naturalSize,
          preferredTransform: sourceVideo.preferredTransform
        )
        let fontSize = iosWatermarkFontSize(forOutputSize: renderSize)
        let timeline = IosWatermarkTimeline(
          startedAtMs: request.startedAtMs,
          trackingNumber: request.trackingNumber
        )
        let firstText = IosWatermarkStyle.attributedText(
          timeline.text(at: 0),
          fontSize: fontSize
        )
        let textBounds = firstText.boundingRect(
          with: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
          ),
          options: [.usesLineFragmentOrigin, .usesFontLeading],
          context: nil
        )
        let layout = IosWatermarkLayout.make(
          naturalSize: sourceVideo.naturalSize,
          preferredTransform: sourceVideo.preferredTransform,
          textSize: CGSize(
            width: textBounds.width.rounded(.up) + 24,
            height: textBounds.height.rounded(.up) + 24
          )
        )
        let width = layout.renderSize.width
        let height = layout.renderSize.height
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: width, height: height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
          start: .zero,
          duration: asset.duration
        )
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(
          assetTrack: compositionVideo
        )
        layerInstruction.setTransform(
          sourceVideo.preferredTransform,
          at: .zero
        )
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        let text = IosWatermarkStyle.textLayer(
          text: firstText,
          frame: layout.textFrame
        )
        let duration = asset.duration.seconds.isFinite
          ? max(0, asset.duration.seconds)
          : 0
        let keyframeSeconds = timeline.keyframeSeconds(duration: duration)
        if duration > 0, keyframeSeconds.count > 1 {
          let values = keyframeSeconds.map {
            IosWatermarkStyle.attributedText(
              timeline.text(at: $0),
              fontSize: fontSize
            )
          }
          let keyTimes = keyframeSeconds.map {
            NSNumber(value: min(1, $0 / duration))
          }
          IosWatermarkStyle.addTextAnimation(
            to: text,
            values: values,
            keyTimes: keyTimes,
            duration: duration
          )
        }
        parentLayer.addSublayer(text)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
          postProcessingAsVideoLayer: videoLayer,
          in: parentLayer
        )

        guard self.isActive(operation) else { return }

        guard
          let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
          )
        else {
          throw IosMediaProcessingCoreError(message: "无法创建水印导出会话")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        self.operationLock.lock()
        guard self.activeWatermarkOperation === operation else {
          self.operationLock.unlock()
          session.cancelExport()
          self.removeOutputUnlessReused(by: operation)
          return
        }
        operation.session = session
        session.exportAsynchronously {
          switch session.status {
          case .completed:
            do {
              let attributes = try FileManager.default.attributesOfItem(
                atPath: output.path
              )
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
              let outputAsset = AVAsset(url: output)
              let duration = outputAsset.duration.seconds
              guard fileSize > 0,
                !outputAsset.tracks(withMediaType: .video).isEmpty,
                duration.isFinite,
                duration > 0
              else {
                throw IosMediaProcessingCoreError(
                  message: "水印成片校验失败，原片已保留"
                )
              }
              self.finish(operation, result: .success(output))
            } catch {
              self.finish(operation, result: .failure(error))
            }
          case .failed:
            self.finish(
              operation,
              result:
              .failure(
                session.error
                  ?? IosMediaProcessingCoreError(message: "水印视频生成失败")
              )
            )
          case .cancelled:
            self.finish(
              operation,
              result:
              .failure(
                IosMediaProcessingCoreError(
                  message: "水印导出被系统中断，原片已保留",
                  code: "watermark_interrupted"
                )
              )
            )
          default:
            self.finish(
              operation,
              result: .failure(
                IosMediaProcessingCoreError(message: "水印视频生成失败")
              )
            )
          }
        }
        self.operationLock.unlock()
      } catch {
        self.finish(operation, result: .failure(error))
      }
    }
  }

  func cancelWatermark() {
    operationLock.lock()
    guard let operation = activeWatermarkOperation else {
      cancelNextWatermark = true
      operationLock.unlock()
      return
    }
    activeWatermarkOperation = nil
    let session = operation.session
    operationLock.unlock()

    session?.cancelExport()
    removeOutputUnlessReused(by: operation)
    operation.completion(.failure(Self.cancelledError()))
  }

  private func isActive(_ operation: WatermarkOperation) -> Bool {
    operationLock.lock()
    defer { operationLock.unlock() }
    return activeWatermarkOperation === operation
  }

  private func finish(
    _ operation: WatermarkOperation,
    result: Result<URL, Error>
  ) {
    operationLock.lock()
    guard activeWatermarkOperation === operation else {
      operationLock.unlock()
      removeOutputUnlessReused(by: operation)
      return
    }
    activeWatermarkOperation = nil
    operationLock.unlock()
    if case .failure = result {
      removeOutputUnlessReused(by: operation)
    }
    operation.completion(result)
  }

  private func removeOutputUnlessReused(by operation: WatermarkOperation) {
    operationLock.lock()
    let reused = activeWatermarkOperation?.output == operation.output
    if !reused {
      try? FileManager.default.removeItem(at: operation.output)
    }
    operationLock.unlock()
  }

  private static func cancelledError() -> IosMediaProcessingCoreError {
    IosMediaProcessingCoreError(
      message: "录像水印生成已取消",
      code: "watermark_cancelled"
    )
  }
}
