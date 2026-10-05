# SpendX 2.0 — Final Domain Contract

**Document**: `29_DOMAIN_CONTRACT.md`  
**Status**: APPROVED CANONICAL SPECIFICATION  
**Scope**: Relational Entity Definitions, Primary Keys, Foreign Keys, Immutability Contracts, and Deletion Policies  
**Foundation for**: SQLite Schema Migration v24

---

## 1. Domain Entity Specifications

### 1.1 `Account` (Balance Sheet & Nominal Nodes)
- **Table Name**: `accounts`
- **Primary Key**: `id TEXT PRIMARY KEY` (UUID v4)
- **Immutable Fields**: `id`, `type`, `created_at`
- **Mutable Fields**: `name`, `parent_id`, `status`, `color`, `icon`, `updated_at`
- **Fields**:
  - `id`: `TEXT PRIMARY KEY`
  - `parent_id`: `TEXT REFERENCES accounts(id) ON DELETE RESTRICT` (Hierarchical tree)
  - `name`: `TEXT NOT NULL`
  - `type`: `TEXT NOT NULL CHECK(type IN ('asset_checking', 'asset_savings', 'asset_cash', 'asset_wallet', 'liability_card', 'liability_loan', 'equity_opening', 'equity_adjustment', 'income', 'expense'))`
  - `currency`: `TEXT NOT NULL DEFAULT 'INR'`
  - `status`: `TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'archived', 'closed'))`
  - `created_at`: `TEXT NOT NULL`
  - `updated_at`: `TEXT NOT NULL`
- **Deletion Policy**: **RESTRICT**. Cannot be deleted if referenced by any row in `postings` or `asset_earmarks`. May only transition to `archived` or `closed`.

---

### 1.2 `EconomicEvent` (Real-World Financial Occurrences)
- **Table Name**: `economic_events`
- **Primary Key**: `id TEXT PRIMARY KEY` (UUID v4)
- **Immutable Fields**: `id`, `currency`, `event_type`, `created_at`
- **Mutable Fields**: `title`, `merchant_normalized`, `status`, `notes`, `tags`, `superseded_by_event_id`, `updated_at`
- **Fields**:
  - `id`: `TEXT PRIMARY KEY`
  - `occurrence_timestamp`: `TEXT NOT NULL` (ISO-8601 UTC)
  - `title`: `TEXT NOT NULL`
  - `merchant_normalized`: `TEXT`
  - `merchant_raw`: `TEXT`
  - `event_type`: `TEXT NOT NULL CHECK(event_type IN ('expense', 'income', 'transfer', 'card_payment', 'refund', 'loan_disbursement', 'loan_payment', 'adjustment', 'opening_balance'))`
  - `status`: `TEXT NOT NULL DEFAULT 'posted' CHECK(status IN ('draft', 'posted', 'corrected', 'reversed'))`
  - `currency`: `TEXT NOT NULL DEFAULT 'INR'`
  - `notes`: `TEXT`
  - `tags`: `TEXT` (JSON Array of strings: `["vacation", "tax"]`)
  - `superseded_by_event_id`: `TEXT REFERENCES economic_events(id) ON DELETE SET NULL`
  - `created_at`: `TEXT NOT NULL`
  - `updated_at`: `TEXT NOT NULL`
- **Deletion Policy**: **TOMBSTONE ONLY**. Deleting transitions `status = 'reversed'` and emits balancing reversal postings. Row is never dropped.

---

### 1.3 `Posting` (Atomic Double-Entry Ledger Legs)
- **Table Name**: `postings`
- **Primary Key**: `id TEXT PRIMARY KEY` (UUID v4)
- **Immutable Fields**: **ALL FIELDS ARE STRICTLY IMMUTABLE**
- **Mutable Fields**: **NONE (Append-Only)**
- **Fields**:
  - `id`: `TEXT PRIMARY KEY`
  - `event_id`: `TEXT NOT NULL REFERENCES economic_events(id) ON DELETE RESTRICT`
  - `account_id`: `TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT`
  - `direction`: `TEXT NOT NULL CHECK(direction IN ('debit', 'credit'))`
  - `amount_minor_units`: `INTEGER NOT NULL CHECK(amount_minor_units > 0)` (Absolute integer paise/cents)
  - `currency`: `TEXT NOT NULL DEFAULT 'INR'`
  - `effective_date`: `TEXT NOT NULL` (ISO-8601 UTC)
  - `sequence_number`: `INTEGER NOT NULL DEFAULT 1`
  - `memo`: `TEXT`
  - `created_at`: `TEXT NOT NULL`
- **Uniqueness**: `UNIQUE(event_id, sequence_number)`
- **Deletion Policy**: **PROHIBITED**. SQLite trigger will abort any `DELETE` or `UPDATE` on this table.

---

