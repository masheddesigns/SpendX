# SpendX 2.0 — Legacy Transaction & Mutation Mapping Blueprint

**Document**: `37_LEGACY_TRANSACTION_MAPPING.md`  
**Status**: APPROVED CANONICAL SPECIFICATION  
**Scope**: Precise Mapping Matrix from Legacy v23 Transactions, Credit Entries, Lendings, and Salary Records to SpendX 2.0 Canonical Economic Events and Double-Entry Postings  
**Cross-References**: `02_ECONOMIC_EVENT_MODEL.md`, `04_DOUBLE_ENTRY_LEDGER.md`, `05_ACCOUNTING_SEMANTICS.md`, `34_FINAL_PRODUCT_DECISION_LOCK.md`

---

## 1. Executive Rules of Transaction Mapping

1. **Every Committed Economic Event Must Have Balanced Postings**:
   $$\sum \text{Debits} = \sum \text{Credits}$$
   No economic event may exist in the target ledger with un-offset postings.
2. **Deterministic Minor Currency Conversion**:
   All monetary amounts are converted from legacy `REAL` (Rupees) to integer paise:
   $$\text{amount\_paise} = \text{round}(\text{amount\_real} \times 100)$$
   Where amounts must be positive, `amount_paise > 0` is strictly enforced.
3. **Zero Phantom Duplication Between Ingestion & Inferred Transactions**:
   A transaction that generated a bank deduction for a credit card bill payment must NOT create both an `Expense:CreditCard` and a `Liability:CreditCard` debit. It creates a single liability settlement event.
4. **Soft-Deleted Rows Never Create Postings**:
   Any row with `is_deleted = 1` in legacy `transactions` is preserved as an audit/tombstone `economic_events` record with `lifecycle_status = 'deleted'`, but produces **ZERO active postings** in the canonical ledger.
5. **Review Queue Separation**:
   Unconfirmed candidates in `review_queue` are NOT financial transactions. They migrate to `review_candidates` and do NOT generate `economic_events` or `postings` until user confirmation.
6. **No Silent Mapping of Unknown Types**:
   Any unexpected `type` or corrupt record is categorized as `BLOCKED — MANUAL MIGRATION RULE REQUIRED`.

---

## 2. Legacy Transaction Mapping Master Matrix

