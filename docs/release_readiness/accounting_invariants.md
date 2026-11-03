# SpendX Release Readiness — Pillar 1: Accounting Invariants & Ledger Reconciliation Specification

**Document Version:** 1.0.0  
**Target Release:** SpendX 2.1.0  
**Milestone Checkpoint:** `visual-redesign-milestone` (`6f118a1`)  
**Status:** Discovery Complete & Baseline Specification Established  
**Scope Boundary:** Phase 1 Investigation & Invariant Formalization (UI & Production Accounting Frozen)

---

## Executive Summary

SpendX has completed an architectural evolution from a legacy single-entry personal finance tracker to a double-entry accounting engine implemented in SQLite schema **v24**.

Under this architecture:
1. **Zero Storage of Truth in Mutable Balance Columns:** Legacy columns (`bank_accounts.balance`, `credit_cards.used_amount`, `loans.paid_amount`, and `goals.current_amount`) are deprecated projections. Authoritative financial state is derived by joining immutable `postings` with `economic_events` where `lifecycle_status = 'posted'`.
2. **Double-Entry Enforcement at the SQLite Engine Level:** Seven native SQLite triggers enforce draft-before-post sequencing, mathematical balance ($\sum \text{Debits} = \sum \text{Credits}$ in integer minor units), and immutability of committed postings.
3. **No Direct In-Place Mutation of Posted Records:** Edits and deletions generate append-only balanced reversal and replacement events.
4. **Monetary Integer Representation:** All underlying calculations operate on 64-bit integer paise (minor units) to eliminate IEEE-754 floating-point drift.

This document establishes the verified accounting contract, traces readers and writers, catalogs existing test coverage, documents identified reconciliation risks and subtle defects, and outlines the regression test matrix required before certifying SpendX for production release.

---

## 1. Accounting Architecture Map

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 PRESENTATION LAYER                                     │
│     Home Dashboard   │   Activity List   │   Accounts / Cards   │   Reports Screen     │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 APPLICATION REPOSITORIES                               │
│   AccountRepo      │   CreditRepo       │   LoanRepo         │   TransactionRepo       │
│  (Projects Models) │  (Projects Cards)  │  (Projects Loans)  │  (Projects Txns)        │
└────────────┬──────────────────┬───────────────────┬───────────────────┬────────────────┘
             │                  │                   │                   │
             ▼                  ▼                   ▼                   ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                            CANONICAL REPOSITORY LAYER (v24)                            │
│  - CanonicalFinancialQueryRepository (Net Worth, Cash Flow, Liquid Cash, Safe-to-Spend)│
│  - CanonicalAccountRepository (Derived Balances: Dr-Cr for Assets, Cr-Dr for Liab)     │
│  - CanonicalEventRepository (Atomic Draft -> Post lifecycle management)                │
│  - CanonicalOpeningBalanceRepository (Reconciliation audit trails)                     │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                             SQLITE STORAGE & TRIGGER SUITE                             │
│  - TablesV24.accounts             (Asset, Liability, Equity, Income, Expense)          │
│  - TablesV24.economic_events      (Draft -> Posted lifecycle, immutable on post)       │
│  - TablesV24.postings             (Debit / Credit integer paise legs)                  │
│  - TablesV24.evidence             (Forensic SHA-256 deduplication & retention)         │
│  - TablesV24.asset_earmarks       (Reserved cash allocations for goals)                │
│                                                                                        │
│  NATIVE ENGINE TRIGGERS:                                                               │
│   1. trg_economic_events_prevent_direct_posted_insert                                  │
│   2. trg_economic_events_validate_posted (Postings >= 2 && Sum(Dr) == Sum(Cr))        │
│   3. trg_postings_prevent_insert_on_posted                                             │
│   4. trg_postings_prevent_update_on_posted                                             │
│   5. trg_postings_prevent_delete_on_posted                                             │
│   6. trg_economic_events_prevent_mutation_on_posted                                    │
│   7. trg_economic_events_prevent_delete_posted                                         │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### Source Code Mapping

