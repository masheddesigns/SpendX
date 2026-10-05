# SpendX 2.0 — Milestone C5 Implementation Report
## Multi-Evidence Ingestion & Deduplication Pipeline Migration

---

### 1. Executive Summary

Milestone **C5** establishes the canonical multi-evidence ingestion, deduplication, and review proposal pipeline for SpendX 2.0. Prior to this milestone, incoming SMS and file imports interacted with legacy tables (`review_queue`, legacy `transactions`), and background SMS processing (`LiveSmsService._applyBalance`) performed direct, silent mutations to `bank_accounts.balance` and `credit_cards.used_amount`.

Under Milestone C5:
1. **Zero Runtime Writes to Legacy `review_queue`**: All pending ingestion proposals are persisted strictly in `TablesV24.reviewCandidates`. The legacy `review_queue` table has zero runtime writes and zero authority over financial state.
2. **Zero Direct Balance Mutations from Ingestion**: `LiveSmsService._applyBalance` and auto-registration paths have been completely disarmed of destructive account balance mutations. Detected balance statements are safely quarantined as immutable canonical `Evidence` records in `TablesV24.evidence`.
3. **Multi-Evidence Ingestion Boundary**: Real-world signals (SMS, CSV, OCR, receipts) create immutable `Evidence` artifacts and non-accounting proposals (`ReviewCandidate`). They create **zero postings**, **zero economic events**, and have **zero impact on Net Worth or Safe-to-Spend** prior to explicit user approval.
4. **Deterministic Canonical Deduplication**: Deduplication operates against canonical `Evidence` (external reference / UTR, SHA-256 body fingerprint) and pending `ReviewCandidate` rows. Rogue mutations or insertions into legacy `transactions` have zero influence on ingestion deduplication.
5. **Canonical Accounting Conversion**: Upon explicit user confirmation, proposals route through `FinancialTransactionService` $\to$ `TransactionRepo` $\to$ `CanonicalEventRepository`, creating immutable `EconomicEvent` rows and balanced double-entry `Posting` records.

All 18 architectural invariants are satisfied with 100% pass rate in the dedicated adversarial test suite, and the full project test suite passes cleanly at 566/566.

---

### 2. Ingestion Reality vs Accounting Reality

The foundational architectural principle established in C5 is the strict separation between **Evidence** (observations of the outside world) and **Accounting Truth** (balanced double-entry state):

$$\begin{aligned}
\text{Outside World (SMS / Bank Statement / OCR)} &\longrightarrow \text{Evidence (observation, unverified)} \\
&\longrightarrow \text{ReviewCandidate (non-accounting proposal)} \\
&\overset{\text{Explicit User Action}}{\longrightarrow} \text{FinancialTransactionService} \\
&\longrightarrow \text{EconomicEvent (immutable ledger entry)} \\
&\longrightarrow \text{Balanced Postings (authoritative financial state)}
\end{aligned}$$

- **An SMS is NOT a transaction**: An SMS is external evidence of an alleged economic event. It may be fraudulent, malformed, a promotional message disguised as a transaction, or a duplicate delivery of a previously processed UPI notification.
- **A balance notification is NOT a balance**: A bank SMS declaring "Avail Bal is ₹89,000" is an external statement valid at a specific point in time. Directly setting `bank_accounts.balance = 89000.0` circumvents auditability, destroys double-entry accounting integrity, and invalidates financial history. In C5, balance notifications are recorded as `Evidence` with `account_context`, providing an audit trail without mutating ledger balances.

---

### 3. Architecture Topology: Before vs After

#### Before C5 (Legacy / Unsafe Pipeline)
```
SMS Received / SMS Scan
       │
       ├─► ParsedTransaction ──► INSERT INTO review_queue (legacy table)
       │                              │
       │                              └─► Legacy review queries / writes
       │
       └─► BalanceHit ─────────► AccountRepo().updateBalance(match.id, amount)
                                 (Silent, destructive mutation of SQLite balance)
```

#### After C5 (Canonical Pipeline)
```
SMS Received / SMS Scan
       │
       ├─► Compute SHA-256 Fingerprint
       ├─► Check Deduplication (UTR in evidence / SHA-256 / Pending Candidates)
       │
       ├─► Transaction Signal:
       │     ├─► INSERT INTO TablesV24.evidence (raw payload, fingerprint, ref)
       │     └─► INSERT INTO TablesV24.reviewCandidates (status = 'pending')
       │           │
       │           ▼
       │     User Reviews & Approves
       │           │
       │           ▼
       │     FinancialTransactionService().createTransaction()
       │           ├─► EconomicEvent (lifecycle = 'posted')
       │           ├─► Balanced Postings (Dr Category / Cr Account)
       │           └─► Update ReviewCandidate (status = 'approved')
       │
       └─► Balance Statement Signal:
             └─► INSERT INTO TablesV24.evidence (source_type = 'sms', account_context = 'XX4321')
                 (ZERO mutation to bank_accounts.balance, ZERO postings)
```