| Legacy Record Origin | Legacy Type / Identifier | Target EconomicEvent `event_type` | Target Debit Account (Leg 1) | Target Credit Account (Leg 2) | Treatment & Semantic Transformation | Risk & Mitigation |
|---|---|---|---|---|---|---|
| `transactions` | `type = 'expense'` (standard) | `expense` | `Expense:<CategoryPath>` | `Asset:LiquidCash:<BankId>` | Standard expense deduction. Decreases bank balance, increases expense tally. | Missing `account_id` $\to$ Fallback to default primary cash account. |
| `transactions` | `type = 'expense'` (`source = 'vehicle'` or category Fuel) | `expense` | `Expense:Transport:Fuel` | `Asset:LiquidCash:<BankId>` | Ordinary fuel expense. Completely decoupled from vehicle entities. | Historical vehicle FKs discarded safely. |
| `transactions` | `type = 'income'` (standard) | `income` | `Asset:LiquidCash:<BankId>` | `Income:<CategoryPath>` | Standard revenue addition. Increases bank balance, increases income tally. | Uncategorized income maps to `Income:General:Miscellaneous`. |
| `transactions` | `type = 'transfer'` | `transfer` | `Asset:LiquidCash:<ToAccountId>` | `Asset:LiquidCash:<FromAccountId>` | Inter-account asset reallocation. Exact zero-sum impact on net worth. | Legacy transfers stored as two separate rows $\to$ Re-paired using timestamp and amount matching. |
| `credit_transactions` / `transactions` | `credit_card_purchase` / `type = 'purchase'` | `credit_purchase` | `Expense:<CategoryPath>` | `Liability:CreditCard:<CardId>` | Credit card purchase. Increases expense immediately; increases card liability (outstanding balance). Bank balance untouched. | Double-counting if user logged both in `transactions` and `credit_transactions` $\to$ Dedup via `external_ref` / timestamp. |
| `transactions` / `ledger_transactions` | `credit_payment` (bank payment to card) | `liability_settlement` | `Liability:CreditCard:<CardId>` | `Asset:LiquidCash:<BankId>` | Card bill settlement. Reduces card liability, reduces bank cash balance. **Must NOT be classified as an Expense**. | Legacy SpendX 1.0 classified this as Expense $\to$ Corrected to pure Asset-Liability transfer. |
| `transactions` / `credit_transactions` | `refund` (matched to original expense) | `refund` | `Asset:LiquidCash:<BankId>` or `Liability:CreditCard:<CardId>` | `Expense:<OriginalCategoryPath>` | Contra-expense activity. Directly offsets original expense category. References original event ID. | If original category unknown, use `Expense:General:Refunds`. |
| `transactions` | `refund` (unmatched) | `refund` | `Asset:LiquidCash:<BankId>` | `Expense:General:Refunds` | Unmatched refund contra-expense (Approved Decision 1). Never treated as Income. Produces balanced posting. | Distinguishing between income and refund $\to$ Keyword analysis and legacy `type = 'refund'`. |
| `lendings` | `type = 'lent'` (initial lending given) | `lending_disbursement` | `Asset:Receivable:Person:<PersonId>` | `Asset:LiquidCash:<BankId>` | Asset conversion. Cash leaves bank, receivable asset increases. Net worth unchanged. | Unnamed borrower $\to$ Generate placeholder contact ID. |
| `lendings` | `type = 'lent'` + repayments (`paid_amount > 0`) | `lending_repayment` | `Asset:LiquidCash:<BankId>` | `Asset:Receivable:Person:<PersonId>` | Receivable collection. Cash enters bank, receivable asset decreases. | Legacy repayments lacked individual timestamps $\to$ Absorb into opening receivable baseline if untracked. |
| `lendings` | `type = 'borrowed'` (initial loan taken) | `borrowing_disbursement` | `Asset:LiquidCash:<BankId>` | `Liability:Payable:Person:<PersonId>` | Debt incurred. Cash enters bank, payable liability increases. | Ensure bank cash is not double-counted with opening balance. |
| `loans` | Loan disbursement | `loan_disbursement` | `Asset:LiquidCash:<BankId>` | `Liability:Loan:<LoanId>` | Bank loan disbursed. Cash increases, loan liability increases. | If disbursement preceded SpendX usage $\to$ Handled via Opening Balance baseline. |
| `loans` / `loan_installments` | Loan EMI repayment (Principal + Interest) | `loan_payment` | `Liability:Loan:<LoanId>` (Principal)<br>`Expense:Financial:Interest` (Interest) | `Asset:LiquidCash:<BankId>` (Total EMI) | Split posting. Cash reduces by total EMI; liability reduces by principal component; interest posted to financial expense. | Missing split data $\to$ Post full amount to `Liability:Loan`, interest residual absorbed into opening baseline. |
| `salary` / `salary_payments` | Salary credit received | `salary_receipt` | `Asset:LiquidCash:<BankId>` | `Income:Salary:Employment` | Employment compensation. Increases bank cash, logs employment income. Links to `salary_contracts`. | Discrepancy between contract base salary and net credited $\to$ Net credited is economic truth. |
| `transactions` | `is_deleted = 1` | `tombstone` | *None (Zero Postings)* | *None (Zero Postings)* | Soft-deleted transaction preserved for historical audit only. Excluded from all active ledger balances. | Historically deleted transactions altering balances $\to$ Neutralized completely in canonical ledger. |
| `review_queue` | `status = 'pending'` | *None* | *None* | *None* | Ingested candidate awaiting review. Transferred to `review_candidates` table. Zero ledger postings. | Must never leak into actual accounts or cashflow. |
| *Any Table* | *Unknown Type / Invalid FK / Corrupted Data* | `BLOCKED` | **BLOCKED** | **BLOCKED** | **BLOCKED — MANUAL MIGRATION RULE REQUIRED**. Recorded in `ledger_backfill_log` exceptions. | Halts automatic migration of affected record until reviewed. |

