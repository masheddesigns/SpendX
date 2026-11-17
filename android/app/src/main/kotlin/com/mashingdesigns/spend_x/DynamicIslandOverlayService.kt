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
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat

/**
 * Native Android Dynamic Island Notch HUD for SpendX.
 *
 * Renders an animated OLED notch pill around the front camera cutout
 * when an expense, income, or bank transaction is captured.
 */
object DynamicIslandOverlayService {

    private var activeView: View? = null
    private var dismissRunnable: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())

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

        // If app is currently in foreground, Flutter's in-app DynamicIslandHUD handles the animation cleanly.
        // We do NOT show system overlay or system notification to avoid heads-up popups over the app!
        if (MainActivity.isAppInForeground) {
            return
        }

        // When user is outside the app (e.g. on Home screen, WhatsApp, etc.):
        // 1. Show Vivo Origin Island notification capsule (LOW importance so NO heads-up popup banner!)
        showVivoOriginIslandNotification(appContext, title, amount, isExpense, subtitle)

        // 2. If overlay permission is granted, also show floating WindowManager notch HUD
        if (!hasPermission(appContext)) {
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

                val collapsedWidth = (80 * dp).toInt()
                val expandedWidth = (310 * dp).toInt()
                val targetHeight = (48 * dp).toInt()

                var notchY = (8 * dp).toInt()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    try {
                        val insets = windowManager.currentWindowMetrics.windowInsets
                        val cutout = insets.displayCutout
                        if (cutout != null) {
                            val top = cutout.safeInsetTop
                            if (top > 0) {
                                notchY = maxOf(4, (top * 0.16).toInt())
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
                    setPadding((12 * dp).toInt(), (6 * dp).toInt(), (14 * dp).toInt(), (6 * dp).toInt())
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.RECTANGLE
                        cornerRadius = 24 * dp
                        setColor(Color.parseColor("#0F0F14"))
                        setStroke((1 * dp).toInt(), Color.parseColor(if (isExpense) "#33F43F5E" else "#3310B981"))
                    }
                    elevation = 16 * dp
                    alpha = 0f
                }

                // SpendX Icon / Logo
                val iconView = ImageView(appContext).apply {
                    setImageResource(R.mipmap.launcher_icon)
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        setColor(Color.parseColor(if (isExpense) "#2A1820" else "#13271E"))
                    }
                    setPadding((3 * dp).toInt(), (3 * dp).toInt(), (3 * dp).toInt(), (3 * dp).toInt())
                }

                // Content Column (Direction + Subtitle)
                val textColumn = LinearLayout(appContext).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER_VERTICAL
                }

                val titleView = TextView(appContext).apply {
                    text = if (subtitle.isNotBlank() && subtitle != "SpendX") subtitle else (if (isExpense) "Spent" else "Received")
                    setTextColor(Color.parseColor("#9CA3AF"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                    maxLines = 1
                }

                val amountView = TextView(appContext).apply {
                    val prefix = if (isExpense) "- " else "+ "
                    text = "$prefix$amount"
                    setTextColor(Color.parseColor(if (isExpense) "#FCA5A5" else "#34D399"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                    typeface = Typeface.create("sans-serif", Typeface.BOLD)
                    maxLines = 1
                }

                textColumn.addView(amountView)
                textColumn.addView(titleView)

                // Direction Badge Icon on Right
                val badgeView = TextView(appContext).apply {
                    text = if (isExpense) "↑" else "↓"
                    setTextColor(Color.parseColor(if (isExpense) "#EF4444" else "#10B981"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                    typeface = Typeface.create("sans-serif", Typeface.BOLD)
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        setColor(Color.parseColor(if (isExpense) "#33EF4444" else "#3310B981"))
                    }
                    gravity = Gravity.CENTER
                }

                rootPill.addView(
                    iconView,
                    LinearLayout.LayoutParams((28 * dp).toInt(), (28 * dp).toInt()).apply {
                        rightMargin = (10 * dp).toInt()
                    }
                )
                rootPill.addView(
                    textColumn,
                    LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                )
                rootPill.addView(
                    badgeView,
                    LinearLayout.LayoutParams((24 * dp).toInt(), (24 * dp).toInt())
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

                // Auto-collapse after 3.8 seconds
                dismissRunnable = Runnable {
                    dismissIsland(windowManager, rootPill)
                }
                mainHandler.postDelayed(dismissRunnable!!, 3800)

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
            val channelId = "spendx_origin_island_v2"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    notificationManager.deleteNotificationChannel("spendx_origin_island")
                } catch (_: Exception) {}

                val channel = NotificationChannel(
                    channelId,
                    "Origin Island Alerts",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "SpendX Origin Island & Dynamic Island Live Updates"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                }
                notificationManager.createNotificationChannel(channel)
            }

            val dirSymbol = if (isExpense) "-" else "+"
            val displayAmount = "$dirSymbol₹$amount"
            val fullTitle = if (isExpense) "Spent $displayAmount" else "Received $displayAmount"
            val sub = if (subtitle.isNotBlank() && subtitle != "SpendX") subtitle else (if (isExpense) "Expense Recorded" else "Income Recorded")

            val builder = NotificationCompat.Builder(context, channelId)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(fullTitle)
                .setContentText(sub)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .setTimeoutAfter(4000)

            // Vivo Origin Island / Atomic Island specific extras
            val extras = Bundle().apply {
                putInt("notification.superx.operation", 0) // 0 = create/show capsule
                putString("notification.superx.template", "capsule")
                putString("notification.superx.scene", "finance")
                putString("notification.superx.title", fullTitle)
                putString("notification.superx.content", sub)
                putString("notification.superx.capsule.text", displayAmount)
                putString("vivo.summary.text", displayAmount)
                putBoolean("is_live_activity", true)
                putString("android.substName", "SpendX")
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

            notificationManager.notify(7771, builder.build())
        } catch (e: Exception) {
            android.util.Log.w("OriginIsland", "Failed to show Vivo Origin Island notification: $e")
        }
    }
}