---

### 4. Evidence Record Specifications

All ingested external signals are recorded in `TablesV24.evidence` with the following attributes:

| Column | Type | Ingestion Contract | Description |
|---|---|---|---|
| `id` | `TEXT PRIMARY KEY` | UUID v4 | Unique evidence identity |
| `economic_event_id` | `TEXT REFERENCES economic_events(id)` | `NULL` at ingestion | Linked to `economic_events.id` upon approval |
| `source_type` | `TEXT CHECK (...)` | `'sms'`, `'ocr'`, `'manual'`, etc. | Origin channel of evidence |
| `extracted_amount_minor_units` | `INTEGER` | Integer minor units | Extracted monetary value in paise |
| `extracted_timestamp` | `TEXT` | ISO-8601 | Extracted timestamp from the source |
| `sender_address` | `TEXT` | Sender ID (e.g., `HDFCBK`) | Source bank/service identifier |
| `external_reference` | `TEXT` | UTR / Bank Ref / UPI ID | External payment reference number |
| `body_sha256` | `TEXT NOT NULL` | 64-char hex string | Deterministic cryptographic fingerprint of raw body |
| `raw_payload_encrypted` | `TEXT` | Raw text | Raw body preserved for auditability |
| `retention_expires_at` | `TEXT` | `DateTime.now() + 30 days` | Automatic retention window boundary |
| `is_payload_purged` | `INTEGER` | `0` | Flag for retention expiration purge |
| `created_at` | `TEXT` | ISO-8601 | Ingestion timestamp |

---

### 5. ReviewCandidate Lifecycle

Candidates transition through a deterministic finite-state lifecycle:

```
          [ SMS / File Ingestion ]
                     │
                     ▼
                 ┌─────────┐
                 │ pending │ ◄── (0 postings, 0 events, 0 balance effect)
                 └────┬────┘
                      │
         ┌────────────┴────────────┐
         ▼                         ▼
   [ Explicit User Approval ]  [ User Rejection ]
         │                         │
         ▼                         ▼
   ┌──────────┐              ┌──────────┐
   │ approved │              │ rejected │
   └──────────┘              └──────────┘
         │                         │
   Creates Event & Postings    0 accounting entries
```

1. **Pending**: Pure proposal. Stored in `TablesV24.reviewCandidates`. Does not affect `CanonicalFinancialQueryRepository.getNetWorth()` or `getSafeToSpend()`.
2. **Approved**: The user accepts the proposal. Handled via `approveReviewProvider` / `FinancialTransactionService.createTransaction`:
   - Validates event balance via `EventBalanceValidator`.
   - Inserts `EconomicEvent` with `lifecycle_status = 'posted'`.
   - Inserts balanced `Posting` records (Debit Category, Credit Asset).
   - Marks candidate status as `approved` in `TablesV24.reviewCandidates`.
3. **Rejected**: The user dismisses the proposal. Marked as `rejected` in `TablesV24.reviewCandidates`. Produces zero postings and zero events.
4. **Duplicate**: Ingestion pipeline detects existing UTR or SHA-256 fingerprint; skips duplicate candidate creation.

---

### 6. Deduplication Mechanics

The deduplication pipeline in `LiveSmsService._alreadyInApp` and `ReviewRepo` enforces deterministic identity resolution:

1. **External Reference (UTR / Bank Ref)**: If `parsed.refId` is present and non-empty, checks `CanonicalEventRepository.getEvidenceByExternalReference(ref)`. If found, ingestion terminates immediately.
2. **Cryptographic SHA-256 Fingerprint**: Computes deterministic hash of raw message body. Checks `CanonicalEventRepository.getEvidenceByFingerprint(sha256)`. If found, message was already captured; skips ingestion.
3. **Canonical Posted Transactions**: Queries canonical events/postings via `TransactionRepo.findByAmountAndDateRange` within a 30-minute window with fuzzy merchant matching.
4. **Pending Review Proposals**: Queries `ReviewRepo.getPending()` (`TablesV24.reviewCandidates`) to match existing proposals by ref, hash, or amount/merchant within 60 minutes.
5. **Isolation from Legacy `transactions` Table**: No queries are made against legacy `transactions` table during deduplication. Rogue insertions directly into `transactions` have zero capability to suppress or influence ingestion deduplication.

---

### 7. Balance SMS Quarantine

Prior to C5, `LiveSmsService._applyBalance` performed direct mutations on bank accounts and credit cards:
```dart
// DEPRECATED & REMOVED (Pre-C5)
await AccountRepo().updateBalance(match.id, hit.amount);
await CreditRepo().update(match.copyWith(usedAmount: hit.amount));
```

