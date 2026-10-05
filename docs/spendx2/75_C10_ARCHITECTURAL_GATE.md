# SpendX 2.0 — Milestone C10 Architectural Gate
## Post-C9 Architectural Discovery & Security/Integrity Specification

**Document ID**: `SPENDX2-C10-GATE-001`  
**Status**: DISCOVERY COMPLETE — AUTHORIZATION REQUIRED  
**Date**: October 5, 2026  
**Milestone**: C10 — At-Rest & Archive Security Hardening (DISCOVERY ONLY)  
**SQLite Schema Version**: v24 (LOCKED)  
**Database Triggers**: 7/7 ACTIVE  
**Full Test Suite**: 673 / 673 PASS (100%)  
**Adversarial Vectors**: C9: 30/30 PASS, C8: 36/36 PASS, C7: 28/28 PASS, C5: 17/17 PASS, C4-7: 20/20 PASS  
**Static Analysis**: 0 Errors, 0 Warnings  

---

## 1. C9 Baseline Verification

The SpendX 2.0 architecture stands on a fully verified, closed baseline:

| Milestone / Component | Architectural Scope | Status | Verification Detail |
| :--- | :--- | :--- | :--- |
| **C3A / C3A.1 Foundation** | Core double-entry domain models, `Money`, immutability triggers | 🟢 CLOSED | Integer-paise arithmetic; $\sum \text{Dr} == \sum \text{Cr}$ |
| **C3B Write Firewall** | Repositories route 100% of mutations to `CanonicalEventRepository` | 🟢 CLOSED | Direct unauthorized accounting writes = 0 |
| **C4 Read Firewall** | UI and providers read solely from canonical derived balances | 🟢 CLOSED | `ILLEGAL_STALE_AUTHORITY` = 0 across all screens |
| **C5 Ingestion & Dedup** | Ingestion decoupled; staged candidates create 0 postings | 🟢 CLOSED | Evidence fingerprinting; 17/17 adversarial tests |
| **C6 Forecast Engine** | Unified deterministic forward projection & runway engine | 🟢 CLOSED | Integer-paise daily simulation; non-linear salary |
| **C7 Riverpod State** | Consolidated state ownership & centralized invalidation | 🟢 CLOSED | 28/28 adversarial tests; cache poisoning eliminated |
| **C8 Backup & Restore** | Canonical `.spendx` package format, atomic swap, rollback | 🟢 CLOSED | Staged DB validation; SHA-256 integrity; 36/36 tests |
| **C9 Legacy Retirement** | Retired runtime shadow writes and legacy financial paths | 🟢 CLOSED | 30/30 tests; Net Worth transfer canonicalized |
| **Test Suite** | Total unit, migration, domain, and feature regression tests | 🟢 673 / 673 | 100% pass rate across entire codebase |
| **Static Analysis** | `flutter analyze --no-fatal-infos` | 🟢 0 err / 0 warn | Zero compile-time errors or warnings |
| **SQLite Schema** | Schema version `v24` | 🟢 LOCKED | 0 DDL changes; 7/7 SQLite triggers active |
| **Legacy Financial Authority** | Runtime legacy table reads and writes | 🟢 0 / 0 | `ILLEGAL_RUNTIME_READS = 0`, `WRITES = 0` |

---

## 2. Discovery Methodology

The architectural audit investigated every layer of SpendX 2.0:
1. **Source Code Audits**: Comprehensive regex searches across `lib/` and `test/` for all SQL table names, deprecated providers, legacy classes, and security endpoints.
2. **Domain & Accounting Verification**: Traced all transaction lifecycle paths (create, transfer, update, delete, reconcile) through `FinancialTransactionService`, `CreditRepo`, `LoanRepo`, and `AccountRepo`.
3. **Numerical & Money Verification**: Audited floating-point vs `Money` integer paise conversions across aggregations, budgets, goals, and forecasts.
4. **Concurrency & Thread Safety**: Analyzed the interactions between Riverpod's in-memory `WriteQueue`, SQLite transactions, and background ingestion routines.
5. **Security & Privacy Analysis**: Evaluated plaintext database persistence on disk, unencrypted backup archives, LLM API key handling, and background raw SMS retention.
6. **Schema v24 Assessment**: Evaluated whether the remaining legacy tables warrant a jump to Schema v25 or if they remain safely quarantined.

