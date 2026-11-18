package com.mashingdesigns.spend_x

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap

class MultipartSmsBoundaryAuditTest {

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

    // ─── 1. Valid single-part SMS ─────────────────────────────────────────────
    @Test
    fun test01_ValidSinglePartSms() {
        val segment = SmsReceiver.RawSmsSegment(
            originatingAddress = "VM-HDFCBK",
            body = "Rs 1,500.00 debited from A/C **1234 on 18-Nov-26 towards AMAZON. Avl Bal: Rs 45,000.00",
            timestampMillis = 1731950000000L
        )

        val reassembled = SmsReceiver.validateAndReassemble(listOf(segment), subId = 0)
        assertNotNull("Valid single-part financial SMS must be accepted", reassembled)
        assertEquals("VM-HDFCBK", reassembled!!.sender)
        assertEquals(segment.body, reassembled.fullBody)
        assertEquals(1731950000000L, reassembled.timestampMillis)
        assertTrue(reassembled.sourceRecordId.startsWith("SRC:TELEPHONY_BROADCAST:0:1731950000000:"))
    }

    // ─── 2. Valid multipart SMS with two segments ──────────────────────────────
    @Test
    fun test02_ValidMultipartSmsWithTwoSegments() {
        val seg1 = SmsReceiver.RawSmsSegment(
            originatingAddress = "VM-HDFCBK",
            body = "Rs 2,499.00 debited from HDFC Bank A/C **5678 on 18-Nov-26 18:30:15 ",
            timestampMillis = 1731950000000L
        )
        val seg2 = SmsReceiver.RawSmsSegment(
            originatingAddress = "VM-HDFCBK",
            body = "towards FLIPKART. Avl Bal: Rs 28,100.50. Ref: 432109876543.",
            timestampMillis = 1731950000000L
        )

        val reassembled = SmsReceiver.validateAndReassemble(listOf(seg1, seg2), subId = 1)
        assertNotNull("Valid 2-segment multipart SMS must be reassembled", reassembled)
        assertEquals("VM-HDFCBK", reassembled!!.sender)
        assertEquals(seg1.body + seg2.body, reassembled.fullBody)
        assertEquals(1, reassembled.subId)
        assertTrue(reassembled.sourceRecordId.startsWith("SRC:TELEPHONY_BROADCAST:1:1731950000000:"))
    }

    // ─── 3. Valid multipart SMS with three or more segments ─────────────────────
    @Test
    fun test03_ValidMultipartSmsWithThreeOrMoreSegments() {
        val seg1 = SmsReceiver.RawSmsSegment("AD-SBIINB", "Dear Customer, your Account ending 9988 ", 1731950100000L)
        val seg2 = SmsReceiver.RawSmsSegment("AD-SBIINB", "has been credited by Rs 50,000.00 on 18-Nov-26 ", 1731950100000L)
        val seg3 = SmsReceiver.RawSmsSegment("AD-SBIINB", "by transfer from SALARY. Total Avail Bal Rs 1,12,000.00.", 1731950100000L)

        val reassembled = SmsReceiver.validateAndReassemble(listOf(seg1, seg2, seg3), subId = 0)
        assertNotNull("Valid 3-segment multipart SMS must be reassembled", reassembled)
        assertEquals("AD-SBIINB", reassembled!!.sender)
        assertEquals(seg1.body + seg2.body + seg3.body, reassembled.fullBody)
    }

    // ─── 4. Reordered segments ────────────────────────────────────────────────
    @Test
    fun test04_ReorderedSegments() {
        // If segments arrive reordered (e.g. seg2 before seg1)
        val seg1 = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Part 1: Rs 500 debited from A/c 1234 ", 1731950000000L)
        val seg2 = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Part 2: towards Swiggy. Avl Bal Rs 5,000.", 1731950000000L)

        val natural = SmsReceiver.validateAndReassemble(listOf(seg1, seg2), 0)
        val inverted = SmsReceiver.validateAndReassemble(listOf(seg2, seg1), 0)

        assertNotNull(natural)
        assertNotNull(inverted)
        assertNotEquals("Different segment orders produce distinct body content", natural!!.fullBody, inverted!!.fullBody)
        assertNotEquals("Different reassembled bodies yield distinct source identities", natural.sourceRecordId, inverted.sourceRecordId)
    }

    // ─── 5. Missing segment (incomplete text) ──────────────────────────────────
    @Test
    fun test05_MissingSegment() {
        // Only the second segment of a split message arrives; lacking financial amount
        val segMissingAmount = SmsReceiver.RawSmsSegment(
            originatingAddress = "VM-HDFCBK",
            body = "towards Merchant XYZ. Thank you for using HDFC netbanking.",
            timestampMillis = 1731950000000L
        )

        val reassembled = SmsReceiver.validateAndReassemble(listOf(segMissingAmount), subId = 0)
        assertNull("Incomplete segment lacking financial amount must be dropped", reassembled)
    }

