# 41. Migration v24 Validation & Automated Verification Plan

## 1. Executive Summary

This document specifies the comprehensive verification protocol, automated assertion suite, and integrity audit queries for **Migration v24** (v23 -> v24). 
Every migration run—whether in automated CI migration test suites or upon the user's first launch of SpendX 2.0—must pass every verification gate defined herein before declaring migration success and setting `PRAGMA user_version = 24`.

---

## 2. Validation Philosophy & Execution Framework

Migration v24 operates under a **Zero-Tolerance Financial Invariant** policy:
1. **Atomic Execution**: All schema transformations, data copies, reconciliations, and synthetic opening balance creations execute within a single immediate SQLite transaction (`BEGIN IMMEDIATE`).
2. **Pre-Commit Verification Suite**: Before the transaction executes `COMMIT`, a deterministic suite of SQL assertion queries runs. If *any* query returns an invariant violation:
   - The transaction executes an immediate `ROLLBACK`.
   - The database remains at `user_version = 23`.
   - The verified cold pre-backup (`spendx_v23_pre_migration.db`) is kept intact.
   - An immutable error event is logged, and the app gracefully routes to a Migration Recovery UI without corrupting existing data.
3. **Post-Commit Verification**: A secondary verification checks SQLite file integrity (`PRAGMA integrity_check`) and foreign key consistency (`PRAGMA foreign_key_check`).

---

## 3. Automated SQL Invariant Test Suite

The following 10 verification queries must be executed sequentially before committing Migration v24.

### Test 1: Global Ledger Zero-Sum Balance
- **Invariant**: The sum of all Debits across the entire ledger must exactly equal the sum of all Credits. Alternatively stated: the algebraic sum of signed amounts must be zero.
- **Assertion Query**:
```sql
SELECT 
    COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END), 0) AS total_debits,
    COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END), 0) AS total_credits,
    COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE -amount_minor_units END), 0) AS net_imbalance
FROM postings;
```
- **Passing Condition**: `net_imbalance == 0` AND `total_debits == total_credits`.

---

### Test 2: Per-Event Balanced Postings (Zero Unbalanced Events)
- **Invariant**: Every single `economic_event` must have at least two postings, and the sum of its debits must exactly equal the sum of its credits.
- **Assertion Query**:
```sql
SELECT 
    event_id,
    COUNT(*) AS posting_count,
    SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END) AS event_debits,
    SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END) AS event_credits
FROM postings
GROUP BY event_id
HAVING event_debits != event_credits OR posting_count < 2;
```
- **Passing Condition**: Query returns **0 rows**.

---

### Test 3: Zero Orphan Postings
- **Invariant**: Every posting must reference a valid, existing `economic_events.id`. No foreign key references may be dangling.
- **Assertion Query**:
```sql
SELECT p.id, p.event_id
FROM postings p
LEFT JOIN economic_events e ON p.event_id = e.id
WHERE e.id IS NULL;
```
- **Passing Condition**: Query returns **0 rows**.

---

### Test 4: Zero Orphan Economic Events
- **Invariant**: Every economic event must have at least two corresponding postings. No ghost events without financial representation may exist.
- **Assertion Query**:
```sql
SELECT e.id, COUNT(p.id) AS posting_count
FROM economic_events e
LEFT JOIN postings p ON e.id = p.event_id
GROUP BY e.id
HAVING posting_count < 2;
```
- **Passing Condition**: Query returns **0 rows**.

---

### Test 5: Soft-Delete Neutrality (Zero Postings for Soft-Deleted Legacy Transactions)
- **Invariant**: Any legacy row in `transactions` with `deleted_at IS NOT NULL` or `is_deleted = 1` must NOT produce active postings in `postings`.
- **Assertion Query**:
```sql
SELECT p.id, p.event_id, t.id AS legacy_tx_id
FROM postings p
JOIN economic_events e ON p.event_id = e.id
JOIN transactions t ON e.legacy_transaction_id = t.id
WHERE t.deleted_at IS NOT NULL OR t.is_deleted = 1;
```
- **Passing Condition**: Query returns **0 rows**.