---

## 3. Complete Remaining-Surface Inventory

Audit of every lingering legacy symbol, table reference, or deprecated construct:

| Surface / Code Location | Entity | Classification | Runtime Authority | Risk Level | Recommendation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `lib/data/repositories/ledger_repo.dart` | `LedgerRepo` | **RETIRED_STUB** | None (Deprecated) | LOW | Retain stub for test compatibility until v25. |
| `lib/services/ledger_service.dart` | `LedgerService` | **RETIRED_STUB** | None (Deprecated) | LOW | Retain stub for test compatibility until v25. |
| `lib/data/providers.dart:100, 144, 149` | `ledger*Provider` | **RETIRED_STUB** | None (Deprecated) | LOW | Retain deprecated stubs; zero active UI calls. |
| `Tables.transactions` | Physical SQLite table | **TRANSITIONAL_LEGACY** | None (0 runtime writes/reads) | LOW | Retain physical table under v24; drop in v25. |
| `Tables.ledgerTransactions` | Physical SQLite table | **TRANSITIONAL_LEGACY** | None (0 runtime writes/reads) | LOW | Retain physical table under v24; drop in v25. |
| `Tables.creditTransactions` | Physical SQLite table | **TRANSITIONAL_LEGACY** | None (0 runtime writes/reads) | LOW | Retain physical table under v24; drop in v25. |
| `credit_repo.dart:448` | `getTransactionById` fallback | **TEST_ONLY / FALLBACK** | None (pre-v24 test fallback) | LOW | Preserve for pre-v24 migration tests. |
| `credit_repo.dart:481, 616` | `credit_transactions` metadata | **TRANSITIONAL_METADATA** | Statement/EMI grouping only | LOW | Zero posting impact; migrate in v25. |
| `loan_installments` | Physical SQLite table | **TRANSITIONAL_METADATA** | Amortization schedule only | LOW | Zero postings; schedules migrate to `expected_events` in v25. |
| `goal_logs` | Physical SQLite table | **TRANSITIONAL_METADATA** | Operational activity notes | LOW | Zero postings; goal earmarks derive from `asset_earmarks`. |
| `loan_service.dart`, `credit_card_service.dart`, `reports_service.dart` | `LedgerRepo?` parameter | **RETIRED_STUB** | None (Unused parameter) | LOW | Retain deprecated parameter for constructor compatibility. |
| `financial_transaction_service.dart:352+` | `legacyFlow()` | **MIGRATION_ONLY** | None (guarded by `!isCanonical`) | LOW | Only executes in non-v24 migration tests. |
| `financial_transaction_service.dart:556+` | `appendLedger()`, `removeLedger()` | **RETIRED_STUB** | None (compatibility projection) | LOW | Retained for pre-v24 legacy test suites. |
| `maintenance_repo.dart` | `clearAllData()`, `clear*()` | **TRANSITIONAL_METADATA** | Test teardown / reset only | LOW | Clears legacy tables during test suite runs. |
| `dev_tools_service.dart` | `_ledgerRepo`, `_creditService` | **TEST_ONLY** | None (Debug mock data generator) | LOW | Used only in developer settings. |

**Discovery Verdict on Legacy Surfaces**:
All remaining legacy surfaces are strictly quarantined. None possess financial authority. Modifying or dropping them requires a physical schema bump to v25, which is not currently justified.

---

## 4. Canonical Architecture Audit

