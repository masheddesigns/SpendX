# SpendX 2.0 — Milestone C2C Destructive Schema Cleanup Report

**Status:** APPROVED & LOCKED  
**Date:** October 3, 2026  
**Auditor / Verification Suite:** SpendX Automated Test Runner (`test/migrations/migration_c2c_destructive_cleanup_test.dart`, `test/migrations/`)  
**Scope:** Physical Database Destructive Schema Cleanup Review & Execution  
**Milestone Gate Decision:** **`C2C PASS — READY FOR C3 REPOSITORY TRANSITION`**

---

## 1. Scope of Milestone C2C

Milestone C2C performed an exhaustive dependency audit and physical schema cleanup of the SpendX SQLite database. Specifically, this phase:
1. Evaluated all 40 physical tables established in the baseline (`36_PHYSICAL_SCHEMA_BASELINE.md`).
2. Identified and physically dropped only obsolete tables that have **zero remaining role** in canonical v24 accounting, verification, audit, or existing active repositories.
3. Prohibited any repository transition, Dart model removal, or provider rewrite (preserving all C3 boundaries).
4. Strictly preserved `allowDestructiveDrops = false` as the immutable default gate.
5. Proved 100% mathematical financial parity before and after destructive cleanup.

---

## 2. Master Destruction Inventory (All 40 Tables + Auxiliaries)

