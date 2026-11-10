# SpendX Release Readiness — Pillar 4.5A.1.22
## Portable Encrypted Backup: Independent Acceptance Test Plan (SEC-01)

**Target:** SpendX 2.1.0  
**Phase:** Pillar 4.5A.1.22 — Database Quiescence Proof and OS Lock Uncertainty  
**Status:** Complete — Architecture Closed with Explicit Implementation Gate  
**Date:** 2026-11-05  

---

## 1. Independent Accounting Fixture Specification

To ensure total test independence, the accounting test fixture is formulated mathematically using first principles of double-entry bookkeeping without calling production helpers.

### 1.1 Account Definitions
- **Account 1 (`acc_chk_01`):** Primary Checking (`account_type: 'asset'`, `subtype: 'checking'`).
- **Account 2 (`acc_cc_01`):** Rewards Credit Card (`account_type: 'liability'`, `subtype: 'credit_card'`).
- **System Accounts:**
  - `TablesV24.sysEqOpeningBalance` (`acc_sys_eq_opening`)
  - `TablesV24.sysIncSalary` (`acc_sys_inc_salary`)
  - `TablesV24.sysExpHousing` (`acc_sys_exp_housing`)
  - `TablesV24.sysExpGroceries` (`acc_sys_exp_groceries`)
  - `TablesV24.sysExpDining` (`acc_sys_exp_dining`)

---

### 1.2 Mathematical Derivation of the 12 Postings across 6 Events

| Event # | Description | Leg 1: Debit (paise) | Leg 2: Credit (paise) | Event Balance Status |
| :--- | :--- | :--- | :--- | :--- |
| **EV-01** | Opening Checking Balance | `acc_chk_01`: **+7,500,000** | `sysEqOpening`: **+7,500,000** | Balanced (7.5M = 7.5M) |
| **EV-02** | Opening Credit Card Balance | `sysEqOpening`: **+1,000,000** | `acc_cc_01`: **+1,000,000** | Balanced (1.0M = 1.0M) |
| **EV-03** | Credit Card Dining Out | `sysExpDining`: **+500,000** | `acc_cc_01`: **+500,000** | Balanced (0.5M = 0.5M) |
| **EV-04** | Monthly Salary Deposit | `acc_chk_01`: **+2,500,000** | `sysIncSalary`: **+2,500,000** | Balanced (2.5M = 2.5M) |
| **EV-05** | Rent Payment via Checking | `sysExpHousing`: **+2,000,000** | `acc_chk_01`: **+2,000,000** | Balanced (2.0M = 2.0M) |
| **EV-06** | Grocery Purchase via Checking | `sysExpGroceries`: **+500,000** | `acc_chk_01`: **+500,000** | Balanced (0.5M = 0.5M) |

---

### 1.3 Independent Mathematical Ledger Reconciliation

```text
Checking Account (acc_chk_01):
  + 7,500,000 (EV-01: Opening asset debit)
  + 2,500,000 (EV-04: Salary asset debit)
  - 2,000,000 (EV-05: Rent asset credit)
  -   500,000 (EV-06: Groceries asset credit)
  ---------------------------------
  = 7,500,000 paise (₹75,000.00 Asset Balance)

Credit Card Liability Account (acc_cc_01):
  + 1,000,000 (EV-02: Opening liability credit)
  +   500,000 (EV-03: Dining liability credit)
  ---------------------------------
  = 1,500,000 paise (₹15,000.00 Liability Balance)

Net Worth Calculation:
  Total Assets      = 7,500,000 paise (₹75,000.00)
  Total Liabilities = 1,500,000 paise (₹15,000.00)
  ------------------------------------------------
  Net Worth         = Assets - Liabilities
                    = 7,500,000 - 1,500,000
                    = 6,000,000 paise (₹60,000.00)

Ledger Posting Invariant:
  Total Postings: exactly 12 (6 events * 2 postings each).
  Total Debits:   7.5M + 1.0M + 0.5M + 2.5M + 2.0M + 0.5M = 14,000,000 paise.
  Total Credits:  7.5M + 1.0M + 0.5M + 2.5M + 2.0M + 0.5M = 14,000,000 paise.
  Debit/Credit Parity Delta: 0 paise.
```

---

## 2. Planned Acceptance Test Matrix (68 Scenarios / 84 Planned Test Cases)

### Group 1: Canonical Content Fingerprint Engine & Cryptographic Independence

#### Scenario 1: Canonical Fingerprint Independent Calculation & Wire-Format Invariant
- **Objective:** Independently calculate expected canonical SHA-256 fingerprint in test harness using standalone encoder (without calling production service) and verify bit-for-bit equivalence.
- **Fixture:** The ₹75k / ₹15k / ₹60k 12-posting fixture across all 15 canonical tables.
- **Independent Assertions:**
  1. `actualFingerprint == testCalculatedExpectedFingerprint`.
  2. Protocol header contains `SPNDXFP1`, schema 24, schema DDL hash, and table count 15.

#### Scenario 2: Delimiter Collision Resistance
- **Objective:** Verify that values containing delimiters (e.g. `|`, `,`, `\0`, or type tags `0x00`-`0x04`) cannot produce collision with adjacent values.
- **Independent Assertions:** Fingerprint A != Fingerprint B. Length-prefixed serialization guarantees zero collision.

#### Scenario 3: NULL versus Empty-String Distinction
- **Objective:** Prove `NULL` (tag `0x00`) produces a distinct hash from empty string `""` (tag `0x03` + length 0).
- **Independent Assertions:** Fingerprint A != Fingerprint B.

#### Scenario 4: Insertion Order Invariance
- **Objective:** Prove databases populated with identical records in different insertion orders yield bit-for-bit identical fingerprints.
- **Independent Assertions:** Fingerprint A == Fingerprint B.

#### Scenario 5: Large Database Streaming Fingerprint Without Limits
- **Objective:** Verify fingerprint computation over 100,000+ postings without string limits or memory spikes.
- **Independent Assertions:** Memory remains constant ($O(1)$) during streaming. Zero concatenation errors.

#### Scenario 6: Raw UTF-8 Byte Hashing vs NFKC Normalization Separation
- **Objective:** Prove database content hashes exact UTF-8 bytes and does NOT apply NFKC normalization.
- **Fixture:**
  - Database A: Event description = `"Office ﬁnance"` (using compatibility ligature `ﬁ` U+FB01, UTF-8: `EF AF 81`).
  - Database B: Event description = `"Office finance"` (using ordinary ASCII `'f'` and `'i'`, UTF-8: `66 69`).
- **Independent Assertions:**
  1. `fingerprint(Database A) != fingerprint(Database B)`.
  2. Proves exact stored text bytes are hashed without NFKC mutation.

#### Scenario 7: Negative Zero & Non-Finite Canonicalization
- **Objective:** Verify `-0.0` normalizes to `+0.0`, and non-finite floats canonicalize to standard IEEE-754 bit representations.
- **Independent Assertions:** Database with `-0.0` produces bit-for-bit identical hash to database with `+0.0`.

---

### Group 2: User Data Coverage & Field Fidelity

