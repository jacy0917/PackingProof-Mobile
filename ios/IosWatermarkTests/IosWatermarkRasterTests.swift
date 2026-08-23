import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
import UIKit
import XCTest

final class IosWatermarkRasterTests: XCTestCase {
  func testPortraitAndLandscapeUseTheSameFontSize() {
    XCTAssertEqual(
      iosWatermarkFontSize(forOutputSize: CGSize(width: 1080, height: 1920)),
      44
    )
    XCTAssertEqual(
      iosWatermarkFontSize(forOutputSize: CGSize(width: 1920, height: 1080)),
      44
    )
  }

  func testPlanReadinessErrorsRemainRetryable() {
    XCTAssertTrue(
      iosLiveWatermarkErrorIsTransient(IosLiveWatermarkError.planNotReady)
    )
    XCTAssertTrue(
      iosLiveWatermarkErrorIsTransient(
        IosLiveWatermarkError.planExpired(
          requestedSecond: 12,
          availableSecond: 10
        )
      )
    )
    XCTAssertFalse(
      iosLiveWatermarkErrorIsTransient(IosLiveWatermarkError.rasterizationFailed)
    )
  }

  func testHostPolicyMaintainsAndRecoversWatermarkDuringSplitFinalization() {
    XCTAssertTrue(
      IosLiveWatermarkHostPolicy.canMaintainPreview(
        writerActive: false,
        preservingSplit: true
      )
    )
    XCTAssertFalse(
      IosLiveWatermarkHostPolicy.preparationFailureIsFatal(
        IosLiveWatermarkError.planNotReady
      )
    )
    XCTAssertFalse(
      IosLiveWatermarkHostPolicy.preparationFailureIsFatal(
        IosLiveWatermarkError.planExpired(
          requestedSecond: 12,
          availableSecond: 10
        )
      )
    )
    XCTAssertFalse(
      IosLiveWatermarkHostPolicy.shouldPublishPreviewFrame(
        watermarkRequired: true,
        transientPreparationFailure: true
      )
    )
    XCTAssertTrue(
      IosLiveWatermarkHostPolicy.shouldPublishPreviewFrame(
        watermarkRequired: true,
        transientPreparationFailure: false
      )
    )
  }

  func testHostPolicyClearsPreservedWatermarkOnlyAfterSplitFailure() {
    XCTAssertTrue(
      IosLiveWatermarkHostPolicy.shouldClearPreservedPreview(
        writerActive: false,
        preservingSplit: true
      )
    )
    XCTAssertFalse(
      IosLiveWatermarkHostPolicy.shouldClearPreservedPreview(
        writerActive: true,
        preservingSplit: true
      )
    )
    XCTAssertFalse(
      IosLiveWatermarkHostPolicy.shouldClearPreservedPreview(
        writerActive: false,
        preservingSplit: false
      )
    )
  }

  func testAttributedTextUsesFixedPreviewLineHeight() throws {
    let fontSize: CGFloat = 40
    let text = IosWatermarkStyle.attributedText(
      "2026/08/21 12:34:56\nTRACK-001",
      fontSize: fontSize
    )
    let attributes = text.attributes(at: 0, effectiveRange: nil)
    let paragraphStyle = try XCTUnwrap(
      attributes[.paragraphStyle] as? NSParagraphStyle
    )
    let font = try XCTUnwrap(attributes[.font] as? UIFont)

    XCTAssertEqual(paragraphStyle.minimumLineHeight, fontSize * 1.25)
    XCTAssertEqual(paragraphStyle.maximumLineHeight, fontSize * 1.25)
    XCTAssertEqual(font.pointSize, fontSize)
    XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    XCTAssertEqual(attributes[.strokeWidth] as? Int, -10)
  }

  func testVideoTextLayerUsesFinalPixelScale() {
    let layer = IosWatermarkStyle.textLayer(
      text: IosWatermarkStyle.attributedText("watermark", fontSize: 35),
      frame: CGRect(x: 0, y: 0, width: 240, height: 60)
    )

    XCTAssertEqual(IosWatermarkStyle.videoContentsScale, 1)
    XCTAssertEqual(layer.contentsScale, 1)
  }

