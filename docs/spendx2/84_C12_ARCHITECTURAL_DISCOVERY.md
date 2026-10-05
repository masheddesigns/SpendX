# SpendX 2.0 — Milestone C12 Architectural Discovery Report

**Document ID**: `docs/spendx2/84_C12_ARCHITECTURAL_DISCOVERY.md`  
**Milestone**: Milestone C12 — Discovery Only  
**Status**: **COMPLETE / READY FOR REVIEW**  
**Date**: October 5, 2026  
**Author**: SpendX Core Architecture Team  

---

## 1. Executive Summary

Milestone C12 Discovery was authorized following the formal closure of Milestone C11 (Runtime Database Encryption / SQLCipher) and C11-RDV (Controlled Real-Device Validation).

### Baseline State Verified:
- **SQLite Schema**: **v24 LOCKED**
- **Financial Triggers**: **7/7 ACTIVE**
- **Test Suite**: **771 / 771 PASS (100%)**
- **Static Analysis**: **0 errors / 0 warnings**
- **Runtime Encryption Engine**: SQLCipher 4.18.0 Community Edition via FFI
- **Migration Pipeline**: Validated on authentic SpendX database on physical host (`darwin-arm64`, macOS 26.5.2) with bit-exact accounting parity and zero source data mutation.

### Core Discovery Finding:
While the C11 out-of-place SQLCipher migration service, key management, and cryptographic engine are 100% verified and functional, **two critical operational gaps remain in production boot wiring**:
1. **Cold Install Plaintext Vulnerability**: When a user installs SpendX afresh and no database exists, `AppDatabase._initDB()` currently falls back to `openDatabase()`, creating a **plaintext SQLite database** on day 1 rather than an encrypted SQLCipher database.
2. **Boot-Time Auto-Migration Missing**: `DatabaseEncryptionMigrationService.instance.runMigration()` is implemented and verified, but it is **not wired into the normal application startup sequence**. Existing plaintext databases remain plaintext unless explicitly migrated via external invocation.
3. **AppDatabase Concurrency Race**: Concurrent access to `AppDatabase.instance.database` during startup lacks synchronization, permitting duplicate parallel invocations of `_initDB()`.

---

## 2. Current Architecture & Canonical Truth Verification

The end-to-end financial data architecture was traced and audited:

```
[Inbound Evidence / SMS / Manual]
             │
             ▼
[Canonical Ingestion Pipeline & Privacy Filter]
             │
             ▼
[CanonicalEventRepository / CanonicalTransactionAdapter]
             │
             ▼ (Atomic SQLite Transaction)
[TablesV24.economic_events] ──► [TablesV24.postings] ──► [TablesV24.evidence]
             │
             ▼
[7/7 SQLite Financial Triggers Enforcing Double-Entry & Immutability]
             │
             ▼
[TablesV24.accounts (Derived Balances via SUM(postings))]
             │
             ▼
[CanonicalFinancialQueryRepository]
   ├── Net Worth (Assets - Liabilities)
   ├── Cash Flow (Income - Expense)
   ├── Safe-to-Spend (Liquid Assets)
   └── CanonicalForecastEngine (Deterministic 30-Day Projections)
             │
             ▼
[Riverpod Providers (DataChangeBus Invalidation)] ──► [UI / Dashboards / AI Bridge]
```

### Verification Verdict:
- **Canonical Flow Intact**: The flow established in C3B–C7 remains authoritative.
- **Zero Legacy Financial Authority**: Legacy single-entry tables (`transactions`, `bank_accounts.balance`, `credit_cards.current_balance`, `loans.paid_amount`) have 0 reads and 0 writes for financial truth. All financial calculations project from `TablesV24.postings` and `TablesV24.accounts`.

---

## 3. Database & Persistence Audit

Every database opening call in `lib/` was analyzed and classified:

| Path / Caller | File | Classification | Status |
| :--- | :--- | :--- | :--- |
| `SpendXDatabaseFactory.openEncryptedDatabase` | `lib/data/core/spendx_database_factory.dart` | **CANONICAL** | Authenticated SQLCipher opening via `PRAGMA key`. |
| `SpendXDatabaseFactory.openPlaintextDatabase` | `lib/data/core/spendx_database_factory.dart` | **COMPATIBILITY** | Used solely by migration service for preflight export. |
| `AppDatabase._initDB` (Encrypted Branch) | `lib/data/core/app_database.dart` | **CANONICAL** | Primary application entry point for encrypted databases. |
| `AppDatabase._initDB` (Plaintext Branch) | `lib/data/core/app_database.dart` | **TRANSITIONAL** | Plaintext fallback when DB is unencrypted. |
| `BackupService` (`snapDb`, `stagedDb`, `testOpen`) | `lib/services/backup_service.dart` | **CANONICAL** | Dynamically checks `isPlaintextSqliteFile` and delegates. |
| `DatabaseHelper.instance.database` | `lib/services/database_helper.dart` | **COMPATIBILITY** | Getter delegates directly to `AppDatabase.instance.database`. |
| `DatabaseSecurityService` | `lib/services/database_security_service.dart` | **LEGACY / SUPERSEDED** | C10 interim AES-GCM file container; uncalled in production. |

