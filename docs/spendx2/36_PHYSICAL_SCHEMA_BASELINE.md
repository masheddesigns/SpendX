# SpendX 2.0 — Physical SQLite Schema Baseline (v23)

**Document**: `36_PHYSICAL_SCHEMA_BASELINE.md`  
**Status**: APPROVED BASELINE SPECIFICATION  
**Scope**: Authoritative Physical Schema Inventory of Existing SQLite Database (Version 23) Prior to Migration v24  
**Source Code Baseline**: `lib/data/core/tables.dart`, `lib/data/core/app_database.dart`, `lib/data/core/schema_validator.dart`

---

## 1. Executive Summary

This document establishes the factual, physical current-state baseline of the SpendX SQLite database at schema version 23. It inventories all 40 tables, their primary keys, columns, foreign keys, mutability risks, and their explicit disposition for Migration v24.

In the current v23 database:
1. **Multiple Competing Sources of Truth**: Financial balances exist as mutable snapshot fields (`bank_accounts.balance`, `credit_cards.used_amount`, `credit_cards.outstanding`, `loans.paid_amount`, `goals.current_amount`) and simultaneously as row-based records in `transactions` and `ledger_transactions`.
2. **Floating-Point Storage**: Monetary amounts across all existing tables are stored as SQLite `REAL` (IEEE 754 floating-point), causing potential fractional-cent rounding errors over repeated addition.
3. **Soft-Delete Leaks**: Transactions use `is_deleted INTEGER DEFAULT 0`, while `ledger_transactions` has no deletion marker, creating historical desynchronization when transactions are soft-deleted.
4. **Legacy Domain Subsystems**: The `vehicles`, `fuel_logs`, and `vehicle_reminders` tables remain physically present in SQLite from v23 (preserved for safe data extraction), despite the Dart domain layer being pruned in Milestone A.

---

## 2. Master Table Inventory (40 Tables at v23)

