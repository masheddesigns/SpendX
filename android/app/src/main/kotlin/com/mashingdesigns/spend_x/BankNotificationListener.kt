package com.mashingdesigns.spend_x

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Listens for system notifications posted by banking and UPI payment apps
 * (e.g. Google Pay, PhonePe, Paytm, iMobile, PayZapp, YONO, Jupiter, CRED, etc.)
 * when banks send alerts via push notifications rather than SMS.
 *
 * Captures the notification text and pipes it through the exact same
 * FinancialSmsFilter and LiveSmsService accounting pipeline.
 */
class BankNotificationListener : NotificationListenerService() {

    companion object {
        // Known banking and UPI app packages in India
        private val PAYMENT_PACKAGES = setOf(
            "com.google.android.apps.nbu.paisa.user", // Google Pay
            "com.phonepe.app",                       // PhonePe
            "net.one97.paytm",                       // Paytm
            "in.amazon.mShop.android.shopping",      // Amazon Pay
            "com.csam.icici.bank.imobile",           // ICICI iMobile
            "com.icicibank.pockets",                 // ICICI Pockets
            "com.snapwork.hdfc",                     // HDFC MobileBanking
            "com.hdfcbank.payzapp",                  // HDFC PayZapp
            "com.axis.mobile",                       // Axis Mobile
            "com.sbi.lotusintouch",                  // SBI YONO
            "com.msf.kbank.mobile",                  // Kotak Mobile
            "com.bankofbaroda.mconnect",             // BOB World
            "money.jupiter",                         // Jupiter
            "com.epifi.slice",                       // Slice / Fi
            "co.onecard",                            // OneCard
            "com.cred.club",                         // CRED
            "com.freecharge.android",                // Freecharge
            "com.mobikwik_new",                      // MobiKwik
            "com.idfcfirstbank.optimus",             // IDFC First Bank
            "com.fedmobile",                         // Federal Bank FedMobile
            "com.canarabank.mobility",               // Canara Bank
            "com.pnb.pnbone",                        // PNB One
            "com.aubank.aubank",                     // AU Small Finance Bank
            "com.indusind.indusmobile"               // IndusInd
        )
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return

        val pkg = sbn.packageName ?: return
        val extras = sbn.notification?.extras ?: return

        // Ignore SpendX's own notifications
        if (pkg == packageName) return

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString() ?: ""

        val messageText = when {
            bigText.isNotBlank() && bigText.length > text.length -> bigText
            text.isNotBlank() -> text
            else -> ""
        }

        val fullBody = when {
            title.isNotBlank() && messageText.isNotBlank() && !messageText.contains(title, ignoreCase = true) ->
                "$title: $messageText"
            messageText.isNotBlank() -> messageText
            else -> title
        }

        if (fullBody.isBlank()) return

        val isFromPaymentPackage = PAYMENT_PACKAGES.contains(pkg)

        // Clean sender / title display
        val senderTitle = if (title.isNotBlank() && title != fullBody) title else pkg

        // If from a known payment package OR passes the FinancialSmsFilter
        val isFinancial = isFromPaymentPackage || FinancialSmsFilter.isFinancial(senderTitle, fullBody)
        if (!isFinancial) return

        // Deliver to Flutter live on UI thread or queue for later
        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)
        if (engine != null) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                MethodChannel(
                    engine.dartExecutor.binaryMessenger,
                    MainActivity.CHANNEL,
                ).invokeMethod("onSmsReceived", listOf(senderTitle, fullBody))
            }
        } else {
            SmsStore.queue(this, senderTitle, fullBody)
        }
    }
}
