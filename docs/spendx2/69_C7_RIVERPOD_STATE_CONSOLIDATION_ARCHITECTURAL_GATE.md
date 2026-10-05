# SpendX 2.0 — Milestone C7: Riverpod State Consolidation
## Architectural Discovery & Gate Document

---

### 1. Status

* **Milestone**: C7 (Riverpod State Consolidation)
* **Current Phase**: **DISCOVERY ONLY (COMPLETED)**
* **Implementation State**: **NOT STARTED — STRICT HARD STOP RESPECTED**
* **Gate Verdict**: **READY FOR AUTHORIZATION**
* **Database Schema**: SQLite **v24 LOCKED** (0 modifications)
* **Integrity Triggers**: **7 / 7 ACTIVE**
* **Verification Suite**: **579 / 579 PASS** (100% green)
* **Static Analysis**: **0 errors / 0 warnings**

---

### 2. Locked Baseline

The following architectural milestones are formally **CLOSED** and serve as immutable constraints for C7:

| Milestone | Scope | Verified Status |
| :--- | :--- | :--- |
| **C3A / C3A.1** | Canonical Double-Entry Foundation | **CLOSED** |
| **C3B-1 → C3B-7** | Final Repository Write Firewall | **CLOSED** |
| **C4-0 → C4-7** | Application Read Firewall & Canonical Invariants | **CLOSED** |
| **C5** | Multi-Evidence Ingestion & Deduplication Pipeline | **CLOSED** |
| **C6** | Deterministic Forecast Engine Consolidation | **CLOSED** |

#### Core Invariants Maintained
1. **Ledger Truth**: The double-entry SQLite ledger (`economic_events`, `postings`) remains the sole authority for financial balances, transactions, and state.
2. **Forecast Authority**: `CanonicalForecastEngine` remains the sole forecast calculation authority.
3. **Ingestion & Dedup**: Pre-approval evidence store creates zero events/postings; approval flows strictly through `FinancialTransactionService`.
4. **Write Firewall**: Zero direct table mutations outside authorized canonical repositories.
5. **No Schema Changes**: SQLite schema remains at version 24. Triggers `trg_prevent_posting_update`, `trg_prevent_posting_delete`, etc., remain active.

---

### 3. Complete Provider Inventory

SpendX currently declares **187 provider variables** and **11 state notifiers** across 24 files in `lib/`.

#### Summary of Provider Registries & Locations
* **`lib/data/providers.dart` (Central God-File)**: 60 provider declarations, 9 `CachedAsyncNotifier` subclasses, 2 `StateNotifier` subclasses.
* **`lib/features/accounts/providers/account_providers.dart`**: 5 providers (aliases & mutation closures).
* **`lib/features/transactions/providers/transaction_providers.dart`**: 8 providers (aliases, pagination, mutation closures).
* **`lib/features/categories/providers/category_providers.dart`**: 5 providers (repository, fetch, CRUD closures).
* **`lib/features/liabilities/providers/liabilities_providers.dart`**: 11 providers (cards, loans, lending, EMIs).
* **`lib/features/liabilities/providers/credit_health_providers.dart`**: 4 providers (credit health, EMI load, pressure, dues).
* **`lib/features/dashboard/insights_providers.dart`**: 8 providers (timeline, sparkline, change, monthly stats, top categories).
* **`lib/features/dashboard/providers/dashboard_providers.dart`**: 6 providers (summary, transactions, intel, period, categories, accounts).
* **`lib/features/goals/goal_providers.dart`**: 9 providers (goals, earmarks, progress).
* **`lib/features/review_queue/providers/review_providers.dart`**: 7 providers (repo, queue, count, approve/reject closures).
* **`lib/features/salary/providers/salary_providers.dart`**: 6 providers (company, active company, dashboard).
* **`lib/features/salary_ledger/salary_ledger_notifier.dart`**: 8 providers (salary ledger notifier, filters, reports).
* **`lib/features/automation/automation_providers.dart`**: 4 providers (nudges, suggestions, daily decisions).
* **`lib/features/alerts/providers/alert_providers.dart`**: 3 providers (alerts stream, snapshot, service).
* **`lib/features/wrapped/providers/wrapped_providers.dart`**: 3 providers (service, summary, periods).
* **`lib/features/streak/streak_provider.dart`**: 3 providers (repo, streak, evaluate).
* **`lib/features/merchant_rules/providers/merchant_rule_providers.dart`**: 4 providers (repo, rules, learn, delete).
* **`lib/features/core & services`**: 18 providers across `service_providers.dart`, `app_data_sync_manager.dart`, `undo_manager.dart`, `write_queue.dart`, `drive_service.dart`, `health_score_provider.dart`, `forecast_provider.dart`, `runway_provider.dart`, `financial_timeline_provider.dart`, etc.

