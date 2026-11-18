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

/**
 * Captures incoming SMS via SMS_RECEIVED_ACTION.
 *
 * Multipart SMS Completeness Policy:
 * -----------------------------------
 * SpendX relies on the Android OS Telephony framework (`InboundSmsHandler`) to stage, validate
 * User Data Headers (UDH), and reassemble multipart 3GPP/3GPP2 SMS PDUs before dispatching
 * the `SMS_RECEIVED_ACTION` broadcast.
 *
 * The public Android SDK `SmsMessage` API intentionally hides internal UDH headers (`@hide SmsHeader`)
 * and does not expose segment sequence numbers, total part counts, or an `isComplete()` method.
 * Consequently, SpendX cannot independently reconstruct sequence ordering or determine whether
 * a delivered segment array is a partial fragment of a larger message if that fragment independently
 * matches financial token filters.
 *
 * Framework reliance:
 * 1. SpendX assumes the array of `SmsMessage` objects passed in the Intent extras is complete and
 *    already ordered by sequence number by `InboundSmsHandler`.
 * 2. SpendX enforces defense-in-depth receiver boundary validation:
 *    - Rejects broadcasts with conflicting originating addresses across segments.
 *    - Rejects broadcasts where segment timestamps diverge by more than 60,000 ms.
 *    - Discards empty or whitespace segments.
 *    - Evaluates the concatenated text against `FinancialSmsFilter`.
 *    - Generates a deterministic SHA-256 sourceRecordId to guarantee idempotent processing.
 */
class SmsReceiver : BroadcastReceiver() {

    data class RawSmsSegment(
        val originatingAddress: String?,
        val body: String?,
        val timestampMillis: Long,
    )

    data class ReassembledBroadcastSms(
        val sender: String,
        val fullBody: String,
        val timestampMillis: Long,
        val subId: Int,
        val sourceRecordId: String,
    )

    companion object {
        /**
          Pure reassembly and validation logic for raw SMS segments delivered in SMS_RECEIVED_ACTION.
          Validates sender consistency, timestamp alignment, multipart concatenation, financial filtering,
          and deterministic identity generation.
         
          Returns null if:
          - Segments list is empty or contains no readable bodies.
          - Segments have conflicting originating addresses (sender mismatch).
          - Segment timestamps diverge by more than 60,000ms.
          - Reassembled body is non-financial (OTP, promo, telecom, etc.).
         */
        fun validateAndReassemble(
            segments: List<RawSmsSegment>,
            subId: Int,
        ): ReassembledBroadcastSms? {
            if (segments.isEmpty()) return null

            // 1. Validate sender consistency across all segments
            val senders = segments.mapNotNull { it.originatingAddress?.trim() }.filter { it.isNotEmpty() }
            if (senders.isEmpty()) return null
            val primarySender = senders.first()
            if (senders.any { !it.equals(primarySender, ignoreCase = true) }) {
                // Inconsistent senders across segments: reject malformed broadcast
                return null
            }

            // 2. Validate timestamp consistency (all segments within 60s window)
            val timestamps = segments.map { it.timestampMillis }
            val minTs = timestamps.minOrNull() ?: 0L
            val maxTs = timestamps.maxOrNull() ?: 0L
            if (maxTs - minTs > 60_000L) {
                // Inconsistent timestamps across segments: reject malformed broadcast
                return null
            }

            // 3. Reassemble bodies in order (preserves array order from framework)
            val validBodies = segments
                .mapNotNull { it.body }
                .filter { it.isNotBlank() }
            if (validBodies.isEmpty()) return null

            val fullBody = validBodies.joinToString("")

            // 4. Financial classification gate
            if (!FinancialSmsFilter.isFinancial(primarySender, fullBody)) {
                return null
            }

            // 5. Deterministic identity generation
            val sourceRecordId = TelephonyIdentityGenerator.generateSourceId(
                subId = subId,
                timestampMillis = timestamps.first(),
                sender = primarySender,
                body = fullBody,
            )

            return ReassembledBroadcastSms(
                sender = primarySender,
                fullBody = fullBody,
                timestampMillis = timestamps.first(),
                subId = subId,
                sourceRecordId = sourceRecordId,
            )
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val segments = messages.map {
            RawSmsSegment(
                originatingAddress = it.displayOriginatingAddress ?: it.originatingAddress,
                body = it.displayMessageBody ?: it.messageBody,
                timestampMillis = it.timestampMillis,
            )
        }

        val subId = intent.getIntExtra(
            "android.telephony.extra.SUBSCRIPTION_INDEX",
            intent.getIntExtra("subscription", intent.getIntExtra("subscription_id", -1))
        )

        val reassembled = validateAndReassemble(segments, subId) ?: return

        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)
        if (engine != null) {
            // Pass [sender, body, subId, sourceRecordId] so Dart can process live on UI thread.
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                MethodChannel(
                    engine.dartExecutor.binaryMessenger,
                    MainActivity.CHANNEL,
                ).invokeMethod(
                    "onSmsReceived",
                    listOf(reassembled.sender, reassembled.fullBody, reassembled.subId.toString(), reassembled.sourceRecordId)
                )
            }
        } else {
            // App is killed / engine not cached: queue durably before showing overlay
            val queued = SmsStore.queue(context, reassembled.sender, reassembled.fullBody, reassembled.sourceRecordId)
            if (!queued) {
                android.util.Log.e("SmsReceiver", "CRITICAL: Failed to durably queue incoming SMS [${reassembled.sourceRecordId}]. Suppressing notification.")
                return
            }

            val parsed = FinancialSmsFilter.extractAmountAndDirection(reassembled.fullBody)
            if (parsed != null) {
                DynamicIslandOverlayService.show(context, "SpendX", parsed.first, parsed.second, reassembled.sender)
            } else {
                DynamicIslandOverlayService.show(context, "SpendX", reassembled.fullBody.take(24), true, reassembled.sender)
            }
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

object TelephonyIdentityGenerator {
    fun generateSourceId(
        subId: Int,
        timestampMillis: Long,
        sender: String,
        body: String,
    ): String {
        val cleanSender = sender.trim().uppercase()
        val cleanBody = body.trim()
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        digest.update(cleanSender.toByteArray(Charsets.UTF_8))
        digest.update(0.toByte())
        digest.update(cleanBody.toByteArray(Charsets.UTF_8))
        val hash = digest.digest().take(8).joinToString("") { "%02x".format(it) }
        val subToken = if (subId >= 0) subId.toString() else "UNKNOWN"
        return "SRC:TELEPHONY_BROADCAST:$subToken:$timestampMillis:$hash"
    }
}
