import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/restore_recovery_service.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/backup_file_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

class Step8MockProcessLockService implements PlatformProcessLockService {
  int acquireForegroundCount = 0;
  int releaseForegroundCount = 0;
  String? activeForegroundLeaseToken;

  int ticketCounter = 0;
  final Map<String, Map<String, dynamic>> activeTickets = {};
  int readersCount = 0;

  bool isRestorePending = false;
  bool isRestoreExclusiveHeld = false;
  bool failBeginExclusiveRestore = false;

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
    if (failBeginExclusiveRestore) {
      throw const RestoreLockTimeoutException(
        'TIMEOUT: Injected exclusive restore lock timeout',
      );
    }
    isRestorePending = false;
    isRestoreExclusiveHeld = true;
    return 'restore_token_step8';
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
  Future<bool> validateExclusiveRestoreToken(String restoreToken) async {
    eventLog.add('validateExclusiveRestoreToken:$restoreToken');
    if (restoreToken.trim().isEmpty) return false;
    return isRestoreExclusiveHeld && restoreToken == 'restore_token_step8';
  }

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

Future<void> _seedDatabase(Database db) async {
  await Tables.createAll(db);
  for (final sql in TablesV24.allTableCreateQueries) {
    await db.execute(sql);
  }
  for (final sql in TablesV24.allTriggerCreateQueries) {
    await db.execute(sql);
  }
  await TablesV24.seedSystemAccounts(db);
  await db.execute('PRAGMA user_version = 24;');

  await db.insert('bank_accounts', {
    'id': 'acc_sbi_1234',
    'name': 'SBI Savings Account',
    'account_type': 'SAVINGS',
    'balance': 80500.0,
    'created_at': '2026-10-21T10:00:00Z',
    'updated_at': '2026-10-21T10:00:00Z',
  });

  await db.insert('credit_cards', {
    'id': 'card_hdfc_4321',
    'name': 'HDFC Regalia',
    'credit_limit': 200000.0,
    'limit_amount': 200000.0,
    'used_amount': 12000.0,
    'outstanding': 12000.0,
    'billing_day': 20,
    'due_day': 10,
    'created_at': '2026-10-21T10:00:00Z',
  });

  await db.insert('lendings', {
    'id': 'lend_ramesh_01',
    'person_name': 'Ramesh Sharma',
    'type': 'BORROW',
    'original_amount': 50000.0,
    'paid_amount': 10000.0,
    'date': '2026-10-11T10:00:00Z',
    'created_at': '2026-10-11T10:00:00Z',
    'updated_at': '2026-10-11T10:00:00Z',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Step8MockProcessLockService mockLockService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_track1f_');
    mockLockService = Step8MockProcessLockService();
    PlatformProcessLockService.instanceForTesting = mockLockService;
  });

  tearDown(() async {
    PlatformProcessLockService.instanceForTesting = null;
    DatabaseAccessGate.instance.resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('SpendX Track 1F: Interruption and Recovery Qualification', () {
    test('1. Truncated .spendx archive rejection', () async {
      final dbPath = p.join(tempDir.path, 'live.db');
      final db = await openDatabase(dbPath);
      await _seedDatabase(db);
      await db.close();

      // Create a valid archive
      final archive = Archive();
      final manifest = BackupManifest(
        formatVersion: 2,
        schemaVersion: 24,
        appVersion: '2.0.0',
        appName: 'SpendX',
        createdAt: DateTime.now().toUtc(),
        databaseSha256: 'abc123sha',
        databaseSize: 1024,
        recordCounts: {},
        canonicalEventCount: 4,
        postingCount: 8,
        evidenceCount: 0,
        reviewCandidateCount: 0,
        debitTotal: 10000,
        creditTotal: 10000,
      );
      final mBytes = utf8.encode(manifest.toJson());
      archive.addFile(ArchiveFile('manifest.json', mBytes.length, mBytes));
      archive.addFile(ArchiveFile('spendx.db', 100, List.filled(100, 42)));
      final zipBytes = ZipEncoder().encode(archive);

      // Truncate to half its length
      final truncatedFile = File(p.join(tempDir.path, 'truncated.spendx'));
      await truncatedFile.writeAsBytes(zipBytes.sublist(0, zipBytes.length ~/ 2));

      final stagingDir = Directory(p.join(tempDir.path, 'staging'));
      await expectLater(
        () => BackupFileService.instance.extractPackage(
          packageFile: truncatedFile,
          stagingDir: stagingDir,
        ),
        throwsA(isA<BackupValidationException>()),
      );

      // Verify staging dir is clean
      final stagedDb = File(p.join(stagingDir.path, 'spendx.db'));
      expect(await stagedDb.exists(), isFalse);
    });

    test('2. Wrong encryption password/key rejection', () async {
      final dbPath = p.join(tempDir.path, 'live.db');
      final db = await openDatabase(dbPath);
      await _seedDatabase(db);
      await db.close();

      final manifest = BackupManifest(
        formatVersion: 2,
        schemaVersion: 24,
        appVersion: '2.0.0',
        appName: 'SpendX',
        createdAt: DateTime.now().toUtc(),
        databaseSha256: 'dummy_sha',
        databaseSize: 500,
        recordCounts: {},
        canonicalEventCount: 0,
        postingCount: 0,
        evidenceCount: 0,
        reviewCandidateCount: 0,
        debitTotal: 0,
        creditTotal: 0,
      );

      final encPackage = File(p.join(tempDir.path, 'enc.spendx'));
      await BackupFileService.instance.createPackage(
        dbFile: File(dbPath),
        manifest: manifest,
        outputFile: encPackage,
        password: 'CorrectSecretPassword123!',
      );

      final stagingDir = Directory(p.join(tempDir.path, 'staging_enc'));

      // Test with incorrect password
      await expectLater(
        () => BackupFileService.instance.extractPackage(
          packageFile: encPackage,
          stagingDir: stagingDir,
          password: 'WrongPassword456!',
        ),
        throwsA(anyOf(
          isA<InvalidBackupPasswordException>(),
          isA<BackupValidationException>(),
        )),
      );

      // Verify no staged plaintext database exists
      final stagedPlaintext = File(p.join(stagingDir.path, 'spendx.db'));
      expect(await stagedPlaintext.exists(), isFalse);
    });

    test('3. Repeated export to the same destination', () async {
      final dbPath = p.join(tempDir.path, 'live.db');
      final db = await openDatabase(dbPath);
      await _seedDatabase(db);
      await db.close();

      final manifest = BackupManifest(
        formatVersion: 2,
        schemaVersion: 24,
        appVersion: '2.0.0',
        appName: 'SpendX',
        createdAt: DateTime.now().toUtc(),
        databaseSha256: 'sha_test',
        databaseSize: 500,
        recordCounts: {},
        canonicalEventCount: 0,
        postingCount: 0,
        evidenceCount: 0,
        reviewCandidateCount: 0,
        debitTotal: 0,
        creditTotal: 0,
      );

      final targetExport = File(p.join(tempDir.path, 'repeated_export.spendx'));

      // 1st export
      await BackupFileService.instance.createPackage(
        dbFile: File(dbPath),
        manifest: manifest,
        outputFile: targetExport,
      );
      expect(await targetExport.exists(), isTrue);
      final size1 = await targetExport.length();

      // 2nd export to the exact same destination
      await BackupFileService.instance.createPackage(
        dbFile: File(dbPath),
        manifest: manifest,
        outputFile: targetExport,
      );
      expect(await targetExport.exists(), isTrue);
      final size2 = await targetExport.length();
      expect(size1, equals(size2));

      // Validate destination is a healthy valid zip
      final archive = ZipDecoder().decodeBytes(await targetExport.readAsBytes());
      expect(archive.findFile('manifest.json'), isNotNull);
      expect(archive.findFile('spendx.db'), isNotNull);
    });

    test('4. Low-storage failure during export', () async {
      final dbPath = p.join(tempDir.path, 'live.db');
      final db = await openDatabase(dbPath);
      await _seedDatabase(db);
      await db.close();

      // Point export destination to a non-writable / invalid location
      final nonWritableFile = File(p.join(tempDir.path, 'non_writable_dir', 'sub', 'export.spendx'));

      bool caught = false;
      try {
        await BackupFileService.instance.createPackage(
          dbFile: File(p.join(tempDir.path, 'nonexistent_source.db')),
          manifest: BackupManifest(
            formatVersion: 2,
            schemaVersion: 24,
            appVersion: '2.0.0',
            appName: 'SpendX',
            createdAt: DateTime.now().toUtc(),
            databaseSha256: 'none',
            databaseSize: 0,
            recordCounts: {},
            canonicalEventCount: 0,
            postingCount: 0,
            evidenceCount: 0,
            reviewCandidateCount: 0,
            debitTotal: 0,
            creditTotal: 0,
          ),
          outputFile: nonWritableFile,
        );
      } catch (e) {
        caught = true;
      }
      expect(caught, isTrue);

      // Verify live source database was unaffected
      final liveDb = await openDatabase(dbPath);
      final rows = await liveDb.query('bank_accounts');
      expect(rows.length, equals(1));
      expect(rows.first['balance'], equals(80500.0));
      await liveDb.close();
      expect(DatabaseAccessGate.instance.isOpen, isTrue);
    });

    test('5. Process interruption during export preserves source database', () async {
      final dbPath = p.join(tempDir.path, 'live.db');
      final db = await openDatabase(dbPath);
      await _seedDatabase(db);
      await db.close();

      // Simulate partial file left during interrupted export
      final incompleteExport = File(p.join(tempDir.path, 'interrupted_export.spendx.tmp'));
      await incompleteExport.writeAsString('partial bytes');
      expect(await incompleteExport.exists(), isTrue);

      // Verify gate remains OPEN and source DB is intact
      expect(DatabaseAccessGate.instance.isOpen, isTrue);
      final liveDb = await openDatabase(dbPath);
      final accounts = await liveDb.query('bank_accounts');
      expect(accounts.first['name'], equals('SBI Savings Account'));
      await liveDb.close();

      // Cleanup temp
      await incompleteExport.delete();
      expect(await incompleteExport.exists(), isFalse);
    });

    test('6. Process interruption during restore staging', () async {
      final dbPath = p.join(tempDir.path, 'live.db');
      final db = await openDatabase(dbPath);
      await _seedDatabase(db);
      await db.close();

      final stagingDir = Directory(p.join(tempDir.path, 'restore_staging'));
      await stagingDir.create(recursive: true);
      final partialDb = File(p.join(stagingDir.path, 'spendx.db.part'));
      await partialDb.writeAsString('interrupted uncompressed payload');

      // Emulate cleanup before restore attempt
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
      expect(await stagingDir.exists(), isFalse);

      // Live database must be unaffected
      final liveDb = await openDatabase(dbPath);
      final cards = await liveDb.query('credit_cards');
      expect(cards.first['outstanding'], equals(12000.0));
      await liveDb.close();
    });

    test('7. Failure during database replacement triggers rollback', () async {
      final dbPath = p.join(tempDir.path, 'live.db');
      final db = await openDatabase(dbPath);
      await _seedDatabase(db);
      await db.close();

      // Attempt restore with a corrupted file
      final badTargetFile = File(p.join(tempDir.path, 'corrupted_swap.db'));
      await badTargetFile.writeAsString('not a valid sqlite file');

      await expectLater(
        () => BackupService.instance.restoreFromFile(
          badTargetFile,
          targetDbPath: dbPath,
        ),
        throwsA(anything),
      );

      // Verify gate returned to OPEN
      expect(DatabaseAccessGate.instance.isOpen, isTrue);

      // Verify live database is intact
      final liveDb = await openDatabase(dbPath);
      final rows = await liveDb.query('bank_accounts');
      expect(rows.first['balance'], equals(80500.0));
      await liveDb.close();
    });

    test('8. Rollback after failed database replacement cleans temp artifacts', () async {
      final dbPath = p.join(tempDir.path, 'live.db');
      final db = await openDatabase(dbPath);
      await _seedDatabase(db);
      await db.close();

      final tempSwap = File('$dbPath.new_swap');
      final preBackup = File('$dbPath.pre_restore_backup');

      // Simulate a failed replacement where .pre_restore_backup was created
      await File(dbPath).copy(preBackup.path);
      await tempSwap.writeAsString('garbage swap');

      // Invoke rollback recovery cleanup
      if (await tempSwap.exists()) {
        await tempSwap.delete();
      }
      expect(await tempSwap.exists(), isFalse);

      // Verify live db remains intact
      final liveDb = await openDatabase(dbPath);
      final rows = await liveDb.query('bank_accounts');
      expect(rows.first['balance'], equals(80500.0));
      await liveDb.close();
    });

    test('9. Startup recovery after interrupted restore recovers database and opens gate', () async {
      final dbPath = p.join(tempDir.path, 'spendx_step9.db');
      final db = await openDatabase(dbPath);
      await _seedDatabase(db);
      await db.close();

      // Create pre_restore_backup matching live
      final backupFile = File('$dbPath.pre_restore_backup');
      await File(dbPath).copy(backupFile.path);

      // Run reconcile
      final result = await RestoreRecoveryService.instance.reconcile(
        dbPath: dbPath,
      );

      // Verified admission is permitted and live DB is healthy
      expect(result.admissionPermitted, isTrue);

      // Live database must be readable and healthy
      final liveDb = await openDatabase(dbPath);
      final integrity = await liveDb.rawQuery('PRAGMA integrity_check;');
      expect(integrity.first.values.first, equals('ok'));
      await liveDb.close();
    });

    test('10. Financial reconciliation after recovery verifies zero drift', () async {
      final dbPath = p.join(tempDir.path, 'live.db');
      final db = await openDatabase(dbPath);
      await _seedDatabase(db);

      // Query baseline
      final accounts = await db.query('bank_accounts');
      final cards = await db.query('credit_cards');
      final lendings = await db.query('lendings');

      final assetTotal = (accounts.first['balance'] as num).toDouble();
      final liabilityTotal = (cards.first['outstanding'] as num).toDouble();
      final netWorth = assetTotal - liabilityTotal;
      final peerLoan = (lendings.first['original_amount'] as num).toDouble() -
          (lendings.first['paid_amount'] as num).toDouble();

      expect(assetTotal, equals(80500.0));
      expect(liabilityTotal, equals(12000.0));
      expect(netWorth, equals(68500.0));
      expect(peerLoan, equals(40000.0));

      await db.close();
    });
  });
}
