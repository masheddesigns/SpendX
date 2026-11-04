# SpendX Release Readiness — Pillar 3: Data Integrity, Backup & Restore Discovery

**Document Version:** 1.0.0
**Date:** November 4, 2026
**Target Release:** SpendX 2.1.0
**Phase:** Pillar 3 Discovery & Audit Mapping
**Status:** Discovery Complete — Production Code Frozen

---

## 1. Architectural Scope & Core Components

Pillar 3 validates that SpendX guarantees zero data corruption, atomic durability, lossless backup/restore round-trips, and safe crash recovery across all storage layers.

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Storage & Encryption Layer                               │
│    - SQLite v24 via SQLCipher (SpendXDatabaseFactory)       │
│    - PRAGMA foreign_keys = ON, PRAGMA journal_mode = WAL    │
│    - PRAGMA synchronous = NORMAL / FULL                     │
│    - Key derivation via DatabaseKeyManager                  │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Lifecycle Coordination & Write Synchronization           │
│    - DatabaseLifecycleCoordinator (Mutual Exclusion)        │
│    - States: active, migrating, backingUp, restoring, closed│
│    - WriteQueue: quiesces writes during snapshot/restore    │
│    - Crash recovery: DatabaseEncryptionMigrationService     │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Canonical Backup & Restore Engine                        │
│    - BackupService.createBackup() / restoreFromFile()       │
│    - Atomic point-in-time snapshot via VACUUM INTO          │
│    - CanonicalBackupValidator: integrity, FKs, parity       │
│    - Staged restore with automatic rollback on error        │
│    - 30-day raw SMS privacy sanitization                    │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Data Export, Import & Deduplication Engine               │
│    - ExportService: CSV & JSON full transaction export      │
│    - ImportService.importGenericCSV(): canonical ingestion  │
│    - Deterministic SHA-256 evidence fingerprint deduplication│
│    - Zero duplicate records on repeated import or restore   │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Six Target Audit Areas & Verification Criteria

### 1. SQLite Database Integrity & Transaction Atomicity
- **Integrity Check:** `PRAGMA integrity_check` and `PRAGMA quick_check` report `ok`.
- **Foreign Keys:** `PRAGMA foreign_keys = ON` strictly enforced across all database connections.
- **Trigger Hardening:** Immutable triggers on `economic_events` and `postings` prevent out-of-band updates/deletions.
- **Atomicity:** All multi-posting financial writes occur inside atomic database transactions (`db.transaction(...)`). Any constraint violation rolls back all legs completely.

### 2. Backup Creation & Restore Correctness
- **Point-in-Time Snapshot:** `VACUUM INTO` creates a consistent, non-locking snapshot without partial writes.
- **Manifest Integrity:** `manifest.json` contains SHA-256 hash of `spendx.db`, device ID, schema version, and timestamp.
- **Validation Pipeline:** `CanonicalBackupValidator` verifies zip structure, schema version (v24), foreign keys, balanced postings ($\sum \text{debits} == \sum \text{credits}$), non-negative amounts, and checksum before replacing the active database.
- **State Invalidation:** Centralized Riverpod provider invalidation ensures UI immediately displays restored data without app restart.

### 3. Data Export/Import Round-Trip Accuracy
- **CSV / JSON Export:** Full fidelity export of transactions, categories, dates, amounts, and metadata.
- **Minor Units Representation:** Decimal rupees format accurately to minor units (paise) without floating-point drift.
- **Account & Category Mapping:** Exported references resolve correctly back to system or custom entities.

### 4. Duplicate Records After Restore or Repeated Imports
- **Repeated Backup Restores:** Restoring the same backup multiple times is idempotent and replaces state deterministically.
- **Repeated CSV Imports:** Importing the same CSV file twice produces 0 duplicate transactions via SHA-256 evidence deduplication (`importService.importGenericCSV`).
- **External Reference Constraints:** Duplicate `externalRef` entries are rejected or ignored.

### 5. App Upgrades & Migration Safety
- **Schema Version Guarding:** Restoring backups with schema version $\neq 24$ is rejected without touching the active database.
- **Migration Idempotency:** Migration scripts (v23 $\rightarrow$ v24) can run repeatedly without altering existing valid data or corrupting ledger state.
- **Orphan Rejection:** Migration backfill aborts with complete rollback if unresolvable orphan records are detected.

### 6. Crash Recovery & Interrupted Write Resilience
- **Lifecycle Coordination:** `DatabaseLifecycleCoordinator` throws `DatabaseLifecycleConflictException` if a concurrent destructive operation is attempted.
- **Interrupted Migration Recovery:** `recoverInterruptedMigration` detects `.migrating` / `.bak` temporary files left by crashes and restores database integrity.
- **WAL Journal Replay:** SQLite WAL files automatically replay uncommitted journal checkpoints upon subsequent connection initialization.
- **Staging Cleanup:** Aborted or corrupted restore packages leave the active database 100% untouched and clean up temporary staging directories.

---

## 3. Existing Test Coverage Inventory

SpendX already contains comprehensive automated test suites for Pillar 3:
1. [`test/features/c8_canonical_backup_restore_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/c8_canonical_backup_restore_test.dart) — **36 tests**:
   - Round-trip fidelity (empty DB, multi-account, income, expense, transfer, CC purchase, CC payment, refund, loans, goals, recurring rules, review candidates, evidence fingerprints, opening balances).
   - Validation & error handling (corrupted zip, 0-byte package, invalid schema version, FK violation, unbalanced postings, non-positive amounts, SHA-256 mismatch, legacy format 1 rejection).
   - Atomic rollback, staging directory cleanup, WAL checkpointing, privacy sanitization, and state invalidation.
2. [`test/features/c11_database_migration_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/c11_database_migration_test.dart) — **26 tests**:
   - Migration idempotency, schema versioning, backup creation before migration, and restore validation.
3. [`test/features/c12_p2_lifecycle_coordination_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/c12_p2_lifecycle_coordination_test.dart) — **7 tests**:
   - Mutual exclusion across active, migrating, backingUp, and restoring states.
4. [`test/features/c9_legacy_retirement_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/c9_legacy_retirement_test.dart) — **30 tests**:
   - CSV import deduplication, zero writes to legacy tables, review queue staging.

---

## 4. Next Step: Pillar 3 Verification Matrix

We will execute the existing suites, identify any edge-case gaps (specifically CSV round-trip export/import and simulated crash recovery), construct targeted verification tests if needed, and compile a complete audit report.
