import 'dart:io';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/services/sms_inbox_watermark.dart';
import 'package:spend_x/services/sms_recovery_paginator.dart';

/// Lifecycle state machine for [Stage5BTestBootstrap].
enum Stage5BBootstrapState {
  unbootstrapped,
  bootstrapping,
  bootstrapped,
  tearingDown,
  tornDown,
  teardownFailed,
  rollbackFailed,
}

/// Stage 5B Test Isolation Bootstrap & Fail-Closed Preflight Controller.
///
/// Ensures all Stage 5B validation operates exclusively against isolated test
/// resources:
/// - Database: `spendx_stage5b_validation.db`
/// - Keystore slot: `spendx_db_test_key_stage5b`
/// - Android App ID: `com.mashingdesigns.spend_x.stage5b`
/// - Recovery checkpoint key: `spendx.sms.recovery_checkpoint_stage5b`
/// - Inbox watermark key: `spendx.sms.inbox_watermark_stage5b`
///
/// Production database (`spendx.db`) and production key (`spendx_db_master_key_v1`)
/// access is strictly prevented.
class Stage5BTestBootstrap {
  static const String testDatabaseFilename = 'spendx_stage5b_validation.db';
  static const String testKeyStorageName = 'spendx_db_test_key_stage5b';
  static const String testApplicationId = 'com.mashingdesigns.spend_x.stage5b';
  static const String testRecoveryCheckpointKey = 'spendx.sms.recovery_checkpoint_stage5b';
  static const String testInboxWatermarkKey = 'spendx.sms.inbox_watermark_stage5b';

  static Stage5BBootstrapState _state = Stage5BBootstrapState.unbootstrapped;
  static Object? _lastTeardownError;
  static Object? _lastRollbackError;

  /// The current state of the Stage 5B bootstrap controller.
  static Stage5BBootstrapState get state => _state;

  /// Returns true if Stage 5B bootstrap has successfully executed.
  static bool get isBootstrapped => _state == Stage5BBootstrapState.bootstrapped;

  /// Returns true if the most recent teardown operation failed.
  static bool get hasTeardownFailed => _state == Stage5BBootstrapState.teardownFailed;

  /// Returns true if the most recent rollback operation failed.
  static bool get hasRollbackFailed => _state == Stage5BBootstrapState.rollbackFailed;

  /// Returns the error recorded during the last failed teardown, if any.
  static Object? get lastTeardownError => _lastTeardownError;

  /// Returns the error recorded during the last failed rollback, if any.
  static Object? get lastRollbackError => _lastRollbackError;

  /// Strictly private: test overrides CANNOT be configured outside the complete
  /// ordered preflight sequence.
  static void _configureOverrides({
    SpendXDatabaseKeyManager? keyManagerOverride,
  }) {
    AppDatabase.setTestDatabasePath(testDatabaseFilename);
    final keyManager = keyManagerOverride ??
        SpendXDatabaseKeyManager(
          keyStorageName: testKeyStorageName,
        );
    SpendXDatabaseKeyManager.setTestInstance(keyManager);
    SmsRecoveryCheckpointStore.setTestKeyOverride(testRecoveryCheckpointKey);
    SmsInboxWatermarkStore.setTestKeyOverride(testInboxWatermarkKey);
    _state = Stage5BBootstrapState.bootstrapping;
  }

