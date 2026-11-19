package com.mashingdesigns.spend_x

import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

class IslandForegroundService : Service() {
    companion object {
        const val ACTION_SHOW = "com.mashingdesigns.spend_x.ACTION_SHOW_ISLAND"
        const val EXTRA_AMOUNT = "amount"
        const val EXTRA_IS_EXPENSE = "isExpense"
        const val EXTRA_SUBTITLE = "subtitle"
        const val EXTRA_TITLE = "title"
        const val NOTIFICATION_ID = 7771
    }

    private val handler = Handler(Looper.getMainLooper())
    private val dismissRunnable = Runnable {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(NOTIFICATION_ID)
            stopSelf()
        } catch (e: Exception) {
            Log.w("IslandFGS", "Error stopping foreground: $e")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val amount = intent?.getStringExtra(EXTRA_AMOUNT) ?: "1.00"
        val isExpense = intent?.getBooleanExtra(EXTRA_IS_EXPENSE, true) ?: true
        val subtitle = intent?.getStringExtra(EXTRA_SUBTITLE) ?: "SpendX"
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "SpendX"

        Log.i("IslandFGS", "onStartCommand: amount=$amount, isExpense=$isExpense, subtitle=$subtitle")

        val notification = DynamicIslandOverlayService.buildOriginIslandNotification(
            this, title, amount, isExpense, subtitle
        )

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC or ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w("IslandFGS", "startForeground with types failed, retrying basic startForeground: $e")
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (e2: Exception) {
                Log.e("IslandFGS", "startForeground failed: $e2")
                val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIFICATION_ID, notification)
            }
        }

        // Keep active for 6 seconds, then dismiss
        handler.removeCallbacks(dismissRunnable)
        handler.postDelayed(dismissRunnable, 6000)

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(dismissRunnable)
        super.onDestroy()
    }
}