### 1.4 `Evidence` (Raw Ingestion Proofs)
- **Table Name**: `evidence`
- **Primary Key**: `id TEXT PRIMARY KEY` (UUID v4)
- **Immutable Fields**: `id`, `source_type`, `raw_payload`, `created_at`
- **Mutable Fields**: `event_id`, `confidence`, `updated_at`
- **Fields**:
  - `id`: `TEXT PRIMARY KEY`
  - `event_id`: `TEXT REFERENCES economic_events(id) ON DELETE SET NULL` (Nullable if unlinked draft)
  - `source_type`: `TEXT NOT NULL CHECK(source_type IN ('sms', 'ocr', 'manual', 'share_intent', 'csv_import', 'pdf_statement'))`
  - `raw_payload`: `TEXT NOT NULL` (Raw SMS body, CSV line, or OCR parsed text)
  - `external_reference`: `TEXT` (Bank UTR number, check number, or UPI ID)
  - `extracted_amount`: `INTEGER` (Paise)
  - `extracted_timestamp`: `TEXT`
  - `extracted_merchant`: `TEXT`
  - `confidence`: `REAL NOT NULL DEFAULT 1.0` (0.0 to 1.0)
  - `media_uri`: `TEXT` (Local receipt image path)
  - `created_at`: `TEXT NOT NULL`
  - `updated_at`: `TEXT NOT NULL`
- **Indices**: `CREATE INDEX idx_evidence_ref ON evidence(external_reference) WHERE external_reference IS NOT NULL`

---

### 1.5 `AssetEarmark` (Goal Cash Allocations)
- **Table Name**: `asset_earmarks`
- **Primary Key**: `id TEXT PRIMARY KEY` (UUID v4)
- **Immutable Fields**: `id`, `created_at`
- **Mutable Fields**: `amount_minor_units`, `updated_at`
- **Fields**:
  - `id`: `TEXT PRIMARY KEY`
  - `goal_id`: `TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE`
  - `account_id`: `TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT`
  - `amount_minor_units`: `INTEGER NOT NULL CHECK(amount_minor_units >= 0)`
  - `created_at`: `TEXT NOT NULL`
  - `updated_at`: `TEXT NOT NULL`
- **Uniqueness**: `UNIQUE(goal_id, account_id)`
- **Critical Constraint**: An earmark does not create money. It is an unspent asset reservation subtracted during Safe-to-Spend queries.

---

### 1.6 `Goal` (Savings Targets)
- **Table Name**: `goals`
- **Primary Key**: `id TEXT PRIMARY KEY` (UUID v4)
- **Immutable Fields**: `id`, `created_at`
- **Mutable Fields**: `title`, `target_amount_minor_units`, `deadline`, `status`, `updated_at`
- **Fields**:
  - `id`: `TEXT PRIMARY KEY`
  - `title`: `TEXT NOT NULL`
  - `target_amount_minor_units`: `INTEGER NOT NULL`
  - `deadline`: `TEXT` (ISO-8601 Date)
  - `status`: `TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'achieved', 'abandoned'))`
  - `created_at`: `TEXT NOT NULL`
  - `updated_at`: `TEXT NOT NULL`

---

### 1.7 `Budget` (Category Spending Envelopes)
- **Table Name**: `budgets`
- **Primary Key**: `id TEXT PRIMARY KEY` (UUID v4)
- **Fields**:
  - `id`: `TEXT PRIMARY KEY`
  - `category_id`: `TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE`
  - `limit_minor_units`: `INTEGER NOT NULL CHECK(limit_minor_units > 0)`
  - `period`: `TEXT NOT NULL DEFAULT 'monthly' CHECK(period IN ('monthly', 'weekly', 'yearly'))`
  - `created_at`: `TEXT NOT NULL`
  - `updated_at`: `TEXT NOT NULL`
- **Uniqueness**: `UNIQUE(category_id, period)`

---

### 1.8 `SalaryContract` (Contractual Income Expectations)
- **Table Name**: `salary_contracts`
- **Primary Key**: `id TEXT PRIMARY KEY` (UUID v4)
- **Fields**:
  - `id`: `TEXT PRIMARY KEY`
  - `employer_name`: `TEXT NOT NULL`
  - `base_amount_minor_units`: `INTEGER NOT NULL`
  - `expected_pay_day`: `INTEGER NOT NULL CHECK(expected_pay_day BETWEEN 1 AND 31)`
  - `destination_account_id`: `TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT`
  - `is_active`: `INTEGER NOT NULL DEFAULT 1`
  - `created_at`: `TEXT NOT NULL`
  - `updated_at`: `TEXT NOT NULL`

---

### 1.9 `RecurringRule` & `ExpectedEvent`
- **`recurring_rules`**:
  - `id TEXT PRIMARY KEY`, `title TEXT NOT NULL`, `amount_minor_units INTEGER NOT NULL`, `category_id TEXT REFERENCES accounts(id)`, `account_id TEXT REFERENCES accounts(id)`, `cadence TEXT NOT NULL`, `day_of_month INTEGER`, `next_due_date TEXT NOT NULL`, `is_active INTEGER DEFAULT 1`.
- **`expected_events`**:
  - `id TEXT PRIMARY KEY`, `rule_id TEXT REFERENCES recurring_rules(id) ON DELETE CASCADE`, `due_date TEXT NOT NULL`, `amount_minor_units INTEGER NOT NULL`, `status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'fulfilled', 'overdue', 'dismissed'))`, `fulfilled_event_id TEXT REFERENCES economic_events(id)`, `created_at TEXT NOT NULL`.
