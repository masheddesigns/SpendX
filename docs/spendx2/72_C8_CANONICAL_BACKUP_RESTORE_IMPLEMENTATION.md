# SpendX 2.0 — Milestone C8 Implementation Report
## Canonical Backup & Restore Verification & Hardening

**Document ID**: `SPENDX2-C8-IMPL-001`  
**Status**: APPROVED / CLOSED  
**Date**: October 4, 2026  
**Milestone**: C8 — Canonical Backup & Restore — Implementation  
**SQLite Schema Version**: v24 (LOCKED)  
**Database Triggers**: 7/7 ACTIVE  
**Full Test Suite**: 643 / 643 PASS (100%)  
**Adversarial Vectors**: 36 / 36 PASS (100%)  
**Static Analysis**: 0 Errors, 0 Warnings  

---

## 1. Executive Summary

Milestone C8 replaces the legacy, unverified database backup/restore mechanism with a hardened, canonical, cryptographic `.spendx` package format. 

Prior to C8, backup and restore posed significant financial integrity hazards:
1. **Unverified Database Replacement**: Backups could overwrite the active SQLite database without verifying schema version, double-entry parity, or SQLite integrity.
2. **Double-Counting & Phantom Postings**: There was risk of merging or replaying events through domain transaction services, violating the core principle that backup/restore is an exact point-in-time persistence snapshot.
3. **Privacy Violations**: Sensitive raw SMS messages were bundled without privacy lifecycle enforcement, violating the 30-day raw SMS retention policy.
4. **Stale In-Memory State**: Restoring a database file left in-memory Riverpod provider caches and UI view models bound to old database data.
5. **No Rollback Protection**: A corrupted or incomplete restore could corrupt the primary database with no atomic recovery guarantee.

Milestone C8 eliminates all of these vulnerabilities through:
- A hardened `.spendx` ZIP container containing a vacuumed SQLite snapshot (`spendx.db`) and cryptographic manifest (`manifest.json`).
- Non-negotiable accounting isolation: Restore is **REPLACE ONLY** and produces **0 new economic events and 0 new postings**.
- An exhaustive multi-layer staging validation pipeline (`CanonicalBackupValidator`).
- Atomic database file replacement with automatic rollback on any failure.
- Synchronous raw SMS retention scrubbing (30-day privacy rule).
- Complete Riverpod financial provider invalidation (`invalidateAllFinancialProviders`).

---

## 2. Baseline Verification

Before and after the C8 implementation, the locked baseline was verified:

| Baseline Criterion | Expected | Verified Status |
| :--- | :--- | :--- |
| **C3B Write Firewall** | Provider direct accounting writes = 0 | 🟢 INTACT |
| **C4 Read Firewall** | `ILLEGAL_STALE_AUTHORITY = 0` | 🟢 INTACT |
| **C5 Ingestion / Dedup** | Evidence decoupled; pre-approval creates 0 postings | 🟢 INTACT |
| **C6 Forecast Engine** | Canonical forecast authority = 1 | 🟢 INTACT |
| **C7 Riverpod State** | Unified reactive invalidation graph | 🟢 INTACT |
| **SQLite Schema** | Version 24 LOCKED | 🟢 v24 LOCKED |
| **SQLite Triggers** | 7/7 ACTIVE | 🟢 7/7 ACTIVE |
| **C8 Test Suite** | 36 / 36 PASS | 🟢 36 / 36 PASS |
| **Full Regression Suite** | 643 / 643 PASS | 🟢 643 / 643 PASS |
| **Flutter Static Analysis** | 0 errors, 0 warnings | 🟢 0 errors, 0 warnings |

---

## 3. Architecture & File Format Specification

### 3.1 Container Structure
The `.spendx` backup file is a ZIP archive containing two files at its root:
```
my_backup.spendx (ZIP container)
 ├── manifest.json
 └── spendx.db
```

