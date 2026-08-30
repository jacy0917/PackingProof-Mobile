package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class RecordingSpecPolicyTest {
    @Test
    fun `unknown or missing spec falls back to HD`() {
        assertEquals(RecordingSpecPolicy.HD, RecordingSpecPolicy.resolve(null))
        assertEquals(RecordingSpecPolicy.HD, RecordingSpecPolicy.resolve(""))
        assertEquals(RecordingSpecPolicy.HD, RecordingSpecPolicy.resolve("weird"))
        assertEquals("hd1080p30", RecordingSpecPolicy.resolveName("weird"))
    }

    @Test
    fun `smooth spec resolves to 720p30 lower bitrate`() {
        val spec = RecordingSpecPolicy.resolve("smooth720p30")
        assertEquals(1280, spec.videoWidth)
        assertEquals(720, spec.videoHeight)
        assertEquals(30, spec.fps)
        assertEquals(6_000_000, spec.avcBitRate)
        assertEquals(4_500_000, spec.hevcBitRate)
        assertEquals("smooth720p30", RecordingSpecPolicy.resolveName("720p30"))
    }

    @Test
    fun `default spec keeps 1080p30 bitrate`() {
        val spec = RecordingSpecPolicy.resolve("hd1080p30")
        assertEquals(1920, spec.videoWidth)
        assertEquals(1080, spec.videoHeight)
        assertEquals(30, spec.fps)
        assertEquals(10_000_000, spec.avcBitRate)
        assertEquals(7_000_000, spec.hevcBitRate)
    }

    @Test
    fun `UHD aliases resolve to 4K30 balanced bitrate`() {
        for (name in listOf("uhd4k30", "4k", "4k30", "2160p30")) {
            assertEquals(RecordingSpecPolicy.UHD, RecordingSpecPolicy.resolve(name))
            assertEquals(RecordingSpecPolicy.UHD_SPEC_NAME, RecordingSpecPolicy.resolveName(name))
        }
        assertEquals(3840, RecordingSpecPolicy.UHD.videoWidth)
        assertEquals(2160, RecordingSpecPolicy.UHD.videoHeight)
        assertEquals(35_000_000, RecordingSpecPolicy.UHD.avcBitRate)
        assertEquals(24_000_000, RecordingSpecPolicy.UHD.hevcBitRate)
    }
}
