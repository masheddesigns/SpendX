# SpendX 2.0 — Milestone C8 Architectural Gate
## Canonical Backup & Restore — Discovery & Architectural Audit

**Document ID**: `SPENDX2-C8-GATE-001`  
**Status**: DISCOVERY COMPLETE — AUTHORIZATION REQUIRED  
**Date**: October 4, 2026  
**Milestone**: C8 — Canonical Backup & Restore  
**SQLite Schema Version**: v24 (LOCKED)  
**Database Triggers**: 7/7 ACTIVE  
**Current Baseline**: 607 / 607 PASS | Analyzer: 0 Errors, 0 Warnings  

---

## 1. Status & Executive Overview

Milestone C8 Discovery is **COMPLETE**.

An exhaustive audit of SpendX's current backup, restore, export, import, synchronization, serialization, and database lifecycle surfaces has been conducted. 

### Core Discovery Finding
SpendX currently suffers from an **existential data-loss vulnerability** in its backup and restore layer:
1. `BackupService`, `BackupFileService`, and `DatabaseHelper.getFullSnapshot()` / `restoreFromSnapshot()` were authored for the pre-C3 schema and **completely omit all canonical v24 tables** (`accounts`, `economic_events`, `postings`, `evidence`, `asset_earmarks`, `recurring_rules`, `expected_events`, `review_candidates`, `opening_balance_reconciliations`, `migration_exceptions`).
2. Backups created today back up only legacy tables (`transactions`, `bank_accounts`, `credit_cards`, etc.).
3. Restoring a backup today clears and replaces legacy tables, but **leaves the canonical ledger untouched or corrupted with broken foreign keys**, or fails mid-transaction due to SQLite trigger constraints and foreign key enforcement.
4. `SyncEngine` is configured to run auto-restores in the background on app resume/launch if `autoRestoreEnabled` is set, presenting an immediate threat of silent ledger corruption.
5. `DatabaseHelper.restoreFromSnapshot()` catches and swallows all insert errors silently in a `try-catch` block (`catch (_) {}`).
6. Zero tests exist in the entire repository for `BackupService`, `BackupFileService`, `ExportService`, or `restoreFromSnapshot()`.

**Verdict on Candidate Objective**:
**Canonical Backup & Restore IS without question the single highest-value architectural bottleneck remaining in SpendX.** It must be the authorized scope for Milestone C8.

---

## 2. Locked Baseline

The following architectural milestones are formally **CLOSED** and must remain strictly protected:
- **C3A / C3A.1 — Canonical Foundation**: Double-entry ledger, immutable events, postings, Money value object.
- **C3B-1 through C3B-7 — Write Firewall**: Zero direct accounting writes outside `FinancialTransactionService`.
- **C4-0 through C4-7 — Read Firewall**: `ILLEGAL_STALE_AUTHORITY = 0`. Canonical ledger is sole financial truth.
- **C5 — Multi-Evidence Ingestion & Deduplication**: Pre-approval isolation; deterministic SHA-256 & UTR deduplication; 30-day raw SMS retention policy.
- **C6 — Deterministic Forecast Engine**: Single authoritative `CanonicalForecastEngine`.
- **C7 — Riverpod State Consolidation**: Unified reactive graph, cache poisoning eliminated, split-brains resolved.
- **SQLite Schema**: v24 LOCKED; 7/7 active triggers enforcing ledger balance, non-negative amounts, and posting immutability.
- **Full Test Baseline**: 607 / 607 PASS; Analyzer clean (0 errors, 0 warnings).

---

## 3. Current Backup Inventory

