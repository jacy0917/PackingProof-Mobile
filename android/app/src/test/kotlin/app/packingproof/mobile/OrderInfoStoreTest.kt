package app.packingproof.mobile

import android.content.ContentValues
import android.content.Context
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [24])
class OrderInfoStoreTest {
    private val context: Context
        get() = RuntimeEnvironment.getApplication()
    private lateinit var store: OrderInfoStore

    @Before
    fun setUp() {
        context.deleteDatabase(DATABASE_NAME)
    }

    @After
    fun tearDown() {
        if (this::store.isInitialized) store.close()
        context.deleteDatabase(DATABASE_NAME)
    }

    @Test
    fun versionTwoUpgradePreservesRowsAndInitializesPersistentCount() {
        val database = context.openOrCreateDatabase(DATABASE_NAME, Context.MODE_PRIVATE, null)
        database.execSQL(
            """
            CREATE TABLE order_info (
                tracking_number TEXT PRIMARY KEY,
                payload TEXT NOT NULL,
                push_time INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        database.execSQL("CREATE INDEX idx_order_info_push_time ON order_info(push_time DESC)")
        insertRaw(database, record("UPGRADE-1", pushTimeMillis = NOW - 2))
        insertRaw(database, record("UPGRADE-2", pushTimeMillis = NOW - 1))
        database.version = 2
        database.close()

        store = newStore()

        assertNotNull(store.lookup("UPGRADE-1"))
        assertNotNull(store.lookup("UPGRADE-2"))
        assertEquals(3, store.readableDatabase.version)
        assertEquals(2L, persistedCount())
        assertEquals(2L, rowCount())
        assertTrue(indexNames().contains("idx_order_info_cleanup"))
        assertTrue(!indexNames().contains("idx_order_info_push_time"))
    }

    @Test
    fun replacingExistingTrackingNumberDoesNotIncreasePersistentCount() {
        store = newStore()
        store.upsert(listOf(record("SAME", orderId = "old", pushTimeMillis = NOW - 1)))
        store.upsert(listOf(record("SAME", orderId = "new", pushTimeMillis = NOW)))

        assertEquals("new", store.lookup("SAME")?.orderId)
        assertEquals(1L, persistedCount())
        assertEquals(1L, rowCount())
    }

    @Test
    fun expiredRowsAreRemovedOldestFirstWithinCleanupBudget() {
        store = newStore(maxRecords = 20, cleanupBatchSize = 2)
        store.upsert(
            listOf(
                record("EXPIRED-1", pushTimeMillis = NOW - 100 * DAY_MILLIS),
                record("EXPIRED-2", pushTimeMillis = NOW - 99 * DAY_MILLIS),
                record("EXPIRED-3", pushTimeMillis = NOW - 98 * DAY_MILLIS),
                record("CURRENT", pushTimeMillis = NOW),
            ),
        )

        assertNull(store.lookup("EXPIRED-1"))
        assertNull(store.lookup("EXPIRED-2"))
        assertNotNull(store.lookup("EXPIRED-3"))
        assertNotNull(store.lookup("CURRENT"))
        assertEquals(2L, persistedCount())
        assertEquals(2L, rowCount())
    }

    @Test
    fun crossingLimitDeletesOnlyOldestRowsAndKeepsCountAtLimit() {
        store = newStore(maxRecords = 3, cleanupBatchSize = 4)
        store.upsert(
            listOf(
                record("OLDEST", pushTimeMillis = NOW - 4),
                record("SECOND", pushTimeMillis = NOW - 3),
                record("THIRD", pushTimeMillis = NOW - 2),
                record("NEWEST", pushTimeMillis = NOW - 1),
            ),
        )

        assertNull(store.lookup("OLDEST"))
        assertNotNull(store.lookup("SECOND"))
        assertNotNull(store.lookup("THIRD"))
        assertNotNull(store.lookup("NEWEST"))
        assertEquals(3L, persistedCount())
        assertEquals(3L, rowCount())
    }

    @Test
    fun oversizedBatchIsRejectedBeforeOpeningAWriteTransaction() {
        store = newStore()

        assertThrows(IllegalArgumentException::class.java) {
            store.upsert(
                List(201) { index ->
                    record("ORDER-$index", pushTimeMillis = NOW + index)
                },
            )
        }
        assertEquals(0L, rowCount())
    }

    @Test
    fun productionLimitStaysAtFiftyThousandWithoutScanningPastTheLimit() {
        store = newStore()
        val database = store.writableDatabase
        database.beginTransaction()
        try {
            database.compileStatement(
                "INSERT INTO order_info(tracking_number, payload, push_time) VALUES(?, ?, ?)",
            ).use { statement ->
                repeat(50_000) { index ->
                    statement.bindString(1, "SEEDED-${index.toString().padStart(5, '0')}")
                    statement.bindString(2, "{}")
                    statement.bindLong(3, NOW - 1)
                    statement.executeInsert()
                    statement.clearBindings()
                }
            }
            database.execSQL("UPDATE order_info_state SET record_count = 50000 WHERE singleton = 1")
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }

        store.upsert(listOf(record("NEWEST-AT-LIMIT", pushTimeMillis = NOW)))

        assertNull(store.lookup("SEEDED-00000"))
        assertNotNull(store.lookup("NEWEST-AT-LIMIT"))
        assertEquals(50_000L, persistedCount())
        assertEquals(50_000L, rowCount())
    }

    @Test
    fun cleanupSelectionUsesCompositeIndex() {
        store = newStore()
        val details = mutableListOf<String>()
        store.readableDatabase.rawQuery(
            """
            EXPLAIN QUERY PLAN
            SELECT tracking_number FROM order_info
            WHERE push_time < ?
            ORDER BY push_time ASC, tracking_number ASC
            LIMIT 256
            """.trimIndent(),
            arrayOf(NOW.toString()),
        ).use { cursor ->
            while (cursor.moveToNext()) details += cursor.getString(3)
        }

        assertTrue(details.joinToString("\n"), details.any { it.contains("idx_order_info_cleanup") })
    }

    private fun newStore(
        maxRecords: Int = 50_000,
        cleanupBatchSize: Int = 256,
    ): OrderInfoStore = OrderInfoStore(
        context = context,
        nowMillis = { NOW },
        maxRecords = maxRecords,
        cleanupBatchSize = cleanupBatchSize,
    )

    private fun record(
        trackingNumber: String,
        orderId: String = trackingNumber,
        pushTimeMillis: Long,
    ): OrderInfoRecord = OrderInfoRecord(
        trackingNumber = trackingNumber,
        orderId = orderId,
        buyerMessage = "",
        sellerMemo = "",
        productInfo = "",
        hasRefund = false,
        isPrintedRefund = false,
        refundStatus = "",
        refundProductInfo = "",
        pushTimeMillis = pushTimeMillis,
    )

    private fun insertRaw(database: android.database.sqlite.SQLiteDatabase, record: OrderInfoRecord) {
        val values = ContentValues().apply {
            put("tracking_number", record.trackingNumber)
            put("payload", record.toJson().toString())
            put("push_time", record.pushTimeMillis)
        }
        database.insertOrThrow("order_info", null, values)
    }

    private fun persistedCount(): Long = store.readableDatabase.rawQuery(
        "SELECT record_count FROM order_info_state WHERE singleton = 1",
        null,
    ).use { cursor ->
        check(cursor.moveToFirst())
        cursor.getLong(0)
    }

    private fun rowCount(): Long = store.readableDatabase.rawQuery(
        "SELECT COUNT(*) FROM order_info",
        null,
    ).use { cursor ->
        check(cursor.moveToFirst())
        cursor.getLong(0)
    }

    private fun indexNames(): Set<String> {
        val result = mutableSetOf<String>()
        store.readableDatabase.rawQuery("PRAGMA index_list(order_info)", null).use { cursor ->
            while (cursor.moveToNext()) result += cursor.getString(1)
        }
        return result
    }

    companion object {
        private const val DATABASE_NAME = "order_info.db"
        private const val DAY_MILLIS = 24L * 60 * 60 * 1000
        private const val NOW = 200L * DAY_MILLIS
    }
}
