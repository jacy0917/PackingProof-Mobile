package app.packingproof.mobile

internal data class CameraGlPoint(
    val x: Float,
    val y: Float,
)

internal data class LiveWatermarkFrameKey(
    val epochSecond: Long,
    val trackingNumber: String,
)

internal data class LiveWatermarkCacheDecision(
    val current: LiveWatermarkFrameKey,
    val next: LiveWatermarkFrameKey,
    val changed: Boolean,
)

/** Decides when the current/next-second watermark textures need regeneration. */
internal class LiveWatermarkTextureCachePolicy {
    private var lastCurrent: LiveWatermarkFrameKey? = null

    fun update(
        frameTimeMs: Long,
        trackingNumber: String,
    ): LiveWatermarkCacheDecision {
        val current = LiveWatermarkFrameKey(
            epochSecond = Math.floorDiv(frameTimeMs, 1_000L),
            trackingNumber = trackingNumber,
        )
        val decision = LiveWatermarkCacheDecision(
            current = current,
            next = current.copy(epochSecond = current.epochSecond + 1L),
            changed = current != lastCurrent,
        )
        lastCurrent = current
        return decision
    }

    fun reset() {
        lastCurrent = null
    }
}

internal enum class LiveWatermarkSegmentDisposition {
    COMPLETED,
    FAILED_PARTIAL,
}

/** Sticky fail-open state: a watermark error never makes the underlying recording unusable. */
internal class LiveWatermarkSegmentState {
    private var renderedFrameCount = 0L
    private var watermarkFailed = false

    @Synchronized
    fun markWatermarkRendered() {
        renderedFrameCount++
    }

    @Synchronized
    fun markWatermarkFailure() {
        watermarkFailed = true
    }

    @Synchronized
    fun disposition(): LiveWatermarkSegmentDisposition =
        if (renderedFrameCount > 0L && !watermarkFailed) {
            LiveWatermarkSegmentDisposition.COMPLETED
        } else {
            LiveWatermarkSegmentDisposition.FAILED_PARTIAL
        }

    @Synchronized
    fun reset() {
        renderedFrameCount = 0L
        watermarkFailed = false
    }
}

internal enum class CameraSurfacePipeline {
    GL_COMPOSITOR,
    DIRECT,
}

internal data class CameraSurfaceTopology(
    val cameraUsesFrameSurface: Boolean,
    val cameraUsesPreviewSurface: Boolean,
    val cameraUsesEncoderSurface: Boolean,
    val cameraUsesAnalysisSurface: Boolean,
    val compositorEncoderEnabled: Boolean,
) {
    val cameraSurfaceCount: Int
        get() = listOf(
            cameraUsesFrameSurface,
            cameraUsesPreviewSurface,
            cameraUsesEncoderSurface,
            cameraUsesAnalysisSurface,
        ).count { it }
}

/** Pure Surface topology shared by regular sessions, fallbacks, and capability probes. */
internal object CameraSurfaceTopologyPolicy {
    fun create(
        pipeline: CameraSurfacePipeline,
        includePreview: Boolean,
        includeEncoder: Boolean,
        includeAnalysis: Boolean,
    ): CameraSurfaceTopology = when (pipeline) {
        CameraSurfacePipeline.GL_COMPOSITOR -> CameraSurfaceTopology(
            cameraUsesFrameSurface = includePreview || includeEncoder,
            cameraUsesPreviewSurface = false,
            cameraUsesEncoderSurface = false,
            cameraUsesAnalysisSurface = includeAnalysis,
            compositorEncoderEnabled = includeEncoder,
        )
        CameraSurfacePipeline.DIRECT -> CameraSurfaceTopology(
            cameraUsesFrameSurface = false,
            cameraUsesPreviewSurface = includePreview,
            cameraUsesEncoderSurface = includeEncoder,
            cameraUsesAnalysisSurface = includeAnalysis,
            compositorEncoderEnabled = false,
        )
    }
}

internal object CameraSurfaceLifecyclePolicy {
    fun shouldRebuildCompositor(
        pipeline: CameraSurfacePipeline,
        compositorReady: Boolean,
        videoSizeChanged: Boolean,
        encoderSurfaceChanged: Boolean,
    ): Boolean = pipeline == CameraSurfacePipeline.GL_COMPOSITOR &&
        (!compositorReady || videoSizeChanged || encoderSurfaceChanged)

    fun failureFallback(current: CameraSurfacePipeline): CameraSurfacePipeline =
        if (current == CameraSurfacePipeline.GL_COMPOSITOR) {
            CameraSurfacePipeline.DIRECT
        } else {
            current
        }
}

internal data class LiveWatermarkQuad(
    val topLeft: CameraGlPoint,
    val topRight: CameraGlPoint,
    val bottomLeft: CameraGlPoint,
    val bottomRight: CameraGlPoint,
)

/** Maps a top-centered final-video watermark back into the encoder's raw frame coordinates. */
internal object LiveWatermarkQuadPolicy {
    private const val TOP_FRACTION = 0.04f

    fun create(
        videoWidth: Int,
        videoHeight: Int,
        bitmapWidth: Int,
        bitmapHeight: Int,
        recordingOrientation: String,
    ): LiveWatermarkQuad {
        require(videoWidth > 0 && videoHeight > 0)
        require(bitmapWidth > 0 && bitmapHeight > 0)
        val rotated = recordingOrientation == "landscapeLeft" ||
            recordingOrientation == "landscapeRight"
        val outputWidth = if (rotated) videoHeight else videoWidth
        val outputHeight = if (rotated) videoWidth else videoHeight
        val width = bitmapWidth.coerceAtMost(outputWidth).toFloat()
        val height = bitmapHeight.coerceAtMost(outputHeight).toFloat()
        val left = ((outputWidth - width) / 2f).coerceAtLeast(0f)
        val top = (outputHeight * TOP_FRACTION).coerceIn(0f, outputHeight - height)

        fun inverse(x: Float, y: Float): CameraGlPoint = when (recordingOrientation) {
            "landscapeLeft" -> CameraGlPoint(y, videoHeight - x)
            "landscapeRight" -> CameraGlPoint(videoWidth - y, x)
            else -> CameraGlPoint(x, y)
        }
        return LiveWatermarkQuad(
            topLeft = inverse(left, top),
            topRight = inverse(left + width, top),
            bottomLeft = inverse(left, top + height),
            bottomRight = inverse(left + width, top + height),
        )
    }

    fun outputHeight(videoWidth: Int, videoHeight: Int, recordingOrientation: String): Int =
        if (recordingOrientation == "landscapeLeft" ||
            recordingOrientation == "landscapeRight"
        ) {
            videoWidth
        } else {
            videoHeight
        }
}