  func testInterruptedClassificationFindsNestedAvFoundationError() {
    let interrupted = NSError(
      domain: AVFoundationErrorDomain,
      code: AVError.Code.operationInterrupted.rawValue
    )
    let wrapper = NSError(
      domain: "PackingProof.WatermarkTests",
      code: 1,
      userInfo: [NSUnderlyingErrorKey: interrupted]
    )

    XCTAssertTrue(iosWatermarkErrorIsInterrupted(wrapper))
    XCTAssertFalse(
      iosWatermarkErrorIsInterrupted(
        NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue)
      )
    )
  }

  func testRecordingTransformKeepsPortraitBuffersAndMapsSemanticDirections() {
    let cases: [(name: String, radians: CGFloat, displayedSize: CGSize)] = [
      ("portrait", 0, CGSize(width: 1080, height: 1920)),
      ("landscapeLeft", .pi / 2, CGSize(width: 1920, height: 1080)),
      ("landscapeRight", -.pi / 2, CGSize(width: 1920, height: 1080)),
    ]

    for fixture in cases {
      let transform = iosRecordingTransform(for: fixture.name)
      let displayedBounds = CGRect(
        origin: .zero,
        size: CGSize(width: 1080, height: 1920)
      ).applying(transform).standardized
      XCTAssertEqual(transform.a, cos(fixture.radians), accuracy: 0.0001)
      XCTAssertEqual(transform.b, sin(fixture.radians), accuracy: 0.0001)
      XCTAssertEqual(transform.c, -sin(fixture.radians), accuracy: 0.0001)
      XCTAssertEqual(transform.d, cos(fixture.radians), accuracy: 0.0001)
      XCTAssertEqual(displayedBounds.origin, .zero, fixture.name)
      XCTAssertEqual(displayedBounds.size, fixture.displayedSize, fixture.name)
      XCTAssertEqual(
        IosWatermarkLayout.resolvedRenderSize(
          naturalSize: CGSize(width: 1080, height: 1920),
          preferredTransform: transform
        ),
        fixture.displayedSize,
        fixture.name
      )
    }
  }

  func testRecordingCaptureMirrorsOnlyFrontCameraPixels() {
    XCTAssertFalse(iosRecordingCaptureShouldMirror(frontCamera: false))
    XCTAssertTrue(iosRecordingCaptureShouldMirror(frontCamera: true))
  }

  func testLiveRasterizerKeepsAsymmetricGlyphUpright() throws {
    let width = 96
    let height = 112
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: width, height: height),
      format: format
    ).image { _ in
      ("L" as NSString).draw(
        at: CGPoint(x: 8, y: 2),
        withAttributes: [
          .font: UIFont.boldSystemFont(ofSize: 88),
          .foregroundColor: UIColor.white,
        ]
      )
    }
    let cgImage = try XCTUnwrap(image.cgImage)
    let pixels = try IosLiveWatermarkRasterizer.bgraPixels(
      from: cgImage,
      width: width,
      height: height
    )

    let upperAlpha = alphaTotal(
      pixels,
      width: width,
      rows: 0..<(height / 3)
    )
    let lowerAlpha = alphaTotal(
      pixels,
      width: width,
      rows: (height * 2 / 3)..<height
    )
    XCTAssertGreaterThan(
      lowerAlpha,
      upperAlpha,
      "L 的底边应留在图像下方，不能在 BGRA 转换时上下翻转"
    )
  }

  func testLiveWatermarkCoordinatesRoundTripWithoutMirroringInAllOrientations() {
    let sourceWidth = 1080
    let sourceHeight = 1920
    let asymmetricOutputPixels = [
      (x: 73, y: 101),
      (x: 319, y: 227),
      (x: 811, y: 1_503),
    ]

    for orientation in ["portrait", "landscapeLeft", "landscapeRight"] {
      let outputSize = IosLiveWatermarkGeometry.outputSize(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        orientation: orientation
      )
      for output in asymmetricOutputPixels where
        output.x < Int(outputSize.width) && output.y < Int(outputSize.height)
      {
        let source = IosLiveWatermarkGeometry.sourcePixel(
          outputX: output.x,
          outputY: output.y,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          orientation: orientation
        )
        let roundTrip: (x: Int, y: Int) = switch orientation {
        case "landscapeLeft":
          (sourceHeight - 1 - source.y, source.x)
        case "landscapeRight":
          (source.y, sourceWidth - 1 - source.x)
        default:
          (source.x, source.y)
        }
        XCTAssertEqual(roundTrip.x, output.x, orientation)
        XCTAssertEqual(roundTrip.y, output.y, orientation)
      }
    }
  }

  func testLiveRendererPlacesSamePixelsAtOutputTopCenterInAllOrientations()
    throws
  {
    let sourceWidth = 1080
    let sourceHeight = 1920
    let date = Date(timeIntervalSince1970: 1_776_768_896)
    for orientation in ["portrait", "landscapeLeft", "landscapeRight"] {
      var pixelBuffer: CVPixelBuffer?
      XCTAssertEqual(
        CVPixelBufferCreate(
          kCFAllocatorDefault,
          sourceWidth,
          sourceHeight,
          kCVPixelFormatType_32BGRA,
          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
          &pixelBuffer
        ),
        kCVReturnSuccess
      )
      let buffer = try XCTUnwrap(pixelBuffer)
      fill(buffer, blue: 80, green: 96, red: 112)
      let renderer = IosLiveWatermarkRenderer(
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
      try renderer.prepare(
        to: buffer,
        orientation: orientation,
        trackingNumber: "TRACK-001",
        date: date
      )
      try renderer.apply(
        to: buffer,
        orientation: orientation,
        trackingNumber: "TRACK-001",
        date: date
      )
      let bounds = try XCTUnwrap(
        changedOutputBounds(
          buffer,
          background: (80, 96, 112),
          orientation: orientation
        )
      )
      let output = IosLiveWatermarkGeometry.outputSize(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        orientation: orientation
      )
      XCTAssertEqual(bounds.midX, output.width / 2, accuracy: 2, orientation)
      let topFraction = iosWatermarkTopFraction(forOutputSize: output)
      XCTAssertGreaterThanOrEqual(bounds.minY, output.height * topFraction, orientation)
      XCTAssertLessThanOrEqual(
        bounds.minY,
        output.height * topFraction + 26,
        orientation
      )
      XCTAssertGreaterThan(bounds.brightPixels, 40, orientation)
      XCTAssertGreaterThan(bounds.darkPixels, 40, orientation)
    }
  }

  func testSplitLiveRasterMatchesLegacyCompositeInAllOrientations() throws {
    let sourceWidth = 1080
    let sourceHeight = 1920
    let date = Date(timeIntervalSince1970: 1_776_768_896)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
    let timestamp = formatter.string(from: date)
    let trackingNumbers = [
      "",
      "TRACK-001",
      "中文面单-123",
      String(repeating: "LONG-", count: 35),
      "ROW1\nROW2",
    ]

    for trackingNumber in trackingNumbers {
      let legacyText = trackingNumber.isEmpty
        ? timestamp
        : "\(timestamp)\n\(trackingNumber)"
      for orientation in ["portrait", "landscapeLeft", "landscapeRight"] {
        let expected = try makePixelBuffer(width: sourceWidth, height: sourceHeight)
        let actual = try makePixelBuffer(width: sourceWidth, height: sourceHeight)
        for buffer in [expected, actual] {
          fill(buffer, blue: 80, green: 96, red: 112)
        }
        try applyLegacyLiveWatermark(
          legacyText,
          to: expected,
          orientation: orientation
        )
        let renderer = IosLiveWatermarkRenderer(
          timeZone: TimeZone(secondsFromGMT: 0)!
        )
        try renderer.prepare(
          to: actual,
          orientation: orientation,
          trackingNumber: trackingNumber,
          date: date
        )
        try renderer.apply(
          to: actual,
          orientation: orientation,
          trackingNumber: trackingNumber,
          date: date
        )

        let pixelDifference = differingPixelCount(
          bytes(of: actual),
          bytes(of: expected)
        )
        XCTAssertLessThanOrEqual(
          pixelDifference,
          102,
          "\(orientation): \(trackingNumber)"
        )
      }
    }
  }

  func testLiveWatermarkRasterOriginUsesOrientationSpecificTopMarginAndCenters() {
    for output in [
      CGSize(width: 1080, height: 1920),
      CGSize(width: 1920, height: 1080),
    ] {
      let raster = CGSize(width: 420, height: 120)
      let origin = IosLiveWatermarkGeometry.outputOrigin(
        outputSize: output,
        rasterSize: raster
      )
      XCTAssertEqual(origin.x + raster.width / 2, output.width / 2)
      XCTAssertEqual(
        origin.y,
        output.height * iosWatermarkTopFraction(forOutputSize: output)
      )
    }
  }

  func testLiveRendererReusesEquivalentOpaquePixelPlan() throws {
    let date = Date(timeIntervalSince1970: 1_776_768_896)
    let first = try makePixelBuffer(width: 1080, height: 1920)
    let second = try makePixelBuffer(width: 1080, height: 1920)
    fill(first, blue: 80, green: 96, red: 112)
    fill(second, blue: 80, green: 96, red: 112)
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    try renderer.prepare(
      to: first,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: date
    )
    try renderer.apply(
      to: first,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: date
    )
    let firstBytes = bytes(of: first)
    try renderer.apply(
      to: second,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: date
    )

    XCTAssertEqual(bytes(of: second), firstBytes)
    XCTAssertGreaterThan(renderer.lastBlendPixelCount, 0)
    XCTAssertLessThan(
      renderer.lastBlendPixelCount,
      renderer.lastRasterPixelCount / 2,
      "帧内应只处理有可见 alpha 的水印像素"
    )
  }

  func testLiveRendererPublishesOneCompleteRasterPerSecond() throws {
    let second: Int64 = 1_776_768_896
    let buffer = try makePixelBuffer(width: 1080, height: 1920)
    fill(buffer, blue: 80, green: 96, red: 112)
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    try renderer.prepare(
      to: buffer,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: Date(timeIntervalSince1970: Double(second))
    )
    renderer.waitForPendingPlansForTesting()

    for offset in 0..<60 {
      try renderer.apply(
        to: buffer,
        orientation: "portrait",
        trackingNumber: "TRACK-001",
        date: Date(timeIntervalSince1970: Double(second + Int64(offset)))
      )
      renderer.waitForPendingPlansForTesting()
    }

    XCTAssertEqual(renderer.rasterizationCountForTesting, 61)
    XCTAssertLessThanOrEqual(renderer.preparedSecondsForTesting.count, 2)
  }

  func testLiveRendererRasterizesBoundedPlansForEmptyTrackingNumber() throws {
    let date = Date(timeIntervalSince1970: 1_776_768_896)
    let buffer = try makePixelBuffer(width: 1080, height: 1920)
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    try renderer.prepare(
      to: buffer,
      orientation: "portrait",
      trackingNumber: "",
      date: date
    )
    renderer.waitForPendingPlansForTesting()

    XCTAssertEqual(renderer.rasterizationCountForTesting, 2)
  }

  func testLiveRendererReusesPreviousPlanUntilNextSecondIsReady() throws {
    let second: Int64 = 1_776_768_896
    let date = Date(timeIntervalSince1970: Double(second))
    let first = try makePixelBuffer(width: 1080, height: 1920)
    let boundary = try makePixelBuffer(width: 1080, height: 1920)
    let ready = try makePixelBuffer(width: 1080, height: 1920)
    for buffer in [first, boundary, ready] {
      fill(buffer, blue: 80, green: 96, red: 112)
    }
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    try renderer.prepare(
      to: first,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: date,
      prefetchNextSecond: false
    )

    try renderer.apply(
      to: boundary,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: date.addingTimeInterval(1)
    )
    XCTAssertEqual(renderer.lastAppliedPlanSecondForTesting, second)
    XCTAssertNotNil(
      changedOutputBounds(
        boundary,
        background: (80, 96, 112),
        orientation: "portrait"
      ),
      "下一秒计划未就绪时也不能漏水印"
    )

    renderer.waitForPendingPlansForTesting()
    try renderer.apply(
      to: ready,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: date.addingTimeInterval(1)
    )
    XCTAssertEqual(renderer.lastAppliedPlanSecondForTesting, second + 1)
  }

  func testLiveRendererRejectsPlanOlderThanOneSecond() throws {
    let second: Int64 = 1_776_768_896
    let buffer = try makePixelBuffer(width: 1080, height: 1920)
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    try renderer.prepare(
      to: buffer,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: Date(timeIntervalSince1970: Double(second)),
      prefetchNextSecond: false
    )

    XCTAssertThrowsError(
      try renderer.apply(
        to: buffer,
        orientation: "portrait",
        trackingNumber: "TRACK-001",
        date: Date(timeIntervalSince1970: Double(second + 2))
      )
    ) { error in
      guard case let IosLiveWatermarkError.planExpired(
        requestedSecond,
        availableSecond
      ) = error else {
        return XCTFail("超过一秒必须返回明确的计划过期错误：\(error)")
      }
      XCTAssertEqual(requestedSecond, second + 2)
      XCTAssertEqual(availableSecond, second)
    }
    XCTAssertNil(renderer.lastAppliedPlanSecondForTesting)
  }

  func testLiveRendererFrozenClockKeepsCurrentAndNextPlansBounded() throws {
    let second: Int64 = 1_776_768_896
    let buffer = try makePixelBuffer(width: 1080, height: 1920)
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    try renderer.prepare(
      to: buffer,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: Date(timeIntervalSince1970: Double(second))
    )
    renderer.waitForPendingPlansForTesting()

    for _ in 0..<120 {
      try renderer.apply(
        to: buffer,
        orientation: "portrait",
        trackingNumber: "TRACK-001",
        date: Date(timeIntervalSince1970: Double(second))
      )
    }

    XCTAssertEqual(renderer.preparedSecondsForTesting, [second, second + 1])
    XCTAssertEqual(renderer.rasterizationCountForTesting, 2)
    XCTAssertEqual(renderer.pendingPlanRequestCountForTesting, 0)
    XCTAssertEqual(renderer.scheduledPlanCountForTesting, 0)
  }

  func testLiveRendererBusyQueueDoesNotReuseOldPlanOrAccumulateRequests()
    throws
  {
    let second: Int64 = 1_776_768_896
    let buffer = try makePixelBuffer(width: 1080, height: 1920)
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    try renderer.prepare(
      to: buffer,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: Date(timeIntervalSince1970: Double(second)),
      prefetchNextSecond: false
    )
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    renderer.blockPlanQueueForTesting(started: started, release: release)
    XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
    var queueReleased = false
    defer {
      if !queueReleased { release.signal() }
    }

    try renderer.apply(
      to: buffer,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: Date(timeIntervalSince1970: Double(second + 1))
    )
    XCTAssertThrowsError(
      try renderer.apply(
        to: buffer,
        orientation: "portrait",
        trackingNumber: "TRACK-001",
        date: Date(timeIntervalSince1970: Double(second + 2))
      )
    ) { error in
      guard case IosLiveWatermarkError.planExpired = error else {
        return XCTFail("繁忙超过容差后必须失败而不是继续复用旧时间：\(error)")
      }
    }
    XCTAssertLessThanOrEqual(renderer.pendingPlanRequestCountForTesting, 2)
    XCTAssertLessThanOrEqual(renderer.scheduledPlanCountForTesting, 2)
    release.signal()
    queueReleased = true
    renderer.waitForPendingPlansForTesting()
    XCTAssertLessThanOrEqual(renderer.preparedSecondsForTesting.count, 3)
  }

  func testLiveRendererClockRollbackDropsFuturePlansAndRebuildsBoundedWindow()
    throws
  {
    let second: Int64 = 1_776_768_896
    let rollbackSecond = second - 30
    let buffer = try makePixelBuffer(width: 1080, height: 1920)
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    try renderer.prepare(
      to: buffer,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: Date(timeIntervalSince1970: Double(second))
    )
    renderer.waitForPendingPlansForTesting()
    XCTAssertEqual(renderer.preparedSecondsForTesting, [second, second + 1])

    XCTAssertThrowsError(
      try renderer.apply(
        to: buffer,
        orientation: "portrait",
        trackingNumber: "TRACK-001",
        date: Date(timeIntervalSince1970: Double(rollbackSecond))
      )
    ) { error in
      guard case IosLiveWatermarkError.planNotReady = error else {
        return XCTFail("时钟回拨不能套用未来水印计划：\(error)")
      }
    }
    XCTAssertTrue(renderer.preparedSecondsForTesting.isEmpty)
    XCTAssertLessThanOrEqual(renderer.pendingPlanRequestCountForTesting, 2)
    XCTAssertLessThanOrEqual(renderer.scheduledPlanCountForTesting, 2)

    renderer.waitForPendingPlansForTesting()
    XCTAssertEqual(
      renderer.preparedSecondsForTesting,
      [rollbackSecond, rollbackSecond + 1]
    )
  }

  func testLiveRendererResetRejectsOlderGenerationPlans() throws {
    let second: Int64 = 1_776_768_896
    let first = try makePixelBuffer(width: 1080, height: 1920)
    let secondBuffer = try makePixelBuffer(width: 1080, height: 1920)
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    try renderer.prepare(
      to: first,
      orientation: "landscapeLeft",
      trackingNumber: "OLD",
      date: Date(timeIntervalSince1970: Double(second))
    )
    renderer.reset()
    renderer.waitForPendingPlansForTesting()
    XCTAssertTrue(renderer.preparedSecondsForTesting.isEmpty)
    XCTAssertThrowsError(
      try renderer.apply(
        to: first,
        orientation: "landscapeLeft",
        trackingNumber: "OLD",
        date: Date(timeIntervalSince1970: Double(second + 1))
      )
    )

    try renderer.prepare(
      to: secondBuffer,
      orientation: "landscapeRight",
      trackingNumber: "NEW",
      date: Date(timeIntervalSince1970: Double(second + 10))
    )
    renderer.waitForPendingPlansForTesting()
    XCTAssertEqual(renderer.preparedSecondsForTesting, [second + 10, second + 11])
  }

  func testLiveRendererCanPrepareFirstPlanAsynchronouslyWithoutPermanentFailure()
    throws
  {
    let date = Date(timeIntervalSince1970: 1_776_768_896)
    let buffer = try makePixelBuffer(width: 1080, height: 1920)
    fill(buffer, blue: 80, green: 96, red: 112)
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    XCTAssertThrowsError(
      try renderer.apply(
        to: buffer,
        orientation: "portrait",
        trackingNumber: "TRACK-001",
        date: date
      )
    ) { error in
      guard case IosLiveWatermarkError.planNotReady = error else {
        return XCTFail("首份计划未就绪必须返回可重试状态")
      }
    }

    let completed = expectation(description: "异步首份水印计划完成")
    var result: Result<Void, Error>?
    renderer.prepareAsynchronously(
      to: buffer,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: date
    ) {
      result = $0
      completed.fulfill()
    }
    wait(for: [completed], timeout: 5)
    try result?.get()
    try renderer.apply(
      to: buffer,
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: date
    )
    XCTAssertEqual(
      renderer.lastAppliedPlanSecondForTesting,
      Int64(date.timeIntervalSince1970)
    )
  }

  func testLiveRendererAsyncPreparationKeepsOnlyLatestGenerationBounded() throws {
    let second: Int64 = 1_776_768_896
    let buffer = try makePixelBuffer(width: 1080, height: 1920)
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let latestCompleted = expectation(description: "最新水印计划完成")

    for offset in 0..<20 {
      renderer.prepareAsynchronously(
        to: buffer,
        orientation: "portrait",
        trackingNumber: "TRACK-\(offset)",
        date: Date(timeIntervalSince1970: Double(second + Int64(offset)))
      ) { result in
        if offset == 19 {
          if case .failure(let error) = result {
            XCTFail("最新水印计划不应失败：\(error)")
          }
          latestCompleted.fulfill()
        }
      }
      XCTAssertLessThanOrEqual(renderer.pendingPlanRequestCountForTesting, 2)
      XCTAssertLessThanOrEqual(renderer.scheduledPlanCountForTesting, 2)
    }

    wait(for: [latestCompleted], timeout: 5)
    renderer.waitForPendingPlansForTesting()
    XCTAssertEqual(renderer.preparedSecondsForTesting, [second + 19, second + 20])
  }

  func testLiveRendererPreparedPlanSupportsConcurrentFrameBuffers() throws {
    let date = Date(timeIntervalSince1970: 1_776_768_896)
    let buffers = try (0..<8).map { _ in
      try makePixelBuffer(width: 1080, height: 1920)
    }
    for buffer in buffers {
      fill(buffer, blue: 80, green: 96, red: 112)
    }
    let renderer = IosLiveWatermarkRenderer(
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    try renderer.prepare(
      to: buffers[0],
      orientation: "portrait",
      trackingNumber: "TRACK-001",
      date: date
    )
    renderer.waitForPendingPlansForTesting()
    let errorLock = NSLock()
    var errors: [Error] = []

    DispatchQueue.concurrentPerform(iterations: buffers.count) { index in
      do {
        try renderer.apply(
          to: buffers[index],
          orientation: "portrait",
          trackingNumber: "TRACK-001",
          date: date
        )
      } catch {
        errorLock.lock()
        errors.append(error)
        errorLock.unlock()
      }
    }

    XCTAssertTrue(errors.isEmpty)
    for buffer in buffers {
      XCTAssertNotNil(
        changedOutputBounds(
          buffer,
          background: (80, 96, 112),
          orientation: "portrait"
        )
      )
    }
  }

  func testNativeRasterKeepsChangingWatermarkUncroppedInAllOrientations()
    throws
  {
    let sourceSize = CGSize(width: 1080, height: 1920)
    let fixtures: [(name: String, transform: CGAffineTransform, expected: CGSize)] = [
      ("portrait", iosRecordingTransform(for: "portrait"), sourceSize),
      (
        "landscape-left",
        iosRecordingTransform(for: "landscapeLeft"),
        CGSize(width: 1920, height: 1080)
      ),
      (
        "landscape-right",
        iosRecordingTransform(for: "landscapeRight"),
        CGSize(width: 1920, height: 1080)
      ),
    ]
    let timeline = IosWatermarkTimeline(
      startedAtMs: 1_767_268_800_000,
      trackingNumber: "TRACK-001",
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    for fixture in fixtures {
      let fontSize = iosWatermarkFontSize(forOutputSize: fixture.expected)
      let firstText = IosWatermarkStyle.attributedText(
        timeline.text(at: 0),
        fontSize: fontSize
      )
      let layout = IosWatermarkLayout.make(
        naturalSize: sourceSize,
        preferredTransform: fixture.transform,
        textSize: measuredSize(of: firstText)
      )
      XCTAssertEqual(layout.renderSize, fixture.expected, fixture.name)
      XCTAssertEqual(
        layout.renderSize.height - layout.textFrame.maxY,
        fixture.expected.height
          * iosWatermarkTopFraction(forOutputSize: fixture.expected),
        accuracy: 0.0001,
        fixture.name
      )

      let firstPixels = try render(
        text: firstText,
        layout: layout,
        fixture: fixture.name
      )
      let secondPixels = try render(
        text: IosWatermarkStyle.attributedText(
          timeline.text(at: 1.25),
          fontSize: fontSize
        ),
        layout: layout,
        fixture: fixture.name
      )
      let firstWatermark = try XCTUnwrap(
        firstPixels.watermarkBounds(),
        "\(fixture.name) 首帧没有渲染水印像素"
      )
      let secondWatermark = try XCTUnwrap(
        secondPixels.watermarkBounds(),
        "\(fixture.name) 第二个时间点没有渲染水印像素"
      )
      assertWatermarkIsUncropped(
        firstWatermark,
        imageSize: fixture.expected,
        fixture: fixture.name
      )
      assertWatermarkIsUncropped(
        secondWatermark,
        imageSize: fixture.expected,
        fixture: fixture.name
      )
      XCTAssertGreaterThan(
        firstPixels.changedWatermarkPixels(comparedWith: secondPixels),
        20,
        "\(fixture.name) 水印在不同时刻没有产生可见变化"
      )
    }
  }

  private func measuredSize(of text: NSAttributedString) -> CGSize {
    let bounds = text.boundingRect(
      with: CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      ),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return CGSize(
      width: bounds.width.rounded(.up) + 24,
      height: bounds.height.rounded(.up) + 24
    )
  }

  private func render(
    text: NSAttributedString,
    layout: IosWatermarkLayout,
    fixture: String
  ) throws -> PixelSnapshot {
    let width = Int(layout.renderSize.width)
    let height = Int(layout.renderSize.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else {
        return false
      }
      let parent = CALayer()
      parent.frame = CGRect(x: 0, y: 0, width: width, height: height)
      parent.backgroundColor = CGColor(
        red: 32 / 255,
        green: 96 / 255,
        blue: 160 / 255,
        alpha: 1
      )
      parent.addSublayer(
        IosWatermarkStyle.textLayer(
          text: text,
          frame: layout.textFrame
        )
      )
      parent.render(in: context)
      return true
    }
    guard rendered else {
      throw WatermarkRasterTestError.cannotRender(fixture)
    }
    return PixelSnapshot(width: width, height: height, rgba: pixels)
  }

  private func assertWatermarkIsUncropped(
    _ watermark: PixelSnapshot.WatermarkBounds,
    imageSize: CGSize,
    fixture: String
  ) {
    XCTAssertGreaterThan(watermark.brightPixels, 40, fixture)
    XCTAssertGreaterThan(watermark.darkPixels, 40, fixture)
    XCTAssertGreaterThanOrEqual(watermark.bounds.minX, 8, fixture)
    XCTAssertGreaterThanOrEqual(watermark.bounds.minY, 8, fixture)
    XCTAssertLessThanOrEqual(watermark.bounds.maxX, imageSize.width - 8, fixture)
    XCTAssertLessThanOrEqual(watermark.bounds.maxY, imageSize.height - 8, fixture)
  }

  private func fill(
    _ pixelBuffer: CVPixelBuffer,
    blue: UInt8,
    green: UInt8,
    red: UInt8
  ) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(
      to: UInt8.self
    )
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * bytesPerRow + x * 4
        bytes[offset] = blue
        bytes[offset + 1] = green
        bytes[offset + 2] = red
        bytes[offset + 3] = 255
      }
    }
  }

  private func applyLegacyLiveWatermark(
    _ text: String,
    to pixelBuffer: CVPixelBuffer,
    orientation: String
  ) throws {
    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    let outputSize = IosLiveWatermarkGeometry.outputSize(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      orientation: orientation
    )
    let fontSize = iosWatermarkFontSize(forOutputSize: outputSize)
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
    let padding = ceil(fontSize * 0.1 + 3)
    let width = max(1, Int(ceil(measurement.width + padding * 2)))
    let height = max(1, Int(ceil(measurement.height + padding * 2)))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: width, height: height),
      format: format
    ).image { _ in
      let rect = CGRect(
        x: padding,
        y: padding,
        width: CGFloat(width) - padding * 2,
        height: CGFloat(height) - padding * 2
      )
      NSAttributedString(
        string: text,
        attributes: [
          .font: font,
          .foregroundColor: UIColor.black,
          .strokeColor: UIColor.black,
          .strokeWidth: -10,
          .paragraphStyle: paragraph,
        ]
      ).draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
      NSAttributedString(
        string: text,
        attributes: [
          .font: font,
          .foregroundColor: UIColor.white,
          .paragraphStyle: paragraph,
        ]
      ).draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
    }
    let raster = try IosLiveWatermarkRasterizer.bgraPixels(
      from: try XCTUnwrap(image.cgImage),
      width: width,
      height: height
    )
    let origin = IosLiveWatermarkGeometry.outputOrigin(
      outputSize: outputSize,
      rasterSize: CGSize(width: width, height: height)
    )
    let originX = Int(origin.x.rounded(.down))
    let originY = Int(origin.y.rounded(.down))
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let destination = CVPixelBufferGetBaseAddress(pixelBuffer)!
      .assumingMemoryBound(to: UInt8.self)
    raster.withUnsafeBytes { raw in
      let source = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
      for rasterY in 0..<height {
        for rasterX in 0..<width {
          let sourceOffset = (rasterY * width + rasterX) * 4
          let alpha = source[sourceOffset + 3]
          guard alpha > 0 else { continue }
          let mapped = IosLiveWatermarkGeometry.sourcePixel(
            outputX: originX + rasterX,
            outputY: originY + rasterY,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            orientation: orientation
          )
          guard mapped.x >= 0, mapped.x < sourceWidth,
                mapped.y >= 0, mapped.y < sourceHeight else { continue }
          let offset = mapped.y * bytesPerRow + mapped.x * 4
          let inverseAlpha = 255 - Int(alpha)
          for channel in 0..<3 {
            destination[offset + channel] = UInt8(min(
              255,
              Int(source[sourceOffset + channel]) +
                (Int(destination[offset + channel]) * inverseAlpha + 127) / 255
            ))
          }
          destination[offset + 3] = 255
        }
      }
    }
  }

  private func differingPixelCount(_ first: [UInt8], _ second: [UInt8]) -> Int {
    precondition(first.count == second.count)
    var count = 0
    for offset in stride(from: 0, to: first.count, by: 4) {
      if first[offset] != second[offset] ||
          first[offset + 1] != second[offset + 1] ||
          first[offset + 2] != second[offset + 2] ||
          first[offset + 3] != second[offset + 3] {
        count += 1
      }
    }
    return count
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &pixelBuffer
      ),
      kCVReturnSuccess
    )
    return try XCTUnwrap(pixelBuffer)
  }

  private func bytes(of pixelBuffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) *
      CVPixelBufferGetHeight(pixelBuffer)
    let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!
    return Array(UnsafeRawBufferPointer(start: baseAddress, count: byteCount))
  }

  private func alphaTotal(
    _ bgra: [UInt8],
    width: Int,
    rows: Range<Int>
  ) -> Int {
    var total = 0
    for y in rows {
      for x in 0..<width {
        total += Int(bgra[(y * width + x) * 4 + 3])
      }
    }
    return total
  }

  private func changedOutputBounds(
    _ pixelBuffer: CVPixelBuffer,
    background: (UInt8, UInt8, UInt8),
    orientation: String
  ) -> (midX: CGFloat, minY: CGFloat, brightPixels: Int, darkPixels: Int)? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(
      to: UInt8.self
    )
    var minX = Int.max
    var maxX = Int.min
    var minY = Int.max
    var brightPixels = 0
    var darkPixels = 0
    for sourceY in 0..<sourceHeight {
      for sourceX in 0..<sourceWidth {
        let offset = sourceY * bytesPerRow + sourceX * 4
        let blue = bytes[offset]
        let green = bytes[offset + 1]
        let red = bytes[offset + 2]
        guard (blue, green, red) != background else { continue }
        let output: (x: Int, y: Int) = switch orientation {
        case "landscapeLeft":
          (sourceHeight - 1 - sourceY, sourceX)
        case "landscapeRight":
          (sourceY, sourceWidth - 1 - sourceX)
        default:
          (sourceX, sourceY)
        }
        minX = min(minX, output.x)
        maxX = max(maxX, output.x)
        minY = min(minY, output.y)
        let luminance = (Int(red) + Int(green) + Int(blue)) / 3
        brightPixels += luminance > 180 ? 1 : 0
        darkPixels += luminance < 45 ? 1 : 0
      }
    }
    guard minX <= maxX else { return nil }
    return (
      midX: CGFloat(minX + maxX) / 2,
      minY: CGFloat(minY),
      brightPixels: brightPixels,
      darkPixels: darkPixels
    )
  }
}

