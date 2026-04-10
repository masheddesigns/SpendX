package com.mashingdesigns.spend_x

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

/**
 * Receives incoming SMS and forwards to Flutter via a shared sink.
 * Registered dynamically from MainActivity (not in manifest — avoids
 * waking the app when it's not running).
 */
class SmsReceiver : BroadcastReceiver() {

    companion object {
        /** Set by MainActivity when EventChannel listener attaches. */
        var onSmsReceived: ((Map<String, Any?>) -> Unit)? = null
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        for (msg in messages) {
            val data = mapOf<String, Any?>(
                "sender" to msg.originatingAddress,
                "body" to msg.messageBody,
                "date" to msg.timestampMillis,
            )
            onSmsReceived?.invoke(data)
        }
    }
}
