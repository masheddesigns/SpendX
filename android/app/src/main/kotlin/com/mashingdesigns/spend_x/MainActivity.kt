package com.mashingdesigns.spend_x

import android.Manifest
import android.content.Context
import android.os.Build
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
        // Cache the engine so SmsReceiver can push live SMS to Dart.
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
                else -> result.notImplemented()
            }
        }
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