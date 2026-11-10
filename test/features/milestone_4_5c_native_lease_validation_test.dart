import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/restore_recovery_service.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

import 'milestone_4_5c_harness.dart';

/// Controllable mock of PlatformProcessLockService for testing token validation behavior.
class ControllableValidationMockLockService implements PlatformProcessLockService {
  bool isExclusiveHeld = false;
  String? currentRestoreToken;
  String? currentEngineId;
  bool forceValidationFailure = false;
  bool simulateCrossEngineMismatch = false;
  int? failOnValidationCallIndex;
  int validationCallCount = 0;
  final List<String> eventLog = [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    return 'mock_fg_lease';
  }

  @override
  Future<bool> releaseForegroundLease({
    required String leaseToken,
    String engineId = 'main_engine',
  }) async {
    return true;
  }

  @override
  Future<String> beginExclusiveRestore({
    int drainTimeoutMs = 5000,
    int contentionTimeoutMs = 5000,
  }) async {
    eventLog.add('beginExclusiveRestore');
    isExclusiveHeld = true;
    currentEngineId = 'engine_main';
    currentRestoreToken = 'test_token_${DateTime.now().millisecondsSinceEpoch}';
    return currentRestoreToken!;
  }

  @override
  Future<bool> completeExclusiveRestore(String restoreToken) async {
    eventLog.add('completeExclusiveRestore:$restoreToken');
    if (currentRestoreToken != restoreToken) return false;
    currentRestoreToken = null;
    currentEngineId = null;
    isExclusiveHeld = false;
    return true;
  }

  @override
  Future<bool> abortExclusiveRestore(String restoreToken) async {
    eventLog.add('abortExclusiveRestore:$restoreToken');
    if (currentRestoreToken != restoreToken) return false;
    currentRestoreToken = null;
    currentEngineId = null;
    isExclusiveHeld = false;
    return true;
  }

  @override
  Future<bool> validateExclusiveRestoreToken(String restoreToken) async {
    validationCallCount++;
    eventLog.add('validateExclusiveRestoreToken:$restoreToken');
    if (failOnValidationCallIndex != null && validationCallCount >= failOnValidationCallIndex!) {
      return false;
    }
    if (forceValidationFailure) return false;
    if (simulateCrossEngineMismatch) return false;
    if (restoreToken.trim().isEmpty) return false;
    if (!isExclusiveHeld) return false;
    if (restoreToken != currentRestoreToken) return false;
    return true;
  }

