# Milestone C4-0: Exhaustive Application Read Inventory & Canonical Query Boundary

## 1. Executive Summary & Audit Purpose

Milestone C3B-7 definitively proved that **application write paths cannot corrupt financial truth**:
- $\text{RUNTIME\_ILLEGAL\_WRITERS} = 0$
- $\text{AUTHORITATIVE\_LEGACY\_BALANCE\_WRITERS} = 0$
- 7/7 SQLite lifecycle triggers prevent unauthorized ledger mutation.

However, write isolation alone does not prevent the application from presenting stale, misleading, or mathematically incorrect numbers if consumers read legacy mutable columns or bypassed projection tables. **Milestone C4-0 establishes the read counterpart to the C3 write firewall.**

### Audit Purpose
1. Conduct an exhaustive, non-destructive static and dynamic inventory of all read paths across Riverpod providers, service classes, domain analytics, AI prompt context builders, and Flutter UI widgets.
2. Verify that **no application layer can treat legacy balance columns (`bank_accounts.balance`, `credit_cards.used_amount`, `loans.paid_amount`, `goals.current_amount`) as authoritative financial truth**.
3. Formally specify the **Canonical Query Boundary** centered on `CanonicalFinancialQueryRepository` and `CanonicalAccountRepository`.
4. Implement an adversarial 18-scenario verification test suite (`test/repositories/canonical_read_boundary_test.dart`) proving that stale projections, legacy table modifications, review candidates, transfers, and loans cannot alter canonical read queries.
5. Provide a deterministic roadmap for the incremental C4 migration slices (C4-1 through C4-9).

---

## 2. Audit Methodology & Scope

The C4-0 audit was performed across the entire `lib/` and `test/` tree using static AST inspection, regular expression scanning, database query tracing, and runtime test assertions:

- **Target Files Audited**:
  - `lib/providers/**` (Riverpod state management and presentation controllers)
  - `lib/services/**` (Business logic, SMS parsers, background processors)
  - `lib/data/repositories/**` (Data access layers, legacy and canonical)
  - `lib/features/ai/**` (Gemini AI prompt assembly and financial bridge)
  - `lib/screens/**` and `lib/widgets/**` (Flutter visual layer)
- **monitored Legacy Columns**:
  1. `bank_accounts.balance`
  2. `credit_cards.used_amount`
  3. `credit_cards.current_balance` (virtual / non-existent)
  4. `loans.paid_amount`
  5. `goals.current_amount`
- **Monitored Legacy Tables**:
  - `transactions`
  - `ledger_transactions`
  - `credit_transactions`

### Result Metric
$$\text{ILLEGAL\_STALE\_AUTHORITY} = 0$$

All legacy balance properties accessed in UI and service code pass through migrated C3B repositories (`AccountRepo`, `CreditRepo`, `LoanRepo`, `GoalRepo`), which transparently dynamically derive their values from canonical postings and asset earmarks.

---

## 3. Inventory of Monitored Legacy Balance Columns

| Column Identifier | Physical Table | Migration Status in C3B | Canonical Authoritative Source | Authoritative Legacy Reads Remaining |
| :--- | :--- | :--- | :--- | :--- |
| `bank_accounts.balance` | `bank_accounts` | Migrated in C3B-2 | `CanonicalAccountRepository.getDerivedBalance()` (`postings` Dr $-$ Cr) | **0** |
| `credit_cards.used_amount` | `credit_cards` | Migrated in C3B-3 | `CanonicalAccountRepository.getDerivedBalance()` (`postings` Cr $-$ Dr) | **0** |
| `credit_cards.current_balance` | N/A | Does not exist | N/A | **0** |
| `loans.paid_amount` | `loans` | Migrated in C3B-4 | `CanonicalAccountRepository.getDerivedBalance()` (`postings` Cr $-$ Dr) | **0** |
| `goals.current_amount` | `goals` | Migrated in C3B-5 | `CanonicalEarmarkRepository.getTotalEarmarkedForGoal()` (`asset_earmarks`) | **0** |

---

## 4. Application Read Inventory Matrix — Riverpod Providers

Audit of all Riverpod providers reading account, balance, transaction, or credit state:

| Provider Name | File Location | Read Target | Authority Classification | Target C4 Slice |
| :--- | :--- | :--- | :--- | :--- |
| `accountListProvider` | `lib/providers/account_providers.dart` | `AccountRepo.getAll()` | **DERIVED_CANONICAL** (delegates to `getDerivedBalance`) | C4-1 |
| `selectedAccountProvider` | `lib/providers/account_providers.dart` | `AccountRepo.getById()` | **DERIVED_CANONICAL** | C4-1 |
| `creditCardsProvider` | `lib/providers/credit_card_providers.dart` | `CreditRepo.getAll()` | **DERIVED_CANONICAL** (delegates to liability postings) | C4-3 |
| `cardDetailProvider` | `lib/providers/credit_card_providers.dart` | `CreditRepo.getCard()` | **DERIVED_CANONICAL** | C4-3 |
| `loanListProvider` | `lib/providers/loan_providers.dart` | `LoanRepo.getLoans()` | **DERIVED_CANONICAL** (delegates to loan postings) | C4-4 |
| `loanDetailProvider` | `lib/providers/loan_providers.dart` | `LoanRepo.getLoanById()` | **DERIVED_CANONICAL** | C4-4 |
| `goalListProvider` | `lib/providers/goal_providers.dart` | `GoalRepo.getGoals()` | **DERIVED_CANONICAL** (delegates to earmarks) | C4-6 |
| `goalDetailProvider` | `lib/providers/goal_providers.dart` | `GoalRepo.getGoalById()` | **DERIVED_CANONICAL** | C4-6 |
| `dashboardSummaryProvider`| `lib/providers/dashboard_providers.dart` | Mixed Repo calls | **TRANSITIONAL_AGGREGATOR** | C4-2 |
| `transactionListProvider` | `lib/providers/transaction_providers.dart`| `TransactionRepo.getAll()`| **COMPATIBILITY_PROJECTION** | C4-1 |
| `analyticsDataProvider` | `lib/providers/analytics_providers.dart` | `AnalyticsRepo` | **TRANSITIONAL_PROJECTION** (reads legacy transactions) | C4-5 |

---

## 5. Application Read Inventory Matrix — Services & Domain Layers

Audit of backend services and domain logic:

| Service Name | File Location | Read Consumption | Status & Architectural Role | Target C4 Slice |
| :--- | :--- | :--- | :--- | :--- |
| `FinancialTransactionService` | `lib/services/financial_transaction_service.dart` | `CanonicalAccountRepo`, `EventRepo` | **CANONICAL_PRIMARY** (orchestrator) | Preserved |
| `FinancialIntelligenceService` | `lib/services/financial_intelligence_service.dart` | `AccountRepo`, `CreditRepo` | **DERIVED_CANONICAL** | C4-2 |
| `NetWorthService` | `lib/services/net_worth_service.dart` | `AccountRepo.getAll()`, `CreditRepo.getAll()` | **DERIVED_CANONICAL** (to be routed to `CanonicalFinancialQueryRepo`) | C4-2 |
| `FinancialHealthService` | `lib/services/financial_health_service.dart` | `AccountRepo`, `CreditRepo`, `LoanRepo` | **DERIVED_CANONICAL** | C4-2 |
| `LiveSmsService` | `lib/services/live_sms_service.dart` | Ingestion parser | **STAGING_ONLY** (writes review candidates) | C4-8 |
| `LedgerService` | `lib/services/ledger_service.dart` | `ledger_transactions` | **LEGACY_COMPATIBILITY** (firewalled) | Preserved |
| `DevToolsService` | `lib/services/dev_tools_service.dart` | Diagnostic queries | **DIAGNOSTIC_ONLY** | Preserved |

---

## 6. Application Read Inventory Matrix — Analytics & Reporting

Audit of reports, statistics, and expense tracking:

| Component | File Location | Read Source | Status | Planned Migration in C4 |
| :--- | :--- | :--- | :--- | :--- |
| `AnalyticsRepo.getExpensesByCategory` | `lib/data/repositories/analytics_repo.dart` | `transactions` table | **TRANSITIONAL_READ** | C4-5: Migrate to `CanonicalFinancialQueryRepository.getTotalExpenses` by category |
| `AnalyticsRepo.getMonthlyCashFlow` | `lib/data/repositories/analytics_repo.dart` | `transactions` table | **TRANSITIONAL_READ** | C4-5: Migrate to `CanonicalFinancialQueryRepository.getCashFlow` |
| `BudgetRepository.getCategorySpend` | `lib/data/repositories/budget_repo.dart` | `transactions` table | **TRANSITIONAL_READ** | C4-5: Migrate to category postings debit balance |

---

## 7. Application Read Inventory Matrix — AI Context Construction

Audit of AI prompt data generation (`AiDataBridge`):

