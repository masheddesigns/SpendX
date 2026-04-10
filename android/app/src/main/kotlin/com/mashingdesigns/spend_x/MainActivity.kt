package com.mashingdesigns.spend_x

import android.content.IntentFilter
import android.provider.Telephony
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val smsChannel = "spend_x/sms"
    private val smsStreamChannel = "spend_x/sms_stream"
    private var smsReceiver: SmsReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Existing: fetch recent SMS on demand ────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, smsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "fetchRecent" -> {
                        val limit = call.argument<Int>("limit") ?: 20
                        val sinceMillis = call.argument<Long>("sinceMillis") ?: 0L
                        result.success(fetchRecentSms(limit, sinceMillis))
                    }
                    else -> result.notImplemented()
                }
            }

        // ── New: stream incoming SMS in real-time ───────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, smsStreamChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    // Register receiver when Flutter starts listening
                    smsReceiver = SmsReceiver()
                    SmsReceiver.onSmsReceived = { smsData ->
                        activity?.runOnUiThread {
                            events?.success(smsData)
                        }
                    }
                    val filter = IntentFilter(Telephony.Sms.Intents.SMS_RECEIVED_ACTION)
                    filter.priority = 999
                    registerReceiver(smsReceiver, filter)
                }

                override fun onCancel(arguments: Any?) {
                    // Unregister when Flutter stops listening
                    smsReceiver?.let {
                        try { unregisterReceiver(it) } catch (_: Exception) {}
                    }
                    SmsReceiver.onSmsReceived = null
                    smsReceiver = null
                }
            })
    }

    override fun onDestroy() {
        smsReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        SmsReceiver.onSmsReceived = null
        smsReceiver = null
        super.onDestroy()
    }

    private fun fetchRecentSms(limit: Int, sinceMillis: Long): List<Map<String, Any?>> {
        val messages = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE
        )

        val cursor = contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            projection,
            if (sinceMillis > 0) "${Telephony.Sms.DATE} >= ?" else null,
            if (sinceMillis > 0) arrayOf(sinceMillis.toString()) else null,
            "${Telephony.Sms.DATE} DESC LIMIT $limit"
        )

        cursor?.use {
            val addressIndex = it.getColumnIndex(Telephony.Sms.ADDRESS)
            val bodyIndex = it.getColumnIndex(Telephony.Sms.BODY)
            val dateIndex = it.getColumnIndex(Telephony.Sms.DATE)

            while (it.moveToNext()) {
                messages.add(
                    mapOf(
                        "sender" to if (addressIndex >= 0) it.getString(addressIndex) else null,
                        "body" to if (bodyIndex >= 0) it.getString(bodyIndex) else null,
                        "date" to if (dateIndex >= 0) it.getLong(dateIndex) else 0L,
                    )
                )
            }
        }

        return messages
    }
}
