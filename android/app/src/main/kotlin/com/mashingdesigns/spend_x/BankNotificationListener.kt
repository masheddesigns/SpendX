package com.mashingdesigns.spend_x

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.util.Collections
import java.util.LinkedHashSet

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
        @Volatile
        var instance: BankNotificationListener? = null

        private val PROCESSED_KEYS: MutableSet<String> = Collections.synchronizedSet(object : LinkedHashSet<String>() {
            override fun add(element: String): Boolean {
                if (size >= 300) {
                    val it = iterator()
                    if (it.hasNext()) {
                        it.next()
                        it.remove()
                    }
                }
                return super.add(element)
            }
        })

        // Known banking, UPI, and financial payment app packages in India
        private val PAYMENT_PACKAGES = setOf(
            // Top UPI & Payment Apps
            "com.google.android.apps.nbu.paisa.user", // Google Pay
            "com.phonepe.app",                       // PhonePe
            "net.one97.paytm",                       // Paytm
            "in.amazon.mShop.android.shopping",      // Amazon Pay
            "in.org.npci.upiapp",                    // BHIM NPCI
            "com.dreamplug.androidapp",              // CRED (Official)
            "com.cred.club",                         // CRED (Legacy / Web)
            "com.creditcard.onecard",                // OneCard (Official)
            "co.onecard",                            // OneCard (Legacy)
            "money.jupiter",                         // Jupiter
            "indwin.c3.shareTrade",                  // Slice
            "com.epifi.slice",                       // Slice legacy
            "money.fi",                              // Fi Money
            "com.supermoney.app",                    // super.money
            "com.navi.naviPay",                      // Navi UPI & Loans
            "in.jfs.jiofinance",                     // JioFinance
            "com.nextbillion.groww",                 // Groww
            "com.groww.stocks",                      // Groww alternate
            "com.tatadigital.tcp",                   // Tata Neu / Tata Pay
            "com.jio.myjio",                         // MyJio / JioPaymentsBank
            "com.google.android.apps.walletnfcrel",  // Google Wallet
            "com.paypal.android.p2pmobile",          // PayPal
            "com.policybazaar",                      // PolicyBazaar
            "com.freecharge.android",                // Freecharge
            "com.mobikwik_new",                      // MobiKwik
            "com.popclub.app",                       // POPclub UPI
            "com.kiwi.credit",                       // Kiwi UPI
            "com.cheq.cheqone",                      // CheQ
            "com.fampay.in",                         // FamApp / FamPay
            "com.postpe.app",                        // PostPe
            "com.bharatpe",                          // BharatPe
            "com.sbicard.app",                       // SBI Card (Official)
            "com.bobcard.app",                       // Bobcard / BOB Credit Card
            "com.rblbank.cards",                     // RBL MyCard
            "com.kotak.cards",                       // Kotak Cards
            "com.slicepay",                          // Slice UPI & Credit
            "in.onecard.app",                        // OneCard alternate
            "com.canarabank.canaracard",             // Canara Credit Card
            "com.enStage.wibmo.hdfc",                // HDFC SmartHub / PayZapp
            "com.axisbank.axispay",                  // Axis Pay UPI
            "com.paytmbank.mobile",                  // Paytm Payments Bank
            "com.bajajfinserv.direct",               // Bajaj Finserv
            "com.vivo.unionpay",                     // Vivo Pay / UnionPay
            "com.zerodha.kite3",                     // Zerodha Kite
            "com.zerodha.coin",                      // Zerodha Coin
            "com.indmoney",                          // INDmoney
            "in.upstox.app",                         // Upstox
            "com.msf.angelmobile",                   // Angel One
            "com.kuvera.app",                        // Kuvera
            "com.etmoney.android",                   // ET Money
            "in.dhan.app",                           // Dhan
            "com.myairtelapp",                       // Airtel Thanks / Airtel Payments Bank

            // Major Indian Banks
            "com.sbi.lotusintouch",                  // SBI YONO
            "com.sbi.SBIFreedomPlus",                // SBI FreedomPlus / YONO Lite
            "com.sbi.upi",                           // BHIM SBI Pay
            "com.csam.icici.bank.imobile",           // ICICI iMobile
            "com.icicibank.pockets",                 // ICICI Pockets
            "com.snapwork.hdfc",                     // HDFC MobileBanking
            "com.hdfcbank.payzapp",                  // HDFC PayZapp
            "com.axis.mobile",                       // Axis Mobile
            "com.msf.kbank.mobile",                  // Kotak Mobile
            "com.kotak.invest",                      // Kotak Cherry
            "com.bankofbaroda.mconnect",             // BOB World
            "in.co.bankofbaroda.bobworld",           // BOB World alternate
            "com.idfcfirstbank.optimus",             // IDFC First Bank
            "com.fedmobile",                         // Federal Bank FedMobile
            "com.canarabank.mobility",               // Canara ai1
            "com.pnb.pnbone",                        // PNB One
            "com.unionbank.mbanking",                // Union Bank Vyom
            "com.aubank.aubank",                     // AU Small Finance Bank
            "com.indusind.indusmobile",              // IndusInd Mobile
            "com.rblbank.mobank",                    // RBL MoBank
            "com.bandhan.mBandhan",                  // Bandhan Bank
            "com.sc.breeze.in",                      // Standard Chartered India
            "com.hsbc.in.hsbcpersonalbanking",       // HSBC India
            "com.dbs.in.dbsmbanking",                // DBS digibank
            "com.citibank.mobile.in",                // Citi Mobile India
            "com.boi.mpay",                          // BOI Mobile Omni
            "com.mgs.centralbank",                   // Central Bank Cent Mobile
            "com.infrasofttech.IndianBank",          // Indian Bank IndOASIS
            "com.lcode.uco",                         // UCO mBanking Plus
            "com.cub.cucebanking",                   // City Union Bank
            "com.tmb.tmbdigilobby",                  // TMB MBank
            "com.sib.mirrorplus",                    // South Indian Bank Mirror+
            "com.lcode.smartbank",                   // Karnataka Bank KBL Mobile Plus
            "com.kvb.mobilebanking"                  // Karur Vysya Bank DLite
        )
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.d("SpendX_Notif", "BankNotificationListener connected")
        syncActiveNotifications()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (instance == this) {
            instance = null
        }
        Log.d("SpendX_Notif", "BankNotificationListener disconnected")
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) {
            instance = null
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        processNotification(sbn)
    }

    fun syncActiveNotifications() {
        try {
            val active = activeNotifications ?: return
            Log.d("SpendX_Notif", "syncActiveNotifications: processing ${active.size} active notifications")
            for (sbn in active) {
                processNotification(sbn)
            }
        } catch (e: Exception) {
            Log.e("SpendX_Notif", "syncActiveNotifications error: $e")
        }
    }

    private fun processNotification(sbn: StatusBarNotification?) {
        if (sbn == null) return

        val pkg = sbn.packageName ?: return
        val extras = sbn.notification?.extras ?: return

        // Ignore SpendX's own notifications
        if (pkg == packageName) return

        val channelId = (sbn.notification?.channelId ?: "").lowercase()
        val tag = (sbn.tag ?: "").lowercase()
        val category = (sbn.notification?.category ?: "").lowercase()

        // Strictly drop promotional, marketing, offer, reward, and advertisement notifications
        if (channelId.contains("offer") || channelId.contains("reward") || channelId.contains("promo") ||
            channelId.contains("marketing") || channelId.contains("deal") || channelId.contains("campaign") ||
            channelId.contains("recommend") || channelId.contains("advertis") ||
            tag.contains("offer") || tag.contains("reward") || tag.contains("promo") ||
            tag.contains("marketing") || tag.contains("deal") || tag.contains("campaign") ||
            category == Notification.CATEGORY_PROMO || category == Notification.CATEGORY_RECOMMENDATION) {
            Log.d("SpendX_Notif", "Dropped promotional/offer notification: pkg=$pkg, tag=$tag, channel=$channelId")
            return
        }

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString() ?: ""
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() ?: ""

        val messageText = when {
            bigText.isNotBlank() && bigText.length > text.length -> bigText
            text.isNotBlank() -> text
            subText.isNotBlank() -> subText
            else -> ""
        }

        val fullBody = when {
            title.isNotBlank() && messageText.isNotBlank() && !messageText.contains(title, ignoreCase = true) ->
                "$title: $messageText"
            messageText.isNotBlank() -> messageText
            else -> title
        }

        if (fullBody.isBlank()) return

        val sbnKey = sbn.key ?: "${pkg}_${sbn.id}_${sbn.postTime}"
        val dedupKey = "$sbnKey|${fullBody.hashCode()}"
        if (PROCESSED_KEYS.contains(dedupKey)) {
            Log.d("SpendX_Notif", "Skipping already processed active notification: $dedupKey")
            return
        }
        PROCESSED_KEYS.add(dedupKey)

        val isFromPaymentPackage = PAYMENT_PACKAGES.contains(pkg)

        // Clean sender / title display
        val displaySender = if (title.isNotBlank() && title != fullBody) title else pkg
        val senderTitle = if (isFromPaymentPackage) "APP:$pkg:$displaySender" else displaySender

        // Strictly evaluate every incoming notification against FinancialSmsFilter.
        // Even notifications from known payment packages (e.g. Google Pay, PhonePe) frequently
        // include ads, cashbacks, scratch cards, or loan offers that must NEVER become expense transactions.
        val isFinancial = FinancialSmsFilter.isFinancial(senderTitle, fullBody)
        Log.d("SpendX_Notif", "onNotificationPosted: pkg=$pkg, sender=$senderTitle, isFinancial=$isFinancial, body=$fullBody")
        if (!isFinancial) return

        // Deliver to Flutter live on UI thread or queue for later
        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)
        if (engine != null) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                MethodChannel(
                    engine.dartExecutor.binaryMessenger,
                    MainActivity.CHANNEL,
                ).invokeMethod("onSmsReceived", listOf(senderTitle, fullBody, pkg))
            }
        } else {
            SmsStore.queue(this, senderTitle, fullBody)
        }
    }
}