| # | Object Name | Classification | Evidence & Rationale | Final C2C Disposition |
|---|---|---|---|---|
| 1 | `accounts` | `KEEP_CANONICAL` | Double-entry chart of accounts (Assets, Liabilities, Equity, Income, Expense). | **RETAINED** |
| 2 | `economic_events` | `KEEP_CANONICAL` | Canonical financial event journal with draft $\to$ posted lifecycle. | **RETAINED** |
| 3 | `evidence` | `KEEP_CANONICAL` | Ingestion metadata, audit trail, and 30-day raw SMS retention boundary. | **RETAINED** |
| 4 | `postings` | `KEEP_CANONICAL` | Double-entry balanced legs ($\sum \text{Debits} = \sum \text{Credits}$). | **RETAINED** |
| 5 | `asset_earmarks` | `KEEP_CANONICAL` | Virtual goal allocations governing Safe-to-Spend derived liquidity. | **RETAINED** |
| 6 | `recurring_rules` | `KEEP_CANONICAL` | Recurring transaction rules and commitments engine. | **RETAINED** |
| 7 | `expected_events` | `KEEP_CANONICAL` | Cashflow forecast schedule and commitment obligations. | **RETAINED** |
| 8 | `review_candidates` | `KEEP_CANONICAL` | Ingested SMS/OCR candidates pending user review; isolated from ledger. | **RETAINED** |
| 9 | `opening_balance_reconciliations` | `KEEP_CANONICAL` | Audit provenance for legacy $\leftrightarrow$ v24 reconstructed balance parity. | **RETAINED** |
| 10 | `migration_exceptions` | `KEEP_CANONICAL` | Quarantined legacy records with non-positive amounts or unmapped types. | **RETAINED** |
| 11 | `vehicles` | `DROP_VEHICLE` | Vehicle subsystem pruned in Milestone A. Zero models, repositories, or UI screens. | **DROPPED** (when flag = true) |
| 12 | `fuel_logs` | `DROP_VEHICLE` | Pruned in Milestone A. Ordinary fuel expenses live in `transactions` under Transport/Fuel. | **DROPPED** (when flag = true) |
| 13 | `vehicle_reminders` | `DROP_VEHICLE` | Pruned in Milestone A. Ordinary reminders live in `reminders`. | **DROPPED** (when flag = true) |
| 14 | `bank_balance_snapshots` | `DROP_OBSOLETE` | Pre-v21 cache. Zero active repository or model consumers in application code. | **DROPPED** (when flag = true) |
| 15 | `transactions` | `KEEP_TRANSITIONAL` | User-facing transactions table; actively used by `TransactionRepo` pending C3. Preserves soft-delete audit trail. | **RETAINED** |
| 16 | `ledger_transactions` | `KEEP_TRANSITIONAL` | Interim v21 single-entry journal; actively queried by `LedgerRepo` pending C3. | **RETAINED** |
| 17 | `bank_accounts` | `KEEP_TRANSITIONAL` | Depository accounts table; actively queried by `AccountRepo` pending C3. | **RETAINED** |
| 18 | `categories` | `KEEP_TRANSITIONAL` | Category taxonomy; queried by `CategoryRepo` pending C3. | **RETAINED** |
| 19 | `credit_cards` | `KEEP_TRANSITIONAL` | Card accounts; queried by `CreditCardRepo` pending C3. | **RETAINED** |
| 20 | `credit_transactions` | `KEEP_TRANSITIONAL` | Legacy credit card entries; queried by card services pending C3. | **RETAINED** |
| 21 | `credit_emis` | `KEEP_TRANSITIONAL` | Card EMI plans; queried by EMI services pending C3. | **RETAINED** |
| 22 | `emi_installments` | `KEEP_TRANSITIONAL` | EMI schedule installments; queried by EMI services pending C3. | **RETAINED** |
| 23 | `emi_plans` | `KEEP_TRANSITIONAL` | Card EMI plans; queried by EMI services pending C3. | **RETAINED** |
| 24 | `card_statements` | `KEEP_TRANSITIONAL` | Statement snapshot records; queried by statement services pending C3. | **RETAINED** |
| 25 | `loans` | `KEEP_TRANSITIONAL` | Loan accounts; queried by `LoanRepo` pending C3. | **RETAINED** |
| 26 | `loan_installments` | `KEEP_TRANSITIONAL` | Loan schedules; queried by `LoanRepo` pending C3. | **RETAINED** |
| 27 | `lendings` | `KEEP_TRANSITIONAL` | P2P lendings; queried by `LendingRepo` pending C3. | **RETAINED** |
| 28 | `budgets` | `KEEP_TRANSITIONAL` | Categorical spending limits; limit amounts converted to minor units in v24. | **RETAINED** |
| 29 | `tags` | `KEEP_TRANSITIONAL` | Tag taxonomy; queried by `TagRepo` pending C3. | **RETAINED** |
| 30 | `recurring_templates` | `KEEP_TRANSITIONAL` | Recurring schedule templates; queried by recurring service pending C3. | **RETAINED** |
| 31 | `reminders` | `KEEP_TRANSITIONAL` | Notification scheduling; queried by reminder service pending C3. | **RETAINED** |
| 32 | `companies` | `KEEP_TRANSITIONAL` | Employer entities; queried by salary service pending C3. | **RETAINED** |
| 33 | `salary_contracts` | `KEEP_TRANSITIONAL` | Employment compensation contracts; queried by salary service pending C3. | **RETAINED** |
| 34 | `salary_payments` | `KEEP_TRANSITIONAL` | Monthly compensation entries; queried by salary service pending C3. | **RETAINED** |
| 35 | `salary_increments` | `KEEP_TRANSITIONAL` | Compensation increase history; queried by salary service pending C3. | **RETAINED** |
| 36 | `salary` | `KEEP_TRANSITIONAL` | Legacy salary records; queried by salary service pending C3. | **RETAINED** |
| 37 | `salary_months` | `KEEP_TRANSITIONAL` | Monthly salary expectations; queried by salary service pending C3. | **RETAINED** |
| 38 | `salary_ledger` | `KEEP_TRANSITIONAL` | Salary journal; queried by salary service pending C3. | **RETAINED** |
| 39 | `goals` | `KEEP_TRANSITIONAL` | Savings targets; queried by `GoalRepo` pending C3. | **RETAINED** |
| 40 | `goal_logs` | `KEEP_TRANSITIONAL` | Goal contributions; queried by `GoalRepo` pending C3. | **RETAINED** |
| 41 | `net_worth_history` | `KEEP_TRANSITIONAL` | Analytical net worth cache; queried by net worth services pending C3. | **RETAINED** |
| 42 | `health_score_history`| `KEEP_TRANSITIONAL` | Analytical score cache; queried by health service pending C3. | **RETAINED** |
| 43 | `merchant_rules` | `KEEP_TRANSITIONAL` | Keyword ingestion dictionary; queried by SMS parser pending C3. | **RETAINED** |
| 44 | `review_queue` | `KEEP_TRANSITIONAL` | Legacy review buffer; queried by review UI pending C3. | **RETAINED** |
| 45 | `streaks` | `KEEP_TRANSITIONAL` | Engagement state; zero accounting impact. | **RETAINED** |
| 46 | `challenges` | `KEEP_TRANSITIONAL` | Engagement state; zero accounting impact. | **RETAINED** |
| 47 | `achievements` | `KEEP_TRANSITIONAL` | Engagement state; zero accounting impact. | **RETAINED** |
| 48 | `app_sessions` | `KEEP_TRANSITIONAL` | Local telemetry; zero accounting impact. | **RETAINED** |
| 49 | `insight_compliance` | `KEEP_TRANSITIONAL` | AI analytics loop; zero accounting impact. | **RETAINED** |
| 50 | `ledger_backfill_log`| `KEEP_TRANSITIONAL` | Historical migration audit log. | **RETAINED** |
| 51 | `sms_import_buffer` | `DROP_OBSOLETE` | Speculative table; never physically existed in SQLite schema. | **NO-OP** |