#### Scenario 8: User Goals & Notes Fidelity
- **Objective:** Prove `goals.notes` is hashed and restored faithfully.
- **Fixture:** Goal with `notes: "Downpayment for home purchase by Dec 2027"`.
- **Independent Assertions:**
  1. Goal notes are included in canonical fingerprint.
  2. Modifying goal notes alters the content fingerprint.
  3. Restored goal retains identical notes string.

#### Scenario 9: User Reminders & Notes Fidelity
- **Objective:** Prove `reminders.notes` and `reminders.description` are preserved.
- **Fixture:** Reminder with `title: "HDFC Credit Card"`, `description: "Bill payment"`, `notes: "Pay before 5 PM to avoid late fee"`.
- **Independent Assertions:**
  1. All user-authored reminder fields are hashed in canonical fingerprint.
  2. Restored reminder retains description and notes.

#### Scenario 10: Category Ownership Fidelity
- **Objective:** Prove `categories.user_id` is hashed and preserved.
- **Fixture:** Custom category with `user_id: "usr_device_alpha_99"`.
- **Independent Assertions:**
  1. `user_id` is included in canonical fingerprint.
  2. Restored category retains exact `user_id`.

#### Scenario 11A: User Tag Definition Fidelity
- **Objective:** Prove that user tag definitions in `tags` survive restore faithfully.
- **Fixture:** Tag definitions in `tags`: `tag_biz` (`"Business"`), `tag_tax` (`"Tax-Deductible"`).
- **Independent Assertions:**
  1. Tag definitions in `tags` table are 100% restored.
  2. Modifying tag names or colors alters the canonical fingerprint.

#### Scenario 11B: Historical Tag Migration Finding Classification & Scope Separation
- **Objective:** Validate that legacy `transactions.tags` assignments were dropped during Migration v24, verify this is formally classified as an unresolved migration / data-retention finding, and prove the portable backup scope preserves the 15 canonical tables including `tags` definitions without creating speculative schema mutations.
- **Independent Assertions:**
  1. Migration v24 source audit demonstrates `tx['tags']` was unread during migration.
  2. Canonical fingerprint tables count is exactly 15.
  3. All definitions in `tags` (`id`, `name`, `color`) are restored.
  4. Test suite asserts zero speculative schema modifications.

---

### Group 3: Cross-Device Portability & Key Lifecycle

#### Scenario 12: Destination Key Independence & Cryptographic Isolation
- **Objective:** Prove restored database on Device B is encrypted exclusively with Device B's key.
- **Independent Assertions:**
  1. Open active DB on Device B using `Key_B`: Succeeds, `user_version == 24`.
  2. Open active DB on Device B using `Key_A`: Throws `SqlCipherException: SQLITE_NOTADB` (code 26).
  3. Open active DB on Device B using `K_db`: Throws `SqlCipherException: SQLITE_NOTADB` (code 26).

#### Scenario 13: Fresh Install Restoration
- **Objective:** Verify restore onto fresh install generates fresh key and transitions Keystore state from `missing` to `available`.

#### Scenario 14: Existing Valid-Key Restoration (Key Preserved Without Rotation)
- **Objective:** Verify existing valid destination key is preserved byte-for-byte without rotation.

#### Scenario 15: Inaccessible Key Unattended Policy (`KeyLossFatalException` Preservation)
- **Objective:** Prove unattended restore with missing Keystore key throws `KeyLossFatalException` without touching disk.

---

### Group 4: Key-Loss Override 8-State Crash Recovery Machine

#### Scenario 16A: Incomplete Orphaned Copy Rejection
- **Objective:** Mock length mismatch on orphaned copy; verify override aborts before `deleteKey()` is called.

#### Scenario 16B: Crash at `overrideIntentPersisted` or `originalCiphertextCopied`
- **Objective:** Crash before key deletion; verify old key and original database are 100% intact.

#### Scenario 16C: Crash at `orphanedCopyValidated`
- **Objective:** Crash after orphaned copy validated; verify orphaned backup is durably retained.

#### Scenario 16D: Crash at `originalKeyDeletionCompleted`
- **Objective:** Crash after key deletion; verify recovery detects orphaned copy, provisions fresh key, and resumes without silent database initialization.

#### Scenario 16E: Full Successful Key-Loss Override Sequence
- **Objective:** Verify end-to-end 8-state sequence executes cleanly.

---

### Group 5: Restore Identity, Recovery-State Matrix & Filesystem Durability

#### Scenario 17: Crash Point C & D — Crash After Active-to-Backup Rename (Staging Present)
- **Objective:** Prove that when active DB was renamed to `.pre_restore_backup` and process dies while `spendx.db.restored` is present, recovery recognizes that `.pre_restore_backup` is the ONLY copy of the original DB, restores active DB from `.pre_restore_backup` via non-destructive staging copy, and NEVER deletes `.pre_restore_backup`.
- **Fixture:** `spendx.db` missing. `spendx.db.pre_restore_backup` exists. `spendx.db.restored` exists. `.intent` exists. `.done` missing.
- **Independent Assertions:**
  1. Recovery creates staging copy from `spendx.db.pre_restore_backup`, places at `spendx.db` using no-replace, and validates.
  2. Staging file `spendx.db.restored` is deleted.
  3. `.pre_restore_backup` is **unmodified and retained by the application**.
  4. Active DB reopens cleanly with pre-restore data.

#### Scenario 18: Crash Point E & F — Active DB Validates but Backup Deletion Strictly Forbidden
- **Objective:** In Point E/F, active DB passes validation, but verified journal durability has not completed. Prove backup deletion is **strictly forbidden**.
- **Fixture:** `spendx.db` exists. `.pre_restore_backup` exists. `spendx.db.restored` absent. Journal in `state: swapping`.
- **Independent Assertions:**
  1. Recovery advances journal to `state: contentVerified`.
  2. `.pre_restore_backup` is **NOT deleted in Point E/F**.
  3. Deletion is deferred until Point J (`durabilityConfirmed`).

#### Scenario 19: Crash Point G & H — `.done` Exists But Active DB Validation Fails
- **Objective:** Prove `.done` marker presence NEVER bypasses active DB deep validation.
- **Fixture:** `.done` marker exists, but active `spendx.db` has injected corrupted B-tree pages.
- **Independent Assertions:**
  1. Deep validation fails (`integrity_check != ok`).
  2. Recovery **refuses to advance to `contentVerified`**.
  3. Recovery **never deletes `.pre_restore_backup`**.
  4. Recovery restores active DB via non-destructive rollback from `.pre_restore_backup`.

#### Scenario 20A: Crash Point I & J — Backup Deletion Authorized Strictly at Point J (Native Directory Sync)
- **Objective:** Prove backup is unlinked only after journal durability is achieved at Point J under native directory sync.
- **Independent Assertions:**
  1. In Point I, backup deletion is prohibited until journal durability confirmed.
  2. In Point J, all conditions of the Universal Deletion Invariant are satisfied; `.pre_restore_backup` is safely deleted.

