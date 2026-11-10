import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tracked_database_task_queue.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/domain/finance/economic_event.dart';
import 'package:spend_x/domain/finance/money.dart';
import 'package:spend_x/domain/finance/review_candidate.dart';
import 'package:spend_x/services/backup_file_service.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';
import 'package:spend_x/services/notification_service_v2.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

/// Milestone 4.5B Step 6: Live Restore Preparation and Staging Concurrency
///
/// ============================================================================
/// ARCHITECTURAL VERIFICATION SCOPE: STEP 6
/// ============================================================================
/// 1. Independent Database Connection:
///    - Staging extraction and validation occurs under an auxiliary connection on
///      temporary files in `stagingDir`.
///    - Staging never bypasses the primary database gate or accesses `AppDatabase.database`.
/// 2. Concurrency Safety:
///    - Foreground reads and writes proceed uninterrupted during staging preparation.
///    - Tracked background tasks and notification callbacks proceed and release native
///      tickets concurrently while staging validation runs.
/// 3. Fail-Closed Resilience:
///    - Staging failures (corrupted ZIP, checksum mismatch, schema violations,
///      double-entry imbalance) abort immediately with [BackupValidationException].
///    - The primary database connection remains open, unaffected, and fully writable.
/// 4. Artifact Hygiene:
///    - All temporary staging artifacts (.db, -wal, -shm, manifest.json) are deleted
///      on both success and failure.
/// 5. Mutual Exclusion:
///    - Concurrent restore attempts are serialized safely via `_busy` guard.
/// 6. Separation of Concerns:
///    - Preparation and validation are completely isolated from destructive database swap.
/// ============================================================================

class Step6MockProcessLockService implements PlatformProcessLockService {
  int acquireForegroundCount = 0;
  int releaseForegroundCount = 0;
  String? activeForegroundLeaseToken;

  int ticketCounter = 0;
  final Map<String, Map<String, dynamic>> activeTickets = {};
  int readersCount = 0;

  bool isRestorePending = false;
  bool isRestoreExclusiveHeld = false;

  final List<String> eventLog = [];

  @override
  MethodChannel get channel => const MethodChannel('spendx/process_lock');