| Surface / File | Mechanism | Tables / Data Handled | Flaws / Architectural Risks |
| :--- | :--- | :--- | :--- |
| `lib/services/backup_service.dart`<br>`backupNow()` | JSON serialization + XOR stream cipher + Drive upload | Calls `BackupFileService.createBackupJson()` | Does not pause incoming writes; ignores v24 canonical tables; runs on main thread for DB read. |
| `lib/services/backup_file_service.dart`<br>`createBackupJson()` | Calls `DatabaseHelper.getFullSnapshot()`, encodes JSON in isolate | 33 legacy tables | **Omits 100% of v24 canonical tables.** Ignores `economic_events`, `postings`, `accounts`, `evidence`, etc. |
| `lib/services/database_helper.dart`<br>`getFullSnapshot()` | Iterates hardcoded list of 33 tables, reads `db.query(table)` | Legacy tables, including deleted `vehicles`, `fuel_logs` | Missing all 10 canonical v24 tables. Reads obsolete tables dropped in C2C. |
| `lib/data/migrations/migration_v24_service.dart`<br>`createPreMigrationBackup()` | `PRAGMA wal_checkpoint(TRUNCATE)` + `VACUUM INTO '$backupPath'` | Full SQLite database file | **The only architecturally sound backup routine in the codebase.** Preserves exact binary database state. |

---

## 4. Current Restore Inventory

| Surface / File | Mechanism | Tables / Data Handled | Flaws / Architectural Risks |
| :--- | :--- | :--- | :--- |
| `lib/services/backup_service.dart`<br>`restoreFromDrive()`, `restoreFromFile()` | Downloads JSON, decrypts, parses, calls `_restoreTables()` | Legacy snapshot tables | Wipes and restores legacy tables; leaves canonical v24 tables completely untouched; causes split-brain state. |
| `lib/services/database_helper.dart`<br>`restoreFromSnapshot()` | Single transaction: `txn.delete(tableName)` then `txn.insert(tableName, row)` | 33 legacy tables | Swallows all insert errors silently (`catch (_) {}`). Random table deletion order causes foreign key constraint failures. If v24 triggers were present, direct inserts of posted events would fail (`trg_economic_events_prevent_direct_posted_insert`). |
| `lib/services/sync_engine.dart`<br>`_evaluateSyncState()` | Auto-restores on launch/resume if remote timestamp > local | Invokes `restoreFromDrive()` | Automatic silent background restoration of defective legacy backups without user confirmation or validation. |

---

## 5. Export / Import Inventory

| Surface / File | Format | Read Authority | Write Authority | Architectural Risk |
| :--- | :--- | :--- | :--- | :--- |
| `lib/services/export_service.dart`<br>`exportFullBackup()` | JSON file picker | `BackupFileService.createBackupJson()` | None | Exports defective legacy snapshot missing v24 tables. |
| `lib/services/export_service.dart`<br>`exportTransactionsToCsv()` | CSV | `TransactionRepo.getAll()` | None | Export only (acceptable presentation format). |
| `lib/services/export_service.dart`<br>`exportTransactionsToJson()` | JSON | `TransactionRepo.getAll()` | None | Export only. |
| `lib/services/export_service.dart`<br>`importTransactionsFromCsv()` | CSV | File | `TransactionRepo.insert()` | Direct write; creates canonical events via adapter but bypasses C5 evidence/review pipeline. |
| `lib/services/import_service.dart`<br>`importFromFile()` | JSON | `BackupService.restoreFromFile()` | Legacy restore | Delegates to defective legacy restore. |
| `lib/services/import_service.dart`<br>`importGenericCSV()` | CSV | File | `TransactionRepo.insert()` + `LedgerRepo.insert()` | Direct write to legacy `ledger_transactions` (v19) and `TransactionRepo`. |
| `lib/services/smart_importer.dart` | Notion ZIP / CSV | File | `TransactionRepo.insert()` | Bypasses C5 ReviewQueue; creates direct transactions. |

---

## 6. Data-Surface Classification

Every table and persisted data entity in SpendX classified by data authority:

| Surface / Table | Classification | Authority in Backup | Authority in Restore |
| :--- | :--- | :---: | :---: |
| `accounts` | `CANONICAL_FINANCIAL` | AUTHORITATIVE | MUST RESTORE |
| `economic_events` | `CANONICAL_FINANCIAL` | AUTHORITATIVE | MUST RESTORE |
| `postings` | `CANONICAL_FINANCIAL` | AUTHORITATIVE | MUST RESTORE |
| `evidence` | `CANONICAL_EVIDENCE` | AUTHORITATIVE (subject to 30-day purge) | MUST RESTORE (purged payloads remain purged) |
| `review_candidates` | `CANONICAL_REVIEW` | AUTHORITATIVE NON-ACCOUNTING | MUST RESTORE AS DRAFT/REVIEW ONLY |
| `asset_earmarks` | `CANONICAL_METADATA` | AUTHORITATIVE | MUST RESTORE |
| `recurring_rules` | `CANONICAL_EXPECTATION` | AUTHORITATIVE | MUST RESTORE |
| `expected_events` | `CANONICAL_EXPECTATION` | AUTHORITATIVE | MUST RESTORE |
| `opening_balance_reconciliations` | `CANONICAL_METADATA` | AUTHORITATIVE AUDIT | MUST RESTORE |
| `migration_exceptions` | `MIGRATION_ONLY` | AUDIT ONLY | MAY RESTORE |
| `categories`, `tags`, `budgets` | `CANONICAL_METADATA` | AUTHORITATIVE METADATA | MUST RESTORE |
| `goals`, `reminders`, `salary_*` | `CANONICAL_METADATA` | AUTHORITATIVE METADATA | MUST RESTORE |
| `streaks`, `challenges`, `achievements` | `CANONICAL_METADATA` | AUXILIARY METADATA | MUST RESTORE |
| `net_worth_history`, `health_score_history` | `CANONICAL_DERIVED_CACHE` | DERIVED CACHE | OPTIONAL (can be recomputed) |
| `transactions`, `ledger_transactions` | `TRANSITIONAL_LEGACY` | COMPATIBILITY MIRROR | DO NOT USE AS FINANCIAL AUTHORITY |
| `credit_cards`, `loans`, `bank_accounts` | `TRANSITIONAL_LEGACY` | COMPATIBILITY MIRROR | RESTORE MIRRORS FROM CANONICAL |
| `credit_transactions`, `loan_installments` | `TRANSITIONAL_LEGACY` | COMPATIBILITY MIRROR | DO NOT USE AS FINANCIAL AUTHORITY |
| `ledger_backfill_flags`, `ledger_backfill_log` | `MIGRATION_ONLY` | OPERATIONAL FLAGS | RESTORE UNCHANGED |
| `SharedPreferences` (settings, preferences) | `UI_STATE` | METADATA CONTAINER | SELECTIVELY RESTORE |

---

## 7. Canonical Backup Model (Option A vs B vs C)

### Evaluation of Options:
- **Option A (Raw SQLite File Copy)**:
  - Fails if WAL mode is active without prior checkpoint.
  - Vulnerable to restoring corrupt or incompatible database files directly over live state.
- **Option B (Logical JSON Export of Tables)**:
  - **FATAL FLAW**: Trigger `trg_economic_events_prevent_direct_posted_insert` forbids inserting rows with `lifecycle_status = 'posted'`. Any table-by-table SQL or JSON re-insertion will be immediately ABORTED by SQLite triggers.
  - Deferring or disabling triggers compromises double-entry invariant enforcement.
  - JSON serialization of thousands of postings risks memory exhaustion (OOM) and numeric precision degradation.
- **Option C (Hybrid: Atomic SQLite Snapshot with Verified Container Manifest) — RECOMMENDED**:
  - **Authoritative Snapshot**: Generated atomically via SQLite's native `PRAGMA wal_checkpoint(TRUNCATE)` followed by `VACUUM INTO '$stagingPath'`.
  - **Deterministic Container**: A packaged archive (`.spendx` container) containing:
    1. `spendx.db` (clean, compact, validated SQLite snapshot).
    2. `manifest.json`:
       - `backup_format_version`: 2
       - `app_version`: String
       - `schema_version`: 24 (LOCKED)
       - `created_at`: ISO-8601 UTC
       - `sha256_checksum`: SHA-256 of `spendx.db`
       - `record_counts`: `{accounts: N, events: N, postings: N, evidence: N, ...}`
       - `financial_checksum`: `{total_debit_minor: N, total_credit_minor: N, net_balance: 0}`
       - `settings`: Synced user preferences.
  - **Why Option C is Safest**:
    - Operates at native SQLite engine level; triggers remain 100% active.
    - Zero impedance mismatch between relational double-entry schema and intermediate formats.
    - Staged and validated hermetically in an isolated environment before active database is touched.