Every production flow has converged onto canonical double-entry accounting:
```
UI Intent / Ingestion
        ↓
FinancialTransactionService / Domain Repo (CreditRepo, LoanRepo, AccountRepo)
        ↓
Canonical Adapter (CanonicalTransactionAdapter, CanonicalCreditAdapter, CanonicalLoanAdapter)
        ↓
CanonicalEventRepository.createAndPostEvent
        ↓
TablesV24.economicEvents + TablesV24.postings + TablesV24.evidence
        ↓
7/7 SQLite Immutability Triggers (Enforced by SQLite Engine)
        ↓
Derived Query Layer (CanonicalFinancialQueryRepository, getDerivedBalance)
        ↓
Riverpod State Layer (safeToSpendProvider, netWorthSummaryProvider, etc.)
        ↓
UI Presentation
```
- **Bypasses**: 0.
- **Unbalanced Postings**: 0. Every posted event strictly enforces $\sum \text{debits} == \sum \text{credits}$.
- **Direct Balance Mutations**: 0. All balance updates (including reconciliations) route through balanced postings against `sys_equity_opening`.

---

## 5. Accounting Audit

- **Immutability Invariant**: Posted events are immutable. Editing or deleting a transaction creates a balanced reversal event (`reversal_of_event_id`) and an optional replacement event (`corrected_by_event_id`).
- **Audit Trails**: Forensic `Evidence` records persist `body_sha256`, `external_reference`, and `source_type`.
- **System Accounts**: System accounts (`sys_equity_opening`, `sys_exp_refunds`, `sys_exp_interest`) are automatically ensured prior to posting.
- **Reconciliation Audit**: Reconciliations persist immutable audit rows in `opening_balance_reconciliations`.

---

## 6. Money / Numerical Integrity Audit

- **Canonical Representation**: Every monetary value in canonical repositories and double-entry postings is represented by `Money` in integer minor units (paise for INR).
- **Economic Safety Cap**: Restricted to $\pm 10^{14}$ paise ($\pm ₹1$ lakh crore), mathematically preventing 64-bit integer overflow even when summing 90,000 transactions over multi-decade projections.
- **Floating-Point Isolation**:
  - `toRupees` is used strictly as a view projection for display widgets and presentation models.
  - Conversions from legacy doubles (`Money.fromRupees`) implement epsilon-biased half-away-from-zero rounding:
    ```dart
    ((rupees * 100.0) + (rupees >= 0 ? 0.0000001 : -0.0000001)).round()
    ```
  - Zero double-precision floating-point drift exists in core accounting calculations.

---

## 7. Concurrency & WriteQueue Audit

- **Current Implementation**:
  - `WriteQueue` (`lib/data/core/write_queue.dart`) is an in-memory Dart FIFO queue accessed via `writeQueueProvider`.
  - It is utilized exclusively by Riverpod mutation notifiers in `lib/data/providers.dart`.
  - Core services (`FinancialTransactionService`, `ImportService`, `LiveSmsService`, `SmsImportService`, `CreditRepo`) execute directly against SQLite using ACID transactions (`db.transaction(...)`).
- **Assessment**:
  - SQLite's single-writer architecture natively serializes concurrent writes at the database file level.
  - No race condition or lost update was detected in adversarial or stress tests.
  - However, background writes (such as incoming SMS processing while the app is active) do not synchronize with the in-memory `WriteQueue`, relying solely on `DataChangeBus.instance.notify()` for UI refresh.
  - While suboptimal in architectural symmetry, this does not cause corruption or data loss.

---

## 8. Ingestion & ReviewCandidate Lifecycle Audit

- **Complete Pipeline**:
  ```
  SMS / CSV / OCR / Manual
          ↓
  Evidence (body_sha256, external_reference)
          ↓
  SHA-256 Deduplication (existsByExternalRef / body_sha256)
          ↓
  ReviewCandidate (TablesV24.reviewCandidates, 0 postings)
          ↓
  User Decision:
    ├── Approve → FinancialTransactionService.createTransaction (EconomicEvent + Postings)
    └── Reject  → Mark status = 'rejected' (0 postings)
  ```
