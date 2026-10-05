# SpendX 2.0 — Milestone C4-4 Execution Report
## Loans & Goals Application Read Migration

**Milestone:** C4-4  
**Date:** October 4, 2026  
**Status:** CLOSED / PASS  
**Scope:** Loans & Goals Application Read Architecture & Riverpod Migration  
**Preceding Milestones:** C3A through C3B-7, C4-0, C4-1, C4-2, C4-3 (CLOSED / PASS)  
**Next Milestone:** C4-5 (Analytics & Budget Read Migration — PENDING AUTHORIZATION)  

---

## 1. Executive Summary

Milestone **C4-4** migrates and verifies all application runtime read paths for **Loans** and **Goals** within SpendX 2.0. Prior to this milestone, canonical double-entry accounting governed loan disbursements, repayments, interest accruals, and asset earmarks at the repository layer (established in C3B-4 and C3B-5), but application providers, services, and consumers possessed legacy touchpoints that could potentially read or rely on transitional columns (`loans.paid_amount`, `goals.current_amount`) or transitional projection tables (`loan_installments`, `goal_logs`).

Under C4-4:
1. **Loans Read Authority**: Outstanding loan liabilities are derived strictly from canonical double-entry postings ($\sum \text{Credits} - \sum \text{Debits}$ on liability accounts). `LoanRepo.getDerivedBalance()`, `LoanRepo.getLoanById()`, `LoanRepo.getLoans()`, `LoanService.getRemainingBalance()`, `loansProvider`, and `liabilitiesSummaryProvider` are unified onto this single canonical stream.
2. **Goals Read Authority**: Goal progress is derived strictly from active reservations in `asset_earmarks`. `CanonicalGoalAdapter.projectGoal` has been hardened to eliminate any fallback to `goals.current_amount`. If a goal has zero earmarks, its derived progress is strictly ₹0.00.
3. **Zero Financial Authority**: Legacy mutable columns `loans.paid_amount` and `goals.current_amount` have **0% financial authority**. Rogue direct SQL mutations to these columns produce **zero effect** on displayed loan balances, goal progress, Safe-to-Spend, or Net Worth.
4. **Zero Accounting Postings for Earmarks**: Earmark creations, updates, and releases produce **0 economic events and 0 ledger postings**, strictly fulfilling the architectural invariant that internal asset reservations do not alter external financial truth or net worth.
5. **Transitional Isolation**: Rogue insertions or mutations in transitional tables (`loan_installments`, `goal_logs`) have **zero effect** on canonical liabilities and goal progress.
6. **Service & Provider Consolidation**: Dual provider definitions across `lib/features/liabilities/providers/liabilities_providers.dart`, `lib/features/goals/goal_providers.dart`, and `lib/core/services/service_providers.dart` have been reconciled so that `loansProvider`, `goalRepoProvider`, and `loanServiceProvider` share identical canonical instances and cache coherence.

---

## 2. Classification of All Loans and Goals Read Paths

Every read path touching Loans, Goals, Earmarks, and Installments across the application was inventoried and classified into one of four formal categories:

| Category | Description | Count |
| :--- | :--- | :---: |
| `CANONICAL_DERIVED_DIRECT` | Queries deriving balance directly from `postings` or `asset_earmarks` | 14 |
| `CANONICAL_DERIVED_PROJECTED` | UI models projected from canonical accounts with derived balances | 6 |
| `COMPATIBILITY_READ_ONLY` | Transitional read queries preserving non-financial UI metadata (due dates, notes) | 3 |
| `ILLEGAL_STALE_AUTHORITY` | Legacy read paths using mutable balance columns as financial authority | **0** |

### Complete Read Inventory