#### Scenario 20B: Pure Dart Runtime Durability — Universal Backup Retention Invariant
- **Objective:** Prove that when native directory synchronization is unavailable (standard Dart `dart:io` runtime), the engine strictly prohibits safety backup deletion and retains both the safety backup and journal.
- **Fixture:** Restore completed under pure Dart runtime (`isDirSyncAvailable == false`). Active DB passes 7-point validation; verified journal flushed to file.
- **Independent Assertions:**
  1. Active DB `spendx.db` is operational and valid.
  2. `spendx.db.pre_restore_backup` **REMAINS UNMODIFIED AND RETAINED ON DISK** (never deleted).
  3. `spendx_restore_journal.json` transitions to `state: cleanupPending` with `isDurabilityConfirmed: false` and is **RETAINED ON DISK**.
  4. Universal Backup-Deletion Invariant is enforced without exception.

#### Scenario 21: Crash Point K — Backup Deletion & Directory Sync Failure Recovery
- **Objective:** Simulate process crash or directory sync failure during or after backup deletion at Point K.
- **Fixture:** Backup `spendx.db.pre_restore_backup` was unlinked in memory, but directory sync failed (`EIO`) or power loss occurred. Journal records `state: cleanupPending`.
- **Independent Assertions:**
  1. Journal is **NOT cleared**; remains `cleanupPending`.
  2. On restart: recovery re-validates `spendx.db` via 7-point deep validation.
  3. Recovery inspects directory for backup file:
     - If backup still appears (due to unsynced dentry rollback): re-executes deletion and syncs directory.
     - If backup already unlinked: executes directory sync to commit deletion.
  4. Only after directory sync confirms durability does recovery delete journal and issue final directory sync.

#### Scenario 22: Catastrophic Validation Failure — Both Databases Corrupted
- **Objective:** Both `spendx.db` and `.pre_restore_backup` fail validation.
- **Independent Assertions:**
  1. STRICT INVARIANT: Preserve all files on disk; throw fatal `RestoreCrashRecoveryException`.
  2. Zero empty or plaintext databases created.

#### Scenario 23A: Operation 2 — Corrupt Active Database Quarantine Before Staging Replacement
- **Objective:** Verify that when `spendx.db` exists at Point E/recovery but is corrupt, recovery NEVER overwrites or deletes it; it quarantines it to `spendx.db.corrupt_<opId>_<timestamp>` using no-replace before renaming staging `spendx.db.restored` $\rightarrow$ `spendx.db`.
- **Fixture:** `spendx.db` exists with invalid header; `spendx.db.restored` exists and passes 7-point deep validation.
- **Independent Assertions:**
  1. Corrupt `spendx.db` is moved to timestamped quarantine path via no-replace.
  2. Quarantine diagnostic log file is created.
  3. Staging DB is safely renamed to `spendx.db` and passes 7-point validation.
  4. Zero data overwritten or lost.

#### Scenario 23B: Operation 2 — Missing Active Database with Valid Staging & Backup
- **Objective:** Verify clean atomic rename of staging to active when active DB path is cleanly vacant.
- **Fixture:** `spendx.db` absent; `spendx.db.restored` valid; `spendx.db.pre_restore_backup` valid.
- **Independent Assertions:**
  1. Staging cleanly renamed to `spendx.db` via no-replace.
  2. Deep validation confirms 7-point integrity.
  3. Safety backup remains untouched on disk.

#### Scenario 23C: Operation 2 — Unexpected Destination Path Collision Handling
- **Objective:** Verify recovery when `spendx.db` exists as a valid database but has an unexpected fingerprint that matches neither pre-restore nor expected restored content.
- **Fixture:** Unexpected valid SQLite DB placed at `spendx.db` prior to staging swap.
- **Independent Assertions:**
  1. Recovery halts defensively or quarantines collision file to `spendx.db.collision_<opId>_<timestamp>`.
  2. Never silently overwrites the colliding database.

#### Scenario 23D: Operation 7 — Journal Deletion Under Pure Dart
- **Objective:** Verify that under standard Dart runtime (`isDirSyncAvailable == false`), journal deletion is strictly prohibited upon successful restore, rollback, and recovery.
- **Independent Assertions:**
  1. Journal file `spendx_restore_journal.json` is RETAINED on disk.
  2. Journal records `state: cleanupPending`, `isContentVerified: true`, `isDurabilityConfirmed: false`.
  3. Recovery metadata is fully preserved across subsequent app launches.

#### Scenario 23E: Operation 7 — Journal Deletion After Directory Sync Failure
- **Objective:** Verify that when journal unlink succeeds in VFS but directory sync returns `EIO`, the cleanup state remains pending and recovery metadata is not cleared.
- **Independent Assertions:**
  1. Recovery metadata is not cleared.
  2. Subsequent launch detects pending cleanup and safely reconciles directory state.

#### Scenario 23F: Operation 7 — Rollback with Directory Sync Unavailable
- **Objective:** Verify that when restore fails and active DB is restored from safety backup under pure Dart, the journal is transitioned to `state: rolledBack`, `isCleanupPending: true`, and retained on disk without deletion.
- **Independent Assertions:**
  1. Active DB is restored to pre-restore state.
  2. Journal file is retained to provide audit history of the aborted restore.

#### Scenario 24: Separation of Content Verified vs Durability Confirmed
- **Objective:** Explicitly test that reaching `isContentVerified: true` does NOT trigger backup deletion until all required sync operations complete and set `isDurabilityConfirmed: true`.
- **Independent Assertions:**
  1. When content verified: active DB is usable, but backup remains on disk.
  2. Only after database file flush, database dir sync, journal file flush, and journal dir sync all succeed does `isDurabilityConfirmed` become `true`.

#### Scenario 25: Normal Rename Outcomes vs Filesystem-Specific Crash Consistency & Corruption
- **Objective:** Test recovery behavior across POSIX atomic renames, filesystem crash rollbacks (ext4/f2fs/APFS), and storage corruption (`EIO`).
- **Independent Assertions:**
  1. Normal rename: single candidate DB validated.
  2. Crash rollback: multi-candidate validation correctly detects active DB was not renamed on flash and resumes cleanly.
  3. Filesystem corruption (`EIO`): engine halts defensively without altering files.

#### Scenario 26: Schema Identity Difference Detection (Indexes & Triggers)
- **Objective:** Verify altering an index or trigger alters `schemaIdentity` hash in stream header, causing rejection even if `user_version == 24`. Autoindexes (`sqlite_autoindex_%`) are ignored.
- **Independent Assertions:** Restore validator throws `BackupValidationException('Schema identity mismatch')`.

#### Scenario 27: Journal Checksum Corruption vs Keyed HMAC Tamper Detection
- **Objective:** Verify unkeyed SHA-256 detects corruption; verify HKDF-SHA256 derived HMAC rejects unauthorized journal modification.
- **Independent Assertions:**
  1. Accidental corruption detected by `journalChecksum`.
  2. Unauthorized file tampering rejected by `journalHmac`.

