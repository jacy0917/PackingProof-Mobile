package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class RecordingStorageBytesTest {
    @Test
    fun readsAvailableBytesFromApplicationFilesVolume() {
        val context = RuntimeEnvironment.getApplication()
        var queriedPath: String? = null

        val available = availableRecordingStorageBytes(context) { path ->
            queriedPath = path
            123456L
        }

        assertEquals(context.filesDir.path, queriedPath)
        assertEquals(123456L, available)
    }
}