| Component / Function | File Path | Classification | Authority Source |
| :--- | :--- | :--- | :--- |
| `LoanRepo.getDerivedBalance` | `lib/data/repositories/loan_repo.dart` | `CANONICAL_DERIVED_DIRECT` | `postings` via `CanonicalAccountRepository` |
| `LoanRepo.getLoans` | `lib/data/repositories/loan_repo.dart` | `CANONICAL_DERIVED_PROJECTED` | `accounts` + canonical derived balance |
| `LoanRepo.getLoanById` | `lib/data/repositories/loan_repo.dart` | `CANONICAL_DERIVED_PROJECTED` | `accounts` + canonical derived balance |
| `LoanRepo.getInstallments` | `lib/data/repositories/loan_repo.dart` | `COMPATIBILITY_READ_ONLY` | `loan_installments` (schedule metadata) |
| `LoanService.getRemainingBalance` | `lib/domain/loans/loan_service.dart` | `CANONICAL_DERIVED_DIRECT` | `_loanRepo.getDerivedBalance` |
| `LoanService.getLoanSummary` | `lib/domain/loans/loan_service.dart` | `CANONICAL_DERIVED_PROJECTED` | Canonical loan projections |
| `loansProvider` | `lib/data/providers.dart` | `CANONICAL_DERIVED_PROJECTED` | `app_data.loanRepoProvider.getLoans()` |
| `loansProvider` (liabilities) | `lib/features/liabilities/providers/liabilities_providers.dart` | `CANONICAL_DERIVED_PROJECTED` | Synchronized: watches `app_data.loansProvider` |
| `liabilitiesSummaryProvider` | `lib/features/liabilities/providers/liabilities_providers.dart` | `CANONICAL_DERIVED_DIRECT` | Aggregates canonical loan & card services |
| `loanServiceProvider` | `lib/core/services/service_providers.dart` | `CANONICAL_DERIVED_DIRECT` | Injects `ref.watch(loanRepoProvider)` |
| `GoalRepo.getDerivedProgress` | `lib/data/repositories/goal_repo.dart` | `CANONICAL_DERIVED_DIRECT` | `asset_earmarks` |
| `GoalRepo.getGoalById` | `lib/data/repositories/goal_repo.dart` | `CANONICAL_DERIVED_PROJECTED` | `goals` + derived progress from earmarks |
| `GoalRepo.getGoals` | `lib/data/repositories/goal_repo.dart` | `CANONICAL_DERIVED_PROJECTED` | `goals` + derived progress from earmarks |
| `GoalRepo.getEarmarks` | `lib/data/repositories/goal_repo.dart` | `CANONICAL_DERIVED_DIRECT` | `asset_earmarks` |
| `GoalRepo.getEarmarksForGoal` | `lib/data/repositories/goal_repo.dart` | `CANONICAL_DERIVED_DIRECT` | Alias to `getEarmarks` |
| `GoalRepo.getTotalEarmarkedForAccount` | `lib/data/repositories/goal_repo.dart` | `CANONICAL_DERIVED_DIRECT` | `asset_earmarks` grouped by account |
| `goalsProvider` | `lib/features/goals/goal_providers.dart` | `CANONICAL_DERIVED_PROJECTED` | `goalRepoProvider.getGoals()` |
| `goalByIdProvider` | `lib/features/goals/goal_providers.dart` | `CANONICAL_DERIVED_PROJECTED` | `goalRepoProvider.getGoalById(id)` |
| `goalEarmarksProvider` | `lib/features/goals/goal_providers.dart` | `CANONICAL_DERIVED_DIRECT` | `goalRepoProvider.getEarmarksForGoal(goalId)` |
| `accountEarmarkedTotalProvider` | `lib/features/goals/goal_providers.dart` | `CANONICAL_DERIVED_DIRECT` | `goalRepoProvider.getTotalEarmarkedForAccount` |
| `goalDerivedProgressProvider` | `lib/features/goals/goal_providers.dart` | `CANONICAL_DERIVED_DIRECT` | `goalRepoProvider.getDerivedProgress(goalId)` |
| `SafeToSpendCalculator` | `lib/domain/finance/safe_to_spend.dart` | `CANONICAL_DERIVED_DIRECT` | `Liquid Assets - Active Earmarks - Commitments` |
| `CanonicalFinancialQueryRepository.getSafeToSpend` | `lib/data/repositories/canonical/canonical_financial_query_repository.dart` | `CANONICAL_DERIVED_DIRECT` | Queries active `asset_earmarks` directly |

**Total Illegal Paths:** **0**

---

## 3. Loans Application Read Architecture

The canonical data pipeline for all loan reads is:

```
SQLite Canonical Truth (accounts + postings)
             ↓
CanonicalAccountRepository.getDerivedBalance(loanId)
             ↓
CanonicalLoanAdapter.toLoan(row, derivedBalance)
             ↓
LoanRepo.getDerivedBalance() / LoanRepo.getLoans() / LoanRepo.getLoanById()
             ↓
LoanService.getRemainingBalance()
             ↓
app_data.loansProvider (synchronized with liabilities_providers.loansProvider)
             ↓
Liabilities Hub UI / Loan Detail Screens
```