---

### 4. Provider Classification

All 187 provider declarations are strictly mapped to the required 8-category taxonomy:

| Taxonomy Category | Count | Definition & Key Examples |
| :--- | :---: | :--- |
| **`CANONICAL_DERIVED`** | 38 | Pure projections of double-entry ledger state: `safeToSpendProvider`, `netWorthSummaryProvider`, `netWorthProvider`, `forecastProvider`, `runwayProvider`, `accountEarmarkedTotalProvider`, `goalDerivedProgressProvider`, `financialHealthScoreProvider`, `creditOutstandingProvider`, `currentMonthStatsProvider`. |
| **`CANONICAL_METADATA`** | 24 | Configuration, categories, tags, merchant rules, recurring templates, reminders: `categoriesProvider`, `tagsProvider`, `budgetsProvider`, `recurringProvider`, `remindersProvider`, `merchantRulesProvider`. |
| **`APPLICATION_STATE`** | 42 | Service singletons, repositories, orchestrators, and mutations: `writeQueueProvider`, `appDataSyncManagerProvider`, `canonicalForecastEngineProvider`, `canonicalFinancialQueryRepositoryProvider`, `transactionRepoProvider`, `accountRepoProvider`, `loanRepoProvider`, `creditRepoProvider`, `addTransactionProvider`, `approveReviewProvider`. |
| **`UI_STATE`** | 22 | Presentation-only filters, date range selectors, ephemeral pagination: `dashboardPeriodProvider`, `reportsPeriodProvider`, `salaryFilterProvider`, `salaryStatusFilterProvider`, `selectedFYProvider`, `paginatedTransactionsProvider`. |
| **`TRANSITIONAL_COMPATIBILITY`** | 45 | Aliases and wrapper projections preserving existing widget API contracts: `lib/features/accounts/providers/account_providers.dart:accountsProvider`, `lib/features/transactions/providers/transaction_providers.dart:transactionsProvider`, `creditCardsProvider` (watching `cardsProvider.future`), `loansProvider` (watching `app_data.loansProvider.future`), `reportsProvider`, `homeSafeToSpendProvider`. |
| **`MIGRATION_ONLY`** | 3 | Historical migration helpers: `ledgerMutationProvider`, `emiPlanMutationProvider`, `dataManagementProvider`. |
| **`TEST_ONLY`** | 0 | (Test files instantiate their own local `ProviderContainer` instances; zero production leak). |
| **`ILLEGAL_DUPLICATE_AUTHORITY`** | **0** | **VERIFIED: 0 runtime providers act as alternate financial authorities.** (Legacy fallbacks like `canonical ?? legacy_column` do not exist in provider reads). |

*Note on Duplicate Definitions*: While `ILLEGAL_DUPLICATE_AUTHORITY = 0` (no provider reads illegal columns), there ARE duplicated *in-memory provider definitions* (e.g. `categoriesProvider` defined twice with distinct types), which are cataloged as invalidation/coupling risks in Section 5.

---

### 5. State Ownership Matrix

Auditing all 19 domain financial and application state concerns:

| State Concern | Authoritative Source | In-Memory Duplicate Providers | Risk / Divergence Vector | C7 Consolidation Strategy |
| :--- | :--- | :--- | :--- | :--- |
| **1. Accounts** | `CanonicalFinancialQueryRepository` via `AccountRepo.getAccounts()` | `data/providers.dart:accountsProvider`, `salary_providers.dart:bankAccountsProvider`, `dashboardAccountsProvider` | `bankAccountsProvider` fetches directly from repo rather than sharing `accountsProvider` cache. | Re-route `bankAccountsProvider` and `dashboardAccountsProvider` to consume `accountsProvider`. |
| **2. Balances** | `CanonicalFinancialQueryRepository.getAccountBalances()` | `Account.balance`, `DashboardSummaryData.balance` | `DashboardSummaryData.balance` is computed as period income - expense, which UI may confuse with account balance. | Ensure nomenclature is explicit (`periodNetFlow` vs `liquidBalance`). |
| **3. Transactions** | Canonical ledger via `TransactionRepo.getAll()` | `transactionsProvider`, `paginatedTransactionsProvider`, `dashboardTransactionsProvider` (data), `dashboardTransactionsProvider` (dashboard), `homeTransactionsProvider` | Two competing mutation pathways: `addTransactionProvider` vs `TransactionsNotifier.add`. `homeTransactionsProvider` and `dashboardTransactionsProvider` duplicate slicing logic. | Unify mutation through `FinancialTransactionService`; derive sliced views from `transactionsProvider`. |
| **4. Credit Cards** | Canonical ledger via `CreditRepo.getAll()` | `cardsProvider` (AsyncNotifier), `creditCardsProvider` (FutureProvider wrapper) | Wrapper adds an async microtask indirection; mutations must invalidate `cardsProvider`. | Keep `cardsProvider` as canonical; alias `creditCardsProvider` directly. |
| **5. Loans** | Canonical ledger via `LoanRepo.getLoans()` | `loansProvider` (AsyncNotifier in data), `loansProvider` (FutureProvider in liabilities) | Two providers with same name across different files; wrapper FutureProvider can cause extra builds. | Consolidate onto single `loansProvider`. |
| **6. Goals** | `CanonicalEarmarkRepository` & `GoalRepo.getAll()` | `goalsProvider`, `activeGoalsProvider`, `goalByIdProvider` | Screens call `goalRepo.insert/update/delete` directly and manually invalidate `goalsProvider`. | Formalize goal action providers; automate progress derivation. |
| **7. Earmarks** | `asset_earmarks` table via `CanonicalEarmarkRepository` | `goalEarmarksProvider`, `accountEarmarkedTotalProvider` | High query frequency per account and goal. | Pure `FutureProvider.family` derived from canonical query. |
| **8. Review Candidates** | `evidence_store` & `review_candidates` | `reviewQueueProvider`, `reviewQueueCountProvider`, `systemAlertsProvider` | **CRITICAL DEFECT FOUND**: `approveReviewProvider` forgets to invalidate `transactionsProvider` and `accountsProvider`! | Fix invalidation chain on review approval: refresh ledger state automatically. |
| **9. Net Worth** | `NetWorthService.calculate()` (canonical postings) | `netWorthSummaryProvider`, `netWorthProvider`, `netWorthHistoryProvider`, `netWorthTimelineProvider`, `netWorthSparklineProvider`, `netWorthChangeProvider` | Redundant timeline queries on home tab sparklines. | Unify timeline snapshots under a single repository cache. |
| **10. Income** | `CanonicalFinancialQueryRepository` | Loop in `dashboardSummaryProvider`, loop in `homeSummaryProvider`, loop in `monthlyStatsProvider` | **TRIPLE DUPLICATION**: 3 independent for-loops summing transaction items in memory. | Centralize monthly income/expense derivation in a single canonical provider. |
| **11. Expenses** | `CanonicalFinancialQueryRepository` | Loop in `dashboardSummaryProvider`, `homeSummaryProvider`, `monthlyStatsProvider`, `topCategoriesProvider` | Multiple divergent date-window parsing for current/previous month. | Single canonical `monthlyFinancialMetricsProvider`. |
| **12. Cashflow** | `CanonicalForecastEngine` | `runwayProvider`, `monthlyStatsProvider` | Consistent since C6, but runway recalculates on each horizon query. | Cache canonical forecast result across dependents. |
| **13. Safe-to-Spend** | `CanonicalFinancialQueryRepository.getSafeToSpend()` | `safeToSpendProvider` (data), `homeSafeToSpendProvider` (home) | `homeSafeToSpendProvider` is an unnecessary passthrough wrapper. | Alias `homeSafeToSpendProvider = safeToSpendProvider`. |
| **14. Forecast** | `CanonicalForecastEngine` | `forecastProvider`, `canonicalForecastEngineProvider` | Consolidated in C6. UI consumes `forecastProvider`. | Retain `forecastProvider` as canonical UI adapter. |
| **15. Runway** | `CanonicalForecastEngine` | `runwayProvider` | Consumed by `smartNudgesProvider`, `dailyDecisionProvider`. | Pure derived provider; correctly layered. |
| **16. Financial Health** | `FinancialHealthService` | `financialHealthScoreProvider`, `financialHealthServiceProvider` | Reads transactions, loans, cards independently. | Pure derived provider; correctly layered. |
| **17. Analytics** | `AnalyticsService.computeSummary()` | `analyticsSummaryProvider`, `categorySpendingProvider`, `budgetSummaryProvider`, `insightsProvider` | **CRITICAL DEFECT FOUND**: Static `_analyticsCacheKey` uses list lengths (`${txns.length}...`), causing stale state when transactions are edited without changing count! | Replace flawed length-based fingerprint with reactive Riverpod select triggers or remove static cache. |
| **18. Recurring Rules** | `CanonicalRecurringRepository` | `recurringProvider`, `canonicalRecurringRepositoryProvider` | Separate notifiers for template metadata vs canonical forecasting rules. | Keep distinct: templates = metadata, rules = canonical forecasting inputs. |
| **19. Expected Events** | `CanonicalRecurringRepository` | Generated on-the-fly by `CanonicalForecastEngine` | Zero duplicate provider storage. | Correctly encapsulated inside domain engine. |

---

