package app.packingproof.mobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.OverlaySettings
import androidx.media3.common.util.Clock
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultAssetLoaderFactory
import androidx.media3.transformer.DefaultDecoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.ceil

internal data class WatermarkOverlayPlacement(
    val overlayAnchorX: Float,
    val overlayAnchorY: Float,
    val backgroundAnchorX: Float,
    val backgroundAnchorY: Float,
    val rotationDegrees: Float,
)

internal fun watermarkOverlayPlacement(
    recordingOrientation: String,
    overlayWidth: Int,
    overlayHeight: Int,
): WatermarkOverlayPlacement {
    require(overlayWidth > 0)
    require(overlayHeight > 0)
    val rotatedTopAnchorX = overlayHeight.toFloat() / overlayWidth
    return when (recordingOrientation) {
        "landscapeLeft" -> WatermarkOverlayPlacement(
            -rotatedTopAnchorX,
            0f,
            -0.8f,
            0f,
            -90f,
        )
        "landscapeRight" -> WatermarkOverlayPlacement(
            rotatedTopAnchorX,
            0f,
            0.8f,
            0f,
            90f,
        )
        else -> WatermarkOverlayPlacement(0f, 1f, 0f, 0.8f, 0f)
    }
}

internal fun watermarkTextLines(
    timestamp: String,
    trackingNumber: String,
): List<String> =
    if (trackingNumber.isBlank()) {
        listOf(timestamp)
    } else {
        listOf(timestamp, trackingNumber)
    }

@OptIn(UnstableApi::class)
internal fun watermarkOverlaySettings(
    recordingOrientation: String,
    overlayWidth: Int,
    overlayHeight: Int,
): StaticOverlaySettings {
    val placement = watermarkOverlayPlacement(
        recordingOrientation,
        overlayWidth,
        overlayHeight,
    )
    return StaticOverlaySettings.Builder()
        .setOverlayFrameAnchor(
            placement.overlayAnchorX,
            placement.overlayAnchorY,
        )
        .setBackgroundFrameAnchor(
            placement.backgroundAnchorX,
            placement.backgroundAnchorY,
        )
        .setRotationDegrees(placement.rotationDegrees)
        .build()
}

internal fun renderWatermarkTextBitmap(
    videoHeight: Int,
    lines: List<String>,
    recordingOrientation: String,
): Bitmap {
    require(videoHeight > 0)
    require(lines.isNotEmpty())
    val textSize = watermarkTextSize(videoHeight, recordingOrientation)
    val strokeWidth = (textSize / 10f).coerceAtLeast(3f)
    val padding = strokeWidth + 3f
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        this.textSize = textSize
        textAlign = Paint.Align.CENTER
        strokeJoin = Paint.Join.ROUND
    }
    val fontMetricsHeight = paint.fontMetrics.bottom - paint.fontMetrics.top
    val lineHeight = textSize * 1.25f
    val contentWidth = lines.maxOf { paint.measureText(it) }
    val width = ceil(contentWidth + padding * 2).toDouble().toInt().coerceAtLeast(1)
    val height = ceil(
        fontMetricsHeight + lineHeight * (lines.size - 1) + padding * 2
    ).toDouble().toInt().coerceAtLeast(1)
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    bitmap.density = Bitmap.DENSITY_NONE
    val canvas = Canvas(bitmap)
    val centerX = width / 2f
    var baseline = padding - paint.fontMetrics.top
    for (line in lines) {
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = strokeWidth
        paint.color = Color.BLACK
        canvas.drawText(line, centerX, baseline, paint)
        paint.style = Paint.Style.FILL
        paint.color = Color.WHITE
        canvas.drawText(line, centerX, baseline, paint)
        baseline += lineHeight
    }
    return bitmap
}

