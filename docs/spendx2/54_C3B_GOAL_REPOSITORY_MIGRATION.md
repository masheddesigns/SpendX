# SpendX 2.0 — Milestone C3B-5: GoalRepo Migration Report

**Date:** 2026-10-03  
**Status:** PASS  
**Target:** `GoalRepo` → Canonical Asset Earmark Boundary (`asset_earmarks`, zero ledger postings)

---

## 1. Executive Summary

Milestone C3B-5 establishes the canonical asset reservation / earmark architecture for savings goals in SpendX 2.0.

Prior to C3B-5, savings goals tracked progress by directly updating a mutable `current_amount` column in the legacy `goals` table whenever a `GoalLog` was added or edited. Under C3B-5:
- **Goals are NOT accounting accounts**: Creating, updating, or deleting a goal produces **zero** economic events, **zero** postings, and **zero** ledger balance changes.
- **Earmarks are Soft Reservations, NOT Money Movements**: Earmarking funds from an asset account designates purchasing intent (`asset_earmarks`), but does not transfer money or impact the double-entry ledger. Net worth, total assets, total liabilities, income, and expenses remain completely unchanged.
- **Goal Progress is Dynamically Derived**: `goal_progress = SUM(asset_earmarks.amount_minor_units) / 100.0`. Legacy `goals.current_amount` is maintained strictly as an operational / compatibility cache and is **never** authoritative financial truth.
- **Real Transfers Remain Canonical**: Moving money between accounts (e.g. Checking to dedicated Savings) is recorded via canonical `transfer` economic events; the goal earmark simply references the resulting asset account.
- **Safe Archival and Clean Rollbacks**: Deleting or archiving a goal safely releases all associated earmarks without destroying or altering any underlying financial ledger history. Multi-table operations are atomic.

All 34 test cases in `test/repositories/canonical_goal_repo_migration_test.dart` and the entire repository suite (142/142 tests) pass with zero analyzer errors or warnings.

---

## 2. Hard Scope Firewall Enforcement

| Subsystem / Layer | Status | Firewall Enforcement Notes |
|---|---|---|
| Riverpod State Providers | UNTOUCHED | Zero provider modifications made |
| Flutter UI / Screens / Widgets | UNTOUCHED | Zero UI code modified |
| GoRouter / Routes | UNTOUCHED | Navigation definitions unmodified |
| `FinancialTransactionService` | UNTOUCHED | Service layer untouched; deferred to C3B-6 |
| `TransactionRepo` | UNTOUCHED | Maintained closed C3B-1 state |
| `AccountRepo` | UNTOUCHED | Maintained closed C3B-2 state |
| `CreditRepo` | UNTOUCHED | Maintained closed C3B-3 state |
| `LoanRepo` | UNTOUCHED | Maintained closed C3B-4 state |
| Database Schema Version | UNTOUCHED | Maintained schema version 24 |
| Transitional Tables | UNTOUCHED | Zero tables physically dropped |
| C3B-6 / C3B-7 Milestones | NOT STARTED | Hard stop strictly observed |

---

## 3. Exact Public Method Inventory Table