### Loan Accounting Invariants:
1. **Outstanding Balance**: A loan liability is a Credit-normal account. Its balance is $\text{Credits} - \text{Debits}$.
2. **Disbursement**: $\text{Dr Bank Asset}, \text{Cr Loan Liability}$. Increases loan outstanding balance and bank asset by identical amounts. Net worth delta = 0.
3. **Principal Repayment**: $\text{Dr Loan Liability}, \text{Cr Bank Asset}$. Reduces loan outstanding balance and bank asset. Produces **zero expense postings**.
4. **Interest Payment**: $\text{Dr sys_exp_interest}, \text{Cr Bank Asset}$. Produces **expense postings**, but **zero reduction to loan principal liability**.
5. **Combined EMI**: 3-leg balanced posting:
   - $\text{Dr Loan Liability}$ (Principal component)
   - $\text{Dr sys_exp_interest}$ (Interest component)
   - $\text{Cr Bank Asset}$ (Total EMI amount)
   Principal reduces loan liability; interest creates expense; cash outflow equals the sum.
6. **Paid Amount Projection**: In the UI model `Loan`, `paidAmount` is strictly derived as:
   $$\text{paidAmount} = \max(0, \text{total} - \text{remainingLiability})$$

---

## 4. Goals Application Read Architecture

The canonical data pipeline for all goal reads is:

```
SQLite Canonical Truth (asset_earmarks)
             ↓
CanonicalGoalAdapter.getDerivedGoalProgress(db, goalId)
             ↓
GoalRepo.getDerivedProgress() / GoalRepo.getGoals() / GoalRepo.getGoalById()
             ↓
goalsProvider / goalByIdProvider / goalDerivedProgressProvider
             ↓
Goals Hub UI / Goal Detail Cards
```

### Goal Accounting Invariants:
1. **Non-Posting Concept**: Goals and earmarks represent **internal reservations of asset funds**, NOT financial transfers or economic exchanges with external entities.
2. **Zero Postings**: Creating, editing, or deleting an `AssetEarmark` creates **0 economic events and 0 ledger postings**.
3. **Strict Derived Progress**: `CanonicalGoalAdapter.projectGoal` derives `currentAmount` solely by summing active earmarks for the goal. If no earmarks exist, progress is 0.00.
4. **Multi-Account Aggregation**: A single goal may be funded by earmarks distributed across multiple bank accounts. The total goal progress is $\sum \text{earmarks}_{\text{goal}}$.
5. **Account Available Balance**: An account's unreserved balance for discretionary spending is derived as:
   $$\text{Available} = \text{Derived Balance} - \sum \text{Active Earmarks}_{\text{account}}$$

---

## 5. Proof of Zero Financial Authority for Legacy Columns

### 5.1 `loans.paid_amount`
- Invariant 1 proves that performing a direct raw SQL update:
  ```sql
  UPDATE loans SET paid_amount = 450000.0 WHERE id = 'loan_inv_1'
  ```
  leaves `LoanRepo.getDerivedBalance()`, `LoanRepo.getLoanById()`, `LoanService.getRemainingBalance()`, `loansProvider`, and `liabilitiesSummaryProvider` completely unaffected. The canonical balance remains strictly derived from the ledger postings.
- Invariant 10 proves that Net Worth calculations (`NetWorthService.calculate()`) are 100% immune to mutations of `loans.paid_amount`.

### 5.2 `goals.current_amount`
- Invariant 11 proves that performing a direct raw SQL update:
  ```sql
  UPDATE goals SET current_amount = 999999.0 WHERE id = 'goal_inv_11'
  ```
  leaves `GoalRepo.getDerivedProgress()`, `GoalRepo.getGoalById()`, `goalsProvider`, `goalByIdProvider`, and `goalDerivedProgressProvider` completely unaffected. Goal progress remains strictly derived from `asset_earmarks`.
- Invariant 17 proves that Safe-to-Spend calculations are completely immune to mutations of `goals.current_amount`.

---

## 6. Treatment of Transitional Tables

### 6.1 `loan_installments`
- The `loan_installments` table remains strictly for operational amortization schedule projection (due dates, notification scheduling, installment metadata).
- Invariant 7 proves that rogue raw SQL insertions into `loan_installments` (e.g., inserting a fake paid installment) produce **zero change** in canonical loan liability.

### 6.2 `goal_logs`
- The `goal_logs` table remains as an operational historical audit/memo table from legacy versions.
- Invariant 18 proves that rogue raw SQL insertions into `goal_logs` produce **zero effect** on goal progress or account earmarks.

