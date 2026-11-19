package com.mashingdesigns.spend_x

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Native Android Dynamic Island / Origin Island Notch HUD for SpendX.
 *
 * Supports:
 * 1. Native Vivo / iQOO Origin Island capsule (adapts status bar icons left and right).
 * 2. System-wide WindowManager floating notch HUD overlay for other Android devices.
 */
object DynamicIslandOverlayService {

    private const val ORIGIN_ISLAND_NOTIFICATION_ID = 7771
    private const val ORIGIN_ISLAND_TAG = "VIVO_SUPERX_TAG"
    private var activeView: View? = null
    private var dismissRunnable: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun isVivoOriginDevice(): Boolean {
        val brand = Build.BRAND.lowercase()
        val manufacturer = Build.MANUFACTURER.lowercase()
        return brand.contains("vivo") || brand.contains("iqoo") ||
                manufacturer.contains("vivo") || manufacturer.contains("iqoo")
    }

    private fun ensureOngoingAppSetting(context: Context) {
        try {
            val cr = context.contentResolver
            val currentList = Settings.Secure.getString(cr, "key_ongoing_app_list") ?: ""
            if (!currentList.contains(context.packageName)) {
                val updated = if (currentList.isBlank()) context.packageName else "$currentList,${context.packageName}"
                Settings.Secure.putString(cr, "key_ongoing_app_list", updated)
            }
            val key = "superx_notification_${context.packageName.replace('.', '_')}"
            Settings.Secure.putInt(cr, key, 1)
        } catch (_: Exception) {}
    }

    fun hasPermission(context: Context): Boolean {
        if (isVivoOriginDevice()) {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ContextCompat.checkSelfPermission(
                    context,
                    android.Manifest.permission.POST_NOTIFICATIONS
                ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            } else {
                androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()
            }
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            true
        }
    }

    fun requestPermission(context: Context) {
        if (isVivoOriginDevice()) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val hasNotif = ContextCompat.checkSelfPermission(
                    context,
                    android.Manifest.permission.POST_NOTIFICATIONS
                ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                if (!hasNotif) {
                    try {
                        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                            putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        context.startActivity(intent)
                        return
                    } catch (_: Exception) {}
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(context)) {
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    android.net.Uri.parse("package:${context.packageName}")
                ).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                context.startActivity(intent)
            } catch (_: Exception) {}
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    fun show(
        context: Context,
        title: String,
        amount: String,
        isExpense: Boolean,
        subtitle: String = "SpendX"
    ) {
        if (amount.isBlank()) {
            android.util.Log.w("DynamicIsland", "Suppressing overlay: blank amount")
            return
        }
        val appContext = context.applicationContext
        val isVivo = isVivoOriginDevice()
        android.util.Log.i("DynamicIsland", "show() called: amount=$amount, isExpense=$isExpense, isVivo=$isVivo")

        // 1. Post native Promoted Ongoing notification for Vivo Origin Island / SystemUI
        if (isVivo) {
            showVivoOriginIslandNotification(appContext, title, amount, isExpense, subtitle)
            return
        }

        // 2. Start IslandForegroundService to keep process high-priority while island is showing
        try {
            val serviceIntent = Intent(appContext, IslandForegroundService::class.java).apply {
                action = IslandForegroundService.ACTION_SHOW
                putExtra(IslandForegroundService.EXTRA_AMOUNT, amount)
                putExtra(IslandForegroundService.EXTRA_IS_EXPENSE, isExpense)
                putExtra(IslandForegroundService.EXTRA_SUBTITLE, subtitle)
                putExtra(IslandForegroundService.EXTRA_TITLE, title)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appContext.startForegroundService(serviceIntent)
            } else {
                appContext.startService(serviceIntent)
            }
            android.util.Log.i("DynamicIsland", "Started IslandForegroundService successfully")
        } catch (e: Exception) {
            android.util.Log.w("DynamicIsland", "startForegroundService exception: $e")
        }

        // 3. For non-Vivo devices (or if overlay explicitly desired), trigger system WindowManager notch HUD
        if (isVivo) {
            // Vivo Origin Island natively adapts the status bar (moves left icons left, battery right).
            // Do not paint a floating overlay on top of the native Origin Island.
            return
        }

        if (!hasPermission(appContext)) {
            android.util.Log.w("DynamicIsland", "Overlay permission NOT granted, skipping WindowManager overlay")
            return
        }

        mainHandler.post {
            try {
                val windowManager = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

                // Dismiss existing if already visible
                activeView?.let { existing ->
                    dismissRunnable?.let { mainHandler.removeCallbacks(it) }
                    try { windowManager.removeView(existing) } catch (_: Exception) {}
                    activeView = null
                }

                val dp = appContext.resources.displayMetrics.density

                val collapsedWidth = (60 * dp).toInt()
                val expandedWidth = minOf(
                    (340 * dp).toInt(),
                    (appContext.resources.displayMetrics.widthPixels - (32 * dp).toInt()).coerceAtLeast((200 * dp).toInt())
                )
                val targetHeight = (64 * dp).toInt()

                var notchY = 0
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    try {
                        val insets = windowManager.currentWindowMetrics.windowInsets
                        val cutout = insets.displayCutout
                        if (cutout != null) {
                            val top = cutout.safeInsetTop
                            if (top > 0) {
                                notchY = maxOf(0, (top * 0.08).toInt())
                            }
                        }
                    } catch (_: Exception) {}
                }

                val layoutParams = WindowManager.LayoutParams(
                    collapsedWidth,
                    targetHeight,
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                    else
                        @Suppress("DEPRECATION")
                        WindowManager.LayoutParams.TYPE_PHONE,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT
                ).apply {
                    gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                    y = notchY
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                    }
                }

                // Root pill container
                val rootPill = LinearLayout(appContext).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding((16 * dp).toInt(), (18 * dp).toInt(), (16 * dp).toInt(), (6 * dp).toInt())
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.RECTANGLE
                        cornerRadius = 32 * dp
                        setColor(Color.BLACK)
                        setStroke((1.2 * dp).toInt(), Color.parseColor(if (isExpense) "#4DF43F5E" else "#4D10B981"))
                    }
                    elevation = 24 * dp
                    alpha = 0f
                }

