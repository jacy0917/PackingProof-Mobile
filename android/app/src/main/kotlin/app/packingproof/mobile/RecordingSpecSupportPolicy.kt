package app.packingproof.mobile

import java.util.Collections

internal object RecordingSpecSupportPolicy {
    private val preferredUhdFps = listOf(30, 25, 24, 20, 15)

    fun selectUhdFps(
        cameraSupportsUhd: Boolean,
        cameraFpsRanges: List<Pair<Int, Int>>,
        maximumVideoFps: Int?,
        encoderSupportsUhd: (Int) -> Boolean,
    ): Int? {
        if (!cameraSupportsUhd) return null
        return preferredUhdFps.firstOrNull { fps ->
            (maximumVideoFps == null || fps <= maximumVideoFps) &&
                cameraFpsRanges.any { fps in it.first..it.second } &&
                encoderSupportsUhd(fps)
        }
    }

    fun supportedSpecs(
        uhdFps: Int?,
    ): List<String> = buildList {
        if (uhdFps != null) {
            add(RecordingSpecPolicy.UHD_SPEC_NAME)
        }
        add(RecordingSpecPolicy.DEFAULT_SPEC_NAME)
        add(RecordingSpecPolicy.SMOOTH_SPEC_NAME)
    }
}

internal object RecordingSpecRuntimeRejectionCache {
    private val rejectedUhdCameraIds = Collections.synchronizedSet(mutableSetOf<String>())

    fun rejectUhd(cameraId: String?) {
        if (!cameraId.isNullOrEmpty()) rejectedUhdCameraIds.add(cameraId)
    }

    fun isUhdRejected(cameraId: String?): Boolean =
        !cameraId.isNullOrEmpty() && cameraId in rejectedUhdCameraIds

    fun clear() {
        rejectedUhdCameraIds.clear()
    }
}
