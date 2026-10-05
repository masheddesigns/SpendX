import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/write_queue.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/live_sms_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory testDir;
  late String dbPath;

  setUpAll(() async {
    await SpendXDatabaseFactory.instance.initialize();
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    testDir = await Directory.systemTemp.createTemp('spendx_c12_p2_test_');
    dbPath = p.join(testDir.path, 'lifecycle_test.db');
    AppDatabase.setTestDatabasePath(dbPath);
    DatabaseLifecycleCoordinator.instance.resetForTesting();
    WriteQueue.instance.resetForTesting();
  });

  tearDown(() async {
    try {
      await AppDatabase.instance.close();
    } catch (_) {}
    DatabaseLifecycleCoordinator.instance.resetForTesting();
    WriteQueue.instance.resetForTesting();
    AppDatabase.setTestDatabasePath(null);
    try {
      if (await testDir.exists()) {
        await testDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Milestone C12-P2: Database Lifecycle & Mutual Exclusion', () {
    // ──────────────────────────────────────────────────────────────────────────
    // P2.1 & P2.6 — Mutual Exclusion & Lifecycle State Coordinator
    // ──────────────────────────────────────────────────────────────────────────
    test('P2.1 — Mutually exclusive operations reject concurrent execution', () async {
      final coordinator = DatabaseLifecycleCoordinator.instance;
      expect(coordinator.currentState, DatabaseLifecycleState.active);
      expect(coordinator.canWrite, isTrue);

      // 1. Begin migration
      await coordinator.beginMigration();
      expect(coordinator.currentState, DatabaseLifecycleState.migrating);
      expect(coordinator.canWrite, isFalse);
      expect(coordinator.isExclusiveOperationRunning, isTrue);

      // Attempting concurrent migration, backup, or restore must fail
      expect(
        () => coordinator.beginMigration(),
        throwsA(isA<DatabaseLifecycleConflictException>()),
      );
      expect(
        () => coordinator.beginBackup(),
        throwsA(isA<DatabaseLifecycleConflictException>()),
      );
      expect(
        () => coordinator.beginRestore(),
        throwsA(isA<DatabaseLifecycleConflictException>()),
      );

      // Release migration
      coordinator.endMigration();
      expect(coordinator.currentState, DatabaseLifecycleState.active);
      expect(coordinator.canWrite, isTrue);

      // 2. Begin backup
      await coordinator.beginBackup();
      expect(coordinator.currentState, DatabaseLifecycleState.backingUp);
      expect(coordinator.canWrite, isFalse);

      expect(
        () => coordinator.beginMigration(),
        throwsA(isA<DatabaseLifecycleConflictException>()),
      );
      expect(
        () => coordinator.beginRestore(),
        throwsA(isA<DatabaseLifecycleConflictException>()),
      );

      coordinator.endBackup();
      expect(coordinator.currentState, DatabaseLifecycleState.active);

      // 3. Begin restore
      await coordinator.beginRestore();
      expect(coordinator.currentState, DatabaseLifecycleState.restoring);
      expect(coordinator.canWrite, isFalse);

      expect(
        () => coordinator.beginMigration(),
        throwsA(isA<DatabaseLifecycleConflictException>()),
      );
      expect(
        () => coordinator.beginBackup(),
        throwsA(isA<DatabaseLifecycleConflictException>()),
      );

      coordinator.endRestore();
      expect(coordinator.currentState, DatabaseLifecycleState.active);
    });

    // ──────────────────────────────────────────────────────────────────────────
    // P2.2 — WriteQueue Coordination During Lifecycle Pivots
    // ──────────────────────────────────────────────────────────────────────────
    test('P2.2 — WriteQueue pauses financial writes during pivot and resumes in order', () async {
      final coordinator = DatabaseLifecycleCoordinator.instance;
      final queue = WriteQueue.instance;
      final executionLog = <String>[];

      // Enqueue initial write when active
      await queue.enqueue(() async {
        executionLog.add('write_1');
      });
      expect(executionLog, ['write_1']);

      // Transition to RESTORING pivot
      await coordinator.beginRestore();

      // Enqueue mutations while restore is in progress
      bool task2Completed = false;
      bool task3Completed = false;

      final f2 = queue.enqueue(() async {
        executionLog.add('write_2');
        task2Completed = true;
      });
      final f3 = queue.enqueue(() async {
        executionLog.add('write_3');
        task3Completed = true;
      });

      // Allow event loop ticks
      await Future.delayed(const Duration(milliseconds: 50));

      // Tasks must NOT have executed yet
      expect(task2Completed, isFalse);
      expect(task3Completed, isFalse);
      expect(executionLog, ['write_1']);
      expect(queue.queueLength, greaterThanOrEqualTo(1));

      // Restore completes and returns to ACTIVE
      coordinator.endRestore();

      // Wait for queued writes to finish
      await Future.wait([f2, f3]);

      expect(task2Completed, isTrue);
      expect(task3Completed, isTrue);
      expect(executionLog, ['write_1', 'write_2', 'write_3']);
      expect(queue.queueLength, 0);
    });

    test('P2.2B — WriteQueue quiescence ensures in-flight tasks finish before pivot', () async {
      final queue = WriteQueue.instance;
      final coordinator = DatabaseLifecycleCoordinator.instance;

      final inFlightCompleter = Completer<void>();
      bool inFlightFinished = false;

      // Start a long-running in-flight task
      final f = queue.enqueue(() async {
        await inFlightCompleter.future;
        inFlightFinished = true;
      });

      // Give it a tick to start processing
      await Future.delayed(const Duration(milliseconds: 20));
      expect(queue.hasInFlightTasks, isTrue);

      // Quiesce should wait for in-flight task
      bool quiesceDone = false;
      final quiesceFuture = queue.quiesce().then((_) {
        quiesceDone = true;
      });

      await Future.delayed(const Duration(milliseconds: 20));
      expect(quiesceDone, isFalse);

      // Complete in-flight task
      inFlightCompleter.complete();
      await f;
      await quiesceFuture;

      expect(quiesceDone, isTrue);
      expect(inFlightFinished, isTrue);
      expect(queue.hasInFlightTasks, isFalse);

      // Now safe to begin pivot
      await coordinator.beginBackup();
      expect(coordinator.currentState, DatabaseLifecycleState.backingUp);
      coordinator.endBackup();
    });

    // ──────────────────────────────────────────────────────────────────────────
    // P2.3 — SMS Ingestion Coordination During Lifecycle Operations
    // ──────────────────────────────────────────────────────────────────────────
    test('P2.3 — SMS ingestion defers flushing during restore/migration without data loss', () async {
      final coordinator = DatabaseLifecycleCoordinator.instance;
      final smsService = LiveSmsService.instance;

      smsService.clearLiveBufferForTesting();

      // Simulate incoming SMS during active state
      smsService.addLiveBufferForTesting('HDFCBK', 'Spent INR 100.00 at Store A');
      expect(smsService.bufferCountForTesting, 1);

      // Lifecycle pivots to MIGRATING
      await coordinator.beginMigration();

      // Additional SMS arrives during migration
      smsService.addLiveBufferForTesting('SBIINB', 'Spent INR 250.00 at Store B');
      expect(smsService.bufferCountForTesting, 2);

      // Attempt flush while migration is active — must wait asynchronously
      bool flushCompleted = false;
      final flushFuture = smsService.flushLiveBufferForTesting().then((_) {
        flushCompleted = true;
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(flushCompleted, isFalse);
      expect(smsService.bufferCountForTesting, 2); // Preserved, never discarded!

      // Migration completes
      coordinator.endMigration();

      // Flush should now proceed and drain buffer
      await flushFuture;
      expect(flushCompleted, isTrue);
      expect(smsService.bufferCountForTesting, 0);
    });

    // ──────────────────────────────────────────────────────────────────────────
    // P2.4 & P2.5 — Backup & Restore Lifecycle Exclusivity & Replacement
    // ──────────────────────────────────────────────────────────────────────────
    test('P2.4 & P2.5 — Backup and Restore execute exclusively with provider invalidation', () async {
      final db = await AppDatabase.instance.database;

      // Seed a financial account
      await db.insert('bank_accounts', {
        'id': 'acc_lifecycle_test',
        'name': 'Lifecycle Bank',
        'bank': 'Lifecycle Bank',
        'account_type': 'savings',
        'balance': 50000.0,
        'last4': '5678',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      // 1. Create backup package
      final (pkgFile, manifest) = await BackupService.instance.createBackupPackage();
      expect(await pkgFile.exists(), isTrue);
      expect(manifest.schemaVersion, 24);

      // 2. Verify replacement callback is invoked on restore
      bool replacementNotified = false;
      void listener() {
        replacementNotified = true;
      }
      DatabaseLifecycleCoordinator.instance.addDatabaseReplacementListener(listener);

      // 3. Restore backup package
      final container = ProviderContainer();
      final restored = await BackupService.instance.restoreFromFile(
        pkgFile,
        container: container,
      );
      expect(restored, isTrue);
      expect(replacementNotified, isTrue);

      // Lifecycle returned to active
      expect(DatabaseLifecycleCoordinator.instance.currentState, DatabaseLifecycleState.active);

      // Data is intact in restored database
      final reopenedDb = await AppDatabase.instance.database;
      final rows = await reopenedDb.query('bank_accounts', where: 'id = ?', whereArgs: ['acc_lifecycle_test']);
      expect(rows.length, 1);
      expect(rows.first['name'], 'Lifecycle Bank');

      DatabaseLifecycleCoordinator.instance.removeDatabaseReplacementListener(listener);
      container.dispose();
      await pkgFile.delete();
    });

    // ──────────────────────────────────────────────────────────────────────────
    // P2.7 — Database Close / Reopen Safety & Generation Convergence
    // ──────────────────────────────────────────────────────────────────────────
    test('P2.7 — Open -> Close -> Reopen cycle transitions lifecycle cleanly', () async {
      final coordinator = DatabaseLifecycleCoordinator.instance;

      // Initial open
      final db1 = await AppDatabase.instance.database;
      expect(db1.isOpen, isTrue);
      expect(coordinator.currentState, DatabaseLifecycleState.active);

      // Close
      await AppDatabase.instance.close();
      expect(coordinator.currentState, DatabaseLifecycleState.closed);

      // Reopen
      final db2 = await AppDatabase.instance.database;
      expect(db2.isOpen, isTrue);
      expect(coordinator.currentState, DatabaseLifecycleState.active);

      // 10 concurrent requests converge on same open instance
      final futures = List.generate(10, (_) => AppDatabase.instance.database);
      final results = await Future.wait(futures);
      for (final r in results) {
        expect(identical(r, db2), isTrue);
      }
    });

    // ──────────────────────────────────────────────────────────────────────────
    // P2.10 — Restore Failure Rollback & Known State Recovery
    // ──────────────────────────────────────────────────────────────────────────
    test('P2.10 — Restore failure from invalid package aborts cleanly without leaving empty DB', () async {
      final db = await AppDatabase.instance.database;
      await db.insert('bank_accounts', {
        'id': 'acc_original_preserved',
        'name': 'Preserved Bank',
        'bank': 'Preserved Bank',
        'account_type': 'savings',
        'balance': 100000.0,
        'last4': '4321',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      // Create an invalid dummy package file
      final dummyPkg = File(p.join(testDir.path, 'corrupted.spendx'));
      await dummyPkg.writeAsString('not a valid zip or spendx package');

      // Attempt restore — must throw and NOT destroy original DB
      await expectLater(
        BackupService.instance.restoreFromFile(dummyPkg),
        throwsA(anything),
      );

      // Coordinator must NOT remain stuck in restoring
      expect(DatabaseLifecycleCoordinator.instance.currentState, DatabaseLifecycleState.active);

      // Original database remains open and data is intact
      final liveDb = await AppDatabase.instance.database;
      final rows = await liveDb.query('bank_accounts', where: 'id = ?', whereArgs: ['acc_original_preserved']);
      expect(rows.length, 1);
      expect(rows.first['name'], 'Preserved Bank');
    });
  });
}