---

## 3. Dependency Audit of Candidate Drop Objects

A codebase-wide search across `lib/` and `test/` for each candidate table confirmed the following:

### 1. `vehicles`
* **Purpose:** Vehicle asset storage (odometer, registration).
* **Code References:**
  - `lib/data/core/tables.dart:202` (v23 DDL definition)
  - `lib/data/repositories/maintenance_repo.dart:46` (included in `clearAllData()` tables list; wrapped in `try/catch`)
  - `lib/services/database_helper.dart:320` (included in `cleanDatabase()` tables list; wrapped in `try/catch`)
* **SQL References:** None in active application logic.
* **Foreign Key References:** Zero tables reference `vehicles`.
* **Triggers / Indexes:** None.
* **Active Repository / UI Dependencies:** **ZERO**. All vehicle models and screens were pruned in Milestone A.
* **Reason Safe to Remove:** Completely dead schema artifact.

### 2. `fuel_logs`
* **Purpose:** Vehicle fuel fill-up logs.
* **Code References:** `tables.dart:218`, `maintenance_repo.dart:47`, `database_helper.dart:321` (all clean/clear loops with error suppression).
* **SQL References:** None in active application logic.
* **Foreign Key References:** Zero tables reference `fuel_logs`.
* **Triggers / Indexes:** None.
* **Active Repository / UI Dependencies:** **ZERO**. Normal fuel expenses are recorded as ordinary `transactions` under Transport/Fuel.
* **Reason Safe to Remove:** Completely dead schema artifact.

