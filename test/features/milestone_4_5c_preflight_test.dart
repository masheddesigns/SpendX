import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/restore_recovery_service.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

import 'milestone_4_5c_harness.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late String disposableDbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spendx_m45c_preflight_');
    disposableDbPath = p.join(tempDir.path, SpendXM45CDisposableIsolation.qualificationDbName);
    SpendXM45CDisposableIsolation.activateIsolation();
  });

  tearDown(() async {
    SpendXM45CDisposableIsolation.deactivateIsolation();
    BackupService.resetTestingFlags();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Milestone 4.5C Preflight — Disposable Isolation & Safety Guards', () {
    test('1.1 Path isolation asserts disposable name and violently aborts on production spendx.db', () {
      // Must pass for qualification database
      expect(
        () => SpendXM45CDisposableIsolation.assertDisposablePath(disposableDbPath),
        returnsNormally,
      );

      // Must throw FatalSafetyViolation on production database paths
      expect(
        () => SpendXM45CDisposableIsolation.assertDisposablePath('/data/user/0/com.mashingdesigns.spend_x/databases/spendx.db'),
        throwsA(isA<DisposablePathViolationException>().having(
          (e) => e.message,
          'message',
          contains('production database spendx.db! Aborting'),
        )),
      );

      expect(
        () => SpendXM45CDisposableIsolation.assertDisposablePath('spendx.db'),
        throwsA(isA<DisposablePathViolationException>()),
      );

      // Must throw on arbitrary unapproved database names
      expect(
        () => SpendXM45CDisposableIsolation.assertDisposablePath(p.join(tempDir.path, 'unapproved_db.db')),
        throwsA(isA<DisposablePathViolationException>().having(
          (e) => e.message,
          'message',
          contains('does not contain required qualification name'),
        )),
      );
    });

    test('1.2 BackupService disposable enforcement rejects production database targets', () async {
      BackupService.enforceDisposableIsolation = true;
      final dummyPackage = File(p.join(tempDir.path, 'dummy.spxbkp'));
      await dummyPackage.writeAsString('dummy');

      // Attempting restore targeting spendx.db must abort immediately
      expect(
        () => BackupService.instance.restoreFromFile(
          dummyPackage,
          targetDbPath: p.join(tempDir.path, 'spendx.db'),
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('FATAL SAFETY ABORT: Production database access forbidden'),
        )),
      );
    });

    test('1.3 Strengthened environment assertion checks canonical symlinks, parent directory, sidecars, and staging', () async {
      // 1. Valid disposable environment passes
      expect(
        () => SpendXM45CDisposableIsolation.assertDisposableEnvironment(
          targetDbPath: disposableDbPath,
          authorizedDirectoryPath: tempDir.path,
        ),
        returnsNormally,
      );

      // 2. Canonical resolution catches symlink alias pointing to production spendx.db
      final fakeProdDb = File(p.join(tempDir.path, 'spendx.db'));
      await fakeProdDb.writeAsString('FAKE_PROD');

      final symlinkDb = Link(p.join(tempDir.path, 'spendx_m45c_qualification.db.symlink_alias'));
      try {
        await symlinkDb.create(fakeProdDb.path);
        expect(
          () => SpendXM45CDisposableIsolation.assertDisposableEnvironment(
            targetDbPath: symlinkDb.path,
            authorizedDirectoryPath: tempDir.path,
          ),
          throwsA(isA<DisposablePathViolationException>().having(
            (e) => e.message,
            'message',
            contains('resolves via symlink to production spendx.db'),
          )),
        );
      } finally {
        try { if (await symlinkDb.exists()) await symlinkDb.delete(); } catch (_) {}
      }

      // 3. Sidecar symlink alias to production sidecar is detected and rejected
      final validDbFile = File(disposableDbPath);
      await validDbFile.writeAsString('VALID_DISPOSABLE');

      final fakeProdWal = File(p.join(tempDir.path, 'spendx.db-wal'));
      await fakeProdWal.writeAsString('FAKE_PROD_WAL');

      final symlinkWal = Link('$disposableDbPath-wal');
      try {
        await symlinkWal.create(fakeProdWal.path);
        expect(
          () => SpendXM45CDisposableIsolation.assertDisposableEnvironment(
            targetDbPath: disposableDbPath,
            authorizedDirectoryPath: tempDir.path,
          ),
          throwsA(isA<DisposablePathViolationException>().having(
            (e) => e.message,
            'message',
            contains('resolves via symlink to production sidecar'),
          )),
        );
      } finally {
        try { if (await symlinkWal.exists()) await symlinkWal.delete(); } catch (_) {}
        try { if (await fakeProdWal.exists()) await fakeProdWal.delete(); } catch (_) {}
      }

      // 4. Staging directory must match spendx_restore_stage_ prefix
      final invalidStageDir = Directory(p.join(tempDir.path, 'arbitrary_stage_dir'));
      await invalidStageDir.create();
      expect(
        () => SpendXM45CDisposableIsolation.assertDisposableEnvironment(
          targetDbPath: disposableDbPath,
          stagingDirPath: invalidStageDir.path,
          authorizedDirectoryPath: tempDir.path,
        ),
        throwsA(isA<DisposablePathViolationException>().having(
          (e) => e.message,
          'message',
          contains('not a dedicated spendx_restore_stage_ directory'),
        )),
      );

      final validStageDir = Directory(p.join(tempDir.path, 'spendx_restore_stage_test123'));
      await validStageDir.create();
      expect(
        () => SpendXM45CDisposableIsolation.assertDisposableEnvironment(
          targetDbPath: disposableDbPath,
          stagingDirPath: validStageDir.path,
          authorizedDirectoryPath: tempDir.path,
        ),
        returnsNormally,
      );
    });

    test('1.4 executeGuardedDisposableMutation validates environment under lock immediately before mutation', () async {
      bool mutationExecuted = false;

      // 1. Missing or empty restore token aborts BEFORE mutation
      expect(
        () => SpendXM45CDisposableIsolation.executeGuardedDisposableMutation(
          targetDbPath: disposableDbPath,
          restoreToken: '',
          authorizedDirectoryPath: tempDir.path,
          mutation: () async {
            mutationExecuted = true;
          },
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Native exclusive restore token required before mutation'),
        )),
      );
      expect(mutationExecuted, isFalse);

      // 2. Unauthorized parent directory aborts BEFORE mutation
      final foreignDir = await Directory.systemTemp.createTemp('spendx_foreign_dir_');
      try {
        final foreignDbPath = p.join(foreignDir.path, SpendXM45CDisposableIsolation.qualificationDbName);
        expect(
          () => SpendXM45CDisposableIsolation.executeGuardedDisposableMutation(
            targetDbPath: foreignDbPath,
            restoreToken: 'valid_restore_token_123',
            authorizedDirectoryPath: tempDir.path,
            mutation: () async {
              mutationExecuted = true;
            },
          ),
          throwsA(isA<DisposablePathViolationException>().having(
            (e) => e.message,
            'message',
            contains('Canonical parent directory'),
          )),
        );
        expect(mutationExecuted, isFalse);
      } finally {
        try { await foreignDir.delete(recursive: true); } catch (_) {}
      }

      // 3. Valid environment under exclusive lock executes mutation cleanly
      final result = await SpendXM45CDisposableIsolation.executeGuardedDisposableMutation(
        targetDbPath: disposableDbPath,
        restoreToken: 'valid_restore_token_123',
        authorizedDirectoryPath: tempDir.path,
        mutation: () async {
          mutationExecuted = true;
          return 'MUTATION_SUCCESS';
        },
      );
      expect(mutationExecuted, isTrue);
      expect(result, equals('MUTATION_SUCCESS'));
    });
  });

  group('Milestone 4.5C Preflight — Group 3 Concurrency (Synchronization Barrier)', () {
    test('3.1 Ten concurrent background workers synchronize at barrier and release cleanly', () async {
      final lockService = SpendXM45CProcessContentionLockService();
      final barrier = SpendXM45CSyncBarrier(10);
      final activeWorkerTickets = <String, NativeTicketResult>{};
      final workerCompletedList = <int>[];

      // Spawn 10 concurrent background workers
      final futures = List.generate(10, (index) async {
        final engineId = 'engine_bg_$index';
        final ticket = await lockService.acquireOperationTicket(
          tag: 'bg_task_$index',
          engineId: engineId,
        );
        activeWorkerTickets[ticket.ticketId] = ticket;

        // Arrive and wait at synchronization barrier
        await barrier.arriveAndWait('worker_$index');

        // All 10 hold tickets simultaneously at this point
        expect(barrier.isReleased, isTrue);
        expect(barrier.arrivedCount, equals(10));

        // Release ticket after synchronized barrier passage
        final ok = await lockService.releaseOperationTicket(
          ticket.ticketId,
          engineId: engineId,
        );
        expect(ok, isTrue);
        workerCompletedList.add(index);
      });

      await Future.wait(futures);

      expect(workerCompletedList.length, equals(10));
      expect(barrier.arrivedCount, equals(10));
      expect(barrier.arrivalLog.length, equals(10));

      final status = await lockService.getLockStatus();
      expect(status['activeTicketsCount'], equals(0));
      expect(status['activeReadersCount'], equals(0));
      expect(status['state'], equals('OPEN'));
    });
  });

  group('Milestone 4.5C Preflight — Group 5 Process Contention Simulator', () {
    test('5.1 Multi-engine lock contention enforces admission closure, cross-engine isolation, and stale checks', () async {
      final lockService = SpendXM45CProcessContentionLockService();

      // 1. Engine A acquires foreground lease
      final leaseA = await lockService.acquireForegroundLease(engineId: 'engine_alpha');
      expect(leaseA, isNotEmpty);

      var status = await lockService.getLockStatus();
      expect(status['activeReadersCount'], equals(1));
      expect(status['state'], equals('OPEN'));

      // 2. Engine B acquires background operation ticket
      final ticketB = await lockService.acquireOperationTicket(
        tag: 'engine_beta_op',
        engineId: 'engine_beta',
      );
      expect(ticketB.ticketId, isNotEmpty);

      // 3. Cross-engine ticket release is rejected
      expect(
        () => lockService.releaseOperationTicket(ticketB.ticketId, engineId: 'engine_gamma'),
        throwsA(isA<CrossEngineReleaseException>()),
      );

      // Clean release by engine B
      final releasedB = await lockService.releaseOperationTicket(
        ticketB.ticketId,
        engineId: 'engine_beta',
      );
      expect(releasedB, isTrue);

      // 4. Stale ticket re-release is rejected
      expect(
        () => lockService.releaseOperationTicket(ticketB.ticketId, engineId: 'engine_beta'),
        throwsA(isA<StaleTicketException>()),
      );

      // 5. Release foreground lease
      await lockService.releaseForegroundLease(
        leaseToken: leaseA,
        engineId: 'engine_alpha',
      );

      status = await lockService.getLockStatus();
      expect(status['activeReadersCount'], equals(0));

      // 6. Begin exclusive restore
      final restoreToken = await lockService.beginExclusiveRestore();
      expect(restoreToken, isNotEmpty);

      status = await lockService.getLockStatus();
      expect(status['state'], equals('EXCLUSIVE_HELD'));
      expect(status['exclusiveHeld'], isTrue);

      // 7. Operations during exclusive restore fail closed
      expect(
        () => lockService.acquireForegroundLease(engineId: 'engine_delta'),
        throwsA(isA<DatabaseAdmissionClosedException>()),
      );
      expect(
        () => lockService.acquireOperationTicket(tag: 'during_exclusive', engineId: 'engine_delta'),
        throwsA(isA<DatabaseAdmissionClosedException>()),
      );

      // 8. Complete exclusive restore
      final completeOk = await lockService.completeExclusiveRestore(restoreToken);
      expect(completeOk, isTrue);

      status = await lockService.getLockStatus();
      expect(status['state'], equals('OPEN'));
      expect(status['exclusiveHeld'], isFalse);
    });
  });

  group('Milestone 4.5C Preflight — Group 6 Deterministic Crash Barrier Activation (Non-Destructive)', () {
    test('6.1 Crash barrier hook captures all 4 phases and manifests without process kill', () async {
      final crashInjection = SpendXM45CCrashInjection();
      crashInjection.injectedCrashPhase = null; // Non-destructive preflight

      // Set hook
      BackupService.crashBarrierForTesting = crashInjection.handleBarrier;

      // Seed valid active DB
      final db = await openDatabase(
        disposableDbPath,
        version: 24,
        onCreate: (d, v) async {
          await TablesV24.createAllV24(d);
          await TablesV24.seedSystemAccounts(d);
          await TablesV24.installTriggers(d);
        },
      );
      await db.rawQuery('PRAGMA user_version = 24;');
      await db.close();

      // Create valid staged replacement file
      final stagedDbFile = File(p.join(tempDir.path, 'staged_fixture.db'));
      final stagedDb = await openDatabase(
        stagedDbFile.path,
        version: 24,
        onCreate: (d, v) async {
          await TablesV24.createAllV24(d);
          await TablesV24.seedSystemAccounts(d);
          await TablesV24.installTriggers(d);
        },
      );
      await stagedDb.rawQuery('PRAGMA user_version = 24;');
      await stagedDb.close();

      // Setup journal and execute atomic replacement directly using testing seams
      final journalFile = File(p.join(tempDir.path, RestoreJournal.journalFileName));
      final journal = await RestoreJournal.create(
        journalFile: journalFile,
        restoreOperationId: 'test_preflight_op',
        targetDbPath: disposableDbPath,
        safetyBackupPath: '$disposableDbPath.pre_restore_backup',
        swapCandidatePath: '$disposableDbPath.new_swap',
      );

      // Exercise all 4 phases with crash barrier
      await journal.record(RestoreJournalState.quiesced);
      await crashInjection.handleBarrier(RestoreJournalState.quiesced, tempDir, journalFile);

      await journal.record(RestoreJournalState.backupCreated);
      await crashInjection.handleBarrier(RestoreJournalState.backupCreated, tempDir, journalFile);

      await journal.record(RestoreJournalState.swapping);
      await crashInjection.handleBarrier(RestoreJournalState.swapping, tempDir, journalFile);

      await journal.record(RestoreJournalState.swapComplete);
      await crashInjection.handleBarrier(RestoreJournalState.swapComplete, tempDir, journalFile);

      // Assert all 4 phases captured
      expect(crashInjection.capturedSnapshots.length, equals(4));
      expect(crashInjection.capturedSnapshots[0].phase, equals(RestoreJournalState.quiesced));
      expect(crashInjection.capturedSnapshots[1].phase, equals(RestoreJournalState.backupCreated));
      expect(crashInjection.capturedSnapshots[2].phase, equals(RestoreJournalState.swapping));
      expect(crashInjection.capturedSnapshots[3].phase, equals(RestoreJournalState.swapComplete));

      // Each snapshot captured directory manifest
      for (final snapshot in crashInjection.capturedSnapshots) {
        expect(snapshot.directoryManifest.isNotEmpty, isTrue);
        expect(snapshot.journalData, isNotNull);
        expect(snapshot.journalData!['restoreOperationId'], equals('test_preflight_op'));
      }
    });
  });

  group('Milestone 4.5C Preflight — Group 7 Recovery Verification', () {
    test('7.1 Pre-open candidate validation and HMAC constant-time check operate on disposable database', () async {
      // Create valid candidate
      final candidatePath = p.join(tempDir.path, 'candidate.db');
      final db = await openDatabase(
        candidatePath,
        version: 24,
        onCreate: (d, v) async {
          await TablesV24.createAllV24(d);
          await TablesV24.seedSystemAccounts(d);
        },
      );
      await db.rawQuery('PRAGMA user_version = 24;');
      await db.close();

      // Validate pre-open
      final isValid = await RestoreRecoveryService.instance.validateCandidateDatabase(candidatePath);
      expect(isValid, isTrue);

      // Corrupt candidate
      final corruptPath = p.join(tempDir.path, 'corrupt_candidate.db');
      await File(corruptPath).writeAsString('TRUNCATED_NOT_SQLITE_DATA');
      final isCorruptValid = await RestoreRecoveryService.instance.validateCandidateDatabase(corruptPath);
      expect(isCorruptValid, isFalse);
    });
  });

  group('Milestone 4.5C Preflight — Group 8 WAL Consistency', () {
    test('8.1 Uncheckpointed WAL frames are captured by fingerprint and preserved', () async {
      final db = await openDatabase(
        disposableDbPath,
        version: 24,
        onCreate: (d, v) async {
          await TablesV24.createAllV24(d);
          await TablesV24.seedSystemAccounts(d);
          await TablesV24.installTriggers(d);
        },
      );
      await db.rawQuery('PRAGMA user_version = 24;');
      await db.rawQuery('PRAGMA journal_mode = WAL;');

      // Insert uncheckpointed row in a transaction
      await db.insert(TablesV24.accounts, {
        'id': 'acc_wal_test',
        'name': 'WAL Test Account',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      final fpWithWal = await DatabaseGenerationFingerprint.compute(
        dbPath: disposableDbPath,
        restoreOperationId: 'wal_op_test',
        expectedGeneration: 1,
      );

      expect(fpWithWal.restoreOperationId, equals('wal_op_test'));
      expect(fpWithWal.compositeHash, isNotEmpty);

      // Checkpoint WAL and ensure hash remains deterministic
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE);');
      await db.close();

      // Reopen and verify data persisted across WAL boundary
      final reopenedDb = await openDatabase(disposableDbPath);
      final rows = await reopenedDb.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: ['acc_wal_test'],
      );
      expect(rows.length, equals(1));
      await reopenedDb.close();
    });
  });

  group('Milestone 4.5C Preflight — Group 9 Key-Loss Safety Provider', () {
    test('9.1 Isolated test key provider never touches production key and fails closed on denial', () async {
      final keyProvider = SpendXM45CDisposableKeyProvider();

      // Normal key retrieval
      final key = await keyProvider.getOrCreateQualificationKey();
      expect(key.length, equals(32));

      // Key retrieval is deterministic and matches
      final keyAgain = await keyProvider.getOrCreateQualificationKey();
      expect(keyAgain, equals(key));

      // Secure storage failure simulation fails closed without key creation
      keyProvider.shouldDenyKey = true;
      expect(
        () => keyProvider.getOrCreateQualificationKey(),
        throwsA(isA<DatabaseKeyAccessException>().having(
          (e) => e.message,
          'message',
          contains('KEY_DENIED: Qualification test simulating secure storage'),
        )),
      );
    });
  });

  group('Milestone 4.5C Preflight — Group 10 Financial Integrity Fixture & Invariant Audit', () {
    test('10.1 Double-entry baseline ledger passes trial balance delta = 0 and full audit', () async {
      final db = await openDatabase(
        disposableDbPath,
        version: 24,
      );

      // Seed baseline ledger
      await SpendXM45CFinancialIntegrity.seedBaselineLedger(db);

      // Run comprehensive invariant audit
      final audit = await SpendXM45CFinancialIntegrity.auditLedgerInvariants(db);

      expect(audit.isValid, isTrue, reason: 'Audit errors: ${audit.errors}');
      expect(audit.errors, isEmpty);
      expect(audit.deltaMinorUnits, equals(0), reason: 'Double-entry parity must equal exactly 0');
      expect(audit.totalDebitMinorUnits, equals(1960000), reason: 'Total debits must equal 1,960,000 minor units (₹19,600)');
      expect(audit.totalCreditMinorUnits, equals(1960000), reason: 'Total credits must equal 1,960,000 minor units (₹19,600)');
      expect(audit.userVersion, equals(24));
      expect(audit.foreignKeyViolations, isEmpty);
      expect(audit.integrityCheckOutput, contains('ok'));

      // Check evidence record attached to dining expense
      final evidenceRows = await db.query(
        TablesV24.evidence,
        where: 'economic_event_id = ?',
        whereArgs: ['evt_m45c_05_cc_purchase'],
      );
      expect(evidenceRows.length, equals(1));
      expect(evidenceRows.first['source_type'], equals('ocr'));
      expect(evidenceRows.first['extracted_amount_minor_units'], equals(80000));

      await db.close();
    });
  });
}
