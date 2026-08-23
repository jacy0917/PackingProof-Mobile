package app.packingproof.mobile

import android.os.StatFs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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

        val available = availableRecordingStorageBytes(context)

        assertTrue(available != null && available > 0)
        assertEquals(StatFs(context.filesDir.path).availableBytes, available)
    }
}
