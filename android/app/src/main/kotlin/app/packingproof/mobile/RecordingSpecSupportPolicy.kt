package app.packingproof.mobile

import java.util.Collections

internal object RecordingSpecSupportPolicy {
    fun supportedSpecs(
        cameraSupportsUhd: Boolean,
        fpsSupports30: Boolean,
        avcEncoderSupportsUhd: Boolean,
        hevcEncoderSupportsUhd: Boolean,
    ): List<String> = buildList {
        if (
            cameraSupportsUhd &&
            fpsSupports30 &&
            (avcEncoderSupportsUhd || hevcEncoderSupportsUhd)
        ) {
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
