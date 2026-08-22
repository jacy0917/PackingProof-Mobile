import Foundation
import QuartzCore
import UIKit

private let iosWatermarkTopFraction: CGFloat = 0.04

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
    topFraction: CGFloat = iosWatermarkTopFraction
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
          renderSize.height - renderSize.height * topFraction - height
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
        max(0, outputSize.height * iosWatermarkTopFraction),
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
}

/// 每秒只排版并栅格化一次水印，同时缓存可见像素的写入位置；其余帧不再扫描透明区域。
/// 位图先绘制黑色粗字，再绘制白色填充，白色会盖住描边的内半圈。
final class IosLiveWatermarkRenderer {
  private let formatter: DateFormatter
  private let watermarkQueue = DispatchQueue(label: "packingproof.camera.watermark")
  private let planLock = NSLock()
  private var generation: Int64 = 0
  private var configuration: IosLiveWatermarkPlanConfiguration?
  private var plans: [Int64: IosLiveWatermarkPlan] = [:]
  private var scheduledSeconds: Set<Int64> = []
  private var planFailure: IosLiveWatermarkError?
  private var lastAppliedPlanSecond: Int64?

  var lastRasterPixelCount: Int {
    planLock.lock()
    defer { planLock.unlock() }
    return plans.values.max(by: { $0.second < $1.second })?.rasterPixelCount ?? 0
  }

  var lastBlendPixelCount: Int {
    planLock.lock()
    defer { planLock.unlock() }
    return plans.values.max(by: { $0.second < $1.second })?.blendPixels.count ?? 0
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
    generation += 1
    let currentGeneration = generation
    configuration = newConfiguration
    plans.removeAll(keepingCapacity: true)
    scheduledSeconds = prefetchNextSecond ? [second, second + 1] : [second]
    planFailure = nil
    lastAppliedPlanSecond = nil
    planLock.unlock()

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
      watermarkQueue.async { [weak self] in
        self?.buildAndPublish(
          second: second + 1,
          generation: currentGeneration,
          configuration: newConfiguration
        )
      }
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
    generation += 1
    let currentGeneration = generation
    configuration = newConfiguration
    plans.removeAll(keepingCapacity: true)
    scheduledSeconds = [second, second + 1]
    planFailure = nil
    lastAppliedPlanSecond = nil
    planLock.unlock()

    watermarkQueue.async { [weak self] in
      guard let self else {
        completion(.failure(IosLiveWatermarkError.planNotReady))
        return
      }
      do {
        let firstPlan = try self.makePlan(
          second: second,
          generation: currentGeneration,
          configuration: newConfiguration
        )
        guard self.publish(firstPlan) else {
          completion(.failure(IosLiveWatermarkError.planNotReady))
          return
        }
        completion(.success(()))
        self.buildAndPublish(
          second: second + 1,
          generation: currentGeneration,
          configuration: newConfiguration
        )
      } catch {
        completion(.failure(error))
      }
    }
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
    var work: [(Int64, Int64, IosLiveWatermarkPlanConfiguration)] = []
    planLock.lock()
    if configuration == currentConfiguration {
      failure = planFailure
      plan = plans[second]
      if plan == nil {
        for candidate in plans.values where candidate.second <= second {
          if plan == nil || candidate.second > (plan?.second ?? Int64.min) {
            plan = candidate
          }
        }
      }
      if let plan {
        lastAppliedPlanSecond = plan.second
      }
      if failure == nil {
        let currentGeneration = generation
        for requestedSecond in [second, second + 1]
          where plans[requestedSecond] == nil && !scheduledSeconds.contains(requestedSecond)
        {
          scheduledSeconds.insert(requestedSecond)
          work.append((requestedSecond, currentGeneration, currentConfiguration))
        }
      }
    }
    planLock.unlock()

    for item in work {
      watermarkQueue.async { [weak self] in
        self?.buildAndPublish(
          second: item.0,
          generation: item.1,
          configuration: item.2
        )
      }
    }
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
    generation += 1
    configuration = nil
    plans.removeAll(keepingCapacity: false)
    scheduledSeconds.removeAll(keepingCapacity: false)
    planFailure = nil
    lastAppliedPlanSecond = nil
    planLock.unlock()
  }

  private func makePlan(
    second: Int64,
    generation: Int64,
    configuration: IosLiveWatermarkPlanConfiguration
  ) throws -> IosLiveWatermarkPlan {
    dispatchPrecondition(condition: .onQueue(watermarkQueue))
    let date = Date(timeIntervalSince1970: Double(second))
    let raster = try makeRaster(
      text: watermarkText(date: date, trackingNumber: configuration.trackingNumber),
      outputSize: configuration.outputSize
    )
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

  private func buildAndPublish(
    second: Int64,
    generation: Int64,
    configuration: IosLiveWatermarkPlanConfiguration
  ) {
    do {
      let plan = try makePlan(
        second: second,
        generation: generation,
        configuration: configuration
      )
      publish(plan)
    } catch {
      planLock.lock()
      if self.generation == generation, self.configuration == configuration {
        planFailure = error as? IosLiveWatermarkError ?? .rasterizationFailed
        scheduledSeconds.remove(second)
      }
      planLock.unlock()
    }
  }

  @discardableResult
  private func publish(_ plan: IosLiveWatermarkPlan) -> Bool {
    planLock.lock()
    defer { planLock.unlock() }
    guard generation == plan.generation, configuration == plan.configuration else {
      return false
    }
    plans[plan.second] = plan
    scheduledSeconds.remove(plan.second)
    plans = plans.filter { $0.key >= plan.second - 1 }
    return true
  }

  func waitForPendingPlansForTesting() {
    watermarkQueue.sync {}
  }

  var preparedSecondsForTesting: [Int64] {
    planLock.lock()
    defer { planLock.unlock() }
    return plans.keys.sorted()
  }

  var lastAppliedPlanSecondForTesting: Int64? {
    planLock.lock()
    defer { planLock.unlock() }
    return lastAppliedPlanSecond
  }

  private func watermarkText(date: Date, trackingNumber: String) -> String {
    let timestamp = formatter.string(from: date)
    return trackingNumber.isEmpty ? timestamp : "\(timestamp)\n\(trackingNumber)"
  }

  private func makeRaster(
    text: String,
    outputSize: CGSize
  ) throws -> IosLiveWatermarkRaster {
    let fontSize = max(35, min(61, outputSize.height * 0.032))
    let font = UIFont.boldSystemFont(ofSize: fontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.minimumLineHeight = fontSize * 1.25
    paragraph.maximumLineHeight = fontSize * 1.25
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
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: width, height: height),
      format: format
    )
    let image = renderer.image { _ in
      let rect = CGRect(
        x: padding,
        y: padding,
        width: CGFloat(width) - padding * 2,
        height: CGFloat(height) - padding * 2
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
      width: width,
      height: height
    )
    return IosLiveWatermarkRaster(width: width, height: height, bgra: pixels)
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
