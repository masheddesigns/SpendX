package com.mashingdesigns.spend_x

import org.junit.Assert.*
import org.junit.Test

class MainActivitySyntheticSmsIsolationTest {

    @Test
    fun testDebugBuildAcceptsSyntheticSmsAction() {
        val action = "com.mashingdesigns.spend_x.TEST_SMS"
        val accepted = MainActivity.shouldAcceptSyntheticSms(action, isDebug = true)
        assertTrue("Debug build must accept com.mashingdesigns.spend_x.TEST_SMS", accepted)
    }

    @Test
    fun testReleaseBuildStrictlyRejectsSyntheticSmsAction() {
        val action = "com.mashingdesigns.spend_x.TEST_SMS"
        val accepted = MainActivity.shouldAcceptSyntheticSms(action, isDebug = false)
        assertFalse("Release build must strictly reject com.mashingdesigns.spend_x.TEST_SMS", accepted)
    }

    @Test
    fun testExternalInvocationCannotInjectSyntheticTransactionsInRelease() {
        // Any external caller invoking with TEST_SMS action in release must be rejected
        val externalActions = listOf(
            "com.mashingdesigns.spend_x.TEST_SMS",
            "com.mashingdesigns.spend_x.TEST_ISLAND",
            "android.intent.action.VIEW",
            "android.intent.action.SEND",
            "android.intent.action.MAIN",
            null,
            "",
            "UNKNOWN_EXTERNAL_ACTION"
        )

        for (action in externalActions) {
            val acceptedInRelease = MainActivity.shouldAcceptSyntheticSms(action, isDebug = false)
            assertFalse(
                "Action '$action' must never be accepted as synthetic test SMS in release build",
                acceptedInRelease
            )
        }
    }

    @Test
    fun testNormalLiveSmsPipelineRemainsUnchanged() {
        // Normal live telephony broadcast uses android.provider.Telephony.SMS_RECEIVED
        // handled exclusively by SmsReceiver (protected by BROADCAST_SMS signature permission).
        val normalTelephonyAction = "android.provider.Telephony.SMS_RECEIVED"
        assertFalse(
            "Telephony broadcast action must not be handled by MainActivity synthetic handler",
            MainActivity.shouldAcceptSyntheticSms(normalTelephonyAction, isDebug = true)
        )
        assertFalse(
            "Telephony broadcast action must not be handled by MainActivity synthetic handler in release",
            MainActivity.shouldAcceptSyntheticSms(normalTelephonyAction, isDebug = false)
        )

        // Verify TelephonyIdentityGenerator generates stable deterministic identities
        val subId = 1
        val timestamp = 1731916800000L
        val sender = "VM-HDFCBK"
        val body = "Rs 1500 debited from HDFC A/c **1234"
        val id1 = TelephonyIdentityGenerator.generateSourceId(subId, timestamp, sender, body)
        val id2 = TelephonyIdentityGenerator.generateSourceId(subId, timestamp, sender, body)
        assertEquals("Production telephony identity generation must be deterministic", id1, id2)
        assertTrue("Identity must start with SRC:TELEPHONY_BROADCAST", id1.startsWith("SRC:TELEPHONY_BROADCAST:1:1731916800000:"))
    }
}
