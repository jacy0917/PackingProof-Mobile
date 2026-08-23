package app.packingproof.mobile

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject

internal class OrderInfoStore(
    context: Context,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val maxRecords: Int = MAX_RECORDS,
    private val cleanupBatchSize: Int = CLEANUP_BATCH_SIZE,
) : SQLiteOpenHelper(
    context,
    "order_info.db",
    null,
    SCHEMA_VERSION,
) {
    init {
        require(maxRecords > 0) { "maxRecords must be positive" }
        require(cleanupBatchSize in 1..SQLITE_SAFE_BIND_LIMIT) {
            "cleanupBatchSize must be between 1 and $SQLITE_SAFE_BIND_LIMIT"
        }
    }

    override fun onCreate(db: SQLiteDatabase) {
        createOrderInfoTable(db)
        createStateTable(db, recordCount = 0)
    }

    private fun createOrderInfoTable(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE order_info (
                tracking_number TEXT PRIMARY KEY,
                payload TEXT NOT NULL,
                push_time INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL(
            "CREATE INDEX idx_order_info_cleanup " +
                "ON order_info(push_time ASC, tracking_number ASC)",
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            // Version 1 could contain payloads decoded with the wrong request
            // charset. Preserve the existing one-time invalid-cache reset.
            db.execSQL("DROP TABLE IF EXISTS order_info_state")
            db.execSQL("DROP TABLE IF EXISTS order_info")
            onCreate(db)
            return
        }
        if (oldVersion < 3) {
            db.execSQL("DROP INDEX IF EXISTS idx_order_info_push_time")
            db.execSQL(
                "CREATE INDEX IF NOT EXISTS idx_order_info_cleanup " +
                    "ON order_info(push_time ASC, tracking_number ASC)",
            )
            createStateTable(db, recordCount = countRows(db))
        }
    }

    @Synchronized
    fun upsert(items: List<OrderInfoRecord>): List<OrderInfoRecord> {
        val incoming = OrderInfoRecord.latestByTrackingNumber(items)
        require(incoming.size <= MAX_UPSERT_ITEMS) {
            "Order batch exceeds $MAX_UPSERT_ITEMS items"
        }
        val stored = mutableListOf<OrderInfoRecord>()
        val db = writableDatabase
        db.beginTransaction()
        try {
            var recordCount = readRecordCount(db)
            for (item in incoming) {
                val existing = findExistingInternal(db, item.trackingNumber)
                val merged = item.mergePreservingConfirmedRefund(existing?.record)
                val values = ContentValues().apply {
                    put("tracking_number", merged.trackingNumber)
                    put("payload", merged.toJson().toString())
                    put("push_time", merged.pushTimeMillis)
                }
                if (existing == null) {
                    db.insertOrThrow("order_info", null, values)
                    recordCount += 1
                } else {
                    check(
                        db.update(
                            "order_info",
                            values,
                            "tracking_number = ?",
                            arrayOf(item.trackingNumber),
                        ) == 1,
                    ) { "Existing order row disappeared during transaction" }
                }
                stored += merged
            }
            recordCount = cleanupInternal(db, recordCount)
            writeRecordCount(db, recordCount)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return stored
    }

    @Synchronized
    fun lookup(trackingNumber: String): OrderInfoRecord? =
        findExistingInternal(readableDatabase, trackingNumber.trim().uppercase())?.record

    private fun findExistingInternal(
        db: SQLiteDatabase,
        trackingNumber: String,
    ): ExistingOrderInfo? {
        db.query(
            "order_info",
            arrayOf("payload"),
            "tracking_number = ?",
            arrayOf(trackingNumber),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            if (!cursor.moveToFirst()) return null
            return ExistingOrderInfo(decode(cursor.getString(0)))
        }
    }

    private fun cleanupInternal(db: SQLiteDatabase, initialCount: Long): Long {
        var recordCount = initialCount
        var remainingBudget = cleanupBatchSize
        val cutoff = nowMillis() - RETENTION_MILLIS
        val expired = oldestTrackingNumbers(
            db = db,
            selection = "push_time < ?",
            selectionArgs = arrayOf(cutoff.toString()),
            limit = remainingBudget,
        )
        val expiredDeleted = deleteTrackingNumbers(db, expired)
        recordCount -= expiredDeleted
        remainingBudget -= expiredDeleted

        val overflow = (recordCount - maxRecords.toLong())
            .coerceAtLeast(0)
            .coerceAtMost(remainingBudget.toLong())
            .toInt()
        if (overflow > 0) {
            val oldest = oldestTrackingNumbers(
                db = db,
                selection = null,
                selectionArgs = null,
                limit = overflow,
            )
            recordCount -= deleteTrackingNumbers(db, oldest)
        }
        return recordCount
    }

    private fun oldestTrackingNumbers(
        db: SQLiteDatabase,
        selection: String?,
        selectionArgs: Array<String>?,
        limit: Int,
    ): List<String> {
        if (limit <= 0) return emptyList()
        val result = ArrayList<String>(limit)
        db.query(
            "order_info",
            arrayOf("tracking_number"),
            selection,
            selectionArgs,
            null,
            null,
            "push_time ASC, tracking_number ASC",
            limit.toString(),
        ).use { cursor ->
            while (cursor.moveToNext()) result += cursor.getString(0)
        }
        return result
    }

    private fun deleteTrackingNumbers(db: SQLiteDatabase, trackingNumbers: List<String>): Int {
        if (trackingNumbers.isEmpty()) return 0
        val placeholders = List(trackingNumbers.size) { "?" }.joinToString(",")
        return db.delete(
            "order_info",
            "tracking_number IN ($placeholders)",
            trackingNumbers.toTypedArray(),
        )
    }

    private fun createStateTable(db: SQLiteDatabase, recordCount: Long) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS order_info_state (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                record_count INTEGER NOT NULL CHECK(record_count >= 0)
            )
            """.trimIndent(),
        )
        val values = ContentValues().apply {
            put("singleton", STATE_SINGLETON)
            put("record_count", recordCount)
        }
        db.insertOrThrow("order_info_state", null, values)
    }

    private fun readRecordCount(db: SQLiteDatabase): Long {
        db.query(
            "order_info_state",
            arrayOf("record_count"),
            "singleton = ?",
            arrayOf(STATE_SINGLETON.toString()),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            check(cursor.moveToFirst()) { "Order info state row is missing" }
            return cursor.getLong(0)
        }
    }

    private fun writeRecordCount(db: SQLiteDatabase, recordCount: Long) {
        val values = ContentValues().apply { put("record_count", recordCount) }
        check(
            db.update(
                "order_info_state",
                values,
                "singleton = ?",
                arrayOf(STATE_SINGLETON.toString()),
            ) == 1,
        ) { "Order info state row is missing" }
    }

    private fun countRows(db: SQLiteDatabase): Long {
        db.rawQuery("SELECT COUNT(*) FROM order_info", null).use { cursor ->
            check(cursor.moveToFirst())
            return cursor.getLong(0)
        }
    }

    private fun decode(payload: String): OrderInfoRecord? = try {
        val value = JSONObject(payload)
        OrderInfoRecord(
            trackingNumber = value.optString("trackingNumber", "").trim().uppercase(),
            orderId = value.optString("orderId", ""),
            buyerMessage = value.optString("buyerMessage", ""),
            sellerMemo = value.optString("sellerMemo", ""),
            productInfo = value.optString("productInfo", ""),
            hasRefund = value.optBoolean("hasRefund", false),
            isPrintedRefund = value.optBoolean("isPrintedRefund", false),
            refundStatus = value.optString("refundStatus", ""),
            refundProductInfo = value.optString("refundProductInfo", ""),
            pushTimeMillis = value.optLong("pushTimeMilliseconds", 0),
            isTest = value.optBoolean("isTest", false),
        )
    } catch (_: Exception) {
        null
    }

    private data class ExistingOrderInfo(val record: OrderInfoRecord?)

    companion object {
        private const val SCHEMA_VERSION = 3
        private const val STATE_SINGLETON = 1
        private const val MAX_RECORDS = 50_000
        private const val CLEANUP_BATCH_SIZE = 256
        private const val MAX_UPSERT_ITEMS = 200
        private const val SQLITE_SAFE_BIND_LIMIT = 999
        private const val RETENTION_MILLIS = 90L * 24 * 60 * 60 * 1000
    }
}
