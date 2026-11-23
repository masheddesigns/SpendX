package com.mashingdesigns.spend_x

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Telephony
import android.service.notification.NotificationListenerService
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
        @Volatile var isAppInForeground: Boolean = false

        /**
         * Pure decision logic for whether a synthetic test SMS intent should be processed.
         * Enforces strict compile-time / build-type isolation: rejected unless [isDebug] is true.
         */
        fun shouldAcceptSyntheticSms(action: String?, isDebug: Boolean = BuildConfig.DEBUG): Boolean {
            return action == "com.mashingdesigns.spend_x.TEST_SMS" && isDebug
        }
    }

    private var pendingIslandCardEvent: Map<String, Any?>? = null
    private var pendingSmsEvent: List<String>? = null
    private var pendingDeepLink: String? = null

    override fun onResume() {
        super.onResume()
        isAppInForeground = true
        rebindNotificationListener()
        BankNotificationListener.instance?.syncActiveNotifications()
    }

    override fun onPause() {
        super.onPause()
        isAppInForeground = false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureSecureStorageAlgorithmMarkers()
        handleIslandIntents(intent)
        rebindNotificationListener()
    }

    private fun rebindNotificationListener() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val component = ComponentName(this, BankNotificationListener::class.java)
                NotificationListenerService.requestRebind(component)
                android.util.Log.i("MainActivity", "Requested rebind for BankNotificationListener")
            } catch (e: Exception) {
                android.util.Log.w("MainActivity", "requestRebind failed: $e")
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIslandIntents(intent)
        handleAppLinkIntent(intent)
    }

    private fun handleAppLinkIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        if (intent.action != Intent.ACTION_VIEW || uri.scheme != "spendx") return

        val engine = flutterEngine ?: FlutterEngineCache.getInstance().get(ENGINE_ID)
        if (engine == null) {
            pendingDeepLink = uri.toString()
            return
        }
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod("onDeepLinkReceived", uri.toString())
        }, 300)
    }

    private fun handleIslandIntents(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        android.util.Log.i("MainActivity", "handleIslandIntents: action=$action, extras=${intent.extras}")

        if (action == "com.mashingdesigns.spend_x.TEST_SMS") {
            if (!shouldAcceptSyntheticSms(action, BuildConfig.DEBUG)) {
                android.util.Log.w("MainActivity", "Rejecting TEST_SMS intent: synthetic injection prohibited in release builds.")
                return
            }
            val sender = intent.getStringExtra("sender") ?: "VM-HDFCBK"
            val body = intent.getStringExtra("body") ?: ""
            val subId = intent.getIntExtra("subId", 0)
            val timestamp = intent.getLongExtra("timestamp", System.currentTimeMillis())
            val sourceRecordId = intent.getStringExtra("sourceRecordId")
                ?: TelephonyIdentityGenerator.generateSourceId(subId, timestamp, sender, body)

            android.util.Log.i("MainActivity", "TEST_SMS received: sender=$sender, body=$body, sourceRecordId=$sourceRecordId")

            val ts = System.currentTimeMillis()
            val payload = listOf(sender, body, subId.toString(), sourceRecordId, ts.toString())
            val engine = flutterEngine ?: FlutterEngineCache.getInstance().get(ENGINE_ID)
            if (engine != null && body.isNotBlank()) {
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onSmsReceived", payload)
                }, 300)
            } else if (body.isNotBlank()) {
                val queued = SmsStore.queue(this, sender, body, sourceRecordId, ts)
                if (queued) {
                    pendingSmsEvent = payload
                } else {
                    android.util.Log.e("MainActivity", "CRITICAL: Failed to durably queue synthetic SMS: $sourceRecordId")
                }
            }
            return
        }

        if (action == "com.mashingdesigns.spend_x.ACTION_SHOW_TRANSACTION_ISLAND" ||
            action == "com.mashingdesigns.spend_x.TEST_ISLAND" ||
            intent.hasExtra("displayAmount") || intent.hasExtra("islandAmount") || intent.hasExtra("amount")) {

            val amount = intent.getStringExtra("amount")
                ?: intent.getStringExtra("islandAmount")
                ?: intent.getStringExtra("displayAmount")
                ?: ""
            val isExpense = intent.getBooleanExtra("isExpense", true)
            val subtitle = intent.getStringExtra("subtitle") ?: intent.getStringExtra("sender") ?: "SpendX"
            val title = intent.getStringExtra("title") ?: if (isExpense) "Expense Recorded" else "Income Recorded"

            android.util.Log.i("MainActivity", "Dispatching island card click to Flutter: amount=$amount, isExpense=$isExpense")

            if (action == "com.mashingdesigns.spend_x.TEST_ISLAND") {
                if (BuildConfig.DEBUG) {
                    DynamicIslandOverlayService.show(this, "SpendX", if (amount.isNotBlank()) amount else "50.00", isExpense, subtitle)
                } else {
                    android.util.Log.w("MainActivity", "Rejecting TEST_ISLAND intent in release builds.")
                    return
                }
            }

            val payload = mapOf(
                "amount" to amount,
                "isExpense" to isExpense,
                "subtitle" to subtitle,
                "title" to title
            )

            val engine = flutterEngine ?: FlutterEngineCache.getInstance().get(ENGINE_ID)
            if (engine != null) {
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onIslandCardClicked", payload)
                }, 300)
            } else {
                pendingIslandCardEvent = payload
            }
        }
    }

    private fun ensureSecureStorageAlgorithmMarkers() {
        try {
            val configPrefs = getSharedPreferences("FlutterSecureStorageConfiguration", Context.MODE_PRIVATE)
            if (!configPrefs.contains("FlutterSecureSAlgorithmKey")) {
                configPrefs.edit()
                    .putString("FlutterSecureSAlgorithmKey", "RSA_ECB_OAEPwithSHA_256andMGF1Padding")
                    .putString("FlutterSecureSAlgorithmStorage", "AES_GCM_NoPadding")
                    .commit()
            }
        } catch (_: Exception) {
            // Defensive ignore
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)

        pendingIslandCardEvent?.let { payload ->
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onIslandCardClicked", payload)
            }, 600)
            pendingIslandCardEvent = null
        }

        pendingSmsEvent?.let { payload ->
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onSmsReceived", payload)
            }, 600)
            pendingSmsEvent = null
        }

        pendingDeepLink?.let { link ->
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                    .invokeMethod("onDeepLinkReceived", link)
            }, 600)
            pendingDeepLink = null
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
                call,
                result,
            ->
            when (call.method) {
                "getPendingSms" -> result.success(SmsStore.all(this))
                "removePendingSms" -> {
                    val ids = (call.argument<List<Any?>>("sourceRecordIds") ?: emptyList())
                        .mapNotNull { it?.toString() }
                        .toSet()
                    val success = SmsStore.remove(this, ids)
                    result.success(success)
                }
                "clearPendingSms" -> {
                    val success = SmsStore.clear(this)
                    result.success(success)
                }
                "requestReceiveSmsPermission" -> {
                    requestReceiveSmsPermission()
                    result.success(null)
                }
                "isNotificationListenerEnabled" -> {
                    val enabled = androidx.core.app.NotificationManagerCompat
                        .getEnabledListenerPackages(this)
                        .contains(packageName)
                    result.success(enabled)
                }
                "openNotificationListenerSettings" -> {
                    try {
                        val intent = android.content.Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "queryInboxPage" -> {
                    val sinceEpochMs = (call.argument<Number>("sinceEpochMs"))?.toLong()
                    val limit = ((call.argument<Number>("limit"))?.toInt() ?: 300).coerceIn(1, 500)
                    val beforeDate = (call.argument<Number>("beforeDate"))?.toLong()
                    val beforeId = (call.argument<Number>("beforeId"))?.toLong()
                    result.success(queryInboxPage(sinceEpochMs, limit, beforeDate, beforeId))
                }
                "queryRecoveryInboxPage" -> {
                    val startMaxId = (call.argument<Number>("startMaxId"))?.toLong()
                    if (startMaxId == null) {
                        result.error("INVALID_ARGUMENT", "startMaxId is required", null)
                        return@setMethodCallHandler
                    }
                    val limit = ((call.argument<Number>("limit"))?.toInt() ?: 300).coerceIn(1, 500)
                    val beforeId = (call.argument<Number>("beforeId"))?.toLong()
                    val sevenDayThresholdMs = (call.argument<Number>("sevenDayThresholdMs"))?.toLong()
                    if (sevenDayThresholdMs == null) {
                        result.error("INVALID_ARGUMENT", "sevenDayThresholdMs is required", null)
                        return@setMethodCallHandler
                    }
                    result.success(queryRecoveryInboxPage(startMaxId, limit, beforeId, sevenDayThresholdMs))
                }
                "getMaxInboxId" -> {
                    result.success(getMaxInboxId())
                }
                "syncActiveNotifications" -> {
                    val listener = BankNotificationListener.instance
                    if (listener != null) {
                        listener.syncActiveNotifications()
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        try {
                            NotificationListenerService.requestRebind(
                                ComponentName(this, BankNotificationListener::class.java)
                            )
                        } catch (e: Exception) {
                            android.util.Log.w("MainActivity", "Failed to requestRebind for BankNotificationListener: $e")
                        }
                    }
                    result.success(true)
                }
                "updateIngestionSourceSettings" -> {
                    val whatsappEnabled = call.argument<Boolean>("whatsappEnabled") ?: false
                    val whatsappSenders = call.argument<List<String>>("whatsappSenders") ?: emptyList()
                    val gmailEnabled = call.argument<Boolean>("gmailEnabled") ?: false
                    val gmailSenders = call.argument<List<String>>("gmailSenders") ?: emptyList()
                    val extraPackages = call.argument<List<String>>("extraPackages") ?: emptyList()
                    IngestionConfigStore.save(
                        this,
                        whatsappEnabled,
                        whatsappSenders,
                        gmailEnabled,
                        gmailSenders,
                        extraPackages
                    )
                    result.success(true)
                }
                "hasOverlayPermission" -> {
                    result.success(DynamicIslandOverlayService.hasPermission(this))
                }
                "requestOverlayPermission" -> {
                    DynamicIslandOverlayService.requestPermission(this)
                    result.success(true)
                }
                "showDynamicIsland" -> {
                    val title = call.argument<String>("title") ?: "SpendX"
                    val amount = call.argument<String>("amount") ?: ""
                    val isExpense = call.argument<Boolean>("isExpense") ?: true
                    val subtitle = call.argument<String>("subtitle") ?: ""
                    DynamicIslandOverlayService.show(this, title, amount, isExpense, subtitle)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }


    }

    /**
     * Reads one bounded page of the SMS inbox.
     *
     * Cursor is the stable `(date, _id)` tuple in descending order, so messages
     * that share a timestamp are neither skipped nor duplicated. Returning a
     * page (rather than the whole inbox) keeps the Binder reply well below the
     * transaction limit even when the inbox has tens of thousands of messages.
     */
    private fun queryInboxPage(
        sinceEpochMs: Long?,
        limit: Int,
        beforeDate: Long?,
        beforeId: Long?,
    ): Map<String, Any?> {
        val clauses = mutableListOf<String>()
        val args = mutableListOf<String>()
        if (sinceEpochMs != null && sinceEpochMs > 0) {
            clauses.add("${Telephony.Sms.DATE} >= ?")
            args.add(sinceEpochMs.toString())
        }
        if (beforeDate != null && beforeId != null) {
            clauses.add(
                "(${Telephony.Sms.DATE} < ? OR (${Telephony.Sms.DATE} = ? AND ${Telephony.Sms._ID} < ?))"
            )
            args.add(beforeDate.toString())
            args.add(beforeDate.toString())
            args.add(beforeId.toString())
        }
        val selection = if (clauses.isEmpty()) null else clauses.joinToString(" AND ")
        val selectionArgs = if (args.isEmpty()) null else args.toTypedArray()
        val sortOrder = "${Telephony.Sms.DATE} DESC, ${Telephony.Sms._ID} DESC"

        val uri = Telephony.Sms.Inbox.CONTENT_URI
        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.THREAD_ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.DATE_SENT,
        )

        val messages = mutableListOf<Map<String, Any?>>()
        var hasMore = false
        var lastDate: Long? = null
        var lastId: Long? = null

        val cursor = contentResolver.query(uri, projection, selection, selectionArgs, sortOrder)
        cursor?.use {
            // Resolve indexes once, outside the row loop.
            val idIdx = it.getColumnIndexOrThrow(Telephony.Sms._ID)
            val threadIdx = it.getColumnIndexOrThrow(Telephony.Sms.THREAD_ID)
            val addressIdx = it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIdx = it.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIdx = it.getColumnIndexOrThrow(Telephony.Sms.DATE)
            val dateSentIdx = it.getColumnIndexOrThrow(Telephony.Sms.DATE_SENT)

            var count = 0
            while (it.moveToNext()) {
                if (count >= limit) {
                    hasMore = true
                    break
                }
                val id = it.getLong(idIdx)
                val date = it.getLong(dateIdx)
                messages.add(
                    mapOf(
                        "id" to id,
                        "thread_id" to it.getInt(threadIdx),
                        "address" to it.getString(addressIdx),
                        "body" to it.getString(bodyIdx),
                        "date" to date,
                        "date_sent" to it.getLong(dateSentIdx),
                    ),
                )
                lastDate = date
                lastId = id
                count++
            }
        }

        return mapOf(
            "messages" to messages,
            "hasMore" to hasMore,
            "nextCursor" to if (hasMore && lastDate != null && lastId != null) {
                mapOf("date" to lastDate, "id" to lastId)
            } else {
                null
            },
        )
    }

    /**
     * Reads one bounded page of the SMS inbox specifically for Phase 1.4 recovery.
     *
     * Keys:
     * - `_id DESC` monotonic keyset pagination
     * - `_id <= startMaxId`: Immutable snapshot ceiling captured at pass initiation
     * - `_id < beforeId`: Strict continuation cursor
     * - `date >= sevenDayThresholdMs`: Inclusive 7-day lookback window
     *
     * Decoupled completely from Phase 1.3 `queryInboxPage` and watermark cursor.
     */
    private fun queryRecoveryInboxPage(
        startMaxId: Long,
        limit: Int,
        beforeId: Long?,
        sevenDayThresholdMs: Long,
    ): Map<String, Any?> {
        val clampedLimit = limit.coerceIn(1, 500)
        val clauses = mutableListOf<String>()
        val args = mutableListOf<String>()

        // 1. Inclusive seven-day timestamp boundary: date >= ?
        clauses.add("${Telephony.Sms.DATE} >= ?")
        args.add(sevenDayThresholdMs.toString())

        // 2. Immutable snapshot ceiling: _id <= ?
        clauses.add("${Telephony.Sms._ID} <= ?")
        args.add(startMaxId.toString())

        // 3. Monotonic continuation: _id < ? (only when beforeId is provided)
        if (beforeId != null) {
            clauses.add("${Telephony.Sms._ID} < ?")
            args.add(beforeId.toString())
        }

        val selection = clauses.joinToString(" AND ")
        val selectionArgs = args.toTypedArray()
        val sortOrder = "${Telephony.Sms._ID} DESC"

        val uri = Telephony.Sms.Inbox.CONTENT_URI
        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.THREAD_ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.DATE_SENT,
        )

        val messages = mutableListOf<Map<String, Any?>>()
        var hasMore = false
        var lastId: Long? = null

        val cursor = contentResolver.query(uri, projection, selection, selectionArgs, sortOrder)
        cursor?.use {
            val idIdx = it.getColumnIndexOrThrow(Telephony.Sms._ID)
            val threadIdx = it.getColumnIndexOrThrow(Telephony.Sms.THREAD_ID)
            val addressIdx = it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIdx = it.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIdx = it.getColumnIndexOrThrow(Telephony.Sms.DATE)
            val dateSentIdx = it.getColumnIndexOrThrow(Telephony.Sms.DATE_SENT)

            var count = 0
            while (it.moveToNext()) {
                if (count >= clampedLimit) {
                    hasMore = true
                    break
                }
                val id = it.getLong(idIdx)
                messages.add(
                    mapOf(
                        "id" to id,
                        "thread_id" to it.getInt(threadIdx),
                        "address" to it.getString(addressIdx),
                        "body" to it.getString(bodyIdx),
                        "date" to it.getLong(dateIdx),
                        "date_sent" to it.getLong(dateSentIdx),
                    )
                )
                lastId = id
                count++
            }
        }

        return mapOf(
            "messages" to messages,
            "hasMore" to hasMore,
            "nextBeforeId" to if (hasMore && lastId != null) lastId else null,
        )
    }

    /**
     * Reads the current maximum `_id` in the telephony SMS inbox.
     * Used to capture the immutable `startMaxId` snapshot at the beginning of a recovery pass.
     */
    private fun getMaxInboxId(): Long? {
        val uri = Telephony.Sms.Inbox.CONTENT_URI
        val projection = arrayOf(Telephony.Sms._ID)
        val sortOrder = "${Telephony.Sms._ID} DESC"
        val cursor = contentResolver.query(uri, projection, null, null, sortOrder)
        cursor?.use {
            if (it.moveToNext()) {
                val idIdx = it.getColumnIndexOrThrow(Telephony.Sms._ID)
                return it.getLong(idIdx)
            }
        }
        return null
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

/// Tiny shared-prefs queue for financial SMS captured while the app isn't running.
object SmsStore {
    private const val PREFS = "spendx_sms"
    private const val KEY = "pending_sms_queue"
    private const val ENTRY_SEP = "\u0001"
    private const val FIELD_SEP = "\u0002"

    @Synchronized
    fun queue(context: Context, sender: String, body: String, sourceRecordId: String? = null, timestampMillis: Long? = null): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val existing = prefs.getString(KEY, "") ?: ""
        val existingEntries = existing.split(ENTRY_SEP).filter { it.isNotBlank() }

        // Deduplicate strictly by sourceRecordId when provided; never collapse two messages simply because sender and body match
        if (!sourceRecordId.isNullOrBlank()) {
            val alreadyQueued = existingEntries.any { entry ->
                val parts = entry.split(FIELD_SEP)
                parts.size >= 3 && parts[2] == sourceRecordId
            }
            if (alreadyQueued) {
                return true
            }
        }

        val tsStr = timestampMillis?.toString() ?: ""
        val entry = if (!sourceRecordId.isNullOrBlank()) {
            "$sender$FIELD_SEP$body$FIELD_SEP$sourceRecordId$FIELD_SEP$tsStr"
        } else {
            "$sender$FIELD_SEP$body"
        }

        val updatedEntries = existingEntries + entry
        var committed = prefs.edit().putString(KEY, updatedEntries.joinToString(ENTRY_SEP)).commit()
        if (!committed) {
            // Retry once synchronously to recover from transient I/O or locking conditions
            committed = prefs.edit().putString(KEY, updatedEntries.joinToString(ENTRY_SEP)).commit()
        }
        return committed
    }

    @Synchronized
    fun all(context: Context): List<Map<String, String>> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY, "") ?: ""
        if (raw.isBlank()) return emptyList()

        val entries = raw.split(ENTRY_SEP).filter { it.isNotBlank() }
        var hasLegacy = false

        val updatedEntries = mutableListOf<String>()
        val resultList = mutableListOf<Map<String, String>>()

        for (entry in entries) {
            val parts = if (entry.contains(FIELD_SEP)) entry.split(FIELD_SEP) else listOf("", entry)
            val sender = parts[0]
            val body = if (parts.size > 1) parts[1] else ""
            val sourceRecordId = if (parts.size >= 3 && parts[2].isNotBlank()) {
                parts[2]
            } else {
                hasLegacy = true
                "SRC:LEGACY_QUEUE:" + java.util.UUID.randomUUID().toString()
            }
            val timestamp = if (parts.size >= 4 && parts[3].isNotBlank()) parts[3] else ""

            updatedEntries.add("$sender$FIELD_SEP$body$FIELD_SEP$sourceRecordId$FIELD_SEP$timestamp")
            val itemMap = mutableMapOf(
                "sender" to sender,
                "body" to body,
                "sourceRecordId" to sourceRecordId,
            )
            if (timestamp.isNotBlank()) {
                itemMap["timestamp"] = timestamp
            }
            resultList.add(itemMap)
        }

        // If any legacy entries were assigned unique IDs, persist them atomically so they are stable
        if (hasLegacy) {
            val success = prefs.edit().putString(KEY, updatedEntries.joinToString(ENTRY_SEP)).commit()
            if (!success) {
                android.util.Log.w("SmsStore", "Failed to persist upgraded legacy queue entries to disk.")
            }
        }

        return resultList
    }

    @Synchronized
    fun remove(context: Context, sourceRecordIdsToRemove: Set<String>): Boolean {
        if (sourceRecordIdsToRemove.isEmpty()) return true
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY, "") ?: ""
        if (raw.isBlank()) return true
        val remaining = raw.split(ENTRY_SEP)
            .filter { it.isNotBlank() }
            .filterNot { entry ->
                val parts = entry.split(FIELD_SEP)
                parts.size >= 3 && sourceRecordIdsToRemove.contains(parts[2])
            }
        return prefs.edit().putString(KEY, remaining.joinToString(ENTRY_SEP)).commit()
    }

    @Synchronized
    fun clear(context: Context): Boolean {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY).commit()
    }
}
