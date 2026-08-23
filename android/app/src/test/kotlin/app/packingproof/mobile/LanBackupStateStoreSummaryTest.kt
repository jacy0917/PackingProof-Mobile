package app.packingproof.mobile

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.time.Instant

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class LanBackupStateStoreSummaryTest {
    private val context
        get() = RuntimeEnvironment.getApplication()
    private lateinit var root: File
    private lateinit var store: LanBackupStateStore

    @Before
    fun setUp() {
        context.deleteDatabase("lan_backup.db")
        context.getSharedPreferences("lan_backup_migration", Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        File(context.filesDir, "lan_backup/jobs").deleteRecursively()
        root = File(context.cacheDir, "backup-summary-test").apply { mkdirs() }
        store = LanBackupStateStore(context)
    }

    @After
    fun tearDown() {
        store.close()
        root.deleteRecursively()
        File(context.filesDir, "lan_backup/jobs").deleteRecursively()
        context.deleteDatabase("lan_backup.db")
    }

    @Test
    fun revisionsAreMonotonicAndFailedGenerationDoesNotAdvance() {
        val source = source("revision.mp4")
        val created = store.upsertJob(source.path, sessions("session-revision")).job
        val createdRevision = store.summary().revision

        val changed = store.updateJob(created.getString("id"), created.getString("generation")) {
            it.put("state", "uploading")
            true
        }
        val changedRevision = store.summary().revision
        val rejected = store.updateJob(created.getString("id"), "stale-generation") {
            it.put("state", "completed")
            true
        }

        assertNotNull(changed)
        assertTrue(changedRevision > createdRevision)
        assertEquals(null, rejected)
        assertEquals(changedRevision, store.summary().revision)
    }

    @Test
    fun updatingJobPreservesReferencedRows() {
        val source = source("referenced-row.mp4")
        val job = store.upsertJob(source.path, sessions("session-referenced-row")).job
        val database = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        try {
            database.setForeignKeyConstraintsEnabled(true)
            database.execSQL(
                """
                CREATE TABLE backup_job_reference (
                    job_id TEXT PRIMARY KEY,
                    FOREIGN KEY(job_id) REFERENCES backup_jobs(id) ON DELETE CASCADE
                )
                """.trimIndent(),
            )
            database.execSQL(
                "INSERT INTO backup_job_reference(job_id) VALUES(?)",
                arrayOf(job.getString("id")),
            )
        } finally {
            database.close()
        }

        val updated = store.updateJob(job.getString("id"), job.getString("generation")) {
            it.put("state", "uploading")
            true
        }

        assertNotNull(updated)
        context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null).use { reopened ->
            val referenceCount = reopened.rawQuery(
                "SELECT COUNT(*) FROM backup_job_reference WHERE job_id = ?",
                arrayOf(job.getString("id")),
            ).use { cursor ->
                cursor.moveToFirst()
                cursor.getLong(0)
            }
            assertEquals(1L, referenceCount)
        }
    }

    @Test
    fun summaryIsFixedSizeAndPathLookupIsBounded() {
        val first = source("first.mp4")
        val second = source("second.mp4")
        store.upsertJob(first.path, sessions("session-first"))
        val failed = store.upsertJob(second.path, sessions("session-second")).job
        store.updateJob(failed.getString("id"), failed.getString("generation")) {
            it.put("state", "failed").put("failureKind", "network")
            true
        }

        val summary = store.summary()
        val selected = store.jobsForPaths(listOf(first.path, File(root, "missing.mp4").path))

        assertEquals(2L, summary.totalCount)
        assertEquals(1L, summary.pendingCount)
        assertEquals(1L, summary.failedCount)
        assertEquals("network", summary.dominantFailureKind)
        assertEquals(failed.getString("id"), summary.problemJob?.id)
        assertEquals(1, selected.jobs.size)
        assertEquals(first.canonicalPath, selected.jobs.single().filePath)
        assertEquals(1, selected.missingPaths.size)
        runCatching { store.jobsForPaths(List(101) { "$root/$it.mp4" }) }
            .onSuccess { throw AssertionError("101 个路径必须被拒绝") }

        val firstJob = store.readJob(LanBackupStateStore.stableId(first.canonicalPath))!!
        assertTrue(store.deleteJob(firstJob.getString("id"), firstJob.getString("generation")))
        assertEquals(1L, store.summary().totalCount)
    }

    @Test
    fun summaryUsesSharedDominantFailurePriority() {
        val credential = store.upsertJob(
            source("failure-credential.mp4").path,
            sessions("session-credential"),
        ).job
        store.updateJob(credential.getString("id"), credential.getString("generation")) {
            it.put("state", "failed").put("failureKind", "credential_invalid")
            true
        }
        val offline = store.upsertJob(
            source("failure-offline.mp4").path,
            sessions("session-offline"),
        ).job
        store.updateJob(offline.getString("id"), offline.getString("generation")) {
            it.put("state", "failed").put("failureKind", "offline_or_timeout")
            true
        }

        val summary = store.summary()
        assertEquals("credential_invalid", summary.dominantFailureKind)
        assertEquals(credential.getString("id"), summary.problemJob?.id)
    }

    @Test
    fun compatibleHostRecoveryOnlyRequeuesItsOwnIncompatibleFailures() {
        store.saveConnection("http://192.168.1.20:5280", "computer-1", "仓库电脑")
        val incompatible = store.upsertJob(
            source("failure-incompatible.mp4").path,
            sessions("session-incompatible"),
        ).job
        store.updateJob(incompatible.getString("id"), incompatible.getString("generation")) {
            it.put("state", "failed")
                .put("failureKind", "incompatible_version")
                .put("errorMessage", "电脑端版本不兼容")
            true
        }
        val otherFailure = store.upsertJob(
            source("failure-storage.mp4").path,
            sessions("session-storage"),
        ).job
        store.updateJob(otherFailure.getString("id"), otherFailure.getString("generation")) {
            it.put("state", "failed").put("failureKind", "storage_unavailable")
            true
        }
        val otherDestination = store.upsertJob(
            source("failure-other-destination.mp4").path,
            sessions("session-other-destination"),
        ).job
        store.updateJob(
            otherDestination.getString("id"),
            otherDestination.getString("generation"),
        ) {
            it.put("state", "failed")
                .put("failureKind", "incompatible_version")
                .put("destinationComputerId", "computer-2")
            true
        }

        assertEquals(1, store.recoverIncompatibleFailures("computer-1"))

        val recovered = store.readJob(incompatible.getString("id"))!!
        assertEquals("pending", recovered.getString("state"))
        assertFalse(recovered.has("failureKind") && !recovered.isNull("failureKind"))
        assertEquals("failed", store.readJob(otherFailure.getString("id"))!!.getString("state"))
        assertEquals(
            "failed",
            store.readJob(otherDestination.getString("id"))!!.getString("state"),
        )
        assertEquals(1L, store.summary().pendingCount)
        assertEquals(2L, store.summary().failedCount)
    }

    @Test
    fun tenThousandProgressRevisionsAreCoalescedLatestWins() {
        val notices = mutableListOf<LanBackupRevisionNotifier.Notice>()
        val listener: (LanBackupRevisionNotifier.Notice) -> Unit = { notice ->
            synchronized(notices) { notices += notice }
        }
        LanBackupRevisionNotifier.addListener(listener)
        try {
            LanBackupRevisionNotifier.publish(0L, immediate = true)
            synchronized(notices) { notices.clear() }
            repeat(10_000) { index ->
                LanBackupRevisionNotifier.publish((index + 1).toLong(), immediate = false)
            }
            Thread.sleep(1_200)

            val progress = synchronized(notices) { notices.filterNot { it.immediate } }
            assertTrue(progress.size <= 2)
            assertEquals(10_000L, progress.last().revision)
        } finally {
            LanBackupRevisionNotifier.removeListener(listener)
        }
    }

    @Test
    fun dispatcherClaimsOneRunnableJobAndSkipsNonRetryablePause() {
        val paused = store.upsertJob(
            source("dispatcher-paused.mp4").path,
            sessions("session-paused"),
        ).job
        store.updateJob(paused.getString("id"), paused.getString("generation")) {
            it.put("state", "paused").put("failureKind", "unknown")
            true
        }
        val pending = store.upsertJob(
            source("dispatcher-pending.mp4").path,
            sessions("session-pending"),
        ).job

        val claimed = store.claimNextUploadJob()

        assertEquals(pending.getString("id"), claimed?.getString("id"))
        assertEquals("uploading", claimed?.getString("state"))
        assertEquals(
            pending.getString("id"),
            store.claimNextUploadJob()?.getString("id"),
        )
    }

    @Test
    fun tenThousandQueuedJobsKeepOldestRunnableFirstWhileNewJobsArrive() {
        store.summary()
        val database = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        val seed = database.compileStatement(
            """
            INSERT INTO backup_jobs(
                id, generation, file_path, state, failure_kind, sessions, updated_revision
            ) VALUES(?, ?, ?, ?, ?, '[]', ?)
            """.trimIndent(),
        )
        database.beginTransaction()
        try {
            repeat(10_000) { index ->
                val id = "fair-old-${index.toString().padStart(5, '0')}"
                seed.clearBindings()
                seed.bindString(1, id)
                seed.bindString(2, "generation-$id")
                seed.bindString(3, "/recordings/$id.mp4")
                seed.bindString(4, if (index == 0) "paused" else "pending")
                if (index == 0) {
                    seed.bindString(5, LanBackupFailureKind.OFFLINE_OR_TIMEOUT.wireValue)
                } else {
                    seed.bindNull(5)
                }
                seed.bindLong(6, (index + 1).toLong())
                seed.executeInsert()
            }
            database.execSQL(
                "UPDATE backup_meta SET int_value = 10000 WHERE key = 'revision'",
            )
            database.execSQL(
                "UPDATE backup_meta SET int_value = 10000 " +
                    "WHERE key = 'summary_total_count'",
            )
            database.execSQL(
                "UPDATE backup_meta SET int_value = 9999 " +
                    "WHERE key = 'summary_pending_count'",
            )
            database.execSQL(
                "UPDATE backup_meta SET int_value = 1 " +
                    "WHERE key = 'summary_paused_count'",
            )
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
            seed.close()
        }

        val newcomer = database.compileStatement(
            """
            INSERT INTO backup_jobs(
                id, generation, file_path, state, sessions, updated_revision
            ) VALUES(?, ?, ?, 'pending', '[]', ?)
            """.trimIndent(),
        )
        try {
            repeat(512) { index ->
                val newId = "fair-new-${index.toString().padStart(5, '0')}"
                newcomer.clearBindings()
                newcomer.bindString(1, newId)
                newcomer.bindString(2, "generation-$newId")
                newcomer.bindString(3, "/recordings/$newId.mp4")
                newcomer.bindLong(4, 1_000_000L + index)
                newcomer.executeInsert()
                database.execSQL(
                    "UPDATE backup_meta SET int_value = int_value + 1 " +
                        "WHERE key IN ('summary_total_count', 'summary_pending_count')",
                )

                val expectedId = "fair-old-${index.toString().padStart(5, '0')}"
                val claimed = store.claimNextUploadJob()!!
                assertEquals(expectedId, claimed.getString("id"))
                assertEquals("generation-$expectedId", claimed.getString("generation"))
                assertEquals("uploading", claimed.getString("state"))
                assertNotNull(
                    store.updateJob(expectedId, claimed.getString("generation")) {
                        it.put("state", "completed")
                        true
                    },
                )
            }
        } finally {
            newcomer.close()
            database.close()
        }
    }

    @Test
    fun fairClaimQueriesUsePartialIndexesWithoutOffsetOrTemporarySort() {
        store.summary()
        val database = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        try {
            val uploadingPlan = explainClaimPlan(
                database,
                LanBackupJobDatabase.UPLOADING_CLAIM_SELECTION,
                LanBackupJobDatabase.UPLOADING_CLAIM_INDEX,
            )
            val queuedPlan = explainClaimPlan(
                database,
                LanBackupJobDatabase.QUEUED_UPLOAD_CLAIM_SELECTION,
                LanBackupJobDatabase.QUEUED_UPLOAD_CLAIM_INDEX,
            )

            assertTrue(
                uploadingPlan,
                uploadingPlan.contains(LanBackupJobDatabase.UPLOADING_CLAIM_INDEX),
            )
            assertTrue(
                queuedPlan,
                queuedPlan.contains(LanBackupJobDatabase.QUEUED_UPLOAD_CLAIM_INDEX),
            )
            assertFalse(uploadingPlan, uploadingPlan.contains("TEMP B-TREE"))
            assertFalse(queuedPlan, queuedPlan.contains("TEMP B-TREE"))
            assertFalse(uploadingPlan.contains("OFFSET"))
            assertFalse(queuedPlan.contains("OFFSET"))
        } finally {
            database.close()
        }
    }

    @Test
    fun cleanupDispatcherSelectsOnlyTheEarliestScheduledJob() {
        val later = store.upsertJob(
            source("cleanup-later.mp4").path,
            sessions("session-cleanup-later"),
        ).job
        store.updateJob(later.getString("id"), later.getString("generation")) {
            it.put("scheduledCleanupAt", "2026-08-25T10:00:00Z")
            true
        }
        val earlier = store.upsertJob(
            source("cleanup-earlier.mp4").path,
            sessions("session-cleanup-earlier"),
        ).job
        store.updateJob(earlier.getString("id"), earlier.getString("generation")) {
            it.put("scheduledCleanupAt", "2026-08-24T10:00:00Z")
            true
        }

        assertEquals(
            earlier.getString("id"),
            store.nextScheduledCleanupJob()?.getString("id"),
        )
    }

    @Test
    fun cleanupEventAndDeletedJobAreCommittedTogetherAndCanBeAcknowledged() {
        val source = source("cleanup.mp4")
        val job = store.upsertJob(source.path, sessions("session-cleanup")).job
        val deletedAt = Instant.parse("2026-08-23T10:00:00Z")

        store.updateJob(job.getString("id"), job.getString("generation")) {
            it.put("localDeletedAt", deletedAt.toString())
                .put("cleanupReason", "测试清理")
            true
        }

        val summary = store.summary()
        val page = store.cleanupEvents(0, 100)
        assertEquals(1L, summary.localDeletedCount)
        assertEquals(summary.cleanupHighWatermark, page.latestRevision)
        assertEquals(1, page.events.size)
        assertEquals(job.getString("id"), page.events.single().jobId)
        assertEquals(deletedAt.toEpochMilli(), page.events.single().deletedAtMs)
        assertFalse(page.hasMore)

        store.acknowledgeCleanupEvents(page.nextAfterRevision)
        assertTrue(store.cleanupEvents(0, 100).events.isEmpty())
        assertEquals(page.latestRevision, store.summary().cleanupHighWatermark)
    }

    @Test
    fun tenThousandJobsAreRecoveredThroughPagesOfAtMostOneHundred() {
        store.summary()
        val database = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        val statement = database.compileStatement(
            """
            INSERT INTO backup_jobs(
                id, generation, file_path, state, total_bytes, last_modified,
                file_created_at, backup_completed_at, local_deleted_at,
                content_sha256, verification_version, last_attested_at, sessions,
                updated_revision
            ) VALUES(?, ?, ?, ?, 1, 1, ?, ?, NULL, ?, ?, ?, '[]', ?)
            """.trimIndent(),
        )
        val attestedAt = Instant.now().toString()
        database.beginTransaction()
        try {
            repeat(10_000) { index ->
                val id = "scale-${index.toString().padStart(5, '0')}"
                val state = listOf("pending", "paused", "uploading", "completed")[index % 4]
                statement.clearBindings()
                statement.bindString(1, id)
                statement.bindString(2, "generation-$id")
                statement.bindString(3, "/recordings/$id.mp4")
                statement.bindString(4, state)
                statement.bindString(5, "2026-08-23T00:00:00Z")
                if (state == "completed") {
                    statement.bindString(6, "2026-08-23T00:01:00Z")
                    statement.bindString(7, "a".repeat(64))
                    statement.bindLong(8, BackupRequestAuthentication.VERSION.toLong())
                    statement.bindString(9, attestedAt)
                } else {
                    statement.bindNull(6)
                    statement.bindNull(7)
                    statement.bindLong(8, 0)
                    statement.bindNull(9)
                }
                statement.bindLong(10, index.toLong())
                statement.executeInsert()
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
            statement.close()
            database.close()
        }

        assertEquals(7_500, countIdPages(store::pendingJobIdsPage))
        assertEquals(7_500, countIdPages(store::unfinishedJobIdsPage))
        assertEquals(10_000, countIdPages(store::cleanupSchedulingJobIdsPage))

        var storageCount = 0
        var createdAt: String? = null
        var id: String? = null
        var page: LanBackupStorageJobPage
        do {
            page = store.storageRecoveryJobsPage(createdAt, id)
            assertTrue(page.jobs.size <= 100)
            storageCount += page.jobs.size
            createdAt = page.nextCreatedAtKey
            id = page.nextId
        } while (page.jobs.size == 100)
        assertEquals(2_500, storageCount)
    }

    @Test
    fun versionTwoDatabaseKeepsJobsAndSeedsExistingCleanupEvents() {
        val legacy = context.openOrCreateDatabase("lan_backup.db", Context.MODE_PRIVATE, null)
        legacy.execSQL(
            """
            CREATE TABLE backup_jobs (
                id TEXT PRIMARY KEY, generation TEXT NOT NULL, file_path TEXT NOT NULL,
                file_name TEXT, destination_computer_id TEXT, state TEXT NOT NULL,
                uploaded_bytes INTEGER NOT NULL DEFAULT 0,
                total_bytes INTEGER NOT NULL DEFAULT 0,
                last_modified INTEGER NOT NULL DEFAULT 0, file_created_at TEXT,
                backup_completed_at TEXT, scheduled_cleanup_at TEXT, local_deleted_at TEXT,
                waiting_cleanup INTEGER NOT NULL DEFAULT 0, remote_record_id INTEGER,
                content_sha256 TEXT, verification_version INTEGER NOT NULL DEFAULT 0,
                verification_receipt TEXT, last_attested_at TEXT, cleanup_reason TEXT,
                error_message TEXT, failure_kind TEXT, sessions TEXT
            )
            """.trimIndent(),
        )
        legacy.execSQL(
            """
            INSERT INTO backup_jobs(
                id, generation, file_path, state, total_bytes, last_modified,
                local_deleted_at, cleanup_reason
            ) VALUES('legacy-job', 'legacy-generation', '/legacy/video.mp4', 'completed',
                     42, 1, '2026-08-23T10:00:00Z', '旧版清理')
            """.trimIndent(),
        )
        legacy.version = 2
        legacy.close()

        val summary = store.summary()
        val events = store.cleanupEvents(0, 100)

        assertEquals(1L, summary.totalCount)
        assertEquals(1L, summary.completedCount)
        assertEquals(1L, summary.localDeletedCount)
        assertEquals(1, events.events.size)
        assertEquals("legacy-job", events.events.single().jobId)
        assertEquals("旧版清理", events.events.single().reason)
    }

    @Test
    fun damagedLegacyJsonIsPreservedAndRetriedWithoutDeletingSuccessfulSources() {
        val legacyDir = File(context.filesDir, "lan_backup/jobs").apply { mkdirs() }
        val validSource = source("legacy-valid.mp4")
        val retrySource = source("legacy-retry.mp4")
        val validFile = File(legacyDir, "legacy-valid.json")
        val damagedFile = File(legacyDir, "legacy-retry.json")
        validFile.writeText(
            legacyJob("legacy-valid", validSource).toString(),
            Charsets.UTF_8,
        )
        damagedFile.writeText("{damaged-json", Charsets.UTF_8)

        val firstSummary = store.summary()

        assertEquals(1L, firstSummary.totalCount)
        assertFalse(validFile.exists())
        assertTrue(damagedFile.exists())
        assertFalse(
            context.getSharedPreferences("lan_backup_migration", Context.MODE_PRIVATE)
                .getBoolean("legacy_files_migrated", false),
        )

        damagedFile.writeText(
            legacyJob("legacy-retry", retrySource).toString(),
            Charsets.UTF_8,
        )
        val retriedSummary = LanBackupStateStore(context).use { it.summary() }

        assertEquals(2L, retriedSummary.totalCount)
        assertFalse(damagedFile.exists())
        assertTrue(
            context.getSharedPreferences("lan_backup_migration", Context.MODE_PRIVATE)
                .getBoolean("legacy_files_migrated", false),
        )
    }

    @Test
    fun unavailableSourcePausesButNeverDeletesCursorPassedJob() {
        val recording = source("cursor-passed.mp4")
        val expectedModified = recording.lastModified()
        val job = store.upsertJob(recording.path, sessions("session-cursor")).job
        assertTrue(recording.delete())

        assertEquals(
            LanBackupSourceStatus.MISSING,
            store.reconcileJobSource(job.getString("id")),
        )
        val preserved = store.readJob(job.getString("id"))!!
        assertEquals("paused", preserved.getString("state"))
        assertTrue(preserved.getString("errorMessage").contains("已保留备份任务"))

        recording.writeText("test-video-cursor-passed.mp4", Charsets.UTF_8)
        assertTrue(recording.setLastModified(expectedModified))
        assertEquals(
            LanBackupSourceStatus.AVAILABLE,
            store.reconcileJobSource(job.getString("id")),
        )
        assertNotNull(store.readJob(job.getString("id")))
    }

    private fun source(name: String) = File(root, name).apply {
        writeText("test-video-$name", Charsets.UTF_8)
    }

    private fun sessions(id: String): JSONArray = JSONArray().put(
        JSONObject()
            .put("id", id)
            .put("startedAt", "2026-08-23T09:30:00Z")
            .put("endedAt", "2026-08-23T09:30:01Z"),
    )

    private fun legacyJob(id: String, file: File) = JSONObject()
        .put("id", id)
        .put("generation", "generation-$id")
        .put("filePath", file.path)
        .put("state", "pending")
        .put("uploadedBytes", 0L)
        .put("totalBytes", file.length())
        .put("lastModified", file.lastModified())
        .put("sessions", sessions("session-$id"))

    private fun countIdPages(load: (String?, Int) -> List<String>): Int {
        var total = 0
        var afterId: String? = null
        var page: List<String>
        do {
            page = load(afterId, 100)
            assertTrue(page.size <= 100)
            total += page.size
            afterId = page.lastOrNull()
        } while (page.size == 100)
        return total
    }

    private fun explainClaimPlan(
        database: android.database.sqlite.SQLiteDatabase,
        selection: String,
        indexName: String,
    ): String = database.rawQuery(
        "EXPLAIN QUERY PLAN SELECT id FROM ${LanBackupJobDatabase.TABLE} " +
            "INDEXED BY $indexName WHERE $selection " +
            "ORDER BY ${LanBackupJobDatabase.UPLOAD_CLAIM_ORDER} LIMIT 1",
        null,
    ).use { cursor ->
        buildList {
            while (cursor.moveToNext()) add(cursor.getString(3))
        }.joinToString("\n")
    }
}