---

## 8. Legacy Data Treatment

### Invariant: Restored Legacy Data Must Never Become Financial Authority
1. When restoring via Option C snapshot:
   - The snapshot contains both canonical tables and legacy transitional mirror tables.
   - Because C4 established `ILLEGAL_STALE_AUTHORITY = 0`, all application reads consume canonical repositories (`CanonicalFinancialQueryRepository`, `CanonicalAccountRepository`, etc.).
   - Legacy tables act strictly as compatibility mirrors for third-party widgets or legacy screens.
2. In the event of a legacy-only backup being imported (Backup Format Version 1):
   - The restore engine must **REJECT** Version 1 backups as direct database replacements.
   - Version 1 backups must either be migrated through `MigrationV24Service` in an isolated staging database or rejected with a clear upgrade path.

---

## 9. Identity & Foreign Key Audit

### Key Relationships in Schema v24:
```
accounts (id: TEXT UUID)
   ▲
   ├── postings (account_id) [RESTRICT]
   ├── asset_earmarks (asset_account_id) [RESTRICT]
   ├── recurring_rules (category_account_id, target_account_id) [RESTRICT]
   ├── review_candidates (suggested_account_id) [SET NULL]
   └── opening_balance_reconciliations (account_id) [CASCADE]

economic_events (id: TEXT UUID)
   ▲
   ├── postings (economic_event_id) [CASCADE]
   ├── evidence (economic_event_id) [CASCADE]
   ├── expected_events (fulfilled_event_id) [SET NULL]
   └── opening_balance_reconciliations (generated_event_id) [SET NULL]

recurring_rules (id: TEXT UUID)
   ▲
   └── expected_events (rule_id) [CASCADE]
```

### Identity Rules on Restore:
- **Primary Keys are Globally Stable**: All canonical IDs are UUIDs. They must **NEVER** be regenerated upon restore.
- **Foreign Keys**: Must satisfy `PRAGMA foreign_key_check` with **0 violations** before staged database is promoted to active.
- **External References**: Deduplication constraints on `evidence.body_sha256` and `evidence.external_reference` must remain strictly enforced.

---

## 10. Backup Versioning Model

```json
{
  "backup_format_version": 2,
  "app_name": "SpendX",
  "app_version": "2.0.0",
  "schema_version": 24,
  "created_at": "2026-10-04T19:30:00Z",
  "device_id": "uuid-here",
  "db_sha256": "abcdef...",
  "financial_invariants": {
    "total_events": 1420,
    "total_postings": 2840,
    "balanced_parity_check": true
  }
}
```

### Version Compatibility Rules:
1. `backup_format_version == 2` AND `schema_version == 24`: Fully supported, direct atomic restore.
2. `schema_version < 24`: Unsupported for direct restore; requires staged migration via `MigrationV24Service`.
3. `schema_version > 24`: Strictly **REJECTED** ("Backup from newer SpendX version cannot be restored").
4. `backup_format_version == 1` (Legacy JSON): Detected and routed to legacy import or rejected.

---

## 11. Corruption & Tamper Detection