  /// Emergency rollback executed if preflight assertions fail after overrides
  /// have been configured.
  ///
  /// Contract:
  /// - Never reset database-path or key-manager overrides while a connection may
  ///   still be alive.
  /// - Never transition to [Stage5BBootstrapState.unbootstrapped] if rollback
  ///   did not fully complete.
  /// - Enter explicit [Stage5BBootstrapState.rollbackFailed] if closure fails.
  /// - Block subsequent bootstrap attempts.
  /// - Preserve test isolation overrides until safe closure is confirmed.
  static Future<void> _rollbackOverridesOnPreflightFailure({
    bool simulateCloseFailure = false,
  }) async {
    try {
      if (simulateCloseFailure) {
        throw StateError('Simulated database close failure during preflight rollback');
      }

      if (AppDatabase.instance.isOpening) {
        throw StateError('STAGE5B_ROLLBACK_VIOLATION: Database opening is still in progress during rollback.');
      }

      if (AppDatabase.instance.isOpen) {
        await AppDatabase.instance.close();
      }

      if (AppDatabase.instance.isOpen) {
        throw StateError('STAGE5B_ROLLBACK_VIOLATION: AppDatabase failed to close connection during rollback.');
      }

      // Safe closure confirmed: nullify overrides and mark unbootstrapped
      SmsRecoveryCheckpointStore.setTestKeyOverride(null);
      SmsInboxWatermarkStore.setTestKeyOverride(null);
      AppDatabase.setTestDatabasePath(null);
      SpendXDatabaseKeyManager.setTestInstance(null);
      DatabaseLifecycleCoordinator.instance.markClosed();
      _state = Stage5BBootstrapState.unbootstrapped;
      _lastRollbackError = null;
    } catch (e) {
      // Retain test overrides fail-closed: DO NOT reset to production!
      _state = Stage5BBootstrapState.rollbackFailed;
      _lastRollbackError = e;
      rethrow;
    }
  }