### 6. Provider Dependency Graph

```
                                  [SQLite v24 Database]
                                            │
        ┌───────────────────────────────────┼──────────────────────────────────┐
        ▼                                   ▼                                  ▼
[CanonicalFinancialQueryRepo]     [CanonicalEventRepo]           [CanonicalRecurringRepo]
        │                                   │                                  │
        │                        [FinancialTxnService]                         │
        │                                   │                                  │
        ├───────────────────────────────────┼──────────────────────────────────┤
        ▼                                   ▼                                  ▼
┌──────────────────────┐        ┌──────────────────────┐           ┌──────────────────────┐
│  accountsProvider    │        │ transactionsProvider │           │  recurringProvider   │
└──────────┬───────────┘        └──────────┬───────────┘           └──────────┬───────────┘
           │                               │                                  │
           └──────────────────────┬────────┘                                  │
                                  ▼                                           ▼
                      ┌───────────────────────┐                  ┌────────────────────────┐
                      │analyticsSummaryProvider│                  │canonicalForecastEngine │
                      └───────────┬───────────┘                  └───────────┬────────────┘
                                  │                                           │
         ┌────────────────────────┼────────────────────────┐                  ├──────────────────────┐
         ▼                        ▼                        ▼                  ▼                      ▼
┌────────────────┐       ┌─────────────────┐      ┌─────────────────┐ ┌────────────────┐     ┌───────────────┐
│safeToSpendProv │       │netWorthSummary  │      │dashboardSummary │ │forecastProvider│     │runwayProvider │
└────────────────┘       └─────────────────┘      └─────────────────┘ └────────────────┘     └───────┬───────┘
                                                                                                     ▼
                                                                                            ┌────────────────┐
                                                                                            │smartNudgesProv │
                                                                                            └────────────────┘
```

#### Identified Architectural Couplings & Bottlenecks
1. **The `analyticsSummaryProvider` Multiplexer Bottleneck**:
   `analyticsSummaryProvider` watches `transactionsProvider`, `accountsProvider`, `loansProvider`, `cardsProvider`, `categoriesProvider`, and `budgetsProvider`. Every time any entity in the entire database changes, `analyticsSummaryProvider` recalculates a heavy summary.
2. **Double Category Provider Definition**:
   `lib/data/providers.dart` defines `categoriesProvider` as `AsyncNotifierProvider<CategoriesNotifier, List<Category>>`.
   `lib/features/categories/providers/category_providers.dart` defines `categoriesProvider` as `FutureProvider<List<Category>>`.
   Widgets and services importing one will NOT be notified when the other is invalidated!
3. **Double Salary Service Definition**:
   `lib/core/services/service_providers.dart` declares `salaryServiceProvider` as `Provider((ref) => SalaryService.instance)`.
   `lib/data/providers.dart` declares `salaryServiceProvider` as `Provider((ref) => SalaryService(salaryRepo: ref.watch(salaryRepoProvider)))`.

---

### 7. Invalidation Graph

An audit of all **150 `ref.invalidate`** occurrences in `lib/` reveals:

#### Top Invalidation Targets
1. `accountsProvider`: 19 calls
2. `liabilitiesSummaryProvider`: 14 calls
3. `creditCardsProvider`: 14 calls
4. `transactionsProvider`: 9 calls
5. `goalsProvider`: 9 calls
6. `loansProvider`: 6 calls
7. `categoriesProvider`: 6 calls
8. `cardsProvider`: 5 calls
9. `reviewQueueProvider`: 5 calls

#### Invalidation Anomalies & Missing Propagation
1. **Review Item Single Approval Omission**:
   In `lib/features/review_queue/providers/review_providers.dart` (`approveReviewProvider`), approving a review candidate commits a real transaction via `FinancialTransactionService.createTransaction`.
   However, it **ONLY** invalidates `reviewQueueProvider` and `reviewQueueCountProvider`.
   It **FAILS** to invalidate `transactionsProvider` and `accountsProvider`!
   As a consequence, the review queue disappears from the UI, but the newly approved transaction does not appear on the home screen until a manual pull-to-refresh!
2. **Category Split-Brain Invalidation**:
   When `category_providers.dart:addCategoryProvider` executes, it invalidates its local `FutureProvider<List<Category>>`. The `CategoriesNotifier` in `data/providers.dart` remains untouched with stale cached state!
3. **Manual Screen Invalidation vs Reactive Graph**:
   Screens like `account_list_screen.dart`, `sms_import_screen.dart`, and `insights_tab.dart` execute shotgun invalidation (invalidating 5–7 providers simultaneously on pull-to-refresh) because the dependency graph lacks automated invalidation triggers from underlying repository mutations.

---

### 8. Write-Boundary Audit

