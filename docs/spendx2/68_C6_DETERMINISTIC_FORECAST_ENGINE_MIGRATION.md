# SpendX 2.0 — Milestone C6 Implementation Report
## Deterministic Forecast Engine Migration

---

### 1. Executive Summary

Milestone **C6: Deterministic Forecast Engine** successfully consolidates all disparate forecasting mechanisms across SpendX into a single canonical forecast calculation authority: `CanonicalForecastEngine` (`lib/services/canonical_forecast_engine.dart`).

Prior to Milestone C6, SpendX suffered from:
1. **The Catastrophic Salary Multiplier Defect**: In `lib/services/forecast_engine.dart`, monthly income was linearly projected via $(\text{MTD Income} / \text{Days Elapsed}) \times \text{Days in Month}$, projecting a phantom ₹15,00,000 for a user paid ₹1,50,000 on Day 3, or projecting ₹0 for a user paid on Day 28.
2. **Conflicting Forecasting Authorities**: Two separate implementations (`lib/services/forecast_engine.dart` and `lib/features/forecast/forecast_engine.dart`) with completely disjoint mathematical formulas produced contradictory numbers across screens.
3. **Debt-Blind Runway Engine**: `lib/features/cashflow/runway_engine.dart` divided liquid balance by 7-day average spend, ignoring upcoming contractual obligations (loan EMIs, credit card statement dues, rent).
4. **Float Precision Drift**: Currency arithmetic utilized standard floating-point `double` calculations rather than integer minor units.
5. **Capital One-Off Contamination**: Historical capital expenditures (e.g. ₹1,00,000 laptop) contaminated daily variable burn velocities.

Under Milestone C6:
- Exactly **one** canonical forecast engine is the sole calculation authority (`CanonicalForecastEngine`).
- Legacy `ForecastEngine` and `RunwayEngine` are compatibility adapters delegating exclusively to the canonical engine.
- Salary timing is strictly event/contractual-date based, eliminating the linear velocity multiplier defect.
- All monetary math uses signed 64-bit integer paise ([Money]) with zero float drift.
- Card purchases vs statement payments, loan principal vs interest, transfers, and earmarks adhere strictly to double-entry accounting invariants.
- Forecast execution writes **0 accounting rows** (0 events, 0 postings, 0 account mutations).
- Schema remains locked at **v24** with **7/7 SQLite triggers** active. Zero UI redesign.
- Dedicated adversarial test suite `test/features/deterministic_forecast_engine_test.dart` passes **13/13 tests**.
- Full project test suite passes **579/579 tests** (100%).
- `flutter analyze` reports **0 errors and 0 warnings**.

---

### 2. Unified Architectural Flow

```
                     AUTHORITATIVE POSTINGS & ACCOUNTS (SQLite v24)
                                          │
                                          ▼
                         CanonicalFinancialQueryRepository
                                          │
                   ┌──────────────────────┼──────────────────────┐
                   ▼                      ▼                      ▼
           Tier 1: Ground Truth   Tier 2: Commitments     Tier 3: Variable Burn
           • Liquid Assets        • Expected Events       • Trailing median/avg
           • Net Worth            • Loan EMIs (LoanRepo)    daily spend
           • Safe-to-Spend        • Card Dues (CreditRepo)• Outlier filtered
                   │                      │                      │
                   └──────────────────────┼──────────────────────┘
                                          │
                                          ▼
                               CanonicalForecastEngine
                             (Sole Calculation Authority)
                                          │
                     ┌────────────────────┴────────────────────┐
                     ▼                                         ▼
         CashflowForecast (Domain)                   Runway (Derived)
         • Daily Projection Curve                    • Days remaining
         • 30 / 60 / 90 Horizons                     • Shortfall date
         • Integer Paise ([Money])                   • Status (safe/warning/crit)
                     │                                         │
                     └────────────────────┬────────────────────┘
                                          │
                                          ▼
                     Riverpod Providers & Compatibility Adapters
                     • forecastProvider
                     • runwayProvider
                     • financialTimelineProvider
                     • services/forecast_engine.dart
                     • features/cashflow/runway_engine.dart
                                          │
                                          ▼
                                UI & Automation Layer
```

---

### 3. Tiers of Financial Truth

| Tier | Category | Authoritative Source | Accounting Semantics |
|---|---|---|---|
| **Tier 1** | Ground Truth | `CanonicalFinancialQueryRepository.getLiquidAssets()` | Authoritative liquid balance derived strictly from posted double-entry debit/credit postings in `TablesV24.postings`. |
| **Tier 2** | Deterministic Commitments | `CanonicalRecurringRepository`, `LoanRepo`, `CreditRepo` | Contractual inflows and outflows scheduled by exact due date. Loan EMIs separated into principal and interest. Card statement settlements draw liquid cash without double-counting expense. |
| **Tier 3** | Discretionary Burn | `CanonicalFinancialQueryRepository.getDailySpendStats()` | Trailing 30-day daily discretionary spend velocity, excluding transfers, card bill payments, loan principal, and capital one-offs (> ₹1,00,000). |

