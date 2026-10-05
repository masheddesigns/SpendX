# 47. Milestone C1 — Canonical Financial Domain Implementation Notes

## 1. Executive Summary

This document records the architectural audit, model mapping, and precision design decisions for **Milestone C1 (Domain Model Implementation & Precision Gate C1.1)** of SpendX 2.0.
The canonical domain model has been established in pure Dart under [`lib/domain/finance/`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/), completely decoupled from SQLite, Flutter UI, Riverpod state management, and platform plugins.

---

## 2. Audit of Existing Conflicting Models

During the C1 discovery phase, we inspected all legacy models under `lib/models/` and identified fundamental architectural conflicts:

| Legacy Model | Location | Primary Invalidation / Conflict | Resolution in C1 Domain Layer |
| :--- | :--- | :--- | :--- |
| **`BankAccount`** | `lib/models/bank_account.dart` | Stores `double balance` as a mutable field on the model. Uses strings for account types. No double-entry identity. | Replaced in domain by [`Account`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/account.dart) with [`AccountType`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/account_type.dart). **Zero mutable balance field**. Balance is strictly derived from postings. |
| **`Transaction`** | `lib/models/transaction.dart` | Single-entry flat record with `double amount`. Conflates income/expense category with asset account. Soft delete via `isDeleted` flag. | Replaced by [`EconomicEvent`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/economic_event.dart) and atomic [`Posting`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/posting.dart) legs. |
| **`LedgerTransaction`** | `lib/models/ledger_transaction.dart` | Flat table with `double amount` and nullable account/card/loan foreign keys. Not double-entry (no debit/credit legs). | Superseded by canonical [`Posting`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/posting.dart) rows attached to an [`EconomicEvent`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/economic_event.dart). |
| **`ReviewItem`** | `lib/models/review_item.dart` | Directly embedded `ParsedTransaction` with `double amount` and string status. | Replaced by [`ReviewCandidate`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/review_candidate.dart), explicitly isolating unconfirmed ingestion proposals from accounting truth. |
| **`Money`** | *(None existed)* | Monetary amounts were scattered as raw `double` throughout the entire codebase, vulnerable to binary floating-point drift. | Established canonical [`Money`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/money.dart) representing signed 64-bit integer paise. |

---

## 3. Canonical Domain Types & Precision Locks

All types reside in `lib/domain/finance/` and are exported via `finance.dart`:

### 3.1 [`Money`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/money.dart) Precision Contract
- **Signed 64-bit Integer Minor Units**: Stores exact integer paise (`minorUnits`).
- **Canonical Rounding Policy**: **Round Half Away From Zero** (`(rupees * 100.0).round()` in Dart, matching SQLite native `ROUND(amount * 100.0)`).
  - Halfway cases round away from zero: `1.005` $\rightarrow$ `101` paise, `-1.005` $\rightarrow$ `-101` paise.
  - **No False Recovery Claims**: This policy provides deterministic conversion of the stored legacy numeric value. It does **not** claim to reconstruct lost decimal intent already degraded by legacy `REAL` binary storage.
- **Economic Safety Cap vs. SQLite Physical Limit**:
  - *SQLite 64-bit Limit*: Signed 64-bit integer ($-2^{63}$ to $2^{63}-1 \approx \pm 9.22 \times 10^{18}$ paise).
  - *SpendX Economic Safety Cap*: $\pm 10^{14}$ paise ($\pm ₹1,000,000,000,000$, $\pm ₹1$ lakh crore).
  - *Rationale*: Individual consumer transactions never approach $₹1$ lakh crore. Setting the cap at $10^{14}$ paise guarantees that summing up to 90,000 transactions or multiplying by calendar projections mathematically cannot overflow the physical 64-bit integer limit of SQLite or the Dart VM. Legacy values exceeding this bound fail loudly as corrupt data.
- **Integer Arithmetic**: Addition and subtraction include overflow guards throwing `MoneyOverflowException`. Multiplication is guarded. Integer division (`~/`) and modulo (`%`) operate purely on integer minor units. Zero floating-point arithmetic is permitted in financial calculations.

### 3.2 [`AccountType`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/account_type.dart) & [`NormalBalance`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/account_type.dart)
- 5 categories: `asset` (Debit normal), `liability` (Credit normal), `equity` (Credit normal), `income` (Credit normal), `expense` (Debit normal).
- Mathematical balance helper: `computeBalanceImpact(debits, credits)`.

### 3.3 [`Account`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/account.dart)
- Immutable identity, hierarchy (`parentAccountId`), category tag, and active status.
- **Zero balance field**—eliminating the mutable balance antipattern.

### 3.4 [`PostingDirection`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/posting.dart) & [`Posting`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/posting.dart)
- Atomic leg with explicit direction (`debit` or `credit`) and strictly positive magnitude (`Money > 0`).
- Rejects zero, negative, or signed double amounts.

### 3.5 [`EconomicEvent`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/economic_event.dart) Lifecycle & Immutability Contract
- State machine: `draft` $\rightarrow$ `posted`.
- **Draft Events**: Represent staged work in progress; may temporarily contain incomplete or zero postings.
- **Posted Events**: MUST be validated and balanced ($\sum \text{Debits} = \sum \text{Credits}$, $\ge 2$ legs). Cannot be instantiated in an unbalanced state.
- **Corrections**: Posted events cannot have postings mutated or appended in domain memory. Financial corrections require a distinct reversal or adjustment event.
- **Domain vs. Storage Boundary**: In-memory Dart immutability enforces business rules during runtime. Storage-level immutability against direct SQL manipulation will be physically enforced by SQLite native triggers in Milestone C2.

