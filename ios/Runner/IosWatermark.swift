import Foundation
import QuartzCore
import UIKit

private let iosPortraitWatermarkTopFraction: CGFloat = 0.10
private let iosLandscapeWatermarkTopFraction: CGFloat = 0.04

func iosWatermarkTopFraction(forOutputSize outputSize: CGSize) -> CGFloat {
  outputSize.height > outputSize.width
    ? iosPortraitWatermarkTopFraction
    : iosLandscapeWatermarkTopFraction
}

func iosWatermarkFontSize(forOutputSize outputSize: CGSize) -> CGFloat {
  let maximum: CGFloat = outputSize.height > outputSize.width ? 44 : 61
  return max(35, min(maximum, outputSize.height * 0.032))
}

/// 保持固定 1080x1920 竖屏采集缓冲不变，仅用 MP4 轨道元数据表达最终录像方向。
func iosRecordingTransform(for recordingOrientation: String) -> CGAffineTransform {
  switch recordingOrientation {
  case "landscapeLeft":
    return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1920, ty: 0)
  case "landscapeRight":
    return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1080)
  default:
    return .identity
  }
}

/// 固定相机画面语义：后摄不镜像，前摄保持自拍预览。水印在采集回调收到
/// 已完成镜像的像素缓冲后才烧录，因此不应跟随前摄再做一次镜像。
func iosRecordingCaptureShouldMirror(frontCamera: Bool) -> Bool {
  frontCamera
}

struct IosWatermarkTimeline {
  let startedAtMs: Int64
  let trackingNumber: String
  private let formatter: DateFormatter

  init(
    startedAtMs: Int64,
    trackingNumber: String,
    timeZone: TimeZone = .current
  ) {
    self.startedAtMs = startedAtMs
    self.trackingNumber = trackingNumber
    formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
  }

  func text(at compositionSeconds: Double) -> String {
    let elapsedMilliseconds = Int64(max(0, compositionSeconds) * 1_000)
    let date = Date(
      timeIntervalSince1970: Double(startedAtMs + elapsedMilliseconds) / 1_000
    )
    let timestamp = formatter.string(from: date)
    return trackingNumber.isEmpty
      ? timestamp
      : "\(timestamp)\n\(trackingNumber)"
  }

  func keyframeSeconds(duration: Double) -> [Double] {
    guard duration.isFinite, duration > 0 else { return [0] }
    let lastWholeSecond = Int(duration.rounded(.down))
    var seconds = (0...lastWholeSecond).map(Double.init)
    if seconds.last != duration {
      seconds.append(duration)
    }
    return seconds
  }
}

struct IosWatermarkLayout {
  let renderSize: CGSize
  let textFrame: CGRect

  static func make(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform,
    textSize: CGSize,
    topFraction: CGFloat? = nil
  ) -> IosWatermarkLayout {
    let renderSize = resolvedRenderSize(
      naturalSize: naturalSize,
      preferredTransform: preferredTransform
    )
    let availableWidth = max(1, renderSize.width)
    let availableHeight = max(1, renderSize.height)
    let width = min(textSize.width, availableWidth)
    let height = min(textSize.height, availableHeight)
    return IosWatermarkLayout(
      renderSize: renderSize,
      textFrame: CGRect(
        x: (renderSize.width - width) / 2,
        y: max(
          0,
          renderSize.height
            - renderSize.height
              * (topFraction ?? iosWatermarkTopFraction(forOutputSize: renderSize))
            - height
        ),
        width: width,
        height: height
      )
    )
  }

  static func resolvedRenderSize(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform
  ) -> CGSize {
    let transformedBounds = CGRect(origin: .zero, size: naturalSize)
      .applying(preferredTransform)
      .standardized
    return CGSize(
      width: transformedBounds.width.rounded(.up),
      height: transformedBounds.height.rounded(.up)
    )
  }
}

struct IosWatermarkStyle {
  /// Core Animation 水印图层使用最终视频像素坐标，禁止跟随设备屏幕倍率二次缩放。
  static let videoContentsScale: CGFloat = 1

  static func attributedText(
    _ value: String,
    fontSize: CGFloat
  ) -> NSAttributedString {
    let paragraphStyle = NSMutableParagraphStyle()
    let lineHeight = fontSize * 1.25
    paragraphStyle.minimumLineHeight = lineHeight
    paragraphStyle.maximumLineHeight = lineHeight
    return NSAttributedString(
      string: value,
      attributes: [
        .font: UIFont.boldSystemFont(ofSize: fontSize),
        .foregroundColor: UIColor.white,
        .strokeColor: UIColor.black,
        .strokeWidth: -10,
        .paragraphStyle: paragraphStyle,
      ]
    )
  }