### 3.2 Backup Manifest (`manifest.json`)
The manifest encapsulates cryptographic integrity, structural metadata, and domain metrics:
```json
{
  "format_version": 2,
  "app_version": "2.0.0",
  "created_at": "2026-10-04T18:00:00.000Z",
  "schema_version": 24,
  "sha256": "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945",
  "database_bytes": 1048576,
  "metrics": {
    "account_count": 6,
    "transaction_count": 42,
    "category_count": 14,
    "budget_count": 3,
    "goal_count": 2,
    "loan_count": 1,
    "credit_card_count": 1,
    "economic_event_count": 42,
    "posting_count": 84,
    "review_candidate_count": 0,
    "evidence_count": 42,
    "balance_reconciliation_count": 6
  }
}
```

### 3.3 Snapshot Mechanism
To ensure point-in-time consistency without lock contention or dirty WAL pages:
1. `PRAGMA wal_checkpoint(TRUNCATE)` is executed to commit all WAL pages into the database file.
2. `VACUUM INTO '<staged_path>'` is executed to produce a clean, defragmented snapshot of the live database in a single atomic SQLite operation.

---

## 4. Multi-Layer Staging Validation Pipeline

Every restore candidate must pass an exhaustive 10-layer validation suite executed on an isolated staging database before touching the live database:

```
Restore Request (.spendx)
       │
       ▼
1. Package Unpack & Archive Inspection (ZIP structure, file presence)
       │
       ▼
2. Manifest Validation (Format version == 2, Schema version == 24)
       │
       ▼
3. Cryptographic Verification (SHA-256 match against spendx.db bytes)
       │
       ▼
4. Stage Isolated SQLite Database (/cache/restore_stage/spendx.db)
       │
       ▼
5. SQLite Low-Level Pragma Checks (PRAGMA integrity_check == 'ok', foreign_key_check)
       │
       ▼
6. Schema Version Verification (PRAGMA user_version == 24)
       │
       ▼
7. Structural Conformance (18 canonical tables + 7 active triggers present)
       │
       ▼
8. Double-Entry Accounting Invariant Enforcement:
   • Total Debits == Total Credits on all posted economic events
   • Zero non-positive postings (amount <= 0 rejected)
   • Zero orphaned postings (all postings belong to valid events & accounts)
   • Mandatory system accounts exist
   • Pending review candidates have 0 postings and 0 events
       │
       ▼
9. 30-Day SMS Privacy Retention Scrubbing
       │
       ▼
10. Atomic File Swap with Automatic Rollback
```

---

## 5. Atomic Replacement & Rollback Engine

Database replacement is handled in `BackupService` through a fail-safe atomic transaction:
1. Close all active database connections.
2. Stage pre-restore active database to `app_database.db.pre_restore_backup`.
3. Copy validated `spendx.db` to active database path (`app_database.db`).
4. Reopen connection to new database and execute `PRAGMA quick_check`.
5. On **SUCCESS**: Delete `pre_restore_backup` and cleanup staging directory.
6. On **FAILURE**: Automatically roll back `pre_restore_backup` to active path, reopen database, cleanup staging directory, and throw `BackupValidationException`.

---

## 6. Privacy & Retention Policy

SpendX enforces a 30-day raw SMS retention rule:
- Before backup creation: `CanonicalBackupValidator.scrubExpiredSmsEvidence()` purges raw SMS content older than 30 days.
- During restore validation: Any raw SMS evidence older than 30 days present in the backup is immediately scrubbed in the staged database before deployment.
- Processed financial transactions, economic events, and postings remain permanent; only raw SMS body text is purged.

---

## 7. Centralized Riverpod State Invalidation

Upon completion of restore or database reset, `invalidateAllFinancialProviders(ref)` or `invalidateAllFinancialProvidersWithContainer(container)` is invoked:
- Fires `DataChangeBus.instance.notifyListeners()`.
- Invalidates all 14 core financial providers:
  - `transactionsProvider`
  - `accountsProvider`
  - `categoriesProvider`
  - `budgetsProvider`
  - `goalsProvider`
  - `loansProvider`
  - `creditCardsProvider`
  - `reviewQueueProvider`
  - `reviewCandidatesProvider`
  - `safeToSpendProvider`
  - `netWorthSummaryProvider`
  - `analyticsSummaryProvider`
  - `forecastProvider`
  - `runwayProvider`
- Triggers instant UI rebuild without requiring an application restart.

---