1. **Archive Integrity**: Unzipping/unpacking container verifies CRC/file lengths.
2. **Cryptographic Checksum**: SHA-256 of `spendx.db` calculated and compared against manifest `db_sha256`.
3. **SQLite Low-Level Check**: `PRAGMA integrity_check` executed on staged database; must return exactly `ok`.
4. **Relational Integrity Check**: `PRAGMA foreign_key_check` executed on staged database; must return empty list.
5. **Double-Entry Accounting Check**:
   ```sql
   SELECT SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE -amount_minor_units END) AS imbalance
   FROM postings p
   JOIN economic_events e ON p.economic_event_id = e.id
   WHERE e.lifecycle_status = 'posted';
   ```
   Must evaluate to exactly `0` (or `NULL` if empty).

---

## 12. Restore Safety Model

### Merge vs Replace:
- **MERGE IS STRICTLY PROHIBITED**: Merging double-entry journals creates catastrophic balance distortions, duplicate postings, and conflicting sequence numbers.
- **REPLACE IS THE ONLY SAFE MODEL**: Staged atomic replacement with full rollback capability.

---

## 13. Pre-Restore Validation Pipeline

Restore MUST execute in a completely isolated staging directory (`spendx_restore_staging/`):

```
Backup File (.spendx)
        │
        ▼
[Step 1: Container & Manifest Validation]
  • Extract manifest.json
  • Validate backup_format_version == 2
  • Validate schema_version == 24
  • Validate SHA-256 matches staged spendx.db
        │
        ▼
[Step 2: Staged SQLite Engine Validation]
  • Open staged spendx.db
  • PRAGMA integrity_check == 'ok'
  • PRAGMA foreign_key_check == 0 rows
  • PRAGMA user_version == 24
        │
        ▼
[Step 3: Canonical Financial Invariants Validation]
  • Verify all posted events have sum(debit) == sum(credit)
  • Verify no negative or zero amounts in postings
  • Verify system accounts exist (Equity, Card Clearing, etc.)
  • Verify evidence external references have no corrupt duplicates
        │
        ▼
[Step 4: Privacy Scrubbing]
  • Purge any expired raw SMS bodies: retention_expires_at <= now()
        │
        ▼
[ALL CHECKS PASS] ───► Proceed to Atomic Replacement
[ANY CHECK FAILS] ───► ABORT! Clean staging directory. Active DB untouched.
```

---

## 14. Atomic Restore Model & File Swap

```
[Staged DB Validated]
        │
        ▼
1. Acquire exclusive write lock / wait for WriteQueue
        │
        ▼
2. Checkpoint active DB: PRAGMA wal_checkpoint(TRUNCATE)
        │
        ▼
3. Close active AppDatabase connection
        │
        ▼
4. Rename active spendx.db -> spendx.db.pre_restore_backup
   (and delete active spendx.db-wal, spendx.db-shm)
        │
        ▼
5. Move staged spendx.db -> active spendx.db
        │
        ▼
6. Re-open AppDatabase
        │
        ▼
   [Success?]
   ├── YES ──► Delete pre_restore_backup; Invalidate Riverpod providers; Notify UI.
   └── NO  ──► ROLLBACK: Restore pre_restore_backup -> spendx.db; Reopen; Throw Error.
```

---

## 15. Crash Recovery & Failure Matrix

| Failure Point | State of Active DB | Recovery Action |
| :--- | :--- | :--- |
| **Crash during backup creation** | Completely unharmed | Staging backup file cleaned up on next app launch. |
| **Crash during backup download** | Completely unharmed | Incomplete download file cleaned up. |
| **Crash during staged validation** | Completely unharmed | Staging directory wiped on restart. |
| **Crash during file swap** | Pre-restore backup exists | On restart, `AppDatabase._initDB()` detects `spendx.db.pre_restore_backup`, completes or rolls back swap. |
| **Disk full during staging** | Completely unharmed | Fails cleanly before touching active DB. |
| **Corrupted archive / Bad hash** | Completely unharmed | Validation throws exception; staging deleted; active DB untouched. |

---

## 16. Concurrent-Write Analysis

