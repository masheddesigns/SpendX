package com.mashingdesigns.spend_x

import android.Manifest
import android.content.Context
import android.os.Build
import android.provider.Telephony
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "spendx/sms_live"
        const val ENGINE_ID = "spendx_engine"
        private const val RECEIVE_SMS_REQUEST_CODE = 5001
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
                call,
                result,
            ->
            when (call.method) {
                "getPendingSms" -> result.success(SmsStore.all(this))
                "clearPendingSms" -> {
                    SmsStore.clear(this)
                    result.success(null)
                }
                "requestReceiveSmsPermission" -> {
                    requestReceiveSmsPermission()
                    result.success(null)
                }
                "queryInboxSince" -> {
                    val sinceEpochMs = (call.argument<Number>("sinceEpochMs"))?.toLong()
                    val limit = (call.argument<Number>("limit"))?.toInt() ?: 5000
                    result.success(queryInboxSince(sinceEpochMs, limit))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun queryInboxSince(sinceEpochMs: Long?, limit: Int): List<Map<String, Any?>> {
        val messages = mutableListOf<Map<String, Any?>>()
        val uri = Telephony.Sms.Inbox.CONTENT_URI
        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.THREAD_ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.DATE_SENT,
        )
        val selection = if (sinceEpochMs != null && sinceEpochMs > 0) "${Telephony.Sms.DATE} >= ?" else null
        val selectionArgs = if (sinceEpochMs != null && sinceEpochMs > 0) arrayOf(sinceEpochMs.toString()) else null
        val sortOrder = "${Telephony.Sms.DATE} DESC"

        val cursor = contentResolver.query(uri, projection, selection, selectionArgs, sortOrder)
        cursor?.use {
            var count = 0
            while (it.moveToNext() && count < limit) {
                messages.add(
                    mapOf(
                        "id" to it.getLong(it.getColumnIndexOrThrow(Telephony.Sms._ID)),
                        "thread_id" to it.getInt(it.getColumnIndexOrThrow(Telephony.Sms.THREAD_ID)),
                        "address" to it.getString(it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)),
                        "body" to it.getString(it.getColumnIndexOrThrow(Telephony.Sms.BODY)),
                        "date" to it.getLong(it.getColumnIndexOrThrow(Telephony.Sms.DATE)),
                        "date_sent" to it.getLong(it.getColumnIndexOrThrow(Telephony.Sms.DATE_SENT)),
                    ),
                )
                count++
            }
        }
        return messages
    }

    private fun requestReceiveSmsPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.RECEIVE_SMS),
                RECEIVE_SMS_REQUEST_CODE,
            )
        }
    }
}

/// Tiny shared-prefs queue for SMS captured while the app isn't running.
object SmsStore {
    private const val PREFS = "spendx_sms"
    private const val KEY = "pending_sms_queue"
    private const val SEP = "\u0001"

    fun queue(context: Context, bodies: List<String>) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val existing = prefs.getString(KEY, "") ?: ""
        val merged = (existing.split(SEP) + bodies)
            .filter { it.isNotBlank() }
            .distinct()
        prefs.edit().putString(KEY, merged.joinToString(SEP)).apply()
    }

    fun all(context: Context): List<String> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return (prefs.getString(KEY, "") ?: "").split(SEP).filter { it.isNotBlank() }
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY).apply()
    }
}