Under C5, `_applyBalance` is strictly quarantined:
```dart
// CANONICAL C5 IMPLEMENTATION
Future<bool> _applyBalance(BalanceHit hit) async {
  try {
    final fingerprint = CanonicalTransactionAdapter.computeSha256(hit.body);
    final ev = Evidence(
      id: const Uuid().v4(),
      sourceType: 'sms',
      sourceIdentifier: hit.sender.isNotEmpty ? hit.sender : (hit.bankKeyword ?? 'sms'),
      sourceTimestamp: DateTime.now(),
      bodyFingerprint: fingerprint,
      extractedAmount: Money.fromRupees(hit.amount),
      accountContext: hit.last4 != null ? 'XX${hit.last4}' : hit.bankKeyword,
      rawPayloadEncrypted: hit.body,
      retentionExpiresAt: DateTime.now().add(const Duration(days: 30)),
      isPayloadPurged: false,
      economicEventId: null,
      createdAt: DateTime.now(),
    );
    await CanonicalEventRepository().insertEvidence(ev);
    return true;
  } catch (_) {
    return false;
  }
}
```
- Direct balance mutations from balance SMS: **STRICTLY 0**.
- Bank account balances and credit card outstandings are unmodified.
- Net Worth and Safe-to-Spend calculations are unmodified.
- The statement is recorded as an immutable `Evidence` record for reconciliation reference.

---

### 8. Write Elimination: Legacy `review_queue` Table Decommission

`ReviewRepo` (`lib/data/repositories/review_repo.dart`) has been refactored to delegate entirely to `CanonicalReviewRepository` (`TablesV24.reviewCandidates`) and `CanonicalEventRepository` (`TablesV24.evidence`):

| Operation | Pre-C5 Path | C5 Canonical Path | Runtime Legacy Writes |
|---|---|---|---|
| `getPending()` | `SELECT FROM review_queue` | `canonicalReviewRepo.listCandidates(...)` | 0 |
| `getById(id)` | `SELECT FROM review_queue` | `canonicalReviewRepo.getCandidate(id)` | 0 |
| `getPendingCount()` | `SELECT COUNT FROM review_queue` | `canonicalReviewRepo.getPendingCount()` | 0 |
| `insert(item)` | `INSERT INTO review_queue` | `insertEvidence` + `createCandidate` | **0** |
| `insertAll(items)` | `INSERT INTO review_queue` | Batch canonical evidence + candidates | **0** |
| `approve(id)` | `UPDATE review_queue SET status='approved'` | `canonicalReviewRepo.approveCandidate(id)` | **0** |
| `reject(id)` | `UPDATE review_queue SET status='rejected'` | `canonicalReviewRepo.rejectCandidate(id)` | **0** |
| `rejectAll()` | `UPDATE review_queue SET status='rejected'` | `canonicalReviewRepo.rejectAllPending()` | **0** |
| `deleteApproved()` | `DELETE FROM review_queue` | `canonicalReviewRepo.deleteApproved()` | **0** |

Runtime writes to `Tables.reviewQueue` across the entire application are **0**.

---

### 9. Downstream Safety: Zero Premature Accounting Impact

To verify that unconfirmed candidates never leak into financial reports, the pipeline guarantees:
1. `postings` table: 0 rows added during ingestion.
2. `economic_events` table: 0 rows added during ingestion.
3. `CanonicalFinancialQueryRepository.getNetWorth()`: Unchanged before vs after ingestion.
4. `CanonicalFinancialQueryRepository.getSafeToSpend()`: Unchanged before vs after ingestion.
5. Ingestion proposals only become accounting state upon explicit user confirmation routed through `FinancialTransactionService`.

---

### 10. Invariant Conformance Matrix

