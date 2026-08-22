package app.packingproof.mobile

import android.media.MediaCodecList

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

    fun disableHevcEncoderForProcess() {
        hevcEncoderDisabledForProcess = true
    }
}