### Required Metric:
- **`ILLEGAL_PRODUCTION_DATABASE_OPENERS = 0`** (All production database access routes through `AppDatabase` or `SpendXDatabaseFactory`).

---

## 4. SQLCipher Lifecycle Audit

The lifecycle states were investigated across cold boot, restart, crash, and backup:

| Lifecycle State | Current Behavior | Deterministic? | Finding / Risk |
| :--- | :--- | :--- | :--- |
| **First Launch (No DB)** | Creates plaintext DB via `openDatabase()` | **YES** | **RISK P1**: Database created in plaintext rather than encrypted. |
| **First Launch (Encrypted DB)** | Opens via `openEncryptedDatabase()` | **YES** | Deterministic. |
| **App Restart** | Reopens encrypted DB cleanly | **YES** | Deterministic. |
| **Key Retrieval Failure** | Throws `DatabaseKeyAccessException` | **YES** | Fails loudly; does not regenerate. |
| **Key Loss (DB exists, key missing)** | Throws `KeyLossFatalException` | **YES** | Rejects opening; **NO empty DB fallback**. |
| **Interrupted Migration** | Journal detected $\rightarrow$ `recoverInterruptedMigration()` | **YES** | Reverts to plaintext safely. |
| **Concurrent Startup Open** | Both execute `_initDB()` in parallel | **NO** | **RISK P2**: Lack of initialization mutex on `get database`. |
| **DB Copied to Another Device** | Key missing $\rightarrow$ fatal key loss | **YES** | Prevents unauthorized opening without Keychain key. |

---

## 5. Migration Architecture Audit

### Chain Construction:
```
Legacy DB (v1..v23) ──► AppDatabase._applyUpgrades() ──► Plaintext v24 ──► DatabaseEncryptionMigrationService ──► SQLCipher v24
```

### Findings:
1. **Convergence**: A fresh v24 database and a migrated historical database converge with identical 54 tables and 7/7 triggers.
2. **Schema Invariant**: Migrations do not alter canonical financial events or postings.
3. **Trigger Invariant**: All 7 financial triggers are installed during `createAllV24()` and enforce immutable constraints on all subsequent operations.
4. **Weak Point**: Upgrading historical schemas (e.g. v19) requires all legacy table columns (`is_deleted`, `account_id`, `external_ref`) to be defensively present before `MigrationV24Service` runs verification queries.

---

## 6. Accounting Integrity Audit

All database mutation points (`insert`, `update`, `delete`, `rawUpdate`, `rawInsert`) were audited across `lib/data/` and `lib/services/`:

- **Canonical Event Repository**: Operates exclusively through balanced atomic transactions (`EconomicEvent` + `Postings`).
- **Trigger Suite**: Native SQLite triggers reject direct insert of posted events, unbalanced postings, and modifications to posted events.
- **Double-Entry Balance**: Verified `debits == credits` across all 10 transaction types (expenses, income, transfers, card purchases, card payments, refunds, loan disbursements, loan repayments, opening balances, adjustments).
- **Rogue Financial Writers**: **`ROGUE_FINANCIAL_WRITERS = 0`**. Zero production code writes to financial tables without canonical event wrapping.

---

## 7. Read-Path Audit

All financial query paths in repositories, services, and view models were audited:

- `accounts`: Projected strictly from `TablesV24.accounts` with balance derived via `CanonicalAccountRepository.getDerivedBalance()`.
- `transactions`: Projected strictly from `TablesV24.economic_events` and `TablesV24.postings`.
- `netWorth`: Computed exclusively via `CanonicalFinancialQueryRepository.getNetWorth()`.
- `safeToSpend`: Computed exclusively via `CanonicalFinancialQueryRepository.getSafeToSpend()` (Liquid Assets).
- `forecast`: Projected exclusively by `CanonicalForecastEngine` (deterministic cash flow schedule).
- **Stale Financial Authority**: **`STALE_FINANCIAL_AUTHORITY = 0`**. Zero readers rely on legacy `bank_accounts.balance` or legacy tables.

