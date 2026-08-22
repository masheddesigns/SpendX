# Writer-Closure Audit (§19.3) — Pre-Implementation

**Mandatory gate before routing.** Run against `lib/` (production code only; tests excluded). Goal: prove every production financial write passes through the approved transaction service, or is explicitly classified as non-financial/administrative.

**Method:** grep for `insert`/`update`/`delete`/`rawInsert`/`rawUpdate`/`rawDelete` against financial tables and repository write methods, plus `adjustBalance`/`adjustOutstandings` and direct table writes.

## Findings

| # | Surface (file:line) | Writes | Classification | Required action |
|---|---|---|---|---|
| 1 | `transaction_providers.dart:254,285,307` (add/update/delete) | `transactions`, `bank_accounts.balance` | **FINANCIAL** | Reroute through service |
| 2 | `transaction_providers.dart:461-479` (bulk) | `transactions`, `bank_accounts.balance`, `credit_transactions`, `credit_cards.outstanding`, `loans.paid_amount` | **FINANCIAL** | Reroute through service |
| 3 | `credit_card_service.dart:26,28` (add) | `credit_transactions`, `ledger_transactions` | **FINANCIAL** | Reroute through service |
| 4 | `credit_card_service.dart:82,85` (delete) | `credit_transactions`, `ledger_transactions` | **FINANCIAL** | Reroute through service |
| 5 | `credit_card_service.dart:147,150,163` (processPayment) | `credit_transactions`, `ledger_transactions` (card + bank-side expense) | **FINANCIAL** | Reroute; also must adjust `bank_accounts.balance` (current code omits this — divergence bug) |
| 6 | `credit_card_service.dart:187,190,205,207,242,275` (convertEMI) | `credit_transactions`, `ledger_transactions`, EMI/installments | **FINANCIAL** | Reroute; complex allocation — encapsulate in service |
| 7 | `credit_card_service.dart:319,325,339` (updateEMI) | `credit_transactions`, `ledger_transactions` | **FINANCIAL** | Reroute |
| 8 | `loan_service.dart:30,173,186` (disbursement/payment) | `loans`, `ledger_transactions` | **FINANCIAL** | Reroute through service |
| 9 | `salary_service.dart:795` (post salary) | `transactions` (income) | **FINANCIAL** | Reroute through service |
| 10 | `import_service.dart:346` | `transactions` | **FINANCIAL** | Reroute (likely via provider) |
| 11 | `smart_importer.dart:239` | `transactions` | **FINANCIAL** | Reroute (likely via provider) |
| 12 | `vehicle_service.dart:58` | `transactions` (fuel_expense) | **FINANCIAL** | Reroute (likely via provider) |
| 13 | `month_detail_screen.dart:574` | `transactions` (income) | **FINANCIAL** | Reroute (likely via provider) |
| 14 | `alert_service.dart:168` | `lendings` (update) | **FINANCIAL** | Reroute through service |
| 15 | `dev_tools_service.dart` (seed) | `transactions`, balances | **SEED/non-production** | Excluded; must not ship enabled; reconciled by backfill |
| 16 | `credit_intelligence_service.dart:109` | `ledger_transactions` (processing_fee) | **REQUIRES CLASSIFICATION** | Verify it is analytics-derived; if it mutates financial truth, reroute |
| 17 | `maintenance_repo.dart:158` | `ledger_transactions` | **REQUIRES CLASSIFICATION** | Verify maintenance/cleanup semantics; classify |
| 18 | `account_repo.dart` / `credit_repo.dart` write primitives | `bank_accounts`, `credit_cards`, `credit_transactions` | **INFRASTRUCTURE** | Callable only by the service after routing |

## Conclusion (provisional)
The previously identified ten surfaces are **not exhaustive**. Additional financial writers exist in `loan_service`, `salary_service`, `import_service`, `smart_importer`, `vehicle_service`, `month_detail_screen`, `alert_service`, and at least two `ledger_transactions` writers of uncertain classification (`credit_intelligence_service`, `maintenance_repo`). Items 16–17 require classification before closure. This audit is the binding proof and must be re-run after routing to confirm zero remaining unclassified financial writers.

## Action
Routing is performed per the implementation plan: transaction providers first (dominant path), then credit/loan/lending/salary/import/vehicle. Items 16–17 are flagged for explicit classification as part of G1 completion.

---

## Post-Implementation Closure (Status)

`ledgerBackfillEnabled` remains OFF; no production rollout. `FinancialTransactionService` is now the sole writer of `ledger_transactions` and `bank_accounts.balance`. Domain subsystems route their journal rows through the new `appendLedger` / `removeLedger` choke-points, which also apply + verify the balance delta for any `accountId`-bearing leg.

| # | Surface | Resolution |
|---|---|---|
| 1 | `transaction_providers` add/update/delete | ✅ Routed through service (append-only edit/delete) |
| 2 | `transaction_providers` bulk | ✅ Routed through `createTransaction` (credit/loan side-effects) |
| 3 | `credit_card_service` add | ✅ `appendLedger` (credit_purchase) |
| 4 | `credit_card_service` delete | ✅ `removeLedger` |
| 5 | `credit_card_service` processPayment | ✅ `appendLedger` for card + bank-side expense — **balance bug fixed** (bank leg now updates `bank_accounts.balance`) |
| 6 | `credit_card_service` convertEMI | ✅ `appendLedger`/`removeLedger` for fee + installments |
| 7 | `credit_card_service` updateEMI | ✅ `appendLedger`/`removeLedger` |
| 8 | `loan_service` disbursement/payment | ✅ `appendLedger` for loan-side + bank-side expense — **balance bug fixed** |
| 9 | `salary_service` post salary | ✅ `createTransaction` / `editTransaction` |
| 10 | `import_service` | ✅ Indirect — `import_preview_screen` uses `addTransactionProvider` (service) |
| 11 | `smart_importer` | ✅ `createTransaction` (no accountId → source-only) |
| 12 | `vehicle_service:58` | ❌ **Not a writer** — builds a display `VehicleActivity` timeline object, no `transactions` write |
| 13 | `month_detail_screen` | ✅ `addTransactionProvider` (service) |
| 14 | `alert_service:168` | ❌ **Not a bypass** — updates `lendings` table only (settlement state); no `ledger_transactions` / `bank_accounts.balance` write |
| 15 | `dev_tools_service` seed | ✅ SEED — excluded; reconciled by backfill |
| 16 | `credit_intelligence_service:109` | ❌ **Read-only** — sums `ledger_transactions` for unbilled amount; does not write |
| 17 | `maintenance_repo:158` | ❌ **Bulk reset** — `clearCreditData`/`clearLoans` delete domain + ledger rows together (wipe, not per-mutation); out of gate scope |
| 18 | repo write primitives | ✅ Invoked only from within `FinancialTransactionService` (or are reads) |

### Remaining known nuance (tracked under §19 / G4)
- `removeLedger` hard-deletes credit-internal ledger rows (e.g. purchase→EMI conversion). This is a domain transform, not a user-edit; full append-only purity for these transforms is deferred to G4 (reconciliation pass), but the ledger now has exactly one writer.
- Historical (pre-backfill) data: bank-side card/loan legs were previously journaled without a balance delta; only the journal carried them. Going forward `appendLedger` keeps balance parity. The one-time `LedgerBackfillService` (G4) reconciles existing rows; it is unchanged and off by default.