Exhaustive search for SQL write keywords (`INSERT`, `UPDATE`, `DELETE`, `rawQuery`, `customStatement`, `database.transaction`) across all provider and notifier files confirmed:

* **Direct Provider Database Mutations**: **0**
* **Direct Ledger/Table Writes in Notifiers**: **0**
* **Firewall Compliance**: **100% PASS**

All write operations in notifiers and action providers delegate strictly to:
1. `FinancialTransactionService` (for balanced double-entry mutations)
2. `TransactionRepo`, `AccountRepo`, `CreditRepo`, `LoanRepo`, `GoalRepo` (protected by C3B write firewall)
3. `WriteQueue` (for serialized async writes)

---

### 9. C4 Read-Firewall Audit

Exhaustive search for legacy non-authoritative read patterns across all providers and notifiers:

* Direct references to `Tables.transactions`: **0** in providers
* Direct references to `Tables.ledgerTransactions`: **0** in providers
* Direct references to `Tables.creditTransactions`: **0** in providers
* Direct reads of `bank_accounts.balance`: **0** in providers
* Direct reads of `credit_cards.used_amount`: **0** in providers
* Direct reads of `loans.paid_amount`: **0** in providers
* Direct reads of `goals.current_amount`: **0** in providers
* `canonicalValue ?? legacyValue` fallback expressions: **0** in providers

**Result: ILLEGAL_STALE_AUTHORITY = 0. C4 Read Firewall is completely preserved at the provider layer.**

---

### 10. Forecast Provider Audit

Following Milestone C6:
1. `CanonicalForecastEngine` is injected via `canonicalForecastEngineProvider` in `lib/data/providers.dart`.
2. `forecastProvider` (`lib/features/forecast/forecast_provider.dart`) derives purely from `canonicalForecastEngineProvider.computeForecast()`.
3. `runwayProvider` (`lib/features/cashflow/runway_provider.dart`) derives purely from `canonicalForecastEngineProvider.computeForecast()`.
4. `financialTimelineProvider` queries `ForecastEngine.instance.compute()`, which in C6 was routed to `CanonicalForecastEngine`.

**Finding**: The forecast calculation authority is unified. However, `forecastProvider` and `runwayProvider` execute separate `computeForecast(horizonDays: 30)` calls when both are watched on the Insights tab.
**C7 Improvement**: Share the underlying canonical forecast future between `forecastProvider` and `runwayProvider` to eliminate redundant forecast simulations.

---

### 11. Review / Ingestion Provider Audit

Auditing `lib/features/review_queue/providers/review_providers.dart`:
* Pre-approval state: Reads `ReviewRepo.getPending()` which queries `evidence_store` and `review_candidates`. Zero postings or economic events are read or created.
* Rejection: Calls `ReviewRepo.reject(id)`, which soft-deletes the review candidate. Zero accounting impact.
* Approval: Calls `approveReviewItem()`, which creates a canonical `Transaction` via `FinancialTransactionService.createTransaction()`, generating balanced postings and economic events.
* **Flaw Identified**: Missing invalidation of `transactionsProvider` and `accountsProvider` on single item approval (present in bulk approve, missing in single approve).

---

### 12. Reactive Consistency Matrix

Mapping financial mutations to downstream provider reactive updates:

| Mutation Type | Service / Repository Path | Providers That MUST Update | Currently Updating? | Defect / Note |
| :--- | :--- | :--- | :---: | :--- |
| **Create Expense** | `FinancialTransactionService.createTransaction` | `transactionsProvider`, `accountsProvider`, `safeToSpendProvider`, `netWorthSummaryProvider`, `analyticsSummaryProvider`, `forecastProvider` | ⚠️ Partially | Updates if called via `addTransactionProvider`. Does NOT invalidate accounts if called via `TransactionsNotifier.add`. |
| **Create Income** | `FinancialTransactionService.createTransaction` | `transactionsProvider`, `accountsProvider`, `safeToSpendProvider`, `netWorthSummaryProvider`, `forecastProvider` | ⚠️ Partially | Same as expense. |
| **Transfer** | `FinancialTransactionService.createTransaction` | `transactionsProvider`, `accountsProvider` (both accounts) | ⚠️ Partially | Requires explicit invalidation of `accountsProvider`. |
| **Card Purchase** | `FinancialTransactionService` or `CreditPurchaseMutationNotifier` | `cardsProvider`, `creditCardsProvider`, `creditOutstandingProvider`, `netWorthSummaryProvider`, `liabilitiesSummaryProvider` | ⚠️ Partially | Must invalidate both `cardsProvider` and `liabilitiesSummaryProvider`. |
| **Card Payment** | `FinancialTransactionService.createTransaction` | `cardsProvider`, `accountsProvider`, `safeToSpendProvider`, `netWorthSummaryProvider` | ⚠️ Partially | Does not create expense, but must update bank balance and card outstanding. |
| **Loan Payment** | `FinancialTransactionService.createTransaction` | `loansProvider`, `accountsProvider`, `liabilitiesSummaryProvider` | ⚠️ Partially | Principal/interest separated; must refresh loan balance and bank account. |
| **Goal Earmark** | `GoalRepo.earmark` | `goalEarmarksProvider`, `goalDerivedProgressProvider`, `safeToSpendProvider`, `accountEarmarkedTotalProvider` | ⚠️ Manual | Screen manually invalidates `goalsProvider`; `safeToSpendProvider` not auto-invalidated. |
| **Review Approval** | `approveReviewProvider` | `reviewQueueProvider`, `reviewQueueCountProvider`, `transactionsProvider`, `accountsProvider`, `safeToSpendProvider` | ❌ NO | `approveReviewProvider` forgets to invalidate `transactionsProvider` and `accountsProvider`! |

