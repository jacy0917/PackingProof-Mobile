package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class RecordingSpecSupportPolicyTest {
    @Test
    fun `4K selects highest common camera video and encoder fps`() {
        val fps = RecordingSpecSupportPolicy.selectUhdFps(
            cameraSupportsUhd = true,
            cameraFpsRanges = listOf(15 to 30),
            maximumVideoFps = 25,
            encoderSupportsUhd = { it <= 24 },
        )
        assertEquals(24, fps)
        assertEquals(
            listOf("uhd4k30", "hd1080p30", "smooth720p30"),
            RecordingSpecSupportPolicy.supportedSpecs(fps),
        )
    }

    @Test
    fun `missing any hardware requirement hides 4K`() {
        for (fps in listOf(
            RecordingSpecSupportPolicy.selectUhdFps(false, listOf(15 to 30), 30) { true },
            RecordingSpecSupportPolicy.selectUhdFps(true, listOf(1 to 14), 30) { true },
            RecordingSpecSupportPolicy.selectUhdFps(true, listOf(15 to 30), 30) { false },
        )) {
            assertEquals(
                listOf("hd1080p30", "smooth720p30"),
                RecordingSpecSupportPolicy.supportedSpecs(fps),
            )
        }
    }

    @Test
    fun `runtime rejection is scoped by camera id`() {
        RecordingSpecRuntimeRejectionCache.clear()
        RecordingSpecRuntimeRejectionCache.rejectUhd("wide")
        assertEquals(true, RecordingSpecRuntimeRejectionCache.isUhdRejected("wide"))
        assertEquals(false, RecordingSpecRuntimeRejectionCache.isUhdRejected("tele"))
        RecordingSpecRuntimeRejectionCache.clear()
    }

    @Test
    fun `runtime state applies negotiated 4K fps and falls back after rejection`() {
        RecordingSpecRuntimeRejectionCache.clear()
        val state = RecordingSpecRuntimeState()
        state.request("4k")
        state.updateUhdFps(24)

        assertEquals(RecordingSpecPolicy.UHD_SPEC_NAME, state.name)
        assertEquals(24, state.spec.fps)
        assertEquals(true, state.shouldRejectUhd(1920, 1080))

        state.rejectUhd("wide")
        assertEquals(RecordingSpecPolicy.DEFAULT_SPEC_NAME, state.name)
        assertEquals(RecordingSpecPolicy.HD, state.spec)
        assertEquals(
            listOf(RecordingSpecPolicy.DEFAULT_SPEC_NAME, RecordingSpecPolicy.SMOOTH_SPEC_NAME),
            state.supportedNames,
        )
        assertEquals(true, RecordingSpecRuntimeRejectionCache.isUhdRejected("wide"))
        RecordingSpecRuntimeRejectionCache.clear()
    }

    @Test
    fun `runtime state keeps requested 4K hidden when capability is unavailable`() {
        val state = RecordingSpecRuntimeState()
        state.request(RecordingSpecPolicy.UHD_SPEC_NAME)
        state.updateUhdFps(null)

        assertEquals(RecordingSpecPolicy.DEFAULT_SPEC_NAME, state.name)
        assertEquals(RecordingSpecPolicy.HD, state.spec)
    }
}