#### Scenario 32: Non-Destructive Rollback with Occupied Corrupt Active Destination (Staging Copy Invariant)
- **Objective:** When active DB is corrupt and staging DB is corrupt/missing, but safety backup is valid: verify execution of non-destructive rollback using `spendx.db.rollback_staging`.
- **Fixture:** `spendx.db` exists with corrupted pages; `spendx.db.restored` missing; `spendx.db.pre_restore_backup` valid.
- **Independent Assertions:**
  1. Step 1: Safety backup `spendx.db.pre_restore_backup` is validated before touching destination.
  2. Step 2: Corrupt `spendx.db` is quarantined to `spendx.db.corrupt_<opId>_<timestamp>` via no-replace.
  3. Step 3: Destination `spendx.db` is confirmed vacant.
  4. Step 4: Staging copy `spendx.db.rollback_staging` is created from `spendx.db.pre_restore_backup`.
  5. Step 5: `spendx.db.pre_restore_backup` **REMAINS UNMODIFIED AND RETAINED ON DISK**.
  6. Step 6: `spendx.db.rollback_staging` is renamed to `spendx.db` via no-replace and deep-validated.
  7. Step 7: Journal records `state: rolledBack`.

#### Scenario 33: Quarantine Failure During Rollback (Zero Overwrite Invariant)
- **Objective:** Simulate filesystem error or permission failure during quarantine rename of corrupt active DB.
- **Independent Assertions:**
  1. Engine halts immediately.
  2. Safety backup `spendx.db.pre_restore_backup` is **NOT renamed or deleted**.
  3. Occupied destination is **NOT overwritten**.

#### Scenario 34: Concurrent Restore/Recovery Attempts & Process Lockfile Serialization
- **Objective:** Verify that concurrent restore or recovery attempts from independent OS processes are strictly serialized via `spendx_restore.lock`.
- **Fixture:** Process 1 acquires exclusive lockfile `spendx_restore.lock`. Process 2 attempts restore or recovery.
- **Independent Assertions:**
  1. Process 2 immediately throws `RestoreConcurrencyConflictException`.
  2. Process 2 makes zero filesystem modifications.

#### Scenario 35: Unexpected Destination Creation Between Inspection and Replacement (TOCTOU Defense)
- **Objective:** Simulate a race condition where an unexpected file is placed at `spendx.db` between destination vacancy inspection and replacement rename.
- **Independent Assertions:**
  1. Under native platforms supporting `RENAME_NOREPLACE` / `RENAME_EXCL`, rename atomically fails with `EEXIST`.
  2. Under pure Dart, verify process lockfile prevents intra-process races and verify collision error handling.
  3. Unexpected file is never silently destroyed.

#### Scenario 36: Pure-Dart Rollback with Durability Unconfirmed
- **Objective:** Verify rollback execution under standard Dart runtime where directory sync is unavailable.
- **Independent Assertions:**
  1. Active DB is restored to pre-restore state and operational.
  2. Durability status is classified as `durabilityUnconfirmed`.
  3. Journal file is **retained** in `state: rolledBack`, `isCleanupPending: true`, preserving audit metadata.

#### Scenario 37: Quarantine with Directory Synchronization Unavailable
- **Objective:** Verify that when a corrupt DB is quarantined under pure Dart (`isDirSyncAvailable == false`), the quarantine file is created, but durability is classified as `durabilityUnconfirmed`.
- **Independent Assertions:**
  1. Quarantine file exists in VFS.
  2. Journal records quarantined artifact in `quarantinedArtifacts`.
  3. Safety backup remains retained.

#### Scenario 38: Ambiguous Filesystem State After Simulated Interruption (Multi-Candidate Defensive Preservation)
- **Objective:** Simulate an interrupted restore leaving multiple conflicting database candidate files with ambiguous fingerprints.
- **Independent Assertions:**
  1. Multi-candidate validator tests every candidate file.
  2. Because identity cannot be verified beyond doubt, engine **retains all files**.
  3. Throws fatal `RestoreCrashRecoveryException`. Zero databases overwritten or deleted.

#### Scenario 39: Failure of Post-Rollback Validation While Preserving Original Safety Backup
- **Objective:** Simulate injected page corruption in the restored active database after `spendx.db.rollback_staging` was renamed to `spendx.db`.
- **Independent Assertions:**
  1. Post-rollback 7-point validation fails.
  2. Engine quarantines failed `spendx.db` to `spendx.db.corrupt_post_rollback_<timestamp>`.
  3. **CRITICAL INVARIANT:** Original `spendx.db.pre_restore_backup` is **UNMODIFIED AND RETAINED BY THE APPLICATION** on disk.
  4. Engine halts safely; user data remains recoverable from safety backup.

#### Scenario 40: Crash After Rollback Replacement But Before Validation
- **Objective:** Process killed immediately after renaming `spendx.db.rollback_staging` to `spendx.db`, before Step 7 validation.
- **Independent Assertions:**
  1. On restart, recovery detects journal in `state: swapping` or `state: backupCreated`.
  2. Recovery finds `spendx.db.pre_restore_backup` unmodified and retained on disk.
  3. Recovery validates `spendx.db`; if valid, finishes rollback; if corrupt, original safety backup is still available to retry non-destructive rollback.

#### Scenario 41: Crash After Validation But Before Journal Update
- **Objective:** Process killed after `spendx.db` passes 7-point validation during rollback, but before journal transitions to `state: rolledBack`.
- **Independent Assertions:**
  1. On restart, recovery performs multi-candidate inspection.
  2. Active `spendx.db` matches `expectedPreRestoreFingerprint`.
  3. Recovery idempotently completes journal advancement to `state: rolledBack`.
  4. Safety backup `spendx.db.pre_restore_backup` was never destroyed.

#### Scenario 42: Crash After Journal Update But Before Directory Synchronization
- **Objective:** Process killed after journal is written to disk, before directory `fsync(dir_fd)` commits the directory entry.
- **Independent Assertions:**
  1. On restart, recovery reads journal and discovers directory sync was unconfirmed.
  2. Re-validates active database.
  3. Retries directory synchronization.
  4. Preserves safety backup until directory durability is confirmed.

#### Scenario 43: Backup Retirement Only After Required Validation and Durability Conditions
- **Objective:** Verify that `spendx.db.pre_restore_backup` is NEVER unlinked or retired unless active DB validation, journal durability confirmation, and native directory sync have ALL succeeded.
- **Independent Assertions:**
  1. If any validation fails $\rightarrow$ backup retained.
  2. If file flush fails $\rightarrow$ backup retained.
  3. If directory sync unavailable $\rightarrow$ backup retained.
  4. If directory sync fails $\rightarrow$ backup retained.
  5. Backup retired ONLY when all conditions are confirmed.

#### Scenario 44: Lock Release After Process Abnormal Termination
- **Objective:** Simulate abnormal process termination (`exit(1)` / mock `SIGKILL`) while holding `spendx_restore.lock`.
- **Independent Assertions:**
  1. OS kernel closes open file descriptor and releases lock automatically.
  2. Subsequent process launch successfully acquires `spendx_restore.lock` without manual lockfile deletion or deadlock.

