package com.mashingdesigns.spend_x

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Telephony
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/// Captures incoming SMS. Filters and queues genuine financial messages for
/// later processing and, when the Flutter engine is alive, pushes them live to Dart.
/// Non-financial SMS (OTPs, personal chats, marketing, service alerts) are dropped.
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val bodies = messages
            .mapNotNull { it.displayMessageBody ?: it.messageBody }
            .filter { it.isNotBlank() }
        if (bodies.isEmpty()) return

        // Extract sender from the first message segment.
        val sender = messages.first().displayOriginatingAddress
            ?: messages.first().originatingAddress
            ?: ""

        val fullBody = bodies.joinToString("\n")

        // Strictly drop non-financial SMS (OTPs, promo, personal chats, etc.)
        if (!FinancialSmsFilter.isFinancial(sender, fullBody)) {
            return
        }

        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)
        if (engine != null) {
            // Pass [sender, body] so Dart can process live.
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                MainActivity.CHANNEL,
            ).invokeMethod("onSmsReceived", listOf(sender, fullBody))
        } else {
            // App is killed / engine not cached: queue and notify user
            SmsStore.queue(context, sender, fullBody)
            showNotification(context, fullBody)
        }
    }

    private fun showNotification(context: Context, body: String) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "spendx_sms_live"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    "Live SMS Detection",
                    NotificationManager.IMPORTANCE_HIGH,
                ),
            )
        }
        val preview = body.take(120)
        val launchIntent = context.packageManager.getLaunchIntentForPackage(
            context.packageName,
        )
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Bank transaction detected")
            .setContentText(preview)
            .setStyle(NotificationCompat.BigTextStyle().bigText(preview))
            .setAutoCancel(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    context,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .build()
        manager.notify((System.currentTimeMillis() % 100000).toInt(), notification)
    }
}