package com.mashingdesigns.spend_x

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.Condition
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.random.Random

/**
 * State machine representing the process-local ownership and lock status.
 */
enum class LockManagerState {
    UNINITIALIZED,
    OPEN,               // Shared OS lock held; normal reads and writes admitted
    EXCLUSIVE_PENDING,  // Admission closed; draining readers or acquiring exclusive lock
    EXCLUSIVE_HELD,     // Exclusive F_WRLCK held; restore operations executing
    INDETERMINATE       // Error during release or lock state uncertain; fail-safe quarantine
}

/**
 * Metadata for an operation-scoped native ticket allocated to an engine.
 */
data class NativeTicket(
    val ticketId: String,
    val engineId: String,
    val operationTag: String,
    val acquiredAtMs: Long
)

/**
 * Authoritative process-level lock lease manager for SpendX.
 *
 * Guarantees:
 * 1. Exactly one owner of the lockfile descriptor per OS process.
 * 2. Shared lease reference counting (aggregate foreground lease + background operation tickets).
 * 3. Atomic admission closure and fail-fast rejection during restore.
 * 4. Active reader drainage with bounded timeout.
 * 5. 6-step non-atomic shared-to-exclusive OS lock upgrade with bounded exponential backoff.
 * 6. Protection against stale, duplicate, or cross-engine ticket releases.
 * 7. Engine-teardown bound cleanup: outstanding tickets reclaimed on FlutterEngine detachment to prevent restore deadlocks.
 */