During backup creation:
1. Writes occurring during an uncoordinated copy can capture a tearing write (half a transaction written to disk).
2. **Resolution**:
   - `PRAGMA wal_checkpoint(TRUNCATE)` flushes pending WAL frames.
   - `VACUUM INTO '$target'` is atomic within SQLite: SQLite obtains a shared read lock during the vacuum operation, ensuring the target database is a point-in-time consistent snapshot.
   - For additional safety, `WriteQueue` must pause new transaction commits during the `VACUUM INTO` execution (< 200ms on typical mobile storage).

---

## 17. Evidence & Privacy Requirements (30-Day SMS Policy)

Milestone C5 established:
> `raw SMS body retention = 30 days`

### Threat:
A backup taken on Day 10 contains a raw SMS. Restoring that backup on Day 60 would resurrect a 60-day-old raw SMS body, defeating the retention policy.

### Architectural Rule:
1. **Pre-Backup Scrub**: Prior to creating the backup snapshot, execute:
   ```sql
   UPDATE evidence
   SET raw_payload_encrypted = NULL, is_payload_purged = 1
   WHERE retention_expires_at IS NOT NULL
     AND retention_expires_at <= datetime('now')
     AND is_payload_purged = 0;
   ```
2. **Post-Restore Scrub**: Immediately upon staging a restored database (prior to promotion), execute the identical retention purge to guarantee no expired payloads are restored into active state.

---

## 18. Review Candidate Analysis

- Review candidates with `status = 'pending'` or `status = 'rejected'` represent **unapproved proposals**.
- They have `0` economic events and `0` postings.
- Option C preserves review candidates exactly as they were, retaining pending review items without converting them to financial truth.
- Restoring leaves them in the review queue awaiting explicit user approval.

---

## 19. Export vs Backup Boundary

| Concept | Purpose | Format | Restoration Target |
| :--- | :--- | :--- | :--- |
| **Canonical Backup** | Disaster recovery, phone transfer, full system restore | Encrypted/Checksummed `.spendx` Container (SQLite Snapshot + Manifest) | Full database replacement |
| **Financial Export** | Accounting audit, tax preparation, spreadsheet import | CSV / JSON / PDF | Read-only external consumption |
| **External Import** | Ingestion of external transactions (bank statement, CSV) | CSV / Notion ZIP | Routed through C5 Evidence & Review Candidate pipeline |

`ExportService` must **NEVER** be used as a backup engine.

---

## 20. Cloud Storage / Google Drive Assessment

- `DriveService` is already integrated in `lib/services/drive_service.dart` via `googleapis` and `google_sign_in`.
- `SyncEngine` in `lib/services/sync_engine.dart` orchestrates upload/download.
- **Architectural Decision for C8**:
  - Phase 1 of C8: Build and verify the hermetic **Local Canonical Backup & Restore Engine** (`.spendx` container creation, verification, atomic swap, and rollback).
  - Phase 2 of C8: Wire `BackupService`, `SyncEngine`, and `BackupHubScreen` to upload/download this canonical `.spendx` container instead of the broken legacy JSON.
  - Disable dangerous background `autoRestoreEnabled` until explicitly verified by adversarial tests.

---

## 21. Encryption & Security Dependency Assessment

- **SQLCipher Status**: SQLCipher active database encryption is **BLOCKED** and not required for C8.
- **Backup Encryption**:
  - Backup files stored in external storage or uploaded to Google Drive can be encrypted at the container level (e.g., standard AES-256 or authenticated archive encryption) without requiring database-level SQLCipher.
  - The homebrew XOR cipher in `lib/services/backup_encryption.dart` should be replaced or wrapped with standard AES-GCM or deferred to a dedicated security milestone.
  - **Verdict**: Milestone C8 is **NOT BLOCKED** by SQLCipher.

---

## 22. Database Snapshot Assessment

`MigrationV24Service.createPreMigrationBackup` proved that:
```dart
await db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
await db.execute("VACUUM INTO '$backupPath';");
```
creates an independent, non-zero, fully consistent, single-file SQLite database at version 24.
This pattern will form the core snapshot primitive of the Canonical Backup Engine.

---

## 23. Riverpod Provider Reinitialization Strategy