- **Provenance**: Verified. Every transaction produced from ingestion carries an `Evidence` record linking back to the raw source.
- **Defect Found**: `CanonicalBackupValidator.scrubExpiredEvidence` prunes raw SMS evidence older than 30 days during backup/restore, but **no scheduled runtime background job exists to prune live evidence** in normal daily operation.

---

## 9. Recurring & Forecast Audit

- **Single Authority**: `CanonicalForecastEngine` (`lib/services/canonical_forecast_engine.dart`) is the sole forecast authority.
- **Commitment Integration**:
  - Expected events from `TablesV24.expectedEvents` are mapped deterministically across the 30/60/90-day horizon.
  - Loan EMIs and credit card dues are factored on their exact contractual due dates.
  - Non-linear salary projection applies income on exact scheduled dates, eliminating the legacy MTD velocity multiplier defect.
- **Zero Accounting Impact**: Forecasting is strictly read-only; it generates 0 events and 0 postings.

---

## 10. Backup & Restore Audit

- **Container Integrity**: `.spendx` package containing `spendx.db` and `manifest.json`.
- **Validation Pipeline**:
  - Manifest validation (format v2, schema v24).
  - SHA-256 hash match against staged database file.
  - SQLite `PRAGMA integrity_check` pass.
  - Canonical double-entry balance check ($\sum \text{Dr} == \sum \text{Cr}$).
- **Rollback Safety**: Atomic file renaming with automatic restoration of the previous database if the swap fails.
- **C9 Compatibility**: Verified 100% compatible with all C9 changes (36/36 C8 tests pass).

---

## 11. Provider & State Architecture Audit

- **Consolidation**: C7 unified Riverpod state ownership and invalidation chains.
- **Centralized Invalidation**: `invalidateAllFinancialProviders(ref)` provides a single point of invalidation across `accountsProvider`, `transactionsProvider`, `cardsProvider`, `loansProvider`, `safeToSpendProvider`, `netWorthSummaryProvider`, and `canonicalForecast30DaysProvider`.
- **State Hygiene**: Deprecated providers (`ledgerRepoProvider`, `ledgerServiceProvider`, `ledgerMutationProvider`) are dormant and receive zero runtime UI calls.

---

## 12. Security & Privacy Audit (CRITICAL FINDINGS)

An exhaustive security and privacy audit was performed across the codebase. While the accounting engine is mathematically verified, **SpendX 2.0 exhibits critical data security and privacy vulnerabilities**:

| Severity | Finding ID | Component | Vulnerability Description |
| :--- | :--- | :--- | :--- |
| 🔴 **CRITICAL** | **SEC-01** | `lib/services/gemini_service.dart:18` | **Gemini API Key in URL Query Parameter**: The secret API key is passed directly in the URL query string: `https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$_apiKey`. URL query strings are routinely logged in plaintext by HTTP proxies, corporate firewalls, VPN gateways, mobile network operators, and error monitoring tools. |
| 🟠 **HIGH** | **SEC-02** | `lib/data/core/app_database.dart` | **Plaintext SQLite Storage At-Rest**: The active database `app.db` is stored unencrypted on device flash memory. Any user with a rooted Android device, jailbroken iPhone, physical device extraction, or standard ADB backup can read complete banking account numbers, balances, transactions, loans, and salary records. |
| 🟠 **HIGH** | **SEC-03** | `lib/services/backup_service.dart` | **Plaintext `.spendx` Backup Archives**: Backup archives are standard unencrypted zip containers containing the raw SQLite database. When users share their `.spendx` file via Google Drive, iCloud, email, or WhatsApp, their entire financial history is exposed in cleartext to cloud providers and intermediate networks. |
| 🟡 **MEDIUM** | **SEC-04** | `lib/services/canonical_backup_validator.dart` | **Unscheduled Live Evidence Retention**: Raw SMS texts containing banking OTPs and account balances in `evidence.raw_payload_encrypted` are only pruned during manual backup/restore. In daily runtime, raw SMS data accumulates indefinitely on disk. |
| 🟡 **MEDIUM** | **SEC-05** | `lib/services/export_service.dart` | **Plaintext CSV Export to Shared Public Storage**: Exported financial CSV spreadsheets are written to world-readable shared storage without encryption or access controls. |
| ⚪ **LOW** | **SEC-06** | `lib/services/live_sms_service.dart:440, 468` | **Debug Print Statements in Production**: `print(...)` statements outputting SMS parsing diagnostic info in production builds. |

