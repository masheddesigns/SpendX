# Milestone C4-2: Dashboard & Net Worth Canonical Read Migration

## 1. Executive Summary & Objective

**Milestone C4-2** executes the canonical read migration for Dashboard summaries, Net Worth calculations, Safe-to-Spend liquidity metrics, and financial-health aggregates across the SpendX Flutter application.

### Core Invariant
**No dashboard metric, net worth display, or liquidity figure may be influenced by legacy mutable columns (`bank_accounts.balance`, `credit_cards.used_amount`, `loans.paid_amount`, `goals.current_amount`) or direct raw inserts into legacy tables (`transactions`, `ledger_transactions`).**

### Key Accomplishments
1. **Canonical Net Worth Migration**:
   - `NetWorthService` in `lib/services/net_worth_service.dart` and `lib/domain/net_worth/net_worth_service.dart` migrated to delegate exclusively to `CanonicalFinancialQueryRepository` (`getTotalAssets()`, `getTotalLiabilities()`, `getNetWorth()`).
   - `netWorthSummaryProvider` in `lib/data/providers.dart` wired to canonical `NetWorthService.calculate()`.
   - `netWorthProvider` updated to observe canonical `netWorthSummaryProvider`.
2. **Dashboard & Home Summary Alignment**:
   - `homeSummaryProvider` and `homeTransactionsProvider` in `lib/features/home/providers/home_providers.dart` migrated to compute monthly income, expense, and balance directly from canonical `transactionsProvider`, cutting off legacy aggregate caches.
   - `dashboardSummaryProvider` in `lib/features/dashboard/providers/dashboard_providers.dart` verified and aligned to canonical transaction streams.
3. **Safe-to-Spend Formal Wiring**:
   - Exported `safeToSpendProvider` backed by `CanonicalFinancialQueryRepository.getSafeToSpend()`.
   - Enforced the mathematically locked domain formula:
     $$\text{Discretionary Cash} = \text{Liquid Assets} - \text{Active Asset Earmarks} - \text{14d Known Commitments} - \text{Pending Debits}$$
     $$\text{Safe-to-Spend} = \max(0, \text{Discretionary Cash})$$
     $$\text{Cashflow Shortfall} = \max(0, -\text{Discretionary Cash})$$
4. **Financial Health Service Hardening**:
   - `FinancialHealthService.calculateMetrics()` and `getHistoricalNetWorth()` in `lib/services/financial_health_service.dart` migrated to derive debt ratio and net worth from `CanonicalFinancialQueryRepository`, eliminating legacy column reads.
5. **Opening Balance Projection Isolation**:
   - In `CanonicalTransactionAdapter.toTransaction`, explicitly mapped `CanonicalEventType.openingBalance` to type `'opening_balance'` rather than defaulting to `'expense'`, guaranteeing account opening equity events never corrupt dashboard expense figures.
6. **Screen Parity Hardening**:
   - `_NetWorthSummary` in `lib/screens/bank/account_list_screen.dart` migrated to prioritize `netWorthSummaryProvider`, ensuring identical asset, liability, and net worth numbers across all screens.
7. **Adversarial Verification Suite**:
   - 12/12 adversarial tests in `test/features/dashboard_net_worth_canonical_read_test.dart` prove that rogue direct writes to legacy columns and tables have **zero impact** on dashboard and net worth state.

---

## 2. Architectural Data Flow

```
                      UI Layer (Home / Net Worth / Accounts)
                                    │
               ┌────────────────────┼────────────────────┐
               ▼                    ▼                    ▼
     homeSummaryProvider    netWorthSummaryProvider  safeToSpendProvider
               │                    │                    │
               ▼                    ▼                    ▼
        TransactionRepo       NetWorthService   CanonicalFinancialQueryRepo
               │                    │                    │
               └────────────────────┼────────────────────┘
                                    ▼
                    CanonicalFinancialQueryRepository
                                    │
               ┌────────────────────┴────────────────────┐
               ▼                                         ▼
       TablesV24.postings                      TablesV24.assetEarmarks
     (Debit/Credit Accounting)                   (Asset Reservations)
```

---

## 3. Adversarial Test Matrix (12 Scenarios)

The test suite in `test/features/dashboard_net_worth_canonical_read_test.dart` executed 12 adversarial test cases:

| # | Test Scenario | Adversarial Attack Vector | Expected Canonical Behavior | Status |
|---|---|---|---|:---:|
| 1 | Canonical Net Worth Baseline | Create Bank (₹10k), Card (₹2k liab), Loan (₹5k liab) | Assets = ₹10k, Liab = ₹7k, Net Worth = ₹3k. | **PASS** |
| 2 | Rogue `bank_accounts.balance` Mutation | `UPDATE bank_accounts SET balance = 999999.0` via raw SQL | Assets and Net Worth remain ₹15,000.0; rogue SQL ignored. | **PASS** |
| 3 | Rogue `credit_cards.used_amount` Mutation | `UPDATE credit_cards SET used_amount = 888888.0` via raw SQL | Liabilities remain ₹3,000.0; Net Worth remains ₹17,000.0. | **PASS** |
| 4 | Rogue `loans.paid_amount` & `total` Mutation | `UPDATE loans SET paid_amount = 0, total = 999999.0` via raw SQL | Liabilities remain ₹10,000.0; Net Worth remains ₹15,000.0. | **PASS** |
| 5 | Rogue `goals.current_amount` Mutation | `UPDATE goals SET current_amount = 777777.0` via raw SQL | Net Worth unaffected (₹30,000.0); goals create zero postings. | **PASS** |
| 6 | Rogue Legacy `transactions` Table Insert | Raw SQL insert of ₹50,000 expense into legacy `transactions` table | `homeSummaryProvider` expense remains ₹2,500.0; rogue row ignored. | **PASS** |
| 7 | Rogue Legacy `ledger_transactions` Table Insert | Raw SQL insert of ₹20,000 into `ledger_transactions` | `NetWorthService` assets remain ₹40,000.0; rogue row ignored. | **PASS** |
| 8 | Dashboard Aggregates Calculation | Post canonical ₹80,000 income and ₹3,200 expense | Income = ₹80,000, Expense = ₹3,200, Balance = ₹76,800. | **PASS** |
| 9 | Safe-to-Spend Locked Formula | ₹50k liquid assets, ₹15k goal earmark | Liquid = ₹50k, Earmarks = ₹15k, Safe-to-Spend = ₹35,000. | **PASS** |
| 10 | Safe-to-Spend Floor at Zero & Shortfall | ₹10k liquid assets, ₹15k commitments | Discretionary = -₹5k, Safe-to-Spend = ₹0, Shortfall = ₹5k. | **PASS** |
| 11 | FinancialHealthService Immunity | Corrupt `credit_cards.used_amount = 999999.0` | Debt ratio = 0.2 (score = 0.8), Net Worth = ₹40,000.0. | **PASS** |
| 12 | Reactive Riverpod Updates | Post ₹5k expense through TransactionRepo | `netWorthSummaryProvider` updates from ₹20k to ₹15k reactively. | **PASS** |

**Adversarial Suite Result**: 12/12 PASS.

---

## 4. Full Project Regression Suite & Static Analysis

| Scope | Test Count | Result |
|---|---|:---:|
| Dedicated C4-2 Adversarial Suite (`test/features/dashboard_net_worth_canonical_read_test.dart`) | 12 | **PASS** |
| Dedicated C4-1 Adversarial Suite (`test/features/accounts_transactions_riverpod_read_test.dart`) | 12 | **PASS** |
| Migrated Repositories Suite (`test/repositories/`) | 206 | **PASS** |
| Financial Transaction Service & Regressions Suite | 27 | **PASS** |
| **Entire SpendX Project Test Suite (`flutter test`)** | **450** | **PASS (100%)** |
| **Static Analyzer (`flutter analyze` on modified files)** | **0 errors, 0 warnings** | **PASS** |

---

## 5. Scope Boundary & Hard Stop Lock

- **Accounting Writes Untouched**: Zero accounting write logic or triggers were modified.
- **Physical Schema Untouched**: SQLite version locked at v24. Zero tables modified, added, or deleted.
- **Transitional Tables Intact**: `transactions`, `ledger_transactions`, `bank_accounts`, `credit_cards`, `loans`, and `goals` tables remain physically intact for backwards compatibility.
- **Out of Scope (Deferred)**:
  - Milestone C4-3: Credit Card Screens Read Migration
  - Milestone C4-4: Loans & Goals Screens Read Migration
  - Milestone C4-5: Analytics & Budget Read Migration
  - Milestone C4-6: AI Data Bridge Read Migration
- **Hard Stop**: Execution halts here. Standing by for authorization to proceed to Milestone C4-3.
