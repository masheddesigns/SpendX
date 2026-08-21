// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' hide Transaction;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/migrations/ledger_backfill_service.dart';

void main() {
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await openDatabase(inMemoryDatabasePath);
    await Tables.createAll(db);
  });

  tearDown(() async => db.close());

  Future<void> _seedAccount(Database db, String id, double balance,
      {int isAsset = 1}) async {
    await db.insert('bank_accounts', {
      'id': id,
      'name': 'Account $id',
      'balance': balance,
      'is_asset': isAsset,
      'created_at': DateTime(2024, 1, 1).toIso8601String(),
      'updated_at': DateTime(2024, 1, 1).toIso8601String(),
    });
  }

  Future<void> _seedTxn(
    Database db,
    String id,
    String type,
    double amount, {
    String? accountId,
    String? relatedEntityId,
    String? categoryId,
  }) async {
    await db.insert('transactions', {
      'id': id,
      'amount': amount,
      'type': type,
      'account_id': accountId,
      'related_entity_id': relatedEntityId,
      'category_id': categoryId,
      'date': DateTime(2025, 5, 1).toIso8601String(),
      'created_at': DateTime(2025, 5, 1).toIso8601String(),
      'updated_at': DateTime(2025, 5, 1).toIso8601String(),
    });
  }

  Future<int> _ledgerCount() async =>
      (await db.query('ledger_transactions')).length;

  group('Phase 1D reconcile — acceptance gate B', () {
    test('clean transaction -> CREATE', () async {
      await _seedAccount(db, 'A', 1000);
      await _seedTxn(db, 't1', 'income', 600, accountId: 'A');
      final report = await LedgerBackfillService.reconcile(db, authorized: true);

      expect(report.verdict, 'PASS');
      expect(report.isExecutable, isTrue);
      expect(report.ledgerEntriesCreated, greaterThanOrEqualTo(1));
      final rows = await db.query('ledger_transactions',
          where: 'reference_id = ?', whereArgs: ['t1']);
      expect(rows.length, 1);
      expect(rows.first['type'], 'income');
    });

    test('already correctly journaled -> SKIP (no duplicate)', () async {
      await _seedAccount(db, 'A', 5000);
      await _seedTxn(db, 't1', 'income', 1000, accountId: 'A');
      await db.insert('ledger_transactions', {
        'id': 'legacy-1',
        'type': 'income',
        'amount': 1000.0,
        'date': DateTime(2025, 1, 1).toIso8601String(),
        'account_id': 'A',
        'reference_id': 't1',
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
      });

      final report = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(report.existingLedgerSkipped, greaterThanOrEqualTo(1));
      expect(report.ledgerEntriesCreated, 0);
      final rows = await db.query('ledger_transactions',
          where: 'reference_id = ?', whereArgs: ['t1']);
      expect(rows.length, 1);
    });

    test('already journaled but amount/type differs -> WARN/REVIEW, no mutation',
        () async {
      await _seedAccount(db, 'A', 1000);
      await _seedTxn(db, 't1', 'income', 1000, accountId: 'A');
      await db.insert('ledger_transactions', {
        'id': 'legacy-mismatched',
        'type': 'income',
        'amount': 500.0,
        'date': DateTime(2025, 1, 1).toIso8601String(),
        'account_id': 'A',
        'reference_id': 't1',
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
      });
      final before = await _ledgerCount();

      final report = await LedgerBackfillService.reconcile(db, authorized: true);

      expect(report.reviewItems, isNotEmpty);
      expect(report.hardFailures, isNotEmpty);
      expect(report.verdict, 'FAIL — ROLLED BACK');
      // The mismatched row is untouched; nothing new was created.
      expect(await _ledgerCount(), before);
      final rows = await db.query('ledger_transactions',
          where: 'reference_id = ?', whereArgs: ['t1']);
      expect(rows.length, 1);
      expect((rows.first['amount'] as num).toDouble(), 500.0);
    });

    test('legacy transaction without reference -> CREATE', () async {
      await _seedAccount(db, 'A', 2000);
      await _seedTxn(db, 'tX', 'expense', 300, accountId: 'A');
      final report = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(report.ledgerEntriesCreated, greaterThanOrEqualTo(1));
      final rows = await db.query('ledger_transactions',
          where: 'reference_id = ?', whereArgs: ['tX']);
      expect(rows.length, 1);
    });

    test('orphan reference -> FAIL', () async {
      await _seedAccount(db, 'A', 5000);
      await db.insert('ledger_transactions', {
        'id': 'orphan-1',
        'type': 'expense',
        'amount': 10.0,
        'date': DateTime(2025, 1, 1).toIso8601String(),
        'account_id': 'A',
        'reference_id': 'ghost-ref-xyz',
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
      });
      final before = await _ledgerCount();

      final report = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(report.verdict, 'FAIL — ROLLED BACK');
      expect(await _ledgerCount(), before);
    });

    test('duplicate reference -> FAIL', () async {
      await _seedAccount(db, 'A', 5000);
      await _seedTxn(db, 'dup1', 'income', 100, accountId: 'A');
      for (var i = 0; i < 2; i++) {
        await db.insert('ledger_transactions', {
          'id': 'dup-leg-$i',
          'type': 'income',
          'amount': 100.0,
          'date': DateTime(2025, 1, 1).toIso8601String(),
          'account_id': 'A',
          'reference_id': 'dup1',
          'created_at': DateTime(2025, 1, 1).toIso8601String(),
        });
      }
      final before = await _ledgerCount();

      final report = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(report.verdict, 'FAIL — ROLLED BACK');
      expect(await _ledgerCount(), before);
    });

    test('unknown reference domain -> FAIL', () async {
      await _seedAccount(db, 'A', 5000);
      await db.insert('ledger_transactions', {
        'id': 'unknown-domain',
        'type': 'expense',
        'amount': 10.0,
        'date': DateTime(2025, 1, 1).toIso8601String(),
        'account_id': 'A',
        'reference_id': 'futuretable-123',
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
      });
      final report = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(report.verdict, 'FAIL — ROLLED BACK');
    });

    test('credit parity mismatch -> FAIL', () async {
      await db.insert('credit_cards', {
        'id': 'C1',
        'name': 'Card',
        'used_amount': 0.0,
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
      });
      await db.insert('ledger_transactions', {
        'id': 'manual-credit',
        'type': 'credit_purchase',
        'amount': 500.0,
        'credit_card_id': 'C1',
        'date': DateTime(2025, 1, 1).toIso8601String(),
        'reference_id': 'migration-credit-manual',
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
      });
      final report = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(report.verdict, 'FAIL — ROLLED BACK');
    });

    test('loan parity mismatch -> FAIL', () async {
      await db.insert('loans', {
        'id': 'LN1',
        'name': 'Car Loan',
        'total': 100000.0,
        'loan_status': 'active',
        'start_date': DateTime(2025, 1, 1).toIso8601String(),
      });
      await db.insert('ledger_transactions', {
        'id': 'manual-loan',
        'type': 'loan_disbursement',
        'amount': 50000.0,
        'loan_id': 'LN1',
        'date': DateTime(2025, 1, 1).toIso8601String(),
        'reference_id': 'migration-loan-manual',
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
      });
      final report = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(report.verdict, 'FAIL — ROLLED BACK');
    });

    test('allowed lending repayment exception -> EXECUTABLE_WITH_EXCEPTIONS',
        () async {
      await db.insert('lendings', {
        'id': 'L1',
        'user_id': 'offline_user',
        'person_name': 'Bob',
        'type': 'lent',
        'original_amount': 2000.0,
        'paid_amount': 500.0,
        'date': DateTime(2025, 1, 1).toIso8601String(),
        'is_settled': 0,
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
        'updated_at': DateTime(2025, 1, 1).toIso8601String(),
      });

      final report = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(report.verdict, 'EXECUTABLE_WITH_EXCEPTIONS');
      expect(report.isExecutable, isTrue);
      expect(report.exceptions.join('\n'), contains('repayments'));
      expect(report.ledgerEntriesCreated, greaterThanOrEqualTo(1));
      // Re-run must not duplicate.
      final second = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(second.ledgerEntriesCreated, 0);
    });

    test('allowed salary/EMI residual -> EXECUTABLE_WITH_EXCEPTIONS + absorbed',
        () async {
      await _seedAccount(db, 'A', 1000);
      await db.insert('salary', {
        'id': 'S1',
        'company_name': 'Acme',
        'salary_month': '2025-05',
        'expected_date': DateTime(2025, 5, 1).toIso8601String(),
        'net_salary': 1000.0,
        'amount_received': 1000.0,
        'account_id': 'A',
        'created_at': DateTime(2025, 5, 1).toIso8601String(),
      });

      final report = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(report.verdict, 'EXECUTABLE_WITH_EXCEPTIONS');
      expect(report.openingAbsorbedSalary, 1000.0);
      expect(report.historicalCompleteness, 'PARTIAL');
      final openings = await db.query('ledger_transactions',
          where: 'type = ? AND account_id = ?',
          whereArgs: ['opening_balance', 'A']);
      expect(openings, isNotEmpty);
    });

    test('re-run -> zero duplicate creation', () async {
      await _seedAccount(db, 'A', 6000);
      await _seedTxn(db, 't1', 'income', 1000, accountId: 'A');
      await _seedTxn(db, 't2', 'expense', 400, accountId: 'A');
      final first = await LedgerBackfillService.reconcile(db, authorized: true);
      final afterFirst = await _ledgerCount();
      final second = await LedgerBackfillService.reconcile(db, authorized: true);
      final afterSecond = await _ledgerCount();
      expect(afterFirst, afterSecond);
      expect(second.ledgerEntriesCreated, 0);
      expect(second.openingBalancesCreated, 0);
      expect(first.verdict, 'PASS');
    });

    test('execution failure -> complete rollback (no partial rows)', () async {
      await _seedAccount(db, 'A', 5000);
      await _seedTxn(db, 'ok', 'income', 1000, accountId: 'A');
      await db.insert('ledger_transactions', {
        'id': 'orphan-2',
        'type': 'expense',
        'amount': 5.0,
        'date': DateTime(2025, 1, 1).toIso8601String(),
        'account_id': 'A',
        'reference_id': 'ghost-ref-2',
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
      });
      final before = await _ledgerCount();

      await LedgerBackfillService.reconcile(db, authorized: true);

      // Only the already-present orphan remains; nothing from the failed run
      // (income leg, opening balance) persisted.
      final rows = await db.query('ledger_transactions');
      expect(rows.length, before);
      expect(rows.first['id'], 'orphan-2');
    });

    test('preflight (authorized:false) never mutates', () async {
      await _seedAccount(db, 'A', 6000);
      await _seedTxn(db, 't1', 'income', 1000, accountId: 'A');
      final before = await _ledgerCount();

      final report =
          await LedgerBackfillService.reconcile(db, authorized: false);
      expect(report.verdict, 'PASS');
      expect(await _ledgerCount(), before);
    });
  });

  group('Phase 1D reconcile — financial invariants (gate D)', () {
    test('derived balance == legacy stored for every reconciled account',
        () async {
      await _seedAccount(db, 'A', 2000);
      await _seedAccount(db, 'B', 5000);
      await _seedTxn(db, 'i1', 'income', 600, accountId: 'A');
      await _seedTxn(db, 'e1', 'expense', 200, accountId: 'A');
      await _seedTxn(db, 'i3', 'income', 5000, accountId: 'B');
      // Pre-existing correct ledger row for B (must be preserved, not duped).
      await db.insert('ledger_transactions', {
        'id': 'legacy-b',
        'type': 'income',
        'amount': 5000.0,
        'date': DateTime(2025, 1, 1).toIso8601String(),
        'account_id': 'B',
        'reference_id': 'i3',
        'created_at': DateTime(2025, 1, 1).toIso8601String(),
      });

      final report = await LedgerBackfillService.reconcile(db, authorized: true);
      expect(report.verdict, 'PASS');

      // Invariant: derived == stored for every account.
      final accounts = await db.query('bank_accounts');
      for (final a in accounts) {
        final accId = a['id'] as String;
        final stored = (a['balance'] as num).toDouble();
        final derived = (await db.rawQuery(
          '''SELECT COALESCE(SUM(CASE WHEN type IN
              ('income','lending_received','loan_disbursement','refund',
               'opening_balance') THEN amount
             WHEN type IN ('expense','credit_payment','emi_installment',
              'loan_payment','transfer','lending_given','fuel_expense',
              'processing_fee','interest_charge') THEN -amount
             ELSE 0 END),0) as b
             FROM ledger_transactions WHERE account_id = ?''',
          [accId],
        )).first['b'];
        expect((derived as num).toDouble(), stored,
            reason: 'Account $accId derived ($derived) != stored ($stored)');
      }

      // transactions unchanged, bank_accounts.balance unchanged.
      expect((await db.query('transactions')).length, 3);
      final balances = await db.query('bank_accounts');
      expect((balances.firstWhere((b) => b['id'] == 'A')['balance'] as num),
          2000);
      expect((balances.firstWhere((b) => b['id'] == 'B')['balance'] as num),
          5000);

      // Pre-existing ledger row preserved & not duplicated.
      final bRows = await db.query('ledger_transactions',
          where: 'reference_id = ?', whereArgs: ['i3']);
      expect(bRows.length, 1);
      expect(report.existingLedgerSkipped, greaterThanOrEqualTo(1));
    });
  });

  group('Phase 1D — AppDatabase flag / authorization / kill-switch gates', () {
    late String dbPath;

    setUpAll(() async {
      dbPath = p.join(
          await getDatabasesPath(), 'spendx_reconcile_gate_test.db');
      AppDatabase.setTestDatabasePath(dbPath);
    });

    tearDownAll(() async {
      AppDatabase.setTestDatabasePath(null);
      try {
        await AppDatabase.instance.close();
      } finally {
        final f = File(dbPath);
        if (await f.exists()) await f.delete();
      }
    });

    Future<Database> _openLive() async {
      final a = AppDatabase.instance;
      // Reset the singleton and wipe the on-disk file so each gate test starts
      // from a pristine, isolated database.
      await a.close();
      final f = File(dbPath);
      if (await f.exists()) await f.delete();
      final live = await a.database;
      await Tables.createAll(live);
      return live;
    }

    test('flag OFF / authorization absent / kill switch -> no mutation',
        () async {
      final live = await _openLive();
      await live.insert('bank_accounts', {
        'id': 'A',
        'name': 'Savings',
        'balance': 2000.0,
        'is_asset': 1,
        'created_at': DateTime(2024, 1, 1).toIso8601String(),
        'updated_at': DateTime(2024, 1, 1).toIso8601String(),
      });
      await live.insert('transactions', {
        'id': 't1',
        'amount': 600.0,
        'type': 'income',
        'account_id': 'A',
        'date': DateTime(2025, 5, 1).toIso8601String(),
        'created_at': DateTime(2025, 5, 1).toIso8601String(),
        'updated_at': DateTime(2025, 5, 1).toIso8601String(),
      });

      // (1) Feature flag OFF (default) -> no mutation.
      final r1 = await AppDatabase.instance.runLedgerBackfill(authorized: true);
      expect((await live.query('ledger_transactions')).isEmpty, isTrue);
      expect(r1.exceptions.join('\n'), contains('disabled'));

      // (2) Flag ON but authorization absent -> preflight only, no mutation.
      await AppDatabase.instance.setBackfillEnabled(true);
      final r2 =
          await AppDatabase.instance.runLedgerBackfill(authorized: false);
      expect((await live.query('ledger_transactions')).isEmpty, isTrue);
      expect(r2.isExecutable || r2.verdict.contains('PASS'), isTrue);

      // (3) Authorized -> actually reconciles.
      final r3 = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );
      expect(r3.verdict, 'PASS');
      expect((await live.query('ledger_transactions')).length,
          greaterThanOrEqualTo(2));

      // (4) Kill switch active -> subsequent run mutates nothing.
      await AppDatabase.instance.setKillSwitch(true);
      final before = (await live.query('ledger_transactions')).length;
      final r4 = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );
      expect(r4.hardFailures.join('\n'), contains('Kill switch'));
      expect((await live.query('ledger_transactions')).length, before);

      await AppDatabase.instance.close();
      final f = File(dbPath);
      if (await f.exists()) await f.delete();
    });
  });
}
