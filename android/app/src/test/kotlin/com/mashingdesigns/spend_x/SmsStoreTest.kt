package com.mashingdesigns.spend_x

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class SmsStoreTest {

    private lateinit var mockStorage: ConcurrentHashMap<String, Any>
    private lateinit var testContext: Context

    @Before
    fun setUp() {
        mockStorage = ConcurrentHashMap()
        val mockPrefs = InMemorySharedPreferences(mockStorage)
        testContext = object : ContextWrapper(null) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences {
                return mockPrefs
            }
        }
    }

    @Test
    fun testQueueSingleMessage() {
        val success = SmsStore.queue(
            testContext,
            sender = "VM-HDFCBK",
            body = "Rs 500 debited",
            sourceRecordId = "SRC:1"
        )
        assertTrue(success)

        val all = SmsStore.all(testContext)
        assertEquals(1, all.size)
        assertEquals("VM-HDFCBK", all[0]["sender"])
        assertEquals("Rs 500 debited", all[0]["body"])
        assertEquals("SRC:1", all[0]["sourceRecordId"])
    }

    @Test
    fun testDeduplicationBySourceRecordId() {
        // Enqueue identical sourceRecordId twice
        SmsStore.queue(testContext, "VM-HDFCBK", "Rs 500 debited", "SRC:DUP:1")
        SmsStore.queue(testContext, "VM-HDFCBK", "Rs 500 debited", "SRC:DUP:1")

        val all = SmsStore.all(testContext)
        assertEquals("Duplicate sourceRecordId must not create duplicate queue entries", 1, all.size)
        assertEquals("SRC:DUP:1", all[0]["sourceRecordId"])
    }

    @Test
    fun testDistinctSourceRecordIdsWithSameBodyRetained() {
        // Two distinct transactions with same amount/body (e.g. two consecutive Rs 50 coffee purchases)
        SmsStore.queue(testContext, "VM-HDFCBK", "Rs 50 debited", "SRC:COFFEE:1")
        SmsStore.queue(testContext, "VM-HDFCBK", "Rs 50 debited", "SRC:COFFEE:2")

        val all = SmsStore.all(testContext)
        assertEquals("Distinct sourceRecordIds must both be queued", 2, all.size)
        assertEquals("SRC:COFFEE:1", all[0]["sourceRecordId"])
        assertEquals("SRC:COFFEE:2", all[1]["sourceRecordId"])
    }

    @Test
    fun testAtomicRemoveBySourceRecordId() {
        SmsStore.queue(testContext, "VM-HDFCBK", "Msg 1", "SRC:1")
        SmsStore.queue(testContext, "VM-HDFCBK", "Msg 2", "SRC:2")
        SmsStore.queue(testContext, "VM-HDFCBK", "Msg 3", "SRC:3")

        // Remove only SRC:2
        val removed = SmsStore.remove(testContext, setOf("SRC:2"))
        assertTrue(removed)

        val remaining = SmsStore.all(testContext)
        assertEquals(2, remaining.size)
        val remainingIds = remaining.map { it["sourceRecordId"] }.toSet()
        assertTrue(remainingIds.contains("SRC:1"))
        assertTrue(remainingIds.contains("SRC:3"))
        assertFalse(remainingIds.contains("SRC:2"))
    }

    @Test
    fun testClearRemovesAllEntries() {
        SmsStore.queue(testContext, "VM-HDFCBK", "Msg 1", "SRC:1")
        SmsStore.queue(testContext, "VM-HDFCBK", "Msg 2", "SRC:2")

        val cleared = SmsStore.clear(testContext)
        assertTrue(cleared)

        val all = SmsStore.all(testContext)
        assertTrue("Queue must be empty after clear()", all.isEmpty())
    }

    @Test
    fun testLegacyEntriesUpgradedWithStableIdentity() {
        // Pre-populate SharedPreferences with raw legacy entry lacking sourceRecordId
        // Format: sender \u0002 body
        val rawLegacy = "VM-HDFCBK\u0002Legacy Rs 100 debited"
        mockStorage["pending_sms_queue"] = rawLegacy

        val all = SmsStore.all(testContext)
        assertEquals(1, all.size)
        assertEquals("VM-HDFCBK", all[0]["sender"])
        assertEquals("Legacy Rs 100 debited", all[0]["body"])

        val generatedId = all[0]["sourceRecordId"]
        assertNotNull(generatedId)
        assertTrue("Legacy entry must be assigned SRC:LEGACY_QUEUE:*", generatedId!!.startsWith("SRC:LEGACY_QUEUE:"))

        // Verify that the generated ID is stably persisted back to storage
        val secondRead = SmsStore.all(testContext)
        assertEquals("Assigned legacy ID must be durable on subsequent reads", generatedId, secondRead[0]["sourceRecordId"])
    }

    @Test
    fun testCorruptEntryResilience() {
        // Test entry without any field separators
        val corruptRaw = "JustACompletelyCorruptRawStringWithoutSeparators"
        mockStorage["pending_sms_queue"] = corruptRaw

        val all = SmsStore.all(testContext)
        assertEquals(1, all.size)
        assertEquals("", all[0]["sender"])
        assertEquals("JustACompletelyCorruptRawStringWithoutSeparators", all[0]["body"])
        assertTrue(all[0]["sourceRecordId"]!!.startsWith("SRC:LEGACY_QUEUE:"))
    }

    @Test
    fun testConcurrentQueueOperations() {
        val count = 50
        val latch = CountDownLatch(count)

        for (i in 0 until count) {
            thread {
                try {
                    SmsStore.queue(testContext, "SENDER_$i", "Body $i", "SRC:CONCURRENT:$i")
                } finally {
                    latch.countDown()
                }
            }
        }

        assertTrue("All concurrent threads must finish", latch.await(5, TimeUnit.SECONDS))
        val all = SmsStore.all(testContext)
        assertEquals("All $count messages queued concurrently must survive", count, all.size)
    }

    // ─── Lightweight In-Memory SharedPreferences ────────────────────────────────
    private class InMemorySharedPreferences(private val storage: ConcurrentHashMap<String, Any>) : SharedPreferences {

        override fun getAll(): Map<String, *> = storage
        override fun getString(key: String?, defValue: String?): String? = storage[key] as? String ?: defValue
        override fun getStringSet(key: String?, defValues: Set<String>?): Set<String>? =
            @Suppress("UNCHECKED_CAST") (storage[key] as? Set<String> ?: defValues)
        override fun getInt(key: String?, defValue: Int): Int = storage[key] as? Int ?: defValue
        override fun getLong(key: String?, defValue: Long): Long = storage[key] as? Long ?: defValue
        override fun getFloat(key: String?, defValue: Float): Float = storage[key] as? Float ?: defValue
        override fun getBoolean(key: String?, defValue: Boolean): Boolean = storage[key] as? Boolean ?: defValue
        override fun contains(key: String?): Boolean = storage.containsKey(key)
        override fun edit(): SharedPreferences.Editor = InMemoryEditor(storage)
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}

        private class InMemoryEditor(private val storage: ConcurrentHashMap<String, Any>) : SharedPreferences.Editor {
            private val pendingChanges = mutableMapOf<String, Any?>()
            private var clearRequested = false

            override fun putString(key: String?, value: String?): SharedPreferences.Editor {
                if (key != null) pendingChanges[key] = value
                return this
            }
            override fun putStringSet(key: String?, values: Set<String>?): SharedPreferences.Editor {
                if (key != null) pendingChanges[key] = values
                return this
            }
            override fun putInt(key: String?, value: Int): SharedPreferences.Editor {
                if (key != null) pendingChanges[key] = value
                return this
            }
            override fun putLong(key: String?, value: Long): SharedPreferences.Editor {
                if (key != null) pendingChanges[key] = value
                return this
            }
            override fun putFloat(key: String?, value: Float): SharedPreferences.Editor {
                if (key != null) pendingChanges[key] = value
                return this
            }
            override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor {
                if (key != null) pendingChanges[key] = value
                return this
            }
            override fun remove(key: String?): SharedPreferences.Editor {
                if (key != null) pendingChanges[key] = null
                return this
            }
            override fun clear(): SharedPreferences.Editor {
                clearRequested = true
                return this
            }
            override fun commit(): Boolean {
                synchronized(storage) {
                    if (clearRequested) storage.clear()
                    for ((k, v) in pendingChanges) {
                        if (v == null) {
                            storage.remove(k)
                        } else {
                            storage[k] = v
                        }
                    }
                }
                return true
            }
            override fun apply() {
                commit()
            }
        }
    }
}
