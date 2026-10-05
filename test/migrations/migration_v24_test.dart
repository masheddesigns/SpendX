import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/migrations/migration_v24_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('MigrationV24Service — Unit & Invariant Tests', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await Tables.createAll(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('1. Deterministic Minor Units conversion and boundary rejection', () {
      expect(MigrationV24Service.toMinorUnits(0.01), 1);
      expect(MigrationV24Service.toMinorUnits(0.10), 10);
      expect(MigrationV24Service.toMinorUnits(1.15), 115);
      expect(MigrationV24Service.toMinorUnits(10.05), 1005);
      expect(MigrationV24Service.toMinorUnits(999.99), 99999);
      expect(MigrationV24Service.toMinorUnits(-50.25), -5025);

      // Overflow rejection (> 1 lakh crore rupees = 10^12 rupees)
      expect(
        () => MigrationV24Service.toMinorUnits(1000000000001.0),
        throwsA(isA<StateError>()),
      );
      expect(
        () => MigrationV24Service.toMinorUnits(-1000000000001.0),
        throwsA(isA<StateError>()),
      );
    });

    test('2. Successful migration of comprehensive legacy fixture', () async {
      // Seed bank accounts
      await db.insert('bank_accounts', {
        'id': 'acc_hdfc',
        'name': 'HDFC Salary',
        'bank': 'HDFC',
        'last4': '1234',
        'balance': 25000.0, // 25,000 INR
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
        'updated_at': DateTime(2025, 1, 1).toIso8601String(),
      });

      // Seed credit cards
      await db.insert('credit_cards', {
        'id': 'card_icici',
        'name': 'ICICI Amazon Pay',
        'bank': 'ICICI',
        'last4': '5678',
        'credit_limit': 150000.0,
        'used_amount': 4500.0, // 4,500 INR used
        'billing_day': 15,
        'due_day': 5,
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
      });

      // Seed categories
      await db.insert('categories', {
        'id': 'cat_food',
        'name': 'Food & Dining',
        'type': 'expense',
      });
      await db.insert('categories', {
        'id': 'cat_salary',
        'name': 'Salary',
        'type': 'income',
      });

      // Seed transactions
      // 1. Ordinary expense
      await db.insert('transactions', {
        'id': 'tx_1',
        'amount': 500.0,
        'type': 'expense',
        'account_id': 'acc_hdfc',
        'category_id': 'cat_food',
        'date': DateTime(2025, 2, 1).toIso8601String(),
        'note': 'Dinner',
        'created_at': DateTime(2025, 2, 1).toIso8601String(),
        'updated_at': DateTime(2025, 2, 1).toIso8601String(),
      });

      // 2. Card purchase
      await db.insert('transactions', {
        'id': 'tx_2',
        'amount': 4500.0,
        'type': 'credit_card_purchase',
        'account_id': 'card_icici',
        'category_id': 'cat_food',
        'date': DateTime(2025, 2, 2).toIso8601String(),
        'note': 'Amazon Grocery',
        'created_at': DateTime(2025, 2, 2).toIso8601String(),
        'updated_at': DateTime(2025, 2, 2).toIso8601String(),
      });

      // 3. Card payment (Zero expense!)
      await db.insert('transactions', {
        'id': 'tx_3',
        'amount': 2000.0,
        'type': 'credit_payment',
        'account_id': 'acc_hdfc',
        'related_entity_id': 'card_icici',
        'date': DateTime(2025, 2, 3).toIso8601String(),
        'note': 'Card bill payment',
        'created_at': DateTime(2025, 2, 3).toIso8601String(),
        'updated_at': DateTime(2025, 2, 3).toIso8601String(),
      });

      // 4. Refund (Contra-expense, zero income!)
      await db.insert('transactions', {
        'id': 'tx_4',
        'amount': 150.0,
        'type': 'refund',
        'account_id': 'acc_hdfc',
        'category_id': 'cat_food',
        'date': DateTime(2025, 2, 4).toIso8601String(),
        'note': 'Refund for meal',
        'created_at': DateTime(2025, 2, 4).toIso8601String(),
        'updated_at': DateTime(2025, 2, 4).toIso8601String(),
      });

      // 5. Soft-deleted transaction (Must NOT produce active postings!)
      await db.insert('transactions', {
        'id': 'tx_deleted',
        'amount': 9999.0,
        'type': 'expense',
        'account_id': 'acc_hdfc',
        'category_id': 'cat_food',
        'is_deleted': 1,
        'date': DateTime(2025, 2, 5).toIso8601String(),
        'note': 'Mistaken entry',
        'created_at': DateTime(2025, 2, 5).toIso8601String(),
        'updated_at': DateTime(2025, 2, 5).toIso8601String(),
      });

      // 6. Review queue item
      await db.insert('review_queue', {
        'id': 'rq_1',
        'raw_sms': 'Rs 250 paid to Swiggy',
        'parsed_json': '{}',
        'confidence': 0.85,
        'status': 'pending',
        'created_at': DateTime(2025, 2, 6).toIso8601String(),
      });

      // Run migration with allowDestructiveDrops = false (C2A default)
      final result = await MigrationV24Service.migrate(
        db,
        allowDestructiveDrops: false,
      );

      expect(result.alreadyMigrated, isFalse);
      expect(result.accountsMigrated, greaterThan(0));
      expect(result.eventsMigrated, greaterThan(0));
      expect(result.postingsCreated, greaterThan(0));
      expect(result.destructiveDropsExecuted, isFalse);

      // Verify PRAGMA user_version is 24
      final ver = (await db.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(ver, 24);

      // Verify legacy tables are still physically present (gated drop)
      final legacyTables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('transactions', 'bank_accounts', 'vehicles');",
      );
      expect(legacyTables.length, greaterThanOrEqualTo(2));

      // Verify review candidates isolated with zero postings
      final rc = await db.query(TablesV24.reviewCandidates);
      expect(rc.length, 1);
      expect(rc.first['id'], 'rq_1');

      // Verify soft-deleted transaction is excluded from economic_events and has zero postings (FX10)
      final deletedEvt = await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: ['tx_deleted'],
      );
      expect(deletedEvt.length, 0);
      final deletedPostings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['tx_deleted'],
      );
      expect(deletedPostings.length, 0);
      expect(result.sourceTransactionsExcludedByPolicy, 1);

      // Verify Card Payment (tx_3) has ZERO Expense postings
      final cardPayPostings = await db.rawQuery('''
        SELECT p.*, a.account_type
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        WHERE p.economic_event_id = 'tx_3' AND a.account_type = 'expense';
      ''');
      expect(cardPayPostings, isEmpty);

      // Verify Refund (tx_4) has ZERO Income postings
      final refundPostings = await db.rawQuery('''
        SELECT p.*, a.account_type
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        WHERE p.economic_event_id = 'tx_4' AND a.account_type = 'income';
      ''');
      expect(refundPostings, isEmpty);

      // Verify Account Parity for HDFC (25,000 INR = 2,500,000 paise)
      final hdfcBalanceRow = await db.rawQuery('''
        SELECT 
          COALESCE(SUM(
            CASE 
              WHEN direction = 'debit' THEN amount_minor_units
              WHEN direction = 'credit' THEN -amount_minor_units
              ELSE 0 
            END
          ), 0) AS derived_balance
        FROM ${TablesV24.postings}
        WHERE account_id = 'acc_hdfc';
      ''');
      expect(hdfcBalanceRow.first['derived_balance'], 2500000);

      // Verify Opening Balance Reconciliation record exists for HDFC
      final obr = await db.query(
        TablesV24.openingBalanceReconciliations,
        where: 'account_id = ?',
        whereArgs: ['acc_hdfc'],
      );
      expect(obr.length, 1);
      expect(obr.first['legacy_reported_balance_minor_units'], 2500000);
    });

    test('3. Native SQLite Trigger Suite enforces draft -> posted lifecycle & balance', () async {
      // First, migrate empty DB to install triggers and system accounts
      await MigrationV24Service.migrate(db);

      // Invariant A: Inserting directly as 'posted' is blocked by trigger
      expect(
        () => db.insert(TablesV24.economicEvents, {
          'id': 'evt_bad_1',
          'event_type': 'expense',
          'lifecycle_status': 'posted',
          'timestamp': DateTime.now().toIso8601String(),
          'currency': 'INR',
          'description': 'Direct posted',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Create valid draft event
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_draft_1',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': DateTime.now().toIso8601String(),
        'currency': 'INR',
        'description': 'Draft event',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      // Invariant B: Transitioning to 'posted' with 0 postings is blocked
      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_draft_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Insert 1 posting (under-legged)
      await db.insert(TablesV24.postings, {
        'id': 'pst_leg_1',
        'economic_event_id': 'evt_draft_1',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 10000,
        'created_at': DateTime.now().toIso8601String(),
      });

      // Invariant C: Transitioning to 'posted' with only 1 posting is blocked
      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_draft_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Insert unbalanced second posting (debit 10000, credit 8000)
      await db.insert(TablesV24.postings, {
        'id': 'pst_leg_2',
        'economic_event_id': 'evt_draft_1',
        'account_id': TablesV24.sysSuspenseTransfer,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 8000,
        'created_at': DateTime.now().toIso8601String(),
      });

      // Invariant D: Transitioning to 'posted' with unbalanced debits != credits is blocked
      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_draft_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Fix balance: update second posting to 10000
      await db.update(
        TablesV24.postings,
        {'amount_minor_units': 10000},
        where: 'id = ?',
        whereArgs: ['pst_leg_2'],
      );

      // Transition to 'posted' now succeeds!
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_draft_1'],
      );

      final ev = (await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: ['evt_draft_1'],
      )).first;
      expect(ev['lifecycle_status'], 'posted');

      // Invariant E: Adding posting to an already-posted event is blocked
      expect(
        () => db.insert(TablesV24.postings, {
          'id': 'pst_leg_3',
          'economic_event_id': 'evt_draft_1',
          'account_id': TablesV24.sysExpMisc,
          'sequence_number': 3,
          'direction': 'debit',
          'amount_minor_units': 5000,
          'created_at': DateTime.now().toIso8601String(),
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Invariant F: Updating postings of a posted event is blocked
      expect(
        () => db.update(
          TablesV24.postings,
          {'amount_minor_units': 20000},
          where: 'id = ?',
          whereArgs: ['pst_leg_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Invariant G: Deleting postings of a posted event is blocked
      expect(
        () => db.delete(
          TablesV24.postings,
          where: 'id = ?',
          whereArgs: ['pst_leg_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Invariant H: Mutating canonical fields or deleting posted event is blocked
      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'event_type': 'income'},
          where: 'id = ?',
          whereArgs: ['evt_draft_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(
        () => db.delete(
          TablesV24.economicEvents,
          where: 'id = ?',
          whereArgs: ['evt_draft_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('4. 30-Day SMS Privacy Purge Contract', () async {
      final nowStr = DateTime.now().toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_1',
        'name': 'Primary',
        'balance': 1000.0,
        'created_at': nowStr,
        'updated_at': nowStr,
      });

      // Old SMS transaction (60 days ago)
      final oldDate =
          DateTime.now().subtract(const Duration(days: 60)).toIso8601String();
      await db.insert('transactions', {
        'id': 'tx_old_sms',
        'amount': 250.0,
        'type': 'expense',
        'account_id': 'acc_1',
        'source': 'sms',
        'note': 'CONFIDENTIAL OTP 1234 Bank Debit Rs 250',
        'external_ref': 'UPI/1234567890/OLD',
        'date': oldDate,
        'created_at': oldDate,
        'updated_at': oldDate,
      });

      // Recent SMS transaction (5 days ago)
      final recentDate =
          DateTime.now().subtract(const Duration(days: 5)).toIso8601String();
      await db.insert('transactions', {
        'id': 'tx_recent_sms',
        'amount': 100.0,
        'type': 'expense',
        'account_id': 'acc_1',
        'source': 'sms',
        'note': 'Recent Bank Debit Rs 100',
        'external_ref': 'UPI/9876543210/RECENT',
        'date': recentDate,
        'created_at': recentDate,
        'updated_at': recentDate,
      });

      await MigrationV24Service.migrate(db);

      // Verify old SMS evidence: raw_payload_encrypted IS NULL, is_payload_purged = 1
      final oldEvi = (await db.query(
        TablesV24.evidence,
        where: 'economic_event_id = ?',
        whereArgs: ['tx_old_sms'],
      )).first;
      expect(oldEvi['raw_payload_encrypted'], isNull);
      expect(oldEvi['is_payload_purged'], 1);
      expect(oldEvi['extracted_amount_minor_units'], 25000);
      expect(oldEvi['external_reference'], 'UPI/1234567890/OLD');
      expect((oldEvi['body_sha256'] as String).length, 64); // Valid sha256

      // Verify recent SMS evidence: raw_payload_encrypted IS NOT NULL, is_payload_purged = 0
      final recentEvi = (await db.query(
        TablesV24.evidence,
        where: 'economic_event_id = ?',
        whereArgs: ['tx_recent_sms'],
      )).first;
      expect(recentEvi['raw_payload_encrypted'], isNotNull);
      expect(recentEvi['is_payload_purged'], 0);
      expect(recentEvi['extracted_amount_minor_units'], 10000);
      expect(recentEvi['external_reference'], 'UPI/9876543210/RECENT');
    });

    test('5. Pre-migration backup creates non-zero file and verifies existence', () async {
      final tempDir = await Directory.systemTemp.createTemp('spendx_test_backup');
      final testDbFile = File('${tempDir.path}/test_spendx.db');

      final diskDb = await openDatabase(
        testDbFile.path,
        version: 23,
        onCreate: (d, v) async {
          await Tables.createAll(d);
          final now = DateTime.now().toIso8601String();
          await d.insert('bank_accounts', {
            'id': 'ba_test',
            'name': 'Test Bank',
            'balance': 100.0,
            'created_at': now,
            'updated_at': now,
          });
        },
      );

      final backupPath =
          await MigrationV24Service.createPreMigrationBackup(diskDb);
      expect(backupPath, isNotNull);
      final backupFile = File(backupPath!);
      expect(await backupFile.exists(), isTrue);
      expect(await backupFile.length(), greaterThan(0));

      await diskDb.close();
      await tempDir.delete(recursive: true);
    });
  });
}
