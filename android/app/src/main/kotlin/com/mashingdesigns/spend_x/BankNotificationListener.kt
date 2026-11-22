package com.mashingdesigns.spend_x

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.util.Collections
import java.util.LinkedHashSet

/**
 * Persists and resolves user-configured financial ingestion source settings
 * (WhatsApp banking alerts, Gmail/email statement alerts, and extra package allowlists).
 */
object IngestionConfigStore {
    private const val PREFS = "spendx_ingestion_config"
    private const val KEY_WHATSAPP_ENABLED = "whatsapp_enabled"
    private const val KEY_WHATSAPP_SENDERS = "whatsapp_senders"
    private const val KEY_GMAIL_ENABLED = "gmail_enabled"
    private const val KEY_GMAIL_SENDERS = "gmail_senders"
    private const val KEY_EXTRA_PACKAGES = "extra_packages"

    // Default verified financial banking bots / sender keywords in WhatsApp
    val DEFAULT_WHATSAPP_SENDERS = setOf(
        "hdfc", "icici", "sbi", "axis", "kotak", "cred", "onecard", "bob", "pnb",
        "canara", "union bank", "idfc", "federal", "indusind", "yes bank", "rbl",
        "standard chartered", "hsbc", "citi", "jupiter", "fi money", "slice",
        "paytm", "groww", "zerodha", "super.money", "navi", "bajaj"
    )

    // Default verified financial email senders / alert domains
    val DEFAULT_GMAIL_SENDERS = setOf(
        "hdfcbank.net", "icicibank.com", "sbi.co.in", "axisbank.com", "kotak.com",
        "cred.club", "getonecard.app", "citi.com", "standardchartered.co.in",
        "federalbank.co.in", "idfcfirstbank.com", "indusind.com", "yesbank.in",
        "rblbank.com", "alerts", "statements", "e-statement", "transaction alert",
        "bill desk", "sbicard.com"
    )

    fun save(
        context: Context,
        whatsappEnabled: Boolean,
        whatsappSenders: List<String>,
        gmailEnabled: Boolean,
        gmailSenders: List<String>,
        extraPackages: List<String>
    ) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean(KEY_WHATSAPP_ENABLED, whatsappEnabled)
            .putStringSet(KEY_WHATSAPP_SENDERS, (DEFAULT_WHATSAPP_SENDERS + whatsappSenders.map { s: String -> s.trim().lowercase() }).toSet())
            .putBoolean(KEY_GMAIL_ENABLED, gmailEnabled)
            .putStringSet(KEY_GMAIL_SENDERS, (DEFAULT_GMAIL_SENDERS + gmailSenders.map { s: String -> s.trim().lowercase() }).toSet())
            .putStringSet(KEY_EXTRA_PACKAGES, extraPackages.map { s: String -> s.trim() }.toSet())
            .apply()
    }

    fun isWhatsAppEnabled(context: Context): Boolean {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_WHATSAPP_ENABLED, false)
    }

    fun getWhatsAppSenders(context: Context): Set<String> {
        val custom = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_WHATSAPP_SENDERS, null)
        return custom ?: DEFAULT_WHATSAPP_SENDERS
    }

    fun isGmailEnabled(context: Context): Boolean {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_GMAIL_ENABLED, false)
    }

    fun getGmailSenders(context: Context): Set<String> {
        val custom = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_GMAIL_SENDERS, null)
        return custom ?: DEFAULT_GMAIL_SENDERS
    }

    fun getExtraPackages(context: Context): Set<String> {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_EXTRA_PACKAGES, emptySet<String>()) ?: emptySet<String>()
    }
}

/**
 * Listens for system notifications posted by banking, UPI, card, and financial apps.
 * Also supports user-enabled WhatsApp banking alerts and Gmail statement notifications
 * under strict privacy boundaries (only verified financial senders/bots are inspected;
 * personal messages and casual chats are immediately dropped).
 */
class BankNotificationListener : NotificationListenerService() {