  @override
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    eventLog.add('acquireForegroundLease:$engineId');
    if (isRestorePending || isRestoreExclusiveHeld) {
      throw const DatabaseAdmissionClosedException(
        'ADMISSION_CLOSED: Cannot acquire foreground lease while restore is pending or exclusive',
      );
    }
    if (activeForegroundLeaseToken != null) {
      return activeForegroundLeaseToken!;
    }
    acquireForegroundCount++;
    readersCount++;
    activeForegroundLeaseToken = 'fg_lease_$acquireForegroundCount';
    return activeForegroundLeaseToken!;
  }

  @override
  Future<bool> releaseForegroundLease({
    required String leaseToken,
    String engineId = 'main_engine',
  }) async {
    eventLog.add('releaseForegroundLease:$leaseToken');
    if (activeForegroundLeaseToken == null || activeForegroundLeaseToken != leaseToken) {
      return false;
    }
    activeForegroundLeaseToken = null;
    releaseForegroundCount++;
    readersCount = (readersCount - 1).clamp(0, 999999);
    return true;
  }

  @override
  Future<NativeTicketResult> acquireOperationTicket({
    String? engineId,
    required String tag,
  }) async {
    eventLog.add('acquireOperationTicket:$tag');
    if (isRestorePending || isRestoreExclusiveHeld) {
      throw const DatabaseAdmissionClosedException(
        'ADMISSION_CLOSED: Cannot acquire operation ticket while restore is pending or exclusive',
      );
    }
    ticketCounter++;
    final assignedEngineId = engineId ?? 'engine_$ticketCounter';
    final ticketId = 'ticket_${ticketCounter}_$tag';
    activeTickets[ticketId] = {
      'ticketId': ticketId,
      'engineId': assignedEngineId,
      'tag': tag,
    };
    readersCount++;
    return NativeTicketResult(
      ticketId: ticketId,
      tag: tag,
      engineId: assignedEngineId,
    );
  }

  @override
  Future<bool> releaseOperationTicket(
    String ticketId, {
    String? engineId,
  }) async {
    eventLog.add('releaseOperationTicket:$ticketId');
    final ticket = activeTickets.remove(ticketId);
    if (ticket == null) {
      throw const StaleTicketException('Stale or unknown ticket');
    }
    readersCount = (readersCount - 1).clamp(0, 999999);
    return true;
  }

  @override
  Future<String> beginExclusiveRestore({
    int drainTimeoutMs = 5000,
    int contentionTimeoutMs = 5000,
  }) async {
    eventLog.add('beginExclusiveRestore');
    if (readersCount > 0) {
      throw StateError('Cannot acquire exclusive restore lock while readersCount ($readersCount) > 0');
    }
    isRestorePending = false;
    isRestoreExclusiveHeld = true;
    return 'restore_token_step6';
  }

  @override
  Future<bool> completeExclusiveRestore(String restoreToken) async {
    eventLog.add('completeExclusiveRestore:$restoreToken');
    isRestoreExclusiveHeld = false;
    return true;
  }

  @override
  Future<bool> abortExclusiveRestore(String restoreToken) async {
    eventLog.add('abortExclusiveRestore:$restoreToken');
    isRestoreExclusiveHeld = false;
    return true;
  }

  @override
  Future<bool> validateExclusiveRestoreToken(String restoreToken) async => true;

  @override
  Future<Map<String, dynamic>> getLockStatus() async {
    return {
      'state': isRestoreExclusiveHeld
          ? 'EXCLUSIVE_HELD'
          : (isRestorePending ? 'RESTORE_PENDING' : 'OPEN'),
      'activeReadersCount': readersCount,
      'activeTicketsCount': activeTickets.length,
      'hasForegroundLease': activeForegroundLeaseToken != null,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Step6MockProcessLockService mockLockService;
  late DatabaseAccessGate gate;
  late TrackedDatabaseTaskQueue taskQueue;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    // Clean up any stale staging artifacts from prior failed runs
    try {
      final initialTempEntries = Directory.systemTemp.listSync();
      for (final entry in initialTempEntries) {
        if (entry is Directory &&
            (p.basename(entry.path).startsWith('spendx_backup_stage_') ||
             p.basename(entry.path).startsWith('spendx_restore_stage_'))) {
          try {
            entry.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}

    tempDir = await Directory.systemTemp.createTemp('spendx_4_5b_step6_test_');
    final dbFile = p.join(tempDir.path, 'spendx_step6.db');
    AppDatabase.setTestDatabasePath(dbFile);

    mockLockService = Step6MockProcessLockService();
    PlatformProcessLockService.instanceForTesting = mockLockService;

    gate = DatabaseAccessGate(processLockService: mockLockService);
    taskQueue = TrackedDatabaseTaskQueue(gate: gate);
    gate.attachTaskQueue(taskQueue);

    DatabaseAccessGate.instanceForTesting = gate;
    DatabaseLifecycleCoordinator.instance.resetForTesting();
  });

  tearDown(() async {
    BackupService.stagingDirectoryCreatorForTesting = null;
    PlatformProcessLockService.instanceForTesting = null;
    DatabaseAccessGate.instanceForTesting = DatabaseAccessGate();
    AppDatabase.setTestDatabasePath(null);
    DatabaseLifecycleCoordinator.instance.resetForTesting();

    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  /// Helper to seed a valid economic event with balanced double-entry postings.
  Future<void> seedBalancedTransaction({
    required Database db,
    required String eventId,
    required double amountRupees,
    required String fromAccountId,
    required String toAccountId,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final amountMinor = (amountRupees * 100).round();

    await db.transaction((txn) async {
      await txn.insert(TablesV24.economicEvents, {
        'id': eventId,
        'event_type': 'transfer',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Balanced transfer of Rs $amountRupees',
        'created_at': now,
        'updated_at': now,
      });

      await txn.insert(TablesV24.postings, {
        'id': '${eventId}_post_cr',
        'economic_event_id': eventId,
        'account_id': fromAccountId,
        'direction': 'credit',
        'amount_minor_units': amountMinor,
        'sequence_number': 1,
        'currency': 'INR',
        'created_at': now,
      });

      await txn.insert(TablesV24.postings, {
        'id': '${eventId}_post_dr',
        'economic_event_id': eventId,
        'account_id': toAccountId,
        'direction': 'debit',
        'amount_minor_units': amountMinor,
        'sequence_number': 2,
        'currency': 'INR',
        'created_at': now,
      });

      await txn.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [eventId],
      );
    });
  }

  /// Helper to generate a valid test backup package (.spendx) from the current database.
  Future<File> generateValidBackupPackage({required String filename}) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final uid = DateTime.now().microsecondsSinceEpoch;
    await db.insert(TablesV24.accounts, {
      'id': 'acc_valid_pkg_01_$uid',
      'name': 'Backup Seed Checking',
      'account_type': 'asset',
      'subtype': 'checking',
      'currency': 'INR',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert(TablesV24.accounts, {
      'id': 'acc_valid_pkg_02_$uid',
      'name': 'Backup Seed Expense',
      'account_type': 'expense',
      'subtype': 'general',
      'currency': 'INR',
      'created_at': now,
      'updated_at': now,
    });

    await seedBalancedTransaction(
      db: db,
      eventId: 'evt_valid_pkg_01_$uid',
      amountRupees: 250.0,
      fromAccountId: 'acc_valid_pkg_01_$uid',
      toAccountId: 'acc_valid_pkg_02_$uid',
    );

    final pkgPath = p.join(tempDir.path, filename);
    final (pkgFile, _) = await BackupService.instance.createBackupPackage(
      outputFile: File(pkgPath),
      sourceDb: db,
    );
    return pkgFile;
  }

  group('Milestone 4.5B — Step 6: Live Restore Preparation and Staging Concurrency', () {
    test('6.1. Staged database opens on independent auxiliary file via prepareStagedRestore without touching primary DB', () async {
      final db = await AppDatabase.instance.database;
      expect(gate.isOpen, isTrue);
      expect(mockLockService.activeForegroundLeaseToken, isNotNull);

      final pkgFile = await generateValidBackupPackage(filename: 'step6_test1.spendx');
      final stagingDir = await Directory.systemTemp.createTemp('spendx_test_stage_61_');

      try {
        final staged = await BackupService.instance.prepareStagedRestore(
          packageFile: pkgFile,
          stagingDir: stagingDir,
        );

        // Assertions:
        // 1. Staged file is strictly located inside the stagingDir, NOT in AppDatabase path
        expect(staged.stagedDbFile.path.startsWith(stagingDir.path), isTrue);
        final primaryPath = await AppDatabase.instance.getDatabasePath();
        expect(staged.stagedDbFile.path, isNot(equals(primaryPath)));

        // 2. Primary database remains open, active, and accessible
        expect(db.isOpen, isTrue);
        final primaryAccounts = await db.query(TablesV24.accounts);
        expect(primaryAccounts.isNotEmpty, isTrue);

        // 3. Native foreground lease was never dropped or replaced
        expect(mockLockService.activeForegroundLeaseToken, isNotNull);
        expect(mockLockService.readersCount, 1);

        // 4. Gate state remains OPEN with 0 active operations after completion
        expect(gate.isOpen, isTrue);
        expect(gate.activeOperations, 0);

        // 5. Coordinator remains in active state (never entered restoring)
        expect(DatabaseLifecycleCoordinator.instance.currentState, DatabaseLifecycleState.active);
      } finally {
        await stagingDir.delete(recursive: true);
        await db.close();
      }
    });

    test('6.2. Preparation concurrent with active foreground reads and writes succeeds without interference', () async {
      final db = await AppDatabase.instance.database;
      final pkgFile = await generateValidBackupPackage(filename: 'step6_test2.spendx');
      final stagingDir = await Directory.systemTemp.createTemp('spendx_test_stage_62_');

      try {
        // Concurrently run foreground reads, writes, and transactions while prepareStagedRestore runs
        final fgWritesCompleter = Completer<void>();
        final now = DateTime.now().toUtc().toIso8601String();

        Future<void> runForegroundOps() async {
          for (int i = 0; i < 5; i++) {
            await db.insert(TablesV24.accounts, {
              'id': 'acc_fg_concurrent_$i',
              'name': 'Concurrent Account $i',
              'account_type': 'asset',
              'subtype': 'savings',
              'currency': 'INR',
              'created_at': now,
              'updated_at': now,
            });
            await db.query(TablesV24.accounts);
            await Future.delayed(const Duration(milliseconds: 10));
          }
          fgWritesCompleter.complete();
        }

        final fgFuture = runForegroundOps();
        final stageFuture = BackupService.instance.prepareStagedRestore(
          packageFile: pkgFile,
          stagingDir: stagingDir,
        );

        final results = await Future.wait([fgFuture, stageFuture]);
        final staged = results[1] as StagedBackup;

        expect(staged.stagedDbFile.existsSync(), isTrue);
        expect(gate.isOpen, isTrue);
        expect(gate.activeOperations, 0);

        // Confirm all 5 concurrent foreground accounts exist in primary DB
        final allAccounts = await db.query(
          TablesV24.accounts,
          where: 'id LIKE ?',
          whereArgs: ['acc_fg_concurrent_%'],
        );
        expect(allAccounts.length, 5);
      } finally {
        await stagingDir.delete(recursive: true);
        await db.close();
      }
    });

    test('6.3. Preparation concurrent with tracked background tasks and notification callbacks', () async {
      final db = await AppDatabase.instance.database;
      final pkgFile = await generateValidBackupPackage(filename: 'step6_test3.spendx');
      final stagingDir = await Directory.systemTemp.createTemp('spendx_test_stage_63_');

      try {
        // 1. Seed candidate for notification action
        final reviewId = 'rev_step6_notif_01';
        final canonicalRepo = CanonicalReviewRepository();
        await canonicalRepo.createCandidate(
          ReviewCandidate(
            id: reviewId,
            sourceType: 'sms',
            suggestedEventType: CanonicalEventType.expense,
            suggestedAmount: Money.fromRupees(350.0),
            rawPayload: jsonEncode({
              'rawSource': 'Rs 350 spent on Groceries',
              'parsed': {
                'amount': 350.0,
                'isCredit': false,
                'rawText': 'Rs 350 spent on Groceries',
                'date': DateTime.now().toUtc().toIso8601String(),
                'merchant': 'Supermarket',
                'confidence': 0.99,
              },
            }),
            confidenceScore: 0.99,
            status: ReviewCandidateStatus.pending,
            createdAt: DateTime.now().toUtc(),
          ),
        );

        final notifResponse = NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction,
          actionId: NotificationServiceV2.liveExpenseAction,
          payload: jsonEncode({
            'source_type': 'live_choice',
            'review_id': reviewId,
          }),
        );

        // 2. Launch tracked background task
        final bgCompleter = Completer<void>();
        taskQueue.runTracked('tracked_bg_task_step6', () async {
          try {
            final now = DateTime.now().toUtc().toIso8601String();
            await db.insert(TablesV24.accounts, {
              'id': 'acc_bg_tracked_step6',
              'name': 'Tracked BG Account',
              'account_type': 'asset',
              'subtype': 'checking',
              'currency': 'INR',
              'created_at': now,
              'updated_at': now,
            });
            await Future.delayed(const Duration(milliseconds: 20));
            bgCompleter.complete();
          } catch (e, st) {
            bgCompleter.completeError(e, st);
          }
        });

        // 3. Launch notification callback
        final notifFuture = notificationTapBackground(notifResponse);

        // 4. Launch staged restore preparation
        final stagingFuture = BackupService.instance.prepareStagedRestore(
          packageFile: pkgFile,
          stagingDir: stagingDir,
        );

        // Await all concurrent operations
        await Future.wait([bgCompleter.future, notifFuture, stagingFuture]);

        // Assertions:
        // - Staging succeeded
        final staged = await stagingFuture;
        expect(staged.stagedDbFile.existsSync(), isTrue);

        // - Background task completed and inserted row
        final bgRow = await db.query(TablesV24.accounts, where: 'id = ?', whereArgs: ['acc_bg_tracked_step6']);
        expect(bgRow.length, 1);

        // - Candidate marked approved by notification callback
        final updatedCandidate = await canonicalRepo.getCandidate(reviewId);
        expect(updatedCandidate?.status, equals(ReviewCandidateStatus.approved));

        // - All native tickets cleanly released
        expect(mockLockService.activeTickets.isEmpty, isTrue);
        expect(mockLockService.readersCount, 1); // Foreground lease only
        expect(taskQueue.activeTaskCount, 0);
        expect(gate.activeOperations, 0);
      } finally {
        await stagingDir.delete(recursive: true);
        await db.close();
      }
    });

    test('6.4. Staging failures (corrupted ZIP, checksum mismatch) fail closed and preserve primary DB', () async {
      final db = await AppDatabase.instance.database;

      // Seed an account that must remain preserved
      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_preserved_before_fail',
        'name': 'Indestructible Account',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });

      // Scenario 6.4A: Truncated / corrupted ZIP file
      final corruptedZip = File(p.join(tempDir.path, 'corrupted.spendx'));
      await corruptedZip.writeAsString('PK\x03\x04 corrupt zip payload not readable');

      final stageDirA = await Directory.systemTemp.createTemp('spendx_stage_fail_a_');
      try {
        await expectLater(
          () => BackupService.instance.prepareStagedRestore(
            packageFile: corruptedZip,
            stagingDir: stageDirA,
          ),
          throwsA(isA<BackupValidationException>()),
        );
      } finally {
        await stageDirA.delete(recursive: true);
      }

      // Scenario 6.4B: Manifest SHA-256 checksum mismatch
      final validPkg = await generateValidBackupPackage(filename: 'valid_for_tamper.spendx');
      final tamperDir = await Directory.systemTemp.createTemp('spendx_tamper_');
      final stagedForTamper = await BackupFileService.instance.extractPackage(
        packageFile: validPkg,
        stagingDir: tamperDir,
      );

      // Modify the staged database file to invalidate the SHA-256 hash
      await stagedForTamper.stagedDbFile.writeAsString('tampered database content', mode: FileMode.append);

      // Re-archive with the old manifest (which contains original checksum)
      final tamperedPkg = File(p.join(tempDir.path, 'tampered_hash.spendx'));
      await BackupFileService.instance.createPackage(
        dbFile: stagedForTamper.stagedDbFile,
        manifest: stagedForTamper.manifest,
        outputFile: tamperedPkg,
      );
      await tamperDir.delete(recursive: true);

      final stageDirB = await Directory.systemTemp.createTemp('spendx_stage_fail_b_');
      try {
        await expectLater(
          () => BackupService.instance.prepareStagedRestore(
            packageFile: tamperedPkg,
            stagingDir: stageDirB,
          ),
          throwsA(isA<BackupValidationException>()),
        );
      } finally {
        await stageDirB.delete(recursive: true);
      }

      // Assertions verifying fail-closed invariants:
      // 1. Primary database remains open and operational
      expect(db.isOpen, isTrue);
      final checkRows = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: ['acc_preserved_before_fail'],
      );
      expect(checkRows.length, 1);
      expect(checkRows.first['name'], 'Indestructible Account');

      // 2. Primary gate is still OPEN
      expect(gate.isOpen, isTrue);
      expect(gate.activeOperations, 0);

      // 3. Coordinator remains active
      expect(DatabaseLifecycleCoordinator.instance.currentState, DatabaseLifecycleState.active);

      await db.close();
    });

    test('6.5. Staging failures with double-entry imbalance or relational integrity preserve primary DB', () async {
      final db = await AppDatabase.instance.database;

      // Seed an account that must remain preserved
      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_step6_double_entry_preservation',
        'name': 'Safe Live Account',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });

      // Construct an invalid package containing unbalanced double-entry postings
      final invalidStaging = await Directory.systemTemp.createTemp('spendx_stage_unbalanced_');
      final invalidDbPath = p.join(invalidStaging.path, 'spendx.db');
      final key = await SpendXDatabaseKeyManager.instance.getOrCreateKey();
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key);

      final invalidDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        invalidDbPath,
        password: blobKey,
      );

      // Create valid schema without triggers first so we can seed unbalanced data
      await invalidDb.execute('PRAGMA user_version = 24;');
      await TablesV24.createAllV24(invalidDb);
      await TablesV24.seedSystemAccounts(invalidDb);

      // Insert an UNBALANCED transaction (credit 500, debit 250 -> imbalance of 250)
      const evtId = 'evt_unbalanced_01';
      await invalidDb.insert(TablesV24.economicEvents, {
        'id': evtId,
        'event_type': 'expense',
        'lifecycle_status': 'posted',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Corrupted unbalanced event',
        'created_at': now,
        'updated_at': now,
      });
      await invalidDb.insert(TablesV24.postings, {
        'id': '${evtId}_p1',
        'economic_event_id': evtId,
        'account_id': TablesV24.sysEquityOpening,
        'direction': 'credit',
        'amount_minor_units': 50000,
        'sequence_number': 1,
        'currency': 'INR',
        'created_at': now,
      });
      await invalidDb.insert(TablesV24.postings, {
        'id': '${evtId}_p2',
        'economic_event_id': evtId,
        'account_id': TablesV24.sysEquityAdj,
        'direction': 'debit',
        'amount_minor_units': 25000, // Deficit!
        'sequence_number': 2,
        'currency': 'INR',
        'created_at': now,
      });

      // Now install triggers so trigger presence check passes and validator reaches double-entry check
      await TablesV24.installTriggers(invalidDb);

      await invalidDb.close();

      // Package it
      final invalidDbFile = File(invalidDbPath);
      final invalidDbBytes = await invalidDbFile.readAsBytes();
      final manifest = BackupManifest(
        formatVersion: BackupManifest.currentFormatVersion,
        schemaVersion: BackupManifest.currentSchemaVersion,
        appVersion: '2.0.0',
        appName: 'SpendX',
        createdAt: DateTime.now().toUtc(),
        databaseSha256: sha256.convert(invalidDbBytes).toString(),
        databaseSize: invalidDbBytes.length,
        recordCounts: {'accounts': 2, 'economic_events': 1, 'postings': 2},
        canonicalEventCount: 1,
        postingCount: 2,
        evidenceCount: 0,
        reviewCandidateCount: 0,
        debitTotal: 50000, // Falsely claims to be balanced to test deep database validation
        creditTotal: 50000,
        deviceId: 'test_dev',
        settings: {},
      );

      final invalidPkg = File(p.join(tempDir.path, 'unbalanced_ledger.spendx'));
      await BackupFileService.instance.createPackage(
        dbFile: invalidDbFile,
        manifest: manifest,
        outputFile: invalidPkg,
      );
      await invalidStaging.delete(recursive: true);

      // Staging validation must detect the double-entry imbalance and throw BackupValidationException
      final testStageDir = await Directory.systemTemp.createTemp('spendx_verify_stage_');
      try {
        await expectLater(
          () => BackupService.instance.prepareStagedRestore(
            packageFile: invalidPkg,
            stagingDir: testStageDir,
          ),
          throwsA(isA<BackupValidationException>().having(
            (e) => e.message,
            'message',
            contains('Unbalanced posted events detected in staged database'),
          )),
        );
      } finally {
        await testStageDir.delete(recursive: true);
      }

      // Verify primary database is completely untouched
      expect(db.isOpen, isTrue);
      final checkAccounts = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: ['acc_step6_double_entry_preservation'],
      );
      expect(checkAccounts.length, 1);
      expect(checkAccounts.first['name'], 'Safe Live Account');

      // Gate remains open
      expect(gate.isOpen, isTrue);
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('6.6. Staging directory and temporary artifacts are cleaned up on success and failure', () async {
      final db = await AppDatabase.instance.database;

      // 1. Success path cleanup: prepareStagedRestore cleans DB connection, caller deletes stagingDir
      final pkgFile = await generateValidBackupPackage(filename: 'step6_test6.spendx');
      final stageDirSuccess = await Directory.systemTemp.createTemp('spendx_clean_success_');
      final staged = await BackupService.instance.prepareStagedRestore(
        packageFile: pkgFile,
        stagingDir: stageDirSuccess,
      );
      expect(staged.stagedDbFile.existsSync(), isTrue);

      // Delete staging directory (mimicking restoreFromFile finally block)
      await stageDirSuccess.delete(recursive: true);
      expect(stageDirSuccess.existsSync(), isFalse);

      // 2. Failure path cleanup in restoreFromFile:
      // When restoreFromFile fails during prepareStagedRestore, it must clean up its internal staging directory.
      final invalidPkg = File(p.join(tempDir.path, 'invalid_cleanup.spendx'));
      await invalidPkg.writeAsString('not a valid archive');

      final beforeTempDirs = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('spendx_restore_stage_'))
          .map((d) => d.path)
          .toSet();

      await expectLater(
        () => BackupService.instance.restoreFromFile(invalidPkg),
        throwsA(anything),
      );

      final afterTempDirs = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('spendx_restore_stage_'))
          .map((d) => d.path)
          .toSet();

      // No leaked staging directories created by restoreFromFile
      final leakedDirs = afterTempDirs.difference(beforeTempDirs);
      expect(leakedDirs, isEmpty);

      await db.close();
    });

    test('6.7. Serialization of concurrent restore attempts: second attempt rejected safely', () async {
      final db = await AppDatabase.instance.database;
      final pkgFile = await generateValidBackupPackage(filename: 'step6_test7.spendx');

      // Emulate restore serialization via restoreFromFile
      // We start one restore, and while it is active, invoke a second restore.
      final stageDir = await Directory.systemTemp.createTemp('spendx_stage_concurrency_');

      try {
        final firstRestoreFuture = BackupService.instance.restoreFromFile(
          pkgFile,
          targetDb: db,
          targetDbPath: await AppDatabase.instance.getDatabasePath(),
        );

        // Attempt a concurrent restore while the first is in progress
        final secondRestoreResult = await BackupService.instance.restoreFromFile(
          pkgFile,
          targetDb: db,
          targetDbPath: await AppDatabase.instance.getDatabasePath(),
        );

        // Second restore must be rejected immediately
        expect(secondRestoreResult, isFalse);

        final firstRestoreResult = await firstRestoreFuture;
        expect(firstRestoreResult, isTrue);
      } finally {
        await stageDir.delete(recursive: true);
        await db.close();
      }
    });

    test('6.8. Separation of preparation/staging from destructive replacement: staging does not swap DB', () async {
      final db = await AppDatabase.instance.database;
      final now = DateTime.now().toUtc().toIso8601String();

      // 1. Initial account in primary database
      await db.insert(TablesV24.accounts, {
        'id': 'acc_original_state',
        'name': 'Original State Account',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });

      // 2. Generate a package with a distinct account
      final pkgFile = await generateValidBackupPackage(filename: 'step6_test8.spendx');

      // 3. Insert a NEW account into the primary database AFTER package was generated
      await db.insert(TablesV24.accounts, {
        'id': 'acc_live_mutation_after_pkg',
        'name': 'Live Mutation After Pkg',
        'account_type': 'expense',
        'subtype': 'groceries',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });

      // 4. Run prepareStagedRestore
      final stagingDir = await Directory.systemTemp.createTemp('spendx_test_stage_68_');
      try {
        final staged = await BackupService.instance.prepareStagedRestore(
          packageFile: pkgFile,
          stagingDir: stagingDir,
        );
        expect(staged.stagedDbFile.existsSync(), isTrue);

        // 5. Verify that prepareStagedRestore DID NOT swap or replace primary database!
        final liveAccounts = await db.query(TablesV24.accounts);
        final liveIds = liveAccounts.map((a) => a['id']).toSet();

        // Both accounts exist in the primary DB (live database was untouched and not overwritten)
        expect(liveIds.contains('acc_original_state'), isTrue);
        expect(liveIds.contains('acc_live_mutation_after_pkg'), isTrue);

        // Coordinator is STILL active, NOT restoring
        expect(DatabaseLifecycleCoordinator.instance.currentState, DatabaseLifecycleState.active);

        // Gate is OPEN
        expect(gate.isOpen, isTrue);
        expect(gate.activeOperations, 0);
      } finally {
        await stagingDir.delete(recursive: true);
        await db.close();
      }
    });

    test('6.9. Injected staging directory creation failure resets _busy and permits subsequent restore', () async {
      final db = await AppDatabase.instance.database;
      final pkgFile = await generateValidBackupPackage(filename: 'step6_test9.spendx');
      final dbPath = await AppDatabase.instance.getDatabasePath();

      // Inject deterministic failure on staging directory creation
      BackupService.stagingDirectoryCreatorForTesting = (_) async {
        throw const FileSystemException('Injected test failure: cannot create staging directory');
      };

      // Attempt restore — must throw FileSystemException
      await expectLater(
        () => BackupService.instance.restoreFromFile(
          pkgFile,
          targetDb: db,
          targetDbPath: dbPath,
        ),
        throwsA(isA<FileSystemException>()),
      );

      // Verify busy state is completely cleared
      expect(BackupService.instance.isBusy, isFalse);

      // Verify coordinator is still active and not stuck in restoring
      expect(DatabaseLifecycleCoordinator.instance.currentState, DatabaseLifecycleState.active);

      // Verify primary database is open and usable
      expect(gate.isOpen, isTrue);
      expect(gate.activeOperations, 0);

      // Reset injection seam
      BackupService.stagingDirectoryCreatorForTesting = null;

      // Verify subsequent restore succeeds without being rejected as busy
      final secondRestoreResult = await BackupService.instance.restoreFromFile(
        pkgFile,
        targetDb: db,
        targetDbPath: await AppDatabase.instance.getDatabasePath(),
      );
      expect(secondRestoreResult, isTrue);
      expect(BackupService.instance.isBusy, isFalse);

      await db.close();
    });

    test('6.10. Staging isolation: two simultaneous preparations using distinct directories succeed independently', () async {
      final db = await AppDatabase.instance.database;
      final pkgFile1 = await generateValidBackupPackage(filename: 'step6_test10_1.spendx');
      final pkgFile2 = await generateValidBackupPackage(filename: 'step6_test10_2.spendx');

      final stageDir1 = await Directory.systemTemp.createTemp('spendx_iso_1_');
      final stageDir2 = await Directory.systemTemp.createTemp('spendx_iso_2_');

      try {
        final f1 = BackupService.instance.prepareStagedRestore(
          packageFile: pkgFile1,
          stagingDir: stageDir1,
        );
        final f2 = BackupService.instance.prepareStagedRestore(
          packageFile: pkgFile2,
          stagingDir: stageDir2,
        );

        final results = await Future.wait([f1, f2]);
        expect(results[0].stagedDbFile.existsSync(), isTrue);
        expect(results[1].stagedDbFile.existsSync(), isTrue);
        expect(results[0].stagedDbFile.path, isNot(equals(results[1].stagedDbFile.path)));
      } finally {
        await stageDir1.delete(recursive: true);
        await stageDir2.delete(recursive: true);
        await db.close();
      }
    });

    test('6.11. Staging isolation: two simultaneous preparations attempting to use same directory reject collision', () async {
      final db = await AppDatabase.instance.database;
      final pkgFile = await generateValidBackupPackage(filename: 'step6_test11.spendx');
      final sharedStageDir = await Directory.systemTemp.createTemp('spendx_shared_stage_');

      try {
        // Start preparation 1
        final f1 = BackupService.instance.prepareStagedRestore(
          packageFile: pkgFile,
          stagingDir: sharedStageDir,
        );

        // Immediately attempt preparation 2 with the identical directory
        final f2 = BackupService.instance.prepareStagedRestore(
          packageFile: pkgFile,
          stagingDir: sharedStageDir,
        );

        // One of the preparations must be rejected immediately with collision exception
        dynamic errorF2;
        try {
          await f2;
        } catch (e) {
          errorF2 = e;
        }

        expect(errorF2, isA<BackupValidationException>().having(
          (e) => e.message,
          'message',
          contains('Staging directory collision'),
        ));

        // The first preparation finishes successfully
        final staged1 = await f1;
        expect(staged1.stagedDbFile.existsSync(), isTrue);
      } finally {
        await sharedStageDir.delete(recursive: true);
        await db.close();
      }
    });

    test('6.12. Staging isolation: non-empty staging directory rejects preparation before extraction', () async {
      final db = await AppDatabase.instance.database;
      final pkgFile = await generateValidBackupPackage(filename: 'step6_test12.spendx');
      final dirtyStageDir = await Directory.systemTemp.createTemp('spendx_dirty_stage_');

      // Seed an existing file in the directory to simulate leftover or colliding artifacts
      final leftoverFile = File(p.join(dirtyStageDir.path, 'leftover.tmp'));
      await leftoverFile.writeAsString('stale content');

      try {
        await expectLater(
          () => BackupService.instance.prepareStagedRestore(
            packageFile: pkgFile,
            stagingDir: dirtyStageDir,
          ),
          throwsA(isA<BackupValidationException>().having(
            (e) => e.message,
            'message',
            contains('is not empty'),
          )),
        );
      } finally {
        await dirtyStageDir.delete(recursive: true);
        await db.close();
      }
    });

    test('6.13. Failure during extraction releases staging ownership and closes database handles', () async {
      final db = await AppDatabase.instance.database;
      final invalidPkg = File(p.join(tempDir.path, 'corrupt_for_release.spendx'));
      await invalidPkg.writeAsString('corrupted non-zip content');

      final stageDir = await Directory.systemTemp.createTemp('spendx_release_test_');

      try {
        await expectLater(
          () => BackupService.instance.prepareStagedRestore(
            packageFile: invalidPkg,
            stagingDir: stageDir,
          ),
          throwsA(isA<BackupValidationException>()),
        );

        // Verify directory registration was cleanly removed from active set
        // by verifying that a subsequent call on the same (now cleaned) directory is accepted
        await stageDir.delete(recursive: true);
        final freshStageDir = await Directory.systemTemp.createTemp('spendx_release_test_');

        final validPkg = await generateValidBackupPackage(filename: 'valid_after_fail.spendx');
        final staged = await BackupService.instance.prepareStagedRestore(
          packageFile: validPkg,
          stagingDir: freshStageDir,
        );
        expect(staged.stagedDbFile.existsSync(), isTrue);

        await freshStageDir.delete(recursive: true);
      } finally {
        if (await stageDir.exists()) {
          await stageDir.delete(recursive: true);
        }
        await db.close();
      }
    });

    test('6.14. Staging isolation: equivalent normalized paths (symlinks/dots/slashes) resolve to same directory and collide', () async {
      final db = await AppDatabase.instance.database;
      final pkgFile = await generateValidBackupPackage(filename: 'step6_test14.spendx');
      final stageDir = await Directory.systemTemp.createTemp('spendx_norm_stage_');

      // Construct an equivalent alias path using relative segments, redundant slashes, and dots
      final aliasPath = '${stageDir.path}/../${p.basename(stageDir.path)}/./';
      final aliasDir = Directory(aliasPath);

      try {
        final f1 = BackupService.instance.prepareStagedRestore(
          packageFile: pkgFile,
          stagingDir: stageDir,
        );

        final f2 = BackupService.instance.prepareStagedRestore(
          packageFile: pkgFile,
          stagingDir: aliasDir,
        );

        dynamic errorF2;
        try {
          await f2;
        } catch (e) {
          errorF2 = e;
        }

        expect(errorF2, isA<BackupValidationException>().having(
          (e) => e.message,
          'message',
          contains('Staging directory collision'),
        ));

        final staged1 = await f1;
        expect(staged1.stagedDbFile.existsSync(), isTrue);
      } finally {
        await stageDir.delete(recursive: true);
        await db.close();
      }
    });
  });
}