### 3.6 [`EventBalanceValidator`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/event_balance_validator.dart)
- Pure in-memory validator enforcing $\ge 2$ postings, positive amounts, identical event IDs, and $\sum \text{Debits} = \sum \text{Credits}$.

### 3.7 [`EventSemantics`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/event_semantics.dart)
- Pure domain factory methods enforcing double-entry rules:
  - `createExpense`: Dr Expense / Cr Asset.
  - `createIncome`: Dr Asset / Cr Income.
  - `createTransfer`: Dr Destination Asset / Cr Source Asset (Asset category net zero).
  - `createCardPurchase`: Dr Expense / Cr Card Liability.
  - `createCardPayment`: Dr Card Liability / Cr Bank Asset (**Zero expense postings**).
  - `createRefund`: Dr Asset / Cr Expense (**Contra-expense, zero income postings**).
  - `createLoanDisbursement`: Dr Bank Asset / Cr Loan Liability.
  - `createLoanRepayment`: Dr Loan Liability (Principal) + Dr Interest Expense (Interest) / Cr Bank Asset (3 legs balanced).
  - `createOpeningBalance`: Dr/Cr Account / Cr/Dr Equity:OpeningBalances.

### 3.8 [`SafeToSpendCalculation`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/safe_to_spend.dart)
- Preserves: `discretionaryCash` (can be negative), `safeToSpend` (floored at zero: $\max(0, \text{discretionary})$), and `cashflowShortfall` ($\max(0, -\text{discretionary})$).
- Never collapses these distinct financial metrics.

### 3.9 [`AssetEarmark`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/asset_earmark.dart)
- Virtual reservation for savings goals. Generates zero double-entry postings.

### 3.10 [`ReviewCandidate`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/review_candidate.dart)
- Ingestion boundary for unconfirmed SMS/OCR proposals. Pending, rejected, or duplicate candidates produce zero postings and never enter ledger truth.

### 3.11 [`Evidence`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/evidence.dart) & Identity Tiering
- **Forensic Fingerprint (`bodyFingerprint`)**: Cryptographic SHA-256 hash of normalized raw payload. Used for exact raw collision checks when raw payload is present. **Does NOT represent complete future identity**.
- **Canonical Identity Material**: Retained structured evidence that participates in future identity matching after the 30-day raw payload purge:
  - `sourceType` (e.g. 'sms')
  - `sourceIdentifier` (sender/channel e.g. 'VM-HDFCBK')
  - `sourceTimestamp` (external transaction timestamp)
  - `extractedAmount` (monetary magnitude and currency)
  - `extractedMerchant` (counterparty/payee)
  - `externalReference` (UTR, bank reference, UPI ID)
  - `accountContext` (card/account last 4 hint e.g. 'XX4092')
- `purgeRawPayload()` clears `rawPayloadEncrypted`, setting `isPayloadPurged = true`, while all Canonical Identity Material and `bodyFingerprint` survive intact.

### 3.12 [`OpeningBalanceReconciliation`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/opening_balance_reconciliation.dart)
- An opening-balance adjustment is an **explicit migration event backed by reconciliation evidence**.
- Retains target account, legacy balance, reconstructed history balance, delta, reason, provenance source, and status. Prohibits unexplained generic balancing plugs.

---

## 4. Mapping from Old Concepts to New Concepts

```
┌───────────────────────────────────────┬─────────────────────────────────────────────────┐
│ Old Concept                           │ SpendX 2.0 Canonical Domain Concept             │
├───────────────────────────────────────┼─────────────────────────────────────────────────┤
│ bank_accounts.balance (mutable float) │ Derived: Sum of Postings across Account         │
│ transactions (single-entry record)    │ EconomicEvent (draft/posted) + List<Posting>    │
│ category_id (arbitrary string)        │ Account (type: AccountType.expense or .income)  │
│ credit_cards.used_amount              │ Derived: Net Credit Balance of CC Liability Acc │
│ loans.principal / paid_amount         │ Derived: Net Balance of Loan Liability Account  │
│ goals.current_amount                  │ Derived: Sum of active AssetEarmarks for Goal   │
│ review_queue                          │ ReviewCandidate (status: pending/approved/etc)  │
│ raw_sms (stored forever)              │ Evidence (raw_payload purged after 30 days)     │
└───────────────────────────────────────┴─────────────────────────────────────────────────┘
```

---

## 5. Persistence Independence

The domain package [`lib/domain/finance/`](file:///Users/sivek/Documents/SpendX/lib/domain/finance/) has **zero dependencies** on:
- `sqflite` or any database drivers
- `AppDatabase` or `DatabaseHelper`
- Flutter UI widgets, themes, or contexts
- State management (`flutter_riverpod`, `provider`)
- Platform-specific Android/iOS plugins

This independence guarantees that the financial truth model can be tested in isolation, verified against adversarial vectors, and proven correct before any SQLite tables or migrations are executed in Milestone C2.
