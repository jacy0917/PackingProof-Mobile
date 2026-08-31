package app.packingproof.mobile

internal class RecordingSpecRuntimeState {
    var spec: RecordingSpec = RecordingSpecPolicy.HD
        private set
    var name: String = RecordingSpecPolicy.DEFAULT_SPEC_NAME
        private set
    var supportedNames: List<String> = RecordingSpecSupportPolicy.supportedSpecs(null)
        private set
    var fpsRangePolicy = RecordingFpsRangePolicy(spec.fps)
        private set
    var streamConfigPolicy = StreamConfigPolicy(spec.videoWidth, spec.videoHeight)
        private set

    private var requestedName = RecordingSpecPolicy.DEFAULT_SPEC_NAME
    private var negotiatedUhdFps = RecordingSpecPolicy.UHD.fps

    fun request(name: String?) {
        requestedName = RecordingSpecPolicy.resolveName(name)
        applyRequested()
    }

    fun updateUhdFps(uhdFps: Int?) {
        negotiatedUhdFps = uhdFps ?: RecordingSpecPolicy.UHD.fps
        supportedNames = RecordingSpecSupportPolicy.supportedSpecs(uhdFps)
        if (requestedName == RecordingSpecPolicy.UHD_SPEC_NAME && uhdFps == null) {
            requestedName = RecordingSpecPolicy.DEFAULT_SPEC_NAME
        }
        applyRequested()
    }

    fun shouldRejectUhd(videoWidth: Int, videoHeight: Int): Boolean =
        name == RecordingSpecPolicy.UHD_SPEC_NAME &&
            (videoWidth != RecordingSpecPolicy.UHD.videoWidth ||
                videoHeight != RecordingSpecPolicy.UHD.videoHeight)

    fun rejectUhd(cameraId: String?) {
        RecordingSpecRuntimeRejectionCache.rejectUhd(cameraId)
        supportedNames = supportedNames.filterNot {
            it == RecordingSpecPolicy.UHD_SPEC_NAME
        }
        requestedName = RecordingSpecPolicy.DEFAULT_SPEC_NAME
        applyRequested()
    }

    private fun applyRequested() {
        name = RecordingSpecPolicy.resolveName(requestedName)
        spec = RecordingSpecPolicy.resolve(name).let { selected ->
            if (name == RecordingSpecPolicy.UHD_SPEC_NAME) {
                selected.copy(fps = negotiatedUhdFps)
            } else {
                selected
            }
        }
        fpsRangePolicy = RecordingFpsRangePolicy(spec.fps)
        streamConfigPolicy = StreamConfigPolicy(spec.videoWidth, spec.videoHeight)
    }
}
