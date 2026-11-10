# SpendX Release Readiness — Pillar 4.5A.1.22
## Portable Encrypted Backup: Architecture & Crash Recovery Specification (SEC-01)

**Target:** SpendX 2.1.0  
**Phase:** Pillar 4.5A.1.22 — Database Quiescence Proof and OS Lock Uncertainty  
**Status:** Complete — Architecture Closed with Explicit Implementation Gate  
**Date:** 2026-11-05  

---

## 1. Durability Contract, Synchronization Inventory & Sequencing

To avoid overstating physical hardware guarantees, SpendX defines durability confirmation within standard OS/filesystem contract boundaries.

### 1.1 Definition of Durability Confirmation
Durability confirmation is defined strictly as the **successful return of required file-level and directory-level synchronization system calls without error**:
- It does **not** assert physical immunity against hardware flash controller drop, battery-backed cache loss, NAND wear, or physical media destruction.
- It asserts that the application has completed all prescribed OS-level synchronization primitives (`fsync()` on file descriptors and `fsync(dir_fd)` on directory descriptors) and that zero I/O errors were reported by the kernel.

### 1.2 Durability Classification
1. **Retained:**
   - The application has not intentionally unlinked or deleted the artifact. The artifact remains untouched by application cleanup routines.
2. **Durability Confirmed:**
   - All prescribed file `fsync()` and directory `fsync(dir_fd)` calls have completed successfully on platforms providing verified native directory synchronization.
3. **Durability Unconfirmed:**
   - The artifact exists and is visible in the current filesystem view (kernel VFS / page cache), but persistence across sudden power loss is **not guaranteed** because directory metadata was not synchronized (e.g. standard Dart `dart:io` runtime or directory `fsync()` failure).
   - Under Durability Unconfirmed, safety backups and journal metadata remain **retained** with `state: cleanupPending`.

### 1.3 Synchronization Inventory & Prescribed Ordering
Participating artifacts and directories:
1. **Database Files Requiring File Sync (`fsync()`):**
   - Active database: `spendx.db`
   - Restored staging database: `spendx.db.restored`
   - Safety backup database: `spendx.db.pre_restore_backup`
   - Rollback staging copy: `spendx.db.rollback_staging`
   - Quarantined databases: `spendx.db.corrupt_<opId>_<timestamp>`
   - Restore journal: `spendx_restore_journal.json`
2. **Directories Requiring Directory Sync (`fsync(dir_fd)`):**
   - Application database parent directory (containing active database, backups, staging files, quarantine files, and lockfile).
   - Journal parent directory (co-located in application database directory).
3. **Prescribed Invariant Ordering:**
   ```text
   Step 1: Source File Flush & File fsync()
   Step 2: Atomic Rename (POSIX rename(2) or native renameat2/renamex_np)
   Step 3: Parent Directory Directory fsync(dir_fd)
   Step 4: Journal State Transition, Flush & File fsync()
   Step 5: Parent Directory Directory fsync(dir_fd)
   Step 6: Authoritative Cleanup & Final Directory fsync(dir_fd)
   ```
4. **Behavior on Synchronization Failure or Unavailability:**
   - File `fsync()` failure: **HALT IMMEDIATELY**. Do not proceed to rename.
   - Directory `fsync()` unavailable (pure Dart `dart:io`): durability status is recorded as **Durability Unconfirmed**; safety backups and journal remain **retained**.
   - Directory `fsync()` failure (`EIO`): **HALT IMMEDIATELY**; do not delete any safety artifact; report storage error.

---

## 2. Coordinator Ownership, Readiness Lifecycle & Concurrency Protocol

### 2.1 The 7-Phase Coordinator Ownership Lifecycle
Because Dart's `RandomAccessFile.lock()` is process-associated and cannot serialize multiple Flutter engines within the same process, SpendX implements a **Two-Tier Synchronization Lifecycle** powered by an authoritative host process lock lease:

```text
Phase 1 (Unpublished / Starting):
        - Candidate isolate spawns in an unpublished, unready state (CoordinatorState.starting).
        - Candidate does NOT register with IsolateNameServer.

Phase 2 (Tier 1: Native Host Process Lease Acquisition):
        - Candidate calls native host platform lock via PlatformChannel:
          MethodChannel('app.spendx/process_lock').invokeMethod('acquire', {'engineId': engineId})
        - Android host executes SpendXProcessLockLeaseManager (JVM singleton in Application context).
        - Strict Single-Lease Non-Reentrant Policy:
          - If lease is already held by requesting engine: returns DUPLICATE_ACQUISITION_REJECTED.
          - If lease is held by another engine: returns ENGINE_LOCK_BUSY.
        - Host opens authoritative descriptor and calls FileChannel.tryLock().

Phase 3 (Tier 2 Verification & Explicit Null Handling):
        - Host evaluates tryLock():
          - If tryLock() == null: external process holds fcntl lock. Host immediately closes
            descriptor in finally block, rolls back Tier 1 state, and returns TIER2_LOCK_BUSY.
          - If tryLock() succeeds: host generates unique UUIDv4 LeaseToken.
        - Candidate stores the returned 'leaseToken'.
        - Note: Dart code NEVER opens 'spendx_restore.lock' directly; descriptor is held by Java host.

Phase 4 (Identity Generation):
        - Candidate generates unique 'coordinatorInstanceId' (UUIDv4 + timestamp).
        - Associates coordinatorInstanceId with the validated leaseToken.

Phase 5 (Endpoint Publication Under Locks):
        - Holding both the Tier 1 lease and Tier 2 OS lock, candidate registers its port:
          IsolateNameServer.registerPortWithName(receivePort.sendPort, 'spendx_restore_coordinator').
        - If a stale mapping exists, the candidate updates/re-registers it under dual-lock protection.

Phase 6 (Readiness Announcement):
        - Candidate transitions state to CoordinatorState.ready.
        - Begins listening for Handshake and Operation requests.

Phase 7 (Caller Handshake & Operation Submission):
        - Calling isolate looks up port and sends HandshakeRequest(nonce).
        - Coordinator returns HandshakeResponse(nonce, coordinatorInstanceId, state: ready).
        - Calling isolate submits database operations ONLY after validating the ready handshake.
```

### 2.2 Corrected Database Access Gate Protocol (DAG-01) & OS Lock Ordering

Static source code inspection reveals that 15 application repositories access `AppDatabase.instance.database` directly without coordinating with `DatabaseLifecycleCoordinator`. Furthermore, auxiliary background execution (`notificationTapBackground`) operates in a detached `FlutterEngine` that cannot share Dart VM state.

To guarantee that no application query races with restore, rollback, or file replacement, SpendX specifies the **Corrected Database Access Gate (DAG-01)** protocol.

#### 2.2.1 Invariant: Establish Ownership Before Destructive Preparation
An exclusive process lease and OS-level file lock **must be acquired BEFORE any destructive restore preparation, admission closure, or connection teardown begins**. If lock acquisition is deferred to the end of the drain, external processes or concurrent engines can acquire the lock, initiate writes, or observe a partially closed database.