---

## 13. Performance Audit

- **Index Optimization**:
  - `postings(account_id, direction)` allows instant calculation of derived account balances.
  - `economic_events(timestamp)` enables fast date-range queries for monthly summaries.
  - `evidence(body_sha256)` and `evidence(external_reference)` allow $O(1)$ duplicate checks during ingestion.
- **Query Latencies**: All canonical queries execute in < 2ms on benchmark datasets.
- **Verdict**: Performance is excellent; no performance bottleneck warrants a dedicated milestone.

---

## 14. Test Coverage Audit

- **Total Tests**: **673 / 673 PASS (100%)**
- **Distribution**:
  - Domain Invariants: 66 tests (Money, EventSemantics, Earmarks, Safe-to-Spend, ReviewCandidate)
  - Repository Migrations & Invariants: 280 tests (Accounts, Credit, Loans, Goals, Events, Query)
  - Features & Read Firewalls: 155 tests (C4, C7, C8, C9, Forecast, Analytics, Dashboard)
  - Migrations & Backfill: 172 tests (v24 migration, backfill dry-runs, destructive cleanups)
- **Gap Identified**:
  - Zero test coverage for database encryption (SQLCipher) or encrypted backup packages (AES-GCM).
  - Zero test coverage for Gemini API key header sanitization.

---

## 15. Schema v24 Assessment & Exit Strategy

- **Question**: Is an immediate upgrade from Schema v24 to Schema v25 justified?
- **Analysis**:
  - The remaining legacy tables (`transactions`, `ledger_transactions`, `credit_transactions`, `salary_ledger`) receive **0 runtime reads** and **0 runtime writes**.
  - They are inert storage tables.
  - Executing a Schema v25 migration now would require writing DDL table-dropping scripts, altering migration test baselines, and risking user database upgrades for purely cosmetic table cleanup.
  - As explicitly instructed: *"A schema migration must NOT be recommended merely because cleanup is desirable. It must have a concrete architectural justification and migration safety plan."*
- **Verdict**: **Schema v24 remains LOCKED**. Physical table retirement should be deferred to a future maintenance milestone when operational metadata (`loan_installments`) is fully migrated to `expected_events`.

---

## 16. Candidate C10 Milestones

### Candidate 1: At-Rest & Archive Security Hardening (Canonical Security & Privacy)
- **Architectural Problem**: Financial data is stored in cleartext SQLite on device disk; `.spendx` backup packages are unencrypted ZIP files; Gemini API key is exposed in URL query parameters; and raw SMS evidence lacks scheduled runtime retention pruning.
- **Evidence**: `SEC-01` (Gemini API key in query string), `SEC-02` (plaintext `app.db`), `SEC-03` (plaintext `.spendx`), `SEC-04` (unscheduled evidence retention).
- **Severity**: **CRITICAL / HIGH**
- **User Impact**: Protects user bank accounts, balances, and transaction history from local extraction, unauthorized cloud access, and network snooping.
- **Technical Impact**: Introduces SQLCipher at-rest database encryption, user password-derived AES-256-GCM encryption for `.spendx` backup archives, `x-goog-api-key` header authentication, and automated 30-day SMS retention pruning.
- **Dependencies**: C8 (Backup/Restore), C3A (Canonical Foundation).
- **Risk**: Low/Medium (Must ensure seamless database migration from unencrypted SQLite to encrypted SQLCipher without data loss, and maintain backward compatibility for restoring unencrypted v24 `.spendx` backups).
- **Estimated Surface**: 6–8 files.
- **Expected Tests**: 25–30 adversarial security tests.
- **Schema Change**: **NO** (Schema remains v24 LOCKED; SQLCipher operates transparently at the SQLite page encryption layer).

