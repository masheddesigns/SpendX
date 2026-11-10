# SpendX Release Readiness — Pillar 4.4: Security Remediation Architecture & Implementation Plan

**Document Version:** 2.0.0 (Validated)  
**Date:** November 4, 2026  
**Target Release:** SpendX 2.1.0  
**Phase:** Pillar 4.4.1 — Security Remediation Architecture & Technical Validation  
**Status:** Architecture Validated · **Production Code 100% Frozen** · **Planning Milestone Only**

---

## 1. Executive Summary

During the Pillar 4.1–4.3 Release Readiness Audits, three distinct security issues were identified, analyzed, and empirically reproduced in automated tests:
1. **SEC-01 (CRITICAL):** Cross-device restoration of SQLCipher backups fails because `VACUUM INTO` outputs a database keyed to the originating device's hardware master key.
2. **SEC-02 (HIGH):** Gemini API credential management relies on application-level compile-time constants or `.env` bundling, exposing developer quota to extraction and abuse.
3. **SEC-03 (MEDIUM):** In the plaintext-to-SQLCipher migration state machine, a failure during post-verification deletion of the pre-migration backup triggers `_rollbackSwap()`, deleting the verified encrypted database and restoring unencrypted plaintext.

In Pillar 4.4.1, technical validation was conducted across all three findings:
- **SQLCipher Portable Export Feasibility:** **VERIFIED** on bundled SQLCipher 4.18.0 Community engine with zero plaintext staging.
- **Migration State-Machine Commit Semantics:** **SAFE DESIGN** with durable commit boundaries that mathematically prohibit post-activation rollback.
- **Gemini BYOK Credential Architecture:** Fully refined with Keystore/Keychain secure storage, in-memory lifetime bounds, and backup firewalls.

**All production code remains 100% frozen during this planning phase.**

---

## 2. Root Cause Analyses