| # | Invariant | Enforcement Mechanism | Status |
|---|---|---|---|
| 1 | SMS creates canonical Evidence | `ReviewRepo.insert` inserts to `TablesV24.evidence` | **PASS** |
| 2 | Deterministic SHA-256 fingerprint | `CanonicalTransactionAdapter.computeSha256(rawText)` | **PASS** |
| 3 | SMS creates canonical ReviewCandidate | `ReviewRepo.insert` inserts to `TablesV24.reviewCandidates` | **PASS** |
| 4 | Runtime SMS writes zero rows to legacy `review_queue` | `ReviewRepo` delegates only to v24 tables | **PASS** |
| 5 | SMS ingestion creates zero postings | No `Posting` records written until user approval | **PASS** |
| 6 | SMS ingestion creates zero EconomicEvents | No `EconomicEvent` records written until user approval | **PASS** |
| 7 | Net Worth unaffected before approval | Verified against `CanonicalFinancialQueryRepository.getNetWorth()` | **PASS** |
| 8 | Safe-to-Spend unaffected before approval | Verified against `CanonicalFinancialQueryRepository.getSafeToSpend()` | **PASS** |
| 9 | Duplicate SMS does not duplicate identity | Deduplication checks evidence ref, hash, and candidates | **PASS** |
| 10 | UTR matching behaves deterministically | `getEvidenceByExternalReference` matches exact reference | **PASS** |
| 11 | Balance SMS creates zero bank-balance mutation | `_applyBalance` stores `Evidence`, mutates 0 accounts | **PASS** |
| 12 | Legacy transaction insertion cannot influence dedup | Deduplication queries canonical evidence & events only | **PASS** |
| 13 | Rejected candidate creates zero accounting effects | Rejection sets candidate status; 0 events/postings created | **PASS** |
| 14 | Approved candidate routes through FinancialTransactionService | Approval converts candidate via `FinancialTransactionService` | **PASS** |
| 15 | Approved candidate creates balanced postings | Verified: debit equals credit, net worth updates | **PASS** |
| 16 | Multiple evidence records for single event supported | Multiple `Evidence` rows can point to same event ID without duplicate postings | **PASS** |
| 17 | Legacy `review_queue` cannot become authority | Rogue inserts to legacy `review_queue` ignored by `ReviewRepo` | **PASS** |
| 18 | Canonical evidence survives legacy state mutations | Deleting/modifying legacy tables leaves canonical `Evidence` intact | **PASS** |

---

### 11. Adversarial Test Results

File: `test/features/canonical_ingestion_pipeline_test.dart`

```
00:03 +17: All tests passed!
```

- **Total Invariant Tests**: 17 tests (covering all 18 invariants)
- **Passed**: 17 / 17 (100%)
- **Failed**: 0
- **Execution Time**: ~3.5 seconds

---

### 12. Full Project Regression Suite Status

```
00:29 +566: All tests passed!
```

- **Pre-C5 Test Baseline**: 549 tests
- **C5 Ingestion Pipeline Tests**: 17 tests
- **Total Project Tests**: 566 tests
- **Pass Rate**: 566 / 566 (100%)
- **Regressions**: 0

---

### 13. Static Analysis Audit

Command: `flutter analyze`

```
Analyzing SpendX...
No errors found.
No warnings found.
(29 legacy infos: deprecated members / info lints in pre-existing test files)
```

- **Errors**: 0
- **Warnings**: 0

---

### 14. SQLite Trigger & Schema State

- **Database Schema**: v24 LOCKED
- **SQLite Triggers**: 7/7 ACTIVE
  1. `trg_prevent_posted_event_mutation`
  2. `trg_prevent_posted_event_deletion`
  3. `trg_prevent_posting_insert_on_posted_event`
  4. `trg_prevent_posting_mutation_on_posted_event`
  5. `trg_prevent_posting_deletion_on_posted_event`
  6. `trg_prevent_account_deletion_with_postings`
  7. `trg_enforce_evidence_retention`

---

### 15. File Modification Registry

| File | Nature of Modification |
|---|---|
| `lib/data/repositories/canonical/canonical_event_repository.dart` | Added `insertEvidence`, `getEvidenceByExternalReference`, `getEvidenceByFingerprint`, optional executor in `_getExecutor` |
| `lib/data/repositories/canonical/canonical_review_repository.dart` | Added `getPendingCount`, `rejectAllPending`, `deleteApproved` |
| `lib/data/repositories/canonical/canonical_transaction_adapter.dart` | Sanitized `sourceType` mapping in `toEvidence` to satisfy SQLite CHECK constraint |
| `lib/data/repositories/review_repo.dart` | Complete architectural refactor to delegate to canonical repositories (`TablesV24.reviewCandidates`, `TablesV24.evidence`); eliminated legacy `review_queue` queries |
| `lib/services/live_sms_service.dart` | Implemented canonical deduplication in `_alreadyInApp`; disarmed `_applyBalance` of direct balance mutations; replaced with canonical `Evidence` persistence |
| `lib/screens/sms_import_screen.dart` | Removed silent balance/outstanding mutations on existing accounts/cards during auto-registration |
| `test/features/canonical_ingestion_pipeline_test.dart` | Authored 18-invariant comprehensive adversarial test suite |
| `docs/spendx2/65_C5_ARCHITECTURAL_GATE_AND_EXECUTION_SPEC.md` | Authored formal C5 specification & gate |
| `docs/spendx2/66_C5_MULTI_EVIDENCE_INGESTION_MIGRATION.md` | This deliverable implementation report |

---

### 16. Hard Stop Declaration

Milestone **C5: Multi-Evidence Ingestion & Deduplication Pipeline Migration** is fully implemented, verified, and complete.

In strict compliance with instructions:
- **HARD STOP REACHED.**
- No work has commenced on Milestone C6 or any subsequent milestone.
- System is idle and awaiting formal user authorization.