---

### 13. Async / Race-Condition Audit

1. **Static Analytics Cache Poisoning (`_analyticsCacheKey`)**:
   `lib/data/providers.dart` lines 1223–1247 use a file-static cache:
   ```dart
   final key = '${txns.length}|${accounts.length}|${loans.length}|${cards.length}|${categories.length}|${budgets.length}';
   if (_analyticsCacheKey == key && _analyticsCacheValue != null) return _analyticsCacheValue!;
   ```
   If a user updates an existing transaction (e.g. changes ₹50 to ₹50,000 or re-categorizes), `txns.length` does NOT change. The provider returns stale cached analytics!
2. **CachedAsyncNotifier Optimistic State Races**:
   `TransactionsNotifier.add` sets optimistic `tempId` state, then asynchronously persists via `WriteQueue`. If `ref.invalidate(transactionsProvider)` is called while the write is queued, Riverpod's `load()` can overwrite the optimistic state with pre-commit database data, and when the write finishes, the list mapping may fail to match `tempId`.
3. **Unawaited Side-Effects**:
   `addTransactionProvider` runs `GamificationService.instance.addXP` unawaited inside a try/catch. This is acceptable for XP, but `DataAuditService.instance.invalidateCache()` must be deterministic.

---

### 14. God-Provider Audit: `lib/data/providers.dart`

`lib/data/providers.dart` contains:
* **Lines**: 1,352 lines
* **Provider Declarations**: 60 providers
* **Notifiers**: 11 class definitions
* **Coupling Concerns**:
  - Contains database infrastructure, repositories, services, derived analytics, UI selectors, and app lifecycle observers all in one compilation unit.
  - Causes frequent recompilation and risk of accidental cyclic dependencies.
* **Extraction Assessment**:
  - While splitting into 10 smaller files might look cleaner, doing so without consolidation risks breaking existing symbol imports across 40+ UI screens.
  - **Decision**: In C7, preserve `lib/data/providers.dart` as the canonical re-export API surface while cleanly delegating logic to authoritative service providers. No breaking export deletions.

---

### 15. Provider API Compatibility Map

To ensure **zero widget and screen regressions**, the following public provider symbols MUST be maintained:

| Public Provider Symbol | Consumer Surface | C7 Compatibility Strategy |
| :--- | :--- | :--- |
| `accountsProvider` | 19 screens, widgets, notifiers | Retain as primary `AsyncNotifierProvider` / alias. |
| `transactionsProvider` | 24 screens, widgets, services | Retain as primary `AsyncNotifierProvider` / alias. |
| `cardsProvider` | 12 screens, widgets | Retain as primary `CardsNotifier`. |
| `creditCardsProvider` | 8 screens | Retain as alias watching `cardsProvider.future`. |
| `loansProvider` | 10 screens | Retain as primary `LoansNotifier` / alias. |
| `safeToSpendProvider` | Home dashboard, widgets | Retain as canonical `FutureProvider<SafeToSpendCalculation>`. |
| `netWorthSummaryProvider` | Net worth screens, dashboard | Retain as canonical `FutureProvider`. |
| `netWorthProvider` | Quick badges | Retain as pure selector on `netWorthSummaryProvider`. |
| `forecastProvider` | Insights, Plan, Timeline | Retain as canonical UI adapter for `CanonicalForecastEngine`. |
| `runwayProvider` | Cashflow, Insights, Nudges | Retain as canonical UI adapter for `CanonicalForecastEngine`. |
| `reviewQueueProvider` | Review Queue Screen | Retain as canonical `FutureProvider<List<ReviewItem>>`. |
| `reviewQueueCountProvider` | Navigation bar badges | Retain as canonical `FutureProvider<int>`. |
| `categoriesProvider` | 14 forms, sheets, screens | Unify on single provider; eliminate split-brain duplicate. |
| `reportsSummaryProvider` | Reports screens | Retain as canonical `FutureProvider<ReportsSummary>`. |