internal class ReusableWatermarkBitmap(
    private val videoHeight: Int,
    maximumLines: List<String>,
    private val recordingOrientation: String,
) {
    init {
        require(maximumLines.isNotEmpty())
    }

    private var bitmap = renderWatermarkTextBitmap(
        videoHeight,
        maximumLines,
        recordingOrientation,
    )

    init {
        // The first render only establishes stable bounds. All subsequent timestamps are
        // repainted into this bitmap so Media3 can update one texture via Bitmap.generationId.
        bitmap.eraseColor(Color.TRANSPARENT)
    }

    fun redraw(lines: List<String>): Bitmap {
        require(lines.isNotEmpty())
        val textSize = watermarkTextSize(videoHeight, recordingOrientation)
        val strokeWidth = (textSize / 10f).coerceAtLeast(3f)
        val padding = strokeWidth + 3f
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            this.textSize = textSize
            textAlign = Paint.Align.CENTER
            strokeJoin = Paint.Join.ROUND
        }
        val fontMetricsHeight = paint.fontMetrics.bottom - paint.fontMetrics.top
        val lineHeight = textSize * 1.25f
        val requiredWidth = lines.maxOf { paint.measureText(it) } + padding * 2
        val requiredHeight =
            fontMetricsHeight + lineHeight * (lines.size - 1) + padding * 2
        require(requiredWidth <= bitmap.width && requiredHeight <= bitmap.height) {
            "Watermark text exceeds the preallocated bitmap bounds"
        }
        val previousGenerationId = bitmap.generationId
        bitmap.eraseColor(Color.TRANSPARENT)
        val canvas = Canvas(bitmap)
        val centerX = bitmap.width / 2f
        var baseline = padding - paint.fontMetrics.top
        for (line in lines) {
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = strokeWidth
            paint.color = Color.BLACK
            canvas.drawText(line, centerX, baseline, paint)
            paint.style = Paint.Style.FILL
            paint.color = Color.WHITE
            canvas.drawText(line, centerX, baseline, paint)
            baseline += lineHeight
        }
        check(bitmap.generationId != previousGenerationId) {
            "Watermark bitmap pixels were not updated"
        }
        return bitmap
    }

    fun current(): Bitmap = bitmap

    fun release() {
        if (!bitmap.isRecycled) bitmap.recycle()
    }
}

@Suppress("UNUSED_PARAMETER")
internal fun watermarkTextSize(videoHeight: Int, recordingOrientation: String): Float {
    require(videoHeight > 0)
    return 42f
}

internal fun isSuccessfulWatermarkExport(
    overlayConfigured: Boolean,
    bitmapRequestCount: Int,
    videoFrameCount: Int,
    videoConversionProcess: Int,
    outputExists: Boolean,
    outputBytes: Long,
): Boolean =
    overlayConfigured &&
        bitmapRequestCount > 0 &&
        videoFrameCount > 0 &&
        videoConversionProcess == ExportResult.CONVERSION_PROCESS_TRANSCODED &&
        outputExists &&
        outputBytes > 0

@OptIn(UnstableApi::class)
internal class WatermarkCancellationState {
    data class Start(val generation: Long, val cancelled: Boolean)

    private var nextGeneration = 0L
    private var activeGeneration: Long? = null
    private var cancelNextStart = false

    @Synchronized
    fun begin(): Start {
        val generation = ++nextGeneration
        if (cancelNextStart) {
            cancelNextStart = false
            return Start(generation, cancelled = true)
        }
        check(activeGeneration == null) { "Watermark export is already active" }
        activeGeneration = generation
        return Start(generation, cancelled = false)
    }

    @Synchronized
    fun cancel(): Long? {
        val generation = activeGeneration
        if (generation == null) {
            cancelNextStart = true
        } else {
            activeGeneration = null
        }
        return generation
    }

    @Synchronized
    fun complete(generation: Long): Boolean {
        if (activeGeneration != generation) return false
        activeGeneration = null
        return true
    }

    @Synchronized
    fun isActive(generation: Long): Boolean = activeGeneration == generation

    @Synchronized
    fun hasActiveExport(): Boolean = activeGeneration != null
}

