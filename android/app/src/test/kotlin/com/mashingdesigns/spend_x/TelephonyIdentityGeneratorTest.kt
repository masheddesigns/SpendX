package com.mashingdesigns.spend_x

import org.junit.Assert.*
import org.junit.Test

class TelephonyIdentityGeneratorTest {

    @Test
    fun testDeterministicHashGeneration() {
        val subId = 1
        val timestamp = 1731950000000L
        val sender = "VM-HDFCBK"
        val body = "Rs 500.00 debited from A/C **1234"

        val id1 = TelephonyIdentityGenerator.generateSourceId(subId, timestamp, sender, body)
        val id2 = TelephonyIdentityGenerator.generateSourceId(subId, timestamp, sender, body)

        assertEquals("Source IDs must be deterministic", id1, id2)
        assertTrue("Source ID must start with SRC:TELEPHONY_BROADCAST:1:", id1.startsWith("SRC:TELEPHONY_BROADCAST:1:1731950000000:"))
    }

    @Test
    fun testSenderCaseAndWhitespaceNormalization() {
        val subId = 0
        val timestamp = 1731950000000L
        val body = "Rs 1000.00 debited"

        val idUpper = TelephonyIdentityGenerator.generateSourceId(subId, timestamp, "  vm-hdfcbk  ", body)
        val idNormal = TelephonyIdentityGenerator.generateSourceId(subId, timestamp, "VM-HDFCBK", body)

        assertEquals("Sender casing and leading/trailing whitespace must be normalized", idNormal, idUpper)
    }

    @Test
    fun testBodyWhitespaceTrimming() {
        val subId = 0
        val timestamp = 1731950000000L
        val sender = "VM-HDFCBK"

        val idTrimmed = TelephonyIdentityGenerator.generateSourceId(subId, timestamp, sender, "Rs 1000.00 debited")
        val idUntrimmed = TelephonyIdentityGenerator.generateSourceId(subId, timestamp, sender, "  Rs 1000.00 debited \n ")

        assertEquals("Body whitespace trimming must result in identical source ID", idTrimmed, idUntrimmed)
    }

    @Test
    fun testSubscriptionIdHandling() {
        val timestamp = 1731950000000L
        val sender = "VM-HDFCBK"
        val body = "Rs 500.00 debited"

        val idSub0 = TelephonyIdentityGenerator.generateSourceId(0, timestamp, sender, body)
        val idSub1 = TelephonyIdentityGenerator.generateSourceId(1, timestamp, sender, body)
        val idSubUnknown = TelephonyIdentityGenerator.generateSourceId(-1, timestamp, sender, body)

        assertTrue(idSub0.startsWith("SRC:TELEPHONY_BROADCAST:0:"))
        assertTrue(idSub1.startsWith("SRC:TELEPHONY_BROADCAST:1:"))
        assertTrue(idSubUnknown.startsWith("SRC:TELEPHONY_BROADCAST:UNKNOWN:"))

        assertNotEquals(idSub0, idSub1)
        assertNotEquals(idSub0, idSubUnknown)
    }

    @Test
    fun testDifferentBodiesProduceDistinctIdentities() {
        val subId = 0
        val timestamp = 1731950000000L
        val sender = "VM-HDFCBK"

        val idA = TelephonyIdentityGenerator.generateSourceId(subId, timestamp, sender, "Rs 100 debited")
        val idB = TelephonyIdentityGenerator.generateSourceId(subId, timestamp, sender, "Rs 200 debited")

        assertNotEquals("Distinct message bodies must produce distinct identity hashes", idA, idB)
    }

    @Test
    fun testDifferentTimestampsProduceDistinctIdentities() {
        val subId = 0
        val sender = "VM-HDFCBK"
        val body = "Rs 100 debited"

        val idA = TelephonyIdentityGenerator.generateSourceId(subId, 1731950000000L, sender, body)
        val idB = TelephonyIdentityGenerator.generateSourceId(subId, 1731950001000L, sender, body)

        assertNotEquals("Distinct timestamps must produce distinct identities", idA, idB)
    }
}
