package app.packingproof.mobile

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.provider.Settings
import android.os.SystemClock
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import app.packingproof.mobile.generated.BackupCleanupEventDto
import app.packingproof.mobile.generated.BackupCleanupPageDto
import app.packingproof.mobile.generated.BackupJobsByPathsDto
import app.packingproof.mobile.generated.BackupSummaryDto

internal object LanBackupRevisionNotifier {
    data class Notice(val revision: Long, val immediate: Boolean)

    private val listeners = linkedSetOf<(Notice) -> Unit>()
    private val progressLock = Any()
    private val progressScheduler = Executors.newSingleThreadScheduledExecutor()
    private var pendingProgressRevision = 0L
    private var lastProgressDispatchAtMs = 0L
    private var progressFuture: ScheduledFuture<*>? = null
    private const val PROGRESS_INTERVAL_MS = 1_000L

    fun addListener(listener: (Notice) -> Unit) = synchronized(listeners) {
        listeners.add(listener)
    }

    fun removeListener(listener: (Notice) -> Unit) = synchronized(listeners) {
        listeners.remove(listener)
    }

    fun publish(revision: Long, immediate: Boolean = true) {
        if (immediate) {
            synchronized(progressLock) {
                progressFuture?.cancel(false)
                progressFuture = null
                pendingProgressRevision = 0L
                lastProgressDispatchAtMs = SystemClock.elapsedRealtime()
            }
            dispatch(Notice(revision = revision, immediate = true))
            return
        }
        synchronized(progressLock) {
            pendingProgressRevision = maxOf(pendingProgressRevision, revision)
            if (progressFuture != null) return
            val elapsed = SystemClock.elapsedRealtime() - lastProgressDispatchAtMs
            val delay = (PROGRESS_INTERVAL_MS - elapsed).coerceAtLeast(0L)
            progressFuture = progressScheduler.schedule(
                {
                    val latest = synchronized(progressLock) {
                        progressFuture = null
                        lastProgressDispatchAtMs = SystemClock.elapsedRealtime()
                        pendingProgressRevision.also { pendingProgressRevision = 0L }
                    }
                    if (latest > 0L) {
                        dispatch(Notice(revision = latest, immediate = false))
                    }
                },
                delay,
                TimeUnit.MILLISECONDS,
            )
        }
    }

    private fun dispatch(notice: Notice) {
        val snapshot = synchronized(listeners) { listeners.toList() }
        snapshot.forEach { it(notice) }
    }
}

internal data class LanBackupConnectionMigration(
    val computerId: String,
    val computerName: String,
)

internal data class LanBackupUpsertResult(
    val job: JSONObject,
    val recreated: Boolean,
)

internal data class LanBackupStorageJobPage(
    val jobs: List<JSONObject>,
    val nextCreatedAtKey: String?,
    val nextId: String?,
)

internal enum class RecordingStorageReclaimResult { deleted, missing, stale, failed, rejected }

internal data class RecordingStorageReclaimOutcome(
    val result: RecordingStorageReclaimResult,
    val jobChanged: Boolean,
)

internal fun planLanBackupConnectionMigration(
    schemaVersion: Int,
    computerId: String?,
    computerName: String?,
): LanBackupConnectionMigration? = if (schemaVersion >= 1) {
    null
} else {
    LanBackupConnectionMigration(
        computerId = computerId.orEmpty().trim(),
        computerName = computerName.orEmpty().trim(),
    )
}