@OptIn(UnstableApi::class)
class VideoWatermarkPlugin(
    context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "app.packingproof.mobile/video_watermark")
    private val applicationContext = context.applicationContext
    private data class ActiveExport(
        val generation: Long,
        val result: MethodChannel.Result,
        val output: File,
        var transformer: Transformer? = null,
    )

    private val operationLock = Any()
    private val cancellationState = WatermarkCancellationState()
    private var activeExport: ActiveExport? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "apply" -> apply(call.arguments as? Map<*, *>, result)
                "cancel" -> {
                    cancelWatermark()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    internal fun invoke(
        method: String,
        arguments: Map<String, Any?>?,
        result: MethodChannel.Result,
    ) {
        when (method) {
            "apply" -> apply(arguments, result)
            "cancel" -> {
                cancelWatermark()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun apply(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (cancellationState.hasActiveExport()) {
            result.error("watermark_busy", "正在保存上一段录像", null)
            return
        }
        val inputPath = arguments?.get("inputPath") as? String
        val outputPath = arguments?.get("outputPath") as? String
        val startedAtMs = (arguments?.get("startedAtMs") as? Number)?.toLong()
        val trackingNumber = arguments?.get("trackingNumber") as? String ?: ""
        val recordingOrientation = arguments?.get("recordingOrientation") as? String ?: "portrait"
        val videoMime = if (arguments?.get("videoCodec") == "h264") {
            MimeTypes.VIDEO_H264
        } else {
            MimeTypes.VIDEO_H265
        }
        if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank() || startedAtMs == null) {
            result.error("invalid_watermark", "录像水印参数无效", null)
            return
        }
        val input = File(inputPath)
        if (!input.isFile) {
            result.error("missing_input", "录像文件不存在", null)
            return
        }
        val output = File(outputPath)
        output.parentFile?.mkdirs()
        output.delete()

        val start = cancellationState.begin()
        if (start.cancelled) {
            output.delete()
            result.error("watermark_cancelled", "录像水印生成已取消", null)
            return
        }
        val operation = ActiveExport(start.generation, result, output)
        synchronized(operationLock) {
            activeExport = operation
        }
        if (!cancellationState.isActive(operation.generation)) {
            val ownsResult = synchronized(operationLock) {
                if (activeExport !== operation) {
                    false
                } else {
                    activeExport = null
                    true
                }
            }
            deleteOutputUnlessReused(operation)
            if (ownsResult) {
                result.error("watermark_cancelled", "录像水印生成已取消", null)
            }
            return
        }

        val overlay = object : BitmapOverlay() {
            private val formatter = SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.ROOT)
            private var cachedSecond = Long.MIN_VALUE
            private var reusableBitmap: ReusableWatermarkBitmap? = null
            private var settings: StaticOverlaySettings? = null
            var wasEverConfigured = false
                private set
            var bitmapRequestCount = 0
                private set

            override fun configure(videoSize: Size) {
                super.configure(videoSize)
                clearCache()
                val maximumLines = watermarkLines("8888/88/88 88:88:88")
                reusableBitmap = ReusableWatermarkBitmap(
                    videoSize.height,
                    maximumLines,
                    recordingOrientation,
                )
                reusableBitmap?.redraw(
                    watermarkLines(formatter.format(Date(startedAtMs))),
                )
                val bitmap = checkNotNull(reusableBitmap).current()
                settings = watermarkOverlaySettings(
                    recordingOrientation,
                    bitmap.width,
                    bitmap.height,
                )
                cachedSecond = 0L
                wasEverConfigured = true
            }

            override fun getBitmap(presentationTimeUs: Long): Bitmap {
                bitmapRequestCount++
                val second = presentationTimeUs / 1_000_000L
                reusableBitmap?.takeIf { cachedSecond == second }?.let {
                    return it.current()
                }
                val timestamp = formatter.format(Date(startedAtMs + presentationTimeUs / 1_000L))
                val renderer = checkNotNull(reusableBitmap) {
                    "Watermark overlay was used before configuration"
                }
                cachedSecond = second
                return renderer.redraw(watermarkLines(timestamp))
            }

            override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings =
                checkNotNull(settings) {
                    "Watermark overlay settings were used before configuration"
                }

            override fun release() {
                clearCache()
                super.release()
            }

            private fun clearCache() {
                reusableBitmap?.release()
                reusableBitmap = null
                settings = null
                cachedSecond = Long.MIN_VALUE
            }

            private fun watermarkLines(timestamp: String): List<String> {
                return watermarkTextLines(timestamp, trackingNumber)
            }
        }
        val editedMediaItem = EditedMediaItem.Builder(
            MediaItem.fromUri(Uri.fromFile(input)),
        ).setEffects(
            Effects(emptyList(), listOf(OverlayEffect(listOf(overlay)))),
        ).build()

        val decoderFactory = DefaultDecoderFactory.Builder(applicationContext)
            .setEnableDecoderFallback(true)
            .build()
        val assetLoaderFactory = DefaultAssetLoaderFactory(
            applicationContext,
            decoderFactory,
            Clock.DEFAULT,
            null,
        )
        val builtTransformer = Transformer.Builder(applicationContext)
            .setAssetLoaderFactory(assetLoaderFactory)
            .setVideoMimeType(videoMime)
            .addListener(
                object : Transformer.Listener {
                    override fun onCompleted(
                        composition: Composition,
                        exportResult: ExportResult,
                    ) {
                        val outputExists = output.isFile
                        val outputBytes = if (outputExists) output.length() else 0L
                        if (
                            isSuccessfulWatermarkExport(
                                overlayConfigured = overlay.wasEverConfigured,
                                bitmapRequestCount = overlay.bitmapRequestCount,
                                videoFrameCount = exportResult.videoFrameCount,
                                videoConversionProcess = exportResult.videoConversionProcess,
                                outputExists = outputExists,
                                outputBytes = outputBytes,
                            )
                        ) {
                            finishSuccess(operation, outputPath)
                        } else {
                            finishError(
                                operation,
                                IllegalStateException("Watermark export contract was not satisfied"),
                                failureStage = "export_contract",
                            )
                        }
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) = finishError(operation, exportException, failureStage = "transformer")
                },
            )
            .build()
        try {
            synchronized(operationLock) {
                if (!cancellationState.isActive(operation.generation) ||
                    activeExport !== operation
                ) {
                    builtTransformer.cancel()
                    output.delete()
                    return
                }
                operation.transformer = builtTransformer
                builtTransformer.start(editedMediaItem, outputPath)
            }
        } catch (error: Exception) {
            finishError(operation, error, failureStage = "start")
        }
    }

    private fun finishSuccess(operation: ActiveExport, outputPath: String) {
        if (!finish(operation)) {
            deleteOutputUnlessReused(operation)
            return
        }
        operation.result.success(outputPath)
    }

    private fun finishError(
        operation: ActiveExport,
        error: Throwable,
        failureStage: String,
    ) {
        Log.e(
            "PackingProof.Watermark",
            "Watermark export failed stage=$failureStage",
            error,
        )
        if (!finish(operation)) {
            deleteOutputUnlessReused(operation)
            return
        }
        operation.output.delete()
        val details = mutableMapOf<String, Any>(
            "failureStage" to failureStage,
            "errorType" to error.javaClass.simpleName,
        )
        if (error is ExportException) {
            details["exportErrorCode"] = error.errorCode
        }
        operation.result.error("watermark_failed", "录像水印生成失败", details)
    }

    private fun finish(operation: ActiveExport): Boolean {
        if (!cancellationState.complete(operation.generation)) return false
        synchronized(operationLock) {
            if (activeExport !== operation) return false
            activeExport = null
        }
        return true
    }

    private fun deleteOutputUnlessReused(operation: ActiveExport) {
        synchronized(operationLock) {
            val reused = activeExport?.output?.absolutePath == operation.output.absolutePath
            if (!reused) operation.output.delete()
        }
    }

    fun cancelWatermark() {
        val generation = cancellationState.cancel() ?: return
        val operation = synchronized(operationLock) {
            activeExport?.takeIf { it.generation == generation }?.also {
                activeExport = null
            }
        } ?: return
        operation.transformer?.cancel()
        deleteOutputUnlessReused(operation)
        operation.result.error("watermark_cancelled", "录像水印生成已取消", null)
    }

    fun dispose() {
        cancelWatermark()
        channel.setMethodCallHandler(null)
    }
}
