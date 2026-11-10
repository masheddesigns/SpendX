import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/backup_file_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';

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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_failure_qual_');
  });

  tearDown(() async {
    BackupService.resetTestingFlags();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Track 1E — Backup Integrity & Failure Qualification', () {
    test('1. Empty and truncated zip archives are rejected with BackupValidationException', () async {
      // 0-byte file
      final emptyFile = File(p.join(tempDir.path, 'empty.spendx'));
      await emptyFile.writeAsBytes(const []);

      await expectLater(
        BackupFileService.instance.extractPackage(
          packageFile: emptyFile,
          stagingDir: Directory(p.join(tempDir.path, 'stage_empty')),
        ),
        throwsA(isA<BackupValidationException>()),
      );

      // Truncated garbage file
      final garbageFile = File(p.join(tempDir.path, 'garbage.spendx'));
      await garbageFile.writeAsBytes([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]);

      await expectLater(
        BackupFileService.instance.extractPackage(
          packageFile: garbageFile,
          stagingDir: Directory(p.join(tempDir.path, 'stage_garbage')),
        ),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('2. Archive missing manifest.json or database snapshot is rejected', () async {
      // Archive with DB only (no manifest)
      final noManifestArchive = Archive();
      noManifestArchive.addFile(ArchiveFile('spendx.db', 10, utf8.encode('dummy data')));
      final noManifestFile = File(p.join(tempDir.path, 'no_manifest.spendx'));
      await noManifestFile.writeAsBytes(ZipEncoder().encode(noManifestArchive));

      await expectLater(
        BackupFileService.instance.extractPackage(
          packageFile: noManifestFile,
          stagingDir: Directory(p.join(tempDir.path, 'stage_no_man')),
        ),
        throwsA(isA<BackupValidationException>().having(
          (e) => e.message,
          'message',
          contains('missing manifest.json'),
        )),
      );

      // Archive with manifest only (no DB)
      final noDbArchive = Archive();
      final manifestJson = jsonEncode({
        'format_version': 2,
        'schema_version': 24,
        'app_version': '2.0.0',
        'database_sha256': 'dummy',
        'is_encrypted': false,
        'record_counts': <String, int>{},
        'created_at': DateTime.now().toIso8601String(),
      });
      noDbArchive.addFile(ArchiveFile('manifest.json', manifestJson.length, utf8.encode(manifestJson)));
      final noDbFile = File(p.join(tempDir.path, 'no_db.spendx'));
      await noDbFile.writeAsBytes(ZipEncoder().encode(noDbArchive));

      await expectLater(
        BackupFileService.instance.extractPackage(
          packageFile: noDbFile,
          stagingDir: Directory(p.join(tempDir.path, 'stage_no_db')),
        ),
        throwsA(isA<BackupValidationException>().having(
          (e) => e.message,
          'message',
          contains('missing spendx.db'),
        )),
      );
    });

    test('3. Database SHA-256 checksum mismatch rejects immediately and deletes staged file', () async {
      final dbBytes = utf8.encode('real_sqlite_data_stream_content');
      final forgedSha256 = sha256.convert(utf8.encode('tampered_content')).toString();

      final archive = Archive();
      final manifestJson = jsonEncode({
        'format_version': 2,
        'schema_version': 24,
        'app_version': '2.0.0',
        'database_sha256': forgedSha256,
        'is_encrypted': false,
        'record_counts': <String, int>{},
        'created_at': DateTime.now().toIso8601String(),
      });
      archive.addFile(ArchiveFile('manifest.json', manifestJson.length, utf8.encode(manifestJson)));
      archive.addFile(ArchiveFile('spendx.db', dbBytes.length, dbBytes));

      final packageFile = File(p.join(tempDir.path, 'tampered_hash.spendx'));
      await packageFile.writeAsBytes(ZipEncoder().encode(archive));

      final stageDir = Directory(p.join(tempDir.path, 'stage_tampered'));
      await expectLater(
        BackupFileService.instance.extractPackage(
          packageFile: packageFile,
          stagingDir: stageDir,
        ),
        throwsA(isA<BackupValidationException>().having(
          (e) => e.message,
          'message',
          contains('Cryptographic checksum mismatch'),
        )),
      );

      final stagedDbFile = File(p.join(stageDir.path, 'spendx.db'));
      expect(await stagedDbFile.exists(), isFalse);
    });

    test('4. Encrypted backup requires password and rejects incorrect password', () async {
      final dbPath = p.join(tempDir.path, 'source_enc.db');
      final db = await openDatabase(
        dbPath,
        version: 24,
        onCreate: (db, ver) => _seedDatabase(db),
      );

      final encOutputFile = File(p.join(tempDir.path, 'encrypted.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        outputFile: encOutputFile,
        password: 'CorrectPassword123!',
      );
      await db.close();

      expect(await encOutputFile.exists(), isTrue);

      await expectLater(
        BackupFileService.instance.extractPackage(
          packageFile: encOutputFile,
          stagingDir: Directory(p.join(tempDir.path, 'stage_no_pass')),
        ),
        throwsA(isA<BackupPasswordRequiredException>()),
      );

      await expectLater(
        BackupFileService.instance.extractPackage(
          packageFile: encOutputFile,
          stagingDir: Directory(p.join(tempDir.path, 'stage_wrong_pass')),
          password: 'WrongPassword456!',
        ),
        throwsA(isA<InvalidBackupPasswordException>()),
      );

      final staged = await BackupFileService.instance.extractPackage(
        packageFile: encOutputFile,
        stagingDir: Directory(p.join(tempDir.path, 'stage_correct_pass')),
        password: 'CorrectPassword123!',
      );
      expect(staged.isEncrypted, isTrue);
      expect(await staged.stagedDbFile.exists(), isTrue);
    });

    test('5. Restore failure before swap preserves active database and returns gate to OPEN', () async {
      final activeDbPath = p.join(tempDir.path, 'active_live.db');
      final activeDb = await openDatabase(
        activeDbPath,
        version: 24,
        onCreate: (db, ver) => _seedDatabase(db),
      );
      await activeDb.close();

      final corruptPackage = File(p.join(tempDir.path, 'corrupted_package.spendx'));
      await corruptPackage.writeAsBytes([1, 2, 3, 4, 5]);

      final targetDb = await openDatabase(activeDbPath);

      await expectLater(
        BackupService.instance.restoreFromFile(
          corruptPackage,
          targetDbPath: activeDbPath,
          targetDb: targetDb,
        ),
        throwsA(isA<BackupValidationException>()),
      );

      final verifyDb = await openDatabase(activeDbPath);
      final accounts = await verifyDb.query('bank_accounts');
      expect(accounts.length, equals(1));
      expect(accounts.first['name'], equals('SBI Savings Account'));
      await verifyDb.close();

      expect(DatabaseAccessGate.instance.isOpen, isTrue);
    });

    test('6. Rollback during atomic swap recovers live DB and cleans temp artifacts', () async {
      final activeDbPath = p.join(tempDir.path, 'rollback_test.db');
      final activeDb = await openDatabase(
        activeDbPath,
        version: 24,
        onCreate: (db, ver) => _seedDatabase(db),
      );

      final validPackage = File(p.join(tempDir.path, 'valid.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: activeDb,
        outputFile: validPackage,
      );
      await activeDb.close();

      BackupService.failReplacementRenameForTesting = true;

      final targetDb = await openDatabase(activeDbPath);
      await expectLater(
        BackupService.instance.restoreFromFile(
          validPackage,
          targetDbPath: activeDbPath,
          targetDb: targetDb,
        ),
        throwsA(isA<RestoreException>()),
      );

      BackupService.resetTestingFlags();

      final verifyDb = await openDatabase(activeDbPath);
      final accounts = await verifyDb.query('bank_accounts');
      expect(accounts.length, equals(1));
      expect(accounts.first['balance'], equals(80500.0));
      await verifyDb.close();

      final tempSwap = File('$activeDbPath.new_swap');
      expect(await tempSwap.exists(), isFalse);
    });

    test('7. Privacy scrubbing: Expired evidence payload is purged prior to snapshot', () async {
      final dbPath = p.join(tempDir.path, 'privacy_test.db');
      final db = await openDatabase(
        dbPath,
        version: 24,
        onCreate: (db, ver) => _seedDatabase(db),
      );

      await db.insert('evidence', {
        'id': 'ev_expired_01',
        'source_type': 'sms',
        'extracted_amount_minor_units': 1000,
        'extracted_timestamp': '2020-01-01T00:00:00Z',
        'body_sha256': 'dummy_hash_1',
        'raw_payload_encrypted': 'Confidential SMS OTP: 987654',
        'retention_expires_at': '2020-01-01T00:00:00Z',
        'is_payload_purged': 0,
        'created_at': '2020-01-01T00:00:00Z',
      });

      await db.insert('evidence', {
        'id': 'ev_active_01',
        'source_type': 'sms',
        'extracted_amount_minor_units': 2500000,
        'extracted_timestamp': '2026-11-10T00:00:00Z',
        'body_sha256': 'dummy_hash_2',
        'raw_payload_encrypted': 'Active Encrypted Payload',
        'retention_expires_at': '2030-01-01T00:00:00Z',
        'is_payload_purged': 0,
        'created_at': '2026-11-10T00:00:00Z',
      });

      final packageFile = File(p.join(tempDir.path, 'privacy_pkg.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        outputFile: packageFile,
      );
      await db.close();

      final staged = await BackupFileService.instance.extractPackage(
        packageFile: packageFile,
        stagingDir: Directory(p.join(tempDir.path, 'stage_privacy')),
      );

      final snapDb = await openDatabase(staged.stagedDbFile.path);
      final evidences = await snapDb.query('evidence');
      expect(evidences.length, equals(2));

      final expiredRecord = evidences.firstWhere((e) => e['id'] == 'ev_expired_01');
      expect(expiredRecord['raw_payload_encrypted'], isNull);
      expect(expiredRecord['is_payload_purged'], equals(1));

      final activeRecord = evidences.firstWhere((e) => e['id'] == 'ev_active_01');
      expect(activeRecord['raw_payload_encrypted'], equals('Active Encrypted Payload'));
      expect(activeRecord['is_payload_purged'], equals(0));
      await snapDb.close();
    });

    test('8. Repeated backup export overwrites cleanly without file lock conflicts', () async {
      final dbPath = p.join(tempDir.path, 'repeat_test.db');
      final db = await openDatabase(
        dbPath,
        version: 24,
        onCreate: (db, ver) => _seedDatabase(db),
      );

      final targetOutput = File(p.join(tempDir.path, 'repeated_target.spendx'));

      final (pkg1, manifest1) = await BackupService.instance.createBackupPackage(
        sourceDb: db,
        outputFile: targetOutput,
      );
      expect(await pkg1.exists(), isTrue);

      await db.insert('transactions', {
        'id': 'tx_repeat_01',
        'amount': 1500.0,
        'type': 'expense',
        'date': '2026-11-10T12:00:00Z',
        'account_id': 'acc_sbi_1234',
        'created_at': '2026-11-10T12:00:00Z',
        'updated_at': '2026-11-10T12:00:00Z',
      });

      final (pkg2, manifest2) = await BackupService.instance.createBackupPackage(
        sourceDb: db,
        outputFile: targetOutput,
      );
      expect(await pkg2.exists(), isTrue);
      expect(pkg2.path, equals(pkg1.path));
      expect(manifest2.databaseSha256, isNot(equals(manifest1.databaseSha256)));
      await db.close();
    });
  });
}