Following a successful atomic database restore, all Riverpod providers must be refreshed.
A centralized helper `invalidateAllFinancialProviders(Ref ref)` will be introduced:
```dart
void invalidateAllFinancialProviders(Ref ref) {
  ref.invalidate(accountsProvider);
  ref.invalidate(transactionsProvider);
  ref.invalidate(cardsProvider);
  ref.invalidate(loansProvider);
  ref.invalidate(categoriesProvider);
  ref.invalidate(tagsProvider);
  ref.invalidate(budgetsProvider);
  ref.invalidate(recurringProvider);
  ref.invalidate(remindersProvider);
  ref.invalidate(reviewQueueProvider);
  ref.invalidate(safeToSpendProvider);
  ref.invalidate(netWorthSummaryProvider);
  ref.invalidate(analyticsSummaryProvider);
  ref.invalidate(canonicalForecast30DaysProvider);
  ref.invalidate(forecastProvider);
  ref.invalidate(runwayProvider);
  ref.invalidate(lendingProvider);
  ref.invalidate(liabilitiesSummaryProvider);
  DataChangeBus.instance.notify();
}
```

---

## 24. Adversarial Test Plan (36 Vectors)

The implementation must author `test/features/c8_canonical_backup_restore_test.dart` covering 36 rigorous vectors:

1. **Empty database backup and restore round-trip**.
2. **Normal multi-account financial dataset round-trip**.
3. **Income event and postings round-trip fidelity**.
4. **Expense event and postings round-trip fidelity**.
5. **Account-to-account transfer round-trip balance fidelity**.
6. **Credit card purchase event and liability posting fidelity**.
7. **Credit card bill payment and bank debit round-trip**.
8. **Refund event with multi-leg reversals preserved**.
9. **Loan disbursement event and liability establishment**.
10. **Loan EMI repayment 3-leg split (principal + interest) preserved**.
11. **Goal asset earmark relationships intact after restore**.
12. **Recurring rules and frequency settings survive restore**.
13. **Expected events and fulfillment pointers survive restore**.
14. **Pending review candidate remains non-accounting after restore**.
15. **Approved review candidate produces identical ledger postings**.
16. **Evidence fingerprint (SHA-256) and external references survive**.
17. **Opening balance reconciliation records preserved with audit provenance**.
18. **Reversal/replacement chains remain linked after restore**.
19. **Legacy compatibility tables mirror canonical data after restore**.
20. **Corrupted backup file rejected during staging validation**.
21. **Truncated backup file rejected during staging validation**.
22. **Incompatible schema version (> 24) rejected without touching active DB**.
23. **Foreign-key constraint violation in staging DB triggers rollback**.
24. **Unbalanced postings in staging DB triggers immediate rejection**.
25. **Negative posting amount in staging DB triggers immediate rejection**.
26. **Duplicate external reference collision properly handled**.
27. **Failed restore leaves active database completely untouched**.
28. **Crash during atomic swap leaves active DB recoverable**.
29. **Concurrent write during backup creation does not produce torn DB**.
30. **Raw SMS payload purged if retention period expired prior to backup**.
31. **Raw SMS payload purged on restore if retention expired during storage**.
32. **All Riverpod providers reflect restored state without app restart**.
33. **Net worth equality verified before backup and after restore**.
34. **Safe-to-Spend calculation identical before backup and after restore**.
35. **Runway and 30-day forecast projection identical before and after restore**.
36. **C3B write firewall & C4 read firewall preserved across restore lifecycle**.

---

## 25. Exact Implementation File Inventory

### MUST CHANGE:
- `lib/services/backup_file_service.dart`: Re-architect to produce and parse canonical `.spendx` backup containers with `manifest.json` and SQLite snapshot.
- `lib/services/backup_service.dart`: Re-architect to use atomic staged restore and snapshot backup; replace broken `_restoreTables()`.
- `lib/services/database_helper.dart`: Deprecate or upgrade `getFullSnapshot()` and `restoreFromSnapshot()` to handle canonical tables safely, or delegate directly to `CanonicalBackupService`.
- `lib/services/sync_engine.dart`: Ensure auto-restore is safe, validated, and guarded against silent data loss.
- `lib/screens/settings/backup_hub_screen.dart`: Update to display canonical backup metadata (counts of accounts, events, postings).
- `lib/features/settings/providers/data_management_providers.dart`: Ensure `clearAllData()` safely cascades through canonical repositories.

