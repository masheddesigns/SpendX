# Phase 2A — Financial Mutation Architecture (Design)

**Status:** Design only. No code. `ledgerBackfillEnabled` remains OFF. Phase 2 implementation is **blocked** pending independent review of G1–G3 and explicit approval.

## Locked gates
| Gate | Status |
|---|---|
| Phase 1A–1E | 🟢 Complete |
| Reconciliation safety | 🟢 Acceptable |
| Production backfill | 🔴 OFF |
| Real-user global backfill | 🔴 Not authorized |
| Phase 2 implementation | 🔴 Blocked (pending 2A review + G1–G3) |
| G1 complete mutation coverage | 🔴 Required |
| G2 canonical balance architecture | 🔴 Required |
| G3 continuous invariant enforcement | 🔴 Required |
| G4 legacy reference analysis | 🟡 Required before *real historical backfill*, **not** before 2A design |

**Reordered sequence:** Phase 2A design (G1+G2+G3) → independent review → corrections → approval → implementation → mutation-path audit → real-data tests → only then consider enabling anything.

**Locked principle:** exactly **one service** is responsible for committing a financial mutation. Providers *request*; repositories *persist*; the ledger *records*; balances *reflect* — but no provider independently mutates `transactions` **and** `bank_accounts.balance` anymore.

---

## 0. Rejection of naive "dual-write"
The following is **explicitly NOT accepted** as the final architecture:

```
update transactions  +  update bank_accounts.balance  +  insert ledger_transactions
```

That is three independently-mutable representations of financial state. The accepted model is:

```
One atomic financial operation
   → canonical journal mutation (ledger_transactions is the source of truth)
   → derived / materialized balance update, enforced transactionally
```

`bank_accounts.balance` is a **materialized cache** whose correctness is *enforced transactionally*: inside the same transaction, after applying the journal event, the balance is recomputed from the journal (or adjusted as a cache) and **asserted equal to the journal-derived value**; on mismatch the whole transaction rolls back. The balance is never a free-standing authoritative value.

---

## 1. Complete financial event inventory
| # | Operation | Source entity | Canonical ledger event(s) | Account(s) | Signed amount | reference_id | Balance effect | Edit/Delete semantics |
|---|---|---|---|---|---|---|---|---|
| 1 | income | `transactions` | `income` | account_id | + | tx.id | +asset | reversal + correction |
| 2 | expense | `transactions` | `expense` | account_id | − | tx.id | −asset | reversal + correction |
| 3 | transfer | `transactions` | `transfer`(−) + `income`(+) | account_id → related_entity_id | −src,+dst | tx.id | src−,dst+ | dual reversal |
| 4 | account opening | `bank_accounts` | `opening_balance` | account_id | =initial | `opening-<acc>` | sets baseline | closure = net-out reversal |
| 5 | account closing | `bank_accounts` | `account_close` | account_id | net to 0 | `close-<acc>` | zeroes | reversal of residual |
| 6 | CC purchase | `credit_transactions` | `credit_purchase` | credit_card_id | +outstanding | ctx.id | card+ | reversal |
| 7 | CC payment | `credit_transactions` | `credit_payment` | account_id (−) & card | −bank,+card pay | ctx.id | bank−,card− | reversal |
| 8 | CC refund | `credit_transactions` | `credit_refund` | credit_card_id / account | −outstanding / +bank | ctx.id | card−/bank+ | reversal |
| 9 | loan disbursement | `loans` | `loan_disbursement` | account_id | + | loan.id | +asset | reversal |
| 10 | loan principal pay | `loan_installments` | `loan_payment` | account_id | − | inst.id | −asset | reversal |
| 11 | loan interest | `loan_installments` | `loan_interest` *(new)* | account_id | − | inst.id+`:int` | −asset | reversal |
| 12 | EMI | `credit_emis` | `emi_installment` | account_id & card | −bank,+card pay | emi.id | bank−,card− | reversal |
| 13 | lending given | `lendings` | `lending_given` | account_id | − | lending.id | −asset | reversal |
| 14 | lending repayment | `lendings` | `lending_received` *(new, journaled live)* | account_id | + | lending.id | +asset | reversal |
| 15 | salary post | `salary`/`salary_months` | `salary_credit` *(new)* | account_id | + | salary.id | +asset | reversal |
| 16 | recurring fire | `recurring_templates`→`transactions` | delegates to 1/2/3 | — | — | tx.id | — | as parent type |
| 17 | fuel/vehicle | `transactions` | `fuel_expense` | account_id | − | tx.id | −asset | reversal |
| 18 | fees/charges | `transactions` | `processing_fee`/`interest_charge` | account_id | − | tx.id | −asset | reversal |
| 19 | refund/reversal | any | `reversal` | per original | inverse | `<src>:<rev:n>` | inverse | append-only |
| 20 | edit | any | `reversal`(old) + corrected event | per type | inverse+new | `<src>:<rev:n>` | corrected | append-only |
| 21 | delete | any | `reversal`(cancel) | per original | inverse | `<src>:<rev:n>` | cancel | source row deleted separately |