| # | Table Name | Purpose | Primary Key | Key Columns | Foreign Keys | Mutable Financial State? | Legacy Status | v24 Migration Action |
|---|---|---|---|---|---|---|---|---|
| 1 | `bank_accounts` | Depository accounts (savings, checking, cash) | `id TEXT` | `name`, `balance REAL`, `account_type`, `is_asset`, `last4` | None | **YES** (`balance`) | Partially Legacy | Migrate to canonical `accounts` (type: `Asset:LiquidCash`); balance replaced by derived sum of postings. Freeze/archive table. |
| 2 | `transactions` | Core user-facing transactions | `id TEXT` | `amount REAL`, `type`, `category_id`, `account_id`, `date`, `external_ref`, `is_deleted` | None | **YES** (`is_deleted`, updates) | Legacy | Migrate non-deleted rows to `economic_events` + `evidence` + `postings`. Reconcile against `ledger_transactions`. Freeze as read-only. |
| 3 | `ledger_transactions` | Single-entry journal added in v17/v20/v21 | `id TEXT` | `amount REAL`, `type`, `date`, `account_id`, `credit_card_id`, `loan_id`, `category_id`, `reference_id` | None | No (Append-only journal) | Interim (v21) | Reconcile against `transactions`. Used to verify historical parity. Replaced by canonical `postings`. Freeze as read-only. |
| 4 | `categories` | Spending & income category taxonomy | `id TEXT` | `name`, `type`, `icon`, `color`, `is_preset` | None | No | Active | Map to hierarchical `accounts` (`Expense:*`, `Income:*`). Keep for UI metadata overlay. |
| 5 | `credit_cards` | Credit card accounts & limits | `id TEXT` | `name`, `credit_limit REAL`, `used_amount REAL`, `outstanding REAL`, `billing_day`, `due_day` | None | **YES** (`used_amount`, `outstanding`) | Legacy | Migrate to canonical `accounts` (type: `Liability:CreditCard`). Balance derived from postings. Retain limit & billing cycle metadata. |
| 6 | `credit_transactions` | Isolated credit card ledger | `id TEXT` | `cardId`, `amount REAL`, `date`, `category`, `type`, `status`, `statementId` | None | **YES** (`status`) | Legacy | Reconcile against `transactions` and `ledger_transactions`; transform to canonical `postings`. Freeze. |
| 7 | `credit_emis` | Credit card EMI schedules | `id TEXT` | `cardId`, `principalAmount REAL`, `interestAmount REAL`, `tenureMonths`, `monthlyInstallment REAL`, `paidMonths` | None | **YES** (`paidMonths`) | Legacy | Transform to `recurring_rules` / expected commitments. Reconcile with ledger postings. |
| 8 | `emi_installments` | Individual monthly installments for card EMIs | `id TEXT` | `emiId`, `dueDate`, `amount REAL`, `status` | None | **YES** (`status`) | Legacy | Migrate to `expected_events`. |
| 9 | `emi_plans` | Alternative EMI plan tracker | `id TEXT` | `card_id`, `name`, `principal REAL`, `interest_rate REAL`, `tenure_months`, `paid_instalments` | None | **YES** (`paid_instalments`) | Dead Duplicate | Merge with `credit_emis` or migrate to `recurring_rules`. Deprecate duplicate table. |
| 10 | `card_statements` | Monthly credit card statement snapshots | `id TEXT` | `cardId`, `startDate`, `endDate`, `statementAmount REAL`, `minimumDue REAL` | None | No | Metadata | Retain as statement audit history. Link to card `accounts`. |
| 11 | `loans` | Fixed-term loan liability accounts | `id TEXT` | `name`, `bank`, `principal_amount REAL`, `total REAL`, `interest_rate REAL`, `paid_amount REAL`, `monthly_installment REAL` | None | **YES** (`paid_amount`) | Legacy | Migrate to canonical `accounts` (type: `Liability:Loan`). Outstanding derived from postings. Retain loan terms metadata. |
| 12 | `loan_installments` | Scheduled loan repayment schedule | `id TEXT` | `loanId`, `dueDate`, `amount REAL`, `principalComponent REAL`, `interestComponent REAL`, `status` | None | **YES** (`status`) | Legacy | Migrate to `expected_events`. Link repayments to loan account. |
| 13 | `lendings` | Peer-to-peer lending / borrowing | `id TEXT` | `person_name`, `type ('lent'/'borrowed')`, `original_amount REAL`, `paid_amount REAL`, `is_settled` | None | **YES** (`paid_amount`, `is_settled`) | Legacy | Migrate to `accounts` (`Asset:Receivable:Person` or `Liability:Payable:Person`). Transform historical payments to postings. |
| 14 | `vehicles` | Physical vehicle assets (odometer, plate) | `id TEXT` | `name`, `odometer REAL`, `fuel_type` | None | **YES** (`odometer`) | Obsolete | Pruned from Dart in Milestone A. **Drop table in v24** after extracting any needed historical notes. |
| 15 | `fuel_logs` | Vehicle fuel fill-up logs | `id TEXT` | `vehicle_id`, `date`, `odometer REAL`, `quantity REAL`, `price_per_unit REAL`, `total_cost REAL` | None | No | Obsolete | Extract to `economic_events` under `Expense:Transport:Fuel` if not already in `transactions`. **Drop table in v24**. |
| 16 | `vehicle_reminders` | Odometer/date-based maintenance alerts | `id TEXT` | `vehicle_id`, `title`, `due_date`, `due_odometer REAL`, `is_active` | None | **YES** (`is_active`) | Obsolete | Pruned from Dart in Milestone A. **Drop table in v24**. |
| 17 | `budgets` | Monthly category spending limits | `id TEXT` | `category_id`, `limit_amount REAL`, `period` | None | No | Active Overlay | Retain table. Convert `limit_amount` from `REAL` to signed 64-bit integer paise. Spending progress derived purely from postings. |
| 18 | `tags` | Transaction tag taxonomy | `id TEXT` | `name`, `color` | None | No | Active | Retain table for transaction categorization overlay. |
| 19 | `recurring_templates`| Recurring transaction templates | `id TEXT` | `name`, `amount REAL`, `type`, `frequency`, `day_of_month`, `last_generated`, `next_generation`, `is_active` | None | **YES** (`last_generated`) | Legacy | Transform to canonical `recurring_rules` and `expected_events`. Convert amounts to minor units. |
| 20 | `reminders` | Generic and system-generated alerts | `id TEXT` | `title`, `type`, `date`, `amount REAL`, `linked_entity_id`, `record_status`, `source_type`, `next_trigger_at` | None | **YES** (`record_status`) | Active | Retain as notification scheduling store. Remove obsolete `due_odometer` column. |
| 21 | `companies` | Employer profile for salary tracking | `id TEXT` | `name`, `salary_credit_day`, `currency`, `employment_type`, `pay_cycle` | None | No | Active | Retain. Map to `salary_contracts` parent entity. |
| 22 | `salary_contracts` | Official employment compensation contracts | `id TEXT` | `company_id`, `base_salary REAL`, `start_date`, `default_account_id`, `is_active` | `company_id -> companies(id)` | **YES** (`is_active`) | Active | Retain. Convert `base_salary` to integer paise. Feed into forecast engine. |
| 23 | `salary_payments` | Granular salary payment records | `id TEXT` | `contract_id`, `month`, `expected_date`, `received_date`, `total_amount REAL`, `amount_received REAL`, `linked_transaction_id` | `contract_id -> salary_contracts(id)` | **YES** (`amount_received`) | Active | Reconcile linked transaction against canonical salary EconomicEvent. |
| 24 | `salary_increments` | Historical compensation increase log | `id TEXT` | `contract_id`, `amount_increase REAL`, `effective_from` | `contract_id -> salary_contracts(id)` | No | Active | Retain as contract metadata. |
| 25 | `salary` | Legacy standalone salary log | `id TEXT` | `company_name`, `salary_month`, `expected_date`, `net_salary REAL`, `amount_received REAL` | None | **YES** (`amount_received`) | Legacy Duplicate | Merge historical records into `salary_payments` or archive. |
| 26 | `salary_months` | Monthly salary expectations tracking | `id TEXT` | `company_id`, `month`, `expected_amount REAL`, `due_date`, `is_on_hold` | None | **YES** (`is_on_hold`) | Interim (v15/v19) | Migrate active rules to `expected_events`. |
| 27 | `salary_ledger` | Salary-specific payment journal | `id TEXT` | `month_id`, `amount REAL`, `type`, `paid_date`, `note` | None | No | Interim (v15) | Reconcile against `salary_payments` and ledger postings. |
| 28 | `goals` | Savings targets | `id TEXT` | `title`, `type`, `target_amount REAL`, `current_amount REAL`, `start_date`, `end_date`, `category_id`, `account_id`, `is_active` | None | **YES** (`current_amount`) | Flawed Financial Model | Retain goal definitions, but **deprecate mutable `current_amount`**. Goal funding derived purely from `asset_earmarks`. |
| 29 | `goal_logs` | Mutable goal contribution entries | `id TEXT` | `goal_id`, `amount REAL`, `note` | None | No | Legacy | Migrate to canonical `asset_earmarks` allocating specific asset account funds to goals. |
| 30 | `bank_balance_snapshots` | Historical bank balance cache | `id INTEGER` | `accountId`, `balance REAL`, `timestamp INTEGER` | None | No | Derived Cache | Historical cache only. Derive historical balances from ledger snapshots in v24. Freeze or retain as diagnostic log. |
| 31 | `net_worth_history` | Historical net worth points | `id TEXT` | `net_worth REAL`, `assets REAL`, `liabilities REAL`, `timestamp` | None | No | Derived Cache | Retain as pre-computed display cache. Point-in-time calculation derived from postings. |
| 32 | `health_score_history` | Financial discipline metrics history | `id TEXT` | `timestamp`, `total_score REAL`, `savings_rate REAL`, `debt_ratio REAL` | None | No | Analytical | Retain as historical analytical metrics. |
| 33 | `merchant_rules` | Auto-categorization rule cache | `id TEXT` | `keyword`, `category_id`, `account_id`, `usage_count`, `last_used` | None | No | Intelligence | Retain as ingestion heuristic dictionary. |
| 34 | `review_queue` | Ingested SMS/OCR candidates pending review | `id TEXT` | `raw_sms`, `parsed_json`, `confidence REAL`, `status`, `created_at` | None | **YES** (`status`) | Active Ingestion Gate | Retain and isolate from accounting truth. Review items must NOT create postings until confirmed by user. |
| 35 | `streaks` | Gamification streak tracking | `id TEXT` | `current_streak INTEGER`, `best_streak INTEGER`, `last_evaluated` | None | **YES** | Gamification | Retain as engagement state. Zero financial truth impact. |
| 36 | `challenges` | Gamification budget/savings challenges | `id TEXT` | `title`, `type`, `target_value REAL`, `current_value REAL`, `status` | None | **YES** (`current_value`) | Gamification | Retain. Progress derived from postings. |
| 37 | `achievements` | Unlocked milestone badges | `id TEXT` | `title`, `icon`, `unlocked_at` | None | No | Gamification | Retain. |
| 38 | `app_sessions` | App launch & foreground duration log | `id TEXT` | `start_time`, `end_time`, `duration_seconds`, `date` | None | No | Telemetry | Retain for local telemetry. Zero financial truth impact. |
| 39 | `insight_compliance` | User follow-through on AI insights | `id TEXT` | `insight_id`, `date`, `status` | None | No | Analytical | Retain as AI feedback loop. |
| 40 | `ledger_backfill_log` | Phase 1B/1E reconciliation audit history | `id INTEGER` | `status`, `ran_at`, `report TEXT` | None | No | Audit Log | Retain as immutable audit history of v21 pre-migration backfills. |

