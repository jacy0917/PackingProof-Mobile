package app.packingproof.mobile

import android.content.Context
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class LanBackupJobDatabaseMigrationTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("lan_backup.db")
    }

    @After
    fun tearDown() {
        context.deleteDatabase("lan_backup.db")
    }

    @Test
    fun versionFiveUpgradeCreatesCleanupScheduleStateAndPartialIndex() {
        val database = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        try {
            database.execSQL(
                "CREATE TABLE backup_jobs(" +
                    "id TEXT PRIMARY KEY, local_deleted_at TEXT)",
            )

            LanBackupJobDatabase(context).onUpgrade(database, 5, 6)

            assertEquals(1, schemaObjectCount("table", "backup_cleanup_schedule_state"))
            assertEquals(
                1,
                schemaObjectCount(
                    "index",
                    LanBackupJobDatabase.CLEANUP_SCHEDULE_REFRESH_INDEX,
                ),
            )
        } finally {
            database.close()
        }
    }

    private fun schemaObjectCount(type: String, name: String): Int {
        val database = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        return try {
            database.rawQuery(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = ? AND name = ?",
                arrayOf(type, name),
            ).use { cursor ->
                cursor.moveToFirst()
                cursor.getInt(0)
            }
        } finally {
            database.close()
        }
    }
}