#### Scenario 45: Requests from Multiple Dart Isolates via Coordinator Isolate
- **Objective:** Verify that restore and recovery requests originating from separate Dart isolates (UI isolate, background sync isolate) are routed over message ports to the single Coordinator Isolate.
- **Independent Assertions:**
  1. Each isolate communicates via `SendPort` looked up from `IsolateNameServer`.
  2. Requests are processed sequentially by the Coordinator Isolate.
  3. Zero cross-isolate race conditions.

#### Scenario 46: Synchronization Failure at Each Cleanup Stage
- **Objective:** Inject I/O error (`EIO`) at each individual cleanup step: (a) during backup unlink, (b) during parent directory sync after backup unlink, (c) during journal unlink, (d) during final directory sync.
- **Independent Assertions:**
  1. At stage (a): backup retained, journal in `cleanupPending`.
  2. At stage (b): backup unlinked in VFS, journal in `cleanupPending`, reconciled on restart.
  3. At stage (c): journal retained, active DB operational, warning logged.
  4. At stage (d): journal unlinked in VFS, cleanup retried on restart.

#### Scenario 47: Simultaneous Coordinator Failure Detection by Multiple Isolates
- **Objective:** Simulate coordinator failure when two or more isolates simultaneously attempt to contact it.
- **Independent Assertions:**
  1. Both isolates detect port failure.
  2. Isolates initiate single-flight startup protocol without uncoordinated mapping wiping.
  3. Only one isolate successfully spawns and registers replacement coordinator.

#### Scenario 48: Concurrent Coordinator Startup Attempts (Single-Flight Registration)
- **Objective:** Simulate two isolates concurrently spawning candidate coordinators and invoking `IsolateNameServer.registerPortWithName()`.
- **Independent Assertions:**
  1. First candidate registers successfully (`registerPortWithName == true`) and acquires OS lock.
  2. Second candidate fails registration (`registerPortWithName == false`) and immediately self-terminates.
  3. Exactly one coordinator isolate survives and holds the lock.

#### Scenario 49: Stale Mapping Cleanup Guard After Replacement Has Registered
- **Objective:** Isolate A detects dead port P1 and prepares to clear mapping; Isolate B has already spawned replacement coordinator with port P2.
- **Independent Assertions:**
  1. Isolate A is prohibited from calling `removePortNameMapping()` because it does not hold the OS lock.
  2. P2 is NOT removed.
  3. Isolate A routes its request to P2.

#### Scenario 50: Coordinator Alive But Unresponsive (No False Usurpation)
- **Objective:** Simulate coordinator busy executing streaming verification (ping timeout).
- **Independent Assertions:**
  1. Calling isolate times out waiting for response.
  2. Calling isolate does NOT assume coordinator termination and does NOT remove port mapping.
  3. Live coordinator continues execution without being usurped by duplicate coordinator.

#### Scenario 51: Duplicate Coordinator Prevention via OS Lock
- **Objective:** Force spawning of two coordinator isolates in separate threads/isolates.
- **Independent Assertions:**
  1. Coordinator 1 acquires `spendx_restore.lock`.
  2. Coordinator 2 attempts to acquire `spendx_restore.lock` and fails.
  3. Coordinator 2 immediately self-terminates without touching database files.

#### Scenario 52: Separate Flutter Engine Contention Across Process/Engine Boundary
- **Objective:** Simulate a separate FlutterEngine (e.g. background notification handler `@pragma('vm:entry-point') notificationTapBackground`) attempting restore while UI FlutterEngine holds `spendx_restore.lock`.
- **Independent Assertions:**
  1. Background engine does not share `IsolateNameServer`.
  2. Background engine attempts to acquire OS lock on `spendx_restore.lock`.
  3. OS lock blocks or throws `RestoreConcurrencyConflictException`.
  4. Background engine safely aborts without modifying database files.

#### Scenario 53: Background Execution Path Unable to Reach Coordinator (Zero Bypass)
- **Objective:** Background isolate cannot resolve coordinator port and cannot acquire lock.
- **Independent Assertions:**
  1. Background isolate strictly refrains from direct database modification.
  2. Throws `RestoreCoordinationException`.
  3. Zero database files touched or bypassed.

#### Scenario 54: Pure-Dart Destination Creation Between Vacancy Check and Rename (TOCTOU Failure Mode)
- **Objective:** Simulate pure Dart execution where an external process places a file at destination path immediately after `File.existsSync()` returns false.
- **Independent Assertions:**
  1. Standard `File.rename()` overwrites destination due to POSIX `rename(2)` wrapper.
  2. Documents that pure Dart cannot prevent external TOCTOU without kernel `RENAME_NOREPLACE`.
  3. Verifies that single-process exclusive lockfile prevents internal SpendX collision.

#### Scenario 55: Crash After Lock Acquisition But Before Port Registration
- **Objective:** Candidate coordinator acquires OS lock on `spendx_restore.lock`, but process crashes before registering with `IsolateNameServer`.
- **Independent Assertions:**
  1. OS kernel closes open file descriptor, releasing `spendx_restore.lock`.
  2. Port was never published; callers never discover unready candidate.
  3. Subsequent launch cleanly acquires OS lock. Zero database files modified.

#### Scenario 56: Crash After Registration But Before Readiness
- **Objective:** Candidate coordinator acquires lock and registers port, but crashes before transitioning to `CoordinatorState.ready`.
- **Independent Assertions:**
  1. OS lock is released by kernel.
  2. Caller sends handshake request and receives no response or closed port error.
  3. Caller does not submit database operations.

#### Scenario 57: Caller Discovers an Unready Coordinator
- **Objective:** Caller queries port and finds candidate coordinator still in `CoordinatorState.starting` (prior to readiness announcement).
- **Independent Assertions:**
  1. Handshake response returns `state: starting`.
  2. Caller refuses to send database operations.
  3. Waits for ready announcement or aborts with timeout.

#### Scenario 58: Concurrent Candidates Attempting Lock Acquisition
- **Objective:** Two candidate coordinator isolates spawn concurrently and attempt to acquire `spendx_restore.lock`.
- **Independent Assertions:**
  1. Candidate 1 acquires lock and proceeds to identity generation and publication.
  2. Candidate 2 fails lock acquisition and immediately self-terminates without publishing port.
  3. Single ownership guaranteed.

#### Scenario 59: Stale Caller Attempting to Remove a Replacement Mapping (Unauthorized Removal Prohibited)
- **Objective:** Caller with stale reference attempts to remove port mapping from `IsolateNameServer`.
- **Independent Assertions:**
  1. Architecture invariant enforces that callers lacking OS lock are prohibited from invoking `removePortNameMapping()`.
  2. Mapping remains intact.

#### Scenario 60: Coordinator Unresponsive But Still Holding the Lock
- **Objective:** Coordinator isolate is alive and holding OS lock, but application event loop is temporarily blocked (ping timeout).
- **Independent Assertions:**
  1. Caller transitions to `CoordinatorState.indeterminate`.
  2. Caller does not usurp coordinator or delete files.
  3. Caller aborts its wait safely with `RestoreIndeterminateException`.

