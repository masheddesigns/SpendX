import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/services/sms_inbox_watermark.dart';
import 'package:spend_x/services/sms_recovery_paginator.dart';

import '../../integration_test/helpers/stage5b_preflight_bootstrap.dart';

void main() {
  late Directory tempDir;
  late InMemorySecureStorageAdapter mockStorage;
  late SpendXDatabaseKeyManager keyManager;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DatabaseAccessGate.instance.resetForTesting();
    DatabaseLifecycleCoordinator.instance.markClosed();
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_stage5b_test_');
    await databaseFactory.setDatabasesPath(tempDir.path);
    mockStorage = InMemorySecureStorageAdapter();
    keyManager = SpendXDatabaseKeyManager(
      storageAdapter: mockStorage,
      keyStorageName: Stage5BTestBootstrap.testKeyStorageName,
    );
    Stage5BTestBootstrap.resetStateForTesting();
  });

  tearDown(() async {
    try {
      await Stage5BTestBootstrap.tearDown(deleteDatabaseFile: true, force: true);
    } catch (_) {}
    Stage5BTestBootstrap.resetStateForTesting();
    DatabaseAccessGate.instance.resetForTesting();
    DatabaseLifecycleCoordinator.instance.markClosed();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  PackageInfo getValidPackageInfo() => PackageInfo(
        appName: 'SpendX',
        packageName: Stage5BTestBootstrap.testApplicationId,
        version: '1.0.0',
        buildNumber: '1',
      );

  group('A. Single Public Preflight Entry Point & Target Identifiers', () {
    test('1. Target Test Identifiers strictly adhere to frozen specification', () {
      expect(
        Stage5BTestBootstrap.testDatabaseFilename,
        equals('spendx_stage5b_validation.db'),
      );
      expect(
        Stage5BTestBootstrap.testKeyStorageName,
        equals('spendx_db_test_key_stage5b'),
      );
      expect(
        Stage5BTestBootstrap.testApplicationId,
        equals('com.mashingdesigns.spend_x.stage5b'),
      );
      expect(
        Stage5BTestBootstrap.testRecoveryCheckpointKey,
        equals('spendx.sms.recovery_checkpoint_stage5b'),
      );
      expect(
        Stage5BTestBootstrap.testInboxWatermarkKey,
        equals('spendx.sms.inbox_watermark_stage5b'),
      );
    });

    test('2. Complete 10-step preflight succeeds and registers all isolated overrides', () async {
      await Stage5BTestBootstrap.runPreflightAssertions(
        packageInfoOverride: getValidPackageInfo(),
        keyManagerOverride: keyManager,
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isTrue);
      expect(Stage5BTestBootstrap.state, equals(Stage5BBootstrapState.bootstrapped));
      expect(AppDatabase.instance.isOpen, isTrue);
      expect(AppDatabase.testDatabasePath, equals(Stage5BTestBootstrap.testDatabaseFilename));
      expect(SpendXDatabaseKeyManager.instance.keyStorageName, equals(Stage5BTestBootstrap.testKeyStorageName));
      expect(SmsRecoveryCheckpointStore.activeKey, equals(Stage5BTestBootstrap.testRecoveryCheckpointKey));
      expect(SmsInboxWatermarkStore.activeKey, equals(Stage5BTestBootstrap.testInboxWatermarkKey));

      final db = await AppDatabase.instance.database;
      final version = Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version;'));
      expect(version, anyOf(25, 26));
    });

    test('3. Re-entry after successful bootstrap is rejected', () async {
      await Stage5BTestBootstrap.runPreflightAssertions(
        packageInfoOverride: getValidPackageInfo(),
        keyManagerOverride: keyManager,
      );

      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Stage 5B bootstrap has already been executed'),
        )),
      );
    });
  });

  group('B. Negative-Path Preflight Verification', () {
    test('1. PackageInfo platform failure aborts immediately fail-closed', () async {
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoLoader: () => throw Exception('PLATFORM_CHANNEL_UNAVAILABLE'),
          keyManagerOverride: keyManager,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Failed to query platform package identity'),
        )),
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
      expect(AppDatabase.instance.isOpen, isFalse);
    });

    test('2. Release-mode execution is rejected with UnsupportedError', () async {
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
          simulateReleaseMode: true,
        ),
        throwsA(isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('strictly prohibited in release builds'),
        )),
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
      expect(AppDatabase.instance.isOpen, isFalse);
    });

    test('3. Database opening already in progress is rejected', () async {
      AppDatabase.setTestInitState(AppDatabaseInitState.openingInProgress);

      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('initialization is currently in flight'),
        )),
      );

      AppDatabase.setTestInitState(AppDatabaseInitState.notInitialized);
      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
    });

    test('4. Production key-storage slot name is rejected', () async {
      final prodKeyManager = SpendXDatabaseKeyManager(
        storageAdapter: mockStorage,
        keyStorageName: SpendXDatabaseKeyManager.defaultKeyStorageName, // Production slot!
      );

      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: prodKeyManager,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Active key manager storage slot'),
        )),
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
      expect(AppDatabase.instance.isOpen, isFalse);
    });

    test('5. Incorrect database filename is rejected', () async {
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
          expectedDbFilenameOverride: 'incorrect_name.db',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('does not match expected'),
        )),
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
    });

    test('6. Unexpected canonical directory is rejected', () async {
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
          expectedCanonicalDirectoryOverride: '/unexpected/rogue/dir',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('does not match canonical directory'),
        )),
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
    });

    test('7. Schema version mismatch is rejected', () async {
      // Test A: Step 10 rejection when schema user_version != 25
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
          simulatedUserVersion: 24,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Schema user_version is 24, expected 25'),
        )),
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
      expect(AppDatabase.instance.isOpen, isFalse);
    });

    test('8. Non-empty economic events table is rejected as contaminated', () async {
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
          simulatedEventsCount: 1,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Test database is contaminated! Contains 1 events'),
        )),
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
      expect(AppDatabase.instance.isOpen, isFalse);
    });

    test('9. Non-empty postings table is rejected as contaminated', () async {
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
          simulatedPostingsCount: 1,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Test database is contaminated! Contains 0 events and 1 postings'),
        )),
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
      expect(AppDatabase.instance.isOpen, isFalse);
    });

    test('10. Incorrect SQLite main database path is rejected', () async {
      final unexpectedPath = p.join(tempDir.path, 'unexpected_target.db');
      File(unexpectedPath).writeAsStringSync('');

      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
          simulatedMainDbFile: unexpectedPath,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Active SQLite file handle'),
        )),
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
      expect(AppDatabase.instance.isOpen, isFalse);
    });

    test('11. Failed database initialization aborts fail-closed', () async {
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
          simulateDbOpenFailure: true,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Simulated database open failure'),
        )),
      );

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
      expect(AppDatabase.instance.isOpen, isFalse);
    });

    test('12. Preflight failure rolls back cleanly with ZERO production fallback', () async {
      // Cause failure at Step 4 by dirtying database
      AppDatabase.setTestDatabasePath('dirty_temp.db');
      final db = await AppDatabase.instance.database;
      expect(db.isOpen, isTrue);

      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
        ),
        throwsA(isA<StateError>()),
      );

      // Verify that after preflight failure, production DB/keys are NEVER configured or opened
      await AppDatabase.instance.close();
      AppDatabase.setTestDatabasePath(null);

      expect(Stage5BTestBootstrap.isBootstrapped, isFalse);
      expect(AppDatabase.instance.isOpen, isFalse);
      expect(AppDatabase.testDatabasePath, isNull);
      expect(SpendXDatabaseKeyManager.instance.keyStorageName, equals(SpendXDatabaseKeyManager.defaultKeyStorageName));
      expect(SmsRecoveryCheckpointStore.activeKey, equals(SmsRecoveryCheckpointStore.defaultKey));
      expect(SmsInboxWatermarkStore.activeKey, equals(SmsInboxWatermarkStore.defaultKey));
    });

    test('13. Database close failure during preflight rollback sets rollbackFailed and preserves test overrides', () async {
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
          simulatedUserVersion: 24, // Triggers preflight assertion failure at Step 10
          simulateCloseFailureDuringRollback: true, // Triggers close failure in rollback
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Simulated database close failure during preflight rollback'),
        )),
      );

      // Must enter explicit rollbackFailed state
      expect(Stage5BTestBootstrap.hasRollbackFailed, isTrue);
      expect(Stage5BTestBootstrap.state, equals(Stage5BBootstrapState.rollbackFailed));

      // Overrides must NEVER be reset while connection could be active!
      expect(AppDatabase.testDatabasePath, equals(Stage5BTestBootstrap.testDatabaseFilename));
      expect(SpendXDatabaseKeyManager.instance.keyStorageName, equals(Stage5BTestBootstrap.testKeyStorageName));
      expect(SmsRecoveryCheckpointStore.activeKey, equals(Stage5BTestBootstrap.testRecoveryCheckpointKey));

      // Subsequent bootstrap attempts must be permanently blocked
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Previous rollback failed'),
        )),
      );

      // Cleanup
      await Stage5BTestBootstrap.tearDown(force: true);
      expect(Stage5BTestBootstrap.hasRollbackFailed, isFalse);
    });
  });

  group('C. SMS Recovery-State & Inbox Watermark Isolation', () {
    test('1. Normal unbootstrapped execution uses default production keys', () {
      expect(SmsRecoveryCheckpointStore.activeKey, equals(SmsRecoveryCheckpointStore.defaultKey));
      expect(SmsInboxWatermarkStore.activeKey, equals(SmsInboxWatermarkStore.defaultKey));

      final paginator = SmsRecoveryPaginator();
      expect(paginator.store.key, equals('spendx.sms.recovery_checkpoint'));

      final watermarkStore = SmsInboxWatermarkStore();
      expect(watermarkStore.key, equals('spendx_sms_inbox_watermark_v1'));
    });

    test('2. Stage 5B bootstrap switches paginators and runners to isolated test keys', () async {
      await Stage5BTestBootstrap.runPreflightAssertions(
        packageInfoOverride: getValidPackageInfo(),
        keyManagerOverride: keyManager,
      );

      expect(SmsRecoveryCheckpointStore.activeKey, equals('spendx.sms.recovery_checkpoint_stage5b'));
      expect(SmsInboxWatermarkStore.activeKey, equals('spendx.sms.inbox_watermark_stage5b'));

      final paginator = SmsRecoveryPaginator();
      expect(paginator.store.key, equals('spendx.sms.recovery_checkpoint_stage5b'));

      final watermarkStore = SmsInboxWatermarkStore();
      expect(watermarkStore.key, equals('spendx.sms.inbox_watermark_stage5b'));
    });

    test('3. Stage 5B writes affect only test keys, leaving production keys completely untouched', () async {
      final prefs = await SharedPreferences.getInstance();

      // Seed production keys with baseline data
      await prefs.setString(SmsRecoveryCheckpointStore.defaultKey, '{"startMaxId":999,"sevenDayThresholdMs":1000,"lastProcessedId":999,"isComplete":true}');
      await prefs.setString(SmsInboxWatermarkStore.defaultKey, '{"committed":{"date":2000,"id":888}}');

      // Bootstrap Stage 5B
      await Stage5BTestBootstrap.runPreflightAssertions(
        packageInfoOverride: getValidPackageInfo(),
        keyManagerOverride: keyManager,
      );

      // Write test recovery checkpoint
      final recoveryStore = SmsRecoveryCheckpointStore();
      await recoveryStore.save(const SmsRecoveryCheckpoint(
        startMaxId: 10,
        sevenDayThresholdMs: 50,
        lastProcessedId: 10,
        isComplete: false,
      ));

      // Write test watermark checkpoint
      final watermarkStore = SmsInboxWatermarkStore();
      await watermarkStore.save(const SmsInboxScanCheckpoint(
        committed: SmsInboxCursor(date: 100, id: 20),
      ));

      // Verify Stage 5B keys contain test data
      final testRecoveryRaw = prefs.getString(Stage5BTestBootstrap.testRecoveryCheckpointKey);
      final testWatermarkRaw = prefs.getString(Stage5BTestBootstrap.testInboxWatermarkKey);
      expect(testRecoveryRaw, contains('"startMaxId":10'));
      expect(testWatermarkRaw, contains('"id":20'));

      // CRITICAL: Verify production keys remain COMPLETELY UNTOUCHED!
      expect(prefs.getString(SmsRecoveryCheckpointStore.defaultKey), contains('"startMaxId":999'));
      expect(prefs.getString(SmsInboxWatermarkStore.defaultKey), contains('"id":888'));
    });

    test('4. Teardown restores normal production keys cleanly', () async {
      await Stage5BTestBootstrap.runPreflightAssertions(
        packageInfoOverride: getValidPackageInfo(),
        keyManagerOverride: keyManager,
      );

      expect(SmsRecoveryCheckpointStore.activeKey, equals('spendx.sms.recovery_checkpoint_stage5b'));
      await Stage5BTestBootstrap.tearDown(deleteDatabaseFile: true);

      expect(SmsRecoveryCheckpointStore.activeKey, equals(SmsRecoveryCheckpointStore.defaultKey));
      expect(SmsInboxWatermarkStore.activeKey, equals(SmsInboxWatermarkStore.defaultKey));
    });
  });

  group('D. Teardown Failure Behavior & Fail-Closed State Machine', () {
    test('1. Checkpoint failure leaves overrides active and marks teardownFailed', () async {
      await Stage5BTestBootstrap.runPreflightAssertions(
        packageInfoOverride: getValidPackageInfo(),
        keyManagerOverride: keyManager,
      );

      await expectLater(
        Stage5BTestBootstrap.tearDown(simulateCheckpointFailure: true),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Simulated checkpoint failure'),
        )),
      );

      expect(Stage5BTestBootstrap.hasTeardownFailed, isTrue);
      expect(Stage5BTestBootstrap.state, equals(Stage5BBootstrapState.teardownFailed));

      // Overrides must NOT be reset prematurely!
      expect(AppDatabase.testDatabasePath, equals(Stage5BTestBootstrap.testDatabaseFilename));
      expect(SpendXDatabaseKeyManager.instance.keyStorageName, equals(Stage5BTestBootstrap.testKeyStorageName));
      expect(SmsRecoveryCheckpointStore.activeKey, equals(Stage5BTestBootstrap.testRecoveryCheckpointKey));

      // Subsequent bootstrap attempt must be blocked until failure is resolved
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Previous teardown failed'),
        )),
      );

      // Force teardown cleans up after failure test
      await Stage5BTestBootstrap.tearDown(force: true);
      expect(Stage5BTestBootstrap.hasTeardownFailed, isFalse);
      expect(Stage5BTestBootstrap.state, equals(Stage5BBootstrapState.tornDown));
    });

    test('2. Database close failure leaves overrides active and blocks re-bootstrap', () async {
      await Stage5BTestBootstrap.runPreflightAssertions(
        packageInfoOverride: getValidPackageInfo(),
        keyManagerOverride: keyManager,
      );

      await expectLater(
        Stage5BTestBootstrap.tearDown(simulateCloseFailure: true),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Simulated database close failure'),
        )),
      );

      expect(Stage5BTestBootstrap.hasTeardownFailed, isTrue);
      expect(Stage5BTestBootstrap.state, equals(Stage5BBootstrapState.teardownFailed));

      // Overrides must NOT be reset prematurely!
      expect(AppDatabase.testDatabasePath, equals(Stage5BTestBootstrap.testDatabaseFilename));

      // Subsequent bootstrap is blocked
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Previous teardown failed'),
        )),
      );

      // Force teardown cleanly restores state
      await Stage5BTestBootstrap.tearDown(force: true);
      expect(Stage5BTestBootstrap.hasTeardownFailed, isFalse);
    });

    test('3. Database admission drain failure leaves overrides active and blocks re-bootstrap', () async {
      await Stage5BTestBootstrap.runPreflightAssertions(
        packageInfoOverride: getValidPackageInfo(),
        keyManagerOverride: keyManager,
      );

      await expectLater(
        Stage5BTestBootstrap.tearDown(simulateDrainFailure: true),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Simulated database admission drain failure'),
        )),
      );

      expect(Stage5BTestBootstrap.hasTeardownFailed, isTrue);
      expect(Stage5BTestBootstrap.state, equals(Stage5BBootstrapState.teardownFailed));

      // Overrides must NOT be reset prematurely!
      expect(AppDatabase.testDatabasePath, equals(Stage5BTestBootstrap.testDatabaseFilename));
      expect(SpendXDatabaseKeyManager.instance.keyStorageName, equals(Stage5BTestBootstrap.testKeyStorageName));
      expect(SmsRecoveryCheckpointStore.activeKey, equals(Stage5BTestBootstrap.testRecoveryCheckpointKey));

      // Subsequent bootstrap is blocked
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Previous teardown failed'),
        )),
      );

      await Stage5BTestBootstrap.tearDown(force: true);
      expect(Stage5BTestBootstrap.hasTeardownFailed, isFalse);
    });

    test('4. WAL checkpoint busy result leaves overrides active and blocks re-bootstrap', () async {
      await Stage5BTestBootstrap.runPreflightAssertions(
        packageInfoOverride: getValidPackageInfo(),
        keyManagerOverride: keyManager,
      );

      await expectLater(
        Stage5BTestBootstrap.tearDown(simulateCheckpointBusy: true),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('failed with busy=1'),
        )),
      );

      expect(Stage5BTestBootstrap.hasTeardownFailed, isTrue);
      expect(Stage5BTestBootstrap.state, equals(Stage5BBootstrapState.teardownFailed));

      // Overrides must NOT be reset prematurely!
      expect(AppDatabase.testDatabasePath, equals(Stage5BTestBootstrap.testDatabaseFilename));
      expect(SpendXDatabaseKeyManager.instance.keyStorageName, equals(Stage5BTestBootstrap.testKeyStorageName));

      // Subsequent bootstrap is blocked
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Previous teardown failed'),
        )),
      );

      await Stage5BTestBootstrap.tearDown(force: true);
      expect(Stage5BTestBootstrap.hasTeardownFailed, isFalse);
    });

    test('5. Incomplete WAL checkpoint frames leave overrides active and block re-bootstrap', () async {
      await Stage5BTestBootstrap.runPreflightAssertions(
        packageInfoOverride: getValidPackageInfo(),
        keyManagerOverride: keyManager,
      );

      await expectLater(
        Stage5BTestBootstrap.tearDown(simulateCheckpointIncomplete: true),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('PRAGMA wal_checkpoint(TRUNCATE) incomplete'),
        )),
      );

      expect(Stage5BTestBootstrap.hasTeardownFailed, isTrue);
      expect(Stage5BTestBootstrap.state, equals(Stage5BBootstrapState.teardownFailed));

      // Overrides must NOT be reset prematurely!
      expect(AppDatabase.testDatabasePath, equals(Stage5BTestBootstrap.testDatabaseFilename));

      // Subsequent bootstrap is blocked
      await expectLater(
        Stage5BTestBootstrap.runPreflightAssertions(
          packageInfoOverride: getValidPackageInfo(),
          keyManagerOverride: keyManager,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Previous teardown failed'),
        )),
      );

      await Stage5BTestBootstrap.tearDown(force: true);
      expect(Stage5BTestBootstrap.hasTeardownFailed, isFalse);
    });
  });
}