---

### 4. Defect Elimination Matrix

| # | Identified Defect | Legacy State | C6 Canonical Engine State |
|---|---|---|---|
| 1 | **Salary Multiplier Defect** | Multiplied MTD income by $(\text{daysInMonth} / \text{daysElapsed})$ | Event/contractual date based: inflows occur only on scheduled paydays (`TablesV24.expectedEvents`). |
| 2 | **Conflicting Forecast Engines** | Split between `services/forecast_engine.dart` and `features/forecast/forecast_engine.dart` | Unified into single `CanonicalForecastEngine`; legacy engines are lightweight compatibility adapters. |
| 3 | **Debt-Blind Runway** | Divided balance by 7-day spend; ignored upcoming loans, credit cards, rent | Aggregates active loan EMIs (`LoanRepo`), card bill dues (`CreditRepo`), and recurring rules into projected curve. |
| 4 | **Floating-Point Drift** | Dart `double` float arithmetic throughout | Pure signed 64-bit integer paise ([Money]) arithmetic across all projections and points. |
| 5 | **Capital One-Off Spikes** | Single ₹1,00,000 expense bloated daily burn rate for the rest of the month | Capital spike anomaly filtering excludes transactions exceeding ₹1,00,000 from daily velocity. |
| 6 | **Double-Counting Card Bills** | Paying card bill counted as both card expense and bank expense | Credit card purchases record expenses; card statement payments reduce card liability and bank cash (0 expense impact). |
| 7 | **Loan Principal Misallocation** | Full EMI treated as generic expense | Principal repayment reduces loan liability (net worth neutral); only interest portion debits expense. |

---

### 5. Horizon & Confidence Contract

- **Horizons**: Supports deterministic projection over 30, 60, and 90 calendar days.
- **Reproducibility**: Daily points for identical dates match exactly regardless of whether evaluated under a 30, 60, or 90-day horizon execution.
- **Confidence Scoring**:
  - `HIGH` ($0.9$): Historical lookback $\ge 30$ days with $\ge 5$ active spend days and verified commitments.
  - `MEDIUM` ($0.65$): Historical lookback $\ge 14$ days or $\ge 1$ active spend days.
  - `LOW` ($0.35$): Insufficient history (< 14 days).

---

### 6. Zero Accounting Writes Guarantee

Executing forward projections over 30, 60, or 90 days writes strictly zero rows to SQLite:
- `economic_events` table delta: **0**
- `postings` table delta: **0**
- `accounts` table delta: **0**
- `bank_accounts.balance` delta: **0**
- `credit_cards.used_amount` delta: **0**
- `loans.paid_amount` delta: **0**

---

### 7. File Modification & Creation Registry

| File | Action | Purpose |
|---|---|---|
| `lib/domain/finance/cashflow_forecast.dart` | **CREATE** | Pure domain entities: `CashflowForecast`, `ForecastDayPoint`, `ForecastConfidence`, `RecurringRule`, `ExpectedEvent`. |
| `lib/domain/finance/finance.dart` | **UPDATE** | Export canonical forecast entities. |
| `lib/domain/finance/money.dart` | **UPDATE** | Added `asRupees` convenience getter alias. |
| `lib/data/repositories/canonical/canonical_recurring_repository.dart` | **CREATE** | Canonical repository for `TablesV24.recurringRules` and `TablesV24.expectedEvents`. |
| `lib/data/repositories/canonical_repositories.dart` | **UPDATE** | Export `CanonicalRecurringRepository`. |
| `lib/data/repositories/canonical/canonical_financial_query_repository.dart` | **UPDATE** | Added `getDailySpendStats`, `getUpcomingExpectedCommitments`, `getUpcomingExpectedInflows`, `DailySpendStats`. |
| `lib/services/canonical_forecast_engine.dart` | **CREATE** | Unified deterministic forecast and runway calculation authority. |
| `lib/data/providers.dart` | **UPDATE** | Registered `canonicalRecurringRepositoryProvider` and `canonicalForecastEngineProvider`. |
| `lib/features/forecast/forecast_engine.dart` | **UPDATE** | Added `Forecast.fromCanonical(CashflowForecast)` adapter. |
| `lib/features/forecast/forecast_provider.dart` | **UPDATE** | Wired `forecastProvider` to `canonicalForecastEngineProvider`. |
| `lib/features/cashflow/runway_engine.dart` | **UPDATE** | Added `Runway.fromCanonical(CashflowForecast)` adapter. |
| `lib/features/cashflow/runway_provider.dart` | **UPDATE** | Wired `runwayProvider` to `canonicalForecastEngineProvider`. |
| `lib/services/forecast_engine.dart` | **UPDATE** | Refactored `ForecastEngine.instance.compute()` to delegate to canonical engine and query repo; eliminated MTD velocity multiplier defect. |
| `lib/features/ai/ai_data_bridge.dart` | **CLEANUP** | Removed redundant unused import. |
| `lib/screens/insights/insights_tab.dart` | **CLEANUP** | Removed redundant unused import. |
| `test/features/deterministic_forecast_engine_test.dart` | **CREATE** | Dedicated adversarial test suite covering all semantic invariants. |
| `docs/spendx2/68_C6_DETERMINISTIC_FORECAST_ENGINE_MIGRATION.md` | **CREATE** | This deliverable implementation report. |

