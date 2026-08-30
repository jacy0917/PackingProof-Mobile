package app.packingproof.mobile

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat

/**
 * 查询设备 MediaCodec 编解码能力。
 *
 * 部分鸿蒙/低端机型只有 H.265 编码器却没有可用的 H.265 解码器，
 * 这类机型录出的 H.265 本机无法播放，需要在录像前自动回退到 H.264。
 */
object CodecCapabilities {
    @Volatile
    private var hevcEncoderDisabledForProcess = false

    private val codecInfos by lazy {
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.toList()
        } catch (_: Throwable) {
            emptyList()
        }
    }

    fun hasDecoder(mime: String): Boolean {
        return codecInfos.any { info ->
            !info.isEncoder &&
                info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
        }
    }

    fun hasEncoder(mime: String): Boolean {
        if (
            mime.equals(android.media.MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) &&
            hevcEncoderDisabledForProcess
        ) {
            return false
        }
        return codecInfos.any { info ->
            info.isEncoder &&
                info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
        }
    }

    fun supportsSurfaceEncoding(
        mime: String,
        width: Int,
        height: Int,
        framesPerSecond: Int,
    ): Boolean {
        if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC && hevcEncoderDisabledForProcess) {
            return false
        }
        return codecInfos.any { info ->
            if (!info.isEncoder || info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) {
                return@any false
            }
            runCatching {
                val capabilities = info.getCapabilitiesForType(mime)
                val videoCapabilities = capabilities.videoCapabilities
                    ?: return@runCatching false
                capabilities.colorFormats.contains(
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
                ) && videoCapabilities.areSizeAndRateSupported(
                    width,
                    height,
                    framesPerSecond.toDouble(),
                )
            }.getOrDefault(false)
        }
    }

    fun disableHevcEncoderForProcess() {
        hevcEncoderDisabledForProcess = true
    }
}