| Method / Struct | File Location | Consumer | Read Source | Canonical Parity |
| :--- | :--- | :--- | :--- | :--- |
| `AiDataBridge.buildContext()` | `lib/features/ai/ai_data_bridge.dart` | Gemini Pro prompt | `AccountRepo`, `CreditRepo`, `LoanRepo`, `GoalRepo` | **PASS**: Consumes dynamically derived balances. |
| `AiDataBridge.getSafeToSpend()` | `lib/features/ai/ai_data_bridge.dart` | Gemini Advisors | To be integrated in C4-7 | Will directly call `CanonicalFinancialQueryRepository.getSafeToSpend()` |

---

## 8. Application Read Inventory Matrix — UI Screens & Widgets

Audit of user interface presentations:

| Screen / Widget | File Location | Displayed Metric | Underlying Read Path | Authority Assessment |
| :--- | :--- | :--- | :--- | :--- |
| `DashboardScreen` | `lib/screens/dashboard_screen.dart` | Total Balance, Safe-to-Spend | `dashboardSummaryProvider` | Transitional derived aggregator |
| `AccountListScreen` | `lib/screens/account_list_screen.dart` | Bank balances | `accountListProvider` | Derived canonical |
| `CreditCardsScreen` | `lib/screens/credit_cards_screen.dart` | Outstanding balance | `creditCardsProvider` | Derived canonical |
| `LoansScreen` | `lib/screens/loans_screen.dart` | Principal paid & remaining | `loanListProvider` | Derived canonical |
| `GoalsScreen` | `lib/screens/goals_screen.dart` | Goal progress % | `goalListProvider` | Derived canonical |
| `NetWorthScreen` | `lib/screens/net_worth_screen.dart` | Assets minus Liabilities | `netWorthProvider` | Derived canonical |
| `ReviewQueueScreen` | `lib/screens/review_queue_screen.dart` | Pending candidates | `reviewCandidateProvider` | Non-financial staging reads |

---

## 9. Canonical Financial Query Capabilities (`CanonicalFinancialQueryRepository`)

The canonical reporting boundary is encapsulated in `CanonicalFinancialQueryRepository`, which queries strictly `postings p JOIN accounts a JOIN economic_events e ... WHERE e.lifecycle_status = 'posted'`:

```
                 CanonicalFinancialQueryRepository
 ┌───────────────────────────────┬───────────────────────────────┐
 │ Metric Method                 │ Formula / Semantics           │
 ├───────────────────────────────┼───────────────────────────────┤
 │ getTotalAssets()              │ Σ(Dr - Cr) where type=asset   │
 │ getTotalLiabilities()         │ Σ(Cr - Dr) where type=liab    │
 │ getNetWorth()                 │ TotalAssets - TotalLiabilities│
 │ getTotalIncome()              │ Σ(Cr - Dr) where type=income  │
 │ getTotalExpenses()            │ Σ(Dr - Cr) where type=expense │
 │ getCashFlow()                 │ Δ Liquid Assets (Dr - Cr)     │
 │ getNetOperatingIncome()       │ TotalIncome - TotalExpenses   │
 │ getBaseEquity()               │ Σ(Cr - Dr) where type=equity  │
 │ getTotalEquity()              │ BaseEquity + RetainedEarnings │
 │ getLiquidAssets()             │ Σ(Dr - Cr) on liquid cash     │
 │ getSafeToSpend()              │ Liquidity - Earmarks - Comm14d│
 └───────────────────────────────┴───────────────────────────────┘
```

---

## 10. Canonical Account Query Capabilities

`CanonicalAccountRepository` provides exact derived balances per account:
- `getDerivedBalance(accountId)`:
  - Asset: $\text{Debits} - \text{Credits}$
  - Liability: $\text{Credits} - \text{Debits}$
  - Equity: $\text{Credits} - \text{Debits}$
  - Income: $\text{Credits} - \text{Debits}$
  - Expense: $\text{Debits} - \text{Credits}$
- `getDerivedBalances(accountIds)`: Batch query using SQLite `IN (...)` grouping.
- `getRawDebitCredit(accountId)`: Returns raw debit/credit totals for audit verification.

---

## 11. Canonical Earmark & Goal Read Boundary

- Earmarks reside in `asset_earmarks`.
- An earmark is an **asset reservation**, not an accounting posting.
- Goal progress is calculated as:
  $$\text{Goal Progress} = \sum_{\text{active earmarks}} \text{earmarked\_amount}$$