#### Scenario 61: Coordinator Process Termination and Lock Release
- **Objective:** Full OS process hosting coordinator receives `SIGKILL`.
- **Independent Assertions:**
  1. Operating system kernel automatically reclaims all open file descriptors in the process file table.
  2. POSIX `fcntl` record lock on `spendx_restore.lock` is released immediately and synchronously by kernel.
  3. Subsequent process launch acquires lock cleanly without deadlock.

#### Scenario 62: Separate Flutter Engine Attempting Restore While Another Engine Holds Lease
- **Objective:** Background engine (`notificationTapBackground`) in the same Android process attempts restore while UI engine holds lease.
- **Independent Assertions:**
  1. Background engine queries Tier 1 Native Host Process Lease Manager (`SpendXProcessLockLeaseManager` in Android ART).
  2. Native host returns `ENGINE_LOCK_BUSY`.
  3. Background engine throws `RestoreConcurrencyConflictException` and self-terminates.
  4. Dart `RandomAccessFile.lock()` is NOT relied upon alone; bypass of Tier 1 native lease is strictly prevented.

#### Scenario 63: Cross-Thread Lease Acquisition and Release
- **Objective:** Verify that `SpendXProcessLockLeaseManager` permits acquisition on Thread A (e.g. Flutter platform thread) and release on Thread B (e.g. background worker/I/O thread).
- **Independent Assertions:**
  1. Acquisition on Thread A returns valid UUIDv4 `LeaseToken`.
  2. Release on Thread B providing the exact `LeaseToken` validates successfully.
  3. Zero `IllegalMonitorStateException` thrown (unlike `ReentrantLock`).
  4. FileChannel lock is released and descriptor closed cleanly.

#### Scenario 64: Stale Owner Attempting to Release Newer Lease (ABA & Stale Release Protection)
- **Objective:** Engine A acquires lease with `tokenA`. Engine A operation stalls. Engine A attempts `release(tokenA)` after lease was reassigned.
- **Independent Assertions:**
  1. Host lease manager compares incoming token against active lease token (`tokenA != tokenB`).
  2. Stale release is rejected with `STALE_LEASE_TOKEN`.
  3. Active lease for Engine B remains completely intact and valid.
  4. FileChannel lock remains held; zero permit leaks or over-releases occur.

#### Scenario 65: Engine Destruction While Native Database Work Remains Active (Fail-Safe Lock Retention)
- **Objective:** FlutterEngine holding restore lease is destroyed while native SQLite thread is still writing database pages.
- **Independent Assertions:**
  1. Engine shutdown Step 3 fails (native database quiescence cannot be established).
  2. Fail-safe retention rule triggered: manager **does NOT release the file lock or close descriptor**.
  3. FileChannel lock remains held by the host process until full OS process termination.
  4. Database is protected against concurrent write corruption.

#### Scenario 66: Safe Engine Destruction with Confirmed Native Database Quiescence
- **Objective:** FlutterEngine holding restore lease is destroyed after all native SQLite connections are closed and I/O drained.
- **Independent Assertions:**
  1. Engine shutdown Step 3 succeeds (native database operations confirmed quiescent).
  2. Host manager safely releases `FileChannel` lock and closes descriptor.
  3. Process-local lease is reclaimed cleanly.

#### Scenario 67: Monotonic Lease Timeout Prohibited from Reclaiming Active Lease (Indeterminate State)
- **Objective:** Restore operation exceeds nominal lease duration while coordinator isolate is still alive.
- **Independent Assertions:**
  1. Monotonic timer fires, but operation cessation is NOT confirmed.
  2. Manager strictly refuses to reclaim or reissue the lease.
  3. Lock remains held; state transitions to `CoordinatorState.indeterminate`.
  4. New operations rejected with `RestoreIndeterminateException`.

#### Scenario 68: Cancellation Failing to Stop Underlying Operation (Lock Retained)
- **Objective:** Cancellation requested, but async SQLite transaction fails to abort immediately.
- **Independent Assertions:**
  1. Cancellation token signaled; manager awaits native quiescence.
  2. Because SQLite work is active, lock is NOT released.
  3. Lock held until operation drains or process terminates.

#### Scenario 69: Duplicate Acquisition from Same Engine (Strict Single-Lease Rejection)
- **Objective:** Engine A calls `acquire()` while Engine A already holds an active lease.
- **Independent Assertions:**
  1. Manager applies Strict Single-Lease Non-Reentrant Policy.
  2. Call is rejected with `DUPLICATE_ACQUISITION_REJECTED`.
  3. Original active lease is unmodified.

#### Scenario 70: Duplicate Release While Another Operation Remains Active
- **Objective:** Caller calls `release(token)` twice in succession.
- **Independent Assertions:**
  1. First release validates and clears lease.
  2. Second release finds `activeLease == null` and returns `false` safely.
  3. Zero state corruption; zero permit accumulation.

#### Scenario 71: Tier 2 tryLock() Returning Null (External Process Contention & Descriptor Cleanup)
- **Objective:** External OS process holds POSIX `fcntl` lock; app calls `acquire()`; Java `tryLock()` returns `null`.
- **Independent Assertions:**
  1. Host manager explicitly handles `null` return.
  2. Host immediately closes `FileChannel` descriptor in `finally` block (zero descriptor leak).
  3. Host rolls back Tier 1 state to unlocked.
  4. Returns `TIER2_LOCK_BUSY`.

#### Scenario 72: Exceptions During Descriptor Close and Lease Release
- **Objective:** `FileChannel.close()` throws `IOException` during release sequence.
- **Independent Assertions:**
  1. Exception is caught, logged as warning, and suppressed from aborting state reset.
  2. State resets to unlocked; lease cleared; zero deadlock on subsequent acquisitions.

#### Scenario 73: Process Death During Acquisition/Release Transitions
- **Objective:** Process receives `SIGKILL` at each transition (before fd open, after fd open, after tryLock, during release).
- **Independent Assertions:**
  1. OS kernel synchronously closes all file descriptors and clears POSIX `fcntl` locks in all cases.
  2. Zero stale locks persist across process restarts.

#### Scenario 74: Recovery from an Indeterminate Restore State
- **Objective:** System recovers after an unconfirmed/indeterminate restore operation.
- **Independent Assertions:**
  1. Coordinator isolate is force-killed and exit listener verified.
  2. Crash recovery routine inspects `spendx_restore_journal.json`.
  3. If active database is unverified, preserves it in quarantine path and restores safety backup.

#### Scenario 75: Coordinator Isolate Exit While Native SQLite Worker Continues Database Access
- **Objective:** Dart coordinator isolate terminates, but an in-flight native SQLite C function (`sqlite3_step` or WAL commit) is still executing in the thread pool.
- **Independent Assertions:**
  1. Manager evaluates Quiescence Inventory (EC-04).
  2. Detects native connection handle still open or active statement in-flight.
  3. Manager strictly refuses to release OS file lock or clear lease.
  4. State is retained as `INDETERMINATE`.
  5. Subsequent restore operations rejected with `RestoreIndeterminateException`.