  static func textLayer(
    text: NSAttributedString,
    frame: CGRect,
    contentsScale: CGFloat = videoContentsScale
  ) -> CATextLayer {
    let layer = CATextLayer()
    layer.string = text
    layer.alignmentMode = .center
    layer.contentsScale = contentsScale
    layer.frame = frame
    return layer
  }
}

enum IosLiveWatermarkError: Error {
  case unsupportedPixelFormat
  case pixelBufferLockFailed(CVReturn)
  case missingBaseAddress
  case rasterizationFailed
  case planNotReady
  case planExpired(requestedSecond: Int64, availableSecond: Int64)
}

func iosLiveWatermarkErrorIsTransient(_ error: Error) -> Bool {
  switch error {
  case IosLiveWatermarkError.planNotReady,
       IosLiveWatermarkError.planExpired:
    return true
  default:
    return false
  }
}

struct IosLiveWatermarkGeometry {
  static func outputSize(
    sourceWidth: Int,
    sourceHeight: Int,
    orientation: String
  ) -> CGSize {
    if orientation == "landscapeLeft" || orientation == "landscapeRight" {
      return CGSize(width: sourceHeight, height: sourceWidth)
    }
    return CGSize(width: sourceWidth, height: sourceHeight)
  }

  static func sourcePixel(
    outputX: Int,
    outputY: Int,
    sourceWidth: Int,
    sourceHeight: Int,
    orientation: String
  ) -> (x: Int, y: Int) {
    switch orientation {
    case "landscapeLeft":
      return (outputY, sourceHeight - 1 - outputX)
    case "landscapeRight":
      return (sourceWidth - 1 - outputY, outputX)
    default:
      return (outputX, outputY)
    }
  }

  static func outputOrigin(outputSize: CGSize, rasterSize: CGSize) -> CGPoint {
    CGPoint(
      x: max(0, (outputSize.width - rasterSize.width) / 2),
      y: min(
        max(
          0,
          outputSize.height * iosWatermarkTopFraction(forOutputSize: outputSize)
        ),
        max(0, outputSize.height - rasterSize.height)
      )
    )
  }
}

private struct IosLiveWatermarkRaster {
  let width: Int
  let height: Int
  let bgra: [UInt8]
}

struct IosLiveWatermarkRasterizer {
  static func bgraPixels(
    from cgImage: CGImage,
    width: Int,
    height: Int
  ) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(
        data: bytes.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
          CGImageAlphaInfo.premultipliedFirst.rawValue
      ) else {
        return false
      }
      // CGImage 与 CVPixelBuffer 的内存行顺序都从首行开始；这里若再套用
      // UIKit 的翻转 CTM，会让开始录像后烧录的文字上下颠倒。
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else {
      throw IosLiveWatermarkError.rasterizationFailed
    }
    return pixels
  }
}

private struct IosLiveWatermarkBlendPixel {
  let destinationOffset: Int
  let blue: UInt8
  let green: UInt8
  let red: UInt8
  let alpha: UInt8
}

private struct IosLiveWatermarkPlanConfiguration: Equatable {
  let orientation: String
  let trackingNumber: String
  let sourceWidth: Int
  let sourceHeight: Int
  let bytesPerRow: Int
  let outputSize: CGSize
}

private struct IosLiveWatermarkPlan {
  let second: Int64
  let generation: Int64
  let configuration: IosLiveWatermarkPlanConfiguration
  let rasterPixelCount: Int
  let blendPixels: [IosLiveWatermarkBlendPixel]

  var blendPixelCount: Int { blendPixels.count }
}

private struct IosLiveWatermarkRasterLayout {
  let width: Int
  let height: Int
  let fontSize: CGFloat
  let padding: CGFloat
}

private struct IosLiveWatermarkPlanRequest {
  let second: Int64
  let generation: Int64
  let configuration: IosLiveWatermarkPlanConfiguration
  let completion: ((Result<Void, Error>) -> Void)?
}