*(Auxiliary: `ledger_backfill_flags` stores key-value strings for reconciliation feature-flags and kill-switches).*

---

## 3. Physical Index Inventory (v23)

Existing indexes explicitly created in the physical database:
1. `idx_tx_external_ref` ON `transactions(external_ref)` — UNIQUE index created in Migration v9 to prevent duplicate external ingestion IDs.
2. `idx_merchant_keyword` ON `merchant_rules(keyword)` — Non-unique index created in Migration v8 for fast keyword lookup during SMS parsing.
3. SQLite implicit primary key indexes on `id` across all 40 tables.

**Critical Physical Finding**:
- No indexes exist on `transactions(date)`, `transactions(account_id)`, or `transactions(category_id)`.
- No indexes exist on `ledger_transactions(account_id)`, `ledger_transactions(reference_id)`, or `ledger_transactions(date)`.
- Foreign key constraints are disabled or omitted in 37 out of 40 tables (only `salary_contracts`, `salary_payments`, and `salary_increments` define `FOREIGN KEY ... REFERENCES ... ON DELETE CASCADE`).
- All other relationships (`transactions.account_id`, `credit_transactions.cardId`, `budgets.category_id`) are unconstrained strings without SQLite foreign key checks.

---

## 4. Physical Column Types & Monetary Storage Baseline

