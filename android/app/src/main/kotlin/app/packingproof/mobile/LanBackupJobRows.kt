package app.packingproof.mobile

import android.content.ContentValues
import android.database.Cursor
import org.json.JSONArray
import org.json.JSONObject
import app.packingproof.mobile.generated.BackupJobDto
import java.time.Instant

internal val LAN_BACKUP_SNAPSHOT_COLUMNS = listOf(
    "id",
    "file_path",
    "state",
    "uploaded_bytes",
    "total_bytes",
    "last_modified",
    "content_sha256",
    "error_message",
    "failure_kind",
    "file_created_at",
    "backup_completed_at",
    "scheduled_cleanup_at",
    "local_deleted_at",
    "waiting_cleanup",
    "remote_record_id",
    "destination_computer_id",
    "cleanup_reason",
)

/** 只映射 Dart `LanBackupJob` 消费的字段，避免快照读取并解析 sessions 等任务私有数据。 */
internal fun lanBackupSnapshotRowToValue(row: Map<String, Any?>): Map<String, Any?> = mapOf(
    "id" to (row["id"] as? String).orEmpty(),
    "filePath" to (row["file_path"] as? String).orEmpty(),
    "state" to (row["state"] as? String).orEmpty(),
    "uploadedBytes" to ((row["uploaded_bytes"] as? Number)?.toLong() ?: 0L),
    "totalBytes" to ((row["total_bytes"] as? Number)?.toLong() ?: 0L),
    "lastModified" to ((row["last_modified"] as? Number)?.toLong() ?: 0L),
    "contentSha256" to row["content_sha256"] as? String,
    "errorMessage" to row["error_message"] as? String,
    "failureKind" to row["failure_kind"] as? String,
    "fileCreatedAt" to row["file_created_at"] as? String,
    "backupCompletedAt" to row["backup_completed_at"] as? String,
    "scheduledCleanupAt" to row["scheduled_cleanup_at"] as? String,
    "localDeletedAt" to row["local_deleted_at"] as? String,
    "waitingCleanup" to ((row["waiting_cleanup"] as? Number)?.toInt() != 0),
    "remoteRecordId" to (row["remote_record_id"] as? Number)?.toLong()?.takeIf { it > 0 },
    "destinationComputerId" to (row["destination_computer_id"] as? String).orEmpty(),
    "cleanupReason" to row["cleanup_reason"] as? String,
)

/** 备份任务行（SQLite 列名 → 值）与任务 JSONObject 的双向映射，字段名与旧版任务文件一致。 */
internal fun lanBackupJobToRow(job: JSONObject): Map<String, Any?> {
    fun text(key: String): String? = LanBackupCleanupScheduler.normalizeNullableText(job.opt(key))
    val remoteRecordId = job.optLong("remoteRecordId").takeIf { it > 0 }
        ?: job.optJSONArray("remoteRecordIds")?.optLong(0)?.takeIf { it > 0 }
    return linkedMapOf(
        "id" to job.optString("id"),
        "generation" to job.optString("generation"),
        "file_path" to job.optString("filePath"),
        "file_name" to job.optString("fileName"),
        "destination_computer_id" to job.optString("destinationComputerId"),
        "state" to job.optString("state"),
        "uploaded_bytes" to job.optLong("uploadedBytes"),
        "total_bytes" to job.optLong("totalBytes"),
        "last_modified" to job.optLong("lastModified"),
        "file_created_at" to text("fileCreatedAt"),
        "backup_completed_at" to text("backupCompletedAt"),
        "scheduled_cleanup_at" to text("scheduledCleanupAt"),
        "local_deleted_at" to text("localDeletedAt"),
        "waiting_cleanup" to if (job.optBoolean("waitingCleanup")) 1 else 0,
        "remote_record_id" to remoteRecordId,
        "content_sha256" to text("contentSha256"),
        "verification_version" to job.optInt("verificationVersion"),
        "verification_receipt" to job.opt("verificationReceipt")
            ?.takeUnless { it == JSONObject.NULL }
            ?.toString(),
        "last_attested_at" to text("lastAttestedAt"),
        "cleanup_reason" to text("cleanupReason"),
        "error_message" to text("errorMessage"),
        "failure_kind" to text("failureKind"),
        "sessions" to job.optJSONArray("sessions")?.toString(),
        "updated_revision" to job.optLong("revision"),
    )
}

