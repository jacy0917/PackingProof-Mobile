package app.packingproof.mobile

import android.content.Context
import androidx.work.Configuration
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.time.Instant
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class LanBackupWorkBoundTest {
    private lateinit var context: Context
    private lateinit var workManager: WorkManager
    private lateinit var store: LanBackupStateStore

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("androidx.work.workdb")
        context.deleteDatabase("lan_backup.db")
        context.getSharedPreferences("lan_backup_migration", Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        val holdWorkers = Executor { }
        val configuration = Configuration.Builder()
            .setExecutor(holdWorkers)
            .setTaskExecutor(SynchronousExecutor())
            .build()
        WorkManagerTestInitHelper.initializeTestWorkManager(
            context,
            configuration,
            WorkManagerTestInitHelper.ExecutorsMode.PRESERVE_EXECUTORS,
        )
        workManager = WorkManager.getInstance(context)
        store = LanBackupStateStore(context)
    }

    @After
    fun tearDown() {
        store.close()
        WorkManagerTestInitHelper.closeWorkDatabase()
        context.deleteDatabase("lan_backup.db")
    }

    @Test
    fun tenThousandWakeupsKeepUploadAndCleanupDispatchersStrictlyBounded() {
        seedScheduledCleanupJobs(10_000)

        repeat(10_000) { index ->
            LanBackupDispatcher.schedule(context)
            LanBackupCleanupScheduler.scheduleNext(context, store)
            if ((index + 1) % 250 == 0) {
                assertTrue(allUniqueWork(LanBackupDispatcher.UNIQUE_WORK).size <= 2)
                assertTrue(allUniqueWork(LanBackupCleanupScheduler.UNIQUE_WORK).size <= 2)
            }
        }

        assertEquals(1, unfinishedCount(LanBackupDispatcher.UNIQUE_WORK))
        assertEquals(1, unfinishedCount(LanBackupCleanupScheduler.UNIQUE_WORK))
        assertEquals(2, unfinishedBackupWorkCount())

        LanBackupDispatcher.schedule(context, append = true)
        LanBackupCleanupScheduler.scheduleNext(context, store, append = true)

        assertEquals(2, unfinishedCount(LanBackupDispatcher.UNIQUE_WORK))
        assertEquals(2, unfinishedCount(LanBackupCleanupScheduler.UNIQUE_WORK))
        assertEquals(4, unfinishedBackupWorkCount())

        LanBackupDispatcher.schedule(context)
        LanBackupCleanupScheduler.scheduleNext(context, store)

        assertEquals(2, unfinishedCount(LanBackupDispatcher.UNIQUE_WORK))
        assertEquals(1, unfinishedCount(LanBackupCleanupScheduler.UNIQUE_WORK))
        assertEquals(3, unfinishedBackupWorkCount())
        assertTrue(allUniqueWork(LanBackupDispatcher.UNIQUE_WORK).size <= 2)
        assertTrue(allUniqueWork(LanBackupCleanupScheduler.UNIQUE_WORK).size <= 2)
        assertTrue(allBackupWork().size <= 4)
    }

    private fun seedScheduledCleanupJobs(count: Int) {
        store.summary()
        val database = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        val statement = database.compileStatement(
            """
            INSERT INTO backup_jobs(
                id, generation, file_path, state, sessions, updated_revision,
                scheduled_cleanup_at, file_created_at
            ) VALUES(?, ?, ?, 'completed', ?, ?, ?, ?)
            """.trimIndent(),
        )
        val scheduledAt = Instant.now().plusSeconds(86_400).toString()
        database.beginTransaction()
        try {
            repeat(count) { index ->
                val id = "work-bound-${index.toString().padStart(5, '0')}"
                statement.clearBindings()
                statement.bindString(1, id)
                statement.bindString(2, "generation-$id")
                statement.bindString(3, "/recordings/$id.mp4")
                statement.bindString(4, """[{"id":"$id"}]""")
                statement.bindLong(5, (index + 1).toLong())
                statement.bindString(6, scheduledAt)
                statement.bindString(7, scheduledAt)
                statement.executeInsert()
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
            statement.close()
            database.close()
        }
    }

    private fun unfinishedCount(uniqueWorkName: String): Int =
        allUniqueWork(uniqueWorkName)
            .count { !it.state.isFinished }

    private fun allUniqueWork(uniqueWorkName: String): List<WorkInfo> =
        workManager.getWorkInfosForUniqueWork(uniqueWorkName)
            .get(30, TimeUnit.SECONDS)

    private fun unfinishedBackupWorkCount(): Int =
        allBackupWork().count { !it.state.isFinished }

    private fun allBackupWork(): List<WorkInfo> =
        workManager.getWorkInfosByTag("lan-backup")
            .get(30, TimeUnit.SECONDS)
}
