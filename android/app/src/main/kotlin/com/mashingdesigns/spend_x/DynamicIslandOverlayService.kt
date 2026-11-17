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
import android.graphics.Color
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

/**
 * Native Android Dynamic Island / Origin Island Notch HUD for SpendX.
 *
 * Supports:
 * 1. Native Vivo / iQOO Origin Island capsule (adapts status bar icons left and right).
 * 2. System-wide WindowManager floating notch HUD overlay for other Android devices.
 */
object DynamicIslandOverlayService {

    private const val ORIGIN_ISLAND_NOTIFICATION_ID = 7771
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
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            true
        }
    }

    fun requestPermission(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(context)) {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                android.net.Uri.parse("package:${context.packageName}")
            ).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            context.startActivity(intent)
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
        val appContext = context.applicationContext
        val isVivo = isVivoOriginDevice()
        android.util.Log.d("DynamicIsland", "show() called: amount=$amount, isExpense=$isExpense, isVivo=$isVivo, hasOverlayPermission=${hasPermission(appContext)}")

        // 1. Always trigger native Vivo Origin Island notification capsule
        showVivoOriginIslandNotification(appContext, title, amount, isExpense, subtitle)

        // 2. For non-Vivo devices (or if overlay explicitly desired), trigger system WindowManager notch HUD
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
                val expandedWidth = (340 * dp).toInt()
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

    fun showVivoOriginIslandNotification(
        context: Context,
        title: String,
        amount: String,
        isExpense: Boolean,
        subtitle: String
    ) {
        try {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channelId = "spendx_live_updates_v3"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    notificationManager.deleteNotificationChannel("spendx_origin_island")
                    notificationManager.deleteNotificationChannel("spendx_origin_island_v2")
                } catch (_: Exception) {}

                val channel = NotificationChannel(
                    channelId,
                    "SpendX Live Updates",
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "SpendX Origin Island & Dynamic Island Live Updates"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                }
                notificationManager.createNotificationChannel(channel)
            }

            ensureOngoingAppSetting(context)

            val dirSymbol = if (isExpense) "-" else "+"
            val cleanAmount = if (amount.startsWith("₹")) amount else "₹$amount"
            val displayAmount = "$dirSymbol$cleanAmount"
            val fullTitle = if (isExpense) "Spent $cleanAmount" else "Received $cleanAmount"
            val sub = if (subtitle.isNotBlank() && subtitle != "SpendX") subtitle else (if (isExpense) "Expense Recorded" else "Income Recorded")

            val icon = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Icon.createWithResource(context, R.drawable.ic_notification)
            } else null

            val builder = NotificationCompat.Builder(context, channelId)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(fullTitle)
                .setContentText(sub)
                .setSubText(displayAmount)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setProgress(100, 100, false)
                .setColor(Color.parseColor(if (isExpense) "#F43F5E" else "#10B981"))
                .setShowWhen(true)

            // Vivo Origin Island / SuperX extras (Reverse-engineered from SystemUIPlugin.apk)
            val extras = Bundle().apply {
                putInt("notification.superx.operation", 0) // 0 = create/show capsule
                putInt("notification.superx.template", 1)  // template 1 (int!)
                putInt("notification.superx.newNode", 1)
                putInt("notification.superx.displays", 0x00111111) // All target locations
                putInt("progress_style_business_type", 1)
                putBoolean("notification.superx.islandNotify", true)
                putString("notification.superx.scene", "finance")
                putString("notification.superx.title", fullTitle)
                putString("notification.superx.content", sub)
                putString("notification.superx.capsule.text", displayAmount)
                putString("vivo.summary.text", displayAmount)
                putString("android.shortCriticalText", displayAmount)
                putBoolean("is_live_activity", true)
                putString("android.substName", "SpendX")

                // ShortInfos bundle (required by validSuperXShortInfoData in SuperXNotificationDataUtils)
                val shortInfos = Bundle().apply {
                    putString("notification.superx.shortInfos.coreInfoShort", displayAmount)
                    putString("notification.superx.shortInfos.describeShort", if (isExpense) "Spent" else "Received")
                    if (icon != null) {
                        putParcelable("notification.superx.shortInfos.image", icon)
                    }
                }
                putBundle("notification.superx.shortInfos", shortInfos)

                // Island specific sub-bundle "notification.superx.island" (Required by isUniqueIslandSuperXMessage & SuperXCapsuleDataController)
                val leftInfoBundle = Bundle().apply {
                    putString("island.superx.leftInfo.content", if (isExpense) "Spent" else "Received")
                    if (icon != null) {
                        putParcelable("island.superx.leftInfo.icon", icon)
                    }
                }
                val rightInfoBundle = Bundle().apply {
                    putString("island.superx.rightInfo.content", displayAmount)
                    putString("island.superx.rightInfo.capsuleContent", displayAmount)
                }

                val islandSubBundle = Bundle().apply {
                    putBoolean("island.superx.forceShow", true)
                    putBoolean("island.superx.forceShowCard", true)
                    putInt("island.superx.template", 1)
                    putInt("island.superx.leftTemplate", 1)
                    putInt("island.superx.rightTemplate", 1)
                    putBundle("island.superx.leftInfo", leftInfoBundle)
                    putBundle("island.superx.rightInfo", rightInfoBundle)
                }
                putBundle("notification.superx.island", islandSubBundle)

                // Root-level island keys for compatibility
                putBoolean("island.superx.forceShow", true)
                putBoolean("island.superx.forceShowCard", true)
                putInt("island.superx.template", 1)
                putInt("island.superx.leftTemplate", 1)
                putInt("island.superx.rightTemplate", 1)
                putBundle("island.superx.leftInfo", leftInfoBundle)
                putBundle("island.superx.rightInfo", rightInfoBundle)

                // Capsule specific bundle
                val capsule = Bundle().apply {
                    putString("notification.superx.capsule.content", displayAmount)
                    if (icon != null) {
                        putParcelable("notification.superx.capsule.icon", icon)
                    }
                }
                putBundle("notification.superx.capsule", capsule)

                // BaseInfos bundle
                val baseInfos = Bundle().apply {
                    putString("notification.superx.baseInfos.title", fullTitle)
                    putString("notification.superx.baseInfos.content", sub)
                    if (icon != null) {
                        putParcelable("notification.superx.baseInfos.icon", icon)
                    }
                }
                putBundle("notification.superx.baseInfos", baseInfos)
            }
            builder.addExtras(extras)

            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            if (launchIntent != null) {
                val pi = PendingIntent.getActivity(
                    context,
                    1005,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                builder.setContentIntent(pi)
            }

            notificationManager.notify(ORIGIN_ISLAND_NOTIFICATION_ID, builder.build())

            // Auto-dismiss after 6.0 seconds
            mainHandler.postDelayed({
                try {
                    notificationManager.cancel(ORIGIN_ISLAND_NOTIFICATION_ID)
                } catch (_: Exception) {}
            }, 6000)
        } catch (e: Exception) {
            android.util.Log.w("OriginIsland", "Failed to show Vivo Origin Island notification: $e")
        }
    }
}