    // ─── 6. Duplicate segment ─────────────────────────────────────────────────
    @Test
    fun test06_DuplicateSegment() {
        val seg1 = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Rs 500 debited from A/c 1234. ", 1731950000000L)
        val segDup = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Rs 500 debited from A/c 1234. ", 1731950000000L)

        val reassembled = SmsReceiver.validateAndReassemble(listOf(seg1, segDup), subId = 0)
        assertNotNull(reassembled)
        // Both segments concatenated: "Rs 500 debited from A/c 1234. Rs 500 debited from A/c 1234. "
        assertTrue(reassembled!!.fullBody.contains("Rs 500 debited"))
    }

    // ─── 7. Malformed PDU / completely empty bodies ────────────────────────────
    @Test
    fun test07_MalformedPdu() {
        val malformed = SmsReceiver.RawSmsSegment(
            originatingAddress = "VM-HDFCBK",
            body = null,
            timestampMillis = 1731950000000L
        )
        val reassembled = SmsReceiver.validateAndReassemble(listOf(malformed), subId = 0)
        assertNull("Malformed segment with null body must be dropped", reassembled)
    }

    // ─── 8. Empty segment (whitespace-only body) ───────────────────────────────
    @Test
    fun test08_EmptySegment() {
        val emptySeg = SmsReceiver.RawSmsSegment("VM-HDFCBK", "   \n\t  ", 1731950000000L)
        val validSeg = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Rs 750 debited from A/c **4321. Avl Bal Rs 10,000", 1731950000000L)

        val reassembled = SmsReceiver.validateAndReassemble(listOf(emptySeg, validSeg), subId = 0)
        assertNotNull(reassembled)
        assertEquals("Whitespace-only segments must be filtered out without breaking concatenation", validSeg.body, reassembled!!.fullBody)
    }

    // ─── 9. Different sender across segments ──────────────────────────────────
    @Test
    fun test09_DifferentSenderAcrossSegments() {
        val seg1 = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Rs 1,000 debited ", 1731950000000L)
        val seg2 = SmsReceiver.RawSmsSegment("AD-AIRTEL", "from your account towards Airtel.", 1731950000000L)

        val reassembled = SmsReceiver.validateAndReassemble(listOf(seg1, seg2), subId = 0)
        assertNull("Segments with conflicting originating addresses must be strictly rejected", reassembled)
    }

    // ─── 10. Different subscription identities ────────────────────────────────
    @Test
    fun test10_DifferentSubscriptionIdentities() {
        val seg = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Rs 500 debited from A/c 1234", 1731950000000L)

        val resSub0 = SmsReceiver.validateAndReassemble(listOf(seg), subId = 0)
        val resSub1 = SmsReceiver.validateAndReassemble(listOf(seg), subId = 1)

        assertNotNull(resSub0)
        assertNotNull(resSub1)
        assertNotEquals("Different subscriptions must produce distinct sourceRecordIds", resSub0!!.sourceRecordId, resSub1!!.sourceRecordId)
        assertTrue(resSub0.sourceRecordId.startsWith("SRC:TELEPHONY_BROADCAST:0:"))
        assertTrue(resSub1.sourceRecordId.startsWith("SRC:TELEPHONY_BROADCAST:1:"))
    }

    // ─── 11. Timestamp inconsistency across segments ──────────────────────────
    @Test
    fun test11_TimestampInconsistency() {
        val seg1 = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Rs 1,000 debited ", 1731950000000L)
        val seg2Drift = SmsReceiver.RawSmsSegment("VM-HDFCBK", "from A/c **1234. Avl Bal Rs 5,000", 1731950100000L) // 100 seconds later

        val reassembled = SmsReceiver.validateAndReassemble(listOf(seg1, seg2Drift), subId = 0)
        assertNull("Segments with timestamps drifting > 60s must be rejected as conflicting broadcasts", reassembled)
    }

    // ─── 12. Duplicate broadcast of same complete message ─────────────────────
    @Test
    fun test12_DuplicateBroadcastOfSameCompleteMessage() {
        val seg1 = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Rs 800 debited from A/c **1122. Avl Bal Rs 12,000", 1731950000000L)

        val deliveryA = SmsReceiver.validateAndReassemble(listOf(seg1), subId = 0)
        val deliveryB = SmsReceiver.validateAndReassemble(listOf(seg1), subId = 0)

        assertNotNull(deliveryA)
        assertNotNull(deliveryB)
        assertEquals("Identical broadcast reassembly must be 100% idempotent", deliveryA!!.sourceRecordId, deliveryB!!.sourceRecordId)

        // Verify native queue deduplication
        SmsStore.queue(testContext, deliveryA.sender, deliveryA.fullBody, deliveryA.sourceRecordId)
        SmsStore.queue(testContext, deliveryB.sender, deliveryB.fullBody, deliveryB.sourceRecordId)

        val queue = SmsStore.all(testContext)
        assertEquals("Duplicate broadcast delivery must result in exactly 1 queue entry", 1, queue.size)
    }