  /// Single public entry point executing the complete ordered preflight sequence.
  ///
  /// Enforces:
  /// 1. Platform package identity verification via [PackageInfo.fromPlatform]
  ///    (or [packageInfoLoader] / [packageInfoOverride]).
  /// 2. Non-release execution check.
  /// 3. Bootstrap, teardown, and rollback failure check.
  /// 4. Singleton quiescent lifecycle check.
  /// 5. Private override configuration for database, key slot, and SMS keys.
  /// 6. Registered identifier verification.
  /// 7. Canonical directory and filename validation.
  /// 8. Isolated test database opening.
  /// 9. SQLite `PRAGMA database_list;` verification.
  /// 10. Schema version 25 and clean ledger sentinel verification.
  static Future<void> runPreflightAssertions({
    PackageInfo? packageInfoOverride,
    Future<PackageInfo> Function()? packageInfoLoader,
    SpendXDatabaseKeyManager? keyManagerOverride,
    bool simulateReleaseMode = false,
    String? expectedDbFilenameOverride,
    String? expectedKeySlotOverride,
    String? expectedCanonicalDirectoryOverride,
    int? simulatedUserVersion,
    String? simulatedMainDbFile,
    int? simulatedEventsCount,
    int? simulatedPostingsCount,
    bool cleanStaleTestDatabase = false,
    bool simulateDbOpenFailure = false,
    bool simulateCloseFailureDuringRollback = false,
  }) async {
    // Step 1: Verify actual Android application ID
    final PackageInfo packageInfo;
    if (packageInfoLoader != null) {
      try {
        packageInfo = await packageInfoLoader();
      } catch (e) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Failed to query platform package identity: $e. Aborting fail-closed.',
        );
      }
    } else if (packageInfoOverride != null) {
      packageInfo = packageInfoOverride;
    } else {
      try {
        packageInfo = await PackageInfo.fromPlatform();
      } catch (e) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Failed to query platform package identity: $e. Aborting fail-closed.',
        );
      }
    }

    if (packageInfo.packageName != testApplicationId) {
      throw StateError(
        'STAGE5B_PREFLIGHT_VIOLATION: Application package ID "${packageInfo.packageName}" '
        'does not match required Stage 5B test ID "$testApplicationId". Aborting fail-closed.',
      );
    }

    // Step 2: Verify non-release execution
    if (const bool.fromEnvironment('dart.vm.product') || simulateReleaseMode) {
      throw UnsupportedError(
        'STAGE5B_PREFLIGHT_VIOLATION: Stage 5B preflight is strictly prohibited in release builds.',
      );
    }

    // Step 3: Verify bootstrap state and prior teardown/rollback status
    if (_state == Stage5BBootstrapState.bootstrapped) {
      throw StateError(
        'STAGE5B_PREFLIGHT_VIOLATION: Stage 5B bootstrap has already been executed.',
      );
    }
    if (_state == Stage5BBootstrapState.teardownFailed) {
      throw StateError(
        'STAGE5B_PREFLIGHT_VIOLATION: Previous teardown failed ($_lastTeardownError). '
        'Cannot bootstrap until the teardown failure is resolved.',
      );
    }
    if (_state == Stage5BBootstrapState.rollbackFailed) {
      throw StateError(
        'STAGE5B_PREFLIGHT_VIOLATION: Previous rollback failed ($_lastRollbackError). '
        'Cannot bootstrap until the rollback failure is resolved and database is safely closed.',
      );
    }

    // Step 4: Verify AppDatabase singleton has not been initialized or opened
    if (AppDatabase.instance.isOpen) {
      throw StateError(
        'STAGE5B_PREFLIGHT_VIOLATION: AppDatabase is already open prior to preflight override configuration.',
      );
    }
    if (AppDatabase.instance.isOpening) {
      throw StateError(
        'STAGE5B_PREFLIGHT_VIOLATION: AppDatabase initialization is currently in flight prior to preflight override configuration.',
      );
    }
    if (!AppDatabase.instance.isCleanForBootstrap) {
      throw StateError(
        'STAGE5B_PREFLIGHT_VIOLATION: AppDatabase singleton is not clean for preflight overrides.',
      );
    }

    // Step 5: Configure the test database path, test key manager, and test SMS keys
    _configureOverrides(keyManagerOverride: keyManagerOverride);

    try {
      // Step 6: Verify all registered test identifiers
      final expectedDbName = expectedDbFilenameOverride ?? testDatabaseFilename;
      final expectedKeySlot = expectedKeySlotOverride ?? testKeyStorageName;

      if (AppDatabase.testDatabasePath != expectedDbName) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: AppDatabase test database path "${AppDatabase.testDatabasePath}" '
          'does not match expected "$expectedDbName".',
        );
      }
      if (SpendXDatabaseKeyManager.instance.keyStorageName != expectedKeySlot) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Active key manager storage slot "${SpendXDatabaseKeyManager.instance.keyStorageName}" '
          'does not match expected "$expectedKeySlot".',
        );
      }
      if (SmsRecoveryCheckpointStore.activeKey != testRecoveryCheckpointKey) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Active recovery checkpoint key "${SmsRecoveryCheckpointStore.activeKey}" '
          'does not match expected "$testRecoveryCheckpointKey".',
        );
      }
      if (SmsInboxWatermarkStore.activeKey != testInboxWatermarkKey) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Active inbox watermark key "${SmsInboxWatermarkStore.activeKey}" '
          'does not match expected "$testInboxWatermarkKey".',
        );
      }

      // Step 7: Verify canonical database path before opening
      final dbDir = await getDatabasesPath();
      final expectedRawPath = p.join(dbDir, expectedDbName);
      final parentDir = Directory(p.dirname(expectedRawPath));
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
      final canonicalParent = parentDir.resolveSymbolicLinksSync();
      final expectedCanonicalPath = p.canonicalize(p.join(canonicalParent, expectedDbName));

      final expectedCanonicalDir = expectedCanonicalDirectoryOverride ?? canonicalParent;
      final actualResolvedParent = Directory(p.dirname(expectedRawPath)).resolveSymbolicLinksSync();
      if (actualResolvedParent != expectedCanonicalDir) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Database directory "$actualResolvedParent" does not match canonical directory "$expectedCanonicalDir".',
        );
      }
      if (p.basename(expectedRawPath) != expectedDbName) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Database filename "${p.basename(expectedRawPath)}" does not match required "$expectedDbName".',
        );
      }

      // Clean stale test database if requested (e.g. leftover from a previously crashed test)
      if (cleanStaleTestDatabase && expectedDbName == testDatabaseFilename) {
        try {
          final staleFile = File(expectedRawPath);
          if (staleFile.existsSync()) staleFile.deleteSync();
          final wal = File('$expectedRawPath-wal');
          if (wal.existsSync()) wal.deleteSync();
          final shm = File('$expectedRawPath-shm');
          if (shm.existsSync()) shm.deleteSync();
        } catch (_) {}
      }

      // Step 8: Open the test database
      if (simulateDbOpenFailure) {
        throw StateError('Simulated database open failure');
      }
      final db = await AppDatabase.instance.database;

      // Step 9: Assert active SQLite handle against expected canonical path
      final dbList = await db.rawQuery('PRAGMA database_list;');
      final mainDb = dbList.firstWhere(
        (row) => row['name'] == 'main',
        orElse: () => throw StateError('STAGE5B_PREFLIGHT_VIOLATION: "main" database is not attached in PRAGMA database_list.'),
      );
      final attachedFile = simulatedMainDbFile ?? (mainDb['file'] as String?);
      if (attachedFile == null || attachedFile.isEmpty) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Attached database file is null or in-memory, expected on-disk isolated database.',
        );
      }

      if (!File(attachedFile).existsSync()) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Active SQLite file handle "$attachedFile" does not exist on disk.',
        );
      }
      final canonicalAttachedFile = File(attachedFile).resolveSymbolicLinksSync();
      if (p.canonicalize(canonicalAttachedFile) != expectedCanonicalPath) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Active SQLite file handle "$canonicalAttachedFile" does not match expected canonical test path "$expectedCanonicalPath".',
        );
      }

      // Step 10: Schema and ledger state verification
      final actualUserVersion = Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version;')) ?? 0;
      final userVersion = simulatedUserVersion ?? actualUserVersion;
      if (userVersion != 25 && userVersion != 26) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Schema user_version is $userVersion, expected 25 or 26.',
        );
      }

      // Ledger sentinel check: ensure canonical tables exist and contain zero contamination
      final actualEventsCount = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM economic_events;'),
          ) ??
          0;
      final actualPostingsCount = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM postings;'),
          ) ??
          0;

      final eventsCount = simulatedEventsCount ?? actualEventsCount;
      final postingsCount = simulatedPostingsCount ?? actualPostingsCount;

      if (eventsCount != 0 || postingsCount != 0) {
        throw StateError(
          'STAGE5B_PREFLIGHT_VIOLATION: Test database is contaminated! Contains $eventsCount events and $postingsCount postings.',
        );
      }

      _state = Stage5BBootstrapState.bootstrapped;
    } catch (e) {
      // Emergency rollback: ensure overrides are torn down with NO fallback to production DB/keys
      await _rollbackOverridesOnPreflightFailure(
        simulateCloseFailure: simulateCloseFailureDuringRollback,
      );
      rethrow;
    }
  }

  /// Safe teardown sequence for Stage 5B test environment.
  ///
  /// Contract:
  /// If draining, WAL checkpointing, or database closure fails:
  /// - Overrides are NOT reset prematurely.
  /// - Bootstrap is NOT marked as successfully torn down.
  /// - Sets state to [Stage5BBootstrapState.teardownFailed].
  /// - Blocks subsequent bootstrap attempts until resolved.
  static Future<void> tearDown({
    bool deleteDatabaseFile = false,
    bool simulateDrainFailure = false,
    bool simulateCheckpointFailure = false,
    bool simulateCheckpointBusy = false,
    bool simulateCheckpointIncomplete = false,
    bool simulateCloseFailure = false,
    bool force = false,
  }) async {
    _state = Stage5BBootstrapState.tearingDown;

    try {
      // 1. Drain database admission gate before any checkpointing or closure
      if (simulateDrainFailure) {
        throw StateError('Simulated database admission drain failure');
      }

      if (DatabaseAccessGate.instance.isOpen) {
        await DatabaseAccessGate.instance.closeAdmissionAndDrain();
      }

      if (DatabaseAccessGate.instance.isOpen) {
        throw StateError('STAGE5B_TEARDOWN_VIOLATION: DatabaseAccessGate could not be closed and drained.');
      }

      // 2. Truncate WAL checkpoint if database connection is open
      if (simulateCheckpointFailure) {
        throw StateError('Simulated checkpoint failure');
      }

      if (AppDatabase.instance.isOpen) {
        final res = await AppDatabase.instance.checkpointWal();
        final busyVal = res['busy'] ?? 0;
        final logVal = res['log'] ?? 0;
        final checkpointedVal = res['checkpointed'] ?? 0;

        final busy = simulateCheckpointBusy ? 1 : busyVal;

        if (busy != 0) {
          throw StateError(
            'STAGE5B_TEARDOWN_VIOLATION: PRAGMA wal_checkpoint(TRUNCATE) failed with busy=$busy (log=$logVal, checkpointed=$checkpointedVal).',
          );
        }
        if (simulateCheckpointIncomplete || (logVal > 0 && checkpointedVal < logVal)) {
          final effectiveLog = logVal == 0 ? 10 : logVal;
          final effectiveCheckpointed = logVal == 0 ? 5 : checkpointedVal;
          throw StateError(
            'STAGE5B_TEARDOWN_VIOLATION: PRAGMA wal_checkpoint(TRUNCATE) incomplete: checkpointed $effectiveCheckpointed of $effectiveLog frames.',
          );
        }
      }

      // 3. Close database connection
      if (simulateCloseFailure) {
        throw StateError('Simulated database close failure');
      }

      await AppDatabase.instance.close();
      if (AppDatabase.instance.isOpen) {
        throw StateError('STAGE5B_TEARDOWN_VIOLATION: AppDatabase failed to close connection.');
      }

      // Draining, checkpointing, and closing succeeded — now safe to reset overrides
      SmsRecoveryCheckpointStore.setTestKeyOverride(null);
      SmsInboxWatermarkStore.setTestKeyOverride(null);
      AppDatabase.setTestDatabasePath(null);
      SpendXDatabaseKeyManager.setTestInstance(null);

      // 4. Delete test database file if requested
      if (deleteDatabaseFile) {
        try {
          final dbDir = await getDatabasesPath();
          final dbPathToDelete = p.join(dbDir, testDatabaseFilename);
          final file = File(dbPathToDelete);
          if (file.existsSync()) file.deleteSync();
          final wal = File('$dbPathToDelete-wal');
          if (wal.existsSync()) wal.deleteSync();
          final shm = File('$dbPathToDelete-shm');
          if (shm.existsSync()) shm.deleteSync();
        } catch (e) {
          throw StateError('Failed to delete test database file: $e');
        }
      }

      // 5. Ensure lifecycle coordinator is marked closed
      DatabaseLifecycleCoordinator.instance.markClosed();

      _state = Stage5BBootstrapState.tornDown;
      _lastTeardownError = null;
    } catch (e) {
      if (force) {
        try {
          await DatabaseAccessGate.instance.closeAdmissionAndDrain();
        } catch (_) {}
        SmsRecoveryCheckpointStore.setTestKeyOverride(null);
        SmsInboxWatermarkStore.setTestKeyOverride(null);
        AppDatabase.setTestDatabasePath(null);
        SpendXDatabaseKeyManager.setTestInstance(null);
        try {
          await AppDatabase.instance.close();
        } catch (_) {}
        DatabaseLifecycleCoordinator.instance.markClosed();
        _state = Stage5BBootstrapState.tornDown;
        _lastTeardownError = null;
        _lastRollbackError = null;
      } else {
        _state = Stage5BBootstrapState.teardownFailed;
        _lastTeardownError = e;
      }
      rethrow;
    }
  }

  /// Test-only seam to explicitly reset the controller state after testing
  /// teardown or rollback failures.
  static void resetStateForTesting() {
    _state = Stage5BBootstrapState.unbootstrapped;
    _lastTeardownError = null;
    _lastRollbackError = null;
  }
}