## 8. Adversarial Test Vectors (36/36 PASS)

The test suite in `test/features/c8_canonical_backup_restore_test.dart` verifies all 36 specified scenarios:

| Vector ID | Test Scenario | Result |
| :--- | :--- | :--- |
| **ADV-01** | Empty database round-trip (schema v24, system accounts, 0 transactions) | 🟢 PASS |
| **ADV-02** | Normal multi-account financial dataset round-trip | 🟢 PASS |
| **ADV-03** | Multiple accounts (assets, liabilities, equity) fidelity | 🟢 PASS |
| **ADV-04** | Income event and postings round-trip fidelity | 🟢 PASS |
| **ADV-05** | Expense event and postings round-trip fidelity | 🟢 PASS |
| **ADV-06** | Account-to-account transfer round-trip balance fidelity | 🟢 PASS |
| **ADV-07** | Credit card purchase event and liability posting fidelity | 🟢 PASS |
| **ADV-08** | Credit card bill payment and bank debit round-trip | 🟢 PASS |
| **ADV-09** | Refund event with multi-leg reversals preserved | 🟢 PASS |
| **ADV-10** | Loan disbursement event and liability establishment | 🟢 PASS |
| **ADV-11** | Loan EMI repayment 3-leg split preserved | 🟢 PASS |
| **ADV-12** | Goal asset earmark relationships intact after restore | 🟢 PASS |
| **ADV-13** | Recurring rules and frequency settings survive restore | 🟢 PASS |
| **ADV-14** | Expected events and fulfillment pointers survive restore | 🟢 PASS |
| **ADV-15** | Review candidate in review queue remains non-accounting after restore | 🟢 PASS |
| **ADV-16** | Approved review candidate produces identical ledger postings | 🟢 PASS |
| **ADV-17** | Ingestion evidence fingerprint (SHA-256) and external references survive | 🟢 PASS |
| **ADV-18** | Account balance reconciliation records preserved with provenance | 🟢 PASS |
| **ADV-19** | Corrupt package (invalid zip structure) rejected | 🟢 PASS |
| **ADV-20** | Truncated package (0 bytes) rejected | 🟢 PASS |
| **ADV-21** | Incompatible schema version (> 24 or < 24) rejected without touching active DB | 🟢 PASS |
| **ADV-22** | SQLite foreign key violation in staging DB triggers validation error | 🟢 PASS |
| **ADV-23** | Unbalanced journal postings in staging DB triggers immediate rejection | 🟢 PASS |
| **ADV-24** | Non-positive posting amount (amount <= 0) rejected | 🟢 PASS |
| **ADV-25** | SHA-256 checksum mismatch on spendx.db rejected | 🟢 PASS |
| **ADV-26** | Legacy format 1 backup detected and rejected | 🟢 PASS |
| **ADV-27** | Failed restore leaves active DB completely untouched | 🟢 PASS |
| **ADV-28** | Post-restore validation failure triggers automatic rollback to pre-restore state | 🟢 PASS |
| **ADV-29** | Staging directory cleaned up after restore attempt | 🟢 PASS |
| **ADV-30** | Checkpoint flushes WAL cleanly during backup creation | 🟢 PASS |
| **ADV-31** | 30-day SMS evidence purged before backup and after restore for expired items | 🟢 PASS |
| **ADV-32** | Cache invalidation refreshes Riverpod state after restore | 🟢 PASS |
| **ADV-33** | Net worth equality verified before backup and after restore | 🟢 PASS |
| **ADV-34** | Safe-to-spend calculation identical before backup and after restore | 🟢 PASS |
| **ADV-35** | 30-day forecast output and runway identical before and after restore | 🟢 PASS |
| **ADV-36** | Restore strictly non-accounting after restore (0 events, 0 postings) | 🟢 PASS |

---

## 9. Conclusion & Milestone Status

Milestone C8 is **COMPLETE, VERIFIED, AND CLOSED**.

All persistence and backup operations strictly adhere to canonical double-entry accounting rules, schema v24 invariants, privacy retention guidelines, and reactive invalidation protocols.

**HARD STOP**: Do not begin Milestone C9 discovery or implementation until explicitly requested and authorized by the user.
