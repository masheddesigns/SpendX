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

/// Captures incoming SMS. Queues the message for later processing and, when
/// the Flutter engine is alive, pushes it live to Dart. When the app is
/// killed it shows a notification so the user knows a bank SMS arrived.
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val bodies = messages
            .mapNotNull { it.displayMessageBody ?: it.messageBody }
            .filter { it.isNotBlank() }
        if (bodies.isEmpty()) return

        SmsStore.queue(context, bodies)

        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)
        if (engine != null) {
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                MainActivity.CHANNEL,
            ).invokeMethod("onSmsReceived", bodies)
        } else {
            showNotification(context, bodies)
        }
    }

    private fun showNotification(context: Context, bodies: List<String>) {
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
        val preview = bodies.first().take(120) +
            if (bodies.size > 1) "\n+${bodies.size - 1} more" else ""
        val launchIntent = context.packageManager.getLaunchIntentForPackage(
            context.packageName,
        )
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("New bank SMS detected")
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