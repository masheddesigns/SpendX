# Android Backup and Restore Security (Package 03)

## Policy

SpendX disables Android Auto Backup and device-to-device transfer for all app data.

| Control | Value |
| --- | --- |
| `android:allowBackup` | `false` |
| `android:fullBackupContent` | `false` |
| `android:dataExtractionRules` | `@xml/data_extraction_rules` |

`android/app/src/main/res/xml/data_extraction_rules.xml` also excludes the `root`,
`file`, `database`, `sharedpref`, and `external` domains for both `cloud-backup`
and `device-transfer` as defence-in-depth.

## What is protected

The exclusions cover:

- the SQLCipher `spendx.db` file and its `-wal` / `-shm` sidecars;
- secure-storage preference containers;
- the pending SMS queue in `SharedPreferences`;
- cached exports and any files written to app storage.

## Why OS backup is disabled

The SQLCipher database key is generated randomly and stored through
`flutter_secure_storage` in the Android Keystore. Android does not include
Keystore key material in Auto Backup or device-transfer payloads. Restoring the
database file without the original key would produce an unreadable database, and
SpendX deliberately refuses to regenerate a key over existing encrypted data.

## Behaviour when the original Keystore key is unavailable

- `SpendXDatabaseKeyManager` reports `DatabaseKeyState.fatalKeyLoss` when an
  encrypted database exists but the key is missing.
- Startup raises `KeyLossFatalException`; the database is not overwritten,
  deleted, or silently re-keyed.
- Restore is also blocked because the staged database cannot be opened and
  validated with the current device key. The active database is left untouched.
- Recovery requires the original Keystore key. There is currently no supported
  key-export or key-escrow path.

## User-controlled backups

`BackupFileService` / `BackupService` write `.spendx` archives through the app's
own storage and Google Drive APIs. These are not affected by `allowBackup=false`.

- Password-protected `.spendx` archives use Argon2id plus AES-256-GCM for the
  archive layer.
- The embedded SQLite snapshot remains SQLCipher-encrypted with the device
  database key. A cross-device restore therefore still requires that key; the
  archive password does not replace it.
- If the key or password is unavailable, validation fails before the active
  database is replaced.

## Verification

Automated coverage lives in
`test/security/android_package03_hardening_test.dart`. It asserts the manifest
flags, extraction-rule exclusions, the non-exported Dynamic Island receiver, the
explicit notification allowlist, and the absence of full notification bodies in
log statements.
