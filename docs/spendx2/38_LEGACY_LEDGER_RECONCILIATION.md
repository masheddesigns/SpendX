# SpendX 2.0 — Legacy Ledger Reconciliation & Contradiction Resolution

**Document**: `38_LEGACY_LEDGER_RECONCILIATION.md`  
**Status**: APPROVED CANONICAL SPECIFICATION  
**Scope**: Reconciliation Architecture Between `transactions`, `ledger_transactions`, and `bank_accounts.balance`  
**Cross-References**: `15_LEGACY_MIGRATION_STRATEGY.md`, `30_FINAL_INVARIANT_LOCK.md`, `36_PHYSICAL_SCHEMA_BASELINE.md`

---

## 1. Physical Forensic Analysis of Competing Historical Sources

In SpendX v23, financial records exist in three separate physical locations with divergent lifecycles:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. `bank_accounts.balance` (Mutable Cache Field)             │
│    - Historically edited directly by screens & imports      │
│    - Represents what the user/bank app currently displays   │
└─────────────────────────────────────────────────────────────┘
                               ▲
            Contradiction Risk │ Parity Checks
                               ▼
┌──────────────────────────────────────┐  Reference Links  ┌──────────────────────────────────────┐
│ 2. `transactions`                    │ ◄───────────────► │ 3. `ledger_transactions`             │
│    - Present since Schema v1         │                   │    - Introduced in Schema v17/v20/v21│
│    - User-editable, categorized      │                   │    - Single-entry cash journal       │
│    - Supports `is_deleted = 1`       │                   │    - No deletion markers             │
│    - Primary source for UI display   │                   │    - Created by v21 backfill service │
└──────────────────────────────────────┘                   └──────────────────────────────────────┘
```

---

## 2. Answers to the Six Architectural Ledger Questions

### 1. Can legacy ledger rows be losslessly mapped to new postings?
**Partially**. While `ledger_transactions` contains `account_id`, `amount`, and `type`, it is a **single-entry** journal (one leg only). It does not store the balancing opposite leg (e.g., an expense row records `account_id = 'A'` and `amount = 500`, but omits the `Expense:Category` credit leg). To become canonical double-entry postings, the opposite leg must be synthesized using `category_id` or transaction metadata.

### 2. Do they represent the same economic reality as `transactions`?
**Yes, but with historical drift**. For transactions created after Schema v21, both tables record the same economic reality. However, for transactions created prior to v21, `transactions` contains rich notes, tags, and merchant details, whereas `ledger_transactions` may only contain synthetic or backfilled records.

### 3. Do they contain duplicated financial facts?
**Yes**. Storing `transactions` and `ledger_transactions` concurrently duplicates financial facts (amount, date, account, type) across two parallel tables without foreign-key enforcement or transactional constraints prior to Phase 1E.

### 4. Which source is authoritative for migration?
**Dual-Source Reconciled Authority**:
- **Economic Event Identity & Categorization**: `transactions` is authoritative for user description, tags, external reference (UTR), category assignment, and soft-delete status.
- **Cash Movement & Journal Integrity**: `ledger_transactions` is authoritative for journal sequencing, opening balances created in v21, and financial side-effects (such as card payments and loan disbursements).
- **Opening Balances**: `bank_accounts.balance` is authoritative as the target ground-truth balance that the sum of canonical postings must match.

### 5. Should legacy ledger rows be migrated, reconciled, or ignored?
**Reconciled & Transformed**:
- Legacy ledger rows that match active `transactions` (`reference_id = transactions.id`) are paired with their parent transaction to create a single canonical `EconomicEvent` with balanced double-entry `postings`.
- Synthetic ledger rows (such as `migration-opening-balance-*`) migrate directly into canonical `Equity:OpeningBalance` events.
- Unmatched or orphaned ledger rows undergo contradiction evaluation (Section 3).
- Both legacy tables are then **frozen as read-only archives**; neither table receives live writes in SpendX 2.0.

### 6. How are contradictions detected and resolved?
Contradictions are detected by joining `transactions` and `ledger_transactions` on `reference_id` and comparing amount, account, and lifecycle status.

---

## 3. Contradiction Scenarios & Resolution Rules

### Scenario 1: Row Exists in `transactions`, Missing in `ledger_transactions`
- **Root Cause**: The transaction was created before Schema v21, or was created by an unmigrated code path that bypassed `LedgerRepo`.
- **Detection**:
  ```sql
  SELECT t.* FROM transactions t
  LEFT JOIN ledger_transactions l ON l.reference_id = t.id
  WHERE l.id IS NULL AND t.is_deleted = 0;
  ```
- **Resolution**:
  - The transaction is valid economic history.
  - A canonical `EconomicEvent` is generated from `transactions`.
  - Balanced `postings` are synthesized (e.g. Debit `Expense:<Category>`, Credit `Asset:<Account>`).
  - The amount is added to the account's historical movement.

### Scenario 2: Row Exists in `ledger_transactions`, Missing in `transactions`
- **Root Cause**:
  1. Legitimate opening balance record (`type = 'opening_balance'`).
  2. Loan or credit card side-effect journaled directly by `LoanService` or `CreditCardService`.
  3. Orphaned ledger row whose parent transaction was hard-deleted in an older app version.
- **Detection**:
  ```sql
  SELECT l.* FROM ledger_transactions l
  LEFT JOIN transactions t ON l.reference_id = t.id
  WHERE t.id IS NULL;
  ```
- **Resolution**:
  - If `l.type == 'opening_balance'`: Migrates to canonical `EconomicEvent` (`event_type: 'opening_balance'`).
  - If `l.loan_id IS NOT NULL` or `l.credit_card_id IS NOT NULL`: Linked to the corresponding Loan or Credit Card account as a liability posting.
  - If unlinked orphan with unknown reference: Flagged in `migration_exceptions`. If total account parity holds, absorbed into `Equity:OpeningBalance:HistoricalResidual`.

### Scenario 3: Discrepancy in Amount (`transactions.amount != ledger_transactions.amount`)
- **Root Cause**: The user edited the transaction amount on a legacy edit screen that updated `transactions.amount` but failed to update `ledger_transactions.amount`.
- **Detection**:
  ```sql
  SELECT t.id, t.amount AS tx_amount, l.amount AS ledger_amount
  FROM transactions t
  JOIN ledger_transactions l ON l.reference_id = t.id
  WHERE ABS(t.amount - l.amount) > 0.009 AND t.is_deleted = 0;
  ```
- **Resolution**:
  - `transactions.amount` represents the user's explicit edited intent.
  - The canonical `EconomicEvent` takes `round(t.amount * 100)` paise.
  - Postings are created for `t.amount`.
  - The delta is logged to `migration_audit_trail`.

### Scenario 4: Soft-Deleted in `transactions` (`is_deleted = 1`), But Present in `ledger_transactions`
- **Root Cause**: `transactions` supports soft deletion via `is_deleted = 1`. In SpendX 1.0, soft-deleting a transaction never deleted or marked the corresponding `ledger_transactions` row.
- **Detection**:
  ```sql
  SELECT t.id, l.id AS ledger_id, t.amount
  FROM transactions t
  JOIN ledger_transactions l ON l.reference_id = t.id
  WHERE t.is_deleted = 1;
  ```
- **Resolution**:
  - The user's explicit intent was **deletion**.
  - The `EconomicEvent` is created with `lifecycle_status = 'deleted'`.
  - **Zero active postings are created in the canonical ledger**.
  - The phantom cash deduction in `ledger_transactions` is purged, correcting historical cash balances.

### Scenario 5: Account ID Mismatch (`transactions.account_id != ledger_transactions.account_id`)
- **Root Cause**: Transaction was reassigned to another bank account without updating the ledger journal.
- **Detection**:
  ```sql
  SELECT t.id, t.account_id AS tx_acc, l.account_id AS ledger_acc
  FROM transactions t
  JOIN ledger_transactions l ON l.reference_id = t.id
  WHERE t.account_id != l.account_id AND t.is_deleted = 0;
  ```
- **Resolution**:
  - `transactions.account_id` represents the user's latest edited intent.
  - Canonical postings debit/credit the account specified by `transactions.account_id`.

---

## 4. Reconciliation Verification Query

Prior to committing Migration v24, the migration engine executes this verification assert across all bank accounts:

$$\Delta(\text{Account}) = \text{LegacyStoredBalance} - \left( \text{OpeningEquityBalance} + \sum \text{CanonicalPostings} \right)$$

$$\forall \text{Account}, \quad |\Delta(\text{Account})| = 0 \text{ paise}$$

If $|\Delta(\text{Account})| > 0$, Migration v24 **aborts and rolls back completely** unless the user has explicitly authorized an equity absorption exception via `ledger_backfill_flags`.