---

## 8. Provider / State Architecture Audit

Riverpod provider graph state was audited:

```
[Write Action] ──► [WriteQueue] ──► [Canonical Event Commit] ──► [invalidateAllFinancialProviders] ──► [DataChangeBus.notify()]
```

### Findings:
1. **Riverpod Authority**: Centralized invalidation via `invalidateAllFinancialProviders()` ensures all derived views (`safeToSpendProvider`, `netWorthSummaryProvider`, `accountsProvider`, `transactionsProvider`, `canonicalForecast30DaysProvider`) re-query canonical repositories synchronously.
2. **Legacy Provider Residue**: Eight peripheral screens (e.g. `profile_settings_screen.dart`, `feature_toggles_screen.dart`) still import `package:provider/provider.dart` for non-financial UI state.

---

## 9. Backup / Restore Audit (C8 after C11)

### Pipeline Verified:
```
Active SQLCipher DB ──► C8 Backup (Scrubbing + WAL Quiesce) ──► .spendx (Argon2id + AES-256-GCM) ──► C8 Restore ──► Active SQLCipher DB
```

### Findings:
1. **Key Separation**: The master SQLCipher database key is **never included** in the backup package.
2. **Authentication**: AES-256-GCM authenticated data (AAD) protects manifest integrity, schema version, and debit/credit totals.
3. **Staged Restore**: Restores unpack to an isolated temporary sandbox, validate SQLite integrity, foreign keys, double-entry parity, and 7/7 triggers before replacing the active database.
4. **Mutual Exclusion**: `BackupService` rejects backup/restore if migration is running. However, `CanonicalEventRepository` does not check if a restore is actively overwriting the database file.

---

## 10. Security & Privacy Audit

A repository-wide security scan was executed:

| Area | Status | Finding |
| :--- | :--- | :--- |
| **Database Encryption Key** | **SECURE** | 256-bit random key in OS SecureStorage; never logged or serialized. |
| **Gemini API Key** | **SECURE** | Authenticated via `x-goog-api-key` header; URL and logs scrubbed. |
| **Backup Encryption** | **SECURE** | AES-256-GCM + Argon2id KDF; tamper-evident AAD. |
| **Raw SMS 30-Day Pruning** | **ACTIVE** | `EvidencePruningService` purges raw SMS payloads after 30 days. |
| **Stdout Print Leakage** | **VULNERABLE (P3)** | `sms_import_service.dart:291` and `live_sms_service.dart:440` print raw financial detection metadata (`amount`, `last4`, `bank`) to stdout. |

---

## 11. Concurrency & Lifecycle Audit

### Key Observations:
1. **Startup Race Condition**: `AppDatabase.database` is not guarded by an async lock. Parallel calls at boot initiate concurrent `_initDB()` operations.
2. **Restore Collision Risk**: `BackupService.restoreFromFile()` closes the database connection and pivots the file on disk. If a concurrent write is queued in `WriteQueue` or `LiveSmsService`, it fails abruptly with closed-connection errors.
3. **Missing Lifecycle Coordinator**: No single coordinator orchestrates the state of the database (active, restoring, migrating, paused) across background services.

---

## 12. Offline & Data Recovery Audit

| Failure Scenario | Current Behavior | Data Loss Risk? |
| :--- | :--- | :--- |
| **Crash during write** | SQLite WAL atomic rollback | **NO** (ACID compliant) |
| **Crash during migration** | Journal rolls back to safety backup | **NO** |
| **Crash during backup** | Temporary files cleaned up; live DB untouched | **NO** |
| **Crash during restore** | Staged DB discarded; live DB untouched | **NO** |
| **Missing Encryption Key** | `KeyLossFatalException` thrown | **NO** (Rejects empty DB fallback) |
| **Power Loss during Swap** | Triple-file pivot recovered via journal | **NO** |

---

## 13. Time, Currency & Numerical Integrity Audit

1. **Currency**: Locked strictly to `INR`. Minor units represented as 64-bit integers (`int` paise).
2. **Domain Cap**: Clamped at $\pm 10^{14}$ paise (₹1 lakh crore).
3. **Timezone Inconsistency (P2)**:
   - `EvidencePruningService` calculates cutoff using `DateTime.now().toUtc()`.
   - `LiveSmsService` calculates `retentionExpiresAt` using `DateTime.now()` (local time without UTC offset).
   - Lexicographical ISO string comparisons in SQLite (`WHERE retention_expires_at <= ?`) can skew retention pruning by up to several hours across timezone boundaries.

