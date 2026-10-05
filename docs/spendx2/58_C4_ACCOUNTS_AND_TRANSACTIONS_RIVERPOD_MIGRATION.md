# Milestone C4-1: Accounts & Transactions Riverpod Read Migration

## 1. Executive Summary & Objective

**Milestone C4-1** executes the first phase of the application read migration authorized under the C4 roadmap established in `docs/spendx2/57_C4_READ_INVENTORY_AND_CANONICAL_QUERY_BOUNDARY.md`.

### Core Objective
Migrate account-related and transaction-related Riverpod state management away from legacy table queries and split provider definitions, binding them exclusively to the canonical repository layer (`AccountRepo` -> `CanonicalAccountRepository`, `TransactionRepo` -> `CanonicalFinancialQueryRepository`).

### Primary Outcomes
1. **Eliminated Dual-Provider Split**: Unified `lib/features/accounts/providers/account_providers.dart` with `lib/data/providers.dart`. All screens consuming accounts now observe a single source of truth backed by canonical postings.
2. **Unified Transaction Providers**: Unified `lib/features/transactions/providers/transaction_providers.dart` with `lib/data/providers.dart`. Paginated and unpaginated transaction feeds are sourced exclusively through `TransactionRepo`'s canonical economic event query boundary.
3. **Resolved WriteQueue Async Completion**: Fixed `WriteQueue.enqueue` to return a `Completer`-backed `Future`, ensuring callers awaiting optimistic mutations wait for the serialized SQLite write to complete, eliminating asynchronous test and runtime races.
4. **Adversarial Verification**: 12/12 adversarial tests in `test/features/accounts_transactions_riverpod_read_test.dart` prove that rogue direct writes to legacy tables (`bank_accounts.balance`, `transactions`) have zero effect on state exposed by Riverpod.
5. **Zero Regressions**: 438/438 project tests passed (206 repository tests, 27 financial regression tests, 12 new adversarial tests). Static analyzer reports 0 errors and 0 warnings.

---

## 2. Pre-C4-1 Audit & Root Cause Analysis

Prior to C4-1, the codebase suffered from architectural fragmentation across Riverpod providers:

### A. Dual Account Notifier Split
Two separate, competing `accountsProvider` definitions existed:
- `lib/data/providers.dart`: Defined `accountsProvider = StateNotifierProvider<AccountsNotifier, AsyncValue<List<BankAccount>>>`, reading from `accountRepoProvider`.
- `lib/features/accounts/providers/account_providers.dart`: Defined a *duplicate* `accountsProvider = StateNotifierProvider<AccountsNotifier, AsyncValue<List<BankAccount>>>` with its own `AccountsNotifier` class.

**Consequence**: Screens importing from `lib/features/accounts/providers/account_providers.dart` (such as `AccountListScreen`, `NetWorthScreen`, `AddExpenseScreen`, `AiDataBridge`, `DashboardScreen`) did not share state or invalidation signals with operations invoking the provider defined in `lib/data/providers.dart`.

### B. Transaction Provider Split
- `lib/features/transactions/providers/transaction_providers.dart` instantiated an independent `transactionRepoProvider = Provider((ref) => TransactionRepo(ref.read(databaseHelperProvider)))`.
- `PaginatedTransactionsNotifier` queried `transactionRepo.getPaginated(...)` without coordination with `transactionsProvider` in `lib/data/providers.dart`.

### C. WriteQueue Fire-and-Forget Asynchrony
In `lib/data/core/write_queue.dart`:
```dart
Future<T> enqueue<T>(Future<T> Function() operation) {
  _queue = _queue.then((_) => operation()); // Result future ignored!
  return ...; // Returned immediately without awaiting operation
}
```
`enqueue` added work to `_queue` but did not chain the return value or await the inner Future before resolving the caller's await. This allowed caller execution to proceed before SQLite mutations actually committed to the disk journal.

---

## 3. Architecture of Migrated Riverpod Reads

```
                    UI Layer (Screens & Widgets)
                                 │
                 ┌───────────────┴───────────────┐
                 ▼                               ▼
       accountsProvider              transactionsProvider
      (app_data.accountsProvider)    (PaginatedTransactionsNotifier)
                 │                               │
                 ▼                               ▼
            AccountRepo                   TransactionRepo
                 │                               │
                 ▼                               ▼
     CanonicalAccountRepository      CanonicalFinancialQueryRepository
                 │                               │
                 └───────────────┬───────────────┘
                                 ▼
                     SQLite v24 Canonical Core
         (economic_events + postings + asset_earmarks)
```

### 3.1 Provider Unification Matrix

| Target File | Previous Implementation | Migrated C4-1 Implementation | Authority |
|---|---|---|---|
| `lib/features/accounts/providers/account_providers.dart` | Standalone `AccountsNotifier` + duplicate `accountsProvider` | Re-exports `accountRepoProvider` and `accountsProvider` from `lib/data/providers.dart`. Retains convenience filters (`totalBalanceProvider`, `activeAccountsProvider`) derived from canonical `accountsProvider`. | Canonical (`AccountRepo`) |
| `lib/features/transactions/providers/transaction_providers.dart` | Standalone `transactionRepoProvider` + uncoordinated repo instance | Re-exports `transactionRepoProvider` and `transactionsProvider` from `lib/data/providers.dart`. `PaginatedTransactionsNotifier` consumes canonical `transactionRepoProvider`. | Canonical (`TransactionRepo`) |
| `lib/data/core/write_queue.dart` | Fire-and-forget queue chain | `Completer<T>`-backed serialized queue execution guaranteeing that awaiting `enqueue` waits for database commit. | Thread-safe Serializer |