/// 每秒只排版并栅格化一次水印，同时缓存可见像素的写入位置；其余帧不再扫描透明区域。
/// 位图先绘制黑色粗字，再绘制白色填充，白色会盖住描边的内半圈。
final class IosLiveWatermarkRenderer: @unchecked Sendable {
  private let formatter: DateFormatter
  private let watermarkQueue = DispatchQueue(label: "packingproof.camera.watermark")
  private let planLock = NSLock()
  private var generation: Int64 = 0
  private var configuration: IosLiveWatermarkPlanConfiguration?
  private var plans: [Int64: IosLiveWatermarkPlan] = [:]
  private var scheduledSeconds: Set<Int64> = []
  private var pendingRequests: [Int64: IosLiveWatermarkPlanRequest] = [:]
  private var planWorkerActive = false
  private var requestedPlanWindow: ClosedRange<Int64>?
  private var planFailure: IosLiveWatermarkError?
  private var lastAppliedPlanSecond: Int64?
  private var rasterizationCount = 0

  var lastRasterPixelCount: Int {
    planLock.lock()
    defer { planLock.unlock() }
    return plans.values.max(by: { $0.second < $1.second })?.rasterPixelCount ?? 0
  }

  var lastBlendPixelCount: Int {
    planLock.lock()
    defer { planLock.unlock() }
    return plans.values.max(by: { $0.second < $1.second })?.blendPixelCount ?? 0
  }

  init(timeZone: TimeZone = .current) {
    formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
  }

  /// 在 writer 对外可见前同步准备首秒，并在专用队列提前生成下一秒。
  /// 之后 capture 回调只读取已经发布的不可变计划，不执行文字排版或栅格化。
  func prepare(
    to pixelBuffer: CVPixelBuffer,
    orientation: String,
    trackingNumber: String,
    date: Date = Date(),
    prefetchNextSecond: Bool = true
  ) throws {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      throw IosLiveWatermarkError.unsupportedPixelFormat
    }
    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    let outputSize = IosLiveWatermarkGeometry.outputSize(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      orientation: orientation
    )
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let newConfiguration = IosLiveWatermarkPlanConfiguration(
      orientation: orientation,
      trackingNumber: trackingNumber,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      bytesPerRow: bytesPerRow,
      outputSize: outputSize
    )
    let second = Int64(date.timeIntervalSince1970.rounded(.down))
    planLock.lock()
    let cancelledCompletions = pendingRequests.values.compactMap(\.completion)
    generation += 1
    let currentGeneration = generation
    configuration = newConfiguration
    plans.removeAll(keepingCapacity: true)
    scheduledSeconds = [second]
    pendingRequests.removeAll(keepingCapacity: true)
    requestedPlanWindow = (second - 1)...(second + 1)
    planFailure = nil
    lastAppliedPlanSecond = nil
    rasterizationCount = 0
    planLock.unlock()
    cancelledCompletions.forEach { $0(.failure(IosLiveWatermarkError.planNotReady)) }