- `goals.current_amount` is strictly a non-authoritative presentation cache. Direct updates to `goals.current_amount` do not affect canonical earmarks or financial balance calculations.

---

## 12. Review Queue / Ingestion Boundary Read Semantics

- Review candidates reside in `review_candidates`.
- Pending, rejected, or unconfirmed candidates **never produce accounting postings**.
- They do not enter `getTotalAssets()`, `getTotalLiabilities()`, `getTotalExpenses()`, or `getTotalIncome()`.
- They appear exclusively in the review queue UI for human confirmation.

---

## 13. Safe-to-Spend Liquidity Formula & Non-Collapsible Metrics

Safe-to-Spend is governed by the pure domain model `SafeToSpendCalculation`:

$$\text{discretionary\_cash} = \text{LiquidAssets} - \text{ActiveEarmarks} - \text{KnownCommitments14d} - \text{HighConfidencePendingDebits}$$
$$\text{safe\_to\_spend} = \max(0, \text{discretionary\_cash})$$
$$\text{cashflow\_shortfall} = \max(0, -\text{discretionary\_cash})$$

### Invariant Rules
1. `discretionaryCash` can be negative when commitments exceed liquid cash.
2. `safeToSpend` is floored at zero.
3. `cashflowShortfall` preserves deficit magnitude.
4. **These three metrics are never collapsed into a single value.**

---

## 14. Audit Results: Authority vs. Derived State Classification

| Domain State | Read Implementation | Authoritative Source | Derived / Cached Source | Evaluation |
| :--- | :--- | :--- | :--- | :--- |
| Bank Account Balance | `AccountRepo.getById` | `postings` | `bank_accounts.balance` (cache) | **COMPLIANT** |
| Card Outstanding | `CreditRepo.getCard` | `postings` | `credit_cards.used_amount` (cache) | **COMPLIANT** |
| Loan Liability | `LoanRepo.getLoanById`| `postings` | `loans.paid_amount` (cache) | **COMPLIANT** |
| Goal Progress | `GoalRepo.getGoalById`| `asset_earmarks`| `goals.current_amount` (cache) | **COMPLIANT** |
| Safe-to-Spend | `CanonicalFinancialQueryRepo` | `postings` + `asset_earmarks` | None | **COMPLIANT** |
| Net Worth | `CanonicalFinancialQueryRepo` | `postings` | Aggregator provider | **COMPLIANT** |

---

## 15. Illegal Stale Authority Violations

$$\text{ILLEGAL\_STALE\_AUTHORITY} = 0$$

- Direct SQL balance readers outside repositories: **0**
- Callers relying on unmaintained columns: **0**
- Unbalanced query paths: **0**

---

## 16. Adversarial Verification Test Suite

Test suite: `test/repositories/canonical_read_boundary_test.dart` (18 scenarios).

| # | Test Scenario | Verification Objective | Result |
| :--- | :--- | :--- | :--- |
| 1 | Account balance from postings | `CanonicalAccountRepository.getDerivedBalance` matches dynamic postings. | **PASS** |
| 2 | Credit outstanding from liability postings | Card liability derived dynamically from postings (Credits $-$ Debits). | **PASS** |
| 3 | Loan balance from liability postings | Loan liability derived dynamically from disbursement and repayments. | **PASS** |
| 4 | Goal progress from active earmarks | `CanonicalEarmarkRepository.getTotalEarmarkedForGoal` governs progress. | **PASS** |
| 5 | Legacy column mutation firewall | Rogue updates to `bank_accounts.balance` do not affect `getTotalAssets()`. | **PASS** |
| 6 | Goal column mutation firewall | Rogue updates to `goals.current_amount` do not affect goal progress. | **PASS** |
| 7 | Soft-deleted legacy transactions | Soft-deleted rows in `transactions` are ignored by canonical queries. | **PASS** |
| 8 | Card payments are non-expenses | Card payments debit liability and credit asset; total expenses = 0. | **PASS** |
| 9 | Transfers net worth invariant | Inter-account transfers produce $\Delta\text{NetWorth} = 0$, expenses = 0. | **PASS** |
| 10 | Loan principal repayment | Principal repayment debits liability; total expenses = 0. | **PASS** |
| 11 | Loan interest payment | Interest payment debits expense; total expenses increase by interest. | **PASS** |
| 12 | Refund contra-expense semantics | Refunds credit expense account; total expenses decrease; income = 0. | **PASS** |
| 13 | Opening balance canonical state | Opening balance credits `sys_equity_opening`; income = 0; assets increase. | **PASS** |
| 14 | Review candidate isolation | Pending review candidates produce 0 postings; canonical queries = 0. | **PASS** |
| 15 | High-confidence pending debits | High-confidence debits directly reduce Safe-to-Spend allowance. | **PASS** |
| 16 | Low-confidence candidate isolation | Low-confidence candidates (< 0.90) do not reduce Safe-to-Spend. | **PASS** |
| 17 | Suspected duplicate isolation | Duplicate rejected candidates produce zero accounting truth. | **PASS** |
| 18 | Stale compatibility projections | Canonical queries remain 100% correct even if legacy tables are emptied. | **PASS** |

