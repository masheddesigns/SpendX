# SpendX 2.0 — Final Financial Display Contract

**Document**: `28_FINANCIAL_DISPLAY_CONTRACT.md`  
**Status**: APPROVED CANONICAL SPECIFICATION  
**Scope**: Mathematical Formulation, Truth Sources, Negative Allowance, and UI Presentation for All Financial Metrics

---

## 1. The Separation of Discretionary Cash and Safe-to-Spend

A critical flaw in standard fintech apps is hiding negative deficits behind `max(0, ...)` functions. If a user has ₹10,000 in cash and ₹15,000 in upcoming bills, telling them they have "₹0 Safe to Spend" conceals an active ₹5,000 solvency shortfall.

SpendX 2.0 formally separates this into two distinct metrics:
1. **Available Discretionary Cash (`discretionary_cash`)**: An unconstrained signed mathematical value that exposes deficits.
2. **User-Facing Safe-to-Spend (`safe_to_spend`)**: The non-negative headline figure.
3. **Cashflow Shortfall (`cashflow_shortfall`)**: The positive deficit amount shown when `discretionary_cash < 0`.

$$\text{DiscretionaryCash} = \sum_{a \in \text{LiquidAssets}} \text{Balance}(a) - \sum \text{ActiveEarmarks} - \sum \text{KnownCommitments14Days} - \sum \text{HighConfidencePendingDebits}$$

$$\text{SafeToSpend} = \max(0, \text{DiscretionaryCash})$$

$$\text{CashflowShortfall} = \max(0, -\text{DiscretionaryCash})$$

---

## 2. Complete Financial Metric Display Contracts

| Metric Identifier | Mathematical Definition | Canonical Source in DB | Pending Review Treatment | Negative Allowed? | UI Presentation Contract |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`total_liquid_cash`** | $\sum \text{Debits} - \sum \text{Credits}$ across all accounts where `type IN ('bank_checking', 'bank_savings', 'cash', 'wallet')`. | `postings` table aggregated over asset accounts. | **EXCLUDED** (Pending items are not ledger postings). | **YES** (Overdrafts allowed). | Tabular format: `₹1,42,850.00`. If negative, rendered in warning crimson. |
| **`discretionary_cash`** | $\text{TotalLiquidCash} - \text{GoalEarmarks} - \text{KnownCommitments14D} - \text{PendingDebits}$. | Derived query in `FinancialQueryService`. | **INCLUDED** (Deducts high-confidence debits). | **YES** (Ground truth deficit). | Used by internal logic, AI context, and risk alerts. |
| **`safe_to_spend`** | $\max(0, \text{DiscretionaryCash})$. | Calculated from `discretionary_cash`. | **INCLUDED**. | **NO** (Floored at 0). | Hero card: `₹84,200.00 Safe to Spend`. |
| **`cashflow_shortfall`** | $\max(0, -\text{DiscretionaryCash})$. | Calculated from `discretionary_cash`. | **INCLUDED**. | **NO** (Zero or positive). | Displayed only when $> 0$: Amber banner: `Shortfall: ₹5,000.00 by 15-Oct`. |
| **`net_worth`** | $\sum \text{LiquidAssets} + \sum \text{Receivables} - \sum \text{CardLiabilities} - \sum \text{LoanLiabilities}$. | Derived query across all balance sheet accounts in `postings`. | **EXCLUDED**. | **YES** (Net debt allowed). | Hero metric in Money tab: `Net Worth: ₹2,25,000.00`. |
| **`month_income`** | $\sum \text{Credits}$ on `Income:*` accounts for current calendar month. | `postings` table where account is Income and `effective_date` in month. | **EXCLUDED** (Draft income not recognized). | **NO** (Normal credit balance $\ge 0$). | Green numeric: `+₹1,50,000.00`. Internal transfers strictly excluded. |
| **`month_expense`** | $\sum \text{Debits} - \sum \text{Credits}$ on `Expense:*` accounts for current calendar month. | `postings` table where account is Expense and `effective_date` in month. | **EXCLUDED**. | **NO** (Net spend $\ge 0$). | Neutral text: `-₹34,500.00`. Subtracts refunds; excludes card payments. |
| **`net_cash_flow`** | $\text{MonthIncome} - \text{MonthExpense}$. | Calculated in `FinancialQueryService`. | **EXCLUDED**. | **YES** (Deficit or surplus). | Header chip: `+₹1,15,500.00 Net Cashflow`. |
| **`card_outstanding`**| $\sum \text{Credits} - \sum \text{Debits}$ on card account. | `postings` table where `account_id = card_id`. | **EXCLUDED**. | **YES** (Overpayment creates negative liability). | Bold card display: `Outstanding: ₹18,400.00`. |
| **`loan_outstanding`**| Initial Principal $-$ $\sum \text{PrincipalComponentsPaid}$. | Derived from `loan_contracts` and paid `loan_installments`. | **EXCLUDED**. | **NO** ($\ge 0$). | Loan card: `Principal Remaining: ₹4,50,000.00`. |
| **`goal_earmarks`** | $\sum \text{amount_minor_units}$ in `asset_earmarks` table. | `asset_earmarks` relational table. | **EXCLUDED**. | **NO** ($\ge 0$). | Subtitle under Liquid Cash: `(₹35,000.00 Locked in Goals)`. |
| **`budget_spent`** | $\sum \text{Debits} - \sum \text{Credits}$ on category expense accounts for current period. | `postings` table filtered by `category_id`. | **EXCLUDED**. | **NO** ($\ge 0$). | Progress bar: `₹7,500.00 / ₹10,000.00`. Excludes soft-deleted txns. |
| **`budget_remaining`**| $\max(0, \text{BudgetLimit} - \text{BudgetSpent})$. | Calculated from `budget_spent`. | **EXCLUDED**. | **NO** (Floored at 0). | Label: `₹2,500.00 Remaining`. If overspent, shows `₹1,200.00 Over limit`. |
| **`upcoming_commitments`**| $\sum \text{amount_minor_units}$ of `KNOWN` bills and EMIs due in next 14 days. | `expected_events` joined with `loan_contracts` & `recurring_rules`. | **EXCLUDED**. | **NO** ($\ge 0$). | Section summary: `Upcoming 14 Days: -₹23,600.00`. |
| **`expected_income`** | Contractual salary or confirmed incoming recurring transfers due in month. | Active `salary_contracts` + incoming `recurring_rules`. | **EXCLUDED**. | **NO** ($\ge 0$). | Forecast corridor indicator: `Expected Salary: ₹1,50,000.00`. |
| **`forecast_balance`**| Deterministic cashflow curve: $\text{CurrentCash} + \text{Inflows} - \text{Commitments} - \text{DailyBurn}$. | `CashFlowForecastEngine` calculation. | **EXCLUDED**. | **YES** (Overdraft warning triggers if $< 0$). | Chart header: `~₹92.4K Projected Month-End Balance`. |

---

## 3. Strict Rules for Derived Queries

1. **Zero Double-Counting**:
   - `month_expense` queries nominal `Expense:*` accounts only. It **never** queries asset movements or card settlements.
   - `total_liquid_cash` queries asset accounts only. It **never** subtracts future commitments or goals directly from the ledger balance.
2. **Zero Accounting Mutations in UI**:
   - Tapping "Safe to Spend" or "Net Worth" executes read-only SQLite `SELECT` queries. The UI has zero authority to alter ledger rows.
3. **Empty States & Zero Values**:
   - If an account has zero transactions, its derived balance is identically `₹0.00` (or its opening equity baseline).
   - If no budgets are defined, `budget_spent` is unconstrained and displays plain category analytics.
