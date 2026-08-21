# Phase 1D Closure Audit — Independent Static Review

**Commit audited:** `61b3efb` (Phase 1D: guarded, explicit historical ledger reconciliation)
**Date:** 2026-08-22
**Method:** Static audit only. No code modified, no flag enabled, no reconciliation run against a real DB, Phase 2 not started.
**Auditor stance:** Independent verification of the implemented behavior against the locked Phase 1D specification.

## Scope

`lib/data/migrations/ledger_backfill_service.dart`
`lib/data/core/app_database.dart`

## Result summary

- **No FAIL findings.** All safety-critical invariants hold.
- **3 WARN findings** (non-blocking, tracked for Phase 1E hardening):
  - WARN-7b: failure runs are not recorded in `ledger_backfill_log`.
  - WARN-11: a third allow-listed exception (loan/credit interest) exists beyond the two enumerated in the locked spec.
  - WARN-TOCTOU: kill-switch / feature-flag gates are not re-read inside the reconcile transaction.

## Safety-critical invariants (PASS)

| # | Question | Result | Ref | Class |
|---|----------|--------|-----|-------|
| 1 | `ledgerBackfillEnabled` false on fresh DB | PASS | `app_database.dart:390-399` | correctness |
| 2 | `authorized:true` cannot bypass feature flag | PASS | flag gate `app_database.dart:478` precedes reconcile `:510` | correctness |
| 3 | `force:true` cannot bypass kill switch | PASS | kill-switch gate `app_database.dart:471` first; `force` only at `:493` | correctness |
| 4 | No startup/`onUpgrade`/`_onCreate`/provider path calls reconciliation | PASS | only `app_database.dart` internal + tests; `ledger_backfill_dry_run.dart` never called from `lib`; no UI/provider import | correctness |
| 5 | Analysis + mutation + parity in ONE SQLite transaction | PASS | `ledger_backfill_service.dart:95` `db.transaction` wraps `_reconcileSteps` (analysis + apply + `_recheckParity` `:132`) | correctness |
| 6 | Every failed parity check rolls back ALL new ledger rows | PASS | any parity mismatch adds `hardFailures` (`:616`,`:311`,`:395`,`:516`,`:641`) → `isExecutable=false` → `_ReconcileNoApply` → rollback (`:97-100`) | correctness |
| 7 | No success marker written on failure | PASS | `ledger_backfill_log` insert only at `app_database.dart:511`, after successful reconcile; `FAIL` verdict never inserted | correctness |
| 8 | Existing ledger rows are append-only | PASS | service only `INSERT`s `migration-*` rows; no `UPDATE`/`DELETE` on `ledger_transactions` anywhere | correctness |
| 9 | Mismatched existing ledger row never overwritten | PASS | `:213-223` adds `reviewItems`+`hardFailures` only; blocks execution/rollback; never mutated | correctness |
| 10 | Orphan/duplicate/unknown-ref can never become `EXECUTABLE_WITH_EXCEPTIONS` | PASS | all add `hardFailures` → verdict `FAIL` (`:896`); `EXECUTABLE_WITH_EXCEPTIONS` requires `passed` (`:897`) | correctness |
| 11 | Only allow-listed exception categories accepted | PASS (see WARN-11) | exceptions only added at `:317` (lending repayment), `:663` (salary residual) | correctness |
| 12 | Opening-balance math: `opening + canonical movements = bank_accounts.balance` | PASS | `opening = stored − (existingMovement + insertedNet)` `:230-231`; derived incl. opening `:608-611` → equals stored | correctness |
| 13 | Second successful reconcile → zero new rows | PASS | reference_id-based skip `:186-224`,`:276-298`,`:343-372`,`:422-477`; tested at `:255`,`:287-289` | correctness |
| 14 | `close()` clears singleton/handle | PASS | `app_database.dart:287-290`; `setTestDatabasePath` also nulls `_database` | correctness |
| 15 | No indirect UI/provider/startup caller | PASS | confirmed via grep across `lib` | correctness |

## WARN findings

### WARN-7b — Failure runs not recorded in `ledger_backfill_log`
Only successful runs write a log row (`app_database.dart:511`). A `FAIL`/rolled-back run leaves no audit entry. This is an *observability* gap, not a safety defect (the critical "no success marker on failure" property holds). Candidate for 1E telemetry.
**Class:** test-coverage / operational gap.

### WARN-11 — Third exception category beyond the locked spec
`loan/credit interest absorbed into opening` (`:669-682`) is allow-listed and explicitly reported, but the locked spec named exactly two (lending repayment; salary/EMI residual). It is not a silent escape hatch, yet it is a spec deviation.
**Class:** spec deviation / documentation.

### WARN-TOCTOU — Kill-switch / feature-flag gates not re-read inside the reconcile transaction
Gates at `app_database.dart:471/478/493` execute *before* `reconcile` opens its own transaction at `:510`. `reconcile` (`:88-114`) re-validates only `authorized`/`isExecutable` (parity), not the kill switch or flag. On single-threaded Dart a concurrent flip between the gate check and the transaction is effectively impossible and no startup/provider path can trigger it — but for strict TOCTOU assurance the gate checks should be re-read *inside* the same transaction as the writes (parity is already re-checked inside via `_recheckParity`; the flag/kill-switch are not).
**Class:** defense-in-depth / hardening candidate.

## Closure record

> **Phase 1D implementation complete.** Guarded historical reconciliation exists (`LedgerBackfillService.reconcile`), is explicitly authorized (separate `authorized` signal, distinct from the local feature flag), append-only (no `UPDATE`/`DELETE` on `ledger_transactions`), parity-gated (`opening + canonical movements = bank_accounts.balance`), transactionally rolled back on any failure (single `db.transaction` wrapping analysis → apply → post-apply parity recheck → commit/rollback), and disabled by default (`ledgerBackfillEnabled` false on fresh DB; no auto-enable). No automatic invocation exists from `onUpgrade`/`_onCreate`/startup/providers. Kill switch and feature flag are independent hard gates. Production rollout remains disabled.
>
> **Outstanding (non-blocking, tracked for 1E hardening):** (a) failure runs not recorded in `ledger_backfill_log`; (b) a third allow-listed exception category (interest absorbed) beyond the two enumerated; (c) kill-switch/flag gates not re-read inside the reconcile transaction (defense-in-depth only).
>
> **Status: Phase 1D CLOSED.** `ledgerBackfillEnabled` remains `false`; Phase 2 not started.

## Sign-off

No FAIL findings. Phase 1D is safe to freeze. Three hardening items are recommended before broader real-user rollout and are scoped as Phase 1E.