```text
[Initiate Restore / Rollback / Recovery]
                   │
                   ▼
┌────────────────────────────────────────────────────────┐
│ Phase 1: Establish Dual-Tier Restore Ownership         │
│  - Tier 1: Acquire JVM Process Lease                   │
│  - Tier 2: Acquire Exclusive POSIX fcntl File Lock     │
└────────────────────────────────────────────────────────┘
                   │ (If acquisition fails -> Abort immediately; zero state change)
                   ▼
┌────────────────────────────────────────────────────────┐
│ Phase 2: Atomic Admission Closure                      │
│  - Step 2a: Native Admission Closure (closeNative())   │ ──► Rejects new native background tickets
│  - Step 2b: Dart Admission Closure (closeDart())       │ ──► Rejects new foreground queries
└────────────────────────────────────────────────────────┘
                   │
                   ▼
┌────────────────────────────────────────────────────────┐
│ Phase 3: Active Operation Drainage (Timeout: 5000 ms)  │
│  - Await activeDartOperations == 0                     │
│  - Await activeNativeTickets == 0                      │
└────────────────────────────────────────────────────────┘
                   │
        ┌──────────┴──────────┐
        │ Drain Timeout       │ Drain Succeeded (Both == 0)
        ▼                     ▼
┌─────────────────┐   ┌────────────────────────────────────────────────────────┐
│ Coordinated     │   │ Phase 4: Explicit Connection Teardown                  │
│ Timeout         │   │  - AppDatabase.instance.close()                        │
│ Rollback        │   └────────────────────────────────────────────────────────┘
│ (See 2.2.3)     │                            │
└─────────────────┘                            ▼
                      ┌────────────────────────────────────────────────────────┐
                      │ Phase 5: Plugin Worker Queue Drain                     │
                      │  - Dispatch barrier task to HandlerThread looper       │
                      │  - Confirm executor queue is idle                      │
                      └────────────────────────────────────────────────────────┘
                                               │
                                               ▼
                      ┌────────────────────────────────────────────────────────┐
                      │ Phase 6: Restore Journal Preparation                   │
                      │  - Write spendx_restore_journal.json (state: swapping) │
                      │  - fsync(file_fd) and fsync(dir_fd)                    │
                      └────────────────────────────────────────────────────────┘
                                               │
                                               ▼
                      ┌────────────────────────────────────────────────────────┐
                      │ Phase 7: Atomic Database Replacement (6-Step Protocol) │
                      │  - Move active to quarantine (no-replace)              │
                      │  - Rename staging to spendx.db (no-replace)            │
                      │  - Post-swap 7-point validation                        │
                      └────────────────────────────────────────────────────────┘
                                               │
                                               ▼
                      ┌────────────────────────────────────────────────────────┐
                      │ Phase 8: Post-Restore Reopening                        │
                      │  - Reopen spendx.db connection                         │
                      │  - Reopen Dart admission gate                          │
                      │  - Reopen Native admission gate                        │
                      │  - Release Tier 2 OS lock and Tier 1 lease             │
                      └────────────────────────────────────────────────────────┘
```

#### 2.2.2 Operation-Scoped Native Tickets (Replacing Boolean Checks)
A boolean flag (`isDatabaseAccessPermitted()`) suffers from a Time-of-Check to Time-of-Use (TOCTOU) race condition. SpendX specifies an **operation-scoped native ticket protocol**:
1. **`acquireDatabaseOperationTicket(engineId)`:** Atomically checks if restore mode is active (`isRestoreActive == true` or `admissionClosed == true`). If closed, returns `null` immediately. If open, increments `activeNativeTicketsCount`, allocates a unique monotonic `ticketId`, and registers `ticketId -> NativeTicket(engineId, timestamp)`.
2. **`releaseDatabaseOperationTicket(ticketId)`:** Validates and removes `ticketId`, decrements `activeNativeTicketsCount`, and if draining, signals drain completion when tickets reach 0.
3. **Behavior When Ticket Cannot Be Acquired:** If `acquireDatabaseOperationTicket()` returns `null`, the background engine is **strictly prohibited from touching `spendx.db`**. The action is serialized to Android Room/SharedPreferences as `PENDING_RESTORE_COMPLETION`, and the engine exits cleanly.

#### 2.2.3 Coordinated Timeout Rollback Protocol
If in-flight operations fail to drain within the 5000 ms timeout window:
1. **Database Files Untouched:** `spendx.db`, WAL files, staging files, and safety backups are never modified or closed.
2. **Reopen Gates Symmetrically:** Both the native host gate (`admissionClosed = false`) and Dart gate (`GateState.open`) reopen consistently to prevent asymmetric deadlock.
3. **Preserve In-Flight Operations:** Operations executing when timeout occurred complete normally under their existing tickets.
4. **Release Locks:** Tier 2 OS lock and Tier 1 lease are released.
5. **Indeterminate State on Release Failure:** If releasing the OS lock throws `IOException`, the system transitions to `INDETERMINATE`, permanently blocking new admissions until process termination.

#### 2.2.4 Writer Participation in OS-Level Lock Protocol
Every execution context capable of opening or modifying `spendx.db` (foreground UI, background sync processes, CLI tools) **must participate in the locking protocol**:
- Normal database connections acquire a **shared (read) lock** on `spendx_restore.lock` (`F_RDLCK`) before executing transactions.
- The restore coordinator acquires an **exclusive (write) lock** on `spendx_restore.lock` (`F_WRLCK`).
- Active normal writers hold shared locks, blocking the restore coordinator until writes complete.
- While the restore coordinator holds the exclusive lock, all normal writers block at the OS kernel level on `spendx_restore.lock`, preventing concurrent database access during file replacement.

---

### 2.3 Execution Context Inventory & SQLite Quiescence Semantics

#### 1. Prohibition Against False Proof of Quiescence
None of the following signals, independently or in combination, constitutes proof that database access has ceased:
- Heartbeat timeout or missed ping.
- Coordinator isolate exit event.
- Forceful termination via `Isolate.kill()`.
- `FlutterEngine` destruction notification.
- Cancellation token completion.

Force-killing a Dart isolate terminates only user-space Dart bytecode execution; it does **not** stop native background threads, in-flight SQLite C library calls, or plugin worker queues already dispatched by the host process.

#### 2. Authoritative Inventory of Database-Capable Execution Contexts
Every execution context capable of accessing the database during backup, restore, rollback, or recovery is accounted for:

| Context # | Execution Context | Concrete Mechanism | Stopping Procedure | Confirmation Criterion |
| :--- | :--- | :--- | :--- | :--- |
| **EC-01** | **Coordinator Isolate** | Dedicated Dart isolate executing restore flow | Cancellation signal sent via port; if unresponsive, `Isolate.kill(priority: immediate)` | `Isolate.addOnExitListener` fires and delivers termination event to listener port |
| **EC-02** | **Root & Auxiliary Dart Isolates** | UI isolate or `compute()` worker isolates accessing database | Gated by `GatedDatabase` admission control (`GateState.draining`) | Active operations counter `activeDartOperations == 0` |
| **EC-03** | **Plugin-Managed Worker Threads** | `sqflite` native Android `HandlerThread` / `ExecutorService` | Dispatch queue barrier task submission via platform channel | Barrier task completes execution on `databaseWorkerPool` looper thread |
| **EC-04** | **Native SQLite / SQLCipher Engine** | In-flight C library execution, WAL auto-checkpoint, pager threads | Await return of active queries; close connection via `AppDatabase.close()` | `db.close()` Future completes successfully; SQLiteDatabase closed; transaction depth == 0 |
| **EC-05** | **Asynchronous I/O Workers** | Platform channel streaming workers, file copy buffers, stream decoders | Stream cancellation and buffer cancellation signaled | All pending I/O `Future` completions observed; underlying file descriptors closed |

#### 3. Quiescence Evidence Matrix by Connection Type (Removal of Universal `sqlite3_next_stmt`)
`sqlite3_next_stmt` is an internal C-FFI pointer function available only when using `package:sqlite3` directly via FFI. It is **not accessible on `sqflite.Database` handles over platform channels**. SpendX formally delineates observable quiescence evidence by connection type:

| Connection Type | Target & Mechanism | Observable Verification Evidence |
| :--- | :--- | :--- |
| **1. `sqflite.Database` Connection Closure** | Production database (`spendx.db`) via platform channel | 1. Dart `await db.close()` Future completes successfully without error.<br>2. Dart `db.isOpen == false`.<br>3. Platform channel completion confirms `closeDatabase()` executed on worker Looper.<br>4. Underlying native SQLiteDatabase handle closed. |
| **2. Plugin Worker Queue Draining** | Dedicated `HandlerThread` ("Sqflite") in Android host | 1. Barrier `Runnable` dispatched to `databaseWorkerPool`.<br>2. When barrier executes on looper, all previous SQL tasks have completed.<br>3. Platform channel returns success callback. |
| **3. Transaction Completion** | In-flight SQLite transactions | 1. Dart `db.inTransaction == false`.<br>2. Java `database.isInTransaction() == false` (`transactionDepth == 0`). |
| **4. Direct FFI Connection Closure** | In-memory verification handles (`ffi.sqlite3.openInMemory()`) | 1. Direct FFI handle closed via `ffiDb.close()`.<br>2. Direct FFI prepared statements verified: `ffi.sqlite3_next_stmt(ffiDb.handle, nullptr) == nullptr`. |
| **5. Database-Wide Quiescence** | Overall physical database file (`spendx.db`) | 1. All Dart tickets drained: `activeDartOperations == 0`.<br>2. All Native tickets drained: `activeNativeTickets == 0`.<br>3. Active connection closed: `AppDatabase.instance.close()` completed.<br>4. Plugin worker pool drained via barrier task.<br>5. Tier 2 exclusive POSIX `fcntl` lock held on `spendx_restore.lock`. |