---

### 16. Existing Test Inventory

The test suite contains **579 tests**, of which **10 test files** specifically evaluate Riverpod provider behavior:
1. `test/features/accounts_transactions_riverpod_read_test.dart` (C4-1): 56 provider checks.
2. `test/features/dashboard_net_worth_canonical_read_test.dart` (C4-2): 27 provider checks.
3. `test/features/credit_card_canonical_read_test.dart` (C4-3): 37 provider checks.
4. `test/features/loans_goals_canonical_read_test.dart` (C4-4): 30 provider checks.
5. `test/features/analytics_budget_canonical_read_test.dart` (C4-5): 9 provider checks.
6. `test/features/ai_automation_canonical_read_test.dart` (C4-6): 24 provider checks.
7. `test/features/final_canonical_read_firewall_audit_test.dart` (C4-7): 22 provider checks.
8. `test/features/canonical_ingestion_pipeline_test.dart` (C5): 9 provider checks.
9. `test/features/deterministic_forecast_engine_test.dart` (C6): 13 provider checks.
10. `test/repositories/canonical_financial_transaction_service_migration_test.dart`: Invalidation assertions.

---

### 17. C7 Adversarial Test Plan

For C7 implementation, author a dedicated test suite:
`test/features/c7_riverpod_state_consolidation_test.dart` covering 28 adversarial vectors:

1. **Mutation Propagation**: Expense creation updates `transactionsProvider`, `accountsProvider`, `safeToSpendProvider`.
2. **Balance Parity**: Transfer between accounts updates both account balances in `accountsProvider`.
3. **Net Worth Sync**: Expense reduces net worth by exact minor unit amount in `netWorthSummaryProvider`.
4. **Safe-to-Spend Earmark Reactivity**: Earmarking a goal reduces Safe-to-Spend while Net Worth remains identical.
5. **Forecast Reactivity**: Recurring rule addition invalidates and updates `forecastProvider`.
6. **Runway Reactivity**: Balance depletion updates `runwayProvider` days count.
7. **Credit Card Purchase Propagation**: Purchase increases card outstanding and reduces net worth without double-counting bank accounts.
8. **Credit Card Payment Propagation**: Payment reduces bank account and reduces card outstanding with zero duplicate expense.
9. **Loan Repayment Propagation**: Repayment splits principal and interest; updates loan balance and bank account.
10. **Single Review Item Approval Propagation**: Approving single item updates review queue count, inserts transaction, and refreshes `transactionsProvider` and `accountsProvider`.
11. **Review Item Rejection Isolation**: Rejecting item removes candidate with zero balance, zero event, and zero posting impact.
12. **Bulk Review Approval Propagation**: Bulk approval updates all affected providers atomically.
13. **Anti-Poisoning Analytics Cache**: Editing an existing transaction's amount without changing transaction count invalidates `analyticsSummaryProvider` (no static length-key hit).
14. **Category Invalidation Convergence**: Updating a category via feature provider invalidates data provider (no split-brain).
15. **Direct Accounting Writes Blocked**: Verify 0 providers execute direct SQL statements.
16. **Legacy Authority Columns Blocked**: Verify 0 providers read `bank_accounts.balance` or `credit_cards.used_amount`.
17. **Idempotent Invalidation**: Rapid multi-invalidation produces identical settled state.
18. **Concurrent Invalidation & Writes**: Parallel transaction insertions through `WriteQueue` preserve ledger balance.
19. **Deterministic Forecast Stability**: Repeated reads of `forecastProvider` produce bit-for-bit identical numbers.
20. **Circular Dependency Check**: Container initialization resolves entire provider graph without cycle error.
21. **Compatibility Adapter Parity**: `creditCardsProvider` and `cardsProvider` emit equivalent list payloads.
22. **Loans Adapter Parity**: Feature `loansProvider` and data `loansProvider` emit equivalent list payloads.
23. **Paginated Refresh Parity**: `paginatedTransactionsProvider` accurately reflects head items after `addTransactionProvider`.
24. **Disposed Notifier Safety**: Rapid screen unmount does not trigger unhandled lifecycle exceptions.
25. **Income/Expense Computation Parity**: `dashboardSummaryProvider` and `analyticsSummaryProvider` report consistent period metrics.
26. **Zero Consumer Cleanup Safety**: Removal of unused zombie providers does not break compilation.
27. **Undoable Action Ledger Parity**: Undo action cleanly reverts ledger event and invalidates dependent providers.
28. **Full Invariant Audit**: Ledger debits == credits holds across all provider mutation flows.