| Layer / Component | Source File Path | Primary Responsibilities |
| :--- | :--- | :--- |
| **Database Lifecycle & Migrations** | [`lib/data/core/app_database.dart`](file:///Users/sivek/Documents/SpendX/lib/data/core/app_database.dart) | Schema v24 configuration, WAL checkpoints, key derivation, upgrade chain (v3–v24). |
| **Canonical DDL & Triggers** | [`lib/data/core/tables_v24.dart`](file:///Users/sivek/Documents/SpendX/lib/data/core/tables_v24.dart) | Table definitions, foreign keys, and 7 native immutability/balance triggers. |
| **Aggregate Financial Queries** | [`lib/data/repositories/canonical/canonical_financial_query_repository.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_financial_query_repository.dart) | Net Worth, Cash Flow, Liquid Assets, Safe-to-Spend, Category Totals, Daily Velocity. |
| **Account Derivation** | [`lib/data/repositories/canonical/canonical_account_repository.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_account_repository.dart) | Dynamic account balance derivation (`SUM(postings)`), account lifecycle. |
| **Event & Posting Engine** | [`lib/data/repositories/canonical/canonical_event_repository.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_event_repository.dart) | Draft staging, posting attachment, atomic transaction commit, trigger validation. |
| **Domain Models & Money** | [`lib/domain/finance/finance.dart`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/finance.dart) | `Money` value object (integer minor units / paise), `AccountType`, `PostingDirection`. |
| **Transaction Translation** | [`lib/data/repositories/canonical/canonical_transaction_adapter.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_transaction_adapter.dart) | Maps legacy `Transaction` $\leftrightarrow$ `EconomicEvent` + `Posting` legs + `Evidence`. |
| **Credit Card Projection** | [`lib/data/repositories/canonical/canonical_credit_adapter.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_credit_adapter.dart) | Projects `accounts` + derived liability balance $\leftrightarrow$ `CreditCard` domain model. |
| **Loan Projection** | [`lib/data/repositories/canonical/canonical_loan_adapter.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_loan_adapter.dart) | Projects `accounts` + derived liability balance $\leftrightarrow$ `Loan` domain model. |
| **Account Projection** | [`lib/data/repositories/canonical/canonical_account_adapter.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_account_adapter.dart) | Projects `accounts` + derived asset balance $\leftrightarrow$ `BankAccount` domain model. |
| **Orchestration Service** | [`lib/services/financial_transaction_service.dart`](file:///Users/sivek/Documents/SpendX/lib/services/financial_transaction_service.dart) | Orchestrates cross-domain transaction entry, reminders auto-settlement. |

---

## 2. Transaction-Type Accounting Matrix

Every financial transaction in SpendX produces a strictly balanced 2-leg or 3-leg double-entry posting set. The table below documents the verified accounting contract for all transaction types:

| Event Type / Operation | Debit Leg (Dr) | Credit Leg (Cr) | Cash Flow Impact | Net Worth Impact | Reporting / Income Statement Impact |
| :--- | :--- | :--- | :---: | :---: | :--- |
| **Bank Expense** | Expense Account (`catId` or `sys_exp_misc`) | Bank Asset Account (`accountId`) | $-X$ | $-X$ | Incurs expense $+X$. Net income decreases by $X$. |
| **Bank Income / Salary** | Bank Asset Account (`accountId`) | Income Account (`catId` or `sys_inc_misc`) | $+X$ | $+X$ | Incurs income $+X$. Net income increases by $X$. |
| **Inter-Account Transfer** | Destination Asset Account (`relatedEntityId`) | Source Asset Account (`accountId`) | $0$ | $0$ | Internal transfer. Zero revenue, zero expense, zero net cash flow change. |
| **Credit Card Purchase** | Expense Account (`catId` or `sys_exp_misc`) | Card Liability Account (`cardId`) | $0$ | $-X$ | Incurs expense $+X$. Liabilities increase by $X$. Cash flow is unaffected. |
| **Credit Card Payment** | Card Liability Account (`relatedEntityId` / `cardId`) | Bank Asset Account (`accountId` / `bankId`) | $-X$ | $0$ | **Not an expense.** Liquid cash decreases, card liability decreases equally. |
| **Bank Refund** | Bank Asset Account (`accountId`) | Expense Account (`catId` or `sys_exp_refunds`) | $+X$ | $+X$ | Contra-expense (credits expense by $-X$). **Does not register as income.** |
| **Credit Card Refund** | Card Liability Account (`cardId`) | Expense Account (`catId` or `sys_exp_refunds`) | $0$ | $+X$ | Contra-expense. Reduces card liability, reduces recognized expenses. |
| **Loan Disbursement** | Bank Asset Account (`assetAccountId`) | Loan Liability Account (`loanId`) | $+X$ | $0$ | Liquid cash increases by $+X$, debt owed increases by $+X$. Zero income. |
| **Loan Principal Repayment** | Loan Liability Account (`loanId`) | Bank Asset Account (`assetAccountId`) | $-X$ | $0$ | Debt principal decreases by $-X$, cash decreases by $-X$. Zero expense. |
| **Loan Interest Payment** | Interest Expense (`sys_exp_interest`) | Bank Asset Account (`assetAccountId`) | $-I$ | $-I$ | Incurs interest expense $+I$. Net income decreases by $I$. |
| **Combined Loan EMI** | Dr Loan Liability ($P$)<br>Dr Interest Expense ($I$) | Cr Bank Asset Account ($P + I$) | $-(P+I)$ | $-I$ | Liquid cash reduced by full EMI ($P+I$). Debt reduced by $P$. Expense recognized only for $I$. |
| **Peer Lending Disbursement** | *Isolated in `lendings` table* | *Isolated in `lendings` table* | $0$* | $0$* | Operational record. Does not generate postings to bank accounts unless mirrored by bank expense. |
| **Opening Balance (Asset > 0)** | Bank Asset Account (`accountId`) | Equity Opening (`sys_equity_opening`) | $0$** | $+X$ | Establishes starting asset baseline balanced against Owner's Opening Equity. |
| **Opening Balance (Card Liab)** | Equity Opening (`sys_equity_opening`) | Card Liability Account (`cardId`) | $0$ | $-X$ | Establishes starting card debt balanced against Owner's Opening Equity. |
| **Transaction Deletion / Reversal** | Inverts original Credits $\rightarrow$ Debits | Inverts original Debits $\rightarrow$ Credits | Inverted | Inverted | Neutralizes original transaction to exactly ₹0.00 across all affected accounts. |

*\* See Section 5.2 for Peer Lending architectural isolation analysis.*  
*\*\* Opening balances are filtered out from period Cash Flow (`e.event_type != 'opening_balance'`).*

---

## 3. Balance Derivation Rules & Formulas

### 3.1 Normal Balances & Account Sign Conventions
Under canonical accounting, account balances are signed scalar projections derived from integer paise postings:

$$\text{Asset Balance} = \sum_{p \in \text{Postings}} (\text{if } p.\text{direction} = \text{debit} \text{ then } p.\text{amount} \text{ else } -p.\text{amount})$$

$$\text{Liability Balance} = \sum_{p \in \text{Postings}} (\text{if } p.\text{direction} = \text{credit} \text{ then } p.\text{amount} \text{ else } -p.\text{amount})$$

$$\text{Equity Balance} = \sum_{p \in \text{Postings}} (\text{if } p.\text{direction} = \text{credit} \text{ then } p.\text{amount} \text{ else } -p.\text{amount})$$

$$\text{Income Balance} = \sum_{p \in \text{Postings}} (\text{if } p.\text{direction} = \text{credit} \text{ then } p.\text{amount} \text{ else } -p.\text{amount})$$

$$\text{Expense Balance} = \sum_{p \in \text{Postings}} (\text{if } p.\text{direction} = \text{debit} \text{ then } p.\text{amount} \text{ else } -p.\text{amount})$$

*Condition:* All queries strictly restrict evaluation to:
`WHERE e.lifecycle_status = 'posted' AND a.is_active = 1`.

### 3.2 Fundamental Accounting Equation
Every posted transaction maintains global mathematical balance:

$$\sum \text{Assets} = \sum \text{Liabilities} + \sum \text{Base Equity} + (\sum \text{Income} - \sum \text{Expenses})$$

$$\text{Net Worth} = \sum \text{Assets} - \sum \text{Liabilities} = \sum \text{Base Equity} + \text{Retained Earnings}$$

### 3.3 Safe-to-Spend Computation
Derived in [`CanonicalFinancialQueryRepository.getSafeToSpend`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_financial_query_repository.dart#L326-L356):

$$\text{Safe-to-Spend} = \text{Liquid Assets} - \text{Active Earmarks} - \text{Known 14d Commitments} - \text{Pending High-Confidence Debits}$$

Where:
- **Liquid Assets**: $\sum(\text{debits} - \text{credits})$ across posted postings on active accounts with `subtype IN ('bank', 'cash', 'savings', 'wallet', 'liquid_cash', 'asset')`. Suspense accounts (`subtype = 'suspense'`) and illiquid accounts are strictly excluded.
- **Active Earmarks**: $\sum(\text{amount\_minor\_units})$ in `asset_earmarks`.
- **Known 14d Commitments**: Active reminders due within 14 days + Credit card statement dues due in 14 days (reconciled against payments already posted) + Upcoming recurring obligations due in 14 days (deduplicated against active reminders).
- **Pending Debits**: High-confidence staged review candidates.

---

## 4. SQLite Schema Version & Supported Migration History

### 4.1 Authoritative Schema Version Verification
- Source File: [`lib/data/core/app_database.dart`](file:///Users/sivek/Documents/SpendX/lib/data/core/app_database.dart#L88-L141)
- Verified active schema version: **`version: 24`**
- Fresh installs invoke `_onCreate`:
  1. `Tables.allCreateQueries` (Baseline schemas)
  2. `_migrateToV21` (Ledger backfill flags & log schema)
  3. `TablesV24.createAllV24` (Canonical double-entry tables & indexes)
  4. `TablesV24.seedSystemAccounts` (`sys_equity_opening`, `sys_exp_refunds`, `sys_exp_misc`, etc.)
  5. `TablesV24.installTriggers` (7 native SQLite triggers)
  6. `EvidencePruningService.pruneExpiredEvidence` (SMS 30-day retention purge)

### 4.2 Migration Chain from Legacy Versions
The upgrade path is implemented in `AppDatabase._applyUpgrades` ([`lib/data/core/app_database.dart`](file:///Users/sivek/Documents/SpendX/lib/data/core/app_database.dart#L178-L209)):

```
v1/v2 ──> v3 ──> v5 ──> v6 ──> v7 ──> v8 ──> v9 ──> v10 ──> v11 ──> v12 ──> v13 ──> v14 ──> v15 ──> v16 ──> v17 ──> v18 ──> v19 ──> v20 ──> v21 ──> v22 ──> v23 ──> v24
```

| Step | Target Version | Actions Executed |
| :--- | :---: | :--- |
| `_migrateToV3` | v3 | Adds `credit_cards.limit_amount`, `credit_cards.used_amount`, `loans.total`, `budgets.category_id`. |
| `_migrateToV5` | v5 | Adds `lendings.user_id`, `lendings.person_name`. |
| `_migrateToV10`| v10 | Creates `review_queue` table. |
| `_migrateToV11`| v11 | Adds `merchant_rules.account_id`. |
| `_migrateToV12`| v12 | Creates `goals` table. |
| `_migrateToV13`| v13 | Creates `streaks` and `goal_logs`. |
| `_migrateToV14`| v14 | Adds `companies.currency`. |
| `_migrateToV15`| v15 | Creates `salary_months` and `salary_ledger`. |
| `_migrateToV20`| v20 | Upgrades `ledger_transactions.category_id` from INTEGER to TEXT (rebuilds table). |
| `_migrateToV21`| v21 | Creates `ledger_backfill_log` and `ledger_backfill_flags`. |
| `_migrateToV22`| v22 | Extends `reminders` table with source linkage, snooze, and scheduling columns. |
| `_migrateToV23`| v23 | Adds `bank_accounts.last4` for automatic SMS account matching. |
| `_migrateToV24`| **v24** | **SpendX 2.0 Canonical Double-Entry Migration:**<br>1. Creates cold backup: `VACUUM INTO '<path>.pre_v24_backup'`.<br>2. Creates `accounts`, `economic_events`, `postings`, `evidence`, `asset_earmarks`.<br>3. Seeds system accounts (`sys_equity_opening`, `sys_exp_refunds`, etc.).<br>4. Reconciles single-entry legacy records into balanced postings.<br>5. Installs the 7 native SQLite lifecycle and immutability triggers. |

---

## 5. Identified Accounting & Reconciliation Risks

### 5.1 Reversal Exclusion Discrepancy in `TransactionRepo.getStatsForRange` (Confirmed Defect / Risk)
- **Affected File:** [`lib/data/repositories/transaction_repo.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/transaction_repo.dart#L347-L375)
- **Evidence:** In `getStatsForRange(start, end)`:
  ```sql
  SELECT
    COALESCE(SUM(CASE WHEN a.account_type = 'income' AND p.direction = 'credit' THEN p.amount_minor_units ELSE 0 END), 0) / 100.0 AS income,
    COALESCE(SUM(CASE WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units ELSE 0 END), 0) / 100.0 AS expense,
    ...
  FROM postings p
  JOIN accounts a ON p.account_id = a.id
  JOIN economic_events e ON p.economic_event_id = e.id
  WHERE e.lifecycle_status = 'posted'
    AND e.event_type NOT LIKE 'adjustment%'
    AND e.description NOT LIKE 'REVERSAL:%'
    AND e.timestamp >= ? AND e.timestamp < ?;
  ```
- **The Defect:** When a transaction is deleted via `TransactionRepo.delete(id)`, a reversal event is created with `description: 'REVERSAL: ...'` and postings with inverted direction (for an expense: credit on expense account).
  Because `getStatsForRange` explicitly excludes `e.description NOT LIKE 'REVERSAL:%'` AND only sums `p.direction = 'debit'`, the original expense debit is **still summed**, while the reversal credit is **ignored**. This causes `getStatsForRange` to report an un-reversed expense!
- **Contrast:** `TransactionRepo.getMonthlyStats` ([line 392](file:///Users/sivek/Documents/SpendX/lib/data/repositories/transaction_repo.dart#L392)) correctly nets debits minus credits:
  ```sql
  WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units
  WHEN a.account_type = 'expense' AND p.direction = 'credit' THEN -p.amount_minor_units
  ```
- **Action for Phase 2:** Documented as a known risk/defect. Do not fix in discovery; include in reconciliation test assertions.

### 5.2 Peer Lending Architectural Isolation
- **Affected Files:** [`lib/data/repositories/lending_repo.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/lending_repo.dart), [`lib/screens/lending/lending_screen.dart`](file:///Users/sivek/Documents/SpendX/lib/screens/lending/lending_screen.dart)
- **Finding:** Entries in `lendings` are maintained as standalone operational records. They do not generate `economic_events` or `postings` in `TablesV24`. As a result:
  - Lending records do not alter `bank_accounts` derived balance.
  - Lending records do not alter `CanonicalFinancialQueryRepository.getTotalAssets()`.
  - Lending records are aggregated separately in `ReportsService` (`lendingTrendMap`) and `LiabilitiesProviders`.
- **Accounting Risk:** If a user expects adding "You Gave ₹5,000" in Lending to automatically deduct ₹5,000 from their Bank Account balance without recording a separate transaction, the bank balance will not change.

### 5.3 Credit Card Bill Settlements Counted as Expenses (Prevented by Design)
- **Verified:** When a credit card bill payment occurs, it is categorized as `type = 'credit_payment'` or `CanonicalEventType.cardPayment` (`liability_settlement`).
- Its posting legs are:
  - Debit Card Liability (reduces debt)
  - Credit Bank Asset (cash outflow)
- In `CanonicalFinancialQueryRepository.getTotalExpenses()`, only accounts with `account_type = 'expense'` are summed. Card liability is `account_type = 'liability'`, so bill payments have strictly **₹0 expense impact**.

### 5.4 Partial Refunds & Contra-Expense Allocation
- **Verified:** When a refund is ingested, `CanonicalTransactionAdapter.toPostings` credits the category account if provided, or defaults to `TablesV24.sysExpRefunds`.
- Because `sys_exp_refunds` has `account_type = 'expense'`, its credit posting properly reduces global net expenses.
- However, if a partial refund does not reference the original transaction's specific `category_id`, that specific category's spending in `getCategorySpending` will remain un-netted, even though overall monthly expenses are netted correctly.

### 5.5 Stale Cache Desynchronization Safeguard
- In `CreditRepo.update(CreditCard card)`, ordinary UI metadata updates (name, color, icon) explicitly ignore `card.usedAmount` to prevent creating spurious opening-balance reconciliation events.
- Balances are derived dynamically from postings on every query.

---

## 6. Existing Test Coverage Analysis

SpendX already has a comprehensive suite of tests verifying double-entry invariants, firewall protections, and repository boundaries:

| Test File | Total Tests | Focus Areas |
| :--- | :---: | :--- |
| [`test/features/live_sms_credit_classification_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/live_sms_credit_classification_test.dart) | 25 | Bank SMS parsing, CC bill payment classification, BBPS/UPI matching, Gate 1 collision, Gate 2 suspense isolation, 15-step suspense scenario. |
| [`test/repositories/canonical_write_firewall_test.dart`](file:///Users/sivek/Documents/SpendX/test/repositories/canonical_write_firewall_test.dart) | 25 | Static invariants, rogue writes to legacy tables fail to alter canonical balances, 7 native SQLite triggers verification, double-write prevention. |
| [`test/features/c9_legacy_retirement_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/c9_legacy_retirement_test.dart) | 30 | Zero writes/reads to legacy `transactions`/`ledger_transactions`, CSV import deduplication, review queue isolation, net worth equality regression. |
| [`test/repositories/canonical_account_repository_test.dart`](file:///Users/sivek/Documents/SpendX/test/repositories/canonical_account_repository_test.dart) | 6 | Derived balance calculation across normal debit and credit accounts, zero draft leakage, archiving. |
| [`test/features/cross_screen_consistency_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/cross_screen_consistency_test.dart) | 4 | Account label resolution, MTD current month tooltip, compact viewport layout constraints. |
| [`test/features/reports_redesign_regression_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/reports_redesign_regression_test.dart) | 7 | Dynamic 3M/6M/12M range calculation, dual rods chart data, loan principal zero-interest integrity. |
| [`test/features/reports_category_resolver_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/reports_category_resolver_test.dart) | 2 | Custom vs system category name resolution. |
| [`test/features/accounts_conversion_regression_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/accounts_conversion_regression_test.dart) | 1 | Asset account to credit card conversion preserving transaction history. |
| **Total Automated Regression Tests** | **100+** | **All currently passing with 0 static analysis issues.** |

### Missing Test Coverage to be Built in Phase 2
The existing tests thoroughly verify single-component boundaries and firewall rules. However, end-to-end multi-day lifecycle reconciliation tests covering chained operations are missing:
1. **Purchase $\rightarrow$ Partial Refund $\rightarrow$ Second Partial Refund** (asserting exact net category and cash balance).
2. **Account A $\rightarrow$ Account B Transfer followed by Transfer Edit** (amount change and destination change).
3. **Credit Card Purchase $\rightarrow$ Partial Statement Payment $\rightarrow$ Remainder Payment** (asserting liability reaches exactly ₹0.00).
4. **Loan Disbursement $\rightarrow$ Regular Monthly EMI $\rightarrow$ Partial Prepayment** (asserting principal balance reduction).
5. **Transaction Creation $\rightarrow$ Update $\rightarrow$ Deletion Chain** (verifying that after deletion, all account balances and net worth return to the exact initial baseline).

---

## 7. Proposed Reconciliation Test Scenarios (Pillar 1 Test Plan)

When approved to implement tests, the following 10 deterministic test suites will be constructed using integer paise assertions:

### Scenario 1: Purchase $\rightarrow$ Partial Refund $\rightarrow$ Full Refund Completion
- **Steps:**
  1. Record bank expense of ₹10,000.00 (`cat_electronics`).
  2. Record partial refund of ₹3,000.00 against `cat_electronics`.
  3. Record second refund of ₹7,000.00 against `cat_electronics`.
- **Assertions:**
  - Bank balance: $-10000 + 3000 + 7000 = 0$ paise change.
  - Category `cat_electronics` expense: $10000 - 3000 - 7000 = 0$ paise.
  - Cash flow impact: ₹0.00 net.
  - Net worth impact: ₹0.00 net.

### Scenario 2: Credit Card Purchase $\rightarrow$ Bill Settlement Sequence
- **Steps:**
  1. Bank opening balance: ₹50,000.00.
  2. Credit Card initial outstanding: ₹0.00.
  3. Credit card purchase of ₹12,500.00 (`cat_shopping`).
  4. Settle credit card bill of ₹12,500.00 from Bank Account.
- **Assertions:**
  - At step 3: Bank balance = ₹50,000.00; Card liability = ₹12,500.00; Net Worth = ₹37,500.00; Expenses = ₹12,500.00; Cash Flow = ₹0.00.
  - At step 4: Bank balance = ₹37,500.00; Card liability = ₹0.00; Net Worth = ₹37,500.00; Expenses = ₹12,500.00; Cash Flow = -₹12,500.00.
  - Reconcile: Bill payment did NOT increase expenses to ₹25,000.00.

### Scenario 3: Partial Credit Card Bill Settlement & Residual Liability
- **Steps:**
  1. Card purchase: ₹20,000.00.
  2. Partial payment: ₹8,000.00 from Bank.
- **Assertions:**
  - Card liability = ₹12,000.00 (1,200,000 paise).
  - Bank balance reduced by exactly ₹8,000.00 (800,000 paise).
  - Expense recognized = ₹20,000.00.

### Scenario 4: Inter-Account Transfer Parity
- **Steps:**
  1. Account A opening balance: ₹1,00,000.00.
  2. Account B opening balance: ₹10,000.00.
  3. Transfer ₹35,000.00 from Account A to Account B.
- **Assertions:**
  - Account A derived balance = ₹65,000.00 (6,500,000 paise).
  - Account B derived balance = ₹45,000.00 (4,500,000 paise).
  - Total liquid assets = ₹1,10,000.00 (unchanged).
  - Net Worth = ₹1,10,000.00 (unchanged).
  - Net Cash Flow = ₹0.00.

### Scenario 5: Full Transaction Lifecycle (Create $\rightarrow$ Edit $\rightarrow$ Delete)
- **Steps:**
  1. Bank opening balance: ₹50,000.00.
  2. Create expense: ₹5,000.00 (`cat_dining`).
  3. Edit expense to ₹7,500.00 (`cat_groceries`).
  4. Delete expense.
- **Assertions:**
  - After step 2: Bank = ₹45,000.00; Dining = ₹5,000.00.
  - After step 3: Bank = ₹42,500.00; Dining = ₹0.00; Groceries = ₹7,500.00.
  - After step 4: Bank = ₹50,000.00; Groceries = ₹0.00; Dining = ₹0.00; Net Worth = ₹50,000.00.
  - Assert that all 3 operations produce immutable posted events and reversals with zero trigger violations.

### Scenario 6: Loan Disbursement $\rightarrow$ Combined EMI Settlement
- **Steps:**
  1. Bank opening balance: ₹25,000.00.
  2. Loan disbursement of ₹5,00,000.00 into Bank.
  3. Record combined EMI: Principal ₹15,000.00, Interest ₹4,500.00 (Total debit ₹19,500.00).
- **Assertions:**
  - After step 2: Bank = ₹5,25,000.00; Loan liability = ₹5,00,000.00; Net Worth = ₹25,000.00.
  - After step 3: Bank = ₹5,05,500.00; Loan liability = ₹4,85,000.00; Interest expense = ₹4,500.00; Net Worth = ₹20,500.00 (reduced strictly by interest).

### Scenario 7: Suspense Account Isolation
- **Steps:**
  1. Ingest SMS debit of ₹2,500.00 where bank account cannot be matched (routes to `sys_suspense_transfer`).
  2. Compute Safe-to-Spend.
- **Assertions:**
  - `sys_suspense_transfer` derived balance = -₹2,500.00.
  - Safe-to-Spend liquid assets is NOT reduced by this negative suspense balance (isolated from liquid cash).

### Scenario 8: Duplicate Transaction Prevention via Forensic SHA-256
- **Steps:**
  1. Ingest SMS transaction with external ref `UPI/123456789/Paytm`.
  2. Attempt re-ingesting identical transaction with same `external_ref`.
- **Assertions:**
  - Database rejects duplicate or `existsByExternalRef` returns `true`.
  - Exactly 1 `EconomicEvent` and 2 `Postings` exist in the database.

### Scenario 9: Mathematical Conservation (Debit Sum == Credit Sum)
- **Steps:**
  - Execute a multi-day interleaved series of 20 operations across 3 bank accounts, 2 credit cards, and 1 loan.
- **Assertions:**
  - Assert query:
    $$\sum_{\text{all posted postings}} (\text{if direction = debit then amount else } -\text{amount}) == 0$$
  - Total Assets == Total Liabilities + Base Equity + (Income - Expenses).

---

## 8. Final Assessment & Deliverable Summary

### 8.1 Verified Invariants
1. **Schema Version is Confirmed v24:** Verified in source code ([`lib/data/core/app_database.dart`](file:///Users/sivek/Documents/SpendX/lib/data/core/app_database.dart#L141)).
2. **Immutable Double-Entry Persistence:** All financial records are persisted through `CanonicalEventRepository.createAndPostEvent` with strict trigger validation.
3. **No Truth in Mutable Columns:** `bank_accounts.balance`, `credit_cards.used_amount`, and `loans.paid_amount` are projections, not authoritative storage.
4. **Zero Draft Leakage:** All canonical queries filter `WHERE e.lifecycle_status = 'posted'`.
5. **Credit Card Bill Payments are Non-Expenses:** Postings reduce liquid bank cash and reduce card liabilities without hitting income statement accounts.

### 8.2 Unverified Assumptions / Clarifications
1. **Peer Lending Isolation:** Peer lending in `lendings` does not generate double-entry postings or debit bank accounts. It is an operational tracker.
2. **Category-Level Partial Refund Tracking:** If a refund does not specify a category ID, it balances against `sys_exp_refunds`. Global expenses are accurate, but the original category spending is not retroactively reduced.

### 8.3 Confirmed Defects
1. **`TransactionRepo.getStatsForRange` Excludes Reversal Credits:**
   - Filters `e.description NOT LIKE 'REVERSAL:%'` while only summing `direction = 'debit'`.
   - Deleted/reversed expenses within the range are not netted to ₹0 in this specific legacy-compatible query method. (Contrast with `getMonthlyStats` which nets properly).

### 8.4 Recommended Next Implementation Step
1. **Implement Pillar 1 Multi-Day Ledger Reconciliation Test Suite:**
   Create `test/features/ledger_reconciliation_test.dart` implementing Scenarios 1 through 9.
2. Verify all 9 scenarios against the current engine without changing production code.
3. Formulate targeted, verified fixes for identified defects (e.g. `getStatsForRange` netting) only after test demonstration and approval.
