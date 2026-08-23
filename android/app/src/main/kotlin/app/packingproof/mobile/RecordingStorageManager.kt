package app.packingproof.mobile

import android.content.Context
import android.os.StatFs
import org.json.JSONObject
import java.time.Instant

internal object RecordingStoragePolicy {
    const val WARNING_BYTES = 3L * 1024 * 1024 * 1024
    const val MINIMUM_BYTES = 2L * 1024 * 1024 * 1024
    const val TARGET_BYTES = 3L * 1024 * 1024 * 1024
    val STORAGE_ATTESTATION_FRESHNESS = java.time.Duration.ofMinutes(5)
    private val HEX_64 = Regex("^[0-9a-fA-F]{64}$")

    fun needsWarning(availableBytes: Long): Boolean = availableBytes < WARNING_BYTES
    fun needsReclaim(availableBytes: Long): Boolean = availableBytes < MINIMUM_BYTES

    fun isFreshAttestation(value: String): Boolean = runCatching {
        val age = java.time.Duration.between(Instant.parse(value), Instant.now()).abs()
        age <= STORAGE_ATTESTATION_FRESHNESS
    }.getOrDefault(false)

    fun isVerifiedCandidate(candidate: RecordingStorageCandidate): Boolean =
        candidate.generation.isNotBlank() &&
            candidate.filePath.isNotBlank() &&
            candidate.destinationComputerId.isNotBlank() &&
            candidate.state == "completed" &&
            candidate.backupCompletedAt != null &&
            candidate.contentSha256?.matches(HEX_64) == true &&
            candidate.verificationVersion >= BackupRequestAuthentication.VERSION &&
            candidate.verificationReceipt?.let { receipt ->
                receipt.authVersion == BackupRequestAuthentication.VERSION &&
                    receipt.verifiedAtUnixSeconds > 0 &&
                    receipt.hostNodeId.equals(candidate.destinationComputerId, ignoreCase = true) &&
                    receipt.sourceDeviceId.isNotBlank() &&
                    receipt.sourceSessionId == candidate.sessionIds.singleOrNull() &&
                    receipt.fileSha256.equals(candidate.contentSha256, ignoreCase = true) &&
                    receipt.fileSizeBytes == candidate.totalBytes &&
                    receipt.recordId == candidate.remoteRecordId &&
                    receipt.receiptSignature.matches(HEX_64)
            } == true &&
            candidate.remoteRecordId > 0 &&
            candidate.sessionIds.size == 1 &&
            candidate.sessionIds.single().isNotBlank() &&
            candidate.totalBytes > 0 &&
            candidate.lastModified > 0 &&
            candidate.lastAttestedAt?.let(RecordingStoragePolicy::isFreshAttestation) == true &&
            candidate.localDeletedAt == null

    fun verifiedCandidates(
        candidates: List<RecordingStorageCandidate>,
    ): List<RecordingStorageCandidate> = candidates
        .filter(::isVerifiedCandidate)
        .sortedBy { runCatching { Instant.parse(it.fileCreatedAt) }.getOrDefault(Instant.MAX) }
}

internal data class RecordingStorageReceipt(
    val authVersion: Int,
    val verifiedAtUnixSeconds: Long,
    val hostNodeId: String,
    val sourceDeviceId: String,
    val sourceSessionId: String,
    val fileSha256: String,
    val fileSizeBytes: Long,
    val recordId: Long,
    val receiptSignature: String,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("authVersion", authVersion)
        .put("verifiedAtUnixSeconds", verifiedAtUnixSeconds)
        .put("hostNodeId", hostNodeId)
        .put("sourceDeviceId", sourceDeviceId)
        .put("sourceSessionId", sourceSessionId)
        .put("fileSha256", fileSha256)
        .put("fileSizeBytes", fileSizeBytes)
        .put("recordId", recordId)
        .put("receiptSignature", receiptSignature)
}

internal data class RecordingStorageCandidate(
    val id: String,
    val generation: String,
    val filePath: String,
    val destinationComputerId: String,
    val state: String,
    val fileCreatedAt: String?,
    val backupCompletedAt: String?,
    val contentSha256: String?,
    val verificationVersion: Int,
    val verificationReceipt: RecordingStorageReceipt?,
    val remoteRecordId: Long,
    val sessionIds: List<String>,
    val totalBytes: Long,
    val lastModified: Long,
    val lastAttestedAt: String?,
    val localDeletedAt: String?,
)

