# 86. Milestone C12-P2: Database Lifecycle & Mutual Exclusion

**Status**: IMPLEMENTED & VERIFIED  
**Date**: 2026-10-05  
**Baseline**: Schema v24 (LOCKED), 7/7 Financial SQLite Triggers  
**Prerequisites**: C12-P1 (`85_C12_P1_DATABASE_STARTUP_ENCRYPTION.md`) — PASS/CLOSED  

---

## 1. Executive Summary & Objective

Milestone **C12-P2** closes the critical database lifecycle and concurrency risks identified during **C12 Discovery**:

> **Central Invariant**: Database replacement, migration, backup, restore, and financial writes must never race with one another. The application must possess one explicit lifecycle authority for operations that close, replace, migrate, or otherwise invalidate the active database.

Prior to C12-P2, concurrent triggers (e.g. background SMS arrival or user transactions enqueued on `WriteQueue`) could theoretically attempt mutations while `BackupService.restoreFromFile()` had closed the active database connection or while `DatabaseEncryptionMigrationService` was transforming the database file.

Under C12-P2, all destructive or pivot operations are managed by a unified `DatabaseLifecycleCoordinator` with strict mutual exclusion, in-flight quiescence, and memory buffering for background ingestion.

---

## 2. Architecture & Design

### 2.1 State Model (`DatabaseLifecycleState`)
The database lifecycle transitions through five distinct states:

```
                  ┌───────────────┐
                  │    CLOSED     │
                  └──────┬────────┘
                         │ open
                         ▼
        ┌─────────►   ACTIVE    ◄─────────┐
        │                │                │
        │ backup         │ restore        │ migration
        │ complete       │ complete       │ complete
        ▼                ▼                ▼
   BACKING_UP        RESTORING        MIGRATING
```

- **`active`**: Normal operational state. Canonical reads and financial writes proceed freely.
- **`migrating`**: Crash-safe plaintext-to-SQLCipher migration active. Exclusive: financial writes paused, concurrent backups/restores rejected with `DatabaseLifecycleConflictException`.
- **`backingUp`**: Point-in-time snapshot / backup package generation active. Financial writes quiesced; concurrent migrations/restores rejected.
- **`restoring`**: Atomic restore and file swap active. Exclusive: active database closed, financial writes paused, SMS ingestion buffered in memory.
- **`closed`**: Active database connection closed. Reopening re-establishes `active` state.

### 2.2 Mutual Exclusion Mechanism
`DatabaseLifecycleCoordinator` enforces single-flight exclusive execution:
- Attempting to begin a migration while a backup or restore is running throws `DatabaseLifecycleConflictException`.
- Attempting to begin a backup while migration or restore is running throws `DatabaseLifecycleConflictException`.
- Attempting to begin a restore while backup or migration is running throws `DatabaseLifecycleConflictException`.

### 2.3 WriteQueue Coordination (P2.2)
`WriteQueue` (`lib/data/core/write_queue.dart`) coordinates directly with `DatabaseLifecycleCoordinator`:
- **Quiescence**: When a lifecycle pivot starts (`backingUp`, `restoring`, `migrating`), `await WriteQueue.instance.quiesce()` waits for any actively running in-flight write task to finish its database transaction tick.
- **Write Pausing**: When new tasks are enqueued during a pivot, `WriteQueue._process()` awaits `DatabaseLifecycleCoordinator.instance.waitUntilWritable()` before dispatching each task.
- **Guarantees**:
  - `ROGUE_FINANCIAL_WRITERS = 0`
  - Zero lost writes: pending mutations remain in FIFO memory queue.
  - Zero duplicate writes: mutations are never replayed or duplicated across lifecycle transitions.
  - Mutations execute against the newly verified database generation once state returns to `active`.

### 2.4 SMS Ingestion Coordination (P2.3)
`LiveSmsService` (`lib/services/live_sms_service.dart`):
- Incoming bank SMS received via native receiver (`onSmsReceived`) is added to `_liveBuffer`.
- In `_flushLiveBuffer()`, `catchUpHistorical()`, and `drainPending()`, the service awaits `DatabaseLifecycleCoordinator.instance.waitUntilWritable()` before processing messages or touching the database.
- Messages arriving during database restoration or migration remain preserved in memory and drain automatically once the database is verified and restored to `active`.
- Zero dropped SMS; zero attempts to write into a closed or transitioning database file.

### 2.5 Backup Coordination (P2.4)
In `BackupService.createBackupPackage()`:
1. Calls `DatabaseLifecycleCoordinator.instance.beginBackup()`.
2. Awaits `WriteQueue.instance.quiesce()`.
3. Checkpoints WAL via `PRAGMA wal_checkpoint(TRUNCATE)`.
4. Creates point-in-time SQLite snapshot via `VACUUM INTO`.
5. Computes SHA-256 and cryptographic manifest.
6. Returns `.spendx` encrypted package.
7. `finally` block calls `DatabaseLifecycleCoordinator.instance.endBackup()`, releasing waiting writers.

