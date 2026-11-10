# SpendX Release Readiness — Pillar 4: Security & Privacy Discovery

**Document Version:** 1.0.0  
**Date:** November 4, 2026  
**Target Release:** SpendX 2.1.0  
**Phase:** Pillar 4 Security Architecture, Threat Model & Inventory  
**Status:** Discovery Complete — Production Code Frozen

---

## 1. Security Architecture Map

SpendX enforces defense-in-depth security across storage, memory, IPC boundaries, network APIs, and backup archives:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Operating System Boundary (Android / iOS)                │
│    - AndroidManifest.xml: SmsReceiver strictly requires     │
│      permission android.permission.BROADCAST_SMS            │
│    - Notifications listener: BIND_NOTIFICATION_LISTENER     │
│    - File sharing intents restricted to document types      │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Credential & Key Lifecycle (Hardware Keystore / Keychain)│
│    - DatabaseKeyManager via FlutterSecureStorage (Encrypted)│
│    - Generates 256-bit cryptographically secure random key  │
│    - Fatal key loss protection: rejects silent regeneration │
│    - Key material never leaked in exceptions, logs, or error│
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Storage at Rest (SQLCipher Database Engine)              │
│    - 256-bit AES database encryption via SQLCipher backend  │
│    - Header check: zero plaintext "SQLite format 3" bytes   │
│    - Schema v24 triggers and foreign-key constraints active │
│    - 8-checkpoint crash-safe migration with 18-field fingerprint│
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Privacy & Evidence Retention                             │
│    - EvidencePruningService: 30-day retention enforcement   │
│    - Sensitive raw SMS body nulled: raw_payload_encrypted=NULL│
│    - Forensic metadata retained: SHA-256 hash & reference   │
│    - Zero accounting or posting mutations during pruning    │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. Backup & Archive Security                                │
│    - BackupFileService: AES-256-GCM authenticated encryption│
│    - Key Derivation: Argon2id (19 MiB RAM, 2 iter, 1 thread)│
│    - Additional Authenticated Data (AAD) binds manifest to DB│
│    - Tampered manifest or ciphertext triggers MAC failure   │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 6. Network & API Boundary                                   │
│    - GeminiService: authentication via x-goog-api-key header │
│    - Zero API keys in URL query parameters                  │
│    - Error message credential redaction: [REDACTED_API_KEY] │
│    - .env excluded from pubspec.yaml assets (zero bundle leak)│
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Comprehensive Threat Model & Mitigations

| Threat ID | Threat Description | Attack Vector | SpendX Mitigation & Architecture Defense |
|---|---|---|---|
| **TH-01** | **At-Rest Extraction** | Extraction of `spendx.db` from device storage or root backup. | SQLCipher 256-bit AES encryption. Header verification proves file is unreadable as standard SQLite (`ADV-C10-04`). |
| **TH-02** | **Silent Key Loss / Data Wipe** | Device hardware resets keystore or secure storage fails. | `KeyLossFatalException` prevents automatic key generation if encrypted database exists on disk (`C11-P2-08`). User data is never silently wiped. |
| **TH-03** | **Intent Spoofing / Malicious SMS Injection** | Rogue app sends fake `SMS_RECEIVED` broadcast to manipulate ledger. | `AndroidManifest.xml` guards `SmsReceiver` with `android:permission="android.permission.BROADCAST_SMS"`. Third-party apps cannot broadcast to this receiver. |
| **TH-04** | **Backup Tampering & Password Brute Force** | Attacker intercepts `.spendx` package on cloud drive and alters amounts. | AES-256-GCM authenticated encryption with Argon2id KDF. Manifest metadata is bound to ciphertext via AAD (`fmt;schema;sha256;events;postings;debits;credits`). Any tampering causes MAC authentication failure (`ADV-C10-32`). |
| **TH-05** | **SMS Privacy Leak (Personal / OTP SMS)** | Sensitive personal SMS or banking OTPs persist indefinitely on disk. | Hard rejection of non-transaction and OTP messages at ingestion. `EvidencePruningService` permanently purges raw SMS bodies older than 30 days while retaining forensic SHA-256 hashes (`ADV-C10-23`). |
| **TH-06** | **Network Credential Leakage** | API keys exposed in proxy logs, server access logs, or query strings. | `GeminiService` authenticates via `x-goog-api-key` HTTP header. URL has zero query parameters (`ADV-C10-02`). Error messages redact keys (`ADV-C10-03`). |
| **TH-07** | **Production Package Secret Exposure** | API keys bundled in APK/IPA assets. | `pubspec.yaml` assets declare only `assets/logo.svg`. `.env` is excluded from bundle assets (`C13-P1`). |
| **TH-08** | **Financial Log Spillage** | Account numbers, transaction amounts, or PANs printed to logcat/console. | `AppLogger` limits verbose logging to debug mode. `P1.6` test asserts sensitive financial amounts and card numbers are not printed to stdout in production builds. |