---

## 7. Safe-to-Spend Interaction with Goals & Earmarks

Safe-to-Spend is computed using the canonical formula:
$$\text{Safe-to-Spend} = \max(0, \text{Liquid Assets} - \text{Active Earmarks} - \text{Upcoming Commitments})$$

- Invariant 17 verifies that creating an earmark of ₹35,000 against a bank account with ₹100,000 instantly reduces Safe-to-Spend from ₹100,000 to ₹65,000.
- Corrupting `goals.current_amount` via raw SQL does not alter Safe-to-Spend.
- Safe-to-Spend queries `asset_earmarks` directly through `CanonicalFinancialQueryRepository.getSafeToSpend()`.

---

## 8. Net Worth Interaction with Loans & Goals

$$\text{Net Worth} = \sum \text{Assets} - \sum \text{Liabilities}$$

1. **Loans**:
   - Loan disbursement creates an asset (cash in bank) and an equal liability (debt). Invariant 2 confirms net worth delta = 0.
   - Loan principal repayment reduces an asset (cash in bank) and an equal liability (debt). Net worth delta = 0.
   - Interest payment reduces an asset (cash in bank) and incurs an expense. Reduces net worth by the interest amount.
   - Invariant 10 proves Net Worth derives loan debt solely from double-entry postings on liability accounts, with 0 reliance on legacy loan table columns.
2. **Goals**:
   - Invariant 16 proves that creating, updating, or deleting goal earmarks produces **zero change** in Net Worth. Net Worth before earmark = ₹500,000; after earmark = ₹500,000.

---

## 9. Provider Unification & Single-Source Audit

The following provider reconciliations were performed:
1. `lib/features/liabilities/providers/liabilities_providers.dart`:
   - `loansProvider` previously executed independent queries on legacy repositories. It now synchronizes directly with `ref.watch(app_data.loansProvider.future)`, eliminating split-brain cache states.
2. `lib/features/goals/goal_providers.dart`:
   - `goalRepoProvider` now references `app_data.goalRepoProvider`.
   - Added canonical providers: `goalByIdProvider`, `goalEarmarksProvider`, `accountEarmarkedTotalProvider`, and `goalDerivedProgressProvider`.
3. `lib/core/services/service_providers.dart`:
   - `loanServiceProvider` was updated from an unparameterized constructor to inject `ref.watch(loanRepoProvider)`.
   - `creditCardServiceProvider` was updated to inject `ref.watch(creditRepoProvider)`.
4. `lib/data/repositories/canonical/canonical_goal_adapter.dart`:
   - `projectGoal()` removed the fallback `if (earmarks.isEmpty) currentAmount = row['current_amount']`. It now strictly evaluates `getDerivedGoalProgress(db, goalId)`.

---

## 10. Test Strategy & Adversarial Coverage

All 18 required adversarial invariants were implemented in `test/features/loans_goals_canonical_read_test.dart` and executed against an in-memory SQLite database initialized with the full v24 canonical schema and active triggers:

| Invariant # | Test Name | Result |
| :---: | :--- | :---: |
| **1** | Rogue mutation of `loans.paid_amount` has ZERO effect on canonical outstanding | **PASS** |
| **2** | Canonical loan disbursement increases liability with net worth unchanged | **PASS** |
| **3** | Principal repayment decreases loan liability and bank balance | **PASS** |
| **4** | Principal repayment creates zero expense postings | **PASS** |
| **5** | Interest payment creates expense without reducing principal liability | **PASS** |
| **6** | Combined EMI splits principal reduction and interest expense correctly | **PASS** |
| **7** | Rogue direct SQL mutations to `loan_installments` cannot alter canonical liability | **PASS** |
| **8** | Loan deletion soft-archives if postings exist, preserving immutable ledger | **PASS** |
| **9** | All loan providers and services agree on canonical outstanding liability | **PASS** |
| **10** | Net worth reflects canonical loan liability and is immune to legacy columns | **PASS** |
| **11** | Rogue `goals.current_amount` mutation has ZERO effect on goal progress | **PASS** |
| **12** | Earmark creation produces ZERO postings and ZERO economic events | **PASS** |
| **13** | Earmark deletion releases reservation with zero postings | **PASS** |
| **14** | Multiple earmarks across multiple accounts aggregate accurately | **PASS** |
| **15** | Deleting a goal automatically releases all its active earmarks | **PASS** |
| **16** | Goal earmarks have ZERO impact on Net Worth | **PASS** |
| **17** | Safe-to-Spend is reduced by active earmarks, immune to legacy `current_amount` | **PASS** |
| **18** | Legacy `goal_logs` entries cannot override canonical earmark progress | **PASS** |