    // ─── 13. Two distinct messages from same sender with similar content ──────
    @Test
    fun test13_TwoDistinctMessagesSameSenderSimilarContent() {
        val segA = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Rs 50.00 debited from A/c **1234 for Tea", 1731950000000L)
        val segB = SmsReceiver.RawSmsSegment("VM-HDFCBK", "Rs 50.00 debited from A/c **1234 for Tea", 1731950060000L) // 60s later

        val resA = SmsReceiver.validateAndReassemble(listOf(segA), subId = 0)
        val resB = SmsReceiver.validateAndReassemble(listOf(segB), subId = 0)

        assertNotNull(resA)
        assertNotNull(resB)
        assertNotEquals("Distinct transactions must have distinct sourceRecordIds due to timestamp", resA!!.sourceRecordId, resB!!.sourceRecordId)

        SmsStore.queue(testContext, resA.sender, resA.fullBody, resA.sourceRecordId)
        SmsStore.queue(testContext, resB.sender, resB.fullBody, resB.sourceRecordId)

        val queue = SmsStore.all(testContext)
        assertEquals("Both legitimate separate transactions must be preserved in queue", 2, queue.size)
    }

    // ─── 14. Process interruption between queue insertion and drain ────────────
    @Test
    fun test14_ProcessInterruptionBetweenQueueInsertionAndDrain() {
        // Enqueue message
        val id = "SRC:TELEPHONY_BROADCAST:0:1731950000000:hash14"
        SmsStore.queue(testContext, "VM-HDFCBK", "Rs 100 debited", id)

        // Simulate process termination by instantiating fresh context pointing to same storage
        val newContext = object : ContextWrapper(null) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences {
                return InMemorySharedPreferences(mockStorage)
            }
        }

        val reloadedQueue = SmsStore.all(newContext)
        assertEquals("Queue must survive process death and reload from persistent storage", 1, reloadedQueue.size)
        assertEquals(id, reloadedQueue[0]["sourceRecordId"])
    }

    // ─── 15. Retry after interrupted queue drain ──────────────────────────────
    @Test
    fun test15_RetryAfterInterruptedQueueDrain() {
        val id1 = "SRC:TELEPHONY_BROADCAST:0:1731950000000:id1"
        val id2 = "SRC:TELEPHONY_BROADCAST:0:1731950001000:id2"
        SmsStore.queue(testContext, "VM-HDFCBK", "Txn 1", id1)
        SmsStore.queue(testContext, "VM-HDFCBK", "Txn 2", id2)

        // Drain begins: Txn 1 is processed and removed, but process is interrupted before Txn 2 is removed
        SmsStore.remove(testContext, setOf(id1))

        // Interruption: new process starts up
        val freshContext = object : ContextWrapper(null) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences {
                return InMemorySharedPreferences(mockStorage)
            }
        }

        val remaining = SmsStore.all(freshContext)
        assertEquals("Unacknowledged item (Txn 2) must remain in queue for retry", 1, remaining.size)
        assertEquals(id2, remaining[0]["sourceRecordId"])

        // Second drain attempt removes Txn 2 successfully
        SmsStore.remove(freshContext, setOf(id2))
        assertTrue("Queue must be empty after complete drain acknowledgment", SmsStore.all(freshContext).isEmpty())
    }

    // ─── In-Memory Storage Helper ─────────────────────────────────────────────
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
            private val pending = mutableMapOf<String, Any?>()
            private var clearRequested = false

            override fun putString(key: String?, value: String?): SharedPreferences.Editor {
                if (key != null) pending[key] = value
                return this
            }
            override fun putStringSet(key: String?, values: Set<String>?): SharedPreferences.Editor {
                if (key != null) pending[key] = values
                return this
            }
            override fun putInt(key: String?, value: Int): SharedPreferences.Editor {
                if (key != null) pending[key] = value
                return this
            }
            override fun putLong(key: String?, value: Long): SharedPreferences.Editor {
                if (key != null) pending[key] = value
                return this
            }
            override fun putFloat(key: String?, value: Float): SharedPreferences.Editor {
                if (key != null) pending[key] = value
                return this
            }
            override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor {
                if (key != null) pending[key] = value
                return this
            }
            override fun remove(key: String?): SharedPreferences.Editor {
                if (key != null) pending[key] = null
                return this
            }
            override fun clear(): SharedPreferences.Editor {
                clearRequested = true
                return this
            }
            override fun commit(): Boolean {
                synchronized(storage) {
                    if (clearRequested) storage.clear()
                    for ((k, v) in pending) {
                        if (v == null) storage.remove(k) else storage[k] = v
                    }
                }
                return true
            }
            override fun apply() { commit() }
        }
    }
}