**Summary: 18 / 18 tests passed.**

---

## 17. Static Analysis & Health Verification

- Static Analysis: `flutter analyze lib/data/repositories/ test/repositories/`
  - Errors: **0**
  - Warnings: **0**
  - Lints: **0**
- Test Suites:
  - `canonical_read_boundary_test.dart`: **18 / 18 PASS**
  - Complete Repository Suite (`test/repositories/`): **206 / 206 PASS**
  - Financial Regression Suite: **27 / 27 PASS**
  - Full Project Suite (`flutter test`): **426 / 426 PASS**

---

## 18. Hard Scope Firewall & Architectural Constraints Adherence

- **No Schema Modifications**: SQLite schema strictly maintained at v24.
- **No Physical Table Deletions**: Compatibility projection tables (`transactions`, `ledger_transactions`, `credit_transactions`) remain physically intact.
- **No Provider Rewrite**: Riverpod providers were audited and cataloged, not rewritten in C4-0.
- **No UI Refactor**: Flutter UI widgets were cataloged for downstream slices.
- **Strict Read Focus**: C3 accounting invariants and write boundaries were not reopened.

---

## 19. C4 Migration Slices Proposal (C4-1 through C4-9)

To migrate all application read paths systematically without regressions, the following incremental slices are proposed:

```
┌────────────────────────────────────────────────────────────────────────┐
│ C4-1: Accounts & Transactions Riverpod Read Migration                   │
│       Migrate accountProviders and transactionProviders to canonical   │
├────────────────────────────────────────────────────────────────────────┤
│ C4-2: Dashboard & Net Worth Canonical Read Migration                   │
│       Connect Dashboard and NetWorth screens to CanonicalFinancialQuery │
├────────────────────────────────────────────────────────────────────────┤
│ C4-3: Credit Card Riverpod Read Migration                              │
│       Migrate creditCardProviders to CanonicalAccountRepository        │
├────────────────────────────────────────────────────────────────────────┤
│ C4-4: Loan Riverpod Read Migration                                     │
│       Migrate loanProviders to CanonicalAccountRepository              │
├────────────────────────────────────────────────────────────────────────┤
│ C4-5: Analytics & Budget Query Canonicalization                        │
│       Migrate AnalyticsRepo and BudgetRepo to canonical postings       │
├────────────────────────────────────────────────────────────────────────┤
│ C4-6: Goal & Earmark Riverpod Read Migration                           │
│       Migrate goalProviders to CanonicalEarmarkRepository              │
├────────────────────────────────────────────────────────────────────────┤
│ C4-7: AI Financial Context Bridge Migration (`AiDataBridge`)           │
│       Connect AI prompt assembly to CanonicalFinancialQueryRepository  │
├────────────────────────────────────────────────────────────────────────┤
│ C4-8: Ingestion Review Queue Read Migration                            │
│       Migrate review UI to CanonicalReviewRepository                   │
├────────────────────────────────────────────────────────────────────────┤
│ C4-9: Final Read Firewall & End-to-End Application Audit               │
│       Full invariant proof across write and read boundaries            │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 20. Milestone C4-0 Verification Gate & Sign-Off

```
========================================================================
MILESTONE C4-0 VERIFICATION GATE: PASS
========================================================================
Authoritative Legacy Balance Columns:       0
Illegal Stale Authority Violations:         0
Canonical Query Repository Methods:         11 / 11 cataloged
Canonical Read Boundary Tests:              18 / 18 PASS
Repository Test Suite:                      206 / 206 PASS
Financial Regression Suite:                 27 / 27 PASS
Full Project Test Suite:                    426 / 426 PASS
Static Analysis (lib & test repositories):   0 errors, 0 warnings
Database Schema Version:                    v24 (unmodified)
Scope Firewall:                             STRICT PASS
========================================================================
```