class SpendXProcessLockLeaseManager(
    private val lockFile: File
) {
    private fun logI(tag: String, msg: String) {
        try {
            Log.i(tag, msg)
        } catch (_: RuntimeException) {
            println("[$tag] INFO: $msg")
        }
    }

    private fun logD(tag: String, msg: String) {
        try {
            Log.d(tag, msg)
        } catch (_: RuntimeException) {
            println("[$tag] DEBUG: $msg")
        }
    }

    private fun logW(tag: String, msg: String) {
        try {
            Log.w(tag, msg)
        } catch (_: RuntimeException) {
            println("[$tag] WARN: $msg")
        }
    }

    private fun logE(tag: String, msg: String, tr: Throwable? = null) {
        try {
            Log.e(tag, msg, tr)
        } catch (_: RuntimeException) {
            println("[$tag] ERROR: $msg ${tr?.message ?: ""}")
        }
    }

    companion object {
        private const val TAG = "SpendXLockManager"
        private const val DEFAULT_LOCK_FILENAME = "spendx_restore.lock"

        @Volatile
        private var instance: SpendXProcessLockLeaseManager? = null

        const val LOCK_CHANNEL = "spendx/process_lock"

        fun registerWithMessenger(binaryMessenger: BinaryMessenger, context: Context, engineId: String) {
            require(engineId.isNotBlank()) { "engineId must not be blank when registering SpendXProcessLock" }
            val lockManager = getInstance(context)
            val boundEngineId = engineId

            MethodChannel(binaryMessenger, LOCK_CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireForegroundLease" -> {
                        val targetEngineId = call.argument<String>("engineId") ?: boundEngineId
                        try {
                            val token = lockManager.acquireForegroundSharedLease(targetEngineId)
                            result.success(mapOf("status" to "ok", "leaseToken" to token, "engineId" to targetEngineId))
                        } catch (e: SecurityException) {
                            result.error("ADMISSION_CLOSED", e.message, null)
                        } catch (e: Exception) {
                            result.error("LEASE_ERROR", e.message, null)
                        }
                    }
                    "releaseForegroundLease" -> {
                        val targetEngineId = call.argument<String>("engineId") ?: boundEngineId
                        val leaseToken = call.argument<String>("leaseToken") ?: ""
                        try {
                            val ok = lockManager.releaseForegroundLease(targetEngineId, leaseToken)
                            result.success(mapOf("status" to (if (ok) "ok" else "error")))
                        } catch (e: Exception) {
                            result.error("RELEASE_ERROR", e.message, null)
                        }
                    }
                    "acquireOperationTicket" -> {
                        val targetEngineId = call.argument<String>("engineId") ?: boundEngineId
                        val tag = call.argument<String>("tag") ?: "generic_op"
                        try {
                            val ticket = lockManager.acquireDatabaseOperationTicket(targetEngineId, tag)
                            result.success(
                                mapOf(
                                    "status" to "ok",
                                    "ticketId" to ticket.ticketId,
                                    "tag" to ticket.operationTag,
                                    "engineId" to ticket.engineId
                                )
                            )
                        } catch (e: SecurityException) {
                            result.error("ADMISSION_CLOSED", e.message, null)
                        } catch (e: Exception) {
                            result.error("TICKET_ERROR", e.message, null)
                        }
                    }
                    "releaseOperationTicket" -> {
                        val ticketId = call.argument<String>("ticketId") ?: ""
                        val callerEngineId = call.argument<String>("engineId") ?: boundEngineId
                        try {
                            val ok = lockManager.releaseDatabaseOperationTicket(ticketId, callerEngineId)
                            result.success(mapOf("status" to (if (ok) "ok" else "stale")))
                        } catch (e: SecurityException) {
                            result.error("CROSS_ENGINE_RELEASE_PROHIBITED", e.message, null)
                        } catch (e: Exception) {
                            result.error("RELEASE_ERROR", e.message, null)
                        }
                    }
                    "beginExclusiveRestore" -> {
                        val drainTimeoutMs = (call.argument<Number>("drainTimeoutMs"))?.toLong() ?: 5000L
                        val contentionTimeoutMs = (call.argument<Number>("contentionTimeoutMs"))?.toLong() ?: 5000L
                        try {
                            val restoreToken = lockManager.beginExclusiveRestore(drainTimeoutMs, contentionTimeoutMs, boundEngineId)
                            result.success(mapOf("status" to "ok", "restoreToken" to restoreToken, "engineId" to boundEngineId))
                        } catch (e: TimeoutException) {
                            result.error("TIMEOUT", e.message, null)
                        } catch (e: IllegalStateException) {
                            result.error("ALREADY_ACTIVE", e.message, null)
                        } catch (e: Exception) {
                            result.error("RESTORE_ERROR", e.message, null)
                        }
                    }
                    "validateExclusiveRestoreToken" -> {
                        val restoreToken = call.argument<String>("restoreToken")
                        val explicitEngineId = call.argument<String>("engineId")
                        if (restoreToken.isNullOrBlank() || boundEngineId.isBlank()) {
                            result.success(mapOf("isValid" to false))
                            return@setMethodCallHandler
                        }
                        if (explicitEngineId != null && (explicitEngineId.isBlank() || explicitEngineId != boundEngineId)) {
                            // Cross-engine validation strictly rejected
                            result.success(mapOf("isValid" to false))
                            return@setMethodCallHandler
                        }
                        val isValid = lockManager.validateExclusiveRestoreToken(restoreToken, boundEngineId)
                        result.success(mapOf("isValid" to isValid))
                    }
                    "completeExclusiveRestore" -> {
                        val restoreToken = call.argument<String>("restoreToken") ?: ""
                        try {
                            val ok = lockManager.completeExclusiveRestore(restoreToken, boundEngineId)
                            result.success(mapOf("status" to (if (ok) "ok" else "error")))
                        } catch (e: SecurityException) {
                            result.error("CROSS_ENGINE_RESTORE_PROHIBITED", e.message, null)
                        } catch (e: Exception) {
                            result.error("COMPLETION_ERROR", e.message, null)
                        }
                    }
                    "abortExclusiveRestore" -> {
                        val restoreToken = call.argument<String>("restoreToken") ?: ""
                        try {
                            val ok = lockManager.abortExclusiveRestore(restoreToken, boundEngineId)
                            result.success(mapOf("status" to (if (ok) "ok" else "error")))
                        } catch (e: SecurityException) {
                            result.error("CROSS_ENGINE_RESTORE_PROHIBITED", e.message, null)
                        } catch (e: Exception) {
                            result.error("ABORT_ERROR", e.message, null)
                        }
                    }
                    "getLockStatus" -> {
                        try {
                            result.success(lockManager.getLockStatus())
                        } catch (e: Exception) {
                            result.error("STATUS_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        fun getInstance(context: Context): SpendXProcessLockLeaseManager {
            return instance ?: synchronized(this) {
                instance ?: run {
                    val file = File(context.filesDir, DEFAULT_LOCK_FILENAME)
                    SpendXProcessLockLeaseManager(file).also {
                        it.initialize()
                        instance = it
                    }
                }
            }
        }

        /**
         * Package-private or test factory for injecting custom lock files.
         */
        fun createForTesting(lockFile: File): SpendXProcessLockLeaseManager {
            return SpendXProcessLockLeaseManager(lockFile).apply {
                initialize()
            }
        }
    }

    private val lock = ReentrantLock()
    private val drainCondition: Condition = lock.newCondition()

    private var randomAccessFile: RandomAccessFile? = null
    private var fileChannel: FileChannel? = null

    private var osSharedLock: FileLock? = null
    private var osExclusiveLock: FileLock? = null

    @Volatile
    private var state: LockManagerState = LockManagerState.UNINITIALIZED

    @Volatile
    private var isRestorePending: Boolean = false

    private var foregroundLeaseToken: String? = null
    private var foregroundEngineId: String? = null

    private val activeTickets = ConcurrentHashMap<String, NativeTicket>()

    // Reader count includes foreground aggregate lease (1 if held) + all active background tickets
    private var activeReadersCount: Int = 0

    @Volatile
    private var exclusiveRestoreOwnerToken: String? = null

    @Volatile
    private var exclusiveRestoreOwnerEngineId: String? = null

    val currentState: LockManagerState
        get() = state

    val currentReadersCount: Int
        get() = lock.withLock { activeReadersCount }

    val sharedLeaseCount: Int
        get() = currentReadersCount

    val restorePending: Boolean
        get() = isRestorePending

    val exclusiveOwnerToken: String?
        get() = exclusiveRestoreOwnerToken

    val exclusiveOwnerEngineId: String?
        get() = exclusiveRestoreOwnerEngineId

    /**
     * Initializes the manager, opens the sentinel lock file, and acquires the process-shared OS lock.
     */
    fun initialize() {
        lock.withLock {
            if (state != LockManagerState.UNINITIALIZED) {
                return
            }

            try {
                val parent = lockFile.parentFile
                if (parent != null && !parent.exists()) {
                    parent.mkdirs()
                }
                val raf = RandomAccessFile(lockFile, "rw")
                val channel = raf.channel

                randomAccessFile = raf
                fileChannel = channel

                // Acquire process-shared OS lock
                val sharedLock = channel.tryLock(0, Long.MAX_VALUE, true)
                    ?: throw IllegalStateException("Could not acquire shared OS lock on ${lockFile.absolutePath}")

                osSharedLock = sharedLock
                state = LockManagerState.OPEN
                isRestorePending = false
                logI(TAG, "SpendXProcessLockLeaseManager initialized successfully in OPEN state")
            } catch (e: Exception) {
                state = LockManagerState.INDETERMINATE
                logE(TAG, "Failed to initialize SpendXProcessLockLeaseManager", e)
                throw e
            }
        }
    }

    /**
     * Acquires the aggregate process-shared lease for the foreground FlutterEngine.
     * Only one aggregate foreground lease can be held at a time.
     */
    fun acquireForegroundSharedLease(engineId: String): String {
        lock.withLock {
            checkNotIndeterminate()
            if (isRestorePending || state != LockManagerState.OPEN) {
                throw SecurityException("ADMISSION_CLOSED: Restore is pending or manager is not in OPEN state (state=$state)")
            }

            if (foregroundLeaseToken != null) {
                // If the same engine requests again, return existing token
                if (foregroundEngineId == engineId) {
                    return foregroundLeaseToken!!
                }
                throw IllegalStateException("Another foreground engine ($foregroundEngineId) already holds the aggregate lease")
            }

            val token = UUID.randomUUID().toString()
            foregroundLeaseToken = token
            foregroundEngineId = engineId
            activeReadersCount++
            logD(TAG, "Granted foreground shared lease to engine=$engineId, readers=$activeReadersCount")
            return token
        }
    }

    /**
     * Releases the aggregate process-shared lease for the foreground FlutterEngine.
     */
    fun releaseForegroundLease(engineId: String, leaseToken: String): Boolean {
        lock.withLock {
            if (foregroundLeaseToken == null || foregroundLeaseToken != leaseToken) {
                logW(TAG, "Rejecting invalid or stale foreground lease token: $leaseToken")
                return false
            }

            foregroundLeaseToken = null
            foregroundEngineId = null
            activeReadersCount = maxOf(0, activeReadersCount - 1)
            check(activeReadersCount >= 0) { "sharedLeaseCount underflow: $activeReadersCount" }
            logD(TAG, "Released foreground shared lease from engine=$engineId, readers=$activeReadersCount")

            if (isRestorePending && activeReadersCount == 0) {
                drainCondition.signalAll()
            }
            return true
        }
    }

    /**
     * Acquires an operation-scoped native ticket for background operations.
     * Fails fast if admission is closed for restore.
     */
    fun acquireDatabaseOperationTicket(engineId: String, operationTag: String): NativeTicket {
        lock.withLock {
            checkNotIndeterminate()
            if (isRestorePending || state != LockManagerState.OPEN) {
                throw SecurityException("ADMISSION_CLOSED: Cannot acquire operation ticket, restore is pending or state=$state")
            }

            val ticketId = UUID.randomUUID().toString()
            val ticket = NativeTicket(
                ticketId = ticketId,
                engineId = engineId,
                operationTag = operationTag,
                acquiredAtMs = System.currentTimeMillis()
            )

            activeTickets[ticketId] = ticket
            activeReadersCount++
            logD(TAG, "Granted native operation ticket $ticketId ($operationTag) for engine=$engineId, readers=$activeReadersCount")
            return ticket
        }
    }

    /**
     * Releases an operation-scoped native ticket.
     * - Rejects duplicate or stale releases (returns false without decrementing).
     * - Rejects cross-engine releases (throws SecurityException without decrementing).
     */
    fun releaseDatabaseOperationTicket(ticketId: String, callerEngineId: String? = null): Boolean {
        lock.withLock {
            val ticket = activeTickets[ticketId]
            if (ticket == null) {
                logW(TAG, "Rejecting stale or unknown native ticket release: $ticketId")
                return false
            }

            if (callerEngineId != null && ticket.engineId != callerEngineId) {
                logE(TAG, "Cross-engine ticket release rejected: ticket $ticketId belongs to ${ticket.engineId}, but caller is $callerEngineId")
                throw SecurityException("CROSS_ENGINE_RELEASE_PROHIBITED: Ticket $ticketId belongs to ${ticket.engineId}, but caller is $callerEngineId")
            }

            activeTickets.remove(ticketId)
            activeReadersCount = maxOf(0, activeReadersCount - 1)
            check(activeReadersCount >= 0) { "sharedLeaseCount underflow: $activeReadersCount" }
            logD(TAG, "Released native ticket $ticketId (${ticket.operationTag}) for engine=${ticket.engineId}, remaining readers=$activeReadersCount")

            if (isRestorePending && activeReadersCount == 0) {
                drainCondition.signalAll()
            }
            return true
        }
    }

    /**
     * Handles FlutterEngine detachment / destruction.
     * Reclaims any outstanding operation tickets and foreground lease associated
     * with the terminating engine, preventing restore deadlocks if the engine is destroyed
     * before Dart reaches finally blocks.
     *
     * If the detached engine held the exclusive restore lock, safely releases the exclusive OS lock,
     * invalidates the restore token, and attempts to re-acquire the shared OS lock. If lock release
     * or downgrade fails, the manager transitions to INDETERMINATE to prevent unsafe operations.
     */
    fun onEngineDetached(engineId: String): Int {
        lock.withLock {
            var reclaimedCount = 0
            val orphanedTickets = activeTickets.values.filter { it.engineId == engineId }
            for (ticket in orphanedTickets) {
                if (activeTickets.remove(ticket.ticketId) != null) {
                    activeReadersCount = maxOf(0, activeReadersCount - 1)
                    reclaimedCount++
                    logW(TAG, "Reclaimed orphaned ticket ${ticket.ticketId} (${ticket.operationTag}) on detachment of engine $engineId, remaining readers=$activeReadersCount")
                }
            }

            if (foregroundEngineId == engineId) {
                foregroundLeaseToken = null
                foregroundEngineId = null
                activeReadersCount = maxOf(0, activeReadersCount - 1)
                reclaimedCount++
                logW(TAG, "Released foreground lease on detachment of engine $engineId, remaining readers=$activeReadersCount")
            }

            // Engine detachment during active restore or pending restore
            if (exclusiveRestoreOwnerEngineId == engineId) {
                logW(TAG, "Exclusive restore owner engine $engineId detached! Safely releasing exclusive OS lock...")
                reclaimedCount++
                val channel = fileChannel
                try {
                    osExclusiveLock?.release()
                    osExclusiveLock = null
                    exclusiveRestoreOwnerToken = null
                    exclusiveRestoreOwnerEngineId = null

                    if (channel == null) {
                        state = LockManagerState.INDETERMINATE
                        logE(TAG, "FileChannel is null during detachment cleanup of restore engine $engineId")
                    } else {
                        val sharedLock = channel.tryLock(0, Long.MAX_VALUE, true)
                        if (sharedLock == null) {
                            state = LockManagerState.INDETERMINATE
                            logE(TAG, "Failed to reacquire shared OS lock during detachment cleanup of restore engine $engineId; entering INDETERMINATE state")
                        } else {
                            osSharedLock = sharedLock
                            isRestorePending = false
                            state = LockManagerState.OPEN
                            logI(TAG, "Successfully reclaimed exclusive lock on detachment of restore engine $engineId; returned to OPEN state")
                        }
                    }
                } catch (e: Exception) {
                    state = LockManagerState.INDETERMINATE
                    logE(TAG, "Critical failure during detachment cleanup of restore engine $engineId", e)
                }
            }

            check(activeReadersCount >= 0) { "sharedLeaseCount underflow: $activeReadersCount" }

            if (isRestorePending && activeReadersCount == 0) {
                drainCondition.signalAll()
            }
            return reclaimedCount
        }
    }

    /**
     * Executes the 6-step non-atomic shared-to-exclusive restore acquisition protocol.
     *
     * @param drainTimeoutMs Max time to wait for active readers to finish.
     * @param contentionTimeoutMs Max time to retry exclusive OS lock acquisition under external contention.
     * @param engineId The mandatory, non-empty Flutter engine ID owning this exclusive lease.
     * @return Exclusive restore owner token.
     */
    fun beginExclusiveRestore(
        drainTimeoutMs: Long = 5000L,
        contentionTimeoutMs: Long = 5000L,
        engineId: String = "engine_main"
    ): String {
        require(engineId.isNotBlank()) { "engineId cannot be blank" }

        // Step 1: Atomic Admission Closure
        lock.withLock {
            checkNotIndeterminate()
            if (isRestorePending || state == LockManagerState.EXCLUSIVE_PENDING || state == LockManagerState.EXCLUSIVE_HELD) {
                throw IllegalStateException("RESTORE_ALREADY_IN_PROGRESS: A restore operation is already active or pending")
            }

            isRestorePending = true
            exclusiveRestoreOwnerEngineId = engineId
            state = LockManagerState.EXCLUSIVE_PENDING
            logI(TAG, "Step 1: Admission closed for restore by engine $engineId. Draining $activeReadersCount active readers...")
        }

        // Step 2: Drain Active Readers
        lock.withLock {
            if (exclusiveRestoreOwnerEngineId != engineId) {
                throw IllegalStateException("Restore aborted: engine $engineId detached during preparation")
            }
            val drainDeadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(drainTimeoutMs)
            try {
                while (activeReadersCount > 0) {
                    val remainingNanos = drainDeadline - System.nanoTime()
                    if (remainingNanos <= 0L) {
                        // Rollback Step 2
                        isRestorePending = false
                        exclusiveRestoreOwnerEngineId = null
                        state = LockManagerState.OPEN
                        logE(TAG, "Step 2 failed: Drain timed out with $activeReadersCount active readers remaining")
                        throw TimeoutException("DRAIN_TIMEOUT: Readers failed to drain within ${drainTimeoutMs}ms (remaining=$activeReadersCount)")
                    }
                    drainCondition.await(remainingNanos, TimeUnit.NANOSECONDS)
                }
            } catch (e: InterruptedException) {
                isRestorePending = false
                exclusiveRestoreOwnerEngineId = null
                state = LockManagerState.OPEN
                Thread.currentThread().interrupt()
                logE(TAG, "Step 2 interrupted during reader drain", e)
                throw e
            }
            logI(TAG, "Step 2: Active readers drained completely (activeReadersCount=0)")
        }

        // Step 3: Release Shared OS Lock
        lock.withLock {
            if (exclusiveRestoreOwnerEngineId != engineId) {
                throw IllegalStateException("Restore aborted: engine $engineId detached during reader drain")
            }
            try {
                osSharedLock?.release()
                osSharedLock = null
                logI(TAG, "Step 3: Released shared OS lock. Entering upgrade window.")
            } catch (e: Exception) {
                exclusiveRestoreOwnerEngineId = null
                state = LockManagerState.INDETERMINATE
                logE(TAG, "Step 3 critical failure: Exception while releasing shared OS lock", e)
                throw e
            }
        }

        // Step 4 & 5: Attempt Exclusive OS Lock Acquisition with Bounded Exponential Backoff
        val channel = fileChannel ?: throw IllegalStateException("FileChannel is null")
        val retryDeadline = System.currentTimeMillis() + contentionTimeoutMs
        var attempt = 0
        var exclusiveLock: FileLock? = null

        while (System.currentTimeMillis() < retryDeadline) {
            try {
                exclusiveLock = channel.tryLock(0, Long.MAX_VALUE, false)
                if (exclusiveLock != null) {
                    break
                }
            } catch (e: OverlappingFileLockException) {
                lock.withLock {
                    exclusiveRestoreOwnerEngineId = null
                    state = LockManagerState.INDETERMINATE
                }
                logE(TAG, "OverlappingFileLockException during exclusive lock attempt", e)
                throw e
            } catch (e: Exception) {
                logW(TAG, "Exception during tryLock: ${e.message}")
            }

            // Exponential backoff with uniform random jitter: 5ms, 10ms, 20ms... up to 100ms
            attempt++
            val baseSleep = minOf(100L, 5L * (1L shl minOf(attempt, 5)))
            val jitter = Random.nextLong(0, baseSleep / 2 + 1)
            val sleepMs = baseSleep + jitter

            try {
                Thread.sleep(minOf(sleepMs, maxOf(1L, retryDeadline - System.currentTimeMillis())))
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            }
        }

        // Step 6: Rollback on Timeout or Finalize Exclusive Lock
        lock.withLock {
            if (exclusiveRestoreOwnerEngineId != engineId) {
                try {
                    exclusiveLock?.release()
                } catch (_: Exception) {}
                throw IllegalStateException("Restore aborted: engine $engineId detached during exclusive lock acquisition")
            }

            if (exclusiveLock == null) {
                logW(TAG, "Step 5 timeout: Could not acquire exclusive OS lock within ${contentionTimeoutMs}ms. Rolling back...")
                // Reacquire shared OS lock
                try {
                    val sharedLock = channel.tryLock(0, Long.MAX_VALUE, true)
                    if (sharedLock == null) {
                        exclusiveRestoreOwnerEngineId = null
                        state = LockManagerState.INDETERMINATE
                        throw IllegalStateException("Failed to reacquire shared OS lock during timeout rollback (tryLock returned null)")
                    }
                    osSharedLock = sharedLock
                } catch (e: Exception) {
                    exclusiveRestoreOwnerEngineId = null
                    state = LockManagerState.INDETERMINATE
                    logE(TAG, "Critical failure during timeout rollback: could not reacquire shared OS lock", e)
                    throw e
                }
                exclusiveRestoreOwnerEngineId = null
                isRestorePending = false
                state = LockManagerState.OPEN
                throw TimeoutException("EXCLUSIVE_LOCK_TIMEOUT: Contention timeout after ${contentionTimeoutMs}ms")
            }

            osExclusiveLock = exclusiveLock
            val token = UUID.randomUUID().toString()
            exclusiveRestoreOwnerToken = token
            state = LockManagerState.EXCLUSIVE_HELD
            logI(TAG, "Step 4/5 success: Acquired exclusive OS lock. Restore token granted: $token to engine: $engineId")
            return token
        }
    }

    /**
     * Validates whether the given restore token is currently held and bound to the specified engine.
     * Returns true ONLY if state is EXCLUSIVE_HELD, the token matches, and the engineId matches.
     */
    fun validateExclusiveRestoreToken(restoreToken: String, engineId: String): Boolean {
        lock.withLock {
            if (state != LockManagerState.EXCLUSIVE_HELD) return false
            if (restoreToken.isBlank() || engineId.isBlank()) return false
            if (exclusiveRestoreOwnerToken == null || exclusiveRestoreOwnerToken != restoreToken) return false
            if (exclusiveRestoreOwnerEngineId == null || exclusiveRestoreOwnerEngineId != engineId) return false
            return true
        }
    }

    /**
     * Completes or aborts the exclusive restore operation, releasing the exclusive lock
     * and restoring the process-shared OS lock. Requires matching engine ownership.
     */
    fun completeExclusiveRestore(restoreToken: String, engineId: String? = null): Boolean {
        return finishExclusiveRestore(restoreToken, isCompleted = true, callerEngineId = engineId)
    }

    fun abortExclusiveRestore(restoreToken: String, engineId: String? = null): Boolean {
        return finishExclusiveRestore(restoreToken, isCompleted = false, callerEngineId = engineId)
    }

    private fun finishExclusiveRestore(restoreToken: String, isCompleted: Boolean, callerEngineId: String? = null): Boolean {
        lock.withLock {
            if (state != LockManagerState.EXCLUSIVE_HELD) {
                throw IllegalStateException("No exclusive restore is currently held (state=$state)")
            }
            if (exclusiveRestoreOwnerToken == null || exclusiveRestoreOwnerToken != restoreToken) {
                throw SecurityException("INVALID_RESTORE_TOKEN: Provided token does not match active restore owner")
            }
            if (callerEngineId != null && exclusiveRestoreOwnerEngineId != null && exclusiveRestoreOwnerEngineId != callerEngineId) {
                throw SecurityException("CROSS_ENGINE_RESTORE_PROHIBITED: Restore belongs to $exclusiveRestoreOwnerEngineId but caller is $callerEngineId")
            }

            val channel = fileChannel ?: throw IllegalStateException("FileChannel is null")

            try {
                osExclusiveLock?.release()
                osExclusiveLock = null

                // Re-acquire shared OS lock
                osSharedLock = channel.tryLock(0, Long.MAX_VALUE, true)
                    ?: run {
                        state = LockManagerState.INDETERMINATE
                        throw IllegalStateException("Failed to reacquire shared OS lock upon completing restore")
                    }

                exclusiveRestoreOwnerToken = null
                exclusiveRestoreOwnerEngineId = null
                isRestorePending = false
                state = LockManagerState.OPEN
                logI(TAG, "Restore operation ${if (isCompleted) "completed" else "aborted"}. Returned to OPEN state.")
                return true
            } catch (e: Exception) {
                state = LockManagerState.INDETERMINATE
                logE(TAG, "Critical error during restore completion downgrade", e)
                throw e
            }
        }
    }

    /**
     * Returns a snapshot of internal lock status for diagnostics and tests.
     */
    fun getLockStatus(): Map<String, Any?> {
        lock.withLock {
            return mapOf(
                "state" to state.name,
                "activeReadersCount" to activeReadersCount,
                "isRestorePending" to isRestorePending,
                "hasForegroundLease" to (foregroundLeaseToken != null),
                "foregroundEngineId" to foregroundEngineId,
                "activeTicketsCount" to activeTickets.size,
                "exclusiveHeld" to (state == LockManagerState.EXCLUSIVE_HELD),
                "hasExclusiveToken" to (exclusiveRestoreOwnerToken != null),
                "exclusiveRestoreOwnerEngineId" to exclusiveRestoreOwnerEngineId
            )
        }
    }

    fun getActiveTicketsForEngine(engineId: String): List<NativeTicket> {
        return activeTickets.values.filter { it.engineId == engineId }
    }

    private fun checkNotIndeterminate() {
        if (state == LockManagerState.INDETERMINATE) {
            throw IllegalStateException("INDETERMINATE_LOCK_STATE: Manager entered indeterminate state due to a previous unrecoverable error")
        }
    }

    /**
     * Testing teardown: closes descriptor.
     */
    fun closeForTesting() {
        lock.withLock {
            try {
                osSharedLock?.release()
            } catch (_: Exception) {}
            try {
                osExclusiveLock?.release()
            } catch (_: Exception) {}
            try {
                fileChannel?.close()
            } catch (_: Exception) {}
            try {
                randomAccessFile?.close()
            } catch (_: Exception) {}
            state = LockManagerState.UNINITIALIZED
        }
    }
}

class TimeoutException(message: String) : Exception(message)
