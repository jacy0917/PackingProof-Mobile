package app.packingproof.mobile

import android.hardware.camera2.params.StreamConfigurationMap
import android.media.MediaFormat
import android.media.MediaRecorder
import android.util.Range
import android.util.Size

internal object CameraRecordingSpecCapabilityProbe {
    fun selectUhdFps(
        configuration: StreamConfigurationMap,
        videoSizes: List<Size>,
        cameraFpsRanges: List<Range<Int>>,
        cameraId: String?,
    ): Int? {
        val cameraSupportsUhd = videoSizes.any {
            it.width == RecordingSpecPolicy.UHD.videoWidth &&
                it.height == RecordingSpecPolicy.UHD.videoHeight
        } && !RecordingSpecRuntimeRejectionCache.isUhdRejected(cameraId)
        val uhdSize = Size(
            RecordingSpecPolicy.UHD.videoWidth,
            RecordingSpecPolicy.UHD.videoHeight,
        )
        val minimumFrameDuration = runCatching {
            configuration.getOutputMinFrameDuration(MediaRecorder::class.java, uhdSize)
        }.getOrDefault(0L)
        val maximumVideoFps = minimumFrameDuration.takeIf { it > 0L }?.let {
            (1_000_000_000L / it).toInt()
        }
        return RecordingSpecSupportPolicy.selectUhdFps(
            cameraSupportsUhd = cameraSupportsUhd,
            cameraFpsRanges = cameraFpsRanges.map { it.lower to it.upper },
            maximumVideoFps = maximumVideoFps,
            encoderSupportsUhd = ::encoderSupportsUhd,
        )
    }

    private fun encoderSupportsUhd(fps: Int): Boolean =
        CodecCapabilities.supportsSurfaceEncoding(
            MediaFormat.MIMETYPE_VIDEO_AVC,
            RecordingSpecPolicy.UHD.videoWidth,
            RecordingSpecPolicy.UHD.videoHeight,
            fps,
        ) || (
            CodecCapabilities.hasDecoder(MediaFormat.MIMETYPE_VIDEO_HEVC) &&
                CodecCapabilities.supportsSurfaceEncoding(
                    MediaFormat.MIMETYPE_VIDEO_HEVC,
                    RecordingSpecPolicy.UHD.videoWidth,
                    RecordingSpecPolicy.UHD.videoHeight,
                    fps,
                )
            )
}