final class IosMediaProcessingCoreTests: XCTestCase {
  func testInvalidInputKeepsFailureMessageAndRemovesStaleOutput() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("watermark-core-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let output = root.appendingPathComponent("output.mp4")
    try Data("stale-output".utf8).write(to: output)
    let completed = expectation(description: "watermark core completed")
    var received: Result<URL, Error>?

    IosMediaProcessingCore().applyWatermark(
      request: IosWatermarkExportRequest(
        inputPath: root.appendingPathComponent("missing.mp4").path,
        outputPath: output.path,
        startedAtMs: 0,
        trackingNumber: ""
      )
    ) { result in
      received = result
      completed.fulfill()
    }

    wait(for: [completed], timeout: 5)
    guard case .failure(let error as IosMediaProcessingCoreError) = received else {
      return XCTFail("无效输入应返回水印 Core 错误")
    }
    XCTAssertEqual(error.message, "无法读取录像视频轨道")
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }
}

private struct PixelSnapshot {
  struct WatermarkBounds {
    let bounds: CGRect
    let brightPixels: Int
    let darkPixels: Int
  }

  let width: Int
  let height: Int
  let rgba: [UInt8]

  func watermarkBounds() -> WatermarkBounds? {
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    var brightPixels = 0
    var darkPixels = 0
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        let bright = isBright(at: offset)
        let dark = isDark(at: offset)
        guard bright || dark else { continue }
        brightPixels += bright ? 1 : 0
        darkPixels += dark ? 1 : 0
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return WatermarkBounds(
      bounds: CGRect(
        x: CGFloat(minX),
        y: CGFloat(minY),
        width: CGFloat(maxX - minX + 1),
        height: CGFloat(maxY - minY + 1)
      ),
      brightPixels: brightPixels,
      darkPixels: darkPixels
    )
  }

