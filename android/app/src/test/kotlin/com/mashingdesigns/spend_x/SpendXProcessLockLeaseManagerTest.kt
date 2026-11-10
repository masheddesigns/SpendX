package com.mashingdesigns.spend_x

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.OverlappingFileLockException
import java.nio.file.Files
import java.util.UUID
import kotlin.concurrent.thread

class SpendXProcessLockLeaseManagerTest {

    private lateinit var tempDir: File
    private lateinit var lockFile: File
    private lateinit var manager: SpendXProcessLockLeaseManager

    @Before
    fun setUp() {
        tempDir = Files.createTempDirectory("spendx_lock_test").toFile()
        lockFile = File(tempDir, "test_spendx_restore.lock")
        manager = SpendXProcessLockLeaseManager.createForTesting(lockFile)
    }

    @After
    fun tearDown() {
        manager.closeForTesting()
        lockFile.delete()
        tempDir.deleteRecursively()
    }

    @Test
    fun testProcessLevelOwnership() {
        assertEquals(LockManagerState.OPEN, manager.currentState)
        assertEquals(0, manager.currentReadersCount)
        assertFalse(manager.restorePending)
        assertNull(manager.exclusiveOwnerToken)

        // Verify that another channel attempting exclusive lock in the same JVM encounters OverlappingFileLockException
        val otherRaf = RandomAccessFile(lockFile, "rw")
        val otherChannel = otherRaf.channel
        try {
            otherChannel.tryLock(0, Long.MAX_VALUE, false)
            fail("Expected OverlappingFileLockException because manager holds a lock on this file")
        } catch (_: OverlappingFileLockException) {
            // Expected: Java NIO FileLockTable enforces single-lock owner within the same JVM process
        } finally {
            otherChannel.close()
            otherRaf.close()
        }
    }

    @Test
    fun testSharedLeaseReferenceCounting() {
        val fgToken = manager.acquireForegroundSharedLease("engine_main")
        assertNotNull(fgToken)
        assertEquals(1, manager.currentReadersCount)

        val ticket1 = manager.acquireDatabaseOperationTicket("engine_bg_1", "sms_sync")
        val ticket2 = manager.acquireDatabaseOperationTicket("engine_bg_2", "notification_choice")
        assertEquals(3, manager.currentReadersCount)

        // Release ticket 1
        val released1 = manager.releaseDatabaseOperationTicket(ticket1.ticketId)
        assertTrue(released1)
        assertEquals(2, manager.currentReadersCount)

        // Release foreground lease
        val releasedFg = manager.releaseForegroundLease("engine_main", fgToken)
        assertTrue(releasedFg)
        assertEquals(1, manager.currentReadersCount)

        // Release ticket 2
        val released2 = manager.releaseDatabaseOperationTicket(ticket2.ticketId)
        assertTrue(released2)
        assertEquals(0, manager.currentReadersCount)
    }

    @Test
    fun testMultipleFlutterEngines() {
        val token1 = manager.acquireForegroundSharedLease("engine_1")
        assertNotNull(token1)

        // Same engine returns same token (idempotent)
        val token1Again = manager.acquireForegroundSharedLease("engine_1")
        assertEquals(token1, token1Again)
        assertEquals(1, manager.currentReadersCount)

        // Different engine attempting foreground lease is rejected
        try {
            manager.acquireForegroundSharedLease("engine_2")
            fail("Expected IllegalStateException when another engine requests foreground lease")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("already holds"))
        }