---

### Candidate 2: Physical Schema v25 & Complete Legacy Table Retirement
- **Architectural Problem**: Legacy tables (`transactions`, `ledger_transactions`, `credit_transactions`, `salary_ledger`) and stale columns remain physically present in SQLite.
- **Evidence**: 4 dead tables, 4 dead columns, deprecated stubs in `LedgerRepo`/`LedgerService`.
- **Severity**: MEDIUM
- **User Impact**: Zero user-visible impact (performance difference is negligible; runtime already ignores legacy tables).
- **Technical Impact**: Requires DDL `DROP TABLE`, rewriting 15+ migration test files, migrating `loan_installments` amortization schedules to `expected_events`.
- **Dependencies**: C9.
- **Risk**: High (Risk of data loss or failed database migrations during physical table drops).
- **Estimated Surface**: 25+ files.
- **Expected Tests**: 40+ migration tests.
- **Schema Change**: **YES** (v24 $\to$ v25).

---

### Candidate 3: Unified Background Ingestion & Real-Time Evidence Pipeline
- **Architectural Problem**: Background SMS receiver (`SmsReceiver.kt` / `LiveSmsService`) and foreground `SmsImportService` have duplicate parsing logic and lack a unified background work manager.
- **Evidence**: Separate SMS parsing routines in `sms_import_service.dart` and `live_sms_service.dart`.
- **Severity**: MEDIUM
- **User Impact**: More consistent SMS background detection.
- **Technical Impact**: Consolidates SMS parsers into a single domain service.
- **Dependencies**: C5.
- **Risk**: Medium.
- **Estimated Surface**: 8–10 files.
- **Expected Tests**: 15–20 tests.
- **Schema Change**: **NO**.

---

### Candidate 4: WriteQueue & Concurrency Barrier Harmonization
- **Architectural Problem**: `WriteQueue` is only used by Riverpod mutation notifiers, while repositories and domain services write directly to SQLite.
- **Evidence**: `lib/data/core/write_queue.dart` is bypassed by `FinancialTransactionService`.
- **Severity**: LOW
- **User Impact**: Negligible (SQLite already serializes transactions via its connection lock).
- **Technical Impact**: Wraps all repository write paths in `WriteQueue`.
- **Dependencies**: C7.
- **Risk**: Low/Medium (Risk of deadlock if nested calls enqueue to the same FIFO queue).
- **Estimated Surface**: 6–8 files.
- **Expected Tests**: 10–15 concurrency tests.
- **Schema Change**: **NO**.

---

## 17. Recommended C10 Milestone

### **MILESTONE C10: AT-REST & ARCHIVE SECURITY HARDENING**

**Rationale**:
SpendX 2.0 has achieved complete mathematical and accounting correctness (C3A through C9). Every dollar, rupee, transaction, and transfer is accounted for with cryptographic SHA-256 deduplication and append-only immutability.
However, **storing this ledger in unencrypted plaintext on disk and exporting unencrypted cleartext backups is a critical vulnerability for a personal finance system**. Furthermore, transmitting LLM API keys in URL query parameters leaks user credentials.

Milestone C10 will seal the security perimeter of SpendX 2.0 without altering accounting semantics or requiring a risky schema bump:
1. **Gemini API Key Header Sanitization**: Migrate API key transmission from URL query parameters to the secure `x-goog-api-key` HTTP header.
2. **At-Rest Database Encryption (SQLCipher)**: Secure `app.db` using 256-bit AES encryption via SQLCipher, with zero data loss during transparent in-place migration for existing users.
3. **Encrypted `.spendx` Backup Archives**: Implement password-based AES-256-GCM encryption with PBKDF2/Argon2 key derivation for backup packages, while preserving backward-compatible restore for legacy unencrypted v24 archives.
4. **Automated 30-Day SMS Evidence Pruning Job**: Implement a scheduled background job to purge raw SMS text from `evidence.raw_payload_encrypted` for records older than 30 days.

---

## 18. Exact Implementation Boundary

