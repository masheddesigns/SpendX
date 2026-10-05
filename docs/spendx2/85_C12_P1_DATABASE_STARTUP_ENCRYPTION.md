# 85. Milestone C12-P1: Database Startup & Default Encryption Enforcement

**Status**: IMPLEMENTED & VERIFIED  
**Date**: 2026-10-05  
**Baseline**: Schema v24 (LOCKED), 7/7 Financial SQLite Triggers  
**Test Suite**: 777+ tests passing, 0 analyzer errors/warnings  
**Prerequisite Milestone**: C12 Discovery (`84_C12_ARCHITECTURAL_DISCOVERY.md`) — PASS/CLOSED  

---

## 1. Executive Summary & Objective

Milestone **C12-P1** enforces default encryption and closes the five operational and security gaps identified during **C12 Discovery**:

1. **Default SQLCipher Encryption on Fresh Databases**: Fresh database creation now unconditionally opens an encrypted SQLCipher database with page-level encryption via `openEncryptedDatabase`. Fallback to plaintext creation is completely eliminated (`PLAINTEXT_FRESH_DATABASE_CREATION = 0`).
2. **Automatic Startup Migration for Legacy Plaintext**: `AppDatabase.instance.database` automatically detects legacy plaintext databases and seamlessly invokes `DatabaseEncryptionMigrationService.instance.runMigration()`, migrating existing databases out-of-place with full safety backups, WAL quiescence, staged validation, atomic directory swap, and zero data loss.
3. **Concurrency-Safe Startup Mutex**: Concurrent access to `AppDatabase.instance.database` during initialization or migration is serialized using an asynchronous initialization mutex (`_initFuture`), preventing race conditions, dual-initialization, or database locking conflicts.
4. **UTC Timestamp ISO-8601 Standardization**: Timestamps across evidence ingestion (`Evidence`), review queues (`ReviewItem`, `CanonicalReviewRepository`), and ledger repositories (`CanonicalEventRepository`, `LiveSmsService`) are strictly standardized to `.toUtc().toIso8601String()`. This eliminates timezone skew and guarantees that 30-day raw SMS retention pruning (`EvidencePruningService`) behaves deterministically across all client timezones.
5. **Sensitive Financial Log Scrubbing**: Debug and production print statements logging unmasked account numbers, card last-4 digits, transaction amounts, and financial institution sender headers in `sms_import_service.dart` and `live_sms_service.dart` were scrubbed and redirected to structured debug logging (`AppLogger.d`), preventing confidential financial information leakage in system logs.

---

## 2. Architectural Implementations

### 2.1 Fresh Database Encryption Enforcement
In `lib/data/core/app_database.dart`:
- `_initDB(String filePath)` no longer opens plaintext databases when creating fresh instances.
- Instead, it checks if the target database file exists on disk:
  - If the database does not exist, `openEncryptedDatabase(filePath)` is called directly using the 256-bit passphrase obtained from `SpendXDatabaseKeyManager.instance.getOrCreateDatabaseKey()`.
  - The SQLite database header is immediately formatted with SQLCipher 4.18.0 page-level encryption (HMAC-SHA512, 64,000 PBKDF2 iterations, 4096-byte page size).
  - All v24 tables, indexes, and all 7 financial SQLite triggers are executed inside this encrypted container.
- If a legacy unencrypted database file exists at `filePath`, and auto-migration is enabled, `AppDatabase` invokes `DatabaseEncryptionMigrationService.instance.runMigration()` before opening the newly encrypted database.

### 2.2 Concurrency-Safe Initialization Mutex
To prevent concurrent calls to `AppDatabase.instance.database` from executing parallel initializations or colliding during migration:
```dart
Future<Database> get database async {
  if (_database != null && _database!.isOpen) return _database!;
  _initFuture ??= _initDB('spendx.db');
  try {
    _database = await _initFuture!;
    return _database!;
  } catch (e) {
    _initFuture = null;
    rethrow;
  }
}
```
Any subsequent callers await the in-flight initialization future, guaranteeing idempotent and thread-safe startup. When `close()` is called, `_initFuture` is reset along with `_database`.

