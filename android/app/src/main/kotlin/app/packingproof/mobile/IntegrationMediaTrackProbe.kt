package app.packingproof.mobile

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

internal object IntegrationTestBridgePolicy {
    const val PACKAGE_NAME = "app.packingproof.mobile.integration_test"

    fun isAllowed(packageName: String): Boolean = packageName == PACKAGE_NAME
}

/** Test-only MP4 track inspection. MainActivity registers it only for the isolated package. */
internal class IntegrationMediaTrackProbe(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL_NAME =
            "app.packingproof.mobile.integration_test/media_track_probe"
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!IntegrationTestBridgePolicy.isAllowed(context.packageName)) {
            result.error("forbidden", "测试媒体探针只允许隔离包使用", null)
            return
        }
        if (call.method != "inspect") {
            result.notImplemented()
            return
        }
        try {
            result.success(inspect(call.argument<String>("path")))
        } catch (_: Throwable) {
            // broad-catch: 隔离测试桥只向 Flutter 返回类型化探测失败
            result.error("probe_failed", "无法读取隔离测试视频轨道", null)
        }
    }

    private fun inspect(path: String?): List<Map<String, Any>> {
        require(!path.isNullOrBlank())
        val file = File(path).canonicalFile
        val privateRoot = context.dataDir.canonicalFile
        require(file.path.startsWith(privateRoot.path + File.separator))
        require(file.isFile)

        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.path)
            (0 until extractor.trackCount).map { trackIndex ->
                val format = extractor.getTrackFormat(trackIndex)
                val mime = format.getString(MediaFormat.KEY_MIME).orEmpty()
                val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                    format.getLong(MediaFormat.KEY_DURATION)
                } else {
                    0L
                }
                val sampleSummary = inspectSamples(file, trackIndex)
                mapOf(
                    "mime" to mime,
                    "durationUs" to durationUs,
                    "sampleCount" to sampleSummary.first,
                    "lastSampleTimeUs" to sampleSummary.second,
                )
            }
        } finally {
            extractor.release()
        }
    }

    private fun inspectSamples(file: File, trackIndex: Int): Pair<Long, Long> {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.path)
            extractor.selectTrack(trackIndex)
            var sampleCount = 0L
            var lastSampleTimeUs = -1L
            while (extractor.sampleTime >= 0L) {
                sampleCount++
                lastSampleTimeUs = extractor.sampleTime
                if (!extractor.advance()) break
            }
            sampleCount to lastSampleTimeUs
        } finally {
            extractor.release()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