internal fun lanBackupRowToJob(row: Map<String, Any?>): JSONObject {
    val job = JSONObject()
        .put("id", row["id"] ?: "")
        .put("generation", row["generation"] ?: "")
        .put("filePath", row["file_path"] ?: "")
        .put("fileName", row["file_name"] ?: "")
        .put("destinationComputerId", row["destination_computer_id"] ?: "")
        .put("state", row["state"] ?: "")
        .put("uploadedBytes", (row["uploaded_bytes"] as? Number)?.toLong() ?: 0L)
        .put("totalBytes", (row["total_bytes"] as? Number)?.toLong() ?: 0L)
        .put("lastModified", (row["last_modified"] as? Number)?.toLong() ?: 0L)
        .put("waitingCleanup", (row["waiting_cleanup"] as? Number)?.toInt() != 0)
        .put("verificationVersion", (row["verification_version"] as? Number)?.toInt() ?: 0)
        .put("revision", (row["updated_revision"] as? Number)?.toLong() ?: 0L)
    val textColumns = mapOf(
        "file_created_at" to "fileCreatedAt",
        "backup_completed_at" to "backupCompletedAt",
        "scheduled_cleanup_at" to "scheduledCleanupAt",
        "local_deleted_at" to "localDeletedAt",
        "content_sha256" to "contentSha256",
        "last_attested_at" to "lastAttestedAt",
        "cleanup_reason" to "cleanupReason",
        "error_message" to "errorMessage",
        "failure_kind" to "failureKind",
    )
    for ((column, key) in textColumns) {
        job.put(key, row[column] as? String ?: JSONObject.NULL)
    }
    job.put(
        "remoteRecordId",
        (row["remote_record_id"] as? Number)?.toLong()?.takeIf { it > 0 }
            ?: JSONObject.NULL,
    )
    job.put(
        "verificationReceipt",
        row["verification_receipt"]?.toString()?.trim()?.takeIf {
            it.isNotEmpty() && it != "null"
        }?.let { raw ->
            if (raw.startsWith("{")) {
                runCatching { JSONObject(raw) }.getOrNull() ?: raw
            } else {
                raw
            }
        } ?: JSONObject.NULL,
    )
    job.put("sessions", row["sessions"].parseJsonArray() ?: JSONArray())
    return job
}

private fun Any?.parseJsonArray(): JSONArray? = this?.let {
    runCatching {
        if (it is JSONArray) it else JSONArray(it.toString())
    }.getOrNull()
}

internal fun Map<String, Any?>.toContentValues(): ContentValues {
    val values = ContentValues()
    for ((key, value) in this) {
        when (value) {
            null -> values.putNull(key)
            is String -> values.put(key, value)
            is Int -> values.put(key, value)
            is Long -> values.put(key, value)
            is Boolean -> values.put(key, if (value) 1 else 0)
            else -> values.put(key, value.toString())
        }
    }
    return values
}

internal fun Cursor.toRowMap(columns: List<String>): Map<String, Any?> =
    columns.associateWith { column ->
        val index = getColumnIndexOrThrow(column)
        when (getType(index)) {
            Cursor.FIELD_TYPE_NULL -> null
            Cursor.FIELD_TYPE_INTEGER -> getLong(index)
            Cursor.FIELD_TYPE_FLOAT -> getDouble(index)
            else -> getString(index)
        }
    }

internal fun lanBackupRowToDto(row: Map<String, Any?>): BackupJobDto {
    fun epochMillis(column: String): Long? = (row[column] as? String)?.let { value ->
        runCatching { Instant.parse(value).toEpochMilli() }.getOrNull()
    }
    return BackupJobDto(
        revision = (row["updated_revision"] as? Number)?.toLong() ?: 0L,
        id = (row["id"] as? String).orEmpty(),
        filePath = (row["file_path"] as? String).orEmpty(),
        state = (row["state"] as? String).orEmpty(),
        uploadedBytes = (row["uploaded_bytes"] as? Number)?.toLong() ?: 0L,
        totalBytes = (row["total_bytes"] as? Number)?.toLong() ?: 0L,
        lastModifiedMs = (row["last_modified"] as? Number)?.toLong(),
        contentSha256 = row["content_sha256"] as? String,
        errorMessage = row["error_message"] as? String,
        failureKind = row["failure_kind"] as? String,
        fileCreatedAtMs = epochMillis("file_created_at"),
        backupCompletedAtMs = epochMillis("backup_completed_at"),
        scheduledCleanupAtMs = epochMillis("scheduled_cleanup_at"),
        localDeletedAtMs = epochMillis("local_deleted_at"),
        waitingCleanup = (row["waiting_cleanup"] as? Number)?.toInt() != 0,
        remoteRecordId = (row["remote_record_id"] as? Number)?.toLong()?.takeIf { it > 0 },
        destinationComputerId = (row["destination_computer_id"] as? String).orEmpty(),
        cleanupReason = row["cleanup_reason"] as? String,
    )
}