### 3.2 Canonical Read Delegation
1. **Accounts**:
   - `accountsProvider` refreshes by calling `AccountRepo.getAccounts()`.
   - `AccountRepo` reads metadata from `bank_accounts`, then invokes `CanonicalAccountRepository.getDerivedBalance(account.id)`.
   - Derived balance executes:
     $$\text{Balance} = \sum_{\text{postings}} \text{Debits} - \sum_{\text{postings}} \text{Credits}$$
     for Asset accounts.
   - Any manual or rogue SQL modification to `bank_accounts.balance` is completely ignored.
2. **Transactions**:
   - `TransactionRepo.getAll()` and `TransactionRepo.getPaginated()` execute queries joining `economic_events`, `postings`, and `evidence`.
   - Legacy `transactions` rows are never queried as authoritative records.

---

## 4. Adversarial Verification Matrix

A dedicated adversarial test suite was authored in `test/features/accounts_transactions_riverpod_read_test.dart` to verify all read invariants under attacking conditions.

| # | Test Scenario | Adversarial Action | Expected Result | Status |
|---|---|---|---|:---:|
| 1 | Baseline Canonical Account Balance | Setup account with ₹5,000 opening balance | `accountsProvider` yields ₹5,000.0 derived from canonical equity/asset postings. | **PASS** |
| 2 | Rogue `bank_accounts.balance` Modification | Execute `UPDATE bank_accounts SET balance = 999999.0` | `accountsProvider` ignores rogue cache and continues yielding ₹5,000.0. | **PASS** |
| 3 | Account Balance Updates on Economic Expense | Record ₹1,200 expense via `AccountRepo` | `accountsProvider` dynamically yields ₹3,800.0 from canonical postings. | **PASS** |
| 4 | Account Balance Updates on Economic Income | Record ₹2,500 income via `AccountRepo` | `accountsProvider` dynamically yields ₹7,500.0 from canonical postings. | **PASS** |
| 5 | Balance Reversal Isolation | Record ₹500 expense then reverse it | `accountsProvider` returns to exact pre-expense balance (₹5,000.0). | **PASS** |
| 6 | Transactions List Baseline | Insert expense through canonical repo | `transactionsProvider` contains exactly 1 transaction with correct amount and type. | **PASS** |
| 7 | Rogue Legacy `transactions` Insert Ignored | Execute `INSERT INTO transactions` directly via raw SQL | `transactionsProvider` ignores raw legacy row; count and content remain untainted. | **PASS** |
| 8 | Soft-Deleted Economic Event Ignored | Soft-delete canonical event | `transactionsProvider` excludes deleted event from read feed. | **PASS** |
| 9 | Paginated Transactions Feeds Canonical Events | Query paginated feed via `transactionRepoProvider` | Feed reflects canonical transactions; rogue SQL inserts in `transactions` are omitted. | **PASS** |
| 10 | Derived `totalBalanceProvider` Parity | Multiple accounts created | `totalBalanceProvider` reflects sum of canonical balances, immune to legacy column drift. | **PASS** |
| 11 | Unification of Duplicate Account Notifiers | Read from both `lib/data/providers.dart` and `lib/features/accounts/providers/account_providers.dart` | Both point to the exact same Riverpod instance and state. | **PASS** |
| 12 | Safe Multi-Account Transfer Read | Transfer ₹1,500 between two accounts | Account 1 reflects -₹1,500; Account 2 reflects +₹1,500; sum remains constant. | **PASS** |

**Adversarial Suite Result**: 12/12 PASS (`test/features/accounts_transactions_riverpod_read_test.dart`).

---

## 5. Project-Wide Regression & Analyzer Results

### A. Test Execution Summary

| Test Suite Scope | Test Count | Result |
|---|---|:---:|
| Dedicated C4-1 Adversarial Suite (`test/features/accounts_transactions_riverpod_read_test.dart`) | 12 | **PASS** |
| Migrated Repositories Suite (`test/repositories/`) | 206 | **PASS** |
| Financial Transaction Service & Domain Regressions | 27 | **PASS** |
| Entire SpendX Project Test Suite (`flutter test`) | **438** | **PASS (100%)** |

### B. Static Analyzer
`flutter analyze` executed across all modified files:
```
Analyzing 4 items...
No issues found! (ran in 3.5s)
```
**Static Analysis Result**: 0 errors, 0 warnings, 0 lints.

---

## 6. Milestone Boundary & Invariant Lock

- **Write Path Untouched**: No accounting write logic, repository mutations, or database triggers were altered.
- **Physical Schema Untouched**: SQLite schema remains at version 24. No tables created, modified, or dropped.
- **Transitional Tables Intact**: `transactions`, `ledger_transactions`, `bank_accounts`, `credit_cards`, `loans`, and `goals` remain physically untouched.
- **UI & Routing Preserved**: No Flutter screens, widgets, or GoRouter routes were altered.
- **Next Milestone**: **C4-2: Dashboard & Net Worth Canonical Read Migration** is strictly deferred until authorized.