---

## 3. Explicit Posting Demonstrations for Critical Scenarios

### Scenario A: Credit Card Purchase Followed by Bill Payment
1. **Purchase**: User spends ₹1,500 at a restaurant using Credit Card `C1`:
   - `EconomicEvent(id: 'evt_p1', event_type: 'credit_purchase', amount: 150000)`
   - Postings:
     - `DEBIT  Expense:Dining` : 150000 paise (₹1,500.00)
     - `CREDIT Liability:CreditCard:C1` : 150000 paise (₹1,500.00)
   - *Result*: Dining expense increases by ₹1,500; card debt increases by ₹1,500. Bank cash untouched.
2. **Bill Payment**: User pays ₹1,500 card bill from Bank Account `A1`:
   - `EconomicEvent(id: 'evt_pay1', event_type: 'liability_settlement', amount: 150000)`
   - Postings:
     - `DEBIT  Liability:CreditCard:C1` : 150000 paise (₹1,500.00)
     - `CREDIT Asset:LiquidCash:A1` : 150000 paise (₹1,500.00)
   - *Result*: Card debt decreases by ₹1,500 (balance back to ₹0); bank cash decreases by ₹1,500.
   - **Zero Double-Counting**: Total expense incurred across both events is exactly ₹1,500.00.

### Scenario B: Loan EMI Payment with Interest Split
User pays monthly Home Loan EMI of ₹45,000 (₹35,000 principal + ₹10,000 interest) from Bank Account `A1`:
- `EconomicEvent(id: 'evt_emi1', event_type: 'loan_payment', amount: 4500000)`
- Postings (3-leg balanced split):
  - `DEBIT  Liability:Loan:HomeLoan` : 3500000 paise (₹35,000.00) [Principal reduction]
  - `DEBIT  Expense:Financial:Interest` : 1000000 paise (₹10,000.00) [Cost of borrowing]
  - `CREDIT Asset:LiquidCash:A1` : 4500000 paise (₹45,000.00) [Bank cash outflow]
- *Balance Check*: $\text{Debits} (3500000 + 1000000) = \text{Credits} (4500000)$. Perfect balance.

### Scenario C: Unmatched Merchant Refund
User receives a ₹450 refund into Bank Account `A1` from a returned e-commerce item without a tracked original expense ID:
- `EconomicEvent(id: 'evt_ref1', event_type: 'refund', amount: 45000)`
- Postings:
  - `DEBIT  Asset:LiquidCash:A1` : 45000 paise (₹450.00) [Bank cash increases]
  - `CREDIT Expense:General:Refunds` : 45000 paise (₹450.00) [Contra-expense decreases net spending]
- *Result*: Net Income and Gross Income are un-distorted; net periodic spending decreases by ₹450.00.

---

## 4. Unknown Legacy Types Policy

If a row in legacy `transactions` has a `type` other than `'expense'`, `'income'`, `'transfer'`, or `'refund'`, or if an unresolvable corruption occurs:
1. The migration script does NOT attempt a guess or silent conversion.
2. The row ID and raw payload are logged to `migration_exceptions` with error code `ERR_UNMAPPED_LEGACY_TYPE`.
3. The event is staged as an uncommitted draft requiring manual user classification.
4. The account balance reconciliation ledger absorbs the discrepancy into `Equity:OpeningBalance:Discrepancy` so the user's real-world cash balance matches ground reality without fabricating fake transactions.