---

### 8. Adversarial Test Conformance Matrix

File: `test/features/deterministic_forecast_engine_test.dart`

| # | Semantic Invariant | Test Assertion | Result |
|---|---|---|---|
| 1 | **Canonical Ground Truth Starting Point** | Starting balance derives strictly from canonical postings; direct SQL corruption of legacy `bank_accounts.balance` has 0 effect. | **PASS** |
| 2 | **Zero Accounting Writes Invariant** | Executing 30, 60, and 90-day projections writes 0 rows to `economic_events`, `postings`, `accounts`, and `transactions`. | **PASS** |
| 3 | **Elimination of Salary Velocity Multiplier** | Salary scheduled on Day 10 is projected as exact contractual inflow on Day 10 only (never multiplied by days in month). | **PASS** |
| 4 | **Card Purchases vs Bill Payments Non-Doubling** | Purchase generates expense; bill payment transfers liquid cash to card liability without creating second expense. | **PASS** |
| 5 | **Loan Principal vs Interest Separation** | Monthly EMI scheduled on contractual due day draws liquid cash while separating principal from interest. | **PASS** |
| 6 | **Transfers Neutrality** | Account-to-account transfer leaves total liquid starting assets and net worth completely unaffected. | **PASS** |
| 7 | **Goal Earmarks Safety** | Active goal earmark reduces Safe-to-Spend discretionary cash but leaves liquid assets and Net Worth intact. | **PASS** |
| 8 | **Integer Minor Unit Precision** | Micro-paise transactions (33p + 33p + 34p = 100p) evaluated with zero float drift. | **PASS** |
| 9 | **Deterministic Reproducibility Across Horizons** | Curves match day-by-day across 30, 60, and 90-day projection runs. | **PASS** |
| 10 | **Accurate Runway & Shortfall Flagging** | Future liability exceeding liquid balance flags exact calendar shortfall date and runway days. | **PASS** |
| 11 | **Capital One-Off Outlier Filtering** | Historical ₹2,00,000 capital purchase is excluded from daily discretionary burn calculation. | **PASS** |
| 12 | **Riverpod Provider Integration** | `forecastProvider` and `runwayProvider` seamlessly adapt canonical engine output with backward-compatible fields. | **PASS** |
| 13 | **Services ForecastEngine Adapter Delegation** | `ForecastEngine.instance.compute()` delegates to canonical query repo and engine without linear velocity bug. | **PASS** |

**Adversarial Suite Result**: **13 / 13 PASS** (~4.5s)

---

### 9. Project Regression & Static Analysis Status

```
00:31 +579: All tests passed!
```

- **Pre-C6 Baseline**: 566 tests
- **C6 Forecast Tests**: 13 tests
- **Total Project Suite**: **579 tests**
- **Pass Rate**: **579 / 579 (100%)**
- **Regressions**: **0**

Command: `flutter analyze`
```
Analyzing SpendX...
No errors found.
No warnings found.
(29 legacy infos: deprecated members / info lints in pre-existing test files)
```
- **Errors**: **0**
- **Warnings**: **0**

---

### 10. Database Schema & SQLite Trigger State

- **Database Schema**: `v24 LOCKED` (No schema changes introduced)
- **SQLite Triggers**: `7/7 ACTIVE`
  1. `trg_prevent_posted_event_mutation`
  2. `trg_prevent_posted_event_deletion`
  3. `trg_prevent_posting_insert_on_posted_event`
  4. `trg_prevent_posting_mutation_on_posted_event`
  5. `trg_prevent_posting_deletion_on_posted_event`
  6. `trg_prevent_account_deletion_with_postings`
  7. `trg_enforce_evidence_retention`

---

### 11. Hard Stop Declaration

Milestone **C6: Deterministic Forecast Engine** is fully implemented, verified, and closed.

In strict compliance with architectural constraints:
- **HARD STOP REACHED.**
- No work has commenced on Milestone C7 or any subsequent milestone.
- The system is idle and awaiting formal user review and authorization.