internal class LanBackupStateStore(
    private val context: Context,
    private val backupCredential: () -> String? = { LanBackupCredentialStore(context).load() },
) : AutoCloseable {
    companion object {
        private const val CONNECTION_SCHEMA_VERSION = 1
        private const val PREFS = "lan_backup_connection"
        private const val RETENTION_PREFS = "lan_backup_retention"
        private const val DEVICE_PREFS = "lan_backup_device"
        private const val TAG = "PackingProofBackup"
        private val jobIoLock = Any()
        private val dominantFailurePriority = listOf(
            "credential_invalid",
            "not_backup_host",
            "incompatible_version",
            "verification_failed",
            "storage_unavailable",
            "upload_expired",
            "temporary_service",
            "offline_or_timeout",
            "unknown",
        )

        fun stableId(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

        fun stableDeviceId(androidId: String?, packageName: String): String? {
            val normalizedAndroidId = androidId?.trim()?.lowercase().orEmpty()
            if (normalizedAndroidId.isBlank() ||
                normalizedAndroidId == "9774d56d682e549c"
            ) {
                return null
            }
            return "android-${stableId("$packageName:$normalizedAndroidId")}"
        }

        fun deviceDisplayName(deviceId: String): String {
            return "本机"
        }

        fun <T> withJobLock(action: () -> T): T = synchronized(jobIoLock, action)
    }

    private val database = LanBackupJobDatabase(context)
    private val db: SQLiteDatabase
        get() = database.writableDatabase
    private val jobDtoColumns = (LAN_BACKUP_SNAPSHOT_COLUMNS + "updated_revision").distinct()

    override fun close() {
        database.close()
    }

    fun saveConnection(
        baseUrl: String,
        computerId: String,
        computerName: String,
        deviceName: String = "",
        supportsUploadVideoCodec: Boolean = false,
    ) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putInt("schemaVersion", CONNECTION_SCHEMA_VERSION)
            .putString("baseUrl", baseUrl)
            .putString("computerId", computerId)
            .putString("computerName", computerName)
            .putBoolean("supportsUploadVideoCodec", supportsUploadVideoCodec)
            .putString("lastConnectedAt", Instant.now().toString())
            .apply()
        if (deviceName.isNotBlank()) {
            context.getSharedPreferences(DEVICE_PREFS, Context.MODE_PRIVATE).edit()
                .putString("name", deviceName.trim())
                .apply()
        }
        bumpRevision()
    }

    fun connection(): JSONObject? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val baseUrl = prefs.getString("baseUrl", null) ?: return null
        return JSONObject()
            .put("baseUrl", baseUrl)
            .put("computerId", prefs.getString("computerId", "") ?: "")
            .put("computerName", prefs.getString("computerName", "已连接电脑") ?: "已连接电脑")
            .put("supportsUploadVideoCodec", prefs.getBoolean("supportsUploadVideoCodec", false))
            .put("lastConnectedAt", prefs.getString("lastConnectedAt", "") ?: "")
    }

    fun clearConnection() {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        bumpRevision()
    }

    fun migrateLegacyConnection(): JSONObject? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val migration = planLanBackupConnectionMigration(
            prefs.getInt("schemaVersion", 0),
            prefs.getString("computerId", ""),
            prefs.getString("computerName", ""),
        ) ?: return null
        prefs.edit()
            .clear()
            .putInt("schemaVersion", CONNECTION_SCHEMA_VERSION)
            .putString("migrationComputerId", migration.computerId)
            .putString("migrationComputerName", migration.computerName)
            .apply()
        bumpRevision()
        return JSONObject()
            .put("migrated", true)
            .put("computerId", migration.computerId)
            .put("computerName", migration.computerName)
    }

    fun migrationHint(): JSONObject? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val computerId = prefs.getString("migrationComputerId", "").orEmpty().trim()
        val computerName = prefs.getString("migrationComputerName", "").orEmpty().trim()
        if (computerId.isEmpty() && computerName.isEmpty()) return null
        return JSONObject().put("computerId", computerId).put("computerName", computerName)
    }

    fun clearMigrationHint() {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove("migrationComputerId")
            .remove("migrationComputerName")
            .apply()
        bumpRevision()
    }

    fun retargetJobs(computerId: String) {
        var afterId: String? = null
        var page: List<String>
        do {
            page = unfinishedJobIdsPage(afterId)
            page.forEach { id -> retargetJob(id, computerId) }
            afterId = page.lastOrNull()
        } while (page.size == 100)
    }

    fun recoverIncompatibleFailures(computerId: String): Int = withJobLock {
        val destination = computerId.trim()
        if (destination.isEmpty()) return@withJobLock 0
        val selection =
            "destination_computer_id = ? AND state = 'failed' AND failure_kind = ?"
        val arguments = arrayOf(
            destination,
            LanBackupFailureKind.INCOMPATIBLE_VERSION.wireValue,
        )
        val count = db.rawQuery(
            "SELECT COUNT(*) FROM ${LanBackupJobDatabase.TABLE} WHERE $selection",
            arguments,
        ).use { cursor -> if (cursor.moveToFirst()) cursor.getInt(0) else 0 }
        if (count == 0) return@withJobLock 0

        var revision = 0L
        db.beginTransaction()
        try {
            revision = nextRevisionUnlocked()
            db.execSQL(
                "UPDATE ${LanBackupJobDatabase.TABLE} " +
                    "SET state = 'pending', error_message = NULL, failure_kind = NULL, " +
                    "updated_revision = ? WHERE $selection",
                arrayOf<Any?>(revision, *arguments),
            )
            setMetaValueUnlocked(
                "summary_pending_count",
                metaValueUnlocked("summary_pending_count") + count,
            )
            setMetaValueUnlocked(
                "summary_failed_count",
                metaValueUnlocked("summary_failed_count") - count,
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        LanBackupRevisionNotifier.publish(revision)
        count
    }

    private fun retargetJob(id: String, computerId: String) = withJobLock {
            val job = readJobUnlocked(id) ?: return@withJobLock
            if (job.optString("state") == "completed") return@withJobLock
            val sameComputer = job.optString("destinationComputerId") == computerId
            val repairsConnectionFailure = job.optString("failureKind") in setOf(
                LanBackupFailureKind.CREDENTIAL_INVALID.wireValue,
                LanBackupFailureKind.NOT_BACKUP_HOST.wireValue,
                LanBackupFailureKind.INCOMPATIBLE_VERSION.wireValue,
            )
            if (sameComputer && !repairsConnectionFailure) return@withJobLock
            val file = File(job.optString("filePath"))
            if (!file.exists()) return@withJobLock
            job.put("state", "pending")
                .put("generation", UUID.randomUUID().toString())
                .put("errorMessage", JSONObject.NULL)
                .put("failureKind", JSONObject.NULL)
            if (!sameComputer) {
                job.put("destinationComputerId", computerId)
                    .put("uploadedBytes", 0L)
                    .put("backupCompletedAt", JSONObject.NULL)
                    .put("contentSha256", JSONObject.NULL)
                    .put("remoteRecordId", JSONObject.NULL)
            }
            writeJobUnlocked(job)
    }

    fun upsertJob(filePath: String, sessions: JSONArray): LanBackupUpsertResult = withJobLock {
        require(sessions.length() == 1) {
            "每个备份任务必须且只能包含一条录像记录"
        }
        val file = File(filePath)
        val id = stableId(file.canonicalPath)
        val existing = readJobUnlocked(id)
        val destinationComputerId = connection()?.optString("computerId").orEmpty()
        val sourceSessionId = sessions.getJSONObject(0).getString("id")
        val existingSessions = existing?.optJSONArray("sessions")
        val sameSession = existingSessions?.length() == 1 &&
            existingSessions.getJSONObject(0).optString("id") == sourceSessionId
        if (existing != null &&
            sameSession &&
            existing.optLong("totalBytes") == file.length() &&
            existing.optLong("lastModified") == file.lastModified() &&
            existing.optString("destinationComputerId") == destinationComputerId
        ) {
            existing.put("filePath", file.absolutePath)
            existing.put("sessions", sessions)
            if (!existing.has("fileCreatedAt")) {
                existing.put("fileCreatedAt", Instant.ofEpochMilli(file.lastModified()).toString())
            }
            if (!existing.has("backupCompletedAt")) existing.put("backupCompletedAt", JSONObject.NULL)
            if (!existing.has("scheduledCleanupAt")) existing.put("scheduledCleanupAt", JSONObject.NULL)
            if (!existing.has("localDeletedAt")) existing.put("localDeletedAt", JSONObject.NULL)
            if (!existing.has("waitingCleanup")) existing.put("waitingCleanup", false)
            if (!existing.has("remoteRecordId")) {
                val legacyRecordId = existing.optJSONArray("remoteRecordIds")
                    ?.optLong(0)
                    ?.takeIf { it > 0 }
                existing.put("remoteRecordId", legacyRecordId ?: JSONObject.NULL)
                existing.remove("remoteRecordIds")
            }
            if (!existing.has("contentSha256")) existing.put("contentSha256", JSONObject.NULL)
            if (!existing.has("verificationVersion")) existing.put("verificationVersion", 0)
            if (!existing.has("verificationReceipt")) existing.put("verificationReceipt", JSONObject.NULL)
            if (!existing.has("lastAttestedAt")) existing.put("lastAttestedAt", JSONObject.NULL)
            if (!existing.has("cleanupReason")) existing.put("cleanupReason", JSONObject.NULL)
            if (!existing.has("failureKind")) existing.put("failureKind", JSONObject.NULL)
            if (existing.optString("generation").isBlank()) {
                existing.put("generation", UUID.randomUUID().toString())
            }
            writeJobUnlocked(existing)
            return@withJobLock LanBackupUpsertResult(existing, recreated = false)
        }
        val job = JSONObject()
            .put("id", id)
            .put("generation", UUID.randomUUID().toString())
            .put("filePath", file.absolutePath)
            .put("fileName", file.name)
            .put("destinationComputerId", destinationComputerId)
            .put("state", "pending")
            .put("uploadedBytes", 0L)
            .put("totalBytes", file.length())
            .put("lastModified", file.lastModified())
            .put("fileCreatedAt", Instant.ofEpochMilli(file.lastModified()).toString())
            .put("backupCompletedAt", JSONObject.NULL)
            .put("scheduledCleanupAt", JSONObject.NULL)
            .put("localDeletedAt", JSONObject.NULL)
            .put("waitingCleanup", false)
            .put("remoteRecordId", JSONObject.NULL)
            .put("contentSha256", JSONObject.NULL)
            .put("verificationVersion", 0)
            .put("verificationReceipt", JSONObject.NULL)
            .put("lastAttestedAt", JSONObject.NULL)
            .put("cleanupReason", JSONObject.NULL)
            .put("errorMessage", JSONObject.NULL)
            .put("failureKind", JSONObject.NULL)
            .put("sessions", sessions)
        writeJobUnlocked(job)
        LanBackupUpsertResult(job, recreated = true)
    }

    fun readJob(id: String): JSONObject? = withJobLock { readJobUnlocked(id) }

    fun writeJob(job: JSONObject) = withJobLock { writeJobUnlocked(job) }

    fun updateJob(
        id: String,
        expectedGeneration: String? = null,
        update: (JSONObject) -> Boolean,
    ): JSONObject? = withJobLock {
        val job = readJobUnlocked(id) ?: return@withJobLock null
        if (expectedGeneration != null && job.optString("generation") != expectedGeneration) {
            return@withJobLock null
        }
        if (!update(job)) return@withJobLock null
        writeJobUnlocked(job)
        JSONObject(job.toString())
    }

    fun summary(): BackupSummaryDto = withJobLock {
        val connection = connection()
        val migration = migrationHint()
        val totals = LanBackupJobDatabase.SUMMARY_COUNTER_KEYS
            .map(::metaValueUnlocked)
        val activeJob = representativeJobUnlocked(
            "state = 'uploading'",
            "updated_revision DESC",
        ) ?: representativeJobUnlocked("state = 'pending'", "updated_revision DESC")
        val problemJob = dominantFailurePriority.asSequence()
            .mapNotNull { failureKind ->
                representativeJobUnlocked(
                    "state = 'failed' AND failure_kind = ?",
                    "updated_revision DESC",
                    arrayOf(failureKind),
                )
            }
            .firstOrNull()
            ?: representativeJobUnlocked("state = 'failed'", "updated_revision DESC")
            ?: representativeJobUnlocked("state = 'paused'", "updated_revision DESC")
        BackupSummaryDto(
            schemaVersion = 1L,
            revision = metaValueUnlocked("revision"),
            completedRevision = metaValueUnlocked("completed_revision"),
            cleanupHighWatermark = metaValueUnlocked("cleanup_high_watermark"),
            deviceId = deviceId(),
            deviceName = deviceName(),
            baseUrl = connection?.optString("baseUrl")?.takeIf { it.isNotBlank() },
            computerId = connection?.optString("computerId")?.takeIf { it.isNotBlank() },
            computerName = connection?.optString("computerName")?.takeIf { it.isNotBlank() },
            lastConnectedAtMs = connection?.optString("lastConnectedAt")?.let {
                runCatching { Instant.parse(it).toEpochMilli() }.getOrNull()
            },
            preferredHostId = migration?.optString("computerId")?.takeIf { it.isNotBlank() },
            preferredHostName = migration?.optString("computerName")?.takeIf { it.isNotBlank() },
            totalCount = totals[0],
            pendingCount = totals[1],
            uploadingCount = totals[2],
            pausedCount = totals[3],
            completedCount = totals[4],
            failedCount = totals[5],
            waitingCleanupCount = totals[6],
            localDeletedCount = totals[7],
            unfinishedUploadedBytes = totals[8],
            unfinishedTotalBytes = totals[9],
            dominantFailureKind = problemJob
                ?.takeIf { it.state == "failed" }
                ?.failureKind,
            activeJob = activeJob,
            problemJob = problemJob,
        )
    }

    fun jobsForPaths(paths: List<String>): BackupJobsByPathsDto = withJobLock {
        require(paths.size <= 100) { "单次最多查询 100 个录像路径" }
        val canonicalPaths = paths.map { File(it).canonicalPath }.distinct()
        if (canonicalPaths.isEmpty()) {
            return@withJobLock BackupJobsByPathsDto(
                revision = metaValueUnlocked("revision"),
                jobs = emptyList(),
                missingPaths = emptyList(),
            )
        }
        val idsByPath = canonicalPaths.associateBy(::stableId)
        val placeholders = List(idsByPath.size) { "?" }.joinToString(",")
        val rows = db.query(
            LanBackupJobDatabase.TABLE,
            jobDtoColumns.toTypedArray(),
            "id IN ($placeholders)",
            idsByPath.keys.toTypedArray(),
            null,
            null,
            null,
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(cursor.toRowMap(jobDtoColumns))
            }
        }
        val foundIds = rows.mapTo(mutableSetOf()) { it["id"] as String }
        BackupJobsByPathsDto(
            revision = metaValueUnlocked("revision"),
            jobs = rows.map(::lanBackupRowToDto),
            missingPaths = idsByPath.filterKeys { it !in foundIds }.values.toList(),
        )
    }

    fun cleanupEvents(afterRevision: Long, limit: Int): BackupCleanupPageDto = withJobLock {
        require(afterRevision >= 0) { "清理事件游标不能为负数" }
        require(limit in 1..100) { "清理事件单页数量必须为 1 到 100" }
        val events = db.query(
            LanBackupJobDatabase.CLEANUP_EVENTS_TABLE,
            arrayOf("revision", "event_id", "job_id", "file_path", "file_size_bytes", "deleted_at_ms", "reason"),
            "revision > ?",
            arrayOf(afterRevision.toString()),
            null,
            null,
            "revision ASC",
            (limit + 1).toString(),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(
                        BackupCleanupEventDto(
                            revision = cursor.getLong(0),
                            eventId = cursor.getString(1),
                            jobId = cursor.getString(2),
                            filePath = cursor.getString(3),
                            fileSizeBytes = cursor.getLong(4),
                            deletedAtMs = cursor.getLong(5),
                            reason = cursor.getString(6),
                        ),
                    )
                }
            }
        }
        val page = events.take(limit)
        BackupCleanupPageDto(
            latestRevision = metaValueUnlocked("cleanup_high_watermark"),
            nextAfterRevision = page.lastOrNull()?.revision ?: afterRevision,
            hasMore = events.size > limit,
            events = page,
        )
    }

    fun acknowledgeCleanupEvents(throughRevision: Long) = withJobLock {
        require(throughRevision >= 0) { "清理事件确认游标不能为负数" }
        db.delete(
            LanBackupJobDatabase.CLEANUP_EVENTS_TABLE,
            "revision <= ?",
            arrayOf(throughRevision.toString()),
        )
    }

    fun hasPendingJobsOutsideDestination(computerId: String): Boolean = withJobLock {
        db.rawQuery(
            "SELECT 1 FROM ${LanBackupJobDatabase.TABLE} " +
                "WHERE state != 'completed' AND COALESCE(destination_computer_id, '') != ? LIMIT 1",
            arrayOf(computerId),
        ).use { it.moveToFirst() }
    }

    fun pendingJobIdsPage(afterId: String?, limit: Int = 100): List<String> = withJobLock {
        require(limit in 1..100) { "备份排程单页数量必须为 1 到 100" }
        jobIdsPageUnlocked(
            whereClause = "state IN ('pending', 'paused', 'uploading')",
            afterId = afterId,
            limit = limit,
        )
    }

    fun claimNextUploadJob(): JSONObject? = withJobLock {
        fun oldest(selection: String, indexName: String): JSONObject? = db.query(
            "${LanBackupJobDatabase.TABLE} INDEXED BY $indexName",
            LanBackupJobDatabase.COLUMNS.toTypedArray(),
            selection,
            null,
            null,
            null,
            LanBackupJobDatabase.UPLOAD_CLAIM_ORDER,
            "1",
        ).use { cursor ->
            if (!cursor.moveToFirst()) {
                null
            } else {
                lanBackupRowToJob(cursor.toRowMap(LanBackupJobDatabase.COLUMNS))
            }
        }
        // 先恢复唯一的中断上传，避免连续崩溃把多条任务都留在 uploading；
        // 其余 pending/可重试 paused 严格按首次排队 revision 领取，持续新增
        // 任务不会插队，也不会使用 OFFSET 或把整个队列加载进内存。
        val job = oldest(
            LanBackupJobDatabase.UPLOADING_CLAIM_SELECTION,
            LanBackupJobDatabase.UPLOADING_CLAIM_INDEX,
        ) ?: oldest(
            LanBackupJobDatabase.QUEUED_UPLOAD_CLAIM_SELECTION,
            LanBackupJobDatabase.QUEUED_UPLOAD_CLAIM_INDEX,
        )
            ?: return@withJobLock null
        job.put("state", "uploading")
            .put("errorMessage", JSONObject.NULL)
            .put("failureKind", JSONObject.NULL)
        writeJobUnlocked(job)
        JSONObject(job.toString())
    }

    fun cleanupSchedulingJobIdsPage(afterId: String?, limit: Int = 100): List<String> =
        withJobLock {
            require(limit in 1..100) { "清理排程单页数量必须为 1 到 100" }
            jobIdsPageUnlocked(
                whereClause = "local_deleted_at IS NULL",
                afterId = afterId,
                limit = limit,
            )
        }

    fun nextScheduledCleanupJob(): JSONObject? = withJobLock {
        db.query(
            LanBackupJobDatabase.TABLE,
            LanBackupJobDatabase.COLUMNS.toTypedArray(),
            "local_deleted_at IS NULL AND scheduled_cleanup_at IS NOT NULL",
            null,
            null,
            null,
            "scheduled_cleanup_at ASC, id ASC",
            "1",
        ).use { cursor ->
            if (cursor.moveToFirst()) {
                lanBackupRowToJob(cursor.toRowMap(LanBackupJobDatabase.COLUMNS))
            } else {
                null
            }
        }
    }

    fun unfinishedJobIdsPage(afterId: String?, limit: Int = 100): List<String> =
        withJobLock {
            require(limit in 1..100) { "失效任务检查单页数量必须为 1 到 100" }
            jobIdsPageUnlocked(
                whereClause = "state != 'completed'",
                afterId = afterId,
                limit = limit,
            )
        }

    fun storageRecoveryJobsPage(
        afterCreatedAtKey: String?,
        afterId: String?,
        limit: Int = 100,
    ): LanBackupStorageJobPage = withJobLock {
        require(limit in 1..100) { "空间回收单页数量必须为 1 到 100" }
        require((afterCreatedAtKey == null) == (afterId == null)) { "空间回收游标必须完整" }
        val createdAtExpression = "COALESCE(file_created_at, '9999-12-31T23:59:59Z')"
        val selection = buildString {
            append("state = 'completed' AND backup_completed_at IS NOT NULL ")
            append("AND content_sha256 IS NOT NULL AND content_sha256 != '' ")
            append("AND verification_version >= ? AND verification_receipt IS NOT NULL ")
            append("AND verification_receipt != '' AND remote_record_id IS NOT NULL ")
            append("AND total_bytes > 0 AND last_modified > 0 AND last_attested_at IS NOT NULL ")
            append("AND local_deleted_at IS NULL")
            if (afterCreatedAtKey != null) {
                append(" AND ($createdAtExpression > ? OR ($createdAtExpression = ? AND id > ?))")
            }
        }
        val args = mutableListOf(BackupRequestAuthentication.VERSION.toString())
        if (afterCreatedAtKey != null && afterId != null) {
            args += afterCreatedAtKey
            args += afterCreatedAtKey
            args += afterId
        }
        val columns = LanBackupJobDatabase.COLUMNS
        val jobs = db.query(
            LanBackupJobDatabase.TABLE,
            columns.toTypedArray(),
            selection,
            args.toTypedArray(),
            null,
            null,
            "$createdAtExpression ASC, id ASC",
            limit.toString(),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(lanBackupRowToJob(cursor.toRowMap(columns)))
                }
            }
        }
        val last = jobs.lastOrNull()
        LanBackupStorageJobPage(
            jobs = jobs,
            nextCreatedAtKey = last?.let(::storageCreatedAtKey),
            nextId = last?.optString("id"),
        )
    }

    /**
     * 空间回收候选读取与文件删除之间可能发生重新入队。这里在统一 job 锁内重读，
     * 并要求 generation、文件身份和完整远端证明仍与候选快照完全一致后才删除。
     */
    fun reclaimVerifiedRecording(
        expected: RecordingStorageCandidate,
    ): RecordingStorageReclaimOutcome = withJobLock {
        val current = readJobUnlocked(expected.id)
            ?: return@withJobLock rejectedStorageReclaim()
        val actual = recordingStorageCandidate(current)
        if (actual != expected || !RecordingStoragePolicy.isVerifiedCandidate(actual)) {
            return@withJobLock rejectedStorageReclaim()
        }
        val receipt = actual.verificationReceipt
            ?: return@withJobLock rejectedStorageReclaim()
        val contentSha256 = actual.contentSha256
            ?: return@withJobLock rejectedStorageReclaim()
        val sessionId = actual.sessionIds.singleOrNull()
            ?: return@withJobLock rejectedStorageReclaim()
        val cryptographicallyVerified = runCatching {
            val credential = backupCredential()?.trim()?.takeIf { it.isNotEmpty() }
                ?: return@runCatching false
            BackupRequestAuthentication.verifyPersistedReceipt(
                response = receipt.toJson(),
                credential = BackupRequestAuthentication.parse(credential),
                hostNodeId = actual.destinationComputerId,
                sourceDeviceId = deviceId(),
                sourceSessionId = sessionId,
                fileSha256 = contentSha256,
                fileSizeBytes = actual.totalBytes,
                recordId = actual.remoteRecordId,
            )
        }.getOrDefault(false)
        if (!cryptographicallyVerified) return@withJobLock rejectedStorageReclaim()
        val file = File(actual.filePath)
        val appDataRoot = context.dataDir.canonicalFile
        val managed = runCatching {
            file.canonicalFile.path.startsWith(appDataRoot.path + File.separator)
        }.getOrDefault(false)
        if (!managed) return@withJobLock rejectedStorageReclaim()

        when (
            val result = LanBackupFileCleanup.deleteExpected(
                file = file,
                expectedBytes = actual.totalBytes,
                expectedLastModified = actual.lastModified,
                expectedSha256 = contentSha256,
            )
        ) {
            LanBackupFileCleanupResult.deleted,
            LanBackupFileCleanupResult.missing,
            -> {
                current.put("localDeletedAt", Instant.now().toString())
                    .put("scheduledCleanupAt", JSONObject.NULL)
                    .put("waitingCleanup", false)
                    .put("cleanupReason", "存储空间不足提前清理")
                    .put("errorMessage", JSONObject.NULL)
                writeJobUnlocked(current)
                RecordingStorageReclaimOutcome(
                    result = if (result == LanBackupFileCleanupResult.deleted) {
                        RecordingStorageReclaimResult.deleted
                    } else {
                        RecordingStorageReclaimResult.missing
                    },
                    jobChanged = true,
                )
            }
            LanBackupFileCleanupResult.stale -> updateStorageReclaimError(
                current,
                RecordingStorageReclaimResult.stale,
                "录像文件已被替换，已取消空间清理",
            )
            LanBackupFileCleanupResult.failed -> updateStorageReclaimError(
                current,
                RecordingStorageReclaimResult.failed,
                "空间清理失败，已保留本机录像",
            )
        }
    }

    private fun rejectedStorageReclaim() = RecordingStorageReclaimOutcome(
        result = RecordingStorageReclaimResult.rejected,
        jobChanged = false,
    )

    private fun updateStorageReclaimError(
        job: JSONObject,
        result: RecordingStorageReclaimResult,
        message: String,
    ): RecordingStorageReclaimOutcome {
        val changed = job.optString("errorMessage") != message
        if (changed) {
            job.put("errorMessage", message)
            writeJobUnlocked(job)
        }
        return RecordingStorageReclaimOutcome(result = result, jobChanged = changed)
    }

    private fun jobIdsPageUnlocked(
        whereClause: String,
        afterId: String?,
        limit: Int,
    ): List<String> {
        val selection = buildString {
            append(whereClause)
            if (afterId != null) append(" AND id > ?")
        }
        return db.query(
            LanBackupJobDatabase.TABLE,
            arrayOf("id"),
            selection,
            afterId?.let { arrayOf(it) },
            null,
            null,
            "id ASC",
            limit.toString(),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(cursor.getString(0))
            }
        }
    }

    fun reconcileUnavailableJobs() {
        var afterId: String? = null
        var page: List<String>
        do {
            page = unfinishedJobIdsPage(afterId)
            page.forEach(::reconcileJobSource)
            afterId = page.lastOrNull()
        } while (page.size == 100)
    }

    fun reconcileJobSource(id: String): LanBackupSourceStatus? = withJobLock {
        val job = readJobUnlocked(id) ?: return@withJobLock null
        if (job.optString("state") == "completed") {
            return@withJobLock LanBackupSourceStatus.AVAILABLE
        }
        val status = sourceStatus(job)
        if (status == LanBackupSourceStatus.AVAILABLE) return@withJobLock status
        val message = "${status.reason}，已保留备份任务等待录像恢复"
        if (job.optString("state") != "paused" ||
            job.optString("errorMessage") != message ||
            job.optString("failureKind") != LanBackupFailureKind.UNKNOWN.wireValue
        ) {
            job.put("state", "paused")
                .put("errorMessage", message)
                .put("failureKind", LanBackupFailureKind.UNKNOWN.wireValue)
            writeJobUnlocked(job)
            Log.w(
                TAG,
                "Preserved unavailable backup job " +
                    "id=${id.take(8)} path=${job.optString("filePath")} reason=${status.reason}",
            )
        }
        status
    }

    fun deleteJob(id: String, expectedGeneration: String): Boolean = withJobLock {
        deleteJobUnlocked(id, expectedGeneration)
    }

    private fun readJobUnlocked(id: String): JSONObject? {
        val columns = LanBackupJobDatabase.COLUMNS.toTypedArray()
        return db.query(
            LanBackupJobDatabase.TABLE,
            columns,
            "id = ?",
            arrayOf(id),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            if (cursor.moveToFirst()) {
                lanBackupRowToJob(cursor.toRowMap(LanBackupJobDatabase.COLUMNS))
            } else {
                null
            }
        }
    }

    private fun writeJobUnlocked(job: JSONObject) {
        val previous = readJobUnlocked(job.optString("id"))
        val progressOnly = isUploadProgressOnly(previous, job)
        var revision = 0L
        db.beginTransaction()
        try {
            revision = nextRevisionUnlocked()
            job.put("revision", revision)
            val row = lanBackupJobToRow(job).toContentValues()
            val updated = db.update(
                LanBackupJobDatabase.TABLE,
                row,
                "id = ?",
                arrayOf(job.getString("id")),
            )
            if (updated == 0) {
                db.insertOrThrow(LanBackupJobDatabase.TABLE, null, row)
            }
            adjustSummaryCountersUnlocked(previous, job)
            if (previous?.optString("state") == "completed" || job.optString("state") == "completed") {
                setMetaValueUnlocked("completed_revision", revision)
            }
            insertCleanupEventIfNeededUnlocked(previous, job, revision)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        LanBackupRevisionNotifier.publish(revision, immediate = !progressOnly)
    }

    private fun deleteJobUnlocked(id: String, expectedGeneration: String): Boolean {
        val current = readJobUnlocked(id) ?: return false
        if (current.optString("generation") != expectedGeneration) return false
        if (current.optString("state") == "completed") return false
        var revision = 0L
        db.beginTransaction()
        try {
            revision = nextRevisionUnlocked()
            db.delete(LanBackupJobDatabase.TABLE, "id = ?", arrayOf(id))
            adjustSummaryCountersUnlocked(current, null)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        LanBackupRevisionNotifier.publish(revision)
        return true
    }

    fun bumpRevision(): Long = withJobLock {
        var revision = 0L
        db.beginTransaction()
        try {
            revision = nextRevisionUnlocked()
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        LanBackupRevisionNotifier.publish(revision)
        revision
    }

    private fun nextRevisionUnlocked(): Long {
        val next = metaValueUnlocked("revision") + 1L
        setMetaValueUnlocked("revision", next)
        return next
    }

    private fun isUploadProgressOnly(previous: JSONObject?, current: JSONObject): Boolean {
        if (previous == null || previous.optLong("uploadedBytes") == current.optLong("uploadedBytes")) {
            return false
        }
        return listOf(
            "generation",
            "state",
            "errorMessage",
            "failureKind",
            "backupCompletedAt",
            "scheduledCleanupAt",
            "localDeletedAt",
            "waitingCleanup",
            "remoteRecordId",
            "verificationReceipt",
        ).all { key ->
            val before = previous.opt(key).takeUnless { it == JSONObject.NULL }
            val after = current.opt(key).takeUnless { it == JSONObject.NULL }
            before == after
        }
    }

    private fun metaValueUnlocked(key: String): Long = db.rawQuery(
        "SELECT int_value FROM ${LanBackupJobDatabase.META_TABLE} WHERE key = ?",
        arrayOf(key),
    ).use { cursor -> if (cursor.moveToFirst()) cursor.getLong(0) else 0L }

    private fun setMetaValueUnlocked(key: String, value: Long) {
        db.execSQL(
            "INSERT OR REPLACE INTO ${LanBackupJobDatabase.META_TABLE}(key, int_value) VALUES(?, ?)",
            arrayOf<Any?>(key, value),
        )
    }

    private fun adjustSummaryCountersUnlocked(previous: JSONObject?, current: JSONObject?) {
        val before = summaryMetrics(previous)
        val after = summaryMetrics(current)
        LanBackupJobDatabase.SUMMARY_COUNTER_KEYS.forEachIndexed { index, key ->
            val delta = after[index] - before[index]
            if (delta == 0L) return@forEachIndexed
            val updated = metaValueUnlocked(key) + delta
            check(updated >= 0L) { "备份摘要计数不能为负数：$key" }
            setMetaValueUnlocked(key, updated)
        }
    }

    private fun summaryMetrics(job: JSONObject?): LongArray {
        if (job == null) return LongArray(LanBackupJobDatabase.SUMMARY_COUNTER_KEYS.size)
        val state = job.optString("state")
        return longArrayOf(
            1L,
            if (state == "pending") 1L else 0L,
            if (state == "uploading") 1L else 0L,
            if (state == "paused") 1L else 0L,
            if (state == "completed") 1L else 0L,
            if (state == "failed") 1L else 0L,
            if (job.optBoolean("waitingCleanup")) 1L else 0L,
            if (LanBackupCleanupScheduler.nullableText(job, "localDeletedAt") != null) 1L else 0L,
            if (state != "completed") job.optLong("uploadedBytes") else 0L,
            if (state != "completed") job.optLong("totalBytes") else 0L,
        )
    }

    private fun insertCleanupEventIfNeededUnlocked(
        previous: JSONObject?,
        job: JSONObject,
        revision: Long,
    ) {
        if (LanBackupCleanupScheduler.nullableText(previous ?: JSONObject(), "localDeletedAt") != null) return
        val deletedAt = LanBackupCleanupScheduler.nullableText(job, "localDeletedAt") ?: return
        val deletedAtMs = runCatching { Instant.parse(deletedAt).toEpochMilli() }.getOrNull() ?: return
        val generation = job.optString("generation")
        val eventId = "cleanup:${job.optString("id")}:$generation"
        db.execSQL(
            """
            INSERT OR IGNORE INTO ${LanBackupJobDatabase.CLEANUP_EVENTS_TABLE}
                (revision, event_id, job_id, file_path, file_size_bytes, deleted_at_ms, reason)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """.trimIndent(),
            arrayOf(
                revision,
                eventId,
                job.optString("id"),
                job.optString("filePath"),
                job.optLong("totalBytes"),
                deletedAtMs,
                LanBackupCleanupScheduler.nullableText(job, "cleanupReason").orEmpty(),
            ),
        )
        setMetaValueUnlocked("cleanup_high_watermark", revision)
    }

    private fun representativeJobUnlocked(
        where: String,
        orderBy: String,
        selectionArgs: Array<String>? = null,
    ) = db.query(
        LanBackupJobDatabase.TABLE,
        jobDtoColumns.toTypedArray(),
        where,
        selectionArgs,
        null,
        null,
        orderBy,
        "1",
    ).use { cursor ->
        if (cursor.moveToFirst()) lanBackupRowToDto(cursor.toRowMap(jobDtoColumns)) else null
    }

    private fun sourceStatus(job: JSONObject): LanBackupSourceStatus =
        LanBackupSourcePolicy.inspect(
            file = File(job.optString("filePath")),
            expectedBytes = job.optLong("totalBytes", -1L),
            expectedLastModified = job.optLong("lastModified", -1L),
        )

    private fun storageCreatedAtKey(job: JSONObject): String =
        LanBackupCleanupScheduler.nullableText(job, "fileCreatedAt")
            ?: "9999-12-31T23:59:59Z"

    fun saveRetentionPolicies(unbackedDays: Int?, backedDays: Int?) {
        context.getSharedPreferences(RETENTION_PREFS, Context.MODE_PRIVATE).edit()
            .putInt("unbackedDays", unbackedDays ?: -1)
            .putInt("backedDays", backedDays ?: -1)
            .apply()
    }

    fun unbackedRetentionDays(): Int = context
        .getSharedPreferences(RETENTION_PREFS, Context.MODE_PRIVATE)
        .getInt("unbackedDays", 30)

    fun backedRetentionDays(): Int = context
        .getSharedPreferences(RETENTION_PREFS, Context.MODE_PRIVATE)
        .getInt("backedDays", 7)

    fun deviceId(): String {
        val androidId = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ANDROID_ID,
        )
        stableDeviceId(androidId, context.packageName)?.let { return it }

        // Only obsolete or unavailable Android IDs use an installation-local
        // fallback. Normal devices keep the same ID after uninstall/reinstall.
        val prefs = context.getSharedPreferences(DEVICE_PREFS, Context.MODE_PRIVATE)
        prefs.getString("id", null)?.takeIf { it.isNotBlank() }?.let { return it }
        val value = UUID.randomUUID().toString()
        prefs.edit().putString("id", value).apply()
        return value
    }

    fun deviceName(): String {
        val savedName = context.getSharedPreferences(DEVICE_PREFS, Context.MODE_PRIVATE)
            .getString("name", null)
            ?.trim()
            .orEmpty()
        return savedName.ifBlank { deviceDisplayName(deviceId()) }
    }
}