  func changedWatermarkPixels(comparedWith other: PixelSnapshot) -> Int {
    guard width == other.width, height == other.height else { return 0 }
    var changed = 0
    for offset in stride(from: 0, to: rgba.count, by: 4) {
      let currentIsWatermark = isBright(at: offset) || isDark(at: offset)
      let otherIsWatermark = other.isBright(at: offset) || other.isDark(at: offset)
      guard currentIsWatermark || otherIsWatermark else { continue }
      let largestDifference = max(
        abs(Int(rgba[offset]) - Int(other.rgba[offset])),
        max(
          abs(Int(rgba[offset + 1]) - Int(other.rgba[offset + 1])),
          abs(Int(rgba[offset + 2]) - Int(other.rgba[offset + 2]))
        )
      )
      if largestDifference >= 60 { changed += 1 }
    }
    return changed
  }

  private func isBright(at offset: Int) -> Bool {
    rgba[offset] >= 210 && rgba[offset + 1] >= 210 && rgba[offset + 2] >= 210
  }

  private func isDark(at offset: Int) -> Bool {
    rgba[offset] <= 45 && rgba[offset + 1] <= 45 && rgba[offset + 2] <= 45
  }
}

private enum WatermarkRasterTestError: Error {
  case cannotRender(String)
}
