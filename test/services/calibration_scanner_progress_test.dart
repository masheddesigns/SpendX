import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/calibration_progress.dart';
import 'package:spend_x/services/live_sms_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory testDir;
  late String dbPath;
  late Database db;
  const channel = MethodChannel('spendx/sms_live');
  const permissionChannel = MethodChannel('flutter.baseflow.com/permissions/methods');

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'live_sms_detection': true,
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (MethodCall call) async {
      if (call.method == 'checkPermissionStatus') {
        return 1; // PermissionStatus.granted
      }
      if (call.method == 'requestPermissions') {
        final perms = call.arguments as List<dynamic>? ?? [];
        return {for (var p in perms) p: 1};
      }
      return null;
    });

    testDir = await Directory.systemTemp.createTemp('spendx_calib_test_');
    dbPath = p.join(testDir.path, 'calib_test.db');
    AppDatabase.setTestDatabasePath(dbPath);
    DatabaseAccessGate.instance.resetForTesting();
    DatabaseLifecycleCoordinator.instance.resetForTesting();
    db = await AppDatabase.instance.database;
    await CategoryRepo(executor: db).ensureDefaults();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
    try {
      await AppDatabase.instance.close();
    } catch (_) {}
    AppDatabase.setTestDatabasePath(null);
    try {
      if (testDir.existsSync()) testDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('CalibrationProgress Model Tests', () {
    test('default constructor initializes all counters to 0', () {
      const progress = CalibrationProgress();
      expect(progress.messagesScanned, 0);
      expect(progress.financialIdentified, 0);
      expect(progress.accountsDiscovered, 0);
      expect(progress.transactionsImported, 0);
      expect(progress.existingMatched, 0);
      expect(progress.reviewRequired, 0);
      expect(progress.obligationsDetected, 0);
      expect(progress.nonFinancialIgnored, 0);
    });

    test('copyWith updates specified counters distinctly', () {
      const progress = CalibrationProgress(
        messagesScanned: 10,
        financialIdentified: 8,
        accountsDiscovered: 2,
        transactionsImported: 5,
        existingMatched: 1,
        reviewRequired: 2,
        obligationsDetected: 1,
        nonFinancialIgnored: 2,
      );

      final updated = progress.copyWith(
        messagesScanned: 11,
        transactionsImported: 6,
      );

      expect(updated.messagesScanned, 11);
      expect(updated.transactionsImported, 6);
      expect(updated.financialIdentified, 8);
      expect(updated.accountsDiscovered, 2);
      expect(updated.reviewRequired, 2);
    });
  });

  group('Phase 1: Calibration Scanner Historical Ingestion & Progress', () {
    test('scans historical inbox, tracks distinct progress counters and enforces idempotency', () async {
      // 1. Seed a known Bank Account for reliable instrument attribution
      await AccountRepo().insertAccount(
        BankAccount(
          id: 'acc_federal_8434',
          name: 'Federal Bank (..8434)',
          bank: 'Federal Bank',
          last4: '8434',
          accountType: 'savings',
          balance: 10000.0,
        ),
      );

      final now = DateTime.now();
      final t1 = now.subtract(const Duration(days: 3)).millisecondsSinceEpoch;
      final t2 = now.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
      final t3 = now.subtract(const Duration(days: 1)).millisecondsSinceEpoch;

      // Messages in native descending order (newest first, as returned by Android Telephony query)
      final testMessages = [
        // Message 3: Credit card statement / bill reminder (obligation)
        {
          'id': 103,
          '_id': 103,
          'address': 'ICICIB',
          'body': 'Your ICICI Bank Credit Card statement is ready. Total amount due is Rs 12,500.00 by 28-Nov-2026. Min due Rs 650.00.',
          'date': t3,
        },
        // Message 2: Financial spend with known bank account (should be safely imported)
        {
          'id': 102,
          '_id': 102,
          'address': 'FEDBNK',
          'body': 'INR 450.00 debited from your A/C XX8434 on 18-Nov-26 towards Swiggy. Avl Bal INR 9550.00. Ref 82736192',
          'date': t2,
        },
        // Message 1: Non-financial OTP (should be ignored)
        {
          'id': 101,
          '_id': 101,
          'address': 'VK-OTP',
          'body': 'Your OTP for login is 482910. Do not share this with anyone.',
          'date': t1,
        },
      ];

      // Setup platform channel mock
      var callCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'syncActiveNotifications') return null;
        if (call.method == 'queryInboxPage') {
          callCount++;
          if (callCount == 1) {
            return {
              'messages': testMessages,
              'hasMore': false,
              'nextCursor': null,
            };
          }
          return {
            'messages': <dynamic>[],
            'hasMore': false,
            'nextCursor': null,
          };
        }
        return null;
      });

      final progressEvents = <CalibrationProgress>[];

      // Run calibration from inbox
      final outcome = await LiveSmsService.instance.calibrateFromInbox(
        cutoff: now.subtract(const Duration(days: 10)),
        onProgress: (p) => progressEvents.add(p),
      );

      expect(outcome.completed, isTrue);
      expect(outcome.error, isNull);

      final finalProgress = outcome.progress;
      expect(finalProgress.messagesScanned, 3, reason: 'Total messages scanned');
      expect(finalProgress.nonFinancialIgnored, 1, reason: 'OTP dropped');
      expect(finalProgress.financialIdentified, 2, reason: 'Debit and Statement alert identified');
      expect(finalProgress.transactionsImported, 1, reason: '1 valid transaction posted');
      expect(finalProgress.obligationsDetected, 1, reason: '1 card statement reminder detected');
      expect(finalProgress.accountsDiscovered, greaterThanOrEqualTo(1));

      // Verify that progress events were emitted as batches processed
      expect(progressEvents.isNotEmpty, isTrue);

      // Verify double-entry ledger canonical tables
      final expenseEvents = await db.query(
        TablesV24.economicEvents,
        where: 'event_type = ?',
        whereArgs: ['expense'],
      );
      expect(expenseEvents.length, 1, reason: 'Exactly one expense economic event safely imported into ledger');
      expect(expenseEvents.first['description'].toString().toLowerCase(), contains('swiggy'));

      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [expenseEvents.first['id']],
      );
      expect(postings.length, 2, reason: 'Balanced double-entry postings (source + destination)');
      expect((postings.first['amount_minor_units'] as num).toInt(), 45000);

      // Verify Idempotency: Second scan with same messages must NOT create duplicate transactions
      callCount = 0;
      final secondOutcome = await LiveSmsService.instance.calibrateFromInbox(
        cutoff: now.subtract(const Duration(days: 10)),
      );

      expect(secondOutcome.completed, isTrue);
      final expenseEventsAfterSecondScan = await db.query(
        TablesV24.economicEvents,
        where: 'event_type = ?',
        whereArgs: ['expense'],
      );
      expect(expenseEventsAfterSecondScan.length, 1, reason: 'Zero duplicate economic events created on rescan');
    });
  });
}