    let firstPlan = try watermarkQueue.sync {
      try makePlan(
        second: second,
        generation: currentGeneration,
        configuration: newConfiguration
      )
    }
    guard publish(firstPlan) else {
      throw IosLiveWatermarkError.planNotReady
    }
    if prefetchNextSecond {
      enqueuePlanRequests([
        IosLiveWatermarkPlanRequest(
          second: second + 1,
          generation: currentGeneration,
          configuration: newConfiguration,
          completion: nil
        ),
      ])
    }
  }

  /// 极端情况下 writer 启动前还没有预览帧时，由首个采集帧只提交格式信息，
  /// 栅格化仍完全在 watermarkQueue 执行。计划发布前不写入视频，避免保存无水印帧。
  func prepareAsynchronously(
    to pixelBuffer: CVPixelBuffer,
    orientation: String,
    trackingNumber: String,
    date: Date = Date(),
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      completion(.failure(IosLiveWatermarkError.unsupportedPixelFormat))
      return
    }
    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    let newConfiguration = IosLiveWatermarkPlanConfiguration(
      orientation: orientation,
      trackingNumber: trackingNumber,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      outputSize: IosLiveWatermarkGeometry.outputSize(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        orientation: orientation
      )
    )
    let second = Int64(date.timeIntervalSince1970.rounded(.down))
    planLock.lock()
    let cancelledCompletions = pendingRequests.values.compactMap(\.completion)
    generation += 1
    let currentGeneration = generation
    configuration = newConfiguration
    plans.removeAll(keepingCapacity: true)
    scheduledSeconds.removeAll(keepingCapacity: true)
    pendingRequests.removeAll(keepingCapacity: true)
    requestedPlanWindow = (second - 1)...(second + 1)
    planFailure = nil
    lastAppliedPlanSecond = nil
    rasterizationCount = 0
    planLock.unlock()
    cancelledCompletions.forEach { $0(.failure(IosLiveWatermarkError.planNotReady)) }
    enqueuePlanRequests([
      IosLiveWatermarkPlanRequest(
        second: second,
        generation: currentGeneration,
        configuration: newConfiguration,
        completion: completion
      ),
      IosLiveWatermarkPlanRequest(
        second: second + 1,
        generation: currentGeneration,
        configuration: newConfiguration,
        completion: nil
      ),
    ])
  }

  func apply(
    to pixelBuffer: CVPixelBuffer,
    orientation: String,
    trackingNumber: String,
    date: Date = Date()
  ) throws {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      throw IosLiveWatermarkError.unsupportedPixelFormat
    }
    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    let currentConfiguration = IosLiveWatermarkPlanConfiguration(
      orientation: orientation,
      trackingNumber: trackingNumber,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      outputSize: IosLiveWatermarkGeometry.outputSize(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        orientation: orientation
      )
    )
    let second = Int64(date.timeIntervalSince1970.rounded(.down))
    var plan: IosLiveWatermarkPlan?
    var failure: IosLiveWatermarkError?
    var work: [IosLiveWatermarkPlanRequest] = []
    var cancelledCompletions: [((Result<Void, Error>) -> Void)] = []
    planLock.lock()
    if configuration == currentConfiguration {
      let mostRecentPastSecond = plans.keys.filter { $0 < second }.max()
      cancelledCompletions = updateRequestedPlanWindowLocked(
        centeredAt: second
      )
      failure = planFailure
      plan = plans[second]
      if plan == nil, let previousPlan = plans[second - 1] {
        plan = previousPlan
      }
      if plan == nil, failure == nil,
         let staleSecond = mostRecentPastSecond {
        failure = .planExpired(
          requestedSecond: second,
          availableSecond: staleSecond
        )
      }
      if let plan {
        lastAppliedPlanSecond = plan.second
      }
      if failure == nil {
        let currentGeneration = generation
        for requestedSecond in [second, second + 1]
          where plans[requestedSecond] == nil && !scheduledSeconds.contains(requestedSecond)
        {
          work.append(IosLiveWatermarkPlanRequest(
            second: requestedSecond,
            generation: currentGeneration,
            configuration: currentConfiguration,
            completion: nil
          ))
        }
      }
    }
    planLock.unlock()

    cancelledCompletions.forEach {
      $0(.failure(IosLiveWatermarkError.planNotReady))
    }
    enqueuePlanRequests(work)
    if let failure {
      throw failure
    }
    guard let plan else {
      throw IosLiveWatermarkError.planNotReady
    }
    try blend(plan.blendPixels, into: pixelBuffer)
  }

  func reset() {
    planLock.lock()
    let cancelledCompletions = pendingRequests.values.compactMap(\.completion)
    generation += 1
    configuration = nil
    plans.removeAll(keepingCapacity: false)
    scheduledSeconds.removeAll(keepingCapacity: false)
    pendingRequests.removeAll(keepingCapacity: false)
    requestedPlanWindow = nil
    planFailure = nil
    lastAppliedPlanSecond = nil
    rasterizationCount = 0
    planLock.unlock()
    cancelledCompletions.forEach { $0(.failure(IosLiveWatermarkError.planNotReady)) }
  }

  /// 单个后台 worker 只保留最新的当前秒和下一秒，避免设备繁忙时逐秒积压排版任务。
  private func enqueuePlanRequests(_ requests: [IosLiveWatermarkPlanRequest]) {
    guard !requests.isEmpty else { return }
    var cancelledCompletions: [((Result<Void, Error>) -> Void)] = []
    var completedCompletions: [((Result<Void, Error>) -> Void)] = []
    var shouldStartWorker = false
    planLock.lock()
    for request in requests {
      guard generation == request.generation,
            configuration == request.configuration,
            requestedPlanWindow?.contains(request.second) == true else {
        if let completion = request.completion {
          cancelledCompletions.append(completion)
        }
        continue
      }
      if plans[request.second] != nil {
        if let completion = request.completion {
          completedCompletions.append(completion)
        }
        continue
      }
      if scheduledSeconds.contains(request.second) { continue }
      pendingRequests[request.second] = request
      scheduledSeconds.insert(request.second)
    }
    if let newestSecond = pendingRequests.keys.max() {
      let obsoleteSeconds = pendingRequests.keys.filter { $0 < newestSecond - 1 }
      for second in obsoleteSeconds {
        if let completion = pendingRequests.removeValue(forKey: second)?.completion {
          cancelledCompletions.append(completion)
        }
        scheduledSeconds.remove(second)
      }
    }
    if !pendingRequests.isEmpty, !planWorkerActive {
      planWorkerActive = true
      shouldStartWorker = true
    }
    planLock.unlock()
    cancelledCompletions.forEach {
      $0(.failure(IosLiveWatermarkError.planNotReady))
    }
    completedCompletions.forEach { $0(.success(())) }
    if shouldStartWorker {
      watermarkQueue.async { [weak self] in
        self?.drainPendingRequests()
      }
    }
  }

  private func drainPendingRequests() {
    dispatchPrecondition(condition: .onQueue(watermarkQueue))
    while true {
      planLock.lock()
      guard let second = pendingRequests.keys.min(),
            let request = pendingRequests.removeValue(forKey: second) else {
        planWorkerActive = false
        planLock.unlock()
        return
      }
      let isCurrent = generation == request.generation
        && configuration == request.configuration
        && requestedPlanWindow?.contains(request.second) == true
      planLock.unlock()
      guard isCurrent else {
        request.completion?(.failure(IosLiveWatermarkError.planNotReady))
        continue
      }
      do {
        let plan = try makePlan(
          second: request.second,
          generation: request.generation,
          configuration: request.configuration
        )
        if publish(plan) {
          request.completion?(.success(()))
        } else {
          request.completion?(.failure(IosLiveWatermarkError.planNotReady))
        }
      } catch {
        recordPlanFailure(
          error,
          second: request.second,
          generation: request.generation,
          configuration: request.configuration
        )
        request.completion?(.failure(error))
      }
    }
  }

  private func makePlan(
    second: Int64,
    generation: Int64,
    configuration: IosLiveWatermarkPlanConfiguration
  ) throws -> IosLiveWatermarkPlan {
    dispatchPrecondition(condition: .onQueue(watermarkQueue))
    let date = Date(timeIntervalSince1970: Double(second))
    let timestamp = timestampText(date: date)
    let text = configuration.trackingNumber.isEmpty
      ? timestamp
      : "\(timestamp)\n\(configuration.trackingNumber)"
    let layout = makeRasterLayout(
      text: text,
      outputSize: configuration.outputSize
    )
    let raster = try makeRaster(
      text: text,
      layout: layout,
      height: layout.height
    )
    recordRasterization(generation: generation, configuration: configuration) {
      rasterizationCount += 1
    }
    return IosLiveWatermarkPlan(
      second: second,
      generation: generation,
      configuration: configuration,
      rasterPixelCount: raster.width * raster.height,
      blendPixels: makeBlendPixels(
        raster,
        outputSize: configuration.outputSize,
        sourceWidth: configuration.sourceWidth,
        sourceHeight: configuration.sourceHeight,
        bytesPerRow: configuration.bytesPerRow,
        orientation: configuration.orientation
      )
    )
  }

  private func recordRasterization(
    generation: Int64,
    configuration: IosLiveWatermarkPlanConfiguration,
    _ update: () -> Void
  ) {
    planLock.lock()
    if self.generation == generation, self.configuration == configuration {
      update()
    }
    planLock.unlock()
  }

  private func recordPlanFailure(
    _ error: Error,
    second: Int64,
    generation: Int64,
    configuration: IosLiveWatermarkPlanConfiguration
  ) {
    planLock.lock()
    if self.generation == generation,
       self.configuration == configuration,
       requestedPlanWindow?.contains(second) == true {
      planFailure = error as? IosLiveWatermarkError ?? .rasterizationFailed
      scheduledSeconds.remove(second)
    }
    planLock.unlock()
  }

  @discardableResult
  private func publish(_ plan: IosLiveWatermarkPlan) -> Bool {
    planLock.lock()
    defer { planLock.unlock() }
    guard generation == plan.generation,
          configuration == plan.configuration,
          requestedPlanWindow?.contains(plan.second) == true else {
      scheduledSeconds.remove(plan.second)
      return false
    }
    plans[plan.second] = plan
    scheduledSeconds.remove(plan.second)
    if let requestedPlanWindow {
      plans = plans.filter { requestedPlanWindow.contains($0.key) }
    }
    if plans.count > 2 {
      let retainedSeconds = Set(
        plans.keys.sorted(by: >).prefix(2)
      )
      plans = plans.filter { retainedSeconds.contains($0.key) }
    }
    return true
  }

  /// 计划只围绕当前帧保留前一秒、当前秒和下一秒。前一秒仅用于秒边界
  /// 的短暂容错；时钟回拨时会立即丢弃未来缓存和排队任务。
  private func updateRequestedPlanWindowLocked(
    centeredAt second: Int64
  ) -> [((Result<Void, Error>) -> Void)] {
    let window = (second - 1)...(second + 1)
    requestedPlanWindow = window
    plans = plans.filter { window.contains($0.key) }
    var cancelledCompletions: [((Result<Void, Error>) -> Void)] = []
    let obsoleteSeconds = pendingRequests.keys.filter {
      !window.contains($0)
    }
    for pendingSecond in obsoleteSeconds {
      if let completion = pendingRequests.removeValue(
        forKey: pendingSecond
      )?.completion {
        cancelledCompletions.append(completion)
      }
      scheduledSeconds.remove(pendingSecond)
    }
    scheduledSeconds = scheduledSeconds.filter { window.contains($0) }
    return cancelledCompletions
  }

  func blockPlanQueueForTesting(
    started: DispatchSemaphore,
    release: DispatchSemaphore
  ) {
    watermarkQueue.async {
      started.signal()
      release.wait()
    }
  }

  func waitForPendingPlansForTesting() {
    watermarkQueue.sync {}
  }

  var preparedSecondsForTesting: [Int64] {
    planLock.lock()
    defer { planLock.unlock() }
    return plans.keys.sorted()
  }

  var pendingPlanRequestCountForTesting: Int {
    planLock.lock()
    defer { planLock.unlock() }
    return pendingRequests.count
  }

  var scheduledPlanCountForTesting: Int {
    planLock.lock()
    defer { planLock.unlock() }
    return scheduledSeconds.count
  }

  var lastAppliedPlanSecondForTesting: Int64? {
    planLock.lock()
    defer { planLock.unlock() }
    return lastAppliedPlanSecond
  }

  var rasterizationCountForTesting: Int {
    planLock.lock()
    defer { planLock.unlock() }
    return rasterizationCount
  }

  private func timestampText(date: Date) -> String {
    formatter.string(from: date)
  }

  private func watermarkFontSize(outputSize: CGSize) -> CGFloat {
    iosWatermarkFontSize(forOutputSize: outputSize)
  }

  private func makeRasterLayout(
    text: String,
    outputSize: CGSize
  ) -> IosLiveWatermarkRasterLayout {
    let fontSize = watermarkFontSize(outputSize: outputSize)
    let font = UIFont.boldSystemFont(ofSize: fontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let lineHeight = fontSize * 1.25
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    let measurement = NSAttributedString(
      string: text,
      attributes: [.font: font, .paragraphStyle: paragraph]
    ).boundingRect(
      with: CGSize(
        width: max(1, outputSize.width),
        height: CGFloat.greatestFiniteMagnitude
      ),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    let strokeWidth = fontSize * 0.1
    let padding = ceil(strokeWidth + 3)
    let width = max(1, Int(ceil(measurement.width + padding * 2)))
    let height = max(1, Int(ceil(measurement.height + padding * 2)))
    return IosLiveWatermarkRasterLayout(
      width: width,
      height: height,
      fontSize: fontSize,
      padding: padding
    )
  }

  private func makeRaster(
    text: String,
    layout: IosLiveWatermarkRasterLayout,
    height: Int
  ) throws -> IosLiveWatermarkRaster {
    let font = UIFont.boldSystemFont(ofSize: layout.fontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.minimumLineHeight = layout.fontSize * 1.25
    paragraph.maximumLineHeight = layout.fontSize * 1.25
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: layout.width, height: height),
      format: format
    )
    let image = renderer.image { _ in
      let rect = CGRect(
        x: layout.padding,
        y: layout.padding,
        width: CGFloat(layout.width) - layout.padding * 2,
        height: CGFloat(height) - layout.padding * 2
      )
      let outline = NSAttributedString(
        string: text,
        attributes: [
          .font: font,
          .foregroundColor: UIColor.black,
          .strokeColor: UIColor.black,
          .strokeWidth: -10,
          .paragraphStyle: paragraph,
        ]
      )
      outline.draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
      let fill = NSAttributedString(
        string: text,
        attributes: [
          .font: font,
          .foregroundColor: UIColor.white,
          .paragraphStyle: paragraph,
        ]
      )
      fill.draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
    }
    guard let cgImage = image.cgImage else {
      throw IosLiveWatermarkError.rasterizationFailed
    }
    let pixels = try IosLiveWatermarkRasterizer.bgraPixels(
      from: cgImage,
      width: layout.width,
      height: height
    )
    return IosLiveWatermarkRaster(
      width: layout.width,
      height: height,
      bgra: pixels
    )
  }

  private func makeBlendPixels(
    _ raster: IosLiveWatermarkRaster,
    outputSize: CGSize,
    sourceWidth: Int,
    sourceHeight: Int,
    bytesPerRow: Int,
    orientation: String
  ) -> [IosLiveWatermarkBlendPixel] {
    let outputWidth = Int(outputSize.width)
    let outputHeight = Int(outputSize.height)
    let origin = IosLiveWatermarkGeometry.outputOrigin(
      outputSize: outputSize,
      rasterSize: CGSize(width: raster.width, height: raster.height)
    )
    let originX = Int(origin.x.rounded(.down))
    let originY = Int(origin.y.rounded(.down))
    var pixels: [IosLiveWatermarkBlendPixel] = []
    pixels.reserveCapacity(raster.width * raster.height / 2)
    raster.bgra.withUnsafeBytes { sourceBytes in
      guard let source = sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return
      }
      for rasterY in 0..<raster.height {
        let outputY = originY + rasterY
        guard outputY >= 0, outputY < outputHeight else { continue }
        for rasterX in 0..<raster.width {
          let outputX = originX + rasterX
          guard outputX >= 0, outputX < outputWidth else { continue }
          let sourceOffset = (rasterY * raster.width + rasterX) * 4
          let alpha = source[sourceOffset + 3]
          if alpha == 0 { continue }
          let mapped = IosLiveWatermarkGeometry.sourcePixel(
            outputX: outputX,
            outputY: outputY,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            orientation: orientation
          )
          guard mapped.x >= 0, mapped.x < sourceWidth,
                mapped.y >= 0, mapped.y < sourceHeight else {
            continue
          }
          pixels.append(IosLiveWatermarkBlendPixel(
            destinationOffset: mapped.y * bytesPerRow + mapped.x * 4,
            blue: source[sourceOffset],
            green: source[sourceOffset + 1],
            red: source[sourceOffset + 2],
            alpha: alpha
          ))
        }
      }
    }
    return pixels
  }

  private func blend(
    _ pixels: [IosLiveWatermarkBlendPixel],
    into pixelBuffer: CVPixelBuffer
  ) throws {
    let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockResult == kCVReturnSuccess else {
      throw IosLiveWatermarkError.pixelBufferLockFailed(lockResult)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw IosLiveWatermarkError.missingBaseAddress
    }
    let destination = baseAddress.assumingMemoryBound(to: UInt8.self)
    blend(pixels, into: destination)
  }

  private func blend(
    _ pixels: [IosLiveWatermarkBlendPixel],
    into destination: UnsafeMutablePointer<UInt8>
  ) {
    for pixel in pixels {
      let offset = pixel.destinationOffset
      if pixel.alpha == 255 {
        destination[offset] = pixel.blue
        destination[offset + 1] = pixel.green
        destination[offset + 2] = pixel.red
      } else {
        let inverseAlpha = 255 - Int(pixel.alpha)
        destination[offset] = UInt8(min(
          255,
          Int(pixel.blue) + (Int(destination[offset]) * inverseAlpha + 127) / 255
        ))
        destination[offset + 1] = UInt8(min(
          255,
          Int(pixel.green) +
            (Int(destination[offset + 1]) * inverseAlpha + 127) / 255
        ))
        destination[offset + 2] = UInt8(min(
          255,
          Int(pixel.red) +
            (Int(destination[offset + 2]) * inverseAlpha + 127) / 255
        ))
      }
      destination[offset + 3] = 255
    }
  }
}