## 2. Canonical `ledger_transactions` event/type specification
Closed enum (extends backfill's set, adds live-only types):
`income, expense, transfer, opening_balance, account_close, credit_purchase, credit_payment, credit_refund, loan_disbursement, loan_payment, loan_interest, emi_installment, lending_given, lending_received, salary_credit, refund, processing_fee, interest_charge, fuel_expense, reversal, correction`.
Every row: `(id, user_id?, amount, type, date, note?, account_id?, credit_card_id?, loan_id?, category_id?, reference_id, created_at)`. `reference_id` is the join key to the source entity. **Only the single financial service may write this table.**

## 3. Account balance invariant (G2)
**Precise invariant:**
> *For every account, the materialized `bank_accounts.balance` equals the deterministic balance derived from the complete canonical ledger state, under a precisely defined inclusion/sign policy.*

`bank_accounts.balance = opening_balance + Σ(signed ledger movements where account_id = X)` is the shorthand; the exact inclusion/sign rules that make this deterministic are defined in **§19.4**.
**Chosen: Option B (materialized), but explicitly a cache.** The canonical truth is the journal. Within one transaction the service: (a) writes the journal event, then (b) recomputes `bank_accounts.balance` from the journal (or applies the matching delta) and **asserts the materialized value equals the journal-derived value**; mismatch → rollback. `adjustBalance` is *absorbed into* the single service and never called independently. The legacy balance is no longer an independent source of truth.

## 4. Credit-card invariant
`credit_cards.outstanding = Σ(credit_purchase + fees + interest) − Σ(credit_payment + credit_refund)`, per `credit_card_id`. Materialized atomically inside the service transaction; correctness enforced by the same assert-from-journal step.

## 5. Loan invariant
`remaining = loan.total − Σ(paidPrincipal) − Σ(paidInterest)`, per `loan_id`. Materialized from `loan_installments` within the same transaction.

## 6. Lending invariant
`net = Σ(lending_given) − Σ(lending_received)`, per `lending.id`. Materialized on `lendings`.

## 7. Salary/EMI treatment
Salary becomes a **journaled `salary_credit` event** when posted (no longer silently absorbed). EMI is `emi_installment` (bank −, card pay +). Interest is explicitly journaled (`loan_interest`), removing the backfill's silent absorption for *live* events. **A live operation that cannot be journaled MUST FAIL, never absorb.**

## 8. Create / update / delete / reversal semantics
**Append-only.** The ledger is never mutated in place.
- **Edit:** emit `reversal`(old event, `reference_id = <src>:<rev:n>`) + a corrected event (`reference_id = <src>` or `<src>:<rev:n+1>`). The source `transactions` row is updated by the repo, but the ledger history is preserved.
- **Delete:** emit `reversal`(cancel) event (`reference_id = <src>:<rev:n>`). The source `transactions` row is deleted separately by the repo; the ledger retains cancellation.
- **Refund/reversal:** inverse journal event, append-only.
The dormant `FinancialTransactionService` today implements **only createIncome/createExpense/createTransfer (INSERTs)**. Extending it to emit `reversal`/`correction` events for update/delete is a **required implementation prerequisite** (G1), not an afterthought.

## 9. Transfer semantics
Atomic two-leg event (source `transfer` −, dest `income` +) within one transaction; reversal reverses both legs.

## 10. Idempotency / reference strategy
Live `reference_id` = **raw source id** (e.g., `tx.id`, `ctx.id`, `inst.id`, `lending.id`, `salary.id`). Migration rows use the `migration-*` prefix → no collision. Reversals/corrections use `<src>:<rev:n>` to remain unique and traceable. A mutation replayed with the same source id is idempotent: because the whole operation is atomic, a crash before commit leaves no partial row, and a clean re-run re-inserts correctly. The service must guard against double-apply if a partial commit is ever observed (unique `reference_id` constraint).

## 11. Atomic transaction boundary
Single `FinancialTransactionService.do(op)`:
```
BEGIN (one db.transaction)
  validate operation
  persist source record (tx/credit/loan/lending/salary)
  insert canonical ledger event(s)            ← canonical truth
  recompute + assert materialized balances     ← derived, verified
     (account, card, loan, lending)
  verify global invariant (ledger-derived == materialized)
COMMIT
failure → ROLLBACK EVERYTHING
```
Not `transactions.insert()` + `ledger.insert()` + fix-balance-later. Not provider→txRepo + provider→accRepo + service→ledger.

## 12. Error / rollback behavior
All-or-nothing. Any validation, persist, or invariant-verify failure rolls back the entire transaction; the caller receives an exception; no partial state. Mirrors backfill's `_ReconcileNoApply` rollback.

## 13. Migration compatibility with existing data
- `transactions` schema unchanged.
- Existing `migration-*` ledger rows retained as historical; live rows use distinct references (§10) → no collision.
- `bank_accounts.balance` already equals `opening + Σmovements` post-backfill → invariant holds at cutover with zero data migration.
- `FinancialTransactionService` must be extended to full coverage before wiring (currently income/expense/transfer only).

## 14. Provider / service boundary (G1 — entry-point consolidation)
The design asserts **exactly one writer** of financial state. The following production surfaces currently mutate financial state OUTSIDE any unified service and **must be rerouted** (this is the headline gap the 1A→1E audit warned about):

| Surface | File:line | Today mutates | Required action |
|---|---|---|---|
| addTransactionProvider | transaction_providers.dart:254,285,307 | tx + `accRepo.adjustBalance` | route through service |
| bulkAddTransactionsProvider | transaction_providers.dart:461-479 | tx + balances + credit + loans | route through service |
| updateTransactionProvider | transaction_providers.dart (update path) | tx + balances | route through service (reversal+correction) |
| deleteTransactionProvider | transaction_providers.dart (delete path) | tx + balances | route through service (reversal) |
| credit_card_service | credit_card_service.dart:201 | credit_transactions (processing_fee) | route credit mutations through service |
| salary_service | salary_service.dart:795 | `transactions` (income) | route salary posting through service |
| import_service | import_service.dart:346 | `transactions` | route through service |
| smart_importer | smart_importer.dart:239 | `transactions` | route through service |
| vehicle_service | vehicle_service.dart:58 | `transactions` (fuel_expense) | route through service |
| month_detail_screen | month_detail_screen.dart:574 | `transactions` (income) | route through service |
| dev_tools_service | dev_tools_service.dart (seed) | `transactions` + balances | exempt as **seed-only**; must be flagged/non-production and reconciled by backfill |

After Phase 2, **no provider/repository other than the single service may write `transactions`, `bank_accounts.balance`, `credit_transactions`, `credit_cards.outstanding`, `loans.paid_amount`, or `ledger_transactions`.** The repositories (`account_repo.adjustBalance`, `credit_repo.adjustOutstandings`, loan UPDATE) become callable **only** by the service.

## 15. Repository boundary
Repos expose atomic persist primitives; they are called *by* the service inside its transaction. Repos contain **no balance/ledger logic**. The service owns the transaction and orchestration.

## 16. Read-model strategy for dashboards / reports
No immediate change: dashboards/reports keep reading `bank_accounts.balance` (now materialized and verified) and `ledger_transactions`. Long-term, reports may read the ledger directly; out of 2A scope.

## 17. Reconciliation's role after Phase 2
Becomes **diagnostic/recovery**, not corrective. The parity check stays (production OFF), but a failure now signals a *bug* (alarm), because live mutations enforce the invariant per-write (G3). Reconciliation no longer silently absorbs residual.

## 18. Concurrency & retry (explicit)
- SQLite is single-writer; transactions serialize at the DB level. Correctness holds **iff every mutation's source-write + ledger-write + balance-recompute is inside ONE `db.transaction()`**. The service must guarantee this for all entry points.
- The materialized balance must **never** be read-modify-written outside the service transaction (that reintroduces the race). The service recomputes from the journal within its own txn.
- Retry safety: idempotent re-run after a crash is safe because the operation is atomic (no partial commit) and `reference_id` uniqueness prevents double journaling.
- No separate distributed lock is required for a single-device SQLite app, but the service must be the sole entry point to avoid interleaved partial writes.

## 19. Writer Closure & Balance Derivation Contract

This section is the gating artifact for implementation approval. Dart does **not** enforce the "repositories are callable only by the service" boundary, so it must be proven by audit, not convention.

### 19.1 Complete writer inventory
Every write that can alter financial state must be enumerated and classified. Current production surfaces (from code search; see §14 for file:line):

| Surface | Writes | Classification |
|---|---|---|
| `transaction_providers.dart` add/bulk/update/delete | `transactions`, `bank_accounts.balance`, `credit_transactions`, `credit_cards.outstanding`, `loans.paid_amount` | **MUST reroute** through service |
| `credit_card_service.dart:201` | `credit_transactions` (processing_fee) | **MUST reroute** |
| `salary_service.dart:795` | `transactions` (income) | **MUST reroute** |
| `import_service.dart:346` | `transactions` | **MUST reroute** |
| `smart_importer.dart:239` | `transactions` | **MUST reroute** |
| `vehicle_service.dart:58` | `transactions` (fuel_expense) | **MUST reroute** |
| `month_detail_screen.dart:574` | `transactions` (income) | **MUST reroute** |
| `dev_tools_service.dart` (seed) | `transactions`, balances | **Excluded — seed/non-production**, reconciled by backfill, must not ship enabled |

The pre-implementation audit (§19.3) is the proof that this list is **complete**, not merely illustrative.

### 19.2 Rule: no financial repository writer may bypass the service
`account_repo.adjustBalance*`, `credit_repo.adjustOutstandings*`, loan `UPDATE paid_amount`, and all `ledger_transactions` inserts are permitted **only** inside `FinancialTransactionService`'s transaction. Any other caller is a defect. Because Dart cannot enforce this, the audit (§19.3) and the mutation-path audit (post-implementation) are the enforcement mechanism.

### 19.3 Writer-closure search / audit criteria
Before `FinancialTransactionService` becomes the production mutation path, run (and record results of) searches for **every** operation that can alter financial state, proving each is either (1) invoked exclusively inside the service transaction, or (2) deliberately classified as non-financial/administrative and excluded with justification. Search for:
- `insert` / `update` / `delete` against financial tables (`transactions`, `bank_accounts`, `credit_transactions`, `credit_cards`, `loans`, `loan_installments`, `lendings`, `salary`, `salary_months`, `credit_emis`, `ledger_transactions`);
- `rawInsert`, `rawUpdate`, `rawDelete`;
- repository methods that ultimately perform those operations;
- `adjustBalance` / `adjustBalances` / `adjustOutstandings`;
- direct `bank_accounts` writes;
- direct `transactions` writes;
- credit-card transaction / payment / refund writes;
- loan / installment writes;
- lending / repayment writes;
- salary / payment writes;
- EMI writes;
- recurring-generated transactions;
- vehicle / fuel-generated expenses;
- import / bulk-import paths;
- dev / test seed paths that could accidentally survive into production.

### 19.4 Ledger-to-balance inclusion / sign policy (deterministic)
The materialized `bank_accounts.balance` is derived **only** from `ledger_transactions` rows whose `account_id` is non-null, under this policy:

- **Sign rule:** `signed = -amount` if `type` ∈ {`expense`, `credit_payment`, `emi_installment`, `loan_payment`, `transfer`, `lending_given`, `fuel_expense`, `processing_fee`, `interest_charge`, `loan_interest`}; otherwise `signed = +amount`. (Mirrors `ledger_repo.dart` sign logic.)
- **opening_balance rows:** included as `+amount` (the baseline; mathematically identical to a positive event).
- **migration rows** (`reference_id` LIKE `migration-%`): included with the same per-type sign rule as their type — they are historical events, not a separate category.
- **transfers:** both legs participate — source leg `transfer` (−) on source `account_id`, dest leg `income` (+) on destination `account_id`.
- **credit / loan / lending events:** only rows with a non-null `account_id` affect `bank_accounts.balance`. `credit_purchase`/`credit_refund` (card-only) affect `credit_cards.outstanding`, not bank balance; `credit_payment` affects both (bank −, card pay +). `loan_disbursement`/`loan_payment`/`loan_interest` affect bank; `lending_given`/`lending_received` affect bank.
- **reversal / correction rows (`reversal`, `correction`):** included with their own signed amount. A reversal carries the inverse sign of the original event by construction, so including it correctly cancels the original in the sum. They are **not** excluded — excluding them would break the invariant for edited/deleted records.
- **rows for closed / deleted source records:** the original event rows remain (append-only) and are balanced by an `account_close` (net-out) or `reversal`(cancel) event; both are included, so the derived balance is correct (closed account → 0; deleted transaction → reverted).
- **Completeness guard:** the derivation must cover every `type` in the §2 enum. Any type not enumerated in this policy is a defect (prevents "mathematically correct but omits a domain").

### 19.5 Explicit handling of reversal / correction rows
- A `reversal` row reverses exactly the original event(s) via inverse signed amount and `reference_id = <src>:<rev:n>`.
- A `correction` row carries the corrected signed amount for the same source.
- Both participate in §19.4 derivation; neither is ever deleted or mutated in place.
- The source `transactions` row may be updated/deleted by the repo, but the ledger keeps the full reversal/correction trail, so the materialized balance always reflects net effect.

## 20. Explicit non-goals of Phase 2A (design only)
- No production backfill enablement; flag stays OFF.
- No auto/startup reconciliation.
- No deletion of Phase 1 code; `FinancialTransactionService` extended, not replaced.
- No UI/screen changes in 2A (design only).
- No remote config.
- No `bank_accounts` schema deletion; materialized balance reuses the existing column.
- No Phase 2 rollout / real-user backfill (G4 deferred).

---

## G3 restated as an invariant (not monitoring)
> *Every financial mutation must either preserve the invariant atomically or fail.* Reconciliation is downgraded to a diagnostic, not the mechanism that keeps the system correct.

## G4 split (as directed)
Phase 2A design → independent review → corrections → approval → implement G1+G2+G3 → real-data validation → **G4 (legacy `reference_id` conformance) before historical backfill rollout**. G4 does not block the 2A design.