#### 4. The Mandatory Quiescence Invariant
If **ANY** of the five execution contexts cannot be confirmed stopped:
- The manager **MUST RETAIN THE PROCESS LEASE AND OS FILE LOCK**.
- The manager **MUST NOT** permit another restore, rollback, or database operation.
- The state transitions to **`CoordinatorState.indeterminate`**. All subsequent callers receive `RestoreIndeterminateException`.
- Force-killing a Dart isolate is explicitly defined as **insufficient** unless all independently executing native/plugin/I/O workers have also been stopped or proven unable to access the database.

### 2.4 Safe Engine Destruction Protocol
When an Android `FlutterEngine` is being detached or destroyed (`EngineLifecycleListener.onEngineWillBeDestroyed`):
1. **Reject New Operations:** Immediately set an atomic flag `isShuttingDown = true` on the engine's channel handler. Reject all incoming operations with `ENGINE_SHUTTING_DOWN`.
2. **Cancel or Drain Active Work:** Issue a cancellation signal to the active restore operation and wait for active I/O worker threads to drain.
3. **Confirm Cessation of Native Database Operations:**
   - Wait for SQLite native connection close (`sqlite3_close_v2`).
   - Confirm zero pending asynchronous I/O writes or journal flushes across all five contexts (EC-01 to EC-05).
4. **Release File Lock & Close Descriptor:** Only AFTER step 3 is confirmed, release the POSIX `fcntl` lock via `FileLock.release()` and close the `FileChannel`.
5. **Reclaim Process-Local Lease:** Transition manager state through the Differentiated Release State Machine (Section 2.5).
- **FAIL-SAFE RETENTION RULE:** If Step 3 **CANNOT be established** (e.g., native SQLite thread is blocked in an un-abortable C call or driver hang), the manager **MUST NOT release the file lock or close the descriptor** merely because the Flutter engine was destroyed! The lock is deliberately kept held until full OS process termination to protect the database against concurrent corruption from another process.

### 2.4 Duplicate Acquisition Policy: Strict Single-Lease Non-Reentrant Rejection
SpendX explicitly selects **Strict Single-Lease Non-Reentrant Rejection**:
- If an engine attempts to call `acquire()` while that same engine (or any engine) already holds an active lease, the manager strictly **REJECTS** the request with `DUPLICATE_ACQUISITION_REJECTED` (error code `LEASE_ALREADY_HELD`).
- There is **zero re-entrancy** and **zero reference counting**.
- **Rationale:** SpendX restore, rollback, and recovery operations are strictly mutually exclusive critical sections. There is never a valid architectural reason for two concurrent restore operations to run within the same engine. Rejecting duplicate acquisition completely eliminates reference-counting hazards such as premature unlock, over-release, ABA permit leaks, and partial cancellation bugs.

### 2.5 Differentiated Lock Release & Cleanup Failure State Machine
Release is not an unconditional reset. SpendX implements a strict 4-way outcome state machine:

```text
                                  +-----------------------+
                                  | release(leaseToken)   |
                                  +-----------------------+
                                              |
                             Validate leaseToken == activeLease.token
                                              |
                       +----------------------+----------------------+
                       | Valid                                      | Mismatch (Stale)
                       v                                            v
         Attempt FileLock.release()                      [Outcome D: STALE_REJECTED]
                       |                                 - Active lease untouched
            +----------+----------+                      - Descriptor untouched
            | Success             | Throws / Uncertain   - Zero state change
            v                     v
   Attempt channel.close()   [Outcome B: INDETERMINATE]
            |                - Retain lock & lease
     +------+------+         - Reject new acquisitions
     |             |         - Requires process restart / retry
     | Success     | Throws
     v             v
[Outcome A:    [Outcome C: DESCRIPTOR_CLEANUP_FAILED]
 UNLOCKED]     - FileLock was released at OS level
 - Lease clear - File descriptor leaked / unclosed
 - Ready       - Reject new acquisitions to prevent POSIX hazards
               - Do NOT claim cleanup succeeded
```

#### Outcome Specifications:
- **Outcome A: Full Success (`State: UNLOCKED`):**
  - `FileLock.release()` returns successfully without error.
  - `FileChannel.close()` returns successfully without error.
  - Action: `activeLease` is set to `null`; manager state transitions to `UNLOCKED`.
- **Outcome B: Release Failure or Uncertainty (`State: INDETERMINATE`):**
  - `FileLock.release()` throws `IOException` or execution times out.
  - Action: The manager does **not** assume the OS lock was released. The lease is **retained**. Manager state transitions to `INDETERMINATE`. All subsequent acquisition requests are strictly rejected with `RestoreIndeterminateException`.
- **Outcome C: Descriptor Close Failure (`State: DESCRIPTOR_CLEANUP_FAILED`):**
  - `FileLock.release()` succeeded, but `FileChannel.close()` throws `IOException`.
  - Action: The manager records a descriptor leak. Because closing descriptors later could trigger POSIX `fcntl` silent release bugs on active locks, the manager transitions to `DESCRIPTOR_CLEANUP_FAILED`. It does **not** claim cleanup succeeded and rejects new acquisitions until the host process restarts.
- **Outcome D: Token Mismatch (`State: STALE_REJECTED`):**
  - Caller supplies a `leaseToken` that does not match `activeLease.token`.
  - Action: The manager performs **zero modifications** to the active lease or descriptor. Returns `STALE_LEASE_TOKEN`.
- **Acquisition Rollback Parity:** If `tryLock()` returns `null` or throws, and the subsequent cleanup `channel.close()` throws `IOException`, the manager transitions to `DESCRIPTOR_CLEANUP_FAILED` rather than claiming the state is `UNLOCKED`.

### 2.6 Acquisition-in-Progress Lifecycle & Mid-Transition Interruption
The manager explicitly governs engine destruction or cancellation during every acquisition transition:

| Transition Point | State Name | Descriptor Status | OS Lock Status | Authoritative Owner | Cleanup Protocol on Engine Destruction / Cancel |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Transition 1** | `LEASE_ACQUIRING_PRE_OPEN` | Not yet opened | None | Manager | Revert state to `UNLOCKED`. Zero descriptor to close. |
| **Transition 2** | `LEASE_ACQUIRING_FD_OPEN` | Opened (`channel != null`) | None (pre-tryLock) | Manager | Manager closes `channel`. If close throws `IOException`, transition to `DESCRIPTOR_CLEANUP_FAILED`. Otherwise `UNLOCKED`. |
| **Transition 3** | `LEASE_ACQUIRING_LOCK_HELD` | Opened (`channel != null`) | Held (`fileLock != null`) | Manager | Manager calls `fileLock.release()` and `channel.close()`. If release fails $\rightarrow$ `INDETERMINATE`. If close fails $\rightarrow$ `DESCRIPTOR_CLEANUP_FAILED`. If both succeed $\rightarrow$ `UNLOCKED`. |
| **Transition 4** | `LEASE_GRANTING` | Opened | Held | `activeLease` | Full release protocol (Section 2.5) executed. |

### 2.7 Authoritative Lockfile Ownership Model
To completely eliminate the POSIX silent `fcntl` close hazard:
- **Component Opening the Lockfile:** The Android Host Process Lock Manager (`SpendXProcessLockLeaseManager`) is the **sole component** authorized to open `spendx_restore.lock`.
- **Component Owning the Descriptor:** The Host Lock Manager owns the single `FileChannel` / `RandomAccessFile` instance.
- **Descriptor Lifetime:** Opened immediately upon valid Tier 1 lease grant; held open continuously across the restore operation; closed and flushed immediately upon validated `release(leaseToken)` or confirmed safe engine destruction.
- **Strict Dart Seclusion:** Dart code **NEVER** calls `File('spendx_restore.lock').open()`. Dart receives and holds only the opaque `leaseToken` string.
- **Independent OS Process Participation:** External processes (distinct Linux PIDs) open `spendx_restore.lock` with POSIX `fcntl(F_SETLK)`. Because separate PIDs have isolated file descriptor tables, opening/closing descriptors in an external process has zero effect on the SpendX Android app process's `fcntl` lock.
- **Platform Interoperability Verification:** On Android Bionic libc, Java `FileChannel.lock()` delegates to `fcntl(fd, F_SETLK64, &fl)`, and Dart CLI/POSIX utilities delegate to `fcntl(fd, F_SETLK, &fl)`. Because both use POSIX `fcntl` across separate PIDs, they correctly block and serialize at the kernel inode level. Native `flock(2)` is strictly prohibited.

