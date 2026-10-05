# 52 — Milestone C3B: Repository Migration to Canonical Accounting

## Executive Summary

Milestone C3B migrates the application repository layer from legacy financial persistence to the canonical v24 double-entry architecture.
- **Slice C3B-1 (Transaction / Financial Event Path)**: Migrated `TransactionRepo` to canonical persistence with zero writes to legacy `transactions`. Status: **PASS**.
- **Slice C3B-2 (Account Repository Boundary)**: Migrated `AccountRepo` to canonical persistence with zero reads or writes to legacy `bank_accounts.balance`. Financial balances are derived strictly via `CanonicalAccountRepository.getDerivedBalance` from double-entry postings. Status: **PASS**.
- **Slice C3B-3 (Credit Card Repository Boundary)**: Migrated `CreditRepo` to canonical persistence with zero reads or writes to legacy `credit_cards.used_amount`. Card liability balances are derived strictly via `CanonicalAccountRepository.getDerivedBalance` (credits - debits) from double-entry postings. Status: **PASS**.

---

## Part 1: Milestone C3B-1 — TransactionRepo Migration

### 1. Inventory & Migration Mapping of `TransactionRepo`

`TransactionRepo` exposes 19 public methods. The table below documents their persistence mechanism before and after the C3B-1 migration.

| Method Signature | Pre-C3B Implementation | C3B-1 Canonical Implementation |
|---|---|---|
| `insert(Transaction)` | Raw write to `transactions` table | Atomically provisions missing account foreign keys, maps to `EconomicEvent` + balanced `postings` + `evidence`, persists via `CanonicalEventRepository.createAndPostEvent`. **0 writes to legacy table**. |
| `insertAll(List<Transaction>)` | Batch insert into `transactions` | Iterates and atomically creates & posts each canonical event within a database transaction. |
| `getAll({int? limit, int? offset})` | `SELECT * FROM transactions ORDER BY date DESC` | Queries canonical `economic_events` joined with `postings` and `evidence`, filters out reversal events and reversed parent events, and projects to `List<Transaction>`. |
| `getById(String id)` | `SELECT * FROM transactions WHERE id = ?` | Queries canonical event and postings by ID. Returns null if soft-deleted/reversed; otherwise projects to `Transaction`. |
| `getByDateRange(DateTime, DateTime)` | `SELECT * FROM transactions WHERE date BETWEEN ? AND ?` | Queries canonical events in range with postings and projects to `List<Transaction>`. |
| `getByAccount(String accountId)` | `SELECT * FROM transactions WHERE account_id = ?` | Queries postings where `account_id = ?`, resolves parent canonical events, and projects to `List<Transaction>`. |
| `getByCategory(String categoryId)` | `SELECT * FROM transactions WHERE category_id = ?` | Queries postings or event metadata matching category ID, projects to `List<Transaction>`. |
| `getUncategorized()` | `SELECT * FROM transactions WHERE category_id IS NULL` | Queries canonical events where category metadata is empty or null, projects to `List<Transaction>`. |
| `update(Transaction)` | `UPDATE transactions SET ... WHERE id = ?` | **Append-only correction**: Posts balanced reversal event targeting original event, then posts new replacement event. Original posted event remains immutable. |
| `updateTransaction(Transaction)` | Alias to `update(Transaction)` | Identical append-only correction behavior. |
| `delete(String id)` | Soft-delete `UPDATE transactions SET is_deleted = 1` | **Append-only soft-delete**: Generates and posts balanced reversal event with inverted postings (`PostingDirection.credit` $\leftrightarrow$ `PostingDirection.debit`). Nullifies financial impact while retaining full forensic audit trail. |
| `existsByExternalRef(String)` | `SELECT COUNT(*) FROM transactions WHERE external_ref = ?` | Queries `evidence` table by `external_reference = ?` and SHA-256 fingerprint. |
| `getExistingExternalRefs(List<String>)` | Queries `transactions` table for matching external refs | Queries canonical `evidence` table for matching external refs. |
| `getStatsForRange(DateTime, DateTime)` | Sums SQL `amount` column grouped by type in `transactions` | Aggregates canonical `postings` grouped by account type (`Asset`, `Liability`, `Expense`, `Income`). |
| `getMonthlyStats(int months)` | SQL aggregate on `transactions` table | Aggregates canonical `postings` across the trailing monthly intervals. |
| `getCategoryBreakdown(DateTime, DateTime)` | SQL sum grouped by `category_id` in `transactions` | Sums debit postings on expense accounts and category-tagged postings. |
| `getTopExpenseCategories({int limit})` | SQL top expense query on `transactions` | Queries debit postings on expense accounts ordered by sum. |
| `getAvgDailySpending(DateTime, DateTime)` | Computed from `transactions` | Computed by aggregating canonical expense postings divided by days in range. |
| `getDistinctMonths()` | `SELECT DISTINCT strftime('%Y-%m', date) FROM transactions` | Queries distinct months from `economic_events.occurred_at`. |