### 3. `vehicle_reminders`
* **Purpose:** Odometer-based vehicle maintenance alerts.
* **Code References:** `tables.dart:234`, `schema_validator.dart:110`, `database_helper.dart:322`.
* **SQL References:** None in active application logic.
* **Foreign Key References:** Zero tables reference `vehicle_reminders`.
* **Triggers / Indexes:** None.
* **Active Repository / UI Dependencies:** **ZERO**. Ordinary reminders use the `reminders` table.
* **Action Taken:** Updated [`SchemaValidator.validate()`](file:///Users/sivek/Documents/SpendX/lib/data/core/schema_validator.dart#L125) to recognize `vehicle_reminders` as an intentionally dropped table on schema version $\ge 24$.
* **Reason Safe to Remove:** Completely dead schema artifact.

### 4. `bank_balance_snapshots`
* **Purpose:** Pre-v21 bank balance snapshot cache.
* **Code References:** `tables.dart:41`, `schema_validator.dart:104`, `maintenance_repo.dart:52`, `database_helper.dart:345`, `backup_service.dart:429`.
* **SQL References:** None in active application logic.
* **Foreign Key References:** Zero tables reference `bank_balance_snapshots`.
* **Triggers / Indexes:** None.
* **Active Repository / UI Dependencies:** **ZERO**. No repository queries or updates this table. Historical balances are derived from double-entry postings.
* **Action Taken:** Updated `SchemaValidator.validate()` to recognize it as intentionally dropped on schema version $\ge 24$.
* **Reason Safe to Remove:** Redundant, obsolete cache table.

### 5. `transactions` and `ledger_transactions` Audit
* **Finding:** Both tables have active callers in `TransactionRepo`, `FinancialTransactionService`, and `LedgerRepo`.
* **Decision:** Retained as `KEEP_TRANSITIONAL`. Dropping them in C2C would introduce unresolved repository dependencies, violating the C2C mandate. They will remain intact until C3 repository migration rewrites those repositories to use canonical v24 tables (`postings`, `economic_events`).

---

## 4. Pre-Destruction Snapshot (Baseline Accounting Truth)

Prior to executing destructive cleanup, baseline financial metrics were captured from a comprehensive standard legacy dataset:
* **Total Assets:** `₹70,000.00` ($7,000,000\text{ paise}$)
* **Total Liabilities:** `₹0.00` ($0\text{ paise}$)
* **Total Equity (Opening Balance Reconciliation):** `₹50,000.00` ($5,000,000\text{ paise}$)
* **Total Income:** `₹25,000.00` ($2,500,000\text{ paise}$)
* **Total Expenses:** `₹5,000.00` ($500,000\text{ paise}$)
* **Net Worth:** `₹70,000.00` ($7,000,000\text{ paise}$)
* **Posted Economic Events Count:** 3
* **Postings Count:** 6
* **Evidence Count:** 3
* **Opening Balance Reconciliations Count:** 1

---

## 5. Cold Backup Verification

1. **Backup Execution:** A cold backup snapshot was created before executing destructive DDL:
   - Target Path: `<db_path>.v23.bak.<timestamp>`
   - Mechanism: SQLite `VACUUM INTO` checkpointed snapshot.
2. **Independent Verification:**
   - File reopened independently using `openDatabase(backupPath)`.
   - `PRAGMA integrity_check`: **`ok`**
   - `PRAGMA foreign_key_check`: **0 violations**
   - `PRAGMA user_version`: **`23`**
   - **Legacy Rows Intact:** Verified all 4 obsolete tables (`vehicles`, `fuel_logs`, `vehicle_reminders`, `bank_balance_snapshots`) exist in the backup file and retain exact pre-migration row data.

---

## 6. Destructive Execution

When `allowDestructiveDrops = true` is explicitly provided, [`MigrationV24Service.approvedDestructiveDropTables`](file:///Users/sivek/Documents/SpendX/lib/data/migrations/migration_v24_service.dart#L93) drops exactly the 4 approved tables:
```sql
DROP TABLE IF EXISTS fuel_logs;
DROP TABLE IF EXISTS vehicle_reminders;
DROP TABLE IF EXISTS vehicles;
DROP TABLE IF EXISTS bank_balance_snapshots;
```
When `allowDestructiveDrops = false` (default), zero `DROP` statements are executed.

---

## 7. Post-Destruction Validation

After running destructive cleanup with `allowDestructiveDrops = true`:
1. **SQLite Integrity:**
   - `PRAGMA integrity_check`: **`ok`**
   - `PRAGMA foreign_key_check`: **0 rows** (zero orphan references)
   - `PRAGMA user_version`: **`24`**
2. **Schema Verification:**
   - Obsolete tables (`vehicles`, `fuel_logs`, `vehicle_reminders`, `bank_balance_snapshots`) do not exist in `sqlite_master`.
   - All 10 canonical v24 tables exist and have valid schemas.
   - All `KEEP_TRANSITIONAL` tables (`transactions`, `ledger_transactions`, `bank_accounts`, `categories`, etc.) exist and are untouched.
3. **Trigger Verification:** All 7 native SQLite immutability and lifecycle triggers exist and remain fully operational:
   - `trg_economic_events_prevent_direct_posted_insert`
   - `trg_economic_events_validate_posted`
   - `trg_postings_prevent_insert_on_posted`
   - `trg_postings_prevent_update_on_posted`
   - `trg_postings_prevent_delete_on_posted`
   - `trg_economic_events_prevent_mutation_on_posted`
   - `trg_economic_events_prevent_delete_posted`
4. **Accounting Invariants:**
   - Global zero-sum: $\sum \text{Debits} = \sum \text{Credits}$ across all postings.
   - Per-event balanced: every posted event has $\ge 2$ postings with zero net imbalance.
   - Immutability: direct inserts into posted events, mutating postings of posted events, or deleting posted events are aborted by SQLite triggers.
   - Draft isolation: draft events contribute 0 to posted balances and metrics.

---

## 8. Financial Parity After Destruction

A side-by-side comparison between Database A (`allowDestructiveDrops = false`) and Database B (`allowDestructiveDrops = true`) with identical data:

| Metric | Before Destruction (DB A) | After Destruction (DB B) | Mathematical Delta |
| :--- | :--- | :--- | :--- |
| **Total Assets** | ₹70,000.00 (7,000,000 paise) | ₹70,000.00 (7,000,000 paise) | **₹0.00 (Exact Equality)** |
| **Total Liabilities** | ₹0.00 (0 paise) | ₹0.00 (0 paise) | **₹0.00 (Exact Equality)** |
| **Total Equity** | ₹50,000.00 (5,000,000 paise) | ₹50,000.00 (5,000,000 paise) | **₹0.00 (Exact Equality)** |
| **Total Income** | ₹25,000.00 (2,500,000 paise) | ₹25,000.00 (2,500,000 paise) | **₹0.00 (Exact Equality)** |
| **Total Expenses** | ₹5,000.00 (500,000 paise) | ₹5,000.00 (500,000 paise) | **₹0.00 (Exact Equality)** |
| **Net Worth** | ₹70,000.00 (7,000,000 paise) | ₹70,000.00 (7,000,000 paise) | **₹0.00 (Exact Equality)** |
| **Posted Economic Events** | 3 | 3 | **0 (Identical Count)** |
| **Postings Count** | 6 | 6 | **0 (Identical Count)** |
| **Evidence Count** | 3 | 3 | **0 (Identical Count)** |
| **Reconciliations Count** | 1 | 1 | **0 (Identical Count)** |

Zero financial values were changed. Only the 4 approved obsolete tables were removed.

---

## 9. Failure Safety & Idempotency Audit

1. **Failure A (Destruction Disabled):** Calling `migrate(db, allowDestructiveDrops: false)` executes zero drops; all tables remain.
2. **Failure B (Injected Crash During Migration):** When an unhandled error or assertion occurs inside the migration transaction, the transaction rolls back atomically. `user_version` remains at the pre-migration state, and zero tables are dropped.
3. **Failure C (Repeated Migration Execution):** Calling `migrate(db, allowDestructiveDrops: true)` on an already-migrated v24 database immediately returns `alreadyMigrated: true` without appending duplicate rows or modifying existing tables.

---

## 10. Remaining Legacy Boundary

The following tables remain physically present in the database as **`KEEP_TRANSITIONAL`**:
* `transactions`, `ledger_transactions`, `bank_accounts`, `categories`, `credit_cards`, `credit_transactions`, `credit_emis`, `emi_installments`, `emi_plans`, `card_statements`, `loans`, `loan_installments`, `lendings`, `budgets`, `tags`, `recurring_templates`, `reminders`, `companies`, `salary_contracts`, `salary_payments`, `salary_increments`, `salary`, `salary_months`, `salary_ledger`, `goals`, `goal_logs`, `net_worth_history`, `health_score_history`, `merchant_rules`, `review_queue`, `streaks`, `challenges`, `achievements`, `app_sessions`, `insight_compliance`, `ledger_backfill_log`.

**Rationale for Retention:** Existing repository classes (`TransactionRepo`, `AccountRepo`, `LedgerRepo`, `BudgetRepo`, `GoalRepo`, etc.) still query these tables. They must remain intact until Milestone C3 systematically migrates each repository domain to read and write to the canonical v24 double-entry engine.

---

## 11. Test Execution Summary

* **Dedicated C2C Destructive Cleanup Suite:**
  - `test/migrations/migration_c2c_destructive_cleanup_test.dart`: **15 / 15 passed**
* **Total Migration Suites:**
  - `test/migrations/`: **54 / 54 passed**
* **Repository-Wide Test Suite:**
  - `flutter test`: **220 / 220 passed**
* **Static Analysis:**
  - `flutter analyze`: **0 errors, 0 warnings** (38 infos in legacy pre-existing files).

---

## 12. Final Gate Declaration

All conditions and requirements of Milestone C2C have been verified:
1. Only approved dead tables (`vehicles`, `fuel_logs`, `vehicle_reminders`, `bank_balance_snapshots`) are dropped.
2. Zero repository dependencies broken.
3. Cold backup independently verified with 100% data recovery.
4. Financial parity before and after destruction is mathematically identical.
5. All 220 repository tests pass with 0 errors and 0 warnings.

```
================================================================================
C2C PASS — READY FOR C3 REPOSITORY TRANSITION
================================================================================
```
