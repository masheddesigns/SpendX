package com.mashingdesigns.spend_x

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class DynamicIslandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d("DynamicIslandReceiver", "onReceive called with action: ${intent.action}")
        val amount = intent.getStringExtra("amount") ?: "371.52"
        val isExpense = intent.getBooleanExtra("isExpense", true)
        val subtitle = intent.getStringExtra("subtitle") ?: "District • CSB Card"
        val title = intent.getStringExtra("title") ?: "SpendX"
        DynamicIslandOverlayService.show(context, title, amount, isExpense, subtitle)
    }
}