### MAY CHANGE:
- `lib/services/export_service.dart`: Ensure `exportFullBackup()` calls the canonical backup service.
- `lib/data/core/app_database.dart`: Expose atomic file replacement / checkpoint helpers if necessary.

### TEST ONLY (NEW):
- `test/features/c8_canonical_backup_restore_test.dart`: Complete 36-vector adversarial suite.

### MUST NOT CHANGE:
- `lib/data/core/tables_v24.dart`: Schema remains v24 LOCKED.
- `lib/domain/finance/*`: Double-entry accounting invariants remain untouched.
- `lib/data/repositories/canonical/*`: Canonical repositories remain untouched.

---

## 26. Non-Goals

The C8 implementation will NOT include:
- SQLCipher or active database encryption.
- Multi-user or remote server syncing (e.g. Supabase, Firebase).
- Schema migrations to v25.
- Deletion of legacy transitional tables.
- UI redesign or GoRouter refactoring.

---

## 27. Architectural Risks & Mitigations

1. **Risk**: Staging database exceeds available device disk space during backup/restore.  
   *Mitigation*: Check available disk space before staging; vacuum target database directly into backup directory.
2. **Risk**: Background SMS ingestion or write queue mutates database while vacuum is running.  
   *Mitigation*: `WriteQueue` acquires a lock or waits for `VACUUM INTO` completion.
3. **Risk**: Platform differences on iOS / Android in renaming open SQLite files.  
   *Mitigation*: Explicitly close `AppDatabase` connection before file swap and reopen afterward.

---

## 28. Recommended Implementation Sequence

```
Phase 1: Canonical Backup Engine Core
  ├── Snapshot generator using VACUUM INTO + PRAGMA wal_checkpoint(TRUNCATE)
  ├── Container packager (.spendx archive + manifest.json + SHA-256)
  └── Retention scrubber for expired evidence payloads

Phase 2: Canonical Staged Restore Engine
  ├── Staging isolation directory
  ├── Multi-phase validation pipeline (checksum, integrity_check, foreign_key_check, balance parity)
  └── Atomic file swap with automatic rollback on failure

Phase 3: Service & UI Integration
  ├── Wire BackupService and BackupFileService to Canonical Engine
  ├── Update SyncEngine with safe restore guards
  └── Centralized Riverpod provider invalidation

Phase 4: Adversarial & Regression Verification
  ├── 36-vector adversarial test suite
  ├── 607-test full regression verification
  └── Analyzer clean check
```

---

## 29. Formal C8 Readiness Verdict

```
================================================================================
                    MILESTONE C8 DISCOVERY GATE VERDICT
================================================================================
  Candidate Objective Evaluation    : Canonical Backup & Restore is confirmed
                                      as the critical primary bottleneck.
  Current State Vulnerability       : Existential data loss on backup/restore.
                                      Canonical v24 tables completely omitted.
  Architectural Strategy            : Option C (Atomic SQLite Snapshot +
                                      Verified Container Manifest).
  Locked Baselines                  : C3B, C4, C5, C6, C7 Intact.
  Database Schema                   : v24 (LOCKED).
  Triggers                          : 7 / 7 Active.
--------------------------------------------------------------------------------
  DISCOVERY VERDICT                 : READY FOR IMPLEMENTATION
================================================================================
```

---

## 30. Explicit Authorization Boundary

> [!IMPORTANT]
> **HARD STOP**: Discovery for Milestone C8 is complete. **NO CODE HAS BEEN IMPLEMENTED.**  
> Awaiting explicit user authorization before commencing C8 implementation.