---

### Test 6: Account Balance Parity & Reconciliation Audit
- **Invariant**: For every active account, the derived ledger balance must equal the recorded legacy balance, OR the exact delta must be accounted for by an `Opening Balance Equity` adjustment posting.
- **Assertion Query**:
```sql
WITH DerivedBalances AS (
    SELECT 
        a.id AS account_id,
        a.type AS account_type,
        COALESCE(SUM(
            CASE 
                -- Asset accounts increase with DEBITS, decrease with CREDITS
                WHEN a.type = 'asset' AND p.direction = 'debit' THEN p.amount_minor_units
                WHEN a.type = 'asset' AND p.direction = 'credit' THEN -p.amount_minor_units
                -- Liability accounts increase with CREDITS, decrease with DEBITS
                WHEN a.type = 'liability' AND p.direction = 'credit' THEN p.amount_minor_units
                WHEN a.type = 'liability' AND p.direction = 'debit' THEN -p.amount_minor_units
                ELSE 0 
            END
        ), 0) AS derived_balance_minor
    FROM accounts a
    LEFT JOIN postings p ON a.id = p.account_id
    GROUP BY a.id
)
SELECT 
    la.id AS legacy_account_id,
    ROUND(la.balance * 100) AS legacy_expected_minor,
    db.derived_balance_minor,
    (db.derived_balance_minor - ROUND(la.balance * 100)) AS unaccounted_discrepancy
FROM accounts_legacy la
JOIN DerivedBalances db ON la.id = db.account_id
WHERE (db.derived_balance_minor - ROUND(la.balance * 100)) != 0;
```
- **Passing Condition**: Query returns **0 rows** (any initial discrepancy was reconciled into opening balance equity events in Step 9).

---

### Test 7: Goal Balance vs Asset Earmark Parity
- **Invariant**: The sum of active earmarks allocated to an asset account cannot exceed the derived balance of that account, and each goal's `current_amount` must equal its total active earmark allocations.
- **Assertion Query**:
```sql
-- Part A: Check Goal allocation vs Earmark total
SELECT 
    g.id AS goal_id,
    ROUND(g.current_amount * 100) AS expected_goal_minor,
    COALESCE(SUM(ae.amount_minor_units), 0) AS actual_earmarked_minor
FROM savings_goals g
LEFT JOIN asset_earmarks ae ON g.id = ae.goal_id AND ae.status = 'active'
WHERE g.status = 'active'
GROUP BY g.id
HAVING expected_goal_minor != actual_earmarked_minor;

-- Part B: Check Earmarks do not exceed Account Available Cash
SELECT 
    a.id AS account_id,
    COALESCE(SUM(
        CASE 
            WHEN p.direction = 'debit' THEN p.amount_minor_units 
            WHEN p.direction = 'credit' THEN -p.amount_minor_units 
            ELSE 0 
        END
    ), 0) AS total_cash_minor,
    COALESCE(ae_sum.earmarked_minor, 0) AS total_earmarked_minor
FROM accounts a
LEFT JOIN postings p ON a.id = p.account_id
LEFT JOIN (
    SELECT account_id, SUM(amount_minor_units) AS earmarked_minor
    FROM asset_earmarks
    WHERE status = 'active'
    GROUP BY account_id
) ae_sum ON a.id = ae_sum.account_id
WHERE a.type = 'asset'
GROUP BY a.id
HAVING total_earmarked_minor > total_cash_minor;
```
- **Passing Condition**: Both queries return **0 rows**.

---

### Test 8: Transfer Net Neutrality
- **Invariant**: All transfer events across asset accounts must result in a net change of exactly zero within the asset category.
- **Assertion Query**:
```sql
SELECT 
    e.id AS event_id,
    SUM(
        CASE 
            WHEN p.direction = 'debit' THEN p.amount_minor_units 
            WHEN p.direction = 'credit' THEN -p.amount_minor_units 
            ELSE 0 
        END
    ) AS asset_delta_minor
FROM economic_events e
JOIN postings p ON e.id = p.event_id
JOIN accounts a ON p.account_id = a.id
WHERE e.canonical_type = 'transfer' AND a.type = 'asset'
GROUP BY e.id
HAVING asset_delta_minor != 0;
```
- **Passing Condition**: Query returns **0 rows**.

