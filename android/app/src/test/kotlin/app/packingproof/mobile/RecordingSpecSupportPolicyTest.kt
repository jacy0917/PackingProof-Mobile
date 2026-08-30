package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class RecordingSpecSupportPolicyTest {
    @Test
    fun `4K requires camera fps and at least one encoder`() {
        val supported = RecordingSpecSupportPolicy.supportedSpecs(
            cameraSupportsUhd = true,
            fpsSupports30 = true,
            avcEncoderSupportsUhd = false,
            hevcEncoderSupportsUhd = true,
        )
        assertEquals(
            listOf("uhd4k30", "hd1080p30", "smooth720p30"),
            supported,
        )
    }

    @Test
    fun `missing any hardware requirement hides 4K`() {
        for (supported in listOf(
            RecordingSpecSupportPolicy.supportedSpecs(false, true, true, true),
            RecordingSpecSupportPolicy.supportedSpecs(true, false, true, true),
            RecordingSpecSupportPolicy.supportedSpecs(true, true, false, false),
        )) {
            assertEquals(listOf("hd1080p30", "smooth720p30"), supported)
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
