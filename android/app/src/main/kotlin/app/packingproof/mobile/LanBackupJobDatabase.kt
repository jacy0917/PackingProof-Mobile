package app.packingproof.mobile

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.time.Instant

/**
 * 备份任务的 SQLite 存储：一个任务一行，替代旧版“一录像一个 JSON 文件”的目录存储。
 * 首次打开时把旧版 `lan_backup/jobs` 目录下的任务文件一次性导入，导入完成后删除旧文件。
 */
internal class LanBackupJobDatabase(private val context: Context) :
    SQLiteOpenHelper(context.applicationContext, DATABASE_NAME, null, DATABASE_VERSION) {

    companion object {
        private const val DATABASE_NAME = "lan_backup.db"
        private const val DATABASE_VERSION = 5
        const val TABLE = "backup_jobs"
        const val META_TABLE = "backup_meta"
        const val CLEANUP_EVENTS_TABLE = "backup_cleanup_events"
        const val SUMMARY_COUNTERS_INITIALIZED = "summary_counters_initialized"
        const val UPLOADING_CLAIM_INDEX = "idx_backup_jobs_uploading_claim"
        const val QUEUED_UPLOAD_CLAIM_INDEX = "idx_backup_jobs_queued_upload_claim"
        const val UPLOADING_CLAIM_SELECTION =
            "local_deleted_at IS NULL AND state = 'uploading'"
        const val QUEUED_UPLOAD_CLAIM_SELECTION =
            "local_deleted_at IS NULL AND (state = 'pending' OR " +
                "(state = 'paused' AND failure_kind IN " +
                "('offline_or_timeout', 'temporary_service', 'storage_unavailable')))"
        const val UPLOAD_CLAIM_ORDER = "updated_revision ASC, id ASC"
        val SUMMARY_COUNTER_KEYS = listOf(
            "summary_total_count",
            "summary_pending_count",
            "summary_uploading_count",
            "summary_paused_count",
            "summary_completed_count",
            "summary_failed_count",
            "summary_waiting_cleanup_count",
            "summary_local_deleted_count",
            "summary_unfinished_uploaded_bytes",
            "summary_unfinished_total_bytes",
        )
        private const val MIGRATION_PREFS = "lan_backup_migration"
        private const val MIGRATION_DONE_KEY = "legacy_files_migrated"

        val COLUMNS = listOf(
            "id",
            "generation",
            "file_path",
            "file_name",
            "destination_computer_id",
            "state",
            "uploaded_bytes",
            "total_bytes",
            "last_modified",
            "file_created_at",
            "backup_completed_at",
            "scheduled_cleanup_at",
            "local_deleted_at",
            "waiting_cleanup",
            "remote_record_id",
            "content_sha256",
            "verification_version",
            "verification_receipt",
            "last_attested_at",
            "cleanup_reason",
            "error_message",
            "failure_kind",
            "sessions",
            "updated_revision",
        )

        private val migrationLock = Any()

        private const val CREATE_TABLE = """
            CREATE TABLE backup_jobs (
                id TEXT PRIMARY KEY,
                generation TEXT NOT NULL,
                file_path TEXT NOT NULL,
                file_name TEXT,
                destination_computer_id TEXT,
                state TEXT NOT NULL,
                uploaded_bytes INTEGER NOT NULL DEFAULT 0,
                total_bytes INTEGER NOT NULL DEFAULT 0,
                last_modified INTEGER NOT NULL DEFAULT 0,
                file_created_at TEXT,
                backup_completed_at TEXT,
                scheduled_cleanup_at TEXT,
                local_deleted_at TEXT,
                waiting_cleanup INTEGER NOT NULL DEFAULT 0,
                remote_record_id INTEGER,
                content_sha256 TEXT,
                verification_version INTEGER NOT NULL DEFAULT 0,
                verification_receipt TEXT,
                last_attested_at TEXT,
                cleanup_reason TEXT,
                error_message TEXT,
                failure_kind TEXT,
                sessions TEXT,
                updated_revision INTEGER NOT NULL DEFAULT 0
            )
        """

        private const val CREATE_META_TABLE = """
            CREATE TABLE backup_meta (
                key TEXT PRIMARY KEY,
                int_value INTEGER NOT NULL
            )
        """

        private const val CREATE_CLEANUP_EVENTS_TABLE = """
            CREATE TABLE backup_cleanup_events (
                revision INTEGER PRIMARY KEY,
                event_id TEXT NOT NULL UNIQUE,
                job_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                file_size_bytes INTEGER NOT NULL,
                deleted_at_ms INTEGER NOT NULL,
                reason TEXT NOT NULL
            )
        """
    }

    override fun onConfigure(db: SQLiteDatabase) {
        super.onConfigure(db)
        db.setForeignKeyConstraintsEnabled(true)
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(CREATE_TABLE)
        createRevisionSchema(db)
    }

    override fun onOpen(db: SQLiteDatabase) {
        super.onOpen(db)
        db.enableWriteAheadLogging()
        migrateLegacyFilesIfNeeded(db)
        ensureSummaryCounters(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE $TABLE ADD COLUMN remote_record_id INTEGER")
            db.rawQuery("SELECT id, remote_record_ids FROM $TABLE", null).use { cursor ->
                while (cursor.moveToNext()) {
                    val legacy = cursor.getString(1)?.let {
                        runCatching { org.json.JSONArray(it) }.getOrNull()
                    }
                    val recordId = legacy?.optLong(0)?.takeIf { it > 0 } ?: continue
                    db.execSQL(
                        "UPDATE $TABLE SET remote_record_id = ? WHERE id = ?",
                        arrayOf(recordId, cursor.getString(0)),
                    )
                }
            }
        }
        if (oldVersion < 3) {
            db.execSQL("ALTER TABLE $TABLE ADD COLUMN updated_revision INTEGER NOT NULL DEFAULT 0")
            createRevisionSchema(db)
            seedLegacyCleanupEvents(db)
        }
        if (oldVersion < 4) {
            createBoundedRecoveryIndexes(db)
        }
        if (oldVersion < 5) {
            createFairUploadClaimIndexes(db)
        }
    }

    private fun createRevisionSchema(db: SQLiteDatabase) {
        db.execSQL(CREATE_META_TABLE.replace("CREATE TABLE", "CREATE TABLE IF NOT EXISTS"))
        db.execSQL(CREATE_CLEANUP_EVENTS_TABLE.replace("CREATE TABLE", "CREATE TABLE IF NOT EXISTS"))
        db.execSQL("INSERT OR IGNORE INTO $META_TABLE(key, int_value) VALUES('revision', 0)")
        db.execSQL("INSERT OR IGNORE INTO $META_TABLE(key, int_value) VALUES('completed_revision', 0)")
        db.execSQL("INSERT OR IGNORE INTO $META_TABLE(key, int_value) VALUES('cleanup_high_watermark', 0)")
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_backup_jobs_state_revision " +
                "ON $TABLE(state, updated_revision DESC)",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_backup_jobs_destination_state " +
                "ON $TABLE(destination_computer_id, state)",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_backup_jobs_cleanup_due " +
                "ON $TABLE(local_deleted_at, scheduled_cleanup_at)",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_backup_jobs_waiting_cleanup " +
                "ON $TABLE(waiting_cleanup, state)",
        )
        createBoundedRecoveryIndexes(db)
        createFairUploadClaimIndexes(db)
    }

    private fun createBoundedRecoveryIndexes(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_backup_jobs_state_id ON $TABLE(state, id)",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_backup_jobs_bounded_scan " +
                "ON $TABLE(id, state, local_deleted_at)",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_backup_jobs_storage_recovery " +
                "ON $TABLE(" +
                "state, local_deleted_at, " +
                "COALESCE(file_created_at, '9999-12-31T23:59:59Z'), id)",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_backup_jobs_failure_revision " +
                "ON $TABLE(state, failure_kind, updated_revision DESC)",
        )
    }

    private fun createFairUploadClaimIndexes(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS $UPLOADING_CLAIM_INDEX " +
                "ON $TABLE(updated_revision ASC, id ASC) " +
                "WHERE $UPLOADING_CLAIM_SELECTION",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS $QUEUED_UPLOAD_CLAIM_INDEX " +
                "ON $TABLE(updated_revision ASC, id ASC) " +
                "WHERE $QUEUED_UPLOAD_CLAIM_SELECTION",
        )
    }

    /**
     * 旧库只在首次打开时聚合播种一次；初始化标记最后与计数一并提交，
     * 中途退出会整体回滚，下次可安全重试，且不改写任何任务行。
     */
    private fun ensureSummaryCounters(db: SQLiteDatabase) {
        val initialized = db.rawQuery(
            "SELECT int_value FROM $META_TABLE WHERE key = ?",
            arrayOf(SUMMARY_COUNTERS_INITIALIZED),
        ).use { cursor -> cursor.moveToFirst() && cursor.getLong(0) == 1L }
        if (initialized) return
        db.beginTransaction()
        try {
            val values = db.rawQuery(
                """
                SELECT COUNT(*),
                       SUM(CASE WHEN state = 'pending' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN state = 'uploading' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN state = 'paused' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN state = 'completed' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN state = 'failed' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN waiting_cleanup != 0 THEN 1 ELSE 0 END),
                       SUM(CASE WHEN local_deleted_at IS NOT NULL THEN 1 ELSE 0 END),
                       SUM(CASE WHEN state != 'completed' THEN uploaded_bytes ELSE 0 END),
                       SUM(CASE WHEN state != 'completed' THEN total_bytes ELSE 0 END)
                  FROM $TABLE
                """.trimIndent(),
                null,
            ).use { cursor ->
                cursor.moveToFirst()
                LongArray(SUMMARY_COUNTER_KEYS.size) { index ->
                    if (cursor.isNull(index)) 0L else cursor.getLong(index)
                }
            }
            SUMMARY_COUNTER_KEYS.forEachIndexed { index, key ->
                db.execSQL(
                    "INSERT OR REPLACE INTO $META_TABLE(key, int_value) VALUES(?, ?)",
                    arrayOf<Any?>(key, values[index]),
                )
            }
            db.execSQL(
                "INSERT OR REPLACE INTO $META_TABLE(key, int_value) VALUES(?, 1)",
                arrayOf(SUMMARY_COUNTERS_INITIALIZED),
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /** v2 已清理任务也必须进入 outbox，避免升级后丢失本地删除审计。 */
    private fun seedLegacyCleanupEvents(db: SQLiteDatabase) {
        var revision = 0L
        db.query(
            TABLE,
            arrayOf(
                "id",
                "generation",
                "file_path",
                "total_bytes",
                "local_deleted_at",
                "cleanup_reason",
            ),
            "local_deleted_at IS NOT NULL",
            null,
            null,
            null,
            "last_modified ASC, id ASC",
        ).use { cursor ->
            while (cursor.moveToNext()) {
                val deletedAtMs = runCatching {
                    Instant.parse(cursor.getString(4)).toEpochMilli()
                }.getOrNull() ?: continue
                revision++
                val id = cursor.getString(0)
                val generation = cursor.getString(1)
                db.execSQL(
                    "UPDATE $TABLE SET updated_revision = ? WHERE id = ?",
                    arrayOf(revision, id),
                )
                db.execSQL(
                    """
                    INSERT OR IGNORE INTO $CLEANUP_EVENTS_TABLE
                        (revision, event_id, job_id, file_path, file_size_bytes, deleted_at_ms, reason)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """.trimIndent(),
                    arrayOf(
                        revision,
                        "cleanup:$id:$generation",
                        id,
                        cursor.getString(2),
                        cursor.getLong(3),
                        deletedAtMs,
                        cursor.getString(5).orEmpty(),
                    ),
                )
            }
        }
        if (revision > 0) {
            db.execSQL(
                "UPDATE $META_TABLE SET int_value = ? WHERE key = 'revision'",
                arrayOf(revision),
            )
            db.execSQL(
                "UPDATE $META_TABLE SET int_value = ? WHERE key = 'completed_revision'",
                arrayOf(revision),
            )
            db.execSQL(
                "UPDATE $META_TABLE SET int_value = ? WHERE key = 'cleanup_high_watermark'",
                arrayOf(revision),
            )
        }
    }

    /** 旧版任务文件一次性导入；带锁且以 SharedPreferences 标记保证只执行一次。 */
    private fun migrateLegacyFilesIfNeeded(db: SQLiteDatabase) {
        val prefs = context.getSharedPreferences(MIGRATION_PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(MIGRATION_DONE_KEY, false)) return
        synchronized(migrationLock) {
            if (prefs.getBoolean(MIGRATION_DONE_KEY, false)) return
            val legacyDir = File(context.filesDir, "lan_backup/jobs")
            val files = legacyDir.listFiles { file ->
                file.name.endsWith(".json") || file.name.endsWith(".json.bak")
            }?.toList().orEmpty()
            if (files.isEmpty()) {
                prefs.edit().putBoolean(MIGRATION_DONE_KEY, true).apply()
                return
            }
            for (file in files.sortedBy { it.name }) {
                val id = file.name.removeSuffix(".bak").removeSuffix(".json")
                val job = runCatching {
                    AtomicFile(file).openRead().bufferedReader(Charsets.UTF_8).use { reader ->
                        JSONObject(reader.readText())
                    }
                }.getOrNull() ?: continue
                if (job.optString("id") != id) continue
                if (listOf("generation", "filePath", "state").any {
                        job.optString(it).isBlank()
                    }
                ) {
                    continue
                }
                val row = runCatching { lanBackupJobToRow(job) }.getOrNull() ?: continue
                val represented = db.query(
                    TABLE,
                    arrayOf("generation", "file_path"),
                    "id = ?",
                    arrayOf(id),
                    null,
                    null,
                    null,
                    "1",
                ).use { cursor ->
                    cursor.moveToFirst() &&
                        cursor.getString(0) == row["generation"] &&
                        cursor.getString(1) == row["file_path"]
                }
                val persisted = represented || runCatching {
                    var inserted = false
                    db.beginTransaction()
                    try {
                        inserted = db.insertWithOnConflict(
                            TABLE,
                            null,
                            row.toContentValues(),
                            SQLiteDatabase.CONFLICT_IGNORE,
                        ) != -1L
                        if (inserted) {
                            db.delete(
                                META_TABLE,
                                "key = ?",
                                arrayOf(SUMMARY_COUNTERS_INITIALIZED),
                            )
                        }
                        db.setTransactionSuccessful()
                    } finally {
                        db.endTransaction()
                    }
                    inserted && db.query(
                        TABLE,
                        arrayOf("generation", "file_path"),
                        "id = ?",
                        arrayOf(id),
                        null,
                        null,
                        null,
                        "1",
                    ).use { cursor ->
                        cursor.moveToFirst() &&
                            cursor.getString(0) == row["generation"] &&
                            cursor.getString(1) == row["file_path"]
                    }
                }.getOrDefault(false)
                if (persisted) runCatching { file.delete() }
            }
            val remaining = legacyDir.listFiles { file ->
                file.name.endsWith(".json") || file.name.endsWith(".json.bak")
            }.orEmpty()
            if (remaining.isEmpty()) {
                legacyDir.delete()
                prefs.edit().putBoolean(MIGRATION_DONE_KEY, true).apply()
            } else {
                prefs.edit().remove(MIGRATION_DONE_KEY).apply()
            }
        }
    }
}