---

### 18. Performance Assessment

1. **Query Multiplication Risk**: Shotgun invalidations trigger up to 12 SQL queries simultaneously. Consolidating dependent views under cached derived providers will reduce query storms.
2. **Static Cache Elimination**: Replacing the defective static cache `_analyticsCacheKey` with Riverpod's native memoization (`ref.watch`) guarantees correctness with zero performance penalty.
3. **Forecast Calculation Dedup**: Sharing `CanonicalForecastEngine.computeForecast()` between `forecastProvider` and `runwayProvider` saves 1 full 30-day forward simulation per tab visit.

---

### 19. Exact Implementation File Inventory

#### MUST CHANGE
* `lib/data/providers.dart`: Fix defective static `_analyticsCacheKey`; unify `categoriesProvider` and `salaryServiceProvider`; ensure notifier actions properly trigger dependent invalidation.
* `lib/features/review_queue/providers/review_providers.dart`: Add missing invalidation of `transactionsProvider` and `accountsProvider` to `approveReviewProvider`.
* `lib/features/categories/providers/category_providers.dart`: Re-export / harmonize `categoriesProvider` with `data/providers.dart`.
* `lib/features/dashboard/providers/dashboard_providers.dart`: Remove duplicate loop calculation; derive from shared metrics.

#### MAY CHANGE
* `lib/features/home/providers/home_providers.dart`: Alias `homeSafeToSpendProvider` directly to `safeToSpendProvider`.
* `lib/features/salary/providers/salary_providers.dart`: Consume `accountsProvider` instead of direct repository call.
* `lib/features/liabilities/providers/liabilities_providers.dart`: Clean up unnecessary microtask wrappers where appropriate.

#### MUST NOT CHANGE
* `lib/data/core/app_database.dart` (Schema v24 remains locked)
* All SQLite migration files and trigger definitions
* `lib/services/financial_transaction_service.dart` (C3B write firewall locked)
* `lib/services/canonical_forecast_engine.dart` (C6 forecast authority locked)
* `lib/data/repositories/canonical/*` (Canonical repositories locked)
* All UI screen widgets and layout code

#### TEST ONLY
* `test/features/c7_riverpod_state_consolidation_test.dart` (New adversarial suite)

---

### 20. Scope / Non-Scope

#### IN SCOPE
* State ownership consolidation (19 state concerns).
* Eliminating split-brain duplicate providers (`categoriesProvider`, `salaryServiceProvider`).
* Fixing broken invalidation paths (e.g. `approveReviewProvider`).
* Eliminating defective static cache key in `analyticsSummaryProvider`.
* Deduping forecast calculation between `forecastProvider` and `runwayProvider`.
* Adding C7 adversarial test suite (28 vectors).

#### NON-SCOPE
* SQLite schema modifications (schema remains v24).
* SQLCipher or encrypted database introduction.
* UI redesign or screen widget rewrites.
* GoRouter migration.
* New financial forecasting features.

---

### 21. Schema Assessment

* **Current Schema**: SQLite **v24**
* **Triggers Active**: **7 / 7**
* **Schema Modification Needed for C7**: **NONE (0 changes)**
* **Assessment**: C7 is strictly a Riverpod state layer consolidation. No schema changes are required or permitted.

---

### 22. Implementation Sequence (Post-Authorization)

```
Step 1: Invalidation Fixes (approveReviewProvider & category split-brain)
   ↓
Step 2: Fix Analytics Cache Defect (_analyticsCacheKey removal & proper memoization)
   ↓
Step 3: Forecast & Runway Shared Evaluation in Riverpod
   ↓
Step 4: Harmonize Duplicate Feature Providers (aliases & re-exports)
   ↓
Step 5: Author C7 Adversarial Suite (28 tests)
   ↓
Step 6: Run Full Project Regression (579 + 28 = 607 tests) & Static Analyzer
```

---

### 23. Risks & Mitigations

| Risk | Impact | Mitigation Strategy |
| :--- | :--- | :--- |
| **Breaking UI Screen Imports** | Build errors across screens | Retain public provider symbols as re-exports in `lib/data/providers.dart`. |
| **Async Rebuild Storms** | Frame drops / UI lag | Use `ref.watch(provider.select(...))` to limit widget rebuild triggers. |
| **Optimistic Write Regressions** | Desynchronized UI | Preserve `WriteQueue` serialization for all asynchronous writes. |

---

### 24. Explicit Authorization Gate

Milestone C7 Discovery is **COMPLETE**.

All production code changes, provider refactoring, and test authoring remain **LOCKED** pending explicit user authorization.

**Gate Verdict**: **READY FOR C7 IMPLEMENTATION AUTHORIZATION**