### 2.8 Process-Local vs OS-Level Lock Failure Matrix & Uncertainty Semantics

When `FileLock.release()` or `FileChannel.close()` throws an exception, the host runtime is in a state of OS-level lock uncertainty:

| Failure Scenario | Process-Local Lease State | OS-Level Lock State | External Process Acquisition | Kernel FD Table Status | Required Recovery Action |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1. `FileLock.release()` throws `IOException`** | Retained (`INDETERMINATE`) | **UNCERTAIN** (Kernel may or may not have cleared lock) | **UNCERTAIN** (External process may block or acquire) | Descriptor remains open in kernel table | **Process Termination REQUIRED**. Dart/JVM cannot verify OS release. OS kernel process termination is the only definitive mechanism to guarantee lock reclamation. |
| **2. `FileChannel.close()` throws `IOException` after successful release** | Retained (`DESCRIPTOR_CLEANUP_FAILED`) | **CONFIRMED RELEASED** (Kernel cleared lock during `release()`) | **CAN ACQUIRE** (External process can obtain lock) | Leaked descriptor in kernel table | **Process Termination REQUIRED**. Prevents future `fcntl` silent unlock bugs on reused file descriptors. |
| **3. Rollback `channel.close()` throws `IOException` after null `tryLock()`** | Retained (`DESCRIPTOR_CLEANUP_FAILED`) | **CONFIRMED HELD BY EXTERNAL PROCESS** | **HELD BY EXTERNAL** | Leaked descriptor in kernel table | **Process Termination REQUIRED**. External owner remains authoritative; SpendX cleans host process state. |
| **4. Clean Release (`release()` & `close()` succeed)** | `UNLOCKED` | **CONFIRMED RELEASED** | **CAN ACQUIRE** | Descriptor closed and removed | None. Safe for subsequent acquisitions. |

**Inviolable Principle of Lock Uncertainty:** Dart VM and Android ART JVM runtimes cannot guarantee OS-level lock release if the release syscall throws. When a release call fails, the lock status is classified as **Uncertain**, the lease is retained as **Indeterminate**, and full process restart is required.

### 2.9 Five-Stage Completion and Durability Separation

To avoid conflating execution milestones with physical durability guarantees, SpendX establishes five distinct, non-fungible stages:

```text
┌────────────────────────────────────────────────────────┐
│ Stage 1: Operation Quiescence                          │ ──► Zero threads/workers executing database queries
└────────────────────────────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ Stage 2: Transaction Completion                        │ ──► SQLite returns SQLITE_OK on COMMIT / ROLLBACK
└────────────────────────────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ Stage 3: Integrity Validation                          │ ──► 7-stage validation passes (Header, PRAGMA, FK, Accounting)
└────────────────────────────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ Stage 4: File Data Durability                          │ ──► POSIX fsync(file_fd) returns 0 without error
└────────────────────────────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ Stage 5: Directory Metadata Durability                 │ ──► POSIX fsync(dir_fd) returns 0 without error
└────────────────────────────────────────────────────────┘
```

1. **Stage 1 (Operation Quiescence):** Confirms that all application repositories, Dart isolates, background `FlutterEngines`, and native `sqflite` worker threads have completed and stopped querying the database.
2. **Stage 2 (Transaction Completion):** Confirms that SQLite's internal storage engine has completed a transaction and returned `SQLITE_OK`. Pages may still reside strictly in OS page cache memory buffers.
3. **Stage 3 (Integrity Validation):** Confirms that the database pages on disk or in cache pass all 7 integrity and accounting invariant checks.
4. **Stage 4 (File Data Durability):** Confirms that POSIX `fsync(file_fd)` has executed without error, flushing dirty file data blocks from volatile kernel page cache to physical storage.
5. **Stage 5 (Directory Metadata Durability):** Confirms that POSIX `fsync(dir_fd)` has executed without error on the parent directory, ensuring that atomic directory entries (e.g. renames of `spendx.db.restored` to `spendx.db`) persist across sudden power loss.

### 2.10 Architectural Evidence Classification Table

Every technical assertion in the SpendX portable-backup architecture is explicitly classified into one of four evidence tiers:

| Evidence Tier | Definition | Concrete Scope in SpendX Architecture |
| :--- | :--- | :--- |
| **Tier 1: Verified from Repository Source** | Facts confirmed by inspecting committed SpendX source files, dependency configurations, and project manifests. | - Dependency versions: `sqflite: 2.4.2`, `sqlite3: 3.5.2`, `sqlite3_flutter_libs: 0.6.0+eol`.<br>- Connection openers in `spendx_database_factory.dart`, `app_database.dart`, `backup_service.dart`.<br>- 15 Repositories directly invoking `AppDatabase.instance.database` without checking coordinator.<br>- Multi-engine background task `notificationTapBackground` in `notification_service_v2.dart`.<br>- Fire-and-forget `unawaited(finalizeLiveChoice(...))` call. |
| **Tier 2: Documented Runtime / OS Behavior** | Documented behavior of the Dart VM, Android ART JVM, Linux kernel, and POSIX standards. | - SQLite C semantics: `sqlite3_close_v2()` zombie connections, `sqlite3_next_stmt()` connection isolation, `PRAGMA wal_checkpoint(TRUNCATE)` concurrency blocks.<br>- POSIX `fcntl(F_SETLK)` process association and descriptor close silent release.<br>- Java `FileChannel.tryLock()` throwing `OverlappingFileLockException` on same-JVM threads.<br>- Kernel synchronous descriptor and lock cleanup on process termination (`SIGKILL`). |
| **Tier 3: Architecture Assumptions** | Design choices, invariants, and policies defined by the SpendX architecture specification. | - Rejection of email-derived keys; Argon2id user password requirement.<br>- Format v3 encrypted zip envelope structure and manifest format.<br>- Non-reentrant single-lease rejection policy (`DUPLICATE_ACQUISITION_REJECTED`).<br>- Quarantine preservation of unverified active databases on crash recovery.<br>- Formal exclusion of iOS from 2.1.0 release scope under `Limitation LIM-PLAT-01-IOS`. |
| **Tier 4: Unverified Physical-Device Behavior** | Hardware-specific timings, vendor-specific kernel quirks, or low-memory killer (LMK) interactions requiring physical execution. | - ART JVM `FileLock.release()` throwing on physical OEM Android devices.<br>- Directory `fsync` behavior across various Android storage partitions (F2FS vs ext4).<br>- All 27 lock lifecycle test cases (Tests L-01 through L-27). Formally gated under **Gate G-SEC-01-LOCK**. |

---

## 3. Multi-Engine & Multi-Process Coordination Boundaries

### 3.1 Coordination Boundaries & Platform Scope Resolution
1. **Single Flutter Engine Isolates:**
   - Isolates spawned from the same root Flutter engine (e.g. via `compute()`, background worker isolates sharing the Dart VM isolate group) serialize restore/recovery operations through the single **Restore Coordinator Isolate** via message ports (`SendPort`/`ReceivePort`).