internal fun recordingStorageCandidate(job: JSONObject): RecordingStorageCandidate {
    val sessions = job.optJSONArray("sessions")
    return RecordingStorageCandidate(
        id = job.optString("id"),
        generation = job.optString("generation"),
        filePath = job.optString("filePath"),
        destinationComputerId = job.optString("destinationComputerId"),
        state = job.optString("state"),
        fileCreatedAt = LanBackupCleanupScheduler.nullableText(job, "fileCreatedAt"),
        backupCompletedAt = LanBackupCleanupScheduler.nullableText(job, "backupCompletedAt"),
        contentSha256 = LanBackupCleanupScheduler.nullableText(job, "contentSha256"),
        verificationVersion = job.optInt("verificationVersion"),
        verificationReceipt = parseRecordingStorageReceipt(job.optJSONObject("verificationReceipt")),
        remoteRecordId = job.optLong("remoteRecordId", -1L),
        sessionIds = if (sessions == null) {
            emptyList()
        } else {
            List(sessions.length()) { index ->
                sessions.optJSONObject(index)?.optString("id")?.trim().orEmpty()
            }
        },
        totalBytes = job.optLong("totalBytes", -1L),
        lastModified = job.optLong("lastModified", -1L),
        lastAttestedAt = LanBackupCleanupScheduler.nullableText(job, "lastAttestedAt"),
        localDeletedAt = LanBackupCleanupScheduler.nullableText(job, "localDeletedAt"),
    )
}

private fun parseRecordingStorageReceipt(value: JSONObject?): RecordingStorageReceipt? {
    value ?: return null
    return runCatching {
        RecordingStorageReceipt(
            authVersion = value.getInt("authVersion"),
            verifiedAtUnixSeconds = value.getLong("verifiedAtUnixSeconds"),
            hostNodeId = value.getString("hostNodeId").trim(),
            sourceDeviceId = value.getString("sourceDeviceId").trim(),
            sourceSessionId = value.getString("sourceSessionId").trim(),
            fileSha256 = value.getString("fileSha256").trim(),
            fileSizeBytes = value.getLong("fileSizeBytes"),
            recordId = value.getLong("recordId"),
            receiptSignature = value.getString("receiptSignature").trim(),
        )
    }.getOrNull()
}

internal data class RecordingStorageCheckResult(
    val values: Map<String, Any>,
    val jobsChanged: Boolean,
)

internal class RecordingStorageManager(
    private val context: Context,
    private val store: LanBackupStateStore,
    private val availableBytes: () -> Long = {
        StatFs(context.filesDir.path).availableBytes
    },
    private val beforeGuardedDeleteForTesting: ((JSONObject) -> Unit)? = null,
) {
    fun checkAndReclaim(): RecordingStorageCheckResult {
        val before = availableBytes()
        var current = before
        var deletedCount = 0
        var freedBytes = 0L
        var jobsChanged = false
        if (RecordingStoragePolicy.needsReclaim(current)) {
            var afterCreatedAtKey: String? = null
            var afterId: String? = null
            var page: LanBackupStorageJobPage
            do {
                page = store.storageRecoveryJobsPage(afterCreatedAtKey, afterId)
                for (job in page.jobs) {
                    if (current >= RecordingStoragePolicy.TARGET_BYTES) break
                    val expected = recordingStorageCandidate(job)
                    if (!RecordingStoragePolicy.isVerifiedCandidate(expected)) {
                        continue
                    }
                    beforeGuardedDeleteForTesting?.invoke(JSONObject(job.toString()))
                    val outcome = store.reclaimVerifiedRecording(expected)
                    when (outcome.result) {
                        RecordingStorageReclaimResult.deleted -> {
                            deletedCount++
                            freedBytes += expected.totalBytes
                        }
                        RecordingStorageReclaimResult.missing,
                        RecordingStorageReclaimResult.stale,
                        RecordingStorageReclaimResult.failed,
                        RecordingStorageReclaimResult.rejected,
                        -> Unit
                    }
                    jobsChanged = jobsChanged || outcome.jobChanged
                    current = availableBytes()
                }
                afterCreatedAtKey = page.nextCreatedAtKey
                afterId = page.nextId
            } while (
                current < RecordingStoragePolicy.TARGET_BYTES && page.jobs.size == 100
            )
        }
        return RecordingStorageCheckResult(
            values = mapOf(
                "availableBytes" to current,
                "availableBytesBefore" to before,
                "freedBytes" to freedBytes,
                "deletedCount" to deletedCount,
                "warning" to RecordingStoragePolicy.needsWarning(current),
                "insufficient" to RecordingStoragePolicy.needsReclaim(current),
            ),
            jobsChanged = jobsChanged,
        )
    }
}