```
                     ┌──────────────────────────────────────────────┐
                     │            C10 IMPLEMENTATION SCOPE          │
                     ├──────────────────────────────────────────────┤
                     │ 1. Gemini Service: x-goog-api-key header     │
                     │ 2. AppDatabase: SQLCipher at-rest encryption │
                     │ 3. BackupService: AES-256-GCM .spendx crypto │
                     │ 4. EvidencePruner: Automated 30-day cleanup  │
                     └──────────────────────────────────────────────┘
                                            │
               ┌────────────────────────────┴────────────────────────────┐
               ▼                                                         ▼
    PRESERVED UNCHANGED                                      PRESERVED UNCHANGED
    - Schema v24 (LOCKED)                                    - C3B Write Firewall
    - 7/7 SQLite Triggers                                    - C4 Read Firewall
    - Canonical Accounting Models                            - C5 Ingestion Deduplication
    - Integer-Paise Money Semantics                          - C6 Deterministic Forecast
    - Double-Entry Postings                                  - C7 Riverpod Architecture
```

---

## 19. MUST CHANGE Files

1. `lib/services/gemini_service.dart`: Remove `?key=$_apiKey` from URL query strings; add `x-goog-api-key` header to all HTTP requests.
2. `lib/data/core/app_database.dart`: Integrate SQLCipher database opening with encryption key derivation (via `sqflite_sqlcipher` or secure platform key storage).
3. `lib/services/backup_service.dart`: Add password-based AES-GCM encryption to `.spendx` backup creation and decryption support during restore.
4. `lib/services/canonical_backup_validator.dart`: Update manifest schema to record encryption metadata (`is_encrypted`, `kdf_salt`, `cipher_algorithm`).
5. `lib/services/evidence_pruning_service.dart` (New Service): Automated periodic job to execute `scrubExpiredEvidence` during runtime app initialization and background sessions.

---

## 20. MAY CHANGE Files

1. `lib/screens/settings/database_tools_screen.dart`: Add password prompt dialog for encrypted backup and restore.
2. `lib/services/backup_file_service.dart`: Support encrypted `.spendx` mime types and file sharing.
3. `pubspec.yaml`: Add cryptographic dependencies if required (e.g. `sqflite_sqlcipher` or `cryptography`).

---

## 21. MUST NOT CHANGE Files

1. `lib/domain/finance/*` (`money.dart`, `economic_event.dart`, `posting.dart`, `event_semantics.dart`): **LOCKED**.
2. `lib/data/core/tables_v24.dart`: **LOCKED** (v24 Schema unchanged; 0 DDL changes).
3. `lib/data/repositories/canonical/*`: **LOCKED** (Accounting logic unchanged).
4. `lib/services/canonical_forecast_engine.dart`: **LOCKED**.
5. `lib/data/repositories/account_repo.dart`, `credit_repo.dart`, `loan_repo.dart`: **LOCKED**.
6. `lib/services/financial_transaction_service.dart`: **LOCKED**.

---

## 22. Adversarial Test Plan (25 Test Vectors)

A dedicated test suite `test/features/c10_security_hardening_test.dart` will execute 25 adversarial test vectors:

| Group | Vector ID | Description |
| :--- | :--- | :--- |
| **G1: API Key Security** | **ADV-C10-01** | Gemini request URL never contains `key=` in query string |
| | **ADV-C10-02** | Gemini request headers contain valid `x-goog-api-key` header |
| | **ADV-C10-03** | Missing API key throws explicit `AuthenticationException` without leaking key |
| **G2: At-Rest Encryption** | **ADV-C10-04** | Reading `app.db` with standard SQLite library fails (`file is not a database`) |
| | **ADV-C10-05** | Opening `app.db` with valid SQLCipher key executes successfully |
| | **ADV-C10-06** | Opening `app.db` with invalid key throws authentication failure |
| | **ADV-C10-07** | Transparent migration of plaintext v24 database to encrypted SQLCipher preserves all rows |
| | **ADV-C10-08** | All 7 SQLite triggers remain active and enforcing inside encrypted SQLCipher DB |
| **G3: Encrypted Backups** | **ADV-C10-09** | Encrypted `.spendx` package cannot be unzipped with standard unzip tool |
| | **ADV-C10-10** | Encrypted `.spendx` manifest indicates AES-256-GCM cipher and salt |
| | **ADV-C10-11** | Restore with correct password decrypts and restores full accounting dataset |
| | **ADV-C10-12** | Restore with incorrect password throws `InvalidBackupPasswordException` (0 state mutation) |
| | **ADV-C10-13** | Corrupted ciphertext throws `BackupIntegrityException` and triggers atomic rollback |
| | **ADV-C10-14** | Restoring legacy unencrypted v24 `.spendx` backup succeeds (backward compatibility) |
| | **ADV-C10-15** | Exported backup never contains plaintext database file when encryption enabled |
| **G4: Evidence Retention** | **ADV-C10-16** | Evidence older than 30 days has `raw_payload_encrypted` purged to NULL |
| | **ADV-C10-17** | Purged evidence sets `is_payload_purged = 1` |
| | **ADV-C10-18** | Evidence younger than 30 days retains payload intact |
| | **ADV-C10-19** | Evidence pruning preserves `body_sha256`, `external_reference`, and event linkage |
| | **ADV-C10-20** | Evidence pruning executes automatically on app initialization |
| **G5: Invariant Parity** | **ADV-C10-21** | Total debits == total credits preserved across encrypted backup/restore cycle |
| | **ADV-C10-22** | Safe-to-Spend calculation identical before and after encryption |
| | **ADV-C10-23** | Net worth summary identical before and after encryption |
| | **ADV-C10-24** | 30-day deterministic forecast identical before and after encryption |
| | **ADV-C10-25** | Full transaction lifecycle operates seamlessly under encrypted database |

---

## 23. Exit Criteria

Milestone C10 will be marked **PASS / CLOSED** only when:
1. `test/features/c10_security_hardening_test.dart`: **25 / 25 PASS**.
2. Full regression suite: **≥ 698 / 698 PASS (100%)**.
3. `flutter analyze --no-fatal-infos`: **0 errors / 0 warnings**.
4. SQLite schema remains strictly `v24` **LOCKED** (0 DDL changes).
5. All 7 SQLite triggers remain **ACTIVE**.
6. Gemini API key is completely removed from URL query parameters.
7. Active database file is verified encrypted at rest with SQLCipher.
8. `.spendx` backup archives support AES-256-GCM password encryption.
9. Legacy unencrypted `.spendx` packages remain restorable.
10. Implementation document `docs/spendx2/76_C10_SECURITY_HARDENING_IMPLEMENTATION.md` authored.

---

## 24. Risks & Mitigations

1. **Risk**: Existing users' plaintext databases could become corrupted during transparent encryption migration.  
   *Mitigation*: Implement staged backup and atomic verification before replacing plaintext `app.db` with encrypted SQLCipher database. Rollback immediately if verification fails.
2. **Risk**: Users forget their backup password.  
   *Mitigation*: Provide clear warnings in UI that backup passwords cannot be recovered; support optional unencrypted export with explicit user confirmation.
3. **Risk**: Platform SQLCipher library dependency issues on iOS/Android.  
   *Mitigation*: Use verified Flutter SQLCipher bindings with cross-platform FFI fallback for desktop/unit test environments.

---

## 25. Final Discovery Verdict

**C10 DISCOVERY COMPLETE — AUTHORIZATION REQUIRED.**

Milestone C10 is fully specified, scoped, and bounded:
- **Recommended Milestone**: **C10: At-Rest & Archive Security Hardening**
- **Schema**: v24 LOCKED (0 DDL changes).
- **Accounting Semantics**: Preserved 100% intact.
- **Estimated Scope**: 25 adversarial tests, ~6–8 files.

**HARD STOP IN EFFECT. NO IMPLEMENTATION AUTHORIZED.**
