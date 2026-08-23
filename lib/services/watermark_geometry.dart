import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import '../models/recording_orientation.dart';

const double portraitWatermarkTopFraction = 0.10;
const double landscapeWatermarkTopFraction = 0.04;

double watermarkTopFractionFor(RecordingOrientation orientation) =>
    orientation == RecordingOrientation.portrait
    ? portraitWatermarkTopFraction
    : landscapeWatermarkTopFraction;

/// 以录像变换为唯一真相的水印几何结果。
class WatermarkGeometry {
  const WatermarkGeometry({
    required this.sourceOffset,
    required this.sourceSize,
    required this.previewQuarterTurns,
    required this.outputRect,
  });

  final Offset sourceOffset;
  final Size sourceSize;
  final int previewQuarterTurns;
  final Rect outputRect;
}

class WatermarkPreviewMetrics {
  const WatermarkPreviewMetrics({
    required this.fontSize,
    required this.strokeWidth,
  });

  final double fontSize;
  final double strokeWidth;
}

WatermarkPreviewMetrics watermarkPreviewMetrics({
  required RecordingOrientation orientation,
  required double viewportWidth,
  required Size sourceVideoSize,
}) {
  if (!viewportWidth.isFinite || viewportWidth <= 0) {
    return const WatermarkPreviewMetrics(fontSize: 0, strokeWidth: 0);
  }
  final Size resolvedSourceVideoSize =
      sourceVideoSize.width.isFinite &&
          sourceVideoSize.height.isFinite &&
          sourceVideoSize.width > 0 &&
          sourceVideoSize.height > 0
      ? sourceVideoSize
      : const Size(1080, 1920);
  final double portraitWidth = math.min(
    resolvedSourceVideoSize.width,
    resolvedSourceVideoSize.height,
  );
  const double outputFontSize = 40;
  final double previewScale = viewportWidth / portraitWidth;
  return WatermarkPreviewMetrics(
    fontSize: outputFontSize * previewScale,
    strokeWidth: outputFontSize * 0.1 * previewScale,
  );
}

WatermarkGeometry watermarkGeometry({
  required RecordingOrientation orientation,
  required Size videoSize,
  required Size watermarkSize,
}) {
  final bool swaps = orientation != RecordingOrientation.portrait;
  final Size output = swaps
      ? Size(videoSize.height, videoSize.width)
      : videoSize;
  final double width = math.min(watermarkSize.width, output.width);
  final double height = math.min(watermarkSize.height, output.height);
  final Rect target = Rect.fromLTWH(
    math.max(0, (output.width - width) / 2),
    math.min(
      output.height * watermarkTopFractionFor(orientation),
      math.max(0, output.height - height),
    ),
    width,
    height,
  );
  final Offset outputTopLeft = target.topLeft;
  final Offset source = switch (orientation) {
    RecordingOrientation.portrait => outputTopLeft,
    RecordingOrientation.landscapeLeft => Offset(
      outputTopLeft.dy,
      videoSize.height - outputTopLeft.dx - width,
    ),
    RecordingOrientation.landscapeRight => Offset(
      videoSize.width - outputTopLeft.dy - height,
      outputTopLeft.dx,
    ),
  };
  return WatermarkGeometry(
    sourceOffset: source,
    sourceSize: Size(width, height),
    previewQuarterTurns: switch (orientation) {
      RecordingOrientation.portrait => 0,
      RecordingOrientation.landscapeLeft => 3,
      RecordingOrientation.landscapeRight => 1,
    },
    outputRect: target,
  );
}