    companion object {
        @Volatile
        var instance: BankNotificationListener? = null

        val WHATSAPP_PACKAGES = setOf(
            "com.whatsapp",
            "com.whatsapp.w4b"
        )

        val EMAIL_PACKAGES = setOf(
            "com.google.android.gm",
            "com.microsoft.office.outlook",
            "com.samsung.android.email.provider"
        )

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

        // Explicit allowlist of banking, UPI, card, and financial apps.
        // Email and general messaging clients are intentionally excluded.
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
            "com.samsung.android.spay",              // Samsung Wallet India
            "com.samsung.android.spaymini",          // Samsung Pay Mini
            "com.mipay.in.wallet",                   // Mi Pay India
            "com.payu.lazypay",                      // LazyPay BNPL & UPI
            "com.onefi.simpl",                       // Simpl BNPL
            "club.uni.cards",                        // Uni Card
            "com.scapia.cards",                      // Scapia Federal Credit Card
            "com.myjar.app",                         // Jar Daily Savings
            "com.gullak.money",                      // Gullak
            "com.paytm.money",                       // Paytm Money
            "com.google.android.apps.nbu.paisa.merchant", // Google Pay for Business
            "com.phonepe.app.business",              // PhonePe Business
            "com.paytm.business",                    // Paytm for Business
            "com.khatabook",                         // Khatabook
            "com.airtel.bank",                       // Airtel Payments Bank
            "com.fss.ippb",                          // India Post Payments Bank (IPPB)
            "com.zerodha.kite3",                     // Zerodha Kite
            "com.zerodha.coin",                      // Zerodha Coin
            "com.indmoney",                          // INDmoney
            "in.upstox.app",                         // Upstox
            "com.msf.angelmobile",                   // Angel One
            "com.kuvera.app",                        // Kuvera
            "com.etmoney.android",                   // ET Money
            "in.dhan.app",                           // Dhan
            "com.myairtelapp",                       // Airtel Thanks / Airtel Payments Bank

            // Major Indian Banks & Credit Card Issuers
            "com.sbi.lotusintouch",                  // SBI YONO
            "com.sbi.SBIFreedomPlus",                // SBI FreedomPlus / YONO Lite
            "com.sbi.upi",                           // BHIM SBI Pay
            "com.csam.icici.bank.imobile",           // ICICI iMobile
            "com.icicibank.pockets",                 // ICICI Pockets
            "com.snapwork.hdfc",                     // HDFC MobileBanking
            "com.hdfcbank.payzapp",                  // HDFC PayZapp
            "com.axis.mobile",                       // Axis Mobile
            "com.msf.kbank.mobile",                  // Kotak Mobile & Kotak 811
            "com.kotak.invest",                      // Kotak Cherry
            "com.kotak.finkotak",                    // Kotak Securities / Stock Trading
            "com.kotak.biz",                         // Kotak Biz
            "com.bankofbaroda.mconnect",             // BOB World
            "in.co.bankofbaroda.bobworld",           // BOB World alternate
            "com.idfcfirstbank.optimus",             // IDFC First Bank
            "com.fedmobile",                         // Federal Bank FedMobile
            "com.canarabank.mobility",               // Canara ai1
            "com.pnb.pnbone",                        // PNB One
            "com.unionbank.mbanking",                // Union Bank Vyom
            "com.aubank.aubank",                     // AU Small Finance Bank
            "com.indusind.indusmobile",              // IndusInd Mobile
            "com.yesbank",                           // iris by YES BANK
            "com.yesbank.yesrobot",                  // YES Robot
            "com.idbi.go_mobile",                    // IDBI Bank GO Mobile+
            "com.idbi.mpassbook",                    // IDBI mPassbook
            "com.fss.iob",                           // Indian Overseas Bank Mobile
            "com.infrasoft.iob",                     // Indian Overseas Bank Pay
            "com.psb.mobile",                        // Punjab & Sind Bank PSB UnIC
            "com.bom.mbank",                         // Bank of Maharashtra MahaMobile
            "com.equitasbank.mobilebanking",         // Equitas Small Finance Bank
            "com.ujjivan.mobilebanking",             // Ujjivan Small Finance Bank
            "com.janabank.mobile",                   // Jana Small Finance Bank
            "com.suryoday.mobile",                   // Suryoday Small Finance Bank
            "com.esaf.mbank",                        // ESAF Small Finance Bank
            "com.utkarsh.mobile",                    // Utkarsh Small Finance Bank
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
        Log.i("SpendX_Notif", "BankNotificationListener connected")
        seedActiveNotifications()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (instance == this) {
            instance = null
        }
        Log.i("SpendX_Notif", "BankNotificationListener disconnected")
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

    /**
     * Seeds pre-existing notifications present in the status bar tray upon listener
     * connect into [PROCESSED_KEYS] without dispatching them to Flutter or triggering
     * the Dynamic Island HUD. Only newly posted incoming notifications will trigger alerts.
     */
    fun seedActiveNotifications() {
        try {
            val active = activeNotifications ?: return
            Log.i("SpendX_Notif", "seedActiveNotifications: seeding ${active.size} active notifications into processed set")
            val extraPkgs = IngestionConfigStore.getExtraPackages(this)
            val waEnabled = IngestionConfigStore.isWhatsAppEnabled(this)
            val gmEnabled = IngestionConfigStore.isGmailEnabled(this)

            for (sbn in active) {
                val pkg = sbn.packageName ?: continue
                if (pkg == packageName) continue
                val isPayment = PAYMENT_PACKAGES.contains(pkg) || extraPkgs.contains(pkg)
                val isWA = waEnabled && WHATSAPP_PACKAGES.contains(pkg)
                val isGM = gmEnabled && EMAIL_PACKAGES.contains(pkg)
                if (!isPayment && !isWA && !isGM) continue

                val sbnKey = sbn.key ?: "${pkg}_${sbn.id}_${sbn.postTime}"
                val tag = sbn.tag ?: ""
                val sourceRecordId = "SRC:ANDROID_NOTIF:$pkg:${sbn.id}:$tag:${sbn.postTime}"
                val extras = sbn.notification?.extras
                val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
                val text = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
                val fullBody = if (title.isNotBlank() && text.isNotBlank()) "$title: $text" else (text.ifBlank { title })
                val dedupKey = "$sbnKey|${fullBody.hashCode()}"
                PROCESSED_KEYS.add(sourceRecordId)
                PROCESSED_KEYS.add(dedupKey)
            }
        } catch (e: Exception) {
            Log.e("SpendX_Notif", "seedActiveNotifications error: $e")
        }
    }

    fun syncActiveNotifications() {
        seedActiveNotifications()
    }

    private fun processNotification(sbn: StatusBarNotification?) {
        if (sbn == null) return

        val pkg = sbn.packageName ?: return

        // Ignore SpendX's own notifications.
        if (pkg == packageName) return

        val isPaymentApp = PAYMENT_PACKAGES.contains(pkg) || IngestionConfigStore.getExtraPackages(this).contains(pkg)
        val isWhatsApp = WHATSAPP_PACKAGES.contains(pkg)
        val isEmail = EMAIL_PACKAGES.contains(pkg)

        if (!isPaymentApp && !isWhatsApp && !isEmail) {
            return
        }

        val extras = sbn.notification?.extras ?: return

        // ── 1. WhatsApp Ingestion Adapter (Privacy-Gated) ──
        if (isWhatsApp) {
            if (!IngestionConfigStore.isWhatsAppEnabled(this)) {
                return // User has not explicitly enabled WhatsApp financial ingestion
            }
            val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim() ?: ""
            val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()?.trim() ?: ""
            val lowerTitle = title.lowercase()
            val lowerSubText = subText.lowercase()
            val allowedSenders = IngestionConfigStore.getWhatsAppSenders(this)

            val matchesFinancial = allowedSenders.any { sender ->
                lowerTitle.contains(sender) || lowerSubText.contains(sender)
            }

            if (!matchesFinancial) {
                // Strict privacy boundary: Personal chat / unlisted contact -> drop immediately without reading body or logging!
                return
            }
        }

        // ── 2. Email Ingestion Adapter (Privacy-Gated) ──
        if (isEmail) {
            if (!IngestionConfigStore.isGmailEnabled(this)) {
                return // User has not explicitly enabled Email preview ingestion
            }
            val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim() ?: ""
            val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()?.trim() ?: ""
            val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim() ?: ""
            val lowerTitle = title.lowercase()
            val lowerSubText = subText.lowercase()
            val lowerText = text.lowercase()
            val allowedSenders = IngestionConfigStore.getGmailSenders(this)

            val matchesSender = allowedSenders.any { sender ->
                lowerTitle.contains(sender) || lowerSubText.contains(sender) || lowerText.contains(sender)
            }
            val matchesSubject = lowerTitle.contains("statement") || lowerTitle.contains("transaction") ||
                lowerTitle.contains("debited") || lowerTitle.contains("credited") || lowerTitle.contains("bill due") ||
                lowerTitle.contains("alert") || lowerTitle.contains("invoice")

            if (!matchesSender && !matchesSubject) {
                // Strict privacy boundary: Personal email / unlisted sender -> drop immediately!
                return
            }
        }

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
            Log.i("SpendX_Notif", "Dropped promotional/offer notification: pkg=$pkg, tag=$tag, channel=$channelId")
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
        val sbnTag = sbn.tag ?: ""
        val sourceRecordId = "SRC:ANDROID_NOTIF:$pkg:${sbn.id}:$sbnTag:${sbn.postTime}"
        val dedupKey = "$sbnKey|${fullBody.hashCode()}"
        if (PROCESSED_KEYS.contains(sourceRecordId) || PROCESSED_KEYS.contains(dedupKey)) {
            Log.i("SpendX_Notif", "Skipping already processed active notification: $sourceRecordId")
            return
        }
        PROCESSED_KEYS.add(sourceRecordId)
        PROCESSED_KEYS.add(dedupKey)

        // Clean sender / title display. The APP: prefix keeps the existing
        // FinancialSmsFilter sender semantics for explicit allowlisted packages.
        val displaySender = if (title.isNotBlank() && title != fullBody) title else pkg
        val senderTitle = "APP:$pkg:$displaySender"

        // Strictly evaluate every incoming notification against FinancialSmsFilter.
        // Even notifications from known payment packages (e.g. Google Pay, PhonePe) frequently
        // include ads, cashbacks, scratch cards, or loan offers that must NEVER become expense transactions.
        val isFinancial = FinancialSmsFilter.isFinancial(senderTitle, fullBody)
        Log.i("SpendX_Notif", "Evaluated notification: pkg=$pkg, isFinancial=$isFinancial")
        if (!isFinancial) return

        // 1. Trigger the Dynamic Island capsule IMMEDIATELY in native Kotlin!
        val parsed = FinancialSmsFilter.extractAmountAndDirection(fullBody)
        val amount = parsed?.first ?: ""
        val isExpense = parsed?.second ?: true
        Log.i("SpendX_Notif", "Financial notification accepted: pkg=$pkg, amountPresent=${amount.isNotBlank()}, isExpense=$isExpense")

        // 2. Deliver to Flutter live on UI thread or queue durably before showing notification
        val postTime = sbn.postTime
        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)
        if (engine != null) {
            // When Flutter engine is running, do NOT show the island from native!
            // Flutter parses, deduplicates, and ingests the notification; LiveSmsService
            // will trigger the dynamic island only if the transaction is successfully recorded.
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                MethodChannel(
                    engine.dartExecutor.binaryMessenger,
                    MainActivity.CHANNEL,
                ).invokeMethod("onSmsReceived", listOf(senderTitle, fullBody, pkg, sourceRecordId, postTime.toString()))
            }
        } else {
            val queued = SmsStore.queue(this, senderTitle, fullBody, sourceRecordId, postTime)
            if (!queued) {
                Log.e("SpendX_Notif", "CRITICAL: Failed to durably queue notification [$sourceRecordId]. Suppressing overlay.")
                return
            }
            // Overlay suppressed per user request
        }
    }
}