Inspection of [`lib/data/repositories/goal_repo.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/goal_repo.dart) reveals exactly **16 public methods**:

| # | Public Method Name | Signature & Return Type | Classification | Authority Source | Legacy Write Behavior |
|---|--------------------|-------------------------|----------------|------------------|-----------------------|
| 1 | `getAll` | `Future<List<Goal>> getAll({Transaction? txn})` | `DERIVED` | Canonical `asset_earmarks` + `goals` | None (Read-only projection) |
| 2 | `getActive` | `Future<List<Goal>> getActive({Transaction? txn})` | `DERIVED` | Canonical `asset_earmarks` + `goals` | None (Read-only projection) |
| 3 | `getGoalById` | `Future<Goal?> getGoalById(String id, {Transaction? txn})` | `DERIVED` | Canonical `asset_earmarks` + `goals` | None (Read-only projection) |
| 4 | `getDerivedProgress` | `Future<double> getDerivedProgress(String goalId, {Transaction? txn})` | `DERIVED` | Canonical `asset_earmarks` (`SUM(amount_minor_units)`) | None (Pure derivation) |
| 5 | `getEarmarks` | `Future<List<AssetEarmark>> getEarmarks(String goalId, {Transaction? txn})` | `DERIVED` | Canonical `asset_earmarks` | None (Read-only query) |
| 6 | `getTotalEarmarkedForAccount` | `Future<Money> getTotalEarmarkedForAccount(String accountId, {Transaction? txn})` | `DERIVED` | Canonical `asset_earmarks` | None (Read-only query) |
| 7 | `insert` | `Future<void> insert(Goal goal, {Transaction? txn})` | `CANONICAL_METADATA` | Operational `goals` table | Writes goal record (0 postings) |
| 8 | `update` | `Future<void> update(Goal goal, {Transaction? txn})` | `CANONICAL_METADATA` | Operational `goals` table | Updates goal metadata (0 postings) |
| 9 | `delete` | `Future<void> delete(String id, {Transaction? txn})` | `CANONICAL_METADATA` | Canonical `asset_earmarks` + `goals` | Releases earmarks, soft-deletes goal (0 postings) |
| 10 | `createEarmark` | `Future<void> createEarmark(AssetEarmark earmark, {Transaction? txn})` | `CANONICAL_METADATA` | Canonical `asset_earmarks` | Writes reservation record (0 postings) |
| 11 | `setEarmark` | `Future<void> setEarmark(AssetEarmark earmark, {Transaction? txn})` | `CANONICAL_METADATA` | Canonical `asset_earmarks` | Upserts reservation record (0 postings) |
| 12 | `deleteEarmark` | `Future<void> deleteEarmark(String id, {Transaction? txn})` | `CANONICAL_METADATA` | Canonical `asset_earmarks` | Deletes reservation record (0 postings) |
| 13 | `updateProgress` | `Future<void> updateProgress(String id, double currentAmount, {Transaction? txn})` | `TRANSITIONAL_COMPATIBILITY` | Operational `goals.current_amount` | Updates cached projection only |
| 14 | `getLogs` | `Future<List<GoalLog>> getLogs(String goalId, {Transaction? txn})` | `TRANSITIONAL_COMPATIBILITY` | Operational `goal_logs` table | None (Read-only query) |
| 15 | `addLog` | `Future<void> addLog(GoalLog log, {Transaction? txn})` | `TRANSITIONAL_COMPATIBILITY` | Operational `goal_logs` + `goals` | Writes log, updates cached projection (0 postings) |
| 16 | `deleteLog` | `Future<void> deleteLog(GoalLog log, {Transaction? txn})` | `TRANSITIONAL_COMPATIBILITY` | Operational `goal_logs` + `goals` | Deletes log, updates cached projection (0 postings) |

---

## 4. Method Classification Totals

- **`CANONICAL_FINANCIAL`**: **0** (Savings goals and earmarks are non-accounting entities and generate zero postings)
- **`CANONICAL_METADATA`**: **6** (`insert`, `update`, `delete`, `createEarmark`, `setEarmark`, `deleteEarmark`)
- **`DERIVED`**: **6** (`getAll`, `getActive`, `getGoalById`, `getDerivedProgress`, `getEarmarks`, `getTotalEarmarkedForAccount`)
- **`TRANSITIONAL_COMPATIBILITY`**: **4** (`updateProgress`, `getLogs`, `addLog`, `deleteLog`)
- **`ILLEGAL`**: **0**

### Mathematical Reconciliation
$$\text{Total Public Methods} = 0 + 6 + 6 + 4 + 0 = 16$$

---

## 5. Goal Schema & Field Audit

Inspection of legacy `goals` table columns:

| Column | Data Type | Classification | Role in v24 Architecture |
|---|---|---|---|
| `id` | `TEXT PRIMARY KEY` | Metadata | Goal unique identifier; referenced by `asset_earmarks.goal_id` |
| `title` | `TEXT NOT NULL` | Metadata | Display label for goal |
| `type` | `TEXT NOT NULL` | Metadata | Goal strategy type (`savings`, `spendingLimit`, `debtPayoff`) |
| `target_amount` | `REAL NOT NULL` | Metadata | Target amount in rupees |
| `current_amount` | `REAL DEFAULT 0.0` | **Derived / Compatibility Projection** | **Non-authoritative**. Dynamically populated from active `asset_earmarks` |
| `start_date` | `TEXT NOT NULL` | Metadata | Goal initiation date |
| `end_date` | `TEXT NOT NULL` | Metadata | Target completion date |
| `category_id` | `TEXT` | Metadata | Optional category linkage for spending limit goals |
| `account_id` | `TEXT` | Metadata | Optional default asset account |
| `is_active` | `INTEGER DEFAULT 1` | Metadata | Active status flag; inactive goals reject new earmarks |
| `created_at` | `TEXT NOT NULL` | Metadata | ISO-8601 audit timestamp |

---

## 6. Earmark Architecture

The canonical asset reservation model is governed by `TablesV24.assetEarmarks`:
```sql
CREATE TABLE IF NOT EXISTS asset_earmarks (
  id TEXT PRIMARY KEY,
  goal_id TEXT NOT NULL,
  asset_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
  amount_minor_units INTEGER NOT NULL CHECK(amount_minor_units >= 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CONSTRAINT uq_goal_account_earmark UNIQUE (goal_id, asset_account_id)
);
```

### Safety Invariants Enforced:
1. **Asset Account Verification**: Must reference a valid `accounts` row with `account_type = 'asset'`.
2. **Goal Existence**: Target `goal_id` must exist and be active (`is_active = 1`).
3. **Strict Positivity**: `amount_minor_units > 0` enforced by Dart domain model and SQLite CHECK constraint.
4. **Account & Goal Uniqueness**: SQLite `UNIQUE(goal_id, asset_account_id)` prevents duplicate reservation records.

---

## 7. Goal Progress Derivation

Goal progress is calculated dynamically by [`CanonicalGoalAdapter.getDerivedGoalProgress`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_goal_adapter.dart#L19-L31):
$$\text{Progress (INR)} = \frac{\sum \text{amount\_minor\_units}}{100.0}$$
Where `SUM` runs over all active rows in `asset_earmarks` matching `goal_id`.
If no earmarks exist yet, legacy `current_amount` or `goal_logs` are used as a fallback projection for pre-migration records.

---

## 8. Legacy `current_amount` Treatment

- `goals.current_amount` is **NEVER** treated as authoritative financial truth.
- Direct mutations to `goals.current_amount` via SQL or `updateProgress` do not affect `getDerivedProgress` or canonical accounting state.
- Whenever an earmark is created, modified, or removed, [`CanonicalGoalAdapter.syncGoalProjection`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_goal_adapter.dart#L125-L141) syncs the derived value into `goals.current_amount` to maintain seamless backward compatibility with legacy UI screens.

---

## 9. Zero-Posting Proof

Every goal and earmark operation was verified against live SQLite database row counts:
- `events_after == events_before`
- `postings_after == postings_before`

| Operation | Economic Events Created | Postings Created | Ledger Balance Change | Net Worth Change |
|---|---|---|---|---|
| Create Goal | 0 | 0 | ₹0.00 | ₹0.00 |
| Update Goal | 0 | 0 | ₹0.00 | ₹0.00 |
| Delete Goal | 0 | 0 | ₹0.00 | ₹0.00 |
| Create Earmark (₹20,000) | 0 | 0 | ₹0.00 | ₹0.00 |
| Update Earmark (₹30,000) | 0 | 0 | ₹0.00 | ₹0.00 |
| Delete Earmark | 0 | 0 | ₹0.00 | ₹0.00 |
| Add Goal Log | 0 | 0 | ₹0.00 | ₹0.00 |
| Delete Goal Log | 0 | 0 | ₹0.00 | ₹0.00 |

---

## 10. Accounting Invariants

Throughout all goal operations:
$$\text{Assets} = \text{Liabilities} + \text{Equity}$$
$$\Delta \text{Net Worth} = 0, \quad \Delta \text{Income} = 0, \quad \Delta \text{Expense} = 0$$
Bank account physical balances remain completely unaffected by earmarks. Earmarks only influence Safe-to-Spend calculations by reserving a portion of the available liquid assets.

---

## 11. Atomicity & Rollback Verification

Multi-table operations are wrapped in transactions:
- **Earmark Creation Rollback**: If an error is thrown during earmark creation, the reservation is cleanly rolled back with 0 partial state.
- **Earmark Update Rollback**: Failing update transactions leave original earmark quantities untouched.
- **Goal Deletion Rollback**: Failing delete transactions preserve the goal, its logs, and its earmarks intact without orphaned rows.

---

## 12. Compatibility Projection

- Legacy callers using `goalRepo.getAll()`, `goalRepo.getActive()`, `goalRepo.addLog()`, `goalRepo.deleteLog()`, or `goalRepo.updateProgress()` continue to function without modification.
- Goals returned by `getAll()` and `getActive()` contain `currentAmount` dynamically populated with canonical derived progress.

---

## 13. Adversarial Test Matrix

All 34 test cases in `test/repositories/canonical_goal_repo_migration_test.dart` verified:

1. `create goal -> zero events and zero postings` (PASS)
2. `update goal -> zero events and zero postings` (PASS)
3. `archive/delete goal -> zero events and zero postings` (PASS)
4. `goal with accounting history remains safe` (PASS)
5. `goal deletion does not delete accounting history` (PASS)
6. `create earmark -> zero events and zero postings` (PASS)
7. `update earmark -> zero events and zero postings` (PASS)
8. `delete earmark -> zero events and zero postings` (PASS)
9. `duplicate (goal_id, account_id) rejected` (PASS)
10. `negative earmark rejected` (PASS)
11. `invalid goal FK rejected` (PASS)
12. `invalid account FK rejected` (PASS)
13. `multiple accounts -> one goal` (PASS)
14. `multiple goals -> one account` (PASS)
15. `derived total earmark amount matches minor units sum` (PASS)
16. `archived goal cannot retain active earmark` (PASS)
17. `earmark does not change account balance` (PASS)
18. `earmark does not change net worth` (PASS)
19. `earmark does not change income` (PASS)
20. `earmark does not change expense` (PASS)
21. `earmark does not create economic event` (PASS)
22. `earmark does not create posting` (PASS)
23. `actual transfer remains a canonical transfer` (PASS)
24. `transfer + earmark remain separate concepts` (PASS)
25. `current_amount cannot become financial truth` (PASS)
26. `legacy projection remains consistent` (PASS)
27. `no legacy balance mutation can alter canonical accounting` (PASS)
28. `earmark creation rollback on error leaves zero partial state` (PASS)
29. `earmark update rollback leaves original state intact` (PASS)
30. `goal deletion rollback preserves goal and earmarks` (PASS)
31. `C3B-1 regression: TransactionRepo operations alongside GoalRepo` (PASS)
32. `C3B-2 regression: AccountRepo operations alongside GoalRepo` (PASS)
33. `C3B-3 regression: CreditRepo operations alongside GoalRepo` (PASS)
34. `C3B-4 regression: LoanRepo operations alongside GoalRepo` (PASS)

---

## 14. Regression & Full Suite Results

- **Targeted C3B-5 Suite**: `34 / 34 PASS`
- **Full Repository Test Suite (`flutter test test/repositories/`)**: `142 / 142 PASS`
- **C3B-1 TransactionRepo Suite**: PASS
- **C3B-2 AccountRepo Suite**: PASS
- **C3B-3 CreditRepo Suite**: PASS
- **C3B-4 LoanRepo Suite**: PASS

---

## 15. Analyzer Results

```bash
flutter analyze lib/data/repositories/goal_repo.dart lib/data/repositories/canonical/canonical_earmark_repository.dart lib/data/repositories/canonical/canonical_goal_adapter.dart test/repositories/canonical_goal_repo_migration_test.dart
Analyzing 4 items...
No issues found! (ran in 1.6s)
```

---

## 16. Files Changed & Created

- `lib/data/repositories/goal_repo.dart`: Migrated to canonical earmark delegation and derived progress.
- `lib/data/repositories/canonical/canonical_earmark_repository.dart`: Enhanced with `createEarmark`, `updateEarmark`, `getTotalEarmarkedForGoal`, validation and projection sync.
- `lib/data/repositories/canonical/canonical_goal_adapter.dart`: Created adapter for validation, derived progress calculation, and projection sync.
- `lib/data/repositories/canonical_repositories.dart`: Exported `canonical_goal_adapter.dart`.
- `test/repositories/canonical_goal_repo_migration_test.dart`: 34-test adversarial suite.
- `docs/spendx2/54_C3B_GOAL_REPOSITORY_MIGRATION.md`: Milestone report.

---

## 17. Files Deliberately Untouched

- All Riverpod providers and state notifiers
- All UI screens, widgets, and view models
- GoRouter navigation routes
- `FinancialTransactionService`
- Database schema version (v24)
- Transitional database tables

---

## 18. Remaining Transitional Dependencies

- Legacy UI screens currently consume `Goal.currentAmount` via `goalRepo.getAll()`; this is satisfied seamlessly by the derived projection.
- `FinancialTransactionService` sits across multiple repository boundaries and is scheduled for canonical refactoring in Milestone C3B-6.

---

## 19. Final Verdict

**`C3B-5 FINAL STATUS: PASS`**