**Adversarial Suite Result:** **18 / 18 PASS** (100%)

---

## 11. Full Regression Suite Results

| Test Suite | Path | Tests Passed | Status |
| :--- | :--- | :---: | :---: |
| **C4-4 Adversarial** | `test/features/loans_goals_canonical_read_test.dart` | **18 / 18** | **PASS** |
| **All Features (C4-1 to C4-4)** | `test/features/` | **54 / 54** | **PASS** |
| **Canonical Repositories** | `test/repositories/` | **206 / 206** | **PASS** |
| **Domain & Financial Invariants** | `test/domain/` | **50 / 50** | **PASS** |
| **Financial Services Regression** | `test/financial_transaction_service_test.dart`, etc. | **27 / 27** | **PASS** |
| **Complete Project Test Suite** | `flutter test` | **480 / 480** | **PASS** |
| **Static Analyzer** | `flutter analyze` (changed scope) | **0 errors, 0 warnings** | **PASS** |

---

## 12. Schema & Storage Invariant Verification

1. **Database Schema Version**: Remains locked at **v24**. No schema version bump or migration was performed.
2. **Active Triggers**: All 7/7 SQLite integrity and immutability triggers remain active and enforced:
   - `trg_economic_events_validate_posted`
   - `trg_economic_events_immutable_posted`
   - `trg_postings_immutable_insert`
   - `trg_postings_immutable_update`
   - `trg_postings_immutable_delete`
   - `trg_accounts_system_protect`
   - `trg_evidence_immutable`
3. **No Physical Deletions**: Legacy tables `loans`, `loan_installments`, `goals`, and `goal_logs` remain physically present in the SQLite schema as non-authoritative operational projection and metadata tables.

---

## 13. Out-of-Scope Confirmations

- **C4-5 (Analytics & Budget Read Migration)**: NOT started. Untouched.
- **C4-6 (AI Integration & Review Queue Read Migration)**: NOT started. Untouched.
- **UI Redesign**: Zero UI layouts, styling, or widgets were altered.
- **GoRouter Navigation**: Routing definitions remain 100% untouched.
- **Accounting Write Paths**: C3B canonical write boundaries, triggers, and repositories remain unaltered.

---

## 14. Architectural Status Matrix

| Milestone | Scope | Status | Evidence / Verification |
| :--- | :--- | :---: | :--- |
| **C3A** | Canonical Repository Boundary | **CLOSED** | 46 repository boundary tests |
| **C3A.1** | Semantic Closure Audit | **CLOSED** | Full semantic verification |
| **C3B-1** | TransactionRepo Migration | **CLOSED** | 30 adversarial tests |
| **C3B-2** | AccountRepo Migration | **CLOSED** | 34 adversarial tests |
| **C3B-3** | CreditRepo Migration | **CLOSED** | 36 adversarial tests |
| **C3B-4** | LoanRepo Migration | **CLOSED** | 30 adversarial tests |
| **C3B-5** | GoalRepo Migration | **CLOSED** | 34 adversarial tests |
| **C3B-6** | FinancialTransactionService | **CLOSED** | 18 adversarial tests |
| **C3B-7** | Final Repository Write Firewall | **CLOSED** | 28 firewall tests |
| **C4-0** | Application Read Inventory | **CLOSED** | 100% read boundary mapping |
| **C4-1** | Accounts & Transactions Read Migration | **CLOSED** | 12 adversarial tests |
| **C4-2** | Dashboard & Net Worth Read Migration | **CLOSED** | 12 adversarial tests |
| **C4-3** | Credit Card Read Migration | **CLOSED** | 12 adversarial tests |
| **C4-4** | Loans & Goals Read Migration | **CLOSED / PASS** | **18 adversarial tests (480/480 full suite)** |
| **C4-5** | Analytics & Budget Read Migration | *NEXT* | Authorization required |

---

## 15. Verification Verdict

**Milestone C4-4 is completely satisfied, verified, and CLOSED with a PASS verdict.**

Runtime application reads for Loans and Goals derive financial truth exclusively from the canonical accounting layer. Legacy mutable columns `loans.paid_amount` and `goals.current_amount` have zero financial authority. All 480 tests in the project suite pass. Static analysis reports 0 errors and 0 warnings.
