package com.mashingdesigns.spend_x

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.util.concurrent.atomic.AtomicLong

/**
 * FlutterPlugin that registers the spendx/process_lock MethodChannel
 * on any FlutterEngine (both foreground Activity engines and background
 * service/notification engines).
 */
class SpendXProcessLockPlugin : FlutterPlugin {
    companion object {
        private val engineCounter = AtomicLong(0)
    }

    private var engineId: String? = null

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        val id = "engine_${engineCounter.incrementAndGet()}_${System.identityHashCode(binding.binaryMessenger)}"
        this.engineId = id
        SpendXProcessLockLeaseManager.registerWithMessenger(
            binding.binaryMessenger,
            binding.applicationContext,
            id
        )
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        val id = engineId
        if (id != null) {
            SpendXProcessLockLeaseManager.getInstance(binding.applicationContext).onEngineDetached(id)
        }
    }
}