Across all 40 tables in v23, monetary values are universally typed as `REAL`:
- `bank_accounts.balance REAL`
- `transactions.amount REAL`
- `ledger_transactions.amount REAL`
- `credit_cards.credit_limit REAL`, `used_amount REAL`, `outstanding REAL`
- `loans.principal_amount REAL`, `total REAL`, `paid_amount REAL`
- `budgets.limit_amount REAL`
- `goals.target_amount REAL`, `current_amount REAL`
- `salary_contracts.base_salary REAL`

**Implication for Migration v24**:
All monetary amounts must undergo a deterministic floating-point to integer conversion:
$$\text{paise} = \text{round}(\text{amount\_real} \times 100)$$
Every target monetary column in v24 will use `INTEGER NOT NULL CHECK(amount >= 0)` (signed 64-bit integer representing minor currency units).

---

## 5. Summary of v24 Action Plan by Category

1. **Tables to DROP in v24**:
   - `vehicles`
   - `fuel_logs`
   - `vehicle_reminders`
2. **Tables to FREEZE as Read-Only Legacy Archives**:
   - `transactions` (kept read-only for historical rollback/audit)
   - `ledger_transactions` (kept read-only for audit comparison)
   - `credit_transactions` (kept read-only)
   - `salary` (legacy standalone table)
   - `emi_plans` (legacy duplicate table)
3. **Tables Transformed into Canonical Double-Entry Architecture**:
   - `bank_accounts` $\to$ `accounts` (`Asset:LiquidCash:*`)
   - `credit_cards` $\to$ `accounts` (`Liability:CreditCard:*`)
   - `loans` $\to$ `accounts` (`Liability:Loan:*`)
   - `lendings` $\to$ `accounts` (`Asset:Receivable:*` or `Liability:Payable:*`)
   - `categories` $\to$ `accounts` (`Expense:*` and `Income:*`)
   - `transactions` & `ledger_transactions` $\to$ `economic_events` + `evidence` + `postings`
   - `goal_logs` $\to$ `asset_earmarks`
4. **Tables Retained with Minor Enhancements (Integer Minor Units / Clean FKs)**:
   - `budgets`, `tags`, `companies`, `salary_contracts`, `salary_payments`, `salary_increments`, `recurring_templates` (mapped to `recurring_rules`), `reminders`, `review_queue`, `goals`, `net_worth_history`, `health_score_history`, `merchant_rules`, `streaks`, `challenges`, `achievements`, `app_sessions`, `insight_compliance`, `ledger_backfill_log`.
