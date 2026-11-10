package org.omnilink.transport

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log

/**
 * Durable inbound payload spool.
 *
 * Every payload received from a radio is written here before it is emitted to
 * Flutter. Dart acknowledges a row only after it has accepted (and durably
 * persisted) the packet. A Flutter engine teardown, process death, or a full
 * event buffer therefore cannot lose an inbound message.
 */
class OmnilinkInboundSpool private constructor(context: Context) :
    SQLiteOpenHelper(context.applicationContext, DB_NAME, null, DB_VERSION) {

    data class SpooledPayload(
        val id: Long,
        val endpointId: String,
        val bytes: ByteArray,
        val receivedAt: Long,
    )

    init {
        try {
            setWriteAheadLoggingEnabled(true)
        } catch (e: Exception) {
            Log.w(TAG, "Unable to enable WAL for inbound spool: ${e.message}")
        }
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE inbound_spool (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                endpoint_id TEXT NOT NULL,
                payload BLOB NOT NULL,
                received_at INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX idx_inbound_spool_received ON inbound_spool(received_at)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // The spool is a transport buffer, not user data. A schema change may
        // safely discard unacknowledged transport rows; senders retain their
        // own receipt-driven outbox copies and will retry.
        db.execSQL("DROP TABLE IF EXISTS inbound_spool")
        onCreate(db)
    }

    /** Persists one payload and returns its spool row id, or null on failure. */
    @Synchronized
    fun append(endpointId: String, bytes: ByteArray): Long? {
        return try {
            val values = ContentValues().apply {
                put("endpoint_id", endpointId)
                put("payload", bytes)
                put("received_at", System.currentTimeMillis())
            }
            val id = writableDatabase.insert("inbound_spool", null, values)
            if (id <= 0L) {
                Log.e(TAG, "Spool insert returned invalid id=$id")
                null
            } else {
                enforceCapacityLocked()
                id
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to spool inbound payload: ${e.message}", e)
            null
        }
    }

    /** Removes a row after Dart has durably accepted it. */
    @Synchronized
    fun acknowledge(id: Long) {
        try {
            writableDatabase.delete("inbound_spool", "id = ?", arrayOf(id.toString()))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acknowledge spool row $id: ${e.message}", e)
        }
    }

    /** Oldest-first pending rows for replay. */
    @Synchronized
    fun pending(limit: Int = DEFAULT_REPLAY_LIMIT): List<SpooledPayload> {
        val result = mutableListOf<SpooledPayload>()
        try {
            readableDatabase.query(
                "inbound_spool",
                arrayOf("id", "endpoint_id", "payload", "received_at"),
                null,
                null,
                null,
                null,
                "id ASC",
                limit.toString(),
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    val blob = cursor.getBlob(2) ?: continue
                    result.add(
                        SpooledPayload(
                            id = cursor.getLong(0),
                            endpointId = cursor.getString(1),
                            bytes = blob,
                            receivedAt = cursor.getLong(3),
                        ),
                    )
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read inbound spool: ${e.message}", e)
        }
        return result
    }

    @Synchronized
    fun count(): Int {
        return try {
            readableDatabase.rawQuery("SELECT COUNT(*) FROM inbound_spool", null).use { cursor ->
                if (cursor.moveToFirst()) cursor.getInt(0) else 0
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to count inbound spool: ${e.message}", e)
            0
        }
    }

    @Synchronized
    fun clearAll() {
        try {
            writableDatabase.delete("inbound_spool", null, null)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clear inbound spool: ${e.message}", e)
        }
    }

    private fun enforceCapacityLocked() {
        try {
            val rows = count()
            if (rows <= MAX_ROWS) return
            val overflow = rows - MAX_ROWS
            writableDatabase.execSQL(
                "DELETE FROM inbound_spool WHERE id IN " +
                    "(SELECT id FROM inbound_spool ORDER BY id ASC LIMIT ?)",
                arrayOf(overflow),
            )
            Log.w(TAG, "Inbound spool overflow: evicted $overflow oldest payload(s)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to enforce spool capacity: ${e.message}", e)
        }
    }

    companion object {
        private const val TAG = "OMNILINK_SPOOL"
        private const val DB_NAME = "omnilink_inbound_spool.db"
        private const val DB_VERSION = 1
        private const val MAX_ROWS = 5_000
        private const val DEFAULT_REPLAY_LIMIT = 256

        @Volatile
        private var INSTANCE: OmnilinkInboundSpool? = null

        fun getInstance(context: Context): OmnilinkInboundSpool {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: OmnilinkInboundSpool(context).also { INSTANCE = it }
            }
        }
    }
}