                // Micro Direction Icon Gem
                val iconView = TextView(appContext).apply {
                    text = if (isExpense) "↗" else "↙"
                    setTextColor(Color.parseColor(if (isExpense) "#F43F5E" else "#10B981"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                    typeface = Typeface.create("sans-serif", Typeface.BOLD)
                    gravity = Gravity.CENTER
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        setColor(Color.parseColor(if (isExpense) "#2BF43F5E" else "#2B10B981"))
                    }
                }

                // Content Column (Amount + Subtitle)
                val textColumn = LinearLayout(appContext).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER_VERTICAL
                }

                val cleanAmount = if (amount.startsWith("₹")) amount else "₹$amount"
                val prefix = if (isExpense) "- " else "+ "
                val amountView = TextView(appContext).apply {
                    text = "$prefix$cleanAmount"
                    setTextColor(Color.parseColor(if (isExpense) "#FCA5A5" else "#34D399"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f)
                    typeface = Typeface.create("sans-serif", Typeface.BOLD)
                    maxLines = 1
                }

                val titleView = TextView(appContext).apply {
                    text = if (subtitle.isNotBlank() && subtitle != "SpendX") subtitle else (if (isExpense) "Spent" else "Received")
                    setTextColor(Color.parseColor("#9CA3AF"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
                    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                    maxLines = 1
                }

                textColumn.addView(amountView)
                textColumn.addView(titleView)

                // Direction Badge Pill on Right (EXPENSE / INCOME)
                val badgeView = TextView(appContext).apply {
                    text = if (isExpense) "EXPENSE" else "INCOME"
                    setTextColor(Color.parseColor(if (isExpense) "#F43F5E" else "#10B981"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 9f)
                    typeface = Typeface.create("sans-serif", Typeface.BOLD)
                    letterSpacing = 0.05f
                    setPadding((7 * dp).toInt(), (3 * dp).toInt(), (7 * dp).toInt(), (3 * dp).toInt())
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.RECTANGLE
                        cornerRadius = 12 * dp
                        setColor(Color.parseColor(if (isExpense) "#33F43F5E" else "#3310B981"))
                    }
                    gravity = Gravity.CENTER
                }

                rootPill.addView(
                    iconView,
                    LinearLayout.LayoutParams((30 * dp).toInt(), (30 * dp).toInt()).apply {
                        rightMargin = (10 * dp).toInt()
                    }
                )
                rootPill.addView(
                    textColumn,
                    LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                )
                rootPill.addView(
                    badgeView,
                    LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                )

                // Tap to open app
                rootPill.setOnClickListener {
                    try {
                        val launchIntent = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)
                        if (launchIntent != null) {
                            launchIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                            appContext.startActivity(launchIntent)
                        }
                    } catch (_: Exception) {}
                    dismissIsland(windowManager, rootPill)
                }

                windowManager.addView(rootPill, layoutParams)
                activeView = rootPill
                android.util.Log.d("DynamicIsland", "WindowManager.addView succeeded! width=$expandedWidth, height=$targetHeight, y=$notchY")

                // Spring expansion animation
                val anim = ValueAnimator.ofFloat(0f, 1f).apply {
                    duration = 380
                    interpolator = OvershootInterpolator(1.2f)
                    addUpdateListener { va ->
                        val prog = va.animatedValue as Float
                        layoutParams.width = (collapsedWidth + (expandedWidth - collapsedWidth) * prog).toInt()
                        rootPill.alpha = prog.coerceIn(0f, 1f)
                        try {
                            windowManager.updateViewLayout(rootPill, layoutParams)
                        } catch (_: Exception) {}
                    }
                }
                anim.start()

                // Auto-collapse after 4.2 seconds
                dismissRunnable = Runnable {
                    dismissIsland(windowManager, rootPill)
                }
                mainHandler.postDelayed(dismissRunnable!!, 4200)

            } catch (e: Exception) {
                android.util.Log.w("DynamicIsland", "Failed to display dynamic island: $e")
            }
        }
    }

    private fun dismissIsland(windowManager: WindowManager, view: View) {
        mainHandler.post {
            try {
                if (view != activeView) return@post
                val collapseAnim = ValueAnimator.ofFloat(1f, 0f).apply {
                    duration = 240
                    interpolator = DecelerateInterpolator()
                    addUpdateListener { va ->
                        val prog = va.animatedValue as Float
                        view.alpha = prog
                        view.scaleX = 0.8f + 0.2f * prog
                        view.scaleY = 0.8f + 0.2f * prog
                    }
                    addListener(object : AnimatorListenerAdapter() {
                        override fun onAnimationEnd(animation: Animator) {
                            try {
                                windowManager.removeView(view)
                            } catch (_: Exception) {}
                            if (activeView == view) {
                                activeView = null
                            }
                        }
                    })
                }
                collapseAnim.start()
            } catch (_: Exception) {}
        }
    }

    private fun createSpendXIslandIcon(context: Context, isExpense: Boolean): Icon {
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        // Draw crisp circular badge: Rose Red for expense, Emerald Green for income
        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor(if (isExpense) "#E11D48" else "#059669")
            style = Paint.Style.FILL
        }
        val radius = size / 2f
        canvas.drawCircle(radius, radius, radius, bgPaint)

        // Draw SpendX wallet icon inside badge
        val drawable = ContextCompat.getDrawable(context, R.drawable.ic_notification)
        if (drawable != null) {
            val inset = (size * 0.22f).toInt()
            drawable.setBounds(inset, inset, size - inset, size - inset)
            drawable.setTint(Color.WHITE)
            drawable.draw(canvas)
        }

        return Icon.createWithBitmap(bitmap)
    }

    fun buildOriginIslandNotification(
        context: Context,
        title: String,
        amount: String,
        isExpense: Boolean,
        subtitle: String
    ): android.app.Notification {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "spendx_live_updates_v8"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                notificationManager.deleteNotificationChannel("spendx_origin_island")
                notificationManager.deleteNotificationChannel("spendx_origin_island_v2")
                notificationManager.deleteNotificationChannel("spendx_live_updates_v3")
                notificationManager.deleteNotificationChannel("spendx_live_updates_v4")
                notificationManager.deleteNotificationChannel("spendx_live_updates_v5")
                notificationManager.deleteNotificationChannel("spendx_live_updates_v6")
                notificationManager.deleteNotificationChannel("spendx_live_updates_v7")
            } catch (_: Exception) {}

            val channel = NotificationChannel(
                channelId,
                "SpendX Live Updates",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "SpendX Origin Island Live Updates"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

        ensureOngoingAppSetting(context)

        val dirSymbol = if (isExpense) "-" else "+"
        val cleanAmount = when {
            amount.isBlank() -> ""
            amount.startsWith("₹") -> amount
            else -> "₹$amount"
        }
        val displayAmount = when {
            cleanAmount.isNotBlank() -> "$dirSymbol$cleanAmount"
            isExpense -> "Expense"
            else -> "Income"
        }
        val fullTitle = if (isExpense) "Spent $cleanAmount" else "Received $cleanAmount"
        val sub = if (subtitle.isNotBlank() && subtitle != "SpendX") subtitle else (if (isExpense) "Expense Recorded" else "Income Recorded")

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(context)
        }

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            action = "com.mashingdesigns.spend_x.ACTION_SHOW_TRANSACTION_ISLAND"
            putExtra("amount", cleanAmount)
            putExtra("islandAmount", cleanAmount)
            putExtra("displayAmount", displayAmount)
            putExtra("isExpense", isExpense)
            putExtra("title", fullTitle)
            putExtra("subtitle", sub)
            putExtra("timestamp", System.currentTimeMillis())
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = if (launchIntent != null) {
            PendingIntent.getActivity(
                context,
                1005,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null

        val icon = createSpendXIslandIcon(context, isExpense)
        val amountColor = Color.parseColor(if (isExpense) "#F43F5E" else "#10B981")
        val styledAmount = android.text.SpannableString(displayAmount).apply {
            setSpan(android.text.style.ForegroundColorSpan(amountColor), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(android.text.style.StyleSpan(android.graphics.Typeface.BOLD), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }

        builder
            .setSmallIcon(icon)
            .setTicker(styledAmount)
            .setContentTitle(styledAmount)
            .setContentText(fullTitle)
            .setSubText("SpendX")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setUsesChronometer(false)
            .setColor(amountColor)
            .setStyle(android.app.Notification.BigTextStyle().setBigContentTitle(styledAmount).bigText("$fullTitle • $sub"))

        @Suppress("DEPRECATION")
        builder.setPriority(android.app.Notification.PRIORITY_MAX)

        if (pi != null) {
            builder.setContentIntent(pi)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            builder.setCategory(android.app.Notification.CATEGORY_STATUS)
            builder.setVisibility(android.app.Notification.VISIBILITY_PUBLIC)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setTimeoutAfter(7000)
        }

        // Android 15 & Vivo Origin Island Promoted Ongoing APIs
        try {
            val setShortCrit = builder.javaClass.getMethod("setShortCriticalText", CharSequence::class.java)
            setShortCrit.invoke(builder, styledAmount)
        } catch (_: Throwable) {}

        try {
            val setPromoted = builder.javaClass.getMethod("setRequestPromotedOngoing", Boolean::class.javaPrimitiveType)
            setPromoted.invoke(builder, true)
        } catch (_: Throwable) {}

        // ShortInfos bundle (required by validSuperXShortInfoData in SuperXNotificationDataUtils)
        val shortInfos = Bundle().apply {
            putCharSequence("notification.superx.shortInfos.coreInfoShort", styledAmount)
            putString("notification.superx.shortInfos.describeShort", if (isExpense) "Spent" else "Received")
            putParcelable("notification.superx.shortInfos.image", icon)
        }

        // BaseInfos bundle
        val baseInfos = Bundle().apply {
            putString("notification.superx.baseInfos.title", fullTitle)
            putString("notification.superx.baseInfos.content", sub)
            putParcelable("notification.superx.baseInfos.icon", icon)
        }

        // Vivo Origin Island SuperX Capsule bundle (consumed by SuperXCapsuleDataController & addAtomIslandCapsuleElementToShow)
        val capsuleBundle = Bundle().apply {
            putInt("notification.superx.capsule.state", 1) // 1 = ACTIVE/SHOW
            putCharSequence("notification.superx.capsule.content", styledAmount) // Capsule text (-₹50.00 / +₹50.00)
            putParcelable("notification.superx.capsule.icon", icon) // Capsule icon (SpendX icon)
            putInt("notification.superx.capsule.contentColor", amountColor)
            putInt("notification.superx.capsule.bgColor", Color.BLACK)
            putInt("notification.superx.capsule.showTime", 6) // Visible for 6 seconds
            putBoolean("notification.superx.capsule.landingAutoHide", true)
            if (pi != null) {
                putParcelable("notification.superx.capsule.clickResp", pi)
            }
        }

        // Left side of Island: SpendX icon & label
        val leftInfoBundle = Bundle().apply {
            putParcelable("island.superx.leftInfo.icon", icon)
            putString("island.superx.leftInfo.content", "SpendX")
        }

        // Right side of Island: display amount text (-₹50.00 / +₹50.00) (Template 6 = text display)
        val rightInfoBundle = Bundle().apply {
            putCharSequence("island.superx.rightInfo.content", styledAmount)
            putCharSequence("island.superx.rightInfo.capsuleContent", styledAmount)
            putInt("island.superx.rightInfo.capsuleContentColor", amountColor)
            putInt("island.superx.rightInfo.contentColor", amountColor)
            putInt("island.superx.rightInfo.capsuleBgColor", Color.BLACK)
            if (pi != null) {
                putParcelable("island.superx.rightInfo.clickResp", pi)
            }
        }

        // Vivo Origin Island SuperX bundle (consumed by addAtomIslandElementToShow)
        // MUST be nested inside notification.superx.island!
        val islandBundle = Bundle().apply {
            putInt("island.superx.leftTemplate", 1) // 1 -> Icon + label
            putInt("island.superx.rightTemplate", 6) // 6 -> Text display (NOT 4 which is chronometer!)
            putBundle("island.superx.leftInfo", leftInfoBundle)
            putBundle("island.superx.rightInfo", rightInfoBundle)
            putBoolean("island.superx.forceShow", true)
            putBoolean("island.superx.forceShowCard", false) // false prevents giant card dropdown!
            putBoolean("island.superx.forceShowCard.keyguard", false)
            putInt("island.superx.forceShowCardInt", 0)
            putString("island.superx.landingInfo", context.packageName)
            putInt("island.superx.islandClick", 1)
            putInt("island.superx.showTime", 6)
            putInt("island.superx.state", 1)
            if (pi != null) {
                putParcelable("island.superx.clickResp", pi)
            }
        }

        // Vivo Origin Island & Android 16 Promoted Ongoing contract
        val extras = Bundle().apply {
            // Android 16 standard Promoted Ongoing chips triggers
            putBoolean("android.requestPromotedOngoing", true)
            putCharSequence("android.shortCriticalText", styledAmount)
            putString("android.substName", "SpendX")
            putInt("android.color", amountColor)
            putBoolean("android.colorized", false)
            putBoolean("android.showChronometer", false)

            // Vivo Origin Island SuperX triggers
            putBundle("notification.superx.island", islandBundle)
            putBundle("notification.superx.capsule", capsuleBundle)
            putBundle("notification.superx.shortInfos", shortInfos)
            putBundle("notification.superx.baseInfos", baseInfos)
            putInt("notification.superx.operation", 0)       // 0 = show/create
            putInt("notification.superx.newNode", 1)
            putInt("notification.superx.displays", 0x00111111) // Bit 0x100 (256) enables status bar island
            putBoolean("notification.superx.islandNotify", true)
            putString("notification.superx.scene", "finance")
            putString("notification.superx.title", fullTitle)
            putString("notification.superx.content", sub)
            putCharSequence("notification.superx.capsule.text", styledAmount)
            putString("vivo.summary.text", displayAmount)
            putBoolean("is_live_activity", true)
            putString("SUPERX_VALUE", "true")

            // Compatibility root keys for legacy Vivo SystemUI
            putBoolean("island.superx.forceShow", true)
            putBoolean("island.superx.forceShowCard", false)
            putBoolean("island.superx.forceShowCard.keyguard", false)
            putInt("island.superx.forceShowCardInt", 0)
            putString("island.superx.landingInfo", context.packageName)
            putParcelable("island.superx.leftInfo.icon", icon)
            putString("island.superx.leftInfo.content", "SpendX")
            putCharSequence("island.superx.rightInfo.content", styledAmount)
            putCharSequence("island.superx.rightInfo.capsuleContent", styledAmount)
            putInt("island.superx.rightInfo.capsuleContentColor", amountColor)
            putInt("island.superx.rightInfo.contentColor", amountColor)
            putInt("island.superx.rightInfo.capsuleBgColor", Color.BLACK)
            if (pi != null) {
                putParcelable("island.superx.rightInfo.clickResp", pi)
                putParcelable("island.superx.clickResp", pi)
            }
            putBundle("island.superx.leftInfo", leftInfoBundle)
            putBundle("island.superx.rightInfo", rightInfoBundle)
        }
        builder.addExtras(extras)

        return builder.build()
    }

    private var vivoDismissRunnable: Runnable? = null

    fun showVivoOriginIslandNotification(
        context: Context,
        title: String,
        amount: String,
        isExpense: Boolean,
        subtitle: String
    ) {
        try {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val notification = buildOriginIslandNotification(context, title, amount, isExpense, subtitle)
            notificationManager.notify(ORIGIN_ISLAND_TAG, ORIGIN_ISLAND_NOTIFICATION_ID, notification)

            // Cancel any previously scheduled dismiss runnable so a second transaction within 6s
            // is not prematurely canceled by the earlier transaction's timer.
            vivoDismissRunnable?.let { mainHandler.removeCallbacks(it) }
            val runnable = Runnable {
                try {
                    notificationManager.cancel(ORIGIN_ISLAND_TAG, ORIGIN_ISLAND_NOTIFICATION_ID)
                } catch (_: Exception) {}
            }
            vivoDismissRunnable = runnable
            mainHandler.postDelayed(runnable, 6000)
        } catch (e: Exception) {
            android.util.Log.w("OriginIsland", "Failed to show Vivo Origin Island notification: $e")
        }
    }
}