---

## 14. Forecast & Analytics Audit

- **Forecast Engine**: `CanonicalForecastEngine` is 100% deterministic, consuming canonical events and recurring rules.
- **Safe-to-Spend**: Uses the authoritative formula `Liquid Assets (Checking + Savings + Cash) - Due Liabilities`.
- **Zero Duplicate Engines**: Historical forecast engines have been retired or mapped to `CanonicalForecastEngine`.

---

## 15. AI & Automation Audit

- **AI Data Bridge**: AI prompts and context generation consume data strictly through `AiDataBridge` and `CanonicalFinancialQueryRepository`.
- **Zero Raw SQL from AI**: Gemini responses are restricted to structured JSON commands (`add_transaction`), which are parsed and validated through `FinancialTransactionService`.
- **Zero Hallucinated Mutations**: AI cannot directly modify accounts, balances, or ledger postings.

---

## 16. Legacy Retirement Audit (C9 Post-Audit)

Remaining legacy code surfaces were classified:

| Surface | Classification | Architectural Impact |
| :--- | :--- | :--- |
| `lib/services/database_security_service.dart` | **SUPERSEDED** | Zero production authority. Ready for safe removal. |
| `refactor_snackbars.py` & other root scripts | **OBSOLETE** | Leftover migration scripts in root directory. |
| `Tables.bankAccounts`, `Tables.transactions` | **COMPATIBILITY** | Used solely by legacy adapters; zero financial truth authority. |
| `package:provider` imports in UI screens | **UI-ONLY** | Settings screens not yet converted to Riverpod. |

---

## 17. Test Architecture Audit

- **Total Tests**: **771 / 771 PASS** (100% passing).
- **Disabled Tests**: **`DISABLED_FINANCIAL_TESTS = 0`**. Zero tests skipped or disabled.
- **SQLCipher Coverage**: Dedicated suites cover FFI initialization, key lifecycle, crash recovery, and real-device execution.
- **Test Seam**: `SpendXDatabaseKeyManager.setTestInstance()` isolates test key storage from user Keychain.

---

## 18. Dependency Audit

| Package | Version | Status | Architectural Implication |
| :--- | :--- | :--- | :--- |
| `sqlcipher_flutter_libs` | `^0.7.0+eol` | **EOL** | Provides SQLCipher 4.18.0. Stable and functional, but maintenance risk. |
| `sqlite3_flutter_libs` | `^0.6.0+eol` | **EOL** | Dev dependency; maintainer marked EOL. |
| `provider` | `^6.1.5+1` | **REDUNDANT** | Coexists with Riverpod `^2.6.1`. |
| `sqflite` / `sqflite_common_ffi` | `^2.4.2` | **ACTIVE** | Core engine adapters. |

*Recommendation*: Do not disrupt working dependencies until lifecycle hardening is complete.

---

## 19. Platform & Release Readiness

| Platform | Readiness Level | Evidence & Notes |
| :--- | :--- | :--- |
| **macOS** | **SUPPORTED & VERIFIED** | Validated via C11-RDV on Apple Silicon Darwin host with authentic user data. |
| **Android** | **SUPPORTED (Code Baseline)** | Bundled native `.so` libraries present; ProGuard rules in place; physical device run pending. |
| **iOS** | **SUPPORTED (Code Baseline)** | CocoaPods pod `SQLCipher` linked via podspec; physical device run pending. |
| **Linux** | **PARTIALLY VERIFIED** | Desktop FFI supported; requires host `libsqlcipher.so` or bundled binary. |
| **Windows** | **UNVERIFIED** | Requires `sqlcipher.dll` on path. |
| **Web** | **UNSUPPORTED** | C-library SQLCipher pager is fundamentally incompatible with standard Web SQLite. |

---

## 20. Performance Audit

1. **Derived Balance Calculations**: Aggregate queries over `postings` for 15+ accounts execute on startup in < 15ms on local database, but caching derived balances in Riverpod state avoids repeat queries.
2. **SQLCipher Page Overhead**: AES-256 page-level crypto adds ~5–10% I/O overhead on disk reads; imperceptible for SpendX's typical database size (< 10 MB).

---

## 21. Architecture Findings Severity Classification