### 2. Canonical Transaction Adapter (`CanonicalTransactionAdapter`)

Located at: [`lib/data/repositories/canonical/canonical_transaction_adapter.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_transaction_adapter.dart)
- Manages mapping between `Transaction` entities and canonical `EconomicEvent`, `Posting`, and `Evidence`.
- Enforces strict $\sum \text{Debits} = \sum \text{Credits}$ balance and append-only reversals.

---

## Part 2: Milestone C3B-2 — AccountRepo Migration

### 1. Inventory & Migration Mapping of `AccountRepo`

`AccountRepo` exposes 17 public methods. The table below classifies and inventories every method before and after the C3B-2 migration.

| Method Signature | Classification | Pre-C3B Implementation | C3B-2 Canonical Implementation |
|---|---|---|---|
| `create(BankAccount)` | `CREATE` | Calls `insertAccount(account)` -> `INSERT INTO bank_accounts` | Delegates to `insertAccount`. Inserts into `TablesV24.accounts`. **0 writes to legacy table**. |
| `getAll()` | `READ` | Calls `getAccounts()` -> `SELECT * FROM bank_accounts` | Calls `getAccounts()`. Queries `accounts` table where `account_type = 'asset' AND is_system = 0 AND is_active = 1`. |
| `getAccounts()` | `READ` | `SELECT * FROM bank_accounts` | Queries canonical `accounts` table, derives balances dynamically from double-entry postings via `CanonicalAccountRepository.getDerivedBalance`, and projects to `List<BankAccount>`. |
| `getById(String? id)` | `LOOKUP` / `READ` | `SELECT * FROM bank_accounts WHERE id = ?` | Queries canonical `accounts` table by `id`, computes derived balance via `getDerivedBalance(id)`, and projects to `BankAccount`. |
| `insertAccount(BankAccount)` | `CREATE` | `INSERT INTO bank_accounts` with raw `balance` column | Inserts canonical `Account` row into `TablesV24.accounts`. If `balance != 0`, posts canonical `openingBalance` event balancing against `sys_equity_opening` with provenance in `opening_balance_reconciliations`. **0 writes to `bank_accounts.balance`**. |
| `updateAccount(BankAccount)` | `UPDATE` | `UPDATE bank_accounts SET ... WHERE id = ?` (mutated balance) | Updates display metadata only (`name`, `subtype`, `institution_name`, `account_number_last4`, `color_hex`, `icon_name`) in `TablesV24.accounts`. **0 writes to balance**. |
| `updateBalance(String id, double balance)` | `BALANCE` / `RECONCILIATION` | `UPDATE bank_accounts SET balance = ?` | **Canonical reconciliation**: Computes delta between target balance and current derived balance. If delta $\neq 0$, posts double-entry reconciliation event balancing against `sys_equity_opening` with provenance in `opening_balance_reconciliations`. **0 writes to `bank_accounts.balance`**. |
| `adjustBalance(String id, double delta)` | `BALANCE` | `UPDATE bank_accounts SET balance = balance + ?` | Routes through canonical reconciliation event delta against `sys_equity_opening`. **0 writes to `bank_accounts.balance`**. |
| `adjustBalances(Map<String, double>)` | `BALANCE` | Loops raw SQL update | Iteratively applies canonical reconciliation adjustments. |
| `adjustBalancesWithTxn(...)` | `BALANCE` | Batch raw SQL updates in transaction | Applies canonical reconciliation adjustments within database executor. |
| `deleteAccount(String id)` | `DELETE` | `DELETE FROM bank_accounts WHERE id = ?` | **Postings-aware deletion**: If account has historical postings, soft-archives (`is_active = 0`) in `accounts` to maintain referential integrity and immutability. If account has 0 postings, physically deletes from `accounts`. Removes transitional `bank_accounts` row if present. |
| `getCards()` | `READ` (Transitional) | `SELECT * FROM credit_cards` | Retained for transitional compatibility (C3B-3 scope). |
| `insertCard(CreditCard)` | `CREATE` (Transitional) | `INSERT INTO credit_cards` | Retained for transitional compatibility. |
| `updateCard(CreditCard)` | `UPDATE` (Transitional) | `UPDATE credit_cards` | Retained for transitional compatibility. |
| `deleteCard(String id)` | `DELETE` (Transitional) | `DELETE FROM credit_cards` | Retained for transitional compatibility. |
| `convertAccountToCard(BankAccount)` | `TRANSFER` / `UTILITY` | Transaction delete account + insert card | Inserts card into `credit_cards`, soft-archives/deletes account via `deleteAccount(account.id)`. |
| `convertCardToAccount(CreditCard)` | `TRANSFER` / `UTILITY` | Transaction delete card + insert account | Deletes card, creates canonical bank account via `insertAccount`. |

---

### 2. Canonical Account Adapter (`CanonicalAccountAdapter`)

Located at: [`lib/data/repositories/canonical/canonical_account_adapter.dart`](file:///Users/sivek/Documents/SpendX/lib/data/repositories/canonical/canonical_account_adapter.dart)

Key responsibilities:
1. **Model Projection (`toBankAccount`)**:
   - Projects canonical `accounts` row + dynamically derived [Money] balance into legacy `BankAccount` model.
   - Balance is strictly computed via `derivedBalance.toRupees` from immutable double-entry postings.
   - `bank_accounts.balance` is never read.
2. **Account Row Translation (`toAccountsRow`, `toCanonicalAccount`)**:
   - Maps metadata (`institution_name`, `account_number_last4`, `color_hex`, `icon_name`, `subtype`) to `TablesV24.accounts`.
3. **Opening Balance Records (`createOpeningBalanceRecords`)**:
   - If initial balance $> 0$: Dr Asset Account, Cr `sys_equity_opening`.
   - If initial balance $< 0$: Cr Asset Account, Dr `sys_equity_opening`.
   - Produces balanced `EconomicEvent`, 2 `postings`, `evidence`, and `OpeningBalanceReconciliation` record with provenance `manual_account_creation`.
   - If initial balance $== 0$: returns `null` (0 posting impact).
4. **Statement Reconciliation Records (`createReconciliationRecords`)**:
   - Calculates mathematical delta between target balance and current derived balance.
   - Generates balanced double-entry adjustment event targeting `sys_equity_opening`.
   - Persists provenance in `opening_balance_reconciliations` with `sms_balance_update`.

---

### 3. Financial Firewall Verification

An exhaustive audit of `AccountRepo` confirms:
- **0 Authoritative Reads from `bank_accounts.balance`**: All balance reads compute strictly from `CanonicalAccountRepository.getDerivedBalance` over `TablesV24.postings`.
- **0 Writes to `bank_accounts.balance`**: No method performs `UPDATE bank_accounts SET balance = ...`.
- **Anti-Tamper Proof**: Adversarial tests verify that modifying `bank_accounts.balance` directly in SQLite has zero effect on `AccountRepo.getById` or `getAll`.
- **Zero Dual-Writes**: All mutations are routed to `TablesV24.accounts`, `economic_events`, `postings`, `evidence`, and `opening_balance_reconciliations`.

---

### 4. Verification Evidence & Test Results

#### A. Dedicated C3B-2 Test Suite
File: [`test/repositories/canonical_account_repo_migration_test.dart`](file:///Users/sivek/Documents/SpendX/test/repositories/canonical_account_repo_migration_test.dart)
All 10 tests pass:
1. `Basic Account: Create account with 0 balance -> balance = 0, postings = 0, 0 legacy writes`: **PASS**
2. `Opening Balance: Account creation with non-zero balance produces balanced event + sys_equity_opening`: **PASS**
3. `Income: Canonical income event increases asset account derived balance`: **PASS**
4. `Expense: Canonical expense event decreases asset account derived balance`: **PASS**
5. `Transfer: Transfer between two asset accounts preserves total assets`: **PASS**
6. `Draft vs Posted: Draft contributes 0; posting changes balance exactly once`: **PASS**
7. `Immutability: SQLite triggers prevent direct UPDATE or DELETE on posted postings`: **PASS**
8. `Historical Account: Deleting account with postings soft-archives it; queryable by id`: **PASS**
9. `Legacy Firewall & Anti-Tamper: Direct writes to bank_accounts.balance do NOT alter truth`: **PASS**
10. `updateBalance & adjustBalance: Route through canonical reconciliation with provenance`: **PASS**

#### B. Full Test Suite Summary
- **Dedicated C3B-2 Suite**: **10 / 10 PASS**
- **Dedicated C3B-1 Suite**: **7 / 7 PASS**
- **Repository Suite (`test/repositories/`)**: **60 / 60 PASS**
- **Migration Suite (`test/migrations/`)**: **54 / 54 PASS**
- **Full Application Suite (`flutter test`)**: **280 / 280 PASS**
- **Static Analysis (`flutter analyze`)**: **0 errors, 0 warnings**

---

### 5. Scope Boundary Compliance

- **Riverpod providers**: Untouched (0 changes).
- **Flutter UI & widgets**: Untouched (0 changes).
- **GoRouter / navigation**: Untouched (0 changes).
- **Transitional tables**: Retained in schema; `bank_accounts` physically preserved for future migration slices.
- **Slice C3B-3**: NOT started (Hard Stop honored).

---

---

## Part 3: Milestone C3B-3 — Credit Card Repository Migration (Canonical Liability Boundary)

### 1. Inventory & Migration Mapping of `CreditRepo`

`CreditRepo` exposes exactly **29 public methods**. Each method is audited and classified into exactly one category:
- **`CANONICAL_FINANCIAL` (10 methods)**: Directly records or reverses canonical double-entry accounting truth (`economic_events`, `postings`, `evidence`, `reconciliations`).
- **`CANONICAL_METADATA` (1 method)**: Modifies canonical account display attributes in `TablesV24.accounts` without mutating accounting truth.
- **`DERIVED` (2 methods)**: Reads/queries canonical accounts and dynamically derives liability balances from immutable double-entry postings ($\sum \text{Credits} - \sum \text{Debits}$).
- **`TRANSITIONAL_COMPATIBILITY` (16 methods)**: Reads or mutates non-authoritative operational metadata tables (`credit_emis`, `emi_installments`, `card_statements`, `credit_transactions`) preserved for legacy UI compatibility.
- **`ILLEGAL` (0 methods)**: Zero methods write to legacy balance columns as authoritative financial truth.

| # | Method Signature | Exact Classification | Pre-C3B Implementation | C3B-3 Canonical Implementation |
|---|---|---|---|---|
| 1 | `getAll()` | `DERIVED` | `SELECT * FROM credit_cards` | Queries canonical `accounts` (`account_type = 'liability'`, `subtype = 'credit_card'`, `is_active = 1`). Derives balances dynamically via `CanonicalAccountRepository.getDerivedBalance` ($\text{credits} - \text{debits}$). Projects to `List<CreditCard>`. **0 reads of `used_amount`**. |
| 2 | `getCard(String id)` | `DERIVED` | `SELECT * FROM credit_cards WHERE id = ?` | Queries canonical `accounts` by `id`, derives liability balance from postings, and projects to `CreditCard`. |
| 3 | `insert(CreditCard card)` | `CANONICAL_FINANCIAL` | `INSERT INTO credit_cards` with `used_amount` | Inserts canonical liability account into `TablesV24.accounts`. If `usedAmount != 0`, posts canonical `openingBalance` event ($\text{Cr Card Liability}, \text{Dr sys_equity_opening}$) with provenance `manual_card_creation` in `opening_balance_reconciliations`. |
| 4 | `update(CreditCard card)` | `CANONICAL_METADATA` | `UPDATE credit_cards SET ...` (mutated balance) | Updates display metadata only (`name`, `institution_name`, `credit_limit_minor_units`, `billing_cycle_day`, `payment_due_day`, `color_hex`, `icon_name`) in `TablesV24.accounts`. Stale `card.usedAmount` is **strictly ignored** to prevent spurious financial reconciliations. |
| 5 | `reconcileOutstanding(...)` | `CANONICAL_FINANCIAL` | Not implemented (reconciliation conflated with `update`) | Explicit canonical reconciliation method. Computes delta against derived balance and emits balanced double-entry adjustment event targeting `sys_equity_opening` with explicit provenance. |
| 6 | `updateBalance(String, double)` | `CANONICAL_FINANCIAL` | Not implemented | Alias to `reconcileOutstanding` for API parity with `AccountRepo.updateBalance`. |
| 7 | `delete(String id)` | `CANONICAL_FINANCIAL` | `DELETE FROM credit_cards WHERE id = ?` | Postings-aware deletion: if card has historical postings, soft-archives (`is_active = 0`) in `accounts` to maintain referential integrity. If 0 postings, physically deletes from `accounts`. Removes transitional row. |
| 8 | `adjustOutstandings(Map<String, double>)` | `CANONICAL_FINANCIAL` | Raw SQL loop updating `used_amount` | Reconciles deltas by posting balanced adjustment events targeting `sys_equity_opening` with provenance `card_reconciliation_delta`. Wrapped in an **atomic SQLite transaction boundary**. |
| 9 | `adjustOutstandingsWithTxn(...)` | `CANONICAL_FINANCIAL` | Raw SQL updates in transaction | Applies canonical reconciliation adjustments within an external executor. |
| 10 | `insertTransaction(CreditTransaction tx)` | `CANONICAL_FINANCIAL` | `INSERT INTO credit_transactions` | Translates transaction into canonical double-entry event: Purchases ($\text{Dr Expense}, \text{Cr Card}$), Payments ($\text{Dr Card}, \text{Cr Bank}$), Refunds ($\text{Dr Card}, \text{Cr Contra-Expense}$). Atomically provisions missing accounts and commits event. Projects compatibility row to `credit_transactions`. |
| 11 | `insertTransactions(List<CreditTransaction>)` | `CANONICAL_FINANCIAL` | Loop raw inserts | Iteratively creates and posts canonical double-entry events. |
| 12 | `insertTransactionsWithTxn(...)` | `CANONICAL_FINANCIAL` | Batch raw inserts | Creates and posts canonical events within executor. |
| 13 | `deleteTransaction(String id)` | `CANONICAL_FINANCIAL` | `DELETE FROM credit_transactions WHERE id = ?` | Deterministic append-only reversal: fetches posted canonical event with `id`, reverses postings, posts reversal event, and deletes compatibility row. |
| 14 | `getTransactions(String cardId)` | `TRANSITIONAL_COMPATIBILITY` | `SELECT * FROM credit_transactions WHERE cardId = ?` | Reads transitional `credit_transactions` for operational query compatibility. |
| 15 | `getTransactionById(String id)` | `TRANSITIONAL_COMPATIBILITY` | `SELECT * FROM credit_transactions WHERE id = ?` | Reads transitional `credit_transactions`. |
| 16 | `updateTransactionStatus(String, String)` | `TRANSITIONAL_COMPATIBILITY` | `UPDATE credit_transactions SET status = ?` | Updates operational status (`'converted_to_emi'`, `'billed'`). **Zero posting impact**. |
| 17 | `getEmis(String cardId)` | `TRANSITIONAL_COMPATIBILITY` | `SELECT * FROM credit_emis WHERE cardId = ?` | Reads operational EMI metadata from transitional table. |
| 18 | `getEMIById(String id)` | `TRANSITIONAL_COMPATIBILITY` | `SELECT * FROM credit_emis WHERE id = ?` | Reads operational EMI metadata. |
| 19 | `insertEMI(CreditEMI emi)` | `TRANSITIONAL_COMPATIBILITY` | `INSERT INTO credit_emis` | Persists EMI metadata in transitional table. |
| 20 | `updateEMI(CreditEMI emi)` | `TRANSITIONAL_COMPATIBILITY` | `UPDATE credit_emis` | Updates EMI metadata. |
| 21 | `deleteEMI(String id)` | `TRANSITIONAL_COMPATIBILITY` | `DELETE FROM credit_emis WHERE id = ?` | Deletes EMI metadata. |
| 22 | `getInstallments(String emiId)` | `TRANSITIONAL_COMPATIBILITY` | `SELECT * FROM emi_installments WHERE emiId = ?` | Reads EMI installments from transitional table. |
| 23 | `insertInstallment(EMIInstallment)` | `TRANSITIONAL_COMPATIBILITY` | `INSERT INTO emi_installments` | Persists installment metadata. |
| 24 | `updateInstallment(EMIInstallment)` | `TRANSITIONAL_COMPATIBILITY` | `UPDATE emi_installments` | Updates installment metadata. |
| 25 | `deleteInstallment(String id)` | `TRANSITIONAL_COMPATIBILITY` | `DELETE FROM emi_installments` | Deletes installment metadata. |
| 26 | `deleteInstallments(String emiId)` | `TRANSITIONAL_COMPATIBILITY` | `DELETE FROM emi_installments WHERE emiId = ?` | Deletes installments metadata. |
| 27 | `insertStatement(CardStatement)` | `TRANSITIONAL_COMPATIBILITY` | `INSERT INTO card_statements` | Persists statement metadata. **Zero balance impact**. |
| 28 | `assignTransactionsToStatement(...)` | `TRANSITIONAL_COMPATIBILITY` | Batch update statementId | Updates operational statement association. |
| 29 | `getStatements(String cardId)` | `TRANSITIONAL_COMPATIBILITY` | `SELECT * FROM card_statements` | Reads statement metadata for card. |

---

### 2. Credit Transaction Read/Write Boundary & Identity Mapping

#### A. Persistence Call Graph
```
CreditRepo.insertTransaction(tx)
  ├── 1. Canonical Account Provisioning: CanonicalCreditAdapter.ensureAccountsExist(database, ...)
  ├── 2. Double-Entry Translation: CanonicalCreditAdapter.toEconomicEventAndPostings(tx)
  │        ├── EconomicEvent (id: tx.id, type: cardPurchase | cardPayment | refund)
  │        ├── Postings (balanced legs)
  │        └── Evidence (SHA-256 fingerprint, source: manual/system)
  ├── 3. Canonical Commit: CanonicalEventRepository.createAndPostEvent(event, postings, evidence)
  │        ├── INSERT INTO economic_events (lifecycle_status = 'draft')
  │        ├── INSERT INTO postings
  │        ├── INSERT INTO evidence
  │        └── UPDATE economic_events (lifecycle_status = 'posted') [Trigger verified]
  └── 4. Compatibility Projection: db.insert(Tables.creditTransactions, tx.toMap())
```

#### B. Proof of Compatibility Projection
- **Canonical Source Event**: The canonical source event is created at Step 3 (`TablesV24.economicEvents` and `postings`).
- **No Financial Truth in Legacy Row**: `credit_transactions` does NOT contain running balances or account totals.
- **Fields Projected**: `id`, `cardId`, `amount`, `date`, `category`, `note`, `type`, `status`, `statementId`, `categoryId`.
- **Identity Mapping**: Deterministic 1:1 identity: `EconomicEvent.id == CreditTransaction.id`.
- **Deletion Safety**: `deleteTransaction(id)` fetches canonical event by primary key `id = ?`. If found and posted, it emits a balanced reversal event (`evt_rev_${event.id}_${timestamp}`) with inverted posting legs before removing the row from `credit_transactions`.

---

### 3. `update(CreditCard)` Reconciliation Safety Analysis

- **Architectural Separation**: `update(CreditCard card)` is **strictly metadata-only**. It updates `name`, `institution_name`, `account_number_last4`, `credit_limit_minor_units`, `billing_cycle_day`, `payment_due_day`, `color_hex`, and `icon_name` in `TablesV24.accounts`.
- **Stale `usedAmount` Safety**: Any `usedAmount` value present on the incoming `CreditCard` model is completely ignored. Editing a card's name, limit, or color can **never** trigger a financial reconciliation event or alter the ledger.
- **Explicit Reconciliation Path**: Callers intending to reconcile outstanding liability against reported statement/SMS balances must call `reconcileOutstanding(cardId, targetUsedAmount)` or `adjustOutstandings(deltas)`. Both record explicit provenance and balance deltas against `sys_equity_opening`.

---

### 4. `adjustOutstandings` Atomicity Verification

`adjustOutstandings(deltas)` is wrapped in an atomic `_runInTransaction` boundary. If any entry in the adjustment map fails (e.g. invalid account ID, foreign key failure, trigger abort), the entire batch rolls back cleanly via SQLite transaction rollback, leaving:
- 0 partial postings
- 0 partial events
- 0 partial reconciliations

---

### 5. Audit of `sys_equity_opening` Usage

`sys_equity_opening` is used exclusively for:
1. **Initial Opening Balances**: When a new card is registered with non-zero used amount (`insert`).
2. **Explicit Statement/SMS Reconciliations**: When statement/SMS synchronization adjusts derived liability (`reconcileOutstanding`, `adjustOutstandings`).
Every event balancing against `sys_equity_opening` records:
- Reason memo (`'Opening balance for ...'`, `'Statement balance reconciliation'`, `'Outstanding adjustment'`)
- ISO-8601 timestamp
- Provenance (`'manual_card_creation'`, `'sms_card_balance_update'`, `'card_reconciliation_delta'`)
- Mathematical balance ($\sum \text{Debits} = \sum \text{Credits}$).

---

### 6. Compatibility Tables Audit

| Table Name | Authoritative Financial Truth? | Metadata Source? | Compatibility Projection? | Remaining Authoritative Financial Writes? |
|---|---|---|---|---|
| `credit_cards` | **NO** | YES (transitional) | YES | **NO** (used_amount writes are non-authoritative) |
| `credit_transactions` | **NO** | YES (operational) | YES | **NO** (canonical events hold truth) |
| `credit_emis` | **NO** | YES (operational) | NO (domain metadata) | **NO** |
| `emi_installments` | **NO** | YES (operational) | NO (domain metadata) | **NO** |
| `card_statements` | **NO** | YES (operational) | NO (statement dates/limits) | **NO** |

---

### 7. Verification Evidence & Test Results

#### A. Dedicated C3B-3 Test Suite
File: [`test/repositories/canonical_credit_repo_migration_test.dart`](file:///Users/sivek/Documents/SpendX/test/repositories/canonical_credit_repo_migration_test.dart)
All 23 tests pass:
1. `card_creation_zero_balance`: **PASS**
2. `card_creation_non_zero_balance`: **PASS**
3. `card_purchase_accounting`: **PASS**
4. `card_payment_accounting`: **PASS**
5. `card_refund_accounting`: **PASS**
6. `unmatched_refund_accounting`: **PASS**
7. `derived_liability_balance`: **PASS**
8. `draft_isolation`: **PASS**
9. `posted_immutability`: **PASS**
10. `historical_card_archival`: **PASS**
11. `adjust_outstandings_reconciliation`: **PASS**
12. `credit_transaction_compatibility`: **PASS**
13. `emi_metadata_isolation`: **PASS**
14. `statement_metadata`: **PASS**
15. `legacy_balance_firewall`: **PASS**
16. `cross_repo_purchase_payment`: **PASS**
17. `accounting_equation_preserved`: **PASS**
18. `idempotency`: **PASS**
19. `c3b_1_regression`: **PASS**
20. `c3b_2_regression`: **PASS**
21. `metadata_safety (stale usedAmount ignored)`: **PASS**
22. `explicit_reconciliation (reconcileOutstanding)`: **PASS**
23. `rollback_safety (atomic batch rollback)`: **PASS**

#### B. Full Test Suite Summary
- **Dedicated C3B-3 Suite**: **23 / 23 PASS**
- **Dedicated C3B-2 Suite**: **10 / 10 PASS**
- **Dedicated C3B-1 Suite**: **7 / 7 PASS**
- **Repository Suite (`test/repositories/`)**: **83 / 83 PASS**
- **Migration Suite (`test/migrations/`)**: **54 / 54 PASS**
- **Full Application Suite (`flutter test`)**: **303 / 303 PASS**
- **Static Analysis (`flutter analyze`)**: **0 errors, 0 warnings**

---

### 8. Scope Boundary Compliance

- **Riverpod providers**: Untouched (0 changes).
- **Flutter UI & widgets**: Untouched (0 changes).
- **GoRouter / navigation**: Untouched (0 changes).
- **Transitional tables**: Retained; `credit_cards`, `credit_transactions`, `credit_emis`, `emi_installments`, `card_statements` physically preserved.
- **Other repositories**: `LoanRepo`, `GoalRepo`, and `FinancialTransactionService` untouched.
- **Milestone C3B-4**: NOT started.

---

## Conclusion

```
C3B-3 CLOSURE AUDIT: PASS
C3B-3 STATUS: PASS
```