### 2.1 SEC-01: Device-Bound SQLCipher Snapshots
- **Mechanism:** In [`lib/services/backup_service.dart:207`](file:///Users/sivek/Documents/SpendX/lib/services/backup_service.dart#L207), database snapshotting is performed via:
  ```dart
  await db.execute("VACUUM INTO '${snapFile.path}';");
  ```
- **Root Cause:** In SQLCipher 4.x, `VACUUM INTO` outputs a new database file that inherits the cryptographic pager configuration and key of the active connection (`PRAGMA key`). When Phone A creates a backup, `snapFile` is encrypted with Phone A's device-unique key.
- **Defect:** While [`BackupFileService.createPackage`](file:///Users/sivek/Documents/SpendX/lib/services/backup_file_service.dart#L63) wraps this file in AES-256-GCM derived from the user's password, the inner file remains locked to Phone A. On Phone B or after application reinstallation, Phone B derives a different local key. When [`BackupService.restoreFromFile`](file:///Users/sivek/Documents/SpendX/lib/services/backup_service.dart#L453) passes Phone B's key to `openEncryptedDatabase`, SQLCipher rejects the file with `SqlCipherException: SQLITE_NOTADB or corrupted header (code 26)`.

### 2.2 SEC-02: Client-Embedded API Key Dilemma
- **Mechanism:** [`lib/services/gemini_service.dart:14-24`](file:///Users/sivek/Documents/SpendX/lib/services/gemini_service.dart#L14-L24) reads keys from `dotenv.env['GEMINI_API_KEY']` or compile-time `String.fromEnvironment('GEMINI_API_KEY')`.
- **Root Cause:** The architecture lacks a user-facing credential configuration interface. If developer keys are compiled into release binaries via `--dart-define`, they reside in the text pool of `libapp.so`.
- **Defect:** Google AI Studio Gemini API keys cannot be restricted by Android app SHA-1 signing certificates. Once extracted, a key can be used from any external client against the developer's quota. If the key is omitted, release builds suffer total AI feature failure ("Gemini API key is not configured").

### 2.3 SEC-03: Post-Verification Cleanup Rollback Inversion
- **Mechanism:** In [`lib/data/security/database_encryption_migration_service.dart:907-953`](file:///Users/sivek/Documents/SpendX/lib/data/security/database_encryption_migration_service.dart#L907-L953), post-swap cleanup executes:
  ```dart
  await journal.record(MigrationState.verified);
  if (await archiveFile.exists()) await archiveFile.delete();
  if (!keepBackupOnSuccess) {
    final bkp = File(rollbackBackupPath);
    if (await bkp.exists()) await bkp.delete();
  }
  ```
- **Root Cause:** Lines 910–916 are not wrapped in a dedicated error handler. If `bkp.delete()` throws a filesystem `FileSystemException` (e.g. file lock or permissions error), execution branches to the outer catch block.
- **Defect:** The catch block evaluates `journal.state == MigrationState.swapping || journal.state == MigrationState.verified` as true, sets `recoveryRequired`, and calls `_rollbackSwap()`. `_rollbackSwap` unlinks the active encrypted database and copies the unencrypted pre-migration backup over the live path.

---

## 3. SQLCipher Portable Export Technical Feasibility Validation

### 3.1 Investigation of Previous Experiment (Exit Code 79)
- **Root Cause of Code 79:** The initial probe script `test_sqlcipher_export_rekey.dart` was executed using `flutter test`, but was written with a top-level `void main() async` instead of standard `test('...', () { ... })` declarations. The Flutter/Dart test runner exited with code 79 (standard Dart test runner code for "No tests were found / No tests ran").
- **Resolution:** Re-implemented the feasibility verification as a compliant unit test structure.

### 3.2 Exact SQLCipher Version & Runtime Capabilities
Empirical probing via `PRAGMA cipher_version;`, `SELECT sqlite_version();`, and `PRAGMA compile_options;` confirmed the exact production runtime specifications:
- **Engine Version:** `SQLCipher 4.18.0 community`
- **Underlying SQLite Core:** `3.53.4`
- **Codec Support:** `HAS_CODEC` active
- **Attachment Limit:** `MAX_ATTACHED=10`
- **Page Size:** `DEFAULT_PAGE_SIZE=4096`
- **Hook Lifecycle:** `EXTRA_INIT=sqlcipher_extra_init`, `EXTRA_SHUTDOWN=sqlcipher_extra_shutdown`
- **Native Parity:** Bundled via `package:sqlite3` with `source: sqlcipher` in `pubspec.yaml`, matching native `libsqlcipher.so` compiled for Android `arm64-v8a`, `armeabi-v7a`, and `x86_64`.

### 3.3 8-Point Empirical Feasibility Verification Results
The minimal isolated experiment executed against the actual bundled SQLCipher engine confirmed:

1. **Source Database Creation:** Created with 256-bit Key A containing full Schema v24 and double-entry financial transactions (₹85,000.00 / 8,500,000 paise).
2. **Attached Target Creation:** Attached destination database using an independently derived 256-bit Key B (`ATTACH DATABASE '$destPath' AS portable KEY "x'<KeyB>'";`).
3. **Direct SQLCipher Export:** Executed `SELECT sqlcipher_export('portable');` and replicated `PRAGMA portable.user_version = 24;`.
4. **Clean Connection Close:** Detached and closed both connections cleanly.
5. **Target Re-Open with Key B:** Destination database opened cleanly using Key B.
6. **Schema & Data Invariant Preservation:**
   - Schema `user_version` = `24`
   - Active triggers: exactly `7` mandatory triggers (`trg_%`) preserved and active
   - Indexes: all schema indexes (`idx_%`) preserved
   - Economic events: posted events intact
   - Postings: debit (8,500,000) and credit (8,500,000) totals match bit-for-bit
   - `PRAGMA integrity_check` = `ok`
   - `PRAGMA foreign_key_check` = `0` violations
7. **Different Key Rejection:** Confirmed destination database **CANNOT** be opened using Key A (throws `SqlCipherException: SQLITE_NOTADB or corrupted header`).
8. **Zero Plaintext Disk Exposure:** Destination database header confirmed to contain zero plaintext "SQLite format 3" magic bytes (`isPlaintextSqliteFile()` returned `false`).

### 3.4 Feasibility Verdict
**Verdict: VERIFIED**  
SQLCipher 4.18.0 natively supports direct encrypted-to-encrypted database export between independent keys without temporary plaintext files.

---

## 4. Proposed Remediation Architecture

### 4.1 SEC-01: Direct Encrypted-to-Encrypted Portable Backup Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│ BACKUP CREATION (Phone A)                                               │
│                                                                         │
│ 1. User enters backup password.                                         │
│ 2. Argon2id derives two independent 256-bit keys from password + salt:  │
│    - K_db: SQLCipher Raw Hex Key (PRAGMA key for portable snapshot)    │
│    - K_gcm: AES-256-GCM Master Key (for manifest & container integrity)│
│                                                                         │
│ 3. Live SQLCipher Connection (Key_PhoneA) executes:                     │
│    ATTACH DATABASE 'staging.db' AS portable KEY "x'<K_db>'";            │
│    SELECT sqlcipher_export('portable');                                 │
│    PRAGMA portable.user_version = 24;                                   │
│    DETACH DATABASE portable;                                            │
│                                                                         │
│ 4. Zero plaintext touches disk. 'staging.db' is encrypted with K_db.    │
│ 5. AES-256-GCM packages manifest.json and spendx.db.enc into .spendx    │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ RESTORATION (Phone B with different local key Key_PhoneB)               │
│                                                                         │
│ 1. Decrypt outer container with user password -> verify AAD and SHA-256.│
│ 2. Derive K_db from password + manifest salt via Argon2id.              │
│ 3. Open 'staging.db' with K_db -> run full financial invariant audit.   │
│ 4. Staging SQLCipher Connection (K_db) executes:                        │
│    ATTACH DATABASE 'spendx.db' AS target KEY "x'<Key_PhoneB>'";         │
│    SELECT sqlcipher_export('target');                                   │
│    PRAGMA target.user_version = 24;                                     │
│    DETACH DATABASE target;                                              │
│                                                                         │
│ 5. Active database is now encrypted with Phone B's local hardware key.  │
│ 6. Unlink staging.db.                                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Portable Backup Protocol Specification (Format v3)
- **Format Version:** `3`
- **Key Derivation Function (KDF):** Argon2id
  - Memory: `19,456 KiB` (19 MiB)
  - Iterations: `2`
  - Parallelism / Lanes: `1`
  - Output Key Material: `64 bytes` (512 bits)
    - Bytes `0..31`: `K_db` (256-bit raw SQLCipher key passed via `x'...'` PRAGMA key)
    - Bytes `32..63`: `K_gcm` (256-bit AES-GCM secret key)
- **Salt Generation:** 16 cryptographically secure random bytes via `Random.secure()`.
- **Nonce Generation:** 12 random bytes via `AesGcm.with256bits().newNonce()`.
- **Authenticated Additional Data (AAD):**
  `fmt=3;schema=24;sha256=<HASH>;events=<N>;postings=<N>;debits=<PAISE>;credits=<PAISE>;kdf=ARGON2ID;salt=<B64>`
- **No Plaintext Staging Guarantee:** Plaintext databases are never written to disk during backup or restore. Staging files are 100% encrypted with `K_db` from their first byte.

---

### 4.2 SEC-02: Refined Gemini Bring-Your-Own-Key (BYOK) Architecture

#### 1. Credential Ownership & Storage
- **Ownership:** 100% user-owned. No application-wide developer key is bundled in release builds.
- **Storage Backend:** `FlutterSecureStorage` with key `'spendx_gemini_user_api_key'`.
  - Android: `EncryptedSharedPreferences` backed by Android Keystore.
  - iOS: Keychain with `kSecAttrAccessibleAfterFirstUnlock`.
- **Replacement & Removal:**
  - `setUserApiKey(String key)` validates format, writes to secure storage, and updates runtime cache.
  - `deleteUserApiKey()` removes the key from secure storage, overwrites the in-memory cache, and sets `hasKey = false`.

#### 2. In-Memory Key Lifetime
- The API key is stored in a private in-memory variable `String? _cachedUserApiKey`.
- It is instantiated on first use and wiped (set to `null`) when the app is paused/backgrounded (`AppLifecycleState.paused` or `detached`), on user sign-out, or upon key deletion.

#### 3. Log, Stack Trace, and Export Redaction
- `_sanitizeError(String msg)` in `GeminiService` redacts any occurrence of the user key with `[REDACTED_API_KEY]`.
- `AppLogger` ensures exception strings, network failure logs, and HTTP headers never leak the key.
- `BackupManifest.settings` strictly filters out any preference key matching `*api_key*`, `*secret*`, or `*token*`. The user's Gemini key is **NEVER** serialized into `.spendx` archives or JSON/CSV exports.

#### 4. Missing & Invalid Key Semantics
- **Missing Key:** If `_apiKey.isEmpty`, `GeminiService.hasKey` returns `false`. Calling AI features immediately returns an informative message: *"Gemini API key is not configured. Please add your API key in Settings to use AI assistance."* Zero HTTP requests are initiated; zero unhandled exceptions are thrown.
- **Invalid Key (HTTP 400/403):** If the Gemini API returns an authentication failure, the response is sanitized and surfaces a user-friendly error: *"Invalid Gemini API key. Please verify your key in Settings."*

#### 5. Functional Defect Classification
Because no key is currently embedded in `app-release.apk`, this is classified as a **Functional Release Configuration Defect**. Implementing BYOK enables AI features while maintaining zero client credential exposure.

---

### 4.3 SEC-03: Corrected Migration State Machine & Commit Semantics

The migration state machine is revised to distinguish durable activation from post-commit cleanup.

```
┌────────────────────────────────────────────────────────────────────────┐
│ PHASE 1: ROLLBACK-ELIGIBLE STATES (Failure restores original plaintext)│
│                                                                        │
│   none ──► preflight ──► backupCreated ──► walQuiesced ──► exporting   │
│                                                                 │      │
│   swapping ◄──────────────── readyToSwap ◄────── validating ◄───┘      │
│      │                                                                 │
│      ├─► [Failure in Phase 1] ──► _rollbackSwap() ──► Plaintext intact │
└──────┼─────────────────────────────────────────────────────────────────┘
       │
═══════╪══════════════════════════════════════════════════════════════════
       │  POINT OF IRREVOCABLE ACTIVATION: Staged DB renamed to spendx.db
═══════╪══════════════════════════════════════════════════════════════════
       ▼
┌────────────────────────────────────────────────────────────────────────┐
│ PHASE 2: POST-ACTIVATION VERIFICATION & DURABLE COMMIT                 │
│                                                                        │
│   1. Probe live encrypted DB (PRAGMA user_version == 24, sqlite_master)│
│   2. Record durable journal commit:                                    │
│      MigrationJournal.record(MigrationState.verified, flush: true)     │
│                                                                        │
│ ══════════════════════════════════════════════════════════════════════ │
│              DURABLE COMMIT POINT: ROLLBACK STRICTLY FORBIDDEN         │
│ ══════════════════════════════════════════════════════════════════════ │
│                                                                        │
│   3. Cleanup phase (archive & pre-migration backup deletion):          │
│      - If deletion succeeds: MigrationJournal.clear()                  │
│      - If deletion fails: MigrationJournal.record(cleanupPending)      │
│        (Non-fatal warning; live encrypted DB remains 100% active)      │
└────────────────────────────────────────────────────────────────────────┘
```

#### State Machine Invariant Rules
1. **Durable Commit Point:**
   - The encrypted database becomes authoritative when `sourceFile.renameSync(archivePath)` and `stagedFile.renameSync(sourcePath)` complete, post-swap verification confirms SQLCipher access, AND `MigrationState.verified` is flushed to `spendx_migration_state.json`.
2. **Rollback Prohibition Invariant:**
   - Once `journal.state == MigrationState.verified` or `MigrationState.cleanupPending`, **`_rollbackSwap` is mathematically prohibited**. Cleanup errors are logged as warnings and cannot revert the live database.
3. **Startup Crash Recovery:**
   - If the app terminates during cleanup:
     - `recoverInterruptedMigration()` inspects `journal.state`.
     - For states `verified` and `cleanupPending`, it probes `sourcePath`. If `sourcePath` is valid SQLCipher, it unlinks stale backups (`spendx.db.pre_migration_backup`), clears the journal, and completes startup.
     - It **never** restores plaintext.
4. **Stale Plaintext Sweeper:**
   - `cleanStaleMigrationArtifacts()` runs during `AppDatabase.initialize()`. If `spendx.db` is confirmed to be healthy SQLCipher, any remaining `.pre_migration_backup` files are safely removed.

**Design Verdict: SAFE DESIGN**

---

## 5. Detailed Implementation Sequence

### Phase 1: Milestone 4.5B — Migration Cleanup Safety & State Machine Hardening
1. Add `cleanupPending` to `enum MigrationState`.
2. Split post-verification cleanup in `DatabaseEncryptionMigrationService.dart`:
   - Record `verified`.
   - Wrap backup deletion in isolated try/catch logging a warning on error and setting `cleanupPending`.
   - Never call `_rollbackSwap` once `verified` is reached.
3. Update `recoverInterruptedMigration()` to handle `verified` and `cleanupPending` by completing cleanup rather than rolling back.
4. Add `cleanStaleMigrationArtifacts()` to startup.

### Phase 2: Milestone 4.5A — Portable Encrypted Backup & Restore
1. Derive 64-byte key material (`K_db` and `K_gcm`) in `BackupFileService`.
2. Update `createBackupPackage()` in `BackupService` to use direct `ATTACH DATABASE ... AS portable KEY "x'<K_db>'"; SELECT sqlcipher_export('portable');`.
3. Update `restoreFromFile()` to decrypt outer container, open staging DB with `K_db`, validate schema invariants, and export directly into target with local device key.
4. Tag archives with `formatVersion: 3`.

### Phase 3: Milestone 4.5C — Gemini BYOK Credential Management
1. Implement `getUserApiKey()`, `setUserApiKey()`, `deleteUserApiKey()` in `GeminiService` using `FlutterSecureStorage`.
2. Restrict runtime resolution: secure storage first; check `dotenv` only in `kDebugMode`.
3. Implement `_sanitizeError()` and backup manifest secret exclusion firewalls.
4. Provide clean missing-key and invalid-key exception messages.

---

## 6. Compatibility Risks & Mitigation

| Area | Compatibility Risk | Mitigation Strategy |
|---|---|---|
| **Backup Format** | Format v2 backups created on Phone A cannot be restored on Phone B. | `BackupFileService.extractPackage()` inspects `manifest.formatVersion`. If `formatVersion < 3` and SQLCipher fails with `SqlCipherException`, provide a user-friendly error: *"This backup was created with a legacy device-locked format. Please restore on the original device or create a Format v3 backup."* |
| **Migration State** | Existing interrupted journal files in field from v2.0. | `MigrationJournal.load()` handles legacy states gracefully. `cleanupPending` maps safely to recovery cleanup. |
| **BYOK Migration** | Existing users upgrading without an API key. | AI features present an informative setup banner: *"Set up Gemini API Key in Settings to enable receipt scanning and AI chat."* Existing ledger and non-AI features continue working with zero disruption. |

---

## 7. Security Trade-offs

1. **Argon2id Memory Cost (19 MiB):**
   - *Trade-off:* 19 MiB RAM allocation during backup creation and restoration.
   - *Security Benefit:* OWASP-compliant protection against GPU-accelerated password cracking and offline rainbow table attacks.
2. **Direct SQLCipher Export vs Plaintext Temporary Staging:**
   - *Trade-off:* Direct export takes slightly more CPU than unencrypted `VACUUM INTO`.
   - *Security Benefit:* 100% elimination of plaintext database leakage on raw NAND flash blocks, circumventing wear-leveling data recovery risks.
3. **BYOK vs Client-Embedded Key:**
   - *Trade-off:* User must acquire a free Gemini API key from Google AI Studio.
   - *Security Benefit:* Total prevention of developer quota exhaustion, account suspension, or financial liability from extracted client credentials.

---

## 8. Comprehensive Regression Test Matrix

| Test Suite | Scenario / Verification Scope | Expected Assertion |
|---|---|---|
| **SEC-01-U1** | Same-Key Portable Backup & Restore | Restore succeeds; derived balances, postings, and events match bit-for-bit. |
| **SEC-01-U2** | Cross-Device Restore (Device A -> Device B) | Staged database opens on Device B; target database re-encrypts with Key B; derived balances match exactly. |
| **SEC-01-U3** | Fresh-Install Restore (Zero initial key) | Generates local Key C; restores Format v3 archive successfully. |
| **SEC-01-U4** | Wrong Password Rejection | Fails with `InvalidBackupPasswordException`; 0 database mutations. |
| **SEC-01-U5** | Tampered Ciphertext / AAD Bit-Flip | AES-GCM MAC failure triggers `InvalidBackupPasswordException`. |
| **SEC-03-U1** | Post-Verification Cleanup I/O Failure | Live encrypted DB remains intact; `isPlaintextSqliteFile()` returns `false`; migration succeeds with `cleanupPending`. |
| **SEC-03-U2** | Interrupted Crash Recovery in `cleanupPending` | Live DB verified as SQLCipher; stale backup unlinked; journal cleared; 0 rollbacks. |
| **SEC-03-U3** | Pre-Swap Failure Rollback | Failure at `exporting` or `validating` successfully rolls back to pristine plaintext. |
| **SEC-02-U1** | BYOK Key Storage & Retrieval | Key saved to `FlutterSecureStorage`; retrieved accurately in `GeminiService`. |
| **SEC-02-U2** | BYOK Key Deletion & Missing Key Handling | Deleting key sets `hasKey = false`; requests return informative configuration error. |
| **SEC-02-U3** | Log Redaction of User Key | `AppLogger` and `_sanitizeError` redact user key from stack traces and URLs. |

---

## 9. Device Verification Plan

1. **Android Physical Device Testing (Pixel / Samsung Galaxy):**
   - Run release APK on Android 14/15 physical device.
   - Test backup creation with password -> copy `.spendx` to a second physical device via Nearby Share -> restore on Device B with password.
   - Verify double-entry balances match.
2. **App Uninstallation & Reinstallation Test:**
   - Create backup -> Uninstall SpendX (Keystore wiped) -> Reinstall from release APK -> Restore backup. Verify data restored.
3. **Airplane Mode & Kill-Switch Injection:**
   - Force kill (`am force-stop`) during migration cleanup; relaunch app and verify startup logs confirm `cleanStaleMigrationArtifacts()` sweeps leftovers without rollback.

---

## 10. Rollback Strategy

If any regression occurs during implementation of Milestones 4.5A, 4.5B, or 4.5C:
- **Code Rollback:** Each milestone will be committed as an independent, atomic commit. Reverting a milestone requires only `git revert <commit-hash>`.
- **Database Safety:** None of the three milestones alter SQLite table schemas, column definitions, or database migrations (schema version remains strictly 24).
- **Format Fallback:** Format v3 includes `formatVersion: 3`. If format v3 needs rollback, backup validators can fall back to existing formats without corrupting databases.

---

## 11. Explicit Release-Blocking Criteria

SpendX 2.1.0 release gating requires 100% satisfaction of the following criteria:
1. **SEC-01 Cleared:** Two independent database instances with different 256-bit keys must execute `createBackupPackage()` on Instance A and successfully restore via `restoreFromFile()` on Instance B with 0 balance discrepancies.
2. **SEC-02 Cleared:** Release APK must build cleanly with zero embedded API keys, and `GeminiService` must load user keys exclusively from `FlutterSecureStorage`.
3. **SEC-03 Cleared:** Simulated deletion failure of `spendx.db.pre_migration_backup` must return `success: true`, leave the live encrypted database 100% intact, and never invoke `_rollbackSwap()`.
4. **Full Test Suite:** All 996+ tests must pass with Exit Code 0 and 0 analyzer warnings.