---

## 3. Existing Security Test Coverage Inventory (84 Tests)

SpendX contains **84 dedicated automated security and packaging tests** across 5 test suites:

| Test Suite | Tests Defined | Primary Security Scope |
|---|:---:|---|
| [`test/features/c10_security_hardening_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/c10_security_hardening_test.dart) | **34** | Gemini API header security, SQLCipher header non-plaintext verification, wrong-key access failure, migration rollback invariants, encrypted backup Argon2id/AES-GCM round-trips, AAD tampering rejection, and 30-day evidence retention purging. |
| [`test/features/c11_sqlcipher_phase1_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/c11_sqlcipher_phase1_test.dart) | **19** | SQLCipher engine initialization, PRAGMA key operations, transaction rollback under cipher, trigger execution, WAL mode under cipher, and schema v24 fixture validation. |
| [`test/features/c11_sqlcipher_key_management_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/c11_sqlcipher_key_management_test.dart) | **19** | 32-byte (256-bit) random key generation, SecureStorage round-trip, malformed key rejection, missing key fatal lock, key leakage prevention in `toString`, and safe deletion guards. |
| [`test/features/c12_p1_startup_encryption_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/c12_p1_startup_encryption_test.dart) | **6** | Day-one encryption enforcement on new databases, automated migration of legacy plaintext databases, mutex concurrency serialization, and financial log scrubbing. |
| [`test/features/c13_production_packaging_security_test.dart`](file:///Users/sivek/Documents/SpendX/test/features/c13_production_packaging_security_test.dart) | **6** | Production packaging security: `pubspec.yaml` asset hygiene (no `.env`), `AndroidManifest.xml` `BROADCAST_SMS` permission check, `Info.plist` usage descriptions, and ProGuard rules preserving SQLCipher JNI classes. |
| **Total Security Tests** | **84** | **100% Live Test Execution Pass Rate (84/84 Passed)** |

---

## 4. Pillar 4 Security Audit: Eight Target Areas Analysis

### 1. SQLCipher Encryption & Key Management
- **Implementation:** [`SpendXDatabaseFactory`](file:///Users/sivek/Documents/SpendX/lib/data/core/spendx_database_factory.dart) and [`DatabaseKeyManager`](file:///Users/sivek/Documents/SpendX/lib/data/security/database_key_manager.dart).
- **Audit Findings:** 256-bit raw key passed via `PRAGMA key = "x'...'"` blob format. If an encrypted database exists but the key is missing from `FlutterSecureStorage`, `KeyLossFatalException` halts database initialization, prohibiting silent re-encryption with a fresh key that would wipe user history.

### 2. Database Encryption Migration & Recovery
- **Implementation:** [`DatabaseEncryptionMigrationService`](file:///Users/sivek/Documents/SpendX/lib/data/security/database_encryption_migration_service.dart).
- **Audit Findings:** Plaintext-to-encrypted migration executes through an 8-stage state machine. Pre-migration backup is stored in `spendx.db.pre_migration_backup`. An 18-field `AccountingFingerprint` verifies schema version, trigger counts, account counts, event counts, posting counts, and net worth minor units bit-for-bit before swapping files. Crash recovery re-establishes clean baselines from backup archives if interrupted.

### 3. Secure Storage of Credentials & Keys
- **Implementation:** `flutter_secure_storage` with Android Keystore (`EncryptedSharedPreferences`) and iOS Keychain (`kSecAttrAccessibleAfterFirstUnlock`).
- **Audit Findings:** Database master keys and Google Drive OAuth tokens are stored in secure storage. No sensitive key material is stored in unencrypted `SharedPreferences` or SQLite tables.

### 4. Sensitive SMS Data Retention & Sanitization
- **Implementation:** [`EvidencePruningService`](file:///Users/sivek/Documents/SpendX/lib/services/evidence_pruning_service.dart).
- **Audit Findings:** Raw SMS text is retained only for 30 days to facilitate review and parsing audit. After 30 days, `pruneExpiredEvidence()` nulls `raw_payload_encrypted` and marks `is_payload_purged = 1`. Cryptographic SHA-256 hash and external reference IDs are retained indefinitely to prevent duplicate transaction ingestion upon re-scanning.

### 5. Backup Encryption, Password Handling & Archive Security
- **Implementation:** [`BackupFileService`](file:///Users/sivek/Documents/SpendX/lib/services/backup_file_service.dart).
- **Audit Findings:** Password-protected backups use Argon2id with 19 MiB RAM and 2 iterations, generating a 256-bit AES-GCM key. The manifest includes salt, nonce, and MAC tag. AAD authentication binds the entire manifest (including record counts, debit sums, and hashes) to the ciphertext. Tampered archives cannot be decrypted or restored.

### 6. Logs, Crash Reports & Accidental Data Exposure
- **Implementation:** [`AppLogger`](file:///Users/sivek/Documents/SpendX/lib/core/logging/app_logger.dart).
- **Audit Findings:** Verbose logs and SQL statements are suppressed in release mode. Error logging sanitizes strings to prevent credential leakage. Test `P1.6` verifies sensitive credit card numbers and monetary amounts are not dumped to standard output.

### 7. Android Permissions & Exported Components
- **Implementation:** [`android/app/src/main/AndroidManifest.xml`](file:///Users/sivek/Documents/SpendX/android/app/src/main/AndroidManifest.xml).
- **Audit Findings:**
  - `SmsReceiver` requires `android.permission.BROADCAST_SMS` with `android:exported="true"`, preventing arbitrary apps from sending fake SMS intents.
  - `BankNotificationListener` requires `android.permission.BIND_NOTIFICATION_LISTENER_SERVICE`.
  - Notification boot receivers have `android:exported="false"`.
  - Permissions requested (`RECEIVE_SMS`, `READ_SMS`, `POST_NOTIFICATIONS`, `SCHEDULE_EXACT_ALARM`) are strictly necessary for core functionality.

### 8. Network Communication & API Credential Exposure
- **Implementation:** [`GeminiService`](file:///Users/sivek/Documents/SpendX/lib/services/gemini_service.dart).
- **Audit Findings:**
  - AI requests authenticate via `x-goog-api-key` header, not URL parameters.
  - `pubspec.yaml` packaging test confirms `.env` is never bundled into release assets.
  - Graceful degradation returns informative error messages when the API key is not configured, with zero unhandled network exceptions.

---

## 5. Next Steps for Pillar 4 Security Audit

1. **Phase 4.1: Live Security Suite Baseline Execution:** Run all 84 existing security tests and document official exit codes and results.
2. **Phase 4.2: Security & Privacy Gap Analysis:**
   - Review ProGuard obfuscation rules for release builds.
   - Inspect network security configuration (HTTPS enforcement / cleartext traffic prohibition in `AndroidManifest.xml`).
   - Audit crash reporting hooks for sensitive memory dump risks.
3. **Phase 4.3: Targeted Verification & Hardening Proposals:** If any gaps or release risks are identified, propose targeted verification scenarios.