2. **Separate Flutter Engines in Same Android OS Process:**
   - Background execution callbacks executed via `@pragma('vm:entry-point')` (specifically `notificationTapBackground` in [`lib/services/notification_service_v2.dart`](file:///Users/sivek/Documents/SpendX/lib/services/notification_service_v2.dart#L1366)) run in an **independent background FlutterEngine** spawned by Android.
   - Separate Flutter engines in the same process do not share `IsolateNameServer` reliably and **cannot** rely on Dart's `RandomAccessFile.lock()` (which fails across same-PID engines).
   - They coordinate strictly through **Tier 1: Native Host Process Lease Manager** (`SpendXProcessLockLeaseManager` in Android ART JVM via Platform Channel).
3. **Platform Scope Resolution: Exclusion of iOS in 2.1.0:**
   - **Android Target:** Fully supported and specified (Tier 1 JVM `SpendXProcessLockLeaseManager` + Tier 2 POSIX `fcntl` on `spendx_restore.lock`).
   - **iOS Target:** **EXCLUDED from SpendX 2.1.0 release scope.** Formally marked as **`Limitation LIM-PLAT-01-IOS: iOS Portable Restore Excluded`**:
     - *Rationale:* No physical iOS hardware is attached to the CI/CD test harness; iOS runtimes do not execute a JVM (making Android JVM lease management inapplicable); native Darwin process synchronization (`os_unfair_lock` / serial dispatch queues) is not implemented in this milestone.
     - *Boundary Rule:* Pure Dart cannot guarantee atomic cross-engine or cross-process safety on iOS without native code extensions.
     - *Integrity Policy:* No proposed iOS mechanism is described as implemented or verified. iOS portability is formally deferred to a post-2.1.0 milestone.
4. **Independent OS Processes:**
   - Distinct OS processes (such as background sync services running with `android:process=":sync"` or CLI maintenance tools) coordinate strictly through **Tier 2: Process-Wide POSIX File Lock** (`spendx_restore.lock`) using `fcntl(F_SETLK)` / `FileChannel.lock()`.
5. **Strict Prohibition Against Coordinator Bypass & Incompatible Primitives:**
   - An isolate or background task unable to reach the coordinator must **NEVER bypass it and directly perform restore, rollback, or recovery**.
   - If a background execution path cannot reach the coordinator, it must either spawn an isolated coordinator that successfully acquires both Tier 1 and Tier 2 locks, or **safely abort** with `RestoreCoordinationException`.
   - Native `flock(2)` is strictly prohibited across all participants. Probing the lockfile descriptor from secondary callers or Dart code is strictly prohibited.

---

## 4. Enforced No-Overwrite Semantics & Qualified Pure-Dart Collision Handling

### 4.1 Scope of No-Overwrite Enforcement
SpendX enforces strict no-overwrite requirements across **all four rename operations**:
1. `spendx.db` $\rightarrow$ `spendx.db.corrupt_<opId>_<timestamp>` (Active database to quarantine)
2. `spendx.db.restored` $\rightarrow$ `spendx.db` (Restored staging to active database)
3. `spendx.db.rollback_staging` $\rightarrow$ `spendx.db` (Rollback staging to active database)
4. `spendx.db.pre_restore_backup` $\rightarrow$ recovery destination (Safety backup to recovery destination)

### 4.2 Native Atomic No-Replace Primitives
Where native platform bindings are available:
- **Linux / Android:** `renameat2(AT_FDCWD, oldpath, AT_FDCWD, newpath, RENAME_NOREPLACE)`
- **macOS / iOS (APFS):** `renamex_np(oldpath, newpath, RENAME_EXCL)`
These system calls guarantee at the OS kernel level that if `newpath` exists, the call fails atomically with `EEXIST` without modifying the destination inode.

### 4.3 Qualified Pure-Dart Collision Handling & Limitation Warning
- In standard Dart `dart:io`, `File.rename()` wraps POSIX `rename(2)`, which silently and atomically overwrites an existing destination file. Dart provides no standard API for `RENAME_NOREPLACE`.
- **Pure Dart Vacancy Check Behavior:**
  - Before invoking `File.rename()`, the engine performs an explicit vacancy check:
    ```dart
    if (File(destinationPath).existsSync()) {
      throw DestinationCollisionException(
        'Destination $destinationPath unexpectedly exists. Aborting rename to prevent overwrite.'
      );
    }
    ```
  - If a destination is detected during this check, the engine executes an immediate **safe abort**, preserving both source and destination without modification.
- **Explicit TOCTOU Race Qualification:**
  - However, if an external uncoordinated process creates `destinationPath` *between* `existsSync()` and `File.rename()`, POSIX `rename(2)` will overwrite it.
  - Therefore, the pure Dart fallback **must never be described as atomic no-replace or as protection against non-cooperating external writers**.
  - It is documented as an **unresolved OS primitive limitation** when running in pure Dart without native FFI extensions.

---

## 5. Operation 2: Replacement Procedure & Non-Destructive Rollback Protocol

Operation 2 transitions the restored database from staging (`spendx.db.restored`) to active (`spendx.db`), or rolls back original data if restore fails.

### 5.1 Operation 2 Branching Matrix

| Case | Active DB (`spendx.db`) State | Staging DB (`spendx.db.restored`) State | Safety Backup (`spendx.db.pre_restore_backup`) State | Authoritative Recovery Action |
| :--- | :--- | :--- | :--- | :--- |
| **Case 2.1** | **Missing** | **Valid Restored DB** (passes 7-point validation) | Exists (Valid original DB) | Rename `spendx.db.restored` $\rightarrow$ `spendx.db` using no-replace. Deep validate `spendx.db`. Issue directory sync. Advance journal to `contentVerified`. |
| **Case 2.2** | **Corrupt** (fails SQLCipher open or integrity check) | **Valid Restored DB** (passes 7-point validation) | Exists (Valid original DB) | **MANDATORY QUARANTINE:** Rename `spendx.db` to `spendx.db.corrupt_<opId>_<timestamp>` using no-replace. Confirm vacancy. Rename staging to active. Deep validate. Advance journal. |
| **Case 2.3** | **Valid but Unexpected Fingerprint** (does not match expected) | **Valid Restored DB** | Any | **HALT DEFENSIVELY / PRESERVE:** Rename active to `spendx.db.collision_<opId>_<timestamp>` using no-replace. Confirm vacancy. Do not overwrite. Halt for manual review. |
| **Case 2.4** | **Corrupt or Invalid** | **Corrupt or Invalid** | **Valid Original DB** (matches expected pre-restore hash) | **NON-DESTRUCTIVE ROLLBACK:** Execute the 8-step rollback sequence detailed below using staging copy. Safety backup is NEVER consumed until validation succeeds. |
| **Case 2.5** | **Corrupt or Missing** | **Corrupt or Missing** | **Corrupt or Missing** | **CATASTROPHIC HALT:** Preserve all files on disk. Throw fatal `RestoreCrashRecoveryException`. Zero new databases created. |

---

### 5.2 Non-Destructive Rollback Protocol (Case 2.4)
To ensure the original safety backup remains unmodified and retained across crashes, power loss, and post-restore validation failures:

```text
Step 1: Validate Safety Backup
        - Open 'spendx.db.pre_restore_backup' with Key_Dest.
        - Verify user_version == 24, PRAGMA integrity_check == 'ok', foreign keys == 0.
        - Verify canonical fingerprint matches expectedPreRestoreFingerprint.
        - If validation fails: HALT IMMEDIATELY; preserve all files; throw RestoreCrashRecoveryException.

Step 2: Quarantine Invalid Active Destination (Enforced No-Replace)
        - Rename corrupt 'spendx.db' -> 'spendx.db.corrupt_<restoreOperationId>_<timestamp>' using no-replace.
        - Write diagnostic manifest: 'spendx.db.corrupt_<restoreOperationId>_<timestamp>.diag'.
        - Issue directory fsync(dir_fd) if supported.
        - If quarantine rename fails or collisions occur: HALT IMMEDIATELY. Do not touch safety backup.

Step 3: Confirm Destination Vacancy
        - Assert File('spendx.db').existsSync() == false.
        - If occupied: HALT IMMEDIATELY.

Step 4: Create Rollback Staging Copy (Safety Backup Preserved!)
        - Copy 'spendx.db.pre_restore_backup' -> 'spendx.db.rollback_staging'.
        - Flush file and issue file fsync().
        - CRITICAL INVARIANT: 'spendx.db.pre_restore_backup' REMAINS UNMODIFIED AND RETAINED ON DISK.
        - If copy fails (e.g. ENOSPC): HALT IMMEDIATELY. Original backup remains safe.

Step 5: Validate Rollback Staging Copy
        - Verify 'spendx.db.rollback_staging' matches expectedPreRestoreFingerprint.
        - If validation fails: Delete corrupted staging copy; HALT IMMEDIATELY. Safety backup remains intact.

Step 6: Atomically Move Rollback Staging to Active (Enforced No-Replace)
        - Rename 'spendx.db.rollback_staging' -> 'spendx.db' using no-replace.
        - Issue directory fsync(dir_fd) if supported.
        - CRITICAL INVARIANT: 'spendx.db.pre_restore_backup' STILL REMAINS UNMODIFIED AND RETAINED.

Step 7: Mandatory Post-Rollback 7-Point Deep Validation
        - Deep-validate 'spendx.db' against expectedPreRestoreFingerprint.
        - If validation fails:
          a. Rename failed 'spendx.db' -> 'spendx.db.corrupt_post_rollback_<timestamp>' using no-replace.
          b. HALT IMMEDIATELY. Original 'spendx.db.pre_restore_backup' is STILL AVAILABLE on disk!

Step 8: Record Rollback State & Authorize Retirement
        - Update journal to state: rolledBack, isCleanupPending: true.
        - Flush journal and issue directory fsync(dir_fd).
        - RETIREMENT RULE: 'spendx.db.pre_restore_backup' is eligible for retirement ONLY after
          Steps 1-8 all succeed AND native directory sync confirms durability.
        - Under pure Dart runtime (durability unconfirmed): 'spendx.db.pre_restore_backup'
          and journal are RETAINED INDEFINITELY.
```

---

## 6. Authoritative Universal Backup-Deletion Invariant

SpendX enforces **one universal backup-deletion invariant** across all restore, rollback, and recovery paths:

> [!CRITICAL]
> **Universal Backup-Deletion Invariant:** Under NO circumstances may `spendx.db.pre_restore_backup` be unlinked or deleted from disk unless **ALL** of the following conditions have been achieved:
> 1. **Active Database Present:** `spendx.db` exists at the live active database path.
> 2. **Content Verified:** `spendx.db` satisfies all 7 logical verification criteria (`isContentVerified == true`).
> 3. **Durability Confirmed:** Active database file flush, active database directory sync, verified journal file flush, and journal directory sync have all completed successfully (`isDurabilityConfirmed == true`).
> 4. **Native Directory Synchronization Available:** The runtime provides verified directory `fsync(dir_fd)` capabilities.
> 5. **Single Authorization Point (Point J):** Crash points prior to verified journal durability (Points A through I) **must never delete the backup**. The backup may **only** be deleted at **Point J**.
> 6. **Strict Retention Under Pure Dart / Sync Failure:** If directory synchronization is unavailable (standard Dart `dart:io`) or if directory synchronization fails (`EIO`), durability is **Durability Unconfirmed**. Under this condition, **backup deletion is STRICTLY FORBIDDEN**. Both `spendx.db.pre_restore_backup` and `spendx_restore_journal.json` **MUST BE RETAINED** on disk. Journal records `state: cleanupPending`.

---

## 7. Operation 7: Journal Deletion Contract Across All Paths

Operation 7 governs journal file cleanup (`spendx_restore_journal.json`):

1. **Path 1 — Native Directory Sync Available & Successful:**
   - Active DB is `contentVerified`.
   - Journal durability confirmed (`fsync()` on journal file + `fsync()` on parent directory).
   - Safety backup `spendx.db.pre_restore_backup` is unlinked, and parent directory is synced.
   - **Journal Deletion Authorized:** Journal file `spendx_restore_journal.json` is unlinked, and parent directory is synced.
   - Restore operation is 100% complete and finalized.
2. **Path 2 — Directory Sync Unavailable (Pure Dart Runtime):**
   - Active DB is `contentVerified` and operational.
   - However, durability is **Durability Unconfirmed**.
   - **JOURNAL DELETION STRICTLY FORBIDDEN.**
   - **SAFETY BACKUP DELETION STRICTLY FORBIDDEN.**
   - Journal records `state: cleanupPending` with `isDurabilityConfirmed: false` and is flushed to disk.
   - Safety backup and journal file remain **retained on disk**.
3. **Path 3 — Directory Sync Fails (I/O Error):**
   - If directory sync call fails at any point:
     - **JOURNAL DELETION STRICTLY FORBIDDEN.**
     - **SAFETY BACKUP DELETION STRICTLY FORBIDDEN.**
     - Retain all recoverable files and report filesystem error.
4. **Path 4 — Journal Unlink Succeeds But Directory Sync Fails:**
   - Unlink succeeded in kernel memory, but directory sync failed.
   - On reboot/restart, if journal is still visible (dentry rollback), journal state reads `cleanupPending`.
   - Recovery re-verifies active DB; does not re-restore. Re-attempts directory sync before declaring complete.
5. **Path 5 — Rollback Path Under Pure Dart:**
   - When original DB is restored from `spendx.db.pre_restore_backup` via non-destructive rollback:
     - Under pure Dart, journal is transitioned to `state: rolledBack`, `isCleanupPending: true` and **retained**.
     - Journal is never deleted without directory sync.

---

## 8. Platform-Specific Durability Policy Decision Table

| Filesystem Condition | Active DB Usable? | Backup Deletion Allowed? | Journal Deletion Allowed? | Journal State | Durability Classification | Recovery / Cleanup Action |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1. Native Directory Sync Available & Successful** | **YES** | **YES** (at Point J) | **YES** (after backup sync) | `contentVerified` $\rightarrow$ `durabilityConfirmed` $\rightarrow$ `cleared` | **Durability Confirmed** | Complete full cleanup: unlink backup, sync dir, unlink journal, sync dir. |
| **2. Directory Sync Unavailable (Pure Dart Runtime)** | **YES** | **STRICTLY FORBIDDEN** | **STRICTLY FORBIDDEN** | `contentVerified`, `cleanupPending` | **Durability Unconfirmed** | Restored DB is active. **Retain `spendx.db.pre_restore_backup` and `spendx_restore_journal.json`**. |
| **3. Directory Sync Fails (I/O Error / EIO)** | **NO** | **STRICTLY FORBIDDEN** | **STRICTLY FORBIDDEN** | `error` or `cleanupPending` | **Durability Unconfirmed** | **HALT IMMEDIATELY.** Retain all files. Report storage hardware error. |
| **4. File Flush Fails (I/O Error / ENOSPC)** | **NO** | **STRICTLY FORBIDDEN** | **STRICTLY FORBIDDEN** | `error` | **Durability Unconfirmed** | **ROLLBACK OR HALT SAFELY.** If active DB modified, restore original DB from backup via non-destructive staging copy. |
| **5. Journal Sync Fails After Flush** | **YES** | **STRICTLY FORBIDDEN** | **STRICTLY FORBIDDEN** | `contentVerified`, `cleanupPending` | **Durability Unconfirmed** | Retain backup and journal. Do not delete backup until journal durability confirmed. |
| **6. Backup Deletion Succeeds, Directory Sync Fails (Point K)** | **YES** | Already unlinked in VFS | **STRICTLY FORBIDDEN** | `cleanupPending` | **Durability Unconfirmed** | Keep journal in `cleanupPending`. On restart: re-validate active DB, reconcile backup status, retry dir sync. |
| **7. Rollback Executed (Directory Sync Unavailable)** | **YES** (original DB restored) | **STRICTLY FORBIDDEN** | **STRICTLY FORBIDDEN** | `rolledBack`, `cleanupPending` | **Durability Unconfirmed** | Original DB restored to `spendx.db`. Retain safety backup and journal to preserve recovery artifacts. |

---

## 9. Corrected Filesystem Recovery-State Matrix (Points A through K)

Artifacts inspected:
- Active DB ($A$): `spendx.db`
- Safety Backup ($B$): `spendx.db.pre_restore_backup`
- Restored Staging DB ($R$): `spendx.db.restored`
- Intent Marker ($I$): `spendx_restore_swap_<id>.intent`
- Done Marker ($D$): `spendx_restore_swap_<id>.done`
- Restore Journal State ($J$): `spendx_restore_journal.json`

| Crash Point | Filesystem State ($A, B, R, I, D, J$) | Physical Evidence & Proven Facts | Recoverable Database Identity | Authoritative Recovery Action | Backup & Journal Deletion Policy |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Point A**<br>Before staging creation | $A$ exists.<br>$B$ missing.<br>$R$ missing.<br>$I, D$ missing.<br>$J = \text{none}$. | No swap attempted. Active DB was never touched. | Active $A$ is only copy. | No-op. Active DB continues running. | No backup exists. |
| **Point B**<br>After staging validated | $A$ exists.<br>$B$ missing.<br>$R$ exists.<br>$I$ exists.<br>$D$ missing.<br>$J = \text{stagingCreated}$. | Active DB was never touched. $R$ is unswapped staging file. | Active $A$ is original database. $R$ is valid restored data. | Delete $R$, unlink $I$, clear journal $J$. Active DB $A$ remains intact. | No backup exists. |
| **Point C**<br>After $A \rightarrow B$ rename, before Dir Sync 1 | $A$ **MISSING**.<br>$B$ **EXISTS**.<br>$R$ **EXISTS**.<br>$I$ exists.<br>$D$ missing.<br>$J = \text{backupCreated}$. | $A$ was moved to $B$, but $R$ was **never renamed**. $A$ does not exist. | **$B$ is the ONLY copy of the original database.** $R$ is unswapped staging. | **Non-Destructive Rollback:** Create staging copy from $B$, place at $A$ using no-replace, validate $A$. Delete $R$, unlink $I$, retain $B$ until durability confirmed. | **STRICTLY FORBIDDEN.** $B$ is preserved; never deleted prematurely. |
| **Point D**<br>After Dir Sync 1, before $R \rightarrow A$ rename | $A$ **MISSING**.<br>$B$ **EXISTS**.<br>$R$ **EXISTS**.<br>$I$ exists.<br>$D$ missing.<br>$J = \text{swapping}$. | Same as Point C. $R$ was never renamed to $A$. | **$B$ is the ONLY copy of the original database.** | **Non-Destructive Rollback:** Create staging copy from $B$, place at $A$ using no-replace, validate $A$. Delete $R$, unlink $I$, retain $B$. | **STRICTLY FORBIDDEN.** $B$ is preserved; never deleted. |
| **Point E**<br>After $R \rightarrow A$ rename, before Dir Sync 2 | $A$ **EXISTS**.<br>$B$ **EXISTS**.<br>$R$ **MISSING**.<br>$I$ exists.<br>$D$ missing.<br>$J = \text{swapping}$. | $R$ was moved to $A$. $D$ was not written. | $B$ is original database. $A$ is candidate restored database. | Deep validate $A$.<br>- If $A$ valid: Advance $J \rightarrow \text{contentVerified}$. **Do NOT delete backup yet.**<br>- If $A$ corrupt: Quarantine $A$ using no-replace, execute non-destructive rollback from $B$, clear $J$.<br>- If identical fingerprints ($A=B=R$): **Preserve all, halt safely.** | **STRICTLY FORBIDDEN.** Backup deletion not permitted in Point E. |
| **Point F**<br>After Dir Sync 2, before $D$ creation | Same as Point E. | Same as Point E. | Same as Point E. | Same as Point E. Advance $J \rightarrow \text{contentVerified}$. | **STRICTLY FORBIDDEN.** Backup deletion not permitted in Point F. |
| **Point G**<br>After $D$ flush, before marker Dir Sync 3 | $A$ **EXISTS**.<br>$B$ **EXISTS**.<br>$R$ **MISSING**.<br>$I$ exists.<br>$D$ **EXISTS**.<br>$J = \text{swapping}$. | $D$ exists. Physical rename completed before crash. | $A$ is restored database. $B$ is safety backup. | Deep validate $A$. If valid: advance $J \rightarrow \text{contentVerified}$, unlink $I, D$. If $A$ corrupt: quarantine $A$ using no-replace, execute non-destructive rollback from $B$. | **STRICTLY FORBIDDEN.** Backup deletion not permitted in Point G. |
| **Point H**<br>After marker Dir Sync 3, before verified journal | Same as Point G. | Same as Point G. | Same as Point G. | Deep validate $A$. Advance $J \rightarrow \text{contentVerified}$, unlink $I, D$. | **STRICTLY FORBIDDEN.** Backup deletion not permitted in Point H. |
| **Point I**<br>After verified journal written, before journal Dir Sync 4 | $A$ **EXISTS**.<br>$B$ **EXISTS**.<br>$R$ **MISSING**.<br>$I, D$ may exist.<br>$J = \text{contentVerified}$. | Journal records `contentVerified`, but journal directory sync unconfirmed. | $A$ is content-verified restored database. | Confirm journal directory durability. **Do NOT delete backup until durability confirmed.** | **STRICTLY FORBIDDEN.** Backup deletion not permitted in Point I. |
| **Point J**<br>After journal durability achieved, before $B$ deletion | $A$ **EXISTS**.<br>$B$ **EXISTS**.<br>$R$ **MISSING**.<br>$J = \text{durabilityConfirmed}$. | All validation, journal advancement, and directory durability completed. | $A$ is durability-confirmed restored database. $B$ is lingering safety artifact. | **AUTHORITATIVE DELETION (Native):** If native directory sync available, safely delete $B$, sync dir, delete journal $J$, sync dir.<br>**PURE DART RUNTIME:** If directory sync unavailable, **RETAIN $B$ and $J$**; transition $J \rightarrow \text{cleanupPending}$. | **APPROVED FOR DELETION ONLY IF NATIVE DIR SYNC AVAILABLE.** Otherwise strictly forbidden. |
| **Point K**<br>During or after $B$ deletion / Dir Sync 5 failure | $A$ **EXISTS**.<br>$B$ partially deleted, missing, or rolled back.<br>$R$ missing.<br>$J = \text{durabilityConfirmed}$ or $\text{cleanupPending}$. | Backup unlink completed in memory, but directory sync failed or interrupted. | $A$ is verified restored database. | Transition $J \rightarrow \text{cleanupPending}$. On restart: re-validate $A$. If $B$ still present, retry unlink. Retry directory sync. Clear journal ONLY after directory sync durability confirmed. | Already unlinked in VFS; confirm durability before clearing journal. |

---

## 10. Historical Tag Migration Classification & Canonical Inventory (15 Tables)

### 10.1 Forensic Migration Audit Findings
1. **Source Implementation:**
   - In [`lib/data/migrations/migration_v24_service.dart`](file:///Users/sivek/Documents/SpendX/lib/data/migrations/migration_v24_service.dart#L404-L615), legacy rows from `transactions` were converted to `economic_events` and `postings`.
   - The field `tx['tags']` was completely ignored and never extracted or migrated.
   - Destination v24 tables (`economic_events` and `postings`) contain no tag columns, foreign keys, or junction tables.
2. **UI Implementation:**
   - [`TagManagementScreen`](file:///Users/sivek/Documents/SpendX/lib/screens/settings/tag_management_screen.dart#L1-L100) manages tag definitions in `tags` (`id`, `name`, `color`).
   - Transaction screens (`add_expense_screen.dart`, `import_preview_screen.dart`, `smart_importer.dart`) pass `tags: const []`.
3. **Defect Classification:**
   - The silent dropping of legacy transaction-tag associations during Migration v24 without user notification is classified as an **unresolved migration / data-retention finding**.
   - No evidence exists confirming this was an intentional product deprecation.
4. **Portable Backup Scope Separation:**
   - Current portable backup preserves the existing v24 state faithfully: it includes the 15 canonical tables, including all tag definitions in `tags`.
   - Portable backup cannot restore associations that were already lost prior to backup creation.
   - No speculative association tables or schema modifications are introduced in this milestone.

### 10.2 Canonical Table List (15 Tables)
1. `accounts` (20 cols)
2. `asset_earmarks` (4 cols)
3. `budgets` (4 cols)
4. `categories` (6 cols, including `user_id`)
5. `economic_events` (11 cols)
6. `evidence` (8 cols)
7. `expected_events` (6 cols)
8. `goals` (6 cols, including `notes`)
9. `merchant_rules` (5 cols)
10. `opening_balance_reconciliations` (9 cols)
11. `postings` (7 cols)
12. `recurring_rules` (10 cols)
13. `reminders` (11 cols, including `notes` and `description`)
14. `review_candidates` (8 cols)
15. `tags` (3 cols: `id`, `name`, `color`)

---

## 11. Platform Verification Status & Explicit Implementation Gate

### 11.1 Implementation Gate G-SEC-01-LOCK
Physical hardware lock lifecycle verification is formally recorded as an **Explicit Implementation Gate** that must be executed and passed on physical Android hardware prior to production release:

```text
[GATE G-SEC-01-LOCK: Physical Hardware Lock Lifecycle Verification]
Prerequisite for: Pillar 4.5A.2 Production Implementation & Release Merge
Target Platform: Android (API 26+) Physical Devices (iOS formally excluded under LIM-PLAT-01-IOS)
```

#### Lock Verification Matrix: Documented OS Semantics vs Architecture Expected vs Actual Results

| Test ID | Test Scenario | Documented OS / Runtime Semantics | Architecture-Level Expected Behavior | Actual Milestone Result | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Test L-01** | **Lease Timeout While Operation Still Running** | Dart VM isolate continues executing SQLite write loop; OS process and fd remain open. | Monotonic timer alone prohibited from reclaiming lease; lock retained; state classified as Indeterminate (`RestoreIndeterminateException`). | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-02** | **Engine Destruction While Native DB Work Active** | Host process remains alive; un-abortable SQLite C call still active in thread pool. | Fail-safe retention rule triggered: lock is NOT released merely because FlutterEngine was destroyed; descriptor kept open until process termination. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-03** | **Cancellation Failing to Stop Underlying Work** | Cancellation token signaled, but async SQLite transaction has not completed. | Host lease manager confirms native database quiescence; if not confirmed, lock is retained; operation drained before release. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-04** | **Two Independent Operations from Same Engine** | Engine A calls `acquire()`, then calls `acquire()` again before releasing. | Policy enforces strict rejection with `DUPLICATE_ACQUISITION_REJECTED`; second operation refused; active lease untouched. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-05** | **Duplicate Release While Another Operation Active** | Engine A calls `release(tokenA)` twice, or provides mismatched `tokenOld`. | Manager validates `leaseToken == activeLease.token`. Duplicate/stale release rejected safely; active lease remains fully protected; zero permit leaks. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-06** | **Tier 2 `tryLock()` Returning Null** | External process holds `fcntl` lock on `spendx_restore.lock`. Java `tryLock()` returns `null` without throwing exception. | Manager detects `null`; closes `FileChannel` descriptor immediately in `finally`; rolls back Tier 1 state to unlocked; returns `TIER2_LOCK_BUSY`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-07** | **Exceptions During Descriptor Close & Lease Release** | `FileChannel.close()` throws `IOException` during release sequence. | State transitions to `DESCRIPTOR_CLEANUP_FAILED`; does not claim cleanup succeeded; rejects new acquisitions. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-08** | **Process Death During Acquisition/Release Transitions** | Process receives `SIGKILL` during fd open, tryLock, or release. | OS kernel synchronously reclaims file descriptor table and clears POSIX `fcntl` locks across all transition points. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-09** | **Recovery from Indeterminate Restore State** | Operation entered indeterminate state; isolate force-killed. | Restart verifies isolate exit, inspects `spendx_restore_journal.json`, preserves unverified active DB in quarantine, restores safety backup. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-10** | **iOS Platform Execution** | iOS Darwin runtime lacks JVM; pure Dart lacks atomic cross-engine lock. | Formally rejected under `Limitation LIM-PLAT-01-IOS`; restore operation throws `PlatformNotSupportedException`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-11** | **Coordinator Isolate Exit While Native Worker Active** | Dart VM isolate terminates, but background native SQLite C thread is writing. | Quiescence check EC-04 fails; manager refuses to release lock or clear lease; state marked `INDETERMINATE`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-12** | **Engine Destruction While Plugin Queue Active** | `FlutterEngine` destroyed while `sqflite` `HandlerThread` has pending tasks. | Quiescence check EC-03 fails; manager retains OS lock until plugin tasks drain or process terminates. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-13** | **Cancellation Completes Before File I/O Drains** | Cancellation token reports done while disk write buffer is in-flight. | Quiescence check EC-05 fails; lock retained until all I/O futures and buffers complete. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-14** | **`FileLock.release()` Throws Exception** | OS release call fails with `IOException`. | Outcome B triggered: state transitions to `INDETERMINATE`; lease retained; new acquisitions blocked. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-15** | **`FileChannel.close()` Throws After Successful Release** | Lock released, but descriptor close throws `IOException`. | Outcome C triggered: state transitions to `DESCRIPTOR_CLEANUP_FAILED`; cleanup not claimed as succeeded. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-16** | **`FileChannel.close()` Throws During Acquisition Rollback** | `tryLock()` returns `null`; subsequent `channel.close()` throws `IOException`. | Rollback parity: state transitions to `DESCRIPTOR_CLEANUP_FAILED` rather than `UNLOCKED`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-17** | **Engine Destruction Between Descriptor Open & Lease Grant** | Engine detached during Transition 2 (`channel != null`, `fileLock == null`). | Manager closes descriptor; handles close failure if thrown; state reverts to `UNLOCKED` or `DESCRIPTOR_CLEANUP_FAILED`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-18** | **Process Termination at Each Acquisition Transition** | `SIGKILL` delivered during Transition 1, 2, 3, or 4. | Kernel cleans up open descriptors and locks synchronously across all four transitions. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-19** | **Recovery from Indeterminate Release State** | System in `INDETERMINATE` release state; new operation attempted. | Operation rejected; requires full process restart or verified native cleanup before retry. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-20** | **Database Access Gate Rejection of New Operations** | Caller attempts query while DAG-01 gate admission barrier is active (`restoreMode = true`). | Query rejected or blocked by gateway; in-flight counter unchanged; active restore protected. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-21** | **In-Flight Accounting Barrier Drain Timeout** | Active query hangs or fails to complete within 5-second drain window. | Gate aborts restore transition; returns `DatabaseBusyException`; live database remains intact. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-22** | **`sqlite3_close_v2` Zombie State File Lock Retention** | Connection closed while unfinalized prepared statement exists. | Native C engine keeps descriptor open; DAG barrier detects non-null stmt and blocks file replacement. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-23** | **Cross-Engine Background Task Rejection by Access Coordinator** | Auxiliary `FlutterEngine` (`notificationTapBackground`) attempts DB write during restore. | Host IPC barrier intercepts request; write rejected or queued until restore completes. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-24** | **`sqlite3_interrupt` Isolation to Single Connection** | Connection A interrupted during query; Connection B active concurrently. | Proves `sqlite3_interrupt` only affects Connection A; confirms necessity of explicit multi-connection barrier. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-25** | **Multi-Connection WAL Checkpoint Contention and TRUNCATE Failure** | Read connection open while main thread issues `PRAGMA wal_checkpoint(TRUNCATE)`. | Checkpoint returns `SQLITE_BUSY`; proves WAL cannot be truncated without closing all readers. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-26** | **`fsync` on File Descriptor Succeeded but Directory `fsync` Throws** | File data flushed; directory `fsync(dir_fd)` fails with `EIO`. | Durability classified as `Durability Unconfirmed`; safety backup retained with `state: cleanupPending`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-27** | **Unawaited Background Future Mutation Outliving Barrier** | Fire-and-forget `unawaited(finalizeLiveChoice(...))` invoked right before restore. | Pillar 4.5A.2 prohibition enforced; unawaited calls eliminated; barrier accounting accounts for all ops. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |

---

## 12. Planned Acceptance Evidence Status

| Metric | Status |
| :--- | :--- |
| **Specified Test Scenarios** | **88 Scenarios** across 6 Groups |
| **Planned Test Cases** | **108 Planned Test Cases** |
| **Tests Executed in Milestone** | **0 (Zero)** — Documentation and architecture design only |
| **Harness Execution Status** | Reproduction command exited with code 127 (`operation not permitted: flutter` under sandbox) |
| **Production Code Status** | **0 lines modified** — No production implementation started |
| **Pass / Regression Verdict** | **Pending future implementation** (No claims of 100% pass or zero regressions) |

---

## 13. Independent Risk Assessment

An independent architectural risk evaluation was conducted across the portable-backup subsystem:

1. **Physical Hardware Lock Contention (High Residual Risk — Gated):**
   - *Risk:* Dart VM POSIX `fcntl` semantics and Android ART JVM `FileChannel.lock()` interactions have not been validated on physical Android hardware due to build harness sandbox constraints.
   - *Mitigation:* Formally gated under `Gate G-SEC-01-LOCK`. Production merge is strictly blocked until physical device tests L-01 through L-27 pass.
2. **Current Repository Coordinator Bypass (High Residual Risk — Implementation Pending):**
   - *Risk:* 15 repositories currently bypass `DatabaseLifecycleCoordinator` and call `AppDatabase.instance.database` directly.
   - *Mitigation:* DAG-01 protocol specifies required production changes for Pillar 4.5A.2: centralized admission gateway, elimination of unawaited futures, and cross-engine IPC barriers.
3. **Crash During Unsynchronized Directory Fallback (Medium Residual Risk):**
   - *Risk:* In pure Dart runtimes where native directory `fsync` is unavailable, sudden power loss during rename may leave directory metadata uncommitted.
   - *Mitigation:* Durability status is explicitly recorded as `Durability Unconfirmed`; safety backups and journal are retained with `state: cleanupPending`.
4. **Low-Memory Device KDF Exhaustion (Low Residual Risk):**
   - *Risk:* Argon2id parameter negotiation (64 MiB RAM) could trigger Android OS LMK (Low Memory Killer) on budget devices (1 GB RAM).
   - *Mitigation:* Hard bounds (8..128 chars, max 64 MiB, max 10 iterations) enforced before KDF invocation; memory allocation monitored.
5. **iOS Platform Exclusion (Managed Release Limitation):**
   - *Risk:* Cross-platform expectations from iOS users.
   - *Mitigation:* Formally documented under `Limitation LIM-PLAT-01-IOS`; clear user-facing error messaging prevents silent corruption.
