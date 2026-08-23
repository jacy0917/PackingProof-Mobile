package app.packingproof.mobile

import android.content.Context
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
import java.util.concurrent.atomic.AtomicInteger

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class LanBackupCleanupScheduleSliceTest {
    private lateinit var context: Context
    private lateinit var store: LanBackupStateStore

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("lan_backup.db")
        context.getSharedPreferences("lan_backup_retention", Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        store = LanBackupStateStore(context)
        store.summary()
    }

    @After
    fun tearDown() {
        store.close()
        context.deleteDatabase("lan_backup.db")
    }

    @Test
    fun fiftyThousandPolicyChangesUseSlicesOfAtMostOneHundredAndOneNoticeEach() {
        seedJobs(50_000)
        assertTrue(
            cleanupSchedulePlan().contains(LanBackupJobDatabase.CLEANUP_SCHEDULE_REFRESH_INDEX),
        )
        assertTrue(store.saveRetentionPolicies(unbackedDays = 30, backedDays = 7))
        val refresh = store.restartCleanupScheduleRefresh()
        val noticeCount = AtomicInteger()
        val listener: (LanBackupRevisionNotifier.Notice) -> Unit = {
            noticeCount.incrementAndGet()
        }
        LanBackupRevisionNotifier.addListener(listener)
        try {
            var processed = 0
            var changed = 0
            var slicesWithChanges = 0
            do {
                val slice = store.refreshCleanupScheduleSlice(refresh.generation)
                assertTrue(slice.processedCount <= 100)
                assertTrue(slice.changedCount <= slice.processedCount)
                processed += slice.processedCount
                changed += slice.changedCount
                if (slice.changedCount > 0) slicesWithChanges++
            } while (slice.hasMore)

            assertEquals(50_000, processed)
            assertEquals(50_000, changed)
            assertEquals(500, slicesWithChanges)
            assertTrue(noticeCount.get() <= slicesWithChanges)
            assertFalse(store.cleanupScheduleRefresh().active)
        } finally {
            LanBackupRevisionNotifier.removeListener(listener)
        }
    }

    @Test
    fun unchangedSliceAdvancesCheckpointWithoutWritingJobsOrRevision() {
        seedJobs(150)
        store.saveRetentionPolicies(unbackedDays = 30, backedDays = 7)
        var refresh = store.restartCleanupScheduleRefresh()
        while (store.refreshCleanupScheduleSlice(refresh.generation).hasMore) {
            // Drain the first pass so every row already has the target schedule.
        }
        val revisionBefore = store.summary().revision

        refresh = store.restartCleanupScheduleRefresh()
        val slice = store.refreshCleanupScheduleSlice(refresh.generation)

        assertEquals(100, slice.processedCount)
        assertEquals(0, slice.changedCount)
        assertEquals(revisionBefore, store.summary().revision)
        assertTrue(slice.hasMore)
    }

    @Test
    fun processRecreationResumesPersistedCheckpointInsteadOfRestarting() {
        seedJobs(250)
        store.saveRetentionPolicies(unbackedDays = 30, backedDays = 7)
        val refresh = store.restartCleanupScheduleRefresh()
        val first = store.refreshCleanupScheduleSlice(refresh.generation)
        assertEquals(100, first.processedCount)
        assertEquals(100, scheduledCount())
        store.close()

        store = LanBackupStateStore(context)
        val resumed = store.ensureCleanupScheduleRefresh()
            ?: error("cleanup schedule refresh checkpoint was not resumed")
        assertEquals(refresh.generation, resumed.generation)
        val second = store.refreshCleanupScheduleSlice(resumed.generation)

        assertEquals(100, second.processedCount)
        assertEquals(200, scheduledCount())
        assertTrue(second.hasMore)
        val third = store.refreshCleanupScheduleSlice(resumed.generation)
        assertEquals(50, third.processedCount)
        assertFalse(third.hasMore)
        assertEquals(250, scheduledCount())
    }

    private fun seedJobs(count: Int) {
        val database = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        val statement = database.compileStatement(
            """
            INSERT INTO backup_jobs(
                id, generation, file_path, state, file_created_at, sessions, updated_revision
            ) VALUES(?, ?, ?, 'paused', '2026-08-01T00:00:00Z', '[]', 0)
            """.trimIndent(),
        )
        database.beginTransaction()
        try {
            repeat(count) { index ->
                val id = "cleanup-${index.toString().padStart(5, '0')}"
                statement.clearBindings()
                statement.bindString(1, id)
                statement.bindString(2, "generation-$id")
                statement.bindString(3, "/recordings/$id.mp4")
                statement.executeInsert()
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
            statement.close()
            database.close()
        }
    }

    private fun scheduledCount(): Int {
        val database = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        return try {
            database.rawQuery(
                "SELECT COUNT(*) FROM backup_jobs WHERE scheduled_cleanup_at IS NOT NULL",
                null,
            ).use { cursor ->
                cursor.moveToFirst()
                cursor.getInt(0)
            }
        } finally {
            database.close()
        }
    }

    private fun cleanupSchedulePlan(): String {
        val database = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        return try {
            database.rawQuery(
                "EXPLAIN QUERY PLAN SELECT id FROM backup_jobs " +
                    "INDEXED BY ${LanBackupJobDatabase.CLEANUP_SCHEDULE_REFRESH_INDEX} " +
                    "WHERE local_deleted_at IS NULL AND id > ? ORDER BY id ASC LIMIT 100",
                arrayOf("cleanup-00099"),
            ).use { cursor ->
                buildList {
                    while (cursor.moveToNext()) add(cursor.getString(3))
                }.joinToString("\n")
            }
        } finally {
            database.close()
        }
    }
}