  @override
  Future<Map<String, dynamic>> getLockStatus() async {
    return {
      'state': isExclusiveHeld ? 'EXCLUSIVE_HELD' : 'OPEN',
      'exclusiveHeld': isExclusiveHeld,
      'currentRestoreToken': currentRestoreToken,
      'currentEngineId': currentEngineId,
    };
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late String disposableDbPath;
  late ControllableValidationMockLockService mockLockService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spendx_m45c_lease_val_');
    disposableDbPath = p.join(tempDir.path, SpendXM45CDisposableIsolation.qualificationDbName);
    AppDatabase.setTestDatabasePath(disposableDbPath);
    SpendXM45CDisposableIsolation.activateIsolation();

    mockLockService = ControllableValidationMockLockService();
    PlatformProcessLockService.instanceForTesting = mockLockService;
    DatabaseAccessGate.instanceForTesting = DatabaseAccessGate();
    DatabaseLifecycleCoordinator.instance.resetForTesting();
  });

  tearDown(() async {
    try {
      await AppDatabase.instance.close();
    } catch (_) {}
    AppDatabase.setTestDatabasePath(null);
    SpendXM45CDisposableIsolation.deactivateIsolation();
    BackupService.resetTestingFlags();
    PlatformProcessLockService.instanceForTesting = null;
    DatabaseAccessGate.instanceForTesting = DatabaseAccessGate();
    DatabaseLifecycleCoordinator.instance.resetForTesting();

    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  Future<void> createValidDatabase(String path) async {
    final db = await openDatabase(
      path,
      version: 24,
      onCreate: (d, v) async {
        await TablesV24.createAllV24(d);
        await TablesV24.seedSystemAccounts(d);
        await TablesV24.installTriggers(d);
        final now = DateTime.now().toUtc().toIso8601String();
        await d.insert(TablesV24.accounts, {
          'id': 'acc_val_seed',
          'name': 'Validation Account',
          'account_type': 'asset',
          'subtype': 'checking',
          'currency': 'INR',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        });
      },
    );
    await db.close();
  }

  Future<File> createTestBackupPackage(String filename) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final uid = DateTime.now().microsecondsSinceEpoch;

    await db.insert(TablesV24.accounts, {
      'id': 'acc_val_test_$uid',
      'name': 'Validation Seed Account',
      'account_type': 'asset',
      'subtype': 'checking',
      'currency': 'INR',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });

    final pkg = await BackupService.instance.createBackupPackage();
    final targetFile = File(p.join(tempDir.path, filename));
    await pkg.$1.copy(targetFile.path);
    return targetFile;
  }

  group('Milestone 4.5C — Native Exclusive Lease Validation Gate', () {
    test('1. Direct Token Validation: Fails closed on empty, wrong token, wrong engine, or non-exclusive state', () async {
      // 1. Unacquired / non-exclusive state
      expect(
        await PlatformProcessLockService.instance.validateExclusiveRestoreToken('token_123'),
        isFalse,
      );

      // 2. Empty or blank token
      expect(
        await PlatformProcessLockService.instance.validateExclusiveRestoreToken(''),
        isFalse,
      );
      expect(
        await PlatformProcessLockService.instance.validateExclusiveRestoreToken('   '),
        isFalse,
      );

      // 3. Acquire valid lease
      final validToken = await PlatformProcessLockService.instance.beginExclusiveRestore();
      expect(validToken, isNotEmpty);

      // Valid token with default bound engine matches
      expect(
        await PlatformProcessLockService.instance.validateExclusiveRestoreToken(validToken),
        isTrue,
      );

      // Wrong token fails
      expect(
        await PlatformProcessLockService.instance.validateExclusiveRestoreToken('spoofed_token_999'),
        isFalse,
      );

      // Cross-engine validation mismatch strictly fails closed
      mockLockService.simulateCrossEngineMismatch = true;
      expect(
        await PlatformProcessLockService.instance.validateExclusiveRestoreToken(validToken),
        isFalse,
      );
      mockLockService.simulateCrossEngineMismatch = false;

      // Complete lease -> subsequent validation fails closed
      await PlatformProcessLockService.instance.completeExclusiveRestore(validToken);
      expect(
        await PlatformProcessLockService.instance.validateExclusiveRestoreToken(validToken),
        isFalse,
      );
    });

    test('2. BackupService: Mutation blocked and active database preserved when validation fails before atomic replace', () async {
      await createValidDatabase(disposableDbPath);
      final packageFile = await createTestBackupPackage('valid_restore_pkg.spendx');
      final activeFile = File(disposableDbPath);
      final originalLength = await activeFile.length();
      expect(originalLength, greaterThan(0));

      // Force native validation to fail during replacement
      mockLockService.forceValidationFailure = true;

      // Invoking restore must fail fast when exclusive lease validation fails
      expect(
        () async => await BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('native exclusive restore lease validation failed'),
        )),
      );

      // Active database file remains intact and unmutated
      expect(await activeFile.exists(), isTrue);
      expect(await activeFile.length(), equals(originalLength));

      // No residual swap or backup files created
      final swapFile = File('$disposableDbPath.new_swap');
      final backupFile = File('$disposableDbPath.pre_restore_backup');
      expect(await swapFile.exists(), isFalse);
      expect(await backupFile.exists(), isFalse);
    });

    test('3. RestoreRecoveryService: Helper _executeWithExclusiveLock aborts when live validation fails', () async {
      await createValidDatabase(disposableDbPath);
      final swapFile = File('$disposableDbPath.new_swap');
      await swapFile.writeAsString('stale_swap_mutation_candidate');

      // Force validation to fail on mock lock service
      mockLockService.forceValidationFailure = true;

      // Attempt recovery: must abort when live token validation fails in _executeWithExclusiveLock
      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: disposableDbPath),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('exclusive restore token validation failed'),
        )),
      );

      // Sibling swap file was NOT mutated/quarantined because exclusive lock validation aborted operation
      expect(await swapFile.exists(), isTrue);
    });

    test('4. BackupService: Rollback failure due to token invalidation enforces permanent quarantine', () async {
      await createValidDatabase(disposableDbPath);
      final packageFile = await createTestBackupPackage('valid_restore_pkg_4.spendx');

      // Trigger rollback by injecting rename failure
      BackupService.failFirstRenameForTesting = true;

      // Allow validations before the rename failure to succeed, but fail on rollback validation
      mockLockService.failOnValidationCallIndex = 4;

      // Restore must rethrow RestoreQuarantinedException to fail closed
      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<RestoreQuarantinedException>().having(
          (e) => e.message,
          'message',
          contains('exclusive restore lease validation failed'),
        )),
      );
    });

    test('5. Backup Creation Semantics: Operates under valid shared admission and fails closed when shared admission is unavailable', () async {
      await createValidDatabase(disposableDbPath);
      final activeFile = File(disposableDbPath);
      expect(await activeFile.exists(), isTrue);

      // A. When admission is OPEN (normal shared operation):
      final packageA = await BackupService.instance.createBackupPackage();
      expect(await packageA.$1.exists(), isTrue);
      expect(packageA.$2.databaseSha256, isNotEmpty);
      expect(DatabaseAccessGate.instance.isOpen, isTrue);

      // B. When admission is CLOSED (e.g. exclusive restore in flight):
      await DatabaseAccessGate.instance.closeAdmissionAndDrain();
      expect(DatabaseAccessGate.instance.isOpen, isFalse);

      // Creating a backup package MUST fail closed immediately because shared admission is unavailable
      await expectLater(
        () => BackupService.instance.createBackupPackage(),
        throwsA(isA<DatabaseGateClosedException>()),
      );

      // C. Re-opening admission restores normal shared backup capability
      await DatabaseAccessGate.instance.reopenAdmission();
      expect(DatabaseAccessGate.instance.isOpen, isTrue);
      final packageB = await BackupService.instance.createBackupPackage();
      expect(await packageB.$1.exists(), isTrue);
    });
  });
}