| Finding ID | Severity | Category | Description & Impact | Recommended Action |
| :--- | :--- | :--- | :--- | :--- |
| **F-01** | **P1** | Security / Persistence | **Cold-Install Creates Plaintext DB**: `AppDatabase._initDB()` falls back to `openDatabase()` when no DB exists, creating plaintext SQLite instead of encrypted SQLCipher on new installs. | Create fresh databases via `SpendXDatabaseFactory.openEncryptedDatabase` by default. |
| **F-02** | **P1** | Security / Migration | **Boot-Time Auto-Migration Missing**: Existing plaintext `spendx.db` is not automatically migrated to SQLCipher at app startup. | Implement an automated startup migration coordinator in `AppDatabase._initDB()`. |
| **F-03** | **P2** | Concurrency | **Concurrent `_initDB` Race**: `AppDatabase.database` getter lacks mutual exclusion, permitting parallel initialization. | Add an async synchronization lock or Completer guard. |
| **F-04** | **P2** | Lifecycle | **Write-During-Restore Conflict**: Background SMS or UI writes can execute while `BackupService` is restoring and closing the database. | Create a unified `DatabaseLifecycleCoordinator` with pause/resume locks. |
| **F-05** | **P2** | Data Integrity | **Timezone ISO Skew**: Timestamps mix local ISO strings and UTC ISO strings with 'Z', causing retention pruning inconsistencies in SQLite string comparisons. | Standardize all database timestamps strictly to `DateTime.now().toUtc().toIso8601String()`. |
| **F-06** | **P3** | Privacy | **SMS Detection Logging**: `sms_import_service.dart` and `live_sms_service.dart` print financial detection details to stdout. | Remove debug `print()` statements in SMS services. |
| **F-07** | **P3** | Technical Debt | **Superseded C10 Dead Code**: `DatabaseSecurityService` and root python scripts remain in codebase. | Safely delete unused legacy scripts and superseded services. |
| **F-08** | **P3** | Architecture | **Residual `package:provider`**: Several settings screens still import `provider.dart` alongside Riverpod. | Complete migration of residual screens to Riverpod. |
| **F-09** | **P3** | Dependencies | **EOL Library Maintenance**: `sqlcipher_flutter_libs` is marked `+eol`. | Plan dependency upgrade path in post-C12 modernization pass. |

---

## 22. Recommended C12 Scope: Production Readiness & Lifecycle Hardening

Based on the discovery findings, Milestone C12 should **NOT** be a broad refactoring or dependency upgrade. It should be tightly scoped as:

### **Milestone C12 — Production Readiness & Lifecycle Hardening**

**Primary Objective**: Eliminate cold-install plaintext fallback, automate startup database migration, serialize database initialization, and establish application-wide lifecycle coordination for safe backup, restore, and SMS processing.

---

## 23. Proposed C12 Phases

### **Phase 1: Database Startup & Default Encryption Enforcement**
- Ensure fresh databases are born **encrypted with SQLCipher** on first launch.
- Wire `DatabaseEncryptionMigrationService.runMigration()` into `AppDatabase._initDB()` for transparent boot-time migration of existing plaintext databases.
- Guard `AppDatabase.database` with an async initialization lock to prevent concurrent initialization races.
- Standardize all database timestamps to UTC ISO-8601 to eliminate timezone pruning skews.
- Eradicate sensitive SMS detection `print()` statements from device logs.

### **Phase 2: Database Lifecycle Coordinator & Mutual Exclusion**
- Implement `DatabaseLifecycleCoordinator` managing states: `active`, `migrating`, `backingUp`, `restoring`, `closed`.
- Pause `WriteQueue` and background SMS processing during backup snapshots and restore pivots.
- Safely retire dead C10 artifacts (`DatabaseSecurityService`, root python scripts).

---

## 24. Acceptance Gates for C12

1. **Encrypted-by-Default Gate**: A cold install with no prior database produces a 100% encrypted SQLCipher database file immediately.
2. **Auto-Migration Gate**: An existing plaintext database is automatically migrated to SQLCipher on first launch with bit-exact accounting parity.
3. **Concurrency Gate**: Parallel calls to `AppDatabase.database` at boot execute `_initDB()` exactly once.
4. **Zero Print Leakage Gate**: Device stdout contains zero financial transaction amounts or card numbers.
5. **Regression Gate**: 771/771 tests pass, schema v24 locked, 7/7 triggers active, analyzer clean (0 errors / 0 warnings).

---

## 25. Explicit Non-Goals for C12

- **NO** schema changes (Schema v24 remains locked).
- **NO** trigger changes (7/7 triggers remain active).
- **NO** accounting domain refactoring (Double-entry invariants unchanged).
- **NO** dependency upgrades (Keep `sqlcipher_flutter_libs ^0.7.0+eol` intact; do not introduce breaking dependency changes).
- **NO** UI feature additions or design revamps.
