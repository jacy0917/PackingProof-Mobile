package app.packingproof.mobile

import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.security.MessageDigest
import java.time.Instant

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class RecordingStorageManagerTest {
    private val context
        get() = RuntimeEnvironment.getApplication()
    private lateinit var source: File
    private lateinit var store: LanBackupStateStore

    @Before
    fun setUp() {
        context.deleteDatabase("lan_backup.db")
        source = File(context.cacheDir, "storage-manager-test.mp4").apply {
            writeText("test-video", Charsets.UTF_8)
        }
        store = LanBackupStateStore(context)
    }

    @After
    fun tearDown() {
        source.delete()
        context.deleteDatabase("lan_backup.db")
    }

    @Test
    fun sufficientStorageDoesNotReportJobChanges() {
        val manager = RecordingStorageManager(
            context,
            store,
            availableBytes = { RecordingStoragePolicy.TARGET_BYTES },
        )

        val result = manager.checkAndReclaim()

        assertFalse(result.jobsChanged)
        assertEquals(0, result.values["deletedCount"])
    }

    @Test
    fun deletionReportsOneChangeAndSubsequentCheckDoesNotRepeatIt() {
        val job = store.upsertJob(source.path, sessions()).job
        store.updateJob(job.getString("id")) { current ->
            current.put("state", "completed")
                .put("backupCompletedAt", Instant.now().toString())
                .put("contentSha256", sha256(source))
                .put("verificationVersion", BackupRequestAuthentication.VERSION)
                .put("lastAttestedAt", Instant.now().toString())
                .put("totalBytes", source.length())
                .put("lastModified", source.lastModified())
            true
        }
        val manager = RecordingStorageManager(context, store, availableBytes = { 0 })

        val first = manager.checkAndReclaim()
        val second = manager.checkAndReclaim()

        assertTrue(first.jobsChanged)
        assertEquals(1, first.values["deletedCount"])
        assertFalse(second.jobsChanged)
        assertEquals(0, second.values["deletedCount"])
    }

    private fun sessions(): JSONArray = JSONArray().put(
        JSONObject()
            .put("id", "storage-manager-session")
            .put("startedAt", "2026-08-23T09:30:00Z")
            .put("endedAt", "2026-08-23T09:30:01Z"),
    )

    private fun sha256(file: File): String = MessageDigest.getInstance("SHA-256")
        .digest(file.readBytes())
        .joinToString("") { "%02x".format(it) }
}