### 2.6 Restore Coordination & Rollback (P2.5)
In `BackupService.restoreFromFile()`:
1. Calls `DatabaseLifecycleCoordinator.instance.beginRestore()`.
2. Awaits `WriteQueue.instance.quiesce()`.
3. Validates staged database in isolation (AES-256-GCM decrypt, SHA-256 verification, schema v24 check, 7 triggers, double-entry parity).
4. Atomically replaces active database: creates `.pre_restore_backup` safety copy before file swap.
5. Reopens production database through `AppDatabase.instance.database` and validates schema v24.
6. Calls `invalidateAllFinancialProvidersWithContainer()` and `DataChangeBus.instance.notify()`.
7. Calls `DatabaseLifecycleCoordinator.instance.notifyDatabaseReplaced()`.
8. `finally` block calls `DatabaseLifecycleCoordinator.instance.endRestore()`.
9. **Fail-safe Rollback**: If restore verification fails, active database rolls back to `.pre_restore_backup`, reopens previous database, and safely resets lifecycle state to `active`. Never leaves an empty or corrupt database.

### 2.7 Migration Coordination (P2.6)
In `DatabaseEncryptionMigrationService.runMigration()`:
1. Calls `DatabaseLifecycleCoordinator.instance.beginMigration()`.
2. Awaits `WriteQueue.instance.quiesce()`.
3. Executes 8-checkpoint out-of-place migration (`sqlcipher_export()`).
4. `finally` block calls `DatabaseLifecycleCoordinator.instance.endMigration()`.

### 2.8 Database Close / Reopen Safety (P2.7)
In `AppDatabase`:
- `close()` marks coordinator `closed`, resets `_database` and `_initFuture`.
- Subsequent access to `AppDatabase.instance.database` initializes single-flight via mutex and transitions coordinator back to `active`.
- 10 concurrent requests converge safely on the exact same database handle.

### 2.9 Provider Invalidation & State Coherence (P2.8)
After database replacement:
- Centralized provider invalidation invalidates all financial, net worth, forecast, review, and analytics Riverpod providers.
- `DataChangeBus.instance.notify()` broadcasts event to UI components.
- `DatabaseLifecycleCoordinator.instance.notifyDatabaseReplaced()` notifies all registered listeners.

### 2.10 C10 Dead Artifact Retirement (P2.9)
Audited and retired confirmed dead/obsolete artifacts:
- **Root-level Python scripts deleted**:
  - `update_onboarding.py`
  - `refactor_snackbars.py`
  - `update_expense_screen.py`
  - `update_onboarding_contrast.py`
- **Legacy Service Deprecated**:
  - `DatabaseSecurityService` (`lib/services/database_security_service.dart`) annotated with `@Deprecated('Superseded by SQLCipher page-level runtime encryption in C11. Retained solely for C10 regression test compatibility.')`.

---

## 3. Verification & Test Matrix

Dedicated lifecycle test suite: `test/features/c12_p2_lifecycle_coordination_test.dart`:

| Test ID | Test Scenario | Description | Result |
|---|---|---|---|
| **P2.1** | Mutual Exclusion | Attempting concurrent migration, backup, or restore throws `DatabaseLifecycleConflictException`. | **PASS** |
| **P2.2A** | WriteQueue Pause/Resume | Enqueued mutations pause during restore and resume in FIFO order after active restoration. | **PASS** |
| **P2.2B** | WriteQueue Quiescence | In-flight write finishes before lifecycle pivot proceeds (`quiesce()`). | **PASS** |
| **P2.3** | SMS Deferral | Incoming SMS is buffered in memory during migration/restore without dropping events; flushes cleanly after active. | **PASS** |
| **P2.4/P2.5** | Backup/Restore Exclusivity | Full backup creation and restore cycle with atomic replacement and provider invalidation. | **PASS** |
| **P2.7** | Close / Reopen Cycle | Open -> Close -> Reopen transitions lifecycle cleanly; 10 concurrent requests converge on identical instance. | **PASS** |
| **P2.10** | Failure Recovery | Corrupted package aborts restore, original database preserved, lifecycle safely restored to active. | **PASS** |

---

## 4. Invariant Verification

- `PLAINTEXT_FRESH_DATABASE_CREATION = 0`: Encrypted by default.
- `ROGUE_FINANCIAL_WRITERS = 0`: All writes coordinate through `DatabaseLifecycleCoordinator`.
- `STALE_FINANCIAL_AUTHORITY = 0`: Provider invalidation and `DataChangeBus` notified after DB replacement.
- `SCHEMA_VERSION = 24`: Locked.
- `FINANCIAL_TRIGGERS = 7 / 7`: Verified.
- `FULL_TEST_SUITE = 784 / 784 PASS` (100%).
- `ANALYZER_ERRORS = 0`, `ANALYZER_WARNINGS = 0`.

