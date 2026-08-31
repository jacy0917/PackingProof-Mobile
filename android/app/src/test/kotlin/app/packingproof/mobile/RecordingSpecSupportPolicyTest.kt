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
}