### 2.3 Automatic Plaintext-to-SQLCipher Migration
When opening an existing database:
- `AppDatabase._initDB` tests whether the file is plaintext using `DatabaseEncryptionMigrationService.isDatabasePlaintext()`.
- If plaintext is detected, `DatabaseEncryptionMigrationService.instance.runMigration(dbPath: path)` is executed:
  1. Preflight sanity check (verifies SQLite header, foreign key consistency, and schema v24).
  2. Creates immutable safety backup `spendx.db.pre_migration_safety_copy`.
  3. Quiesces WAL via `PRAGMA wal_checkpoint(TRUNCATE)` and checkpoints WAL frames.
  4. Stages encrypted copy via `ATTACH ... KEY ...` and `sqlcipher_export()`.
  5. Validates staged database independently (schema v24, foreign keys, 7 triggers, accounting fingerprint checksum).
  6. Performs atomic same-directory rename swap.
- Once migration completes, `openEncryptedDatabase(path)` opens the verified SQLCipher database.

### 2.4 UTC ISO-8601 Standardization
Timezone discrepancies in timestamp comparisons could allow evidence records to be pruned prematurely or retained past the 30-day compliance window. All timestamp writes and comparisons are now normalized to UTC:
- **`ReviewItem`**: `createdAt = (createdAt ?? DateTime.now()).toUtc();` and serialization uses `.toUtc().toIso8601String()`.
- **`ReviewRepo`**: All evidence insertion records `receivedAt: DateTime.now().toUtc()`.
- **`CanonicalReviewRepository`**: Review candidates record `createdAt: DateTime.now().toUtc().toIso8601String()`.
- **`CanonicalEventRepository`**: Events, postings, and evidence link records save `.toUtc().toIso8601String()`.
- **`LiveSmsService`**: Evidence creation standardizes `receivedAt: DateTime.now().toUtc()`.

### 2.5 Sensitive Financial Log Scrubbing
Log scrubbing in `sms_import_service.dart` and `live_sms_service.dart`:
- Removed raw `print('... balance: $balance, acc: $accNum')` statements.
- Scrubbed card and loan auto-registration debug logs from outputting full unmasked identifiers and balances.
- Converted non-critical diagnostic logs to `AppLogger.d()` without leaking PII.

---

## 3. Test Verification Matrix

A dedicated test suite was implemented in `test/features/c12_p1_startup_encryption_test.dart` verifying all five areas:

| Test ID | Test Scenario | Description | Result |
|---|---|---|---|
| **C12-P1.1** | Fresh Database Default Encryption | Verifies fresh DB created by `AppDatabase` is encrypted with SQLCipher (fails plaintext open with `DatabaseException(26)`, succeeds with correct key). | **PASS** |
| **C12-P1.2** | Legacy Plaintext Startup Migration | Verifies pre-existing plaintext v24 database is automatically migrated to SQLCipher upon calling `AppDatabase.instance.database`. | **PASS** |
| **C12-P1.3** | Concurrency-Safe Initialization | Verifies 10 concurrent requests to `AppDatabase.instance.database` yield the exact same underlying open database instance without race conditions. | **PASS** |
| **C12-P1.4** | UTC ISO-8601 Timestamp Standardization | Verifies `Evidence`, `ReviewItem`, and `CanonicalReviewRepository` persist timestamps with UTC timezone and ISO-8601 compliance. | **PASS** |
| **C12-P1.5** | Evidence Pruning UTC Skew Safety | Verifies `EvidencePruningService` prunes raw SMS evidence $\ge 30$ days old deterministically regardless of timezone differences. | **PASS** |
| **C12-P1.6** | Sensitive Financial Log Scrubbing | Static analysis verification ensuring no unmasked financial print calls remain in SMS ingestion pipelines. | **PASS** |

### Regression Suite Results
- **Full Test Suite**: 777 / 777 tests passing (100%).
- **Flutter Analyzer**: 0 errors, 0 warnings.
- **C8–C11 Security Regressions**: 164 / 164 passing.
- **Accounting & Ledger Invariants**: 100% preserved, 7/7 triggers verified.

---

## 4. Verification Conclusion & Gate Status

Milestone **C12-P1** is **COMPLETE and PASS**.
All 5 operational gaps from C12 Discovery are closed:
1. `PLAINTEXT_FRESH_DATABASE_CREATION = 0` (strict default SQLCipher encryption).
2. Transparent legacy startup migration.
3. Thread-safe initialization mutex.
4. Universal UTC timestamp normalization.
5. Scrubbed financial logs.

**HARD STOP ENFORCED**: Awaiting user review and formal authorization before proceeding to C12-P2.