---

### Test 9: Zero Credit Card Payment Expense Double-Counting
- **Invariant**: Credit card payments must be debits to Liability (reducing credit card balance) and credits to Asset (reducing bank balance). Zero postings from a credit card payment event may reference an Expense account.
- **Assertion Query**:
```sql
SELECT 
    e.id AS event_id,
    p.id AS posting_id,
    a.type AS account_type,
    a.name AS account_name
FROM economic_events e
JOIN postings p ON e.id = p.event_id
JOIN accounts a ON p.account_id = a.id
WHERE e.canonical_type = 'credit_card_payment' AND a.type = 'expense';
```
- **Passing Condition**: Query returns **0 rows**.

---

### Test 10: 30-Day SMS Body Retention Enforcement
- **Invariant**: Any row in `evidence` with `type = 'sms'` whose `received_at` is older than 30 days must have `raw_payload_encrypted IS NULL`, while preserving `body_sha256`, `extracted_amount_minor_units`, and `sender`.
- **Assertion Query**:
```sql
SELECT id, source_ref, received_at, raw_payload_encrypted
FROM evidence
WHERE source_type = 'sms'
  AND received_at < (strftime('%s', 'now') * 1000 - (30 * 86400 * 1000))
  AND raw_payload_encrypted IS NOT NULL;
```
- **Passing Condition**: Query returns **0 rows**.

---

## 4. SQLite Integrity & Foreign Key Gates

Following the SQL assertion suite:
```sql
PRAGMA foreign_key_check;
PRAGMA integrity_check;
```
- `foreign_key_check` must return **0 rows**.
- `integrity_check` must return a single row containing `'ok'`.

---

## 5. Dart Integration Test Suite Specifications

A dedicated test suite in `test/migrations/migration_v24_verification_test.dart` will be executed during automated builds:

### Test Case 1: `testColdDatabaseUpgradeFromV23`
- **Setup**: Load a fixture SQLite file containing a production v23 database with 5,000 legacy transactions, 10 bank accounts, 4 credit cards, 3 loans, 8 budgets, 6 savings goals, 12 recurring rules, and 2,000 SMS messages.
- **Action**: Run `DatabaseHelper.upgradeToV24(db)`.
- **Verification**: Run all 10 assertion queries, verify `user_version == 24`, verify table counts.

### Test Case 2: `testFloatingPointPrecisionConversion`
- **Setup**: Inject legacy transactions with fractional cents (e.g., `100.004`, `99.999`, `50.555`).
- **Action**: Run migration.
- **Verification**: Verify half-even rounding (`ROUND(amount * 100)`), verify debits == credits to the exact integer paise.

### Test Case 3: `testLegacyOrphanAndDeletedHandling`
- **Setup**: Inject transactions with `deleted_at != NULL`, transactions referencing non-existent account IDs, and transactions with unknown `type` strings.
- **Action**: Run migration.
- **Verification**: Verify soft-deleted rows generate zero postings; verify unknown types map to Review Queue / suspense account; verify orphan accounts are mapped to `System:Legacy:UnknownAccount`.

### Test Case 4: `testInterruptedMigrationRollback`
- **Setup**: Inject a simulated crash/exception during Step 11 (postings generation).
- **Action**: Catch exception; verify rollback.
- **Verification**: Confirm database schema remains v23, all legacy tables intact, zero data loss, cold backup identical.

---

## 6. Success Sign-Off Criteria

Migration v24 is certified **READY FOR EXECUTION** only when:
1. All 10 SQL assertion queries execute with 0 failures on real user fixtures.
2. `PRAGMA foreign_key_check` and `PRAGMA integrity_check` pass.
3. Cold pre-backup generation is verified before any write operation.
4. Retention policy successfully purges 30-day raw SMS payloads.