#### Scenario 76: FlutterEngine Destruction While Plugin-Managed Dispatch Queue Remains Active
- **Objective:** `FlutterEngine` is destroyed while the `sqflite` plugin's native Android `HandlerThread` has pending tasks.
- **Independent Assertions:**
  1. Manager evaluates Quiescence Inventory (EC-03).
  2. Plugin barrier task fails to complete or reports queued tasks.
  3. Fail-safe retention rule triggered: manager does NOT release `FileChannel` lock or close descriptor.
  4. Lock is retained until host process terminates.

#### Scenario 77: Cancellation Request Completes Before Underlying File I/O Drains
- **Objective:** User cancels restore; cancellation Future returns, but disk write buffer is still flushing.
- **Independent Assertions:**
  1. Manager evaluates Quiescence Inventory (EC-05).
  2. Detects open file stream futures or pending flush.
  3. Lock is retained until all I/O streams are drained and descriptors closed.

#### Scenario 78: FileLock.release() Throws Exception (Outcome B: Indeterminate Release)
- **Objective:** OS file lock release call throws `IOException` during restore teardown.
- **Independent Assertions:**
  1. Outcome B triggered: manager does not assume OS lock was cleared.
  2. Lease is retained; state transitions to `INDETERMINATE`.
  3. New acquisition requests rejected with `RestoreIndeterminateException`.
  4. Zero assumption of unlock.

#### Scenario 79: FileChannel.close() Throws Exception After Successful Release (Outcome C: Descriptor Cleanup Failure)
- **Objective:** `FileLock.release()` succeeds, but `FileChannel.close()` throws `IOException`.
- **Independent Assertions:**
  1. Outcome C triggered: manager records descriptor leak.
  2. State transitions to `DESCRIPTOR_CLEANUP_FAILED`.
  3. Manager does NOT claim cleanup succeeded.
  4. Rejects new acquisitions until host process restarts to prevent POSIX `fcntl` descriptor hazards.

#### Scenario 80: FileChannel.close() Throws Exception During Failed Acquisition Rollback
- **Objective:** `tryLock()` returns `null`; subsequent cleanup `channel.close()` throws `IOException`.
- **Independent Assertions:**
  1. Acquisition rollback parity enforced.
  2. State transitions to `DESCRIPTOR_CLEANUP_FAILED` rather than `UNLOCKED`.
  3. System records descriptor cleanup failure.

#### Scenario 81: Engine Destruction Between Descriptor Open and Lease Grant (Transition 2 Cleanup)
- **Objective:** FlutterEngine destroyed during Transition 2 (`channel != null`, `fileLock == null`).
- **Independent Assertions:**
  1. Manager executes Transition 2 cleanup protocol.
  2. Closes open `FileChannel`.
  3. If close succeeds $\rightarrow$ state reverts to `UNLOCKED`.
  4. If close throws $\rightarrow$ state transitions to `DESCRIPTOR_CLEANUP_FAILED`.

#### Scenario 82: Process Termination at Each Acquisition Transition
- **Objective:** Host process receives `SIGKILL` during Transition 1, 2, 3, or 4.
- **Independent Assertions:**
  1. OS kernel synchronously reclaims file descriptors and clears POSIX locks across all transitions.
  2. Post-restart launch acquires lock cleanly without deadlock.

#### Scenario 83: Recovery from an Indeterminate Release State
- **Objective:** Attempt restore after release entered `INDETERMINATE` state.
- **Independent Assertions:**
  1. New acquisition rejected with `RestoreIndeterminateException`.
  2. Full process restart or verified native cleanup required before retry.

#### Scenario 84: Second Connection Opened During Gate Acquisition (Connection Isolation)
- **Objective:** Secondary repository or background task attempts to open a database connection while the Database Access Gate (DAG-01) is active.
- **Independent Assertions:**
  1. DAG-01 gate admission barrier intercepts connection open request.
  2. Operation is blocked or rejected with `DatabaseBusyException`.
  3. Active restore operation completes without connection leakage or data race.

#### Scenario 85: Auxiliary Background Engine Database Access Attempt After Gate Close
- **Objective:** `notificationTapBackground` triggers in a detached background `FlutterEngine` after DAG-01 has closed connections.
- **Independent Assertions:**
  1. Android Host IPC barrier intercepts execution or blocks engine initialization of `AppDatabase`.
  2. Mutation rejected or deferred until restore completes and gate reopens.
  3. Live database file is not modified concurrently during file swap.

#### Scenario 86: Queued Android Plugin Operation Arriving After Worker Drain Barrier
- **Objective:** An in-flight `sqflite` platform channel task arrives at the Java `HandlerThread` after the drain barrier task was dispatched.
- **Independent Assertions:**
  1. Barrier task ensures all preceding operations are fully flushed to disk.
  2. Subsequent operation is rejected by gate admission barrier before native execution.
  3. Zero un-drained SQLite statements execute during file swap.

#### Scenario 87: Multiple Open Connections with Unfinalized Prepared Statements (`sqlite3_close_v2` Zombie Verification)
- **Objective:** Connection A has an active `PRAGMA` or `SELECT` statement unfinalized when `sqlite3_close_v2()` is invoked.
- **Independent Assertions:**
  1. Connection transitions to zombie state; OS file descriptor remains open.
  2. DAG-01 Step 5 statement finalization barrier detects open statement (`sqlite3_next_stmt != null`).
  3. Restore operation halts safely before atomic rename, retaining active database and safety backup.

#### Scenario 88: Completed Dart Future with In-Flight Unclosed File Descriptor
- **Objective:** A Dart file write Future resolves, but POSIX kernel buffer or descriptor flush is still processing in native I/O thread.
- **Independent Assertions:**
  1. Gate Step 4 / Quiescence check EC-05 does not treat Dart Future resolution as durability proof.
  2. Host manager invokes explicit `fsync(file_fd)` and awaits 0 return before proceeding to swap.
  3. Zero truncated or buffered file data lost.

---

### Group 6: Cryptographic Bounds & Legacy Boundaries

#### Scenario 28: Password Normalization (Unicode NFKC & Bounding)
- **Objective:** Verify NFC and NFD normalize to identical keys for passwords; bounds 8..128 chars enforced.

#### Scenario 29: Untrusted Archive KDF Resource Limits
- **Objective:** Archives requesting memory > 64 MiB or iterations > 10 rejected before KDF execution.

#### Scenario 30: Live Source Ledger Immutability During Backup Creation
- **Objective:** Prove `createBackupPackage()` treats live DB as strictly read-only and scrubs expired evidence only on the staging DB.

#### Scenario 31: Legacy Format v1 & v2 Boundaries
- **Objective:** Verify Format v1 and v2 report descriptive unsupported/device-bound errors without modifying files.

---

## 3. Test Execution & Evidence Reporting

### 3.1 Gated Physical Lock Lifecycle Verification Matrix (Gate G-SEC-01-LOCK)

