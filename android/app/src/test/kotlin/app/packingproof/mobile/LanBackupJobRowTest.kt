package app.packingproof.mobile

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LanBackupJobRowTest {
    @Test
    fun fullJobRoundTripsThroughRow() {
        val job = JSONObject()
            .put("id", "job-1")
            .put("generation", "gen-1")
            .put("filePath", "/data/user/0/app.packingproof.mobile/recordings/a.mp4")
            .put("fileName", "a.mp4")
            .put("destinationComputerId", "host-1")
            .put("state", "completed")
            .put("uploadedBytes", 1234L)
            .put("totalBytes", 1234L)
            .put("lastModified", 1724000000000L)
            .put("fileCreatedAt", "2026-08-19T04:00:00Z")
            .put("backupCompletedAt", "2026-08-19T05:00:00Z")
            .put("scheduledCleanupAt", "2026-08-26T05:00:00Z")
            .put("localDeletedAt", JSONObject.NULL)
            .put("waitingCleanup", false)
            .put("remoteRecordId", 1L)
            .put("contentSha256", "a".repeat(64))
            .put("verificationVersion", 3)
            .put("verificationReceipt", JSONObject().put("signature", "sig"))
            .put("lastAttestedAt", "2026-08-19T05:00:00Z")
            .put("cleanupReason", JSONObject.NULL)
            .put("errorMessage", JSONObject.NULL)
            .put("failureKind", JSONObject.NULL)
            .put("sessions", JSONArray().put(JSONObject().put("id", "session-1")))

        val row = lanBackupJobToRow(job)
        assertEquals("job-1", row["id"])
        assertEquals("a.mp4", row["file_name"])
        assertEquals(1234L, row["uploaded_bytes"])
        assertEquals(0, row["waiting_cleanup"])
        assertEquals(3, row["verification_version"])

        val restored = lanBackupRowToJob(row)
        assertEquals(job.getString("id"), restored.getString("id"))
        assertEquals(job.getString("generation"), restored.getString("generation"))
        assertEquals(job.getString("filePath"), restored.getString("filePath"))
        assertEquals(job.getString("state"), restored.getString("state"))
        assertEquals(job.optLong("uploadedBytes"), restored.optLong("uploadedBytes"))
        assertEquals(job.optLong("totalBytes"), restored.optLong("totalBytes"))
        assertEquals(job.optLong("lastModified"), restored.optLong("lastModified"))
        assertEquals(job.optInt("verificationVersion"), restored.optInt("verificationVersion"))
        assertEquals(1L, restored.getLong("remoteRecordId"))
        assertEquals("sig", restored.optJSONObject("verificationReceipt").getString("signature"))
        assertEquals(1, restored.optJSONArray("sessions").length())
        assertTrue(restored.isNull("errorMessage"))
        assertTrue(restored.isNull("localDeletedAt"))
        assertFalse(restored.optBoolean("waitingCleanup"))
    }

    @Test
    fun nullableColumnsRestoreAsJsonNull() {
        val job = JSONObject()
            .put("id", "job-2")
            .put("generation", "gen-2")
            .put("filePath", "/data/user/0/app.packingproof.mobile/recordings/b.mp4")
            .put("state", "pending")
            .put("uploadedBytes", 0L)
            .put("totalBytes", 0L)
            .put("lastModified", 0L)
            .put("verificationVersion", 0)

        val row = lanBackupJobToRow(job)
        assertEquals(null, row["content_sha256"])
        assertEquals(null, row["backup_completed_at"])

        val restored = lanBackupRowToJob(row)
        assertTrue(restored.isNull("contentSha256"))
        assertTrue(restored.isNull("backupCompletedAt"))
        assertTrue(restored.isNull("verificationReceipt"))
        assertTrue(restored.isNull("remoteRecordId"))
        assertEquals(0, restored.optJSONArray("sessions").length())
        assertFalse(restored.optBoolean("waitingCleanup"))
    }

    @Test
    fun waitingCleanupAndBooleanRoundTrip() {
        val job = JSONObject()
            .put("id", "job-3")
            .put("generation", "gen-3")
            .put("filePath", "/data/user/0/app.packingproof.mobile/recordings/c.mp4")
            .put("state", "uploading")
            .put("uploadedBytes", 5L)
            .put("totalBytes", 10L)
            .put("lastModified", 1L)
            .put("waitingCleanup", true)

        val restored = lanBackupRowToJob(lanBackupJobToRow(job))
        assertTrue(restored.optBoolean("waitingCleanup"))
    }

    @Test
    fun snapshotColumnsExcludePrivateAndLargeFields() {
        assertFalse(LAN_BACKUP_SNAPSHOT_COLUMNS.contains("generation"))
        assertFalse(LAN_BACKUP_SNAPSHOT_COLUMNS.contains("sessions"))
        assertFalse(LAN_BACKUP_SNAPSHOT_COLUMNS.contains("verification_receipt"))
        assertEquals(17, LAN_BACKUP_SNAPSHOT_COLUMNS.size)
    }

    @Test
    fun snapshotRowMapsOnlyDartConsumedFields() {
        val row = mapOf<String, Any?>(
            "id" to "job-4",
            "file_path" to "/data/user/0/app.packingproof.mobile/recordings/d.mp4",
            "state" to "uploading",
            "uploaded_bytes" to 5L,
            "total_bytes" to 10L,
            "last_modified" to 1724000000000L,
            "content_sha256" to null,
            "error_message" to null,
            "failure_kind" to null,
            "file_created_at" to "2026-08-19T04:00:00Z",
            "backup_completed_at" to null,
            "scheduled_cleanup_at" to "2026-08-26T04:00:00Z",
            "local_deleted_at" to null,
            "waiting_cleanup" to 1L,
            "remote_record_id" to 9L,
            "destination_computer_id" to "host-1",
            "cleanup_reason" to null,
        )

        val snapshot = lanBackupSnapshotRowToValue(row)

        assertEquals(LAN_BACKUP_SNAPSHOT_COLUMNS.size, snapshot.size)
        assertEquals("job-4", snapshot["id"])
        assertEquals(5L, snapshot["uploadedBytes"])
        assertEquals(true, snapshot["waitingCleanup"])
        assertEquals(9L, snapshot["remoteRecordId"])
        assertFalse(snapshot.containsKey("generation"))
        assertFalse(snapshot.containsKey("sessions"))
    }
}