        // But secondary engine CAN acquire operation tickets
        val ticket = manager.acquireDatabaseOperationTicket("engine_2", "bg_task")
        assertEquals(2, manager.currentReadersCount)
        manager.releaseDatabaseOperationTicket(ticket.ticketId)
        manager.releaseForegroundLease("engine_1", token1)
    }

    @Test
    fun testDuplicateTicketRelease() {
        val ticket = manager.acquireDatabaseOperationTicket("engine_bg", "test_op")
        assertEquals(1, manager.currentReadersCount)

        val firstRelease = manager.releaseDatabaseOperationTicket(ticket.ticketId)
        assertTrue(firstRelease)
        assertEquals(0, manager.currentReadersCount)

        val secondRelease = manager.releaseDatabaseOperationTicket(ticket.ticketId)
        assertFalse("Duplicate release must return false", secondRelease)
        assertEquals(0, manager.currentReadersCount)
    }

    @Test
    fun testStaleTicketRejection() {
        val fakeTicketId = UUID.randomUUID().toString()
        val result = manager.releaseDatabaseOperationTicket(fakeTicketId)
        assertFalse("Stale or unknown ticket must be rejected", result)
    }

    @Test
    fun testBackgroundFailFastBehavior() {
        // Start restore in a background thread or trigger admission closed
        val restoreThread = thread(start = true) {
            manager.beginExclusiveRestore(drainTimeoutMs = 500, contentionTimeoutMs = 500)
        }

        // Wait briefly for restore to acquire exclusive lock
        restoreThread.join()
        assertEquals(LockManagerState.EXCLUSIVE_HELD, manager.currentState)

        // Now background operation must fail-fast immediately
        try {
            manager.acquireDatabaseOperationTicket("engine_bg", "fail_fast_check")
            fail("Expected SecurityException when admission is closed")
        } catch (e: SecurityException) {
            assertTrue(e.message!!.contains("ADMISSION_CLOSED"))
        }

        val token = manager.exclusiveOwnerToken
        assertNotNull(token)
        manager.completeExclusiveRestore(token!!)
        assertEquals(LockManagerState.OPEN, manager.currentState)
    }

    @Test
    fun testSimultaneousRestoreRejection() {
        val restoreToken = manager.beginExclusiveRestore(drainTimeoutMs = 500, contentionTimeoutMs = 500)
        assertNotNull(restoreToken)
        assertEquals(LockManagerState.EXCLUSIVE_HELD, manager.currentState)

        // Second restore attempt must be rejected immediately
        try {
            manager.beginExclusiveRestore(drainTimeoutMs = 500, contentionTimeoutMs = 500)
            fail("Expected IllegalStateException for simultaneous restore")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("RESTORE_ALREADY_IN_PROGRESS"))
        }

        manager.completeExclusiveRestore(restoreToken)
        assertEquals(LockManagerState.OPEN, manager.currentState)
    }

    @Test
    fun testExclusiveAcquisitionAndDrain() {
        val ticket = manager.acquireDatabaseOperationTicket("engine_bg", "long_op")
        assertEquals(1, manager.currentReadersCount)

        // Launch delayed release in background thread
        thread(start = true) {
            Thread.sleep(150)
            manager.releaseDatabaseOperationTicket(ticket.ticketId)
        }

        // Restore waits for drain and succeeds
        val startMs = System.currentTimeMillis()
        val token = manager.beginExclusiveRestore(drainTimeoutMs = 1000, contentionTimeoutMs = 500)
        val elapsedMs = System.currentTimeMillis() - startMs

        assertTrue("Restore drain should have waited for operation to finish", elapsedMs >= 100)
        assertEquals(LockManagerState.EXCLUSIVE_HELD, manager.currentState)
        assertEquals(0, manager.currentReadersCount)

        manager.completeExclusiveRestore(token)
        assertEquals(LockManagerState.OPEN, manager.currentState)
    }

    @Test
    fun testLockAcquisitionTimeout() {
        // Hold a ticket and do not release it
        val ticket = manager.acquireDatabaseOperationTicket("engine_hung", "hung_task")
        assertEquals(1, manager.currentReadersCount)

        // Restore should time out after drainTimeoutMs (300ms)
        try {
            manager.beginExclusiveRestore(drainTimeoutMs = 300, contentionTimeoutMs = 300)
            fail("Expected TimeoutException when readers fail to drain")
        } catch (e: TimeoutException) {
            assertTrue(e.message!!.contains("DRAIN_TIMEOUT"))
        }

        // Safe Rollback Invariant: state must be returned to OPEN, DB untouched
        assertEquals(LockManagerState.OPEN, manager.currentState)
        assertFalse(manager.restorePending)
        assertNull(manager.exclusiveOwnerToken)

        // Clean up ticket
        manager.releaseDatabaseOperationTicket(ticket.ticketId)
    }

    @Test
    fun testSharedToExclusiveContentionAndRollback() {
        // Spawn external OS process that acquires POSIX F_RDLCK on the lockfile
        val process = ProcessBuilder(
            "/usr/bin/python3",
            "-c",
            "import fcntl, time; f = open('${lockFile.absolutePath}', 'r+'); fcntl.lockf(f, fcntl.LOCK_SH); print('LOCKED', flush=True); time.sleep(3)"
        ).start()

        val reader = process.inputStream.bufferedReader()
        val line = reader.readLine()
        assertEquals("LOCKED", line)

        try {
            // Manager attempts exclusive restore: readers = 0, but exclusive OS lock fails due to external shared lock
            try {
                manager.beginExclusiveRestore(drainTimeoutMs = 100, contentionTimeoutMs = 300)
                fail("Expected TimeoutException due to external lock contention")
            } catch (e: TimeoutException) {
                assertTrue(e.message!!.contains("EXCLUSIVE_LOCK_TIMEOUT"))
            }

            // Invariant: rollback returns manager to OPEN with shared OS lock restored
            assertEquals(LockManagerState.OPEN, manager.currentState)
            assertFalse(manager.restorePending)
            assertNull(manager.exclusiveOwnerToken)
        } finally {
            process.destroyForcibly()
        }
    }

    @Test
    fun testCancellationAndCleanup() {
        val restoreToken = manager.beginExclusiveRestore(drainTimeoutMs = 500, contentionTimeoutMs = 500)
        assertEquals(LockManagerState.EXCLUSIVE_HELD, manager.currentState)

        // Abort restore
        val aborted = manager.abortExclusiveRestore(restoreToken)
        assertTrue(aborted)
        assertEquals(LockManagerState.OPEN, manager.currentState)
        assertFalse(manager.restorePending)
        assertNull(manager.exclusiveOwnerToken)
    }

    @Test
    fun testCrossEngineTicketReleaseProhibited() {
        val ticketA = manager.acquireDatabaseOperationTicket("engine_A", "task_A")
        assertEquals(1, manager.currentReadersCount)

        // Engine B attempts to release Engine A's ticket -> must be rejected
        try {
            manager.releaseDatabaseOperationTicket(ticketA.ticketId, callerEngineId = "engine_B")
            fail("Expected SecurityException when engine_B attempts to release engine_A's ticket")
        } catch (e: SecurityException) {
            assertTrue(e.message!!.contains("CROSS_ENGINE_RELEASE_PROHIBITED"))
        }

        // Reader count must remain 1 (no corruption)
        assertEquals(1, manager.currentReadersCount)

        // Legitimate caller engine_A releases successfully
        val ok = manager.releaseDatabaseOperationTicket(ticketA.ticketId, callerEngineId = "engine_A")
        assertTrue(ok)
        assertEquals(0, manager.currentReadersCount)
    }

    @Test
    fun testEngineTeardownReclaimsOutstandingTickets() {
        val ticket1 = manager.acquireDatabaseOperationTicket("engine_bg_1", "task_1")
        val ticket2 = manager.acquireDatabaseOperationTicket("engine_bg_1", "task_2")
        val ticketOther = manager.acquireDatabaseOperationTicket("engine_other", "task_other")
        assertEquals(3, manager.currentReadersCount)

        // Engine bg_1 detaches/terminates
        val reclaimedCount = manager.onEngineDetached("engine_bg_1")
        assertEquals(2, reclaimedCount)

        // Active readers must now reflect only engine_other
        assertEquals(1, manager.currentReadersCount)
        assertEquals(1, manager.getActiveTicketsForEngine("engine_other").size)
        assertEquals(0, manager.getActiveTicketsForEngine("engine_bg_1").size)

        // Stale release from engine_bg_1 after teardown returns false and does not underflow
        val lateRelease = manager.releaseDatabaseOperationTicket(ticket1.ticketId, "engine_bg_1")
        assertFalse("Late release after teardown must be rejected as stale", lateRelease)
        assertEquals(1, manager.currentReadersCount)

        // Clean up remaining ticket
        manager.releaseDatabaseOperationTicket(ticketOther.ticketId, "engine_other")
        assertEquals(0, manager.currentReadersCount)
    }

    @Test
    fun testEngineTeardownUnblocksWaitingRestore() {
        // Background engine acquires ticket
        val ticket = manager.acquireDatabaseOperationTicket("engine_bg_unblock", "long_op")
        assertEquals(1, manager.currentReadersCount)

        var restoreCompleted = false
        var restoreToken: String? = null

        // Start restore in separate thread - it will block waiting for readers to drain
        val restoreThread = thread(start = true) {
            restoreToken = manager.beginExclusiveRestore(drainTimeoutMs = 2000, contentionTimeoutMs = 500)
            restoreCompleted = true
        }

        // Wait briefly to ensure restore is in drain loop
        Thread.sleep(100)
        assertFalse("Restore must remain blocked while background ticket is active", restoreCompleted)
        assertEquals(LockManagerState.EXCLUSIVE_PENDING, manager.currentState)

        // Now simulate background engine detachment (teardown)
        val reclaimed = manager.onEngineDetached("engine_bg_unblock")
        assertEquals(1, reclaimed)

        // Wait for restore thread to complete
        restoreThread.join(2000)
        assertTrue("Restore must unblock and acquire exclusive lock upon engine teardown", restoreCompleted)
        assertEquals(LockManagerState.EXCLUSIVE_HELD, manager.currentState)
        assertNotNull(restoreToken)

        // Abort restore to return manager to OPEN
        manager.abortExclusiveRestore(restoreToken!!)
        assertEquals(LockManagerState.OPEN, manager.currentState)
    }

    @Test
    fun testConcurrentEnginesTeardownIsolation() {
        val fgToken = manager.acquireForegroundSharedLease("engine_fg")
        val bgTicket = manager.acquireDatabaseOperationTicket("engine_bg", "bg_op")
        assertEquals(2, manager.currentReadersCount)

        // Detach bg engine -> fg lease remains intact
        manager.onEngineDetached("engine_bg")
        assertEquals(1, manager.currentReadersCount)
        assertEquals(LockManagerState.OPEN, manager.currentState)

        // Restore still cannot acquire until fg lease is released
        try {
            manager.beginExclusiveRestore(drainTimeoutMs = 100, contentionTimeoutMs = 100)
            fail("Expected TimeoutException because foreground lease is still held")
        } catch (e: TimeoutException) {
            assertTrue(e.message!!.contains("DRAIN_TIMEOUT"))
        }

        // Release fg lease
        manager.releaseForegroundLease("engine_fg", fgToken)
        assertEquals(0, manager.currentReadersCount)
    }

    @Test
    fun testRepeatedEngineDetach() {
        val engineId = "engine_repeated_detach"
        val fg = manager.acquireForegroundSharedLease(engineId)
        val t1 = manager.acquireDatabaseOperationTicket(engineId, "t1")
        val t2 = manager.acquireDatabaseOperationTicket(engineId, "t2")
        val t3 = manager.acquireDatabaseOperationTicket(engineId, "t3")
        assertEquals(4, manager.sharedLeaseCount)

        // First detach: reclaims 3 tickets + 1 foreground lease = 4
        val reclaimedFirst = manager.onEngineDetached(engineId)
        assertEquals(4, reclaimedFirst)
        assertEquals(0, manager.sharedLeaseCount)

        // Second detach: must be idempotent and reclaim 0 without underflow
        val reclaimedSecond = manager.onEngineDetached(engineId)
        assertEquals(0, reclaimedSecond)
        assertEquals(0, manager.sharedLeaseCount)

        // Third detach: must be idempotent
        val reclaimedThird = manager.onEngineDetached(engineId)
        assertEquals(0, reclaimedThird)
        assertEquals(0, manager.sharedLeaseCount)
    }

    @Test
    fun testRepeatedTicketReleaseAfterDetach() {
        val engineId = "engine_post_detach_release"
        val ticket = manager.acquireDatabaseOperationTicket(engineId, "single_op")
        assertEquals(1, manager.sharedLeaseCount)

        val reclaimed = manager.onEngineDetached(engineId)
        assertEquals(1, reclaimed)
        assertEquals(0, manager.sharedLeaseCount)

        // Subsequent release calls for the detached ticket must return false and not decrement
        assertFalse(manager.releaseDatabaseOperationTicket(ticket.ticketId, engineId))
        assertEquals(0, manager.sharedLeaseCount)

        assertFalse(manager.releaseDatabaseOperationTicket(ticket.ticketId, engineId))
        assertEquals(0, manager.sharedLeaseCount)

        assertFalse(manager.releaseDatabaseOperationTicket(ticket.ticketId, engineId))
        assertEquals(0, manager.sharedLeaseCount)
    }

    @Test
    fun testMultipleTicketsOwnedByOneEngine() {
        val engineId = "engine_multi_ticket"
        val tickets = (1..5).map { manager.acquireDatabaseOperationTicket(engineId, "tag_$it") }
        assertEquals(5, manager.sharedLeaseCount)

        val reclaimed = manager.onEngineDetached(engineId)
        assertEquals(5, reclaimed)
        assertEquals(0, manager.sharedLeaseCount)

        for (t in tickets) {
            assertFalse(manager.releaseDatabaseOperationTicket(t.ticketId, engineId))
        }
        assertEquals(0, manager.sharedLeaseCount)
    }

    @Test
    fun testMultipleEnginesDetachingWhileAnotherRetainsActiveTicket() {
        val e1 = "engine_1"
        val e2 = "engine_2"
        val e3 = "engine_3"
        val e4 = "engine_4"

        manager.acquireDatabaseOperationTicket(e1, "op1")
        manager.acquireDatabaseOperationTicket(e1, "op2")

        manager.acquireDatabaseOperationTicket(e2, "op3")
        manager.acquireDatabaseOperationTicket(e2, "op4")
        manager.acquireDatabaseOperationTicket(e2, "op5")

        val e3Ticket = manager.acquireDatabaseOperationTicket(e3, "retained_op")

        manager.acquireDatabaseOperationTicket(e4, "op7")

        assertEquals(7, manager.sharedLeaseCount)

        assertEquals(2, manager.onEngineDetached(e1))
        assertEquals(5, manager.sharedLeaseCount)

        assertEquals(3, manager.onEngineDetached(e2))
        assertEquals(2, manager.sharedLeaseCount)

        assertEquals(1, manager.onEngineDetached(e4))
        assertEquals(1, manager.sharedLeaseCount)

        // Engine 3's ticket remains active and valid
        assertTrue(manager.releaseDatabaseOperationTicket(e3Ticket.ticketId, e3))
        assertEquals(0, manager.sharedLeaseCount)
    }

    @Test
    fun testEngineDetachRacingWithTicketRelease() {
        for (round in 1..20) {
            val engineId = "engine_race_$round"
            val ticket = manager.acquireDatabaseOperationTicket(engineId, "race_op_$round")
            assertEquals(1, manager.sharedLeaseCount)

            var detachReclaimed = -1
            var releaseSuccess = false

            val tDetach = thread(start = true) {
                detachReclaimed = manager.onEngineDetached(engineId)
            }
            val tRelease = thread(start = true) {
                releaseSuccess = manager.releaseDatabaseOperationTicket(ticket.ticketId, engineId)
            }

            tDetach.join()
            tRelease.join()

            // Exactly one of them must have reclaimed/released the ticket
            val totalReclaimed = (if (detachReclaimed > 0) 1 else 0) + (if (releaseSuccess) 1 else 0)
            assertEquals("Ticket for round $round must be reclaimed exactly once across race", 1, totalReclaimed)
            assertEquals("sharedLeaseCount must be 0 after race", 0, manager.sharedLeaseCount)
        }
    }

    @Test
    fun testRestoreWaitingDuringConcurrentDetachAndRelease() {
        val eA = "engine_restore_race_A"
        val eB = "engine_restore_race_B"

        manager.acquireDatabaseOperationTicket(eA, "opA1")
        manager.acquireDatabaseOperationTicket(eA, "opA2")
        val tB1 = manager.acquireDatabaseOperationTicket(eB, "opB1")
        val tB2 = manager.acquireDatabaseOperationTicket(eB, "opB2")

        assertEquals(4, manager.sharedLeaseCount)

        var restoreToken: String? = null
        var restoreCompleted = false

        val restoreThread = thread(start = true) {
            restoreToken = manager.beginExclusiveRestore(drainTimeoutMs = 3000, contentionTimeoutMs = 500)
            restoreCompleted = true
        }

        Thread.sleep(100)
        assertFalse("Restore must wait while 4 tickets are held", restoreCompleted)
        assertEquals(LockManagerState.EXCLUSIVE_PENDING, manager.currentState)

        // Concurrently detach eA and release eB's tickets
        val threadA = thread(start = true) {
            manager.onEngineDetached(eA)
        }
        val threadB = thread(start = true) {
            manager.releaseDatabaseOperationTicket(tB1.ticketId, eB)
            manager.releaseDatabaseOperationTicket(tB2.ticketId, eB)
        }

        threadA.join()
        threadB.join()
        restoreThread.join(3000)

        assertTrue("Restore must unblock when all tickets are released/detached", restoreCompleted)
        assertEquals(LockManagerState.EXCLUSIVE_HELD, manager.currentState)
        assertEquals(0, manager.sharedLeaseCount)
        assertNotNull(restoreToken)

        manager.completeExclusiveRestore(restoreToken!!)
        assertEquals(LockManagerState.OPEN, manager.currentState)
    }

    @Test
    fun testGenuineCrossProcessFileLockContention() {
        val javaHome = System.getProperty("java.home")
        val javaBin = File(javaHome, "bin/java").absolutePath
        val classPath = System.getProperty("java.class.path")

        // 1. External OS Process attempts exclusive lock while manager holds shared OS lock in OPEN state
        val processA = ProcessBuilder(
            javaBin,
            "-cp",
            classPath,
            "com.mashingdesigns.spend_x.ExternalProcessLockHolder",
            lockFile.absolutePath,
            "500",
            "exclusive"
        ).redirectErrorStream(true).start()

        val outputA = processA.inputStream.bufferedReader().readText().trim()
        processA.waitFor()

        // Because manager holds shared OS lock, external process CANNOT acquire exclusive lock
        assertEquals("External OS process must be blocked from exclusive lock while manager holds shared lock", "LOCK_FAILED", outputA)

        // 2. Close manager so lock file is free
        manager.closeForTesting()

        // 3. Launch external OS process to hold exclusive lock for 3000ms
        val processB = ProcessBuilder(
            javaBin,
            "-cp",
            classPath,
            "com.mashingdesigns.spend_x.ExternalProcessLockHolder",
            lockFile.absolutePath,
            "3000",
            "exclusive"
        ).redirectErrorStream(true).start()

        val readerB = processB.inputStream.bufferedReader()
        val firstLineB = readerB.readLine()
        assertEquals("LOCK_ACQUIRED", firstLineB)

        // 4. While external process holds exclusive OS lock, attempting to initialize manager must fail
        try {
            val contestedManager = SpendXProcessLockLeaseManager.createForTesting(lockFile)
            contestedManager.closeForTesting()
            fail("Manager must not initialize when external OS process holds exclusive lock")
        } catch (e: Exception) {
            assertTrue("Expected lock acquisition failure, got: ${e.message}",
                e.message?.contains("Failed to acquire initial shared lock") == true ||
                e.message?.contains("tryLock returned null") == true ||
                e is IllegalStateException
            )
        }

        // 5. Force kill the external OS process (simulating SIGKILL)
        processB.destroyForcibly()
        processB.waitFor()

        // 6. Kernel immediately releases OS file lock upon process death: manager re-creation must now succeed
        val recoveredManager = SpendXProcessLockLeaseManager.createForTesting(lockFile)
        assertEquals(LockManagerState.OPEN, recoveredManager.currentState)
        recoveredManager.closeForTesting()
    }

    @Test
    fun testExclusiveRestoreTokenEngineBindingAndValidation() {
        val engineMain = "engine_main_1"
        val engineOther = "engine_other_2"

        val token = manager.beginExclusiveRestore(drainTimeoutMs = 1000, contentionTimeoutMs = 1000, engineId = engineMain)
        assertNotNull(token)
        assertEquals(LockManagerState.EXCLUSIVE_HELD, manager.currentState)
        assertEquals(engineMain, manager.exclusiveOwnerEngineId)

        // 1. Correct token + correct engine validates true
        assertTrue(manager.validateExclusiveRestoreToken(token, engineMain))

        // 2. Wrong token + correct engine validates false
        assertFalse(manager.validateExclusiveRestoreToken("invalid_token", engineMain))

        // 3. Correct token + wrong engine validates false
        assertFalse(manager.validateExclusiveRestoreToken(token, engineOther))

        // 4. Blank token or blank engine validates false
        assertFalse(manager.validateExclusiveRestoreToken("", engineMain))
        assertFalse(manager.validateExclusiveRestoreToken(token, ""))

        // 5. Cross-engine completion rejected
        try {
            manager.completeExclusiveRestore(token, engineId = engineOther)
            fail("Expected SecurityException when completing restore from different engine")
        } catch (_: SecurityException) {
            // Expected
        }
        assertTrue(manager.validateExclusiveRestoreToken(token, engineMain))

        // 6. Cross-engine abort rejected
        try {
            manager.abortExclusiveRestore(token, engineId = engineOther)
            fail("Expected SecurityException when aborting restore from different engine")
        } catch (_: SecurityException) {
            // Expected
        }
        assertTrue(manager.validateExclusiveRestoreToken(token, engineMain))

        // 7. Legitimate completion succeeds and invalidates token
        val completed = manager.completeExclusiveRestore(token, engineId = engineMain)
        assertTrue(completed)
        assertEquals(LockManagerState.OPEN, manager.currentState)
        assertNull(manager.exclusiveOwnerToken)
        assertNull(manager.exclusiveOwnerEngineId)

        // 8. Subsequent validation of old token returns false
        assertFalse(manager.validateExclusiveRestoreToken(token, engineMain))
    }

    @Test
    fun testMissingEngineIdentityAndCrossEngineValidation() {
        val ownerEngine = "engine_authorized_owner"
        val foreignEngine = "engine_foreign_intruder"

        // Attempting to begin restore with blank engine ID must fail closed
        try {
            manager.beginExclusiveRestore(drainTimeoutMs = 500, contentionTimeoutMs = 500, engineId = "")
            fail("Expected IllegalArgumentException on blank engine ID")
        } catch (_: IllegalArgumentException) {}

        try {
            manager.beginExclusiveRestore(drainTimeoutMs = 500, contentionTimeoutMs = 500, engineId = "   ")
            fail("Expected IllegalArgumentException on whitespace engine ID")
        } catch (_: IllegalArgumentException) {}

        // Legitimate acquisition
        val token = manager.beginExclusiveRestore(drainTimeoutMs = 500, contentionTimeoutMs = 500, engineId = ownerEngine)
        assertNotNull(token)

        // Validation with missing (blank/whitespace) engine ID must fail closed
        assertFalse(manager.validateExclusiveRestoreToken(token, ""))
        assertFalse(manager.validateExclusiveRestoreToken(token, "   "))

        // Validation with cross-engine ID must fail closed
        assertFalse(manager.validateExclusiveRestoreToken(token, foreignEngine))

        // Legitimate owner engine validates true
        assertTrue(manager.validateExclusiveRestoreToken(token, ownerEngine))

        // Cleanup
        manager.abortExclusiveRestore(token, ownerEngine)
    }

    @Test
    fun testExclusiveRestoreOwnerEngineDetachment() {
        val restoreEngine = "engine_restore_worker"
        val token = manager.beginExclusiveRestore(drainTimeoutMs = 1000, contentionTimeoutMs = 1000, engineId = restoreEngine)
        assertNotNull(token)
        assertEquals(LockManagerState.EXCLUSIVE_HELD, manager.currentState)
        assertTrue(manager.validateExclusiveRestoreToken(token, restoreEngine))

        // When restore owner engine detaches unexpectedly:
        val reclaimed = manager.onEngineDetached(restoreEngine)
        assertTrue(reclaimed > 0)

        // Manager must safely downgrade to OPEN, invalidate token, and clear owner
        assertEquals(LockManagerState.OPEN, manager.currentState)
        assertNull(manager.exclusiveOwnerToken)
        assertNull(manager.exclusiveOwnerEngineId)
        assertFalse(manager.validateExclusiveRestoreToken(token, restoreEngine))

        // Normal operations must now be admitted
        val newFgLease = manager.acquireForegroundSharedLease("engine_new_main")
        assertNotNull(newFgLease)
        manager.releaseForegroundLease("engine_new_main", newFgLease)
    }

    @Test
    fun testExclusiveRestoreDetachmentWithLockFailureEntersIndeterminate() {
        val restoreEngine = "engine_restore_worker"
        val token = manager.beginExclusiveRestore(drainTimeoutMs = 1000, contentionTimeoutMs = 1000, engineId = restoreEngine)
        assertNotNull(token)

        // Close the manager's channel underneath it to simulate an I/O failure when trying to re-acquire the shared lock
        val lockFileField = SpendXProcessLockLeaseManager::class.java.getDeclaredField("fileChannel")
        lockFileField.isAccessible = true
        val channel = lockFileField.get(manager) as? java.nio.channels.FileChannel
        channel?.close()

        // On detachment, the lock manager cannot re-acquire shared lock on closed channel and must enter INDETERMINATE
        manager.onEngineDetached(restoreEngine)
        assertEquals(LockManagerState.INDETERMINATE, manager.currentState)
        assertFalse(manager.validateExclusiveRestoreToken(token, restoreEngine))
    }
}

class ExternalProcessLockHolder {
    companion object {
        @JvmStatic
        fun main(args: Array<String>) {
            if (args.isEmpty()) return
            val file = File(args[0])
            val durationMs = if (args.size > 1) args[1].toLong() else 1000L
            val mode = if (args.size > 2) args[2] else "exclusive"
            val isShared = mode == "shared"

            val raf = RandomAccessFile(file, "rw")
            val channel = raf.channel
            try {
                val lock = channel.tryLock(0, Long.MAX_VALUE, isShared)
                if (lock != null) {
                    println("LOCK_ACQUIRED")
                    System.out.flush()
                    Thread.sleep(durationMs)
                    lock.release()
                    println("LOCK_RELEASED")
                    System.out.flush()
                } else {
                    println("LOCK_FAILED")
                    System.out.flush()
                }
            } catch (e: Exception) {
                println("LOCK_ERROR:${e.message}")
                System.out.flush()
            } finally {
                channel.close()
                raf.close()
            }
        }
    }
}