| Test ID | Test Scenario | Documented OS / Runtime Semantics | Architecture-Level Expected Behavior | Actual Milestone Result | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Test L-01** | **Lease Timeout While Operation Still Running** | Dart VM isolate continues executing SQLite write loop; OS process and fd remain open. | Monotonic timer alone prohibited from reclaiming lease; lock retained; state classified as Indeterminate (`RestoreIndeterminateException`). | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-02** | **Engine Destruction While Native DB Work Active** | Host process remains alive; un-abortable SQLite C call still active in thread pool. | Fail-safe retention rule triggered: lock is NOT released merely because FlutterEngine was destroyed; descriptor kept open until process termination. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-03** | **Cancellation Failing to Stop Underlying Work** | Cancellation token signaled, but async SQLite transaction has not completed. | Host lease manager confirms native database quiescence; if not confirmed, lock is retained; operation drained before release. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-04** | **Two Independent Operations from Same Engine** | Engine A calls `acquire()`, then calls `acquire()` again before releasing. | Policy enforces strict rejection with `DUPLICATE_ACQUISITION_REJECTED`; second operation refused; active lease untouched. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-05** | **Duplicate Release While Another Operation Active** | Engine A calls `release(tokenA)` twice, or provides mismatched `tokenOld`. | Manager validates `leaseToken == activeLease.token`. Duplicate/stale release rejected safely; active lease remains fully protected; zero permit leaks. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-06** | **Tier 2 `tryLock()` Returning Null** | External process holds `fcntl` lock on `spendx_restore.lock`. Java `tryLock()` returns `null` without throwing exception. | Manager detects `null`; closes `FileChannel` descriptor immediately in `finally`; rolls back Tier 1 state to unlocked; returns `TIER2_LOCK_BUSY`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-07** | **Exceptions During Descriptor Close & Lease Release** | `FileChannel.close()` throws `IOException` during release sequence. | State transitions to `DESCRIPTOR_CLEANUP_FAILED`; does not claim cleanup succeeded; rejects new acquisitions. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-08** | **Process Death During Acquisition/Release Transitions** | Process receives `SIGKILL` during fd open, tryLock, or release. | OS kernel synchronously reclaims file descriptor table and clears POSIX `fcntl` locks across all transition points. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-09** | **Recovery from Indeterminate Restore State** | Operation entered indeterminate state; isolate force-killed. | Restart verifies isolate exit, inspects `spendx_restore_journal.json`, preserves unverified active DB in quarantine, restores safety backup. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-10** | **iOS Platform Execution** | iOS Darwin runtime lacks JVM; pure Dart lacks atomic cross-engine lock. | Formally rejected under `Limitation LIM-PLAT-01-IOS`; restore operation throws `PlatformNotSupportedException`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-11** | **Coordinator Isolate Exit While Native Worker Active** | Dart VM isolate terminates, but background native SQLite C thread is writing. | Quiescence check EC-04 fails; manager refuses to release lock or clear lease; state marked `INDETERMINATE`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-12** | **Engine Destruction While Plugin Queue Active** | `FlutterEngine` destroyed while `sqflite` `HandlerThread` has pending tasks. | Quiescence check EC-03 fails; manager retains OS lock until plugin tasks drain or process terminates. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-13** | **Cancellation Completes Before File I/O Drains** | Cancellation token reports done while disk write buffer is in-flight. | Quiescence check EC-05 fails; lock retained until all I/O futures and buffers complete. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-14** | **`FileLock.release()` Throws Exception** | OS release call fails with `IOException`. | Outcome B triggered: state transitions to `INDETERMINATE`; lease retained; new acquisitions blocked. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-15** | **`FileChannel.close()` Throws After Successful Release** | Lock released, but descriptor close throws `IOException`. | Outcome C triggered: state transitions to `DESCRIPTOR_CLEANUP_FAILED`; cleanup not claimed as succeeded. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-16** | **`FileChannel.close()` Throws During Acquisition Rollback** | `tryLock()` returns `null`; subsequent `channel.close()` throws `IOException`. | Rollback parity: state transitions to `DESCRIPTOR_CLEANUP_FAILED` rather than `UNLOCKED`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-17** | **Engine Destruction Between Descriptor Open & Lease Grant** | Engine detached during Transition 2 (`channel != null`, `fileLock == null`). | Manager closes descriptor; handles close failure if thrown; state reverts to `UNLOCKED` or `DESCRIPTOR_CLEANUP_FAILED`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-18** | **Process Termination at Each Acquisition Transition** | `SIGKILL` delivered during Transition 1, 2, 3, or 4. | Kernel cleans up open descriptors and locks synchronously across all four transitions. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-19** | **Recovery from Indeterminate Release State** | System in `INDETERMINATE` release state; new operation attempted. | Operation rejected; requires full process restart or verified native cleanup before retry. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-20** | **Database Access Gate Rejection of New Operations** | Caller attempts query while DAG-01 gate admission barrier is active (`restoreMode = true`). | Query rejected or blocked by gateway; in-flight counter unchanged; active restore protected. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-21** | **In-Flight Accounting Barrier Drain Timeout** | Active query hangs or fails to complete within 5-second drain window. | Gate aborts restore transition; returns `DatabaseBusyException`; live database remains intact. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-22** | **`sqlite3_close_v2` Zombie State File Lock Retention** | Connection closed while unfinalized prepared statement exists. | Native C engine keeps descriptor open; DAG barrier detects non-null stmt and blocks file replacement. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-23** | **Cross-Engine Background Task Rejection by Access Coordinator** | Auxiliary `FlutterEngine` (`notificationTapBackground`) attempts DB write during restore. | Host IPC barrier intercepts request; write rejected or queued until restore completes. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-24** | **`sqlite3_interrupt` Isolation to Single Connection** | Connection A interrupted during query; Connection B active concurrently. | Proves `sqlite3_interrupt` only affects Connection A; confirms necessity of explicit multi-connection barrier. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-25** | **Multi-Connection WAL Checkpoint Contention and TRUNCATE Failure** | Read connection open while main thread issues `PRAGMA wal_checkpoint(TRUNCATE)`. | Checkpoint returns `SQLITE_BUSY`; proves WAL cannot be truncated without closing all readers. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-26** | **`fsync` on File Descriptor Succeeded but Directory `fsync` Throws** | File data flushed; directory `fsync(dir_fd)` fails with `EIO`. | Durability classified as `Durability Unconfirmed`; safety backup retained with `state: cleanupPending`. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |
| **Test L-27** | **Unawaited Background Future Mutation Outliving Barrier** | Fire-and-forget `unawaited(finalizeLiveChoice(...))` invoked right before restore. | Pillar 4.5A.2 prohibition enforced; unawaited calls eliminated; barrier accounting accounts for all ops. | **Not executed** (CLI sandbox exit code 127; no physical device) | **Gated under Gate G-SEC-01-LOCK** |

---

### 3.2 Overall Milestone Metrics

| Metric | Status |
| :--- | :--- |
| **Specified Test Scenarios** | **88 Scenarios** across 6 Groups |
| **Planned Test Cases** | **108 Planned Test Cases** |
| **Tests Executed in Milestone** | **0 (Zero)** — Documentation and architecture design only |
| **Harness Execution Status** | Reproduction command exited with code 127 (`operation not permitted: flutter` under sandbox) |
| **Production Code Status** | **0 lines modified** — No production implementation started |
| **Pass / Regression Verdict** | **Pending future implementation** (No claims of 100% pass or zero regressions) |
