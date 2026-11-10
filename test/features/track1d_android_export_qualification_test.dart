import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/data/security/database_encryption_migration_service.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/backup_file_service.dart';
import 'package:spend_x/services/export_service.dart';

class MockFilePickerForExport extends FilePicker with MockPlatformInterfaceMixin {
  Uint8List? capturedBytes;
  String? capturedFileName;
  FileType? capturedType;
  List<String>? capturedAllowedExtensions;
  String? returnPath;
  bool shouldReturnNull = false;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    capturedBytes = bytes;
    capturedFileName = fileName;
    capturedType = type;
    capturedAllowedExtensions = allowedExtensions;

    if (shouldReturnNull) {
      return null;
    }

    if (returnPath != null && bytes != null) {
      final file = File(returnPath!);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    }
    return returnPath;
  }
}

Future<void> _createSchema(Database db) async {
  await Tables.createAll(db);
  for (final sql in TablesV24.allTableCreateQueries) {
    await db.execute(sql);
  }
  for (final sql in TablesV24.allTriggerCreateQueries) {
    await db.execute(sql);
  }
  await TablesV24.seedSystemAccounts(db);
  await db.execute('PRAGMA user_version = 24;');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late MockFilePickerForExport mockPicker;
  FilePicker? originalPicker;

  setUpAll(() {
    try {
      originalPicker = FilePicker.platform;
    } catch (_) {}
  });

  tearDownAll(() {
    if (originalPicker != null) {
      FilePicker.platform = originalPicker!;
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_export_qual_');
    mockPicker = MockFilePickerForExport();
    FilePicker.platform = mockPicker;
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('1. ExportFullBackup provides non-null non-empty bytes to FilePicker', () async {
    final destinationPath = p.join(tempDir.path, 'output', 'spendx_backup.spendx');
    mockPicker.returnPath = destinationPath;

    // Create synthetic database with realistic records
    final dbPath = p.join(tempDir.path, 'source_test.db');
    final db = await openDatabase(
      dbPath,
      version: 24,
      onCreate: (db, version) async {
        await _createSchema(db);
      },
    );

    await db.insert('bank_accounts', {
      'id': 'acc_sbi',
      'name': 'SBI Savings Account',
      'account_type': 'SAVINGS',
      'balance': 80500.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    await db.insert('credit_cards', {
      'id': 'card_hdfc',
      'name': 'HDFC Regalia',
      'credit_limit': 200000.0,
      'limit_amount': 200000.0,
      'used_amount': 12000.0,
      'outstanding': 12000.0,
      'billing_day': 20,
      'due_day': 10,
      'created_at': DateTime.now().toIso8601String(),
    });

    await db.close();

    // Call BackupService to create backup package
    final (packageFile, manifest) = await BackupService.instance.createBackupPackage(
      sourceDbPath: dbPath,
    );
    expect(await packageFile.exists(), isTrue);
    expect(await packageFile.length(), greaterThan(0));

    // Verify manual export pass: bytes must be supplied
    final exportedBytes = await packageFile.readAsBytes();
    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Backup',
      fileName: BackupFileService.backupFileName,
      type: FileType.custom,
      allowedExtensions: ['spendx'],
      bytes: exportedBytes,
    );

    expect(savedPath, equals(destinationPath));
    expect(mockPicker.capturedBytes, isNotNull);
    expect(mockPicker.capturedBytes!.length, equals(exportedBytes.length));
    expect(mockPicker.capturedFileName, equals('spendx_backup.spendx'));
    expect(mockPicker.capturedAllowedExtensions, equals(['spendx']));

    final savedFile = File(destinationPath);
    expect(await savedFile.exists(), isTrue);
    expect(await savedFile.length(), equals(exportedBytes.length));
  });

  test('2. Exported .spendx package is a valid zip containing manifest.json and spendx.db', () async {
    final destinationPath = p.join(tempDir.path, 'validity_check', 'spendx_backup.spendx');
    mockPicker.returnPath = destinationPath;

    final dbPath = p.join(tempDir.path, 'source_validity.db');
    final db = await openDatabase(
      dbPath,
      version: 24,
      onCreate: (db, version) async {
        await _createSchema(db);
      },
    );

    await db.insert('bank_accounts', {
      'id': 'acc_1',
      'name': 'Test Account',
      'account_type': 'CHECKING',
      'balance': 5000.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.close();

    final (packageFile, manifest) = await BackupService.instance.createBackupPackage(
      sourceDbPath: dbPath,
    );

    final bytes = await packageFile.readAsBytes();
    await FilePicker.platform.saveFile(
      fileName: 'spendx_backup.spendx',
      bytes: bytes,
    );

    final savedFile = File(destinationPath);
    final archive = ZipDecoder().decodeBytes(await savedFile.readAsBytes());

    final manifestEntry = archive.findFile('manifest.json');
    expect(manifestEntry, isNotNull);

    final manifestJson = jsonDecode(utf8.decode(manifestEntry!.content as List<int>));
    expect(manifestJson['format_version'], isNotNull);
    expect(manifestJson['database_sha256'], isNotNull);

    final dbEntry = archive.findFile('spendx.db');
    expect(dbEntry, isNotNull);

    final extractedDbBytes = dbEntry!.content as List<int>;
    final computedSha256 = sha256.convert(extractedDbBytes).toString();
    expect(computedSha256, equals(manifestJson['database_sha256']));
  });

  test('3. ExportFullBackup returns null cleanly when user cancels file picker', () async {
    mockPicker.shouldReturnNull = true;

    final result = await ExportService.instance.exportFullBackup();
    expect(result, isNull);
    expect(mockPicker.capturedBytes, isNotNull, reason: 'Bytes must still have been prepared and passed to saveFile');
  });

  test('4. End-to-end round-trip: Exported realistic backup can be validated and restored', () async {
    final destinationPath = p.join(tempDir.path, 'round_trip', 'spendx_backup.spendx');
    mockPicker.returnPath = destinationPath;

    // 1. Create populated source database
    final sourceDbPath = p.join(tempDir.path, 'source_populated.db');
    final sourceDb = await openDatabase(
      sourceDbPath,
      version: 24,
      onCreate: (db, version) async {
        await _createSchema(db);
      },
    );

    // Insert SBI Savings ₹80,500
    await sourceDb.insert('bank_accounts', {
      'id': 'acc_sbi_1234',
      'name': 'SBI Savings Account',
      'account_type': 'SAVINGS',
      'balance': 80500.0,
      'created_at': '2026-10-21T10:00:00Z',
      'updated_at': '2026-10-21T10:00:00Z',
    });

    // Insert HDFC Regalia liability ₹12,000
    await sourceDb.insert('credit_cards', {
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

    // Insert 4 transactions
    await sourceDb.insert('transactions', {
      'id': 'tx_01',
      'note': 'Opening Balance',
      'amount': 25000.0,
      'type': 'income',
      'date': '2026-10-21T10:00:00Z',
      'account_id': 'acc_sbi_1234',
      'created_at': '2026-10-21T10:00:00Z',
      'updated_at': '2026-10-21T10:00:00Z',
    });
    await sourceDb.insert('transactions', {
      'id': 'tx_02',
      'note': 'Monthly Salary Credit',
      'amount': 60000.0,
      'type': 'income',
      'date': '2026-10-26T10:00:00Z',
      'account_id': 'acc_sbi_1234',
      'created_at': '2026-10-26T10:00:00Z',
      'updated_at': '2026-10-26T10:00:00Z',
    });
    await sourceDb.insert('transactions', {
      'id': 'tx_03',
      'note': 'Supermarket Groceries',
      'amount': 4500.0,
      'type': 'expense',
      'date': '2026-10-31T12:00:00Z',
      'account_id': 'acc_sbi_1234',
      'created_at': '2026-10-31T12:00:00Z',
      'updated_at': '2026-10-31T12:00:00Z',
    });
    await sourceDb.insert('transactions', {
      'id': 'tx_04',
      'note': 'Electronics & Dining',
      'amount': 12000.0,
      'type': 'expense',
      'date': '2026-11-05T18:00:00Z',
      'account_id': 'acc_sbi_1234',
      'created_at': '2026-11-05T18:00:00Z',
      'updated_at': '2026-11-05T18:00:00Z',
    });

    // 2. Export package from source DB
    final (packageFile, manifest) = await BackupService.instance.createBackupPackage(
      sourceDb: sourceDb,
      sourceDbPath: sourceDbPath,
    );
    await sourceDb.close();
    final bytes = await packageFile.readAsBytes();
    final exportedPath = await FilePicker.platform.saveFile(
      fileName: 'spendx_backup.spendx',
      bytes: bytes,
    );
    expect(exportedPath, equals(destinationPath));

    final exportedFile = File(destinationPath);
    expect(await exportedFile.exists(), isTrue);

    // 3. Extract and validate package
    final extractDir = Directory(p.join(tempDir.path, 'extract_staging'));
    await extractDir.create();
    final staged = await BackupFileService.instance.extractPackage(
      packageFile: exportedFile,
      stagingDir: extractDir,
    );
    expect(staged.manifest.schemaVersion, equals(24));
    expect(staged.manifest.databaseSha256, equals(manifest.databaseSha256));

    // 4. Restore into fresh target DB
    final targetDbPath = p.join(tempDir.path, 'target_restored.db');
    final targetDb = await openDatabase(
      targetDbPath,
      version: 24,
      onCreate: (db, version) async {
        await _createSchema(db);
      },
    );

    final restoreSuccess = await BackupService.instance.restoreFromFile(
      exportedFile,
      targetDbPath: targetDbPath,
      targetDb: targetDb,
    );
    expect(restoreSuccess, isTrue);

    // 5. Verify restored database records and balances
    final isPlaintext = DatabaseEncryptionMigrationService.isPlaintextSqliteFile(targetDbPath);
    final Database restoredDb;
    if (isPlaintext) {
      restoredDb = await openDatabase(targetDbPath);
    } else {
      final key = await SpendXDatabaseKeyManager.instance.getOrCreateKey();
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key);
      restoredDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        targetDbPath,
        password: blobKey,
        bypassPrimaryGuard: true,
      );
    }
    final accounts = await restoredDb.query('bank_accounts');
    expect(accounts.length, equals(1));
    expect(accounts.first['name'], equals('SBI Savings Account'));
    expect(accounts.first['balance'], equals(80500.0));

    final cards = await restoredDb.query('credit_cards');
    expect(cards.length, equals(1));
    expect(cards.first['name'], equals('HDFC Regalia'));
    expect(cards.first['used_amount'], equals(12000.0));

    final txs = await restoredDb.query('transactions');
    expect(txs.length, equals(4));

    await restoredDb.close();
  });
}
