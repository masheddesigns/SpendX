import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/migrations/ledger_backfill_service.dart';

Future<void> _seedAccount(
  Database db,
  String id,
  double balance, {
  int isAsset = 1,
}) async {
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

  tearDown(() async {
    await db.close();
  });

  test('1. opening balance creates exactly one ledger representation',
      () async {
    await _seedAccount(db, 'A', 5000);
    final report = await LedgerBackfillService.run(db);

    final openings = await db.query(
      'ledger_transactions',
      where: 'type = ?',
      whereArgs: ['opening_balance'],
    );
    expect(openings.length, 1);
    expect(openings.first['account_id'], 'A');
    expect(openings.first['reference_id'], 'migration-opening-balance-A');
    expect(openings.first['category_id'], isNull);
    expect(report.openingBalancesCreated, 1);
    expect(report.verdict, 'PASS');
  });

  test('2. opening balance does not count as income', () async {
    await _seedAccount(db, 'A', 5000);
    await LedgerBackfillService.run(db);

    final incomeRows = await db.query(
      'ledger_transactions',
      where: 'type = ?',
      whereArgs: ['income'],
    );
    expect(incomeRows.isEmpty, isTrue);

    final bal = (await db.rawQuery(
      '''SELECT SUM(CASE WHEN type IN ('income','lending_received',
          'loan_disbursement','refund','opening_balance') THEN amount
          WHEN type IN ('expense','credit_payment','emi_installment',
            'loan_payment','transfer','lending_given','fuel_expense',
            'processing_fee','interest_charge') THEN -amount ELSE 0 END) as b
         FROM ledger_transactions WHERE account_id = ?''',
      ['A'],
    )).first['b'];
    expect((bal as num).toDouble(), 5000);
  });

  test('3. existing income transaction gets one ledger row', () async {
    await _seedAccount(db, 'A', 6000);
    await _seedTxn(db, 't1', 'income', 1000, accountId: 'A');
    final report = await LedgerBackfillService.run(db);

    final rows = await db.query(
      'ledger_transactions',
      where: 'reference_id = ?',
      whereArgs: ['t1'],
    );
    expect(rows.length, 1);
    expect(rows.first['type'], 'income');
    expect(report.ledgerEntriesCreated, 1);
  });

  test('4. existing expense transaction gets one ledger row', () async {
    await _seedAccount(db, 'A', 4000);
    await _seedTxn(db, 't2', 'expense', 2000, accountId: 'A');
    final report = await LedgerBackfillService.run(db);

    final rows = await db.query(
      'ledger_transactions',
      where: 'reference_id = ?',
      whereArgs: ['t2'],
    );
    expect(rows.length, 1);
    expect(rows.first['type'], 'expense');
    expect(report.ledgerEntriesCreated, 1);
  });

  test('5. transfer gets exactly two ledger legs', () async {
    await _seedAccount(db, 'A', 3000);
    await _seedAccount(db, 'B', 3000);
    await _seedTxn(db, 't3', 'transfer', 1500,
        accountId: 'A', relatedEntityId: 'B');
    final report = await LedgerBackfillService.run(db);

    final rows = await db.query(
      'ledger_transactions',
      where: 'reference_id = ?',
      whereArgs: ['t3'],
    );
    expect(rows.length, 2);
    final types = rows.map((r) => r['type']).toSet();
    expect(types.contains('transfer'), isTrue);
    expect(types.contains('income'), isTrue);
    expect(report.ledgerEntriesCreated, 2);
  });

  test('6. category_id survives backfill', () async {
    await _seedAccount(db, 'A', 5000);
    await _seedTxn(db, 't6', 'expense', 300,
        accountId: 'A', categoryId: 'cat_food');
    await LedgerBackfillService.run(db);

    final rows = await db.query(
      'ledger_transactions',
      where: 'reference_id = ?',
      whereArgs: ['t6'],
    );
    expect(rows.first['category_id'], 'cat_food');
  });

  test('7. already-ledgered transaction is not duplicated', () async {
    await _seedAccount(db, 'A', 5000);
    await _seedTxn(db, 't7', 'income', 1000, accountId: 'A');
    await db.insert('ledger_transactions', {
      'id': 'legacy-1',
      'type': 'income',
      'amount': 1000,
      'date': DateTime(2025, 1, 1).toIso8601String(),
      'account_id': 'A',
      'reference_id': 't7',
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
    });

    final report = await LedgerBackfillService.run(db);
    final rows = await db.query(
      'ledger_transactions',
      where: 'reference_id = ?',
      whereArgs: ['t7'],
    );
    expect(rows.length, 1);
    expect(report.existingLedgerSkipped, 1);
    expect(report.ledgerEntriesCreated, 0);
  });

  test('8. migration is idempotent', () async {
    await _seedAccount(db, 'A', 6000);
    await _seedTxn(db, 't8', 'income', 1000, accountId: 'A');
    await _seedTxn(db, 't8b', 'expense', 400, accountId: 'A');

    final first = await LedgerBackfillService.run(db);
    final afterFirst = (await db.query('ledger_transactions')).length;

    final second = await LedgerBackfillService.run(db);
    final afterSecond = (await db.query('ledger_transactions')).length;

    expect(afterFirst, afterSecond);
    expect(second.ledgerEntriesCreated, 0);
    expect(second.openingBalancesCreated, 0);
    expect(first.verdict, 'PASS');
    expect(second.verdict, 'PASS');
  });

  test('9. account parity passes (opening absorbs movements)', () async {
    await _seedAccount(db, 'A', 1000);
    await _seedTxn(db, 'i1', 'income', 600, accountId: 'A');
    await _seedTxn(db, 'e1', 'expense', 200, accountId: 'A');

    final report = await LedgerBackfillService.run(db);
    expect(report.accountParity.first.passed, isTrue);
    expect(report.verdict, 'PASS');

    final openings = await db.query(
      'ledger_transactions',
      where: 'type = ? AND account_id = ?',
      whereArgs: ['opening_balance', 'A'],
    );
    expect((openings.first['amount'] as num).toDouble(), 600);
  });

  test('10. unresolved transaction type rolls back the migration', () async {
    await _seedAccount(db, 'A', 5000);
    await _seedTxn(db, 'bad', 'unknown_type', 999, accountId: 'A');

    expect(
      () => LedgerBackfillService.run(db),
      throwsA(isA<BackfillFailedException>()),
    );

    final rows = await db.query('ledger_transactions');
    expect(rows.length, 0);
  });

  test('11. lending backfill reconciles', () async {
    await db.insert('lendings', {
      'id': 'L1',
      'user_id': 'offline_user',
      'person_name': 'Bob',
      'type': 'lent',
      'original_amount': 2000.0,
      'paid_amount': 0.0,
      'date': DateTime(2025, 1, 1).toIso8601String(),
      'is_settled': 0,
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
      'updated_at': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.insert('lendings', {
      'id': 'L2',
      'user_id': 'offline_user',
      'person_name': 'Carol',
      'type': 'borrowed',
      'original_amount': 1500.0,
      'paid_amount': 0.0,
      'date': DateTime(2025, 1, 1).toIso8601String(),
      'is_settled': 0,
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
      'updated_at': DateTime(2025, 1, 1).toIso8601String(),
    });

    final report = await LedgerBackfillService.run(db);
    expect(report.lendingReconciled, 2);
    expect(report.lendingParity.every((p) => p.passed), isTrue);

    final lent = await db.query('ledger_transactions',
        where: 'reference_id = ?', whereArgs: ['L1']);
    expect(lent.first['type'], 'lending_given');
    final borrowed = await db.query('ledger_transactions',
        where: 'reference_id = ?', whereArgs: ['L2']);
    expect(borrowed.first['type'], 'lending_received');
  });

  test('12. credit historical reconciliation', () async {
    await db.insert('credit_cards', {
      'id': 'C1',
      'name': 'Card',
      'used_amount': 0.0,
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.insert('credit_transactions', {
      'id': 'CT1',
      'cardId': 'C1',
      'amount': 100.0,
      'date': DateTime(2025, 2, 1).toIso8601String(),
      'category': 'Food',
      'type': 'purchase',
      'status': 'posted',
    });
    await db.insert('credit_transactions', {
      'id': 'CT2',
      'cardId': 'C1',
      'amount': 40.0,
      'date': DateTime(2025, 3, 1).toIso8601String(),
      'category': 'Payment',
      'type': 'payment',
      'status': 'posted',
    });

    final report = await LedgerBackfillService.run(db);
    expect(report.creditReconciled, 2);
    expect(report.creditParity.first.passed, isTrue);
    expect(report.ledgerEntriesCreated, 2);
  });

  test('13 + 14. loan principal reconciliation (interest excluded)', () async {
    await db.insert('loans', {
      'id': 'LN1',
      'name': 'Car',
      'total': 120000.0,
      'loan_status': 'active',
      'start_date': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.insert('loan_installments', {
      'id': 'I1',
      'loanId': 'LN1',
      'dueDate': DateTime(2025, 2, 1).toIso8601String(),
      'amount': 60000.0,
      'principalComponent': 50000.0,
      'interestComponent': 10000.0,
      'status': 'paid',
      'paidDate': DateTime(2025, 2, 1).toIso8601String(),
    });
    await db.insert('loan_installments', {
      'id': 'I2',
      'loanId': 'LN1',
      'dueDate': DateTime(2025, 3, 1).toIso8601String(),
      'amount': 60000.0,
      'principalComponent': 50000.0,
      'interestComponent': 10000.0,
      'status': 'pending',
    });

    final report = await LedgerBackfillService.run(db);
    expect(report.loanReconciled, 1);
    final p = report.loanParity.first;
    // Remaining = total(120000) - paid principal(50000) = 70000.
    expect(p.expectedRemaining, 70000);
    expect(p.ledgerRemaining, 70000);
    expect(p.passed, isTrue);
  });

  test('15a. orphan ledger row fails the migration', () async {
    await _seedAccount(db, 'A', 5000);
    // Ledger row whose reference_id matches no known entity.
    await db.insert('ledger_transactions', {
      'id': 'orphan-1',
      'type': 'expense',
      'amount': 10.0,
      'date': DateTime(2025, 1, 1).toIso8601String(),
      'account_id': 'A',
      'reference_id': 'ghost-ref-xyz',
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
    });

    final report = await LedgerBackfillService.run(db).catchError(
      (e) => (e as BackfillFailedException).report,
    );
    expect(report.verdict, 'FAIL — ROLLED BACK');
    expect(report.orphanCount, greaterThanOrEqualTo(1));
  });

  test('15b. duplicate ledger representation fails the migration', () async {
    await _seedAccount(db, 'A', 5000);
    await _seedTxn(db, 'dup1', 'income', 100, accountId: 'A');
    // Two identical ledger rows for the same transaction reference.
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

    final report = await LedgerBackfillService.run(db).catchError(
      (e) => (e as BackfillFailedException).report,
    );
    expect(report.verdict, 'FAIL — ROLLED BACK');
    expect(report.duplicateCount, greaterThanOrEqualTo(1));
  });

  test('16. complete migration rollback on required mismatch', () async {
    await _seedAccount(db, 'A', 5000);
    await _seedTxn(db, 'ok', 'income', 1000, accountId: 'A');
    // An orphan row that would force a rollback; verify NOTHING persists.
    await db.insert('ledger_transactions', {
      'id': 'orphan-2',
      'type': 'expense',
      'amount': 5.0,
      'date': DateTime(2025, 1, 1).toIso8601String(),
      'account_id': 'A',
      'reference_id': 'ghost-ref-2',
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
    });

    await expectLater(
      LedgerBackfillService.run(db),
      throwsA(isA<BackfillFailedException>()),
    );

    // Both the would-be opening entry and the income leg must be gone.
    final rows = await db.query('ledger_transactions');
    expect(rows.length, 1); // only the manually seeded orphan remains
    expect(rows.first['id'], 'orphan-2');
  });
}

