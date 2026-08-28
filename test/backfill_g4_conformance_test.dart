import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/migrations/ledger_backfill_service.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/services/financial_transaction_service.dart';

Transaction _tx({
  required String id,
  required String type,
  required double amount,
  String? accountId,
}) =>
    Transaction(
      id: id,
      userId: 'offline_user',
      type: type,
      amount: amount,
      accountId: accountId,
      date: DateTime(2026, 1, 15),
      notes: 'test',
    );

void main() {
  late Database db;
  late FinancialTransactionService svc;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await openDatabase(inMemoryDatabasePath);
    await Tables.createAll(db);
    await db.insert(Tables.bankAccounts, {
      'id': 'A',
      'user_id': 'offline_user',
      'name': 'A',
      'balance': 1000.0,
      'created_at': DateTime(2026).toIso8601String(),
      'updated_at': DateTime(2026).toIso8601String(),
    });
    svc = FinancialTransactionService(database: db);
  });

  tearDown(() async => db.close());

  Future<int> _ledgerCount() async =>
      (await db.query(Tables.ledgerTransactions)).length;

  test('G4: backfill reconciles a post-G1-G3 journal (edit+delete emit reversal/correction)',
      () async {
    await svc.createTransaction(_tx(id: 't1', type: 'income', amount: 100, accountId: 'A'));
    await svc.editTransaction(
      oldTransaction: _tx(id: 't1', type: 'income', amount: 100, accountId: 'A'),
      newTransaction: _tx(id: 't1', type: 'income', amount: 150, accountId: 'A'),
    );
    await svc.createTransaction(_tx(id: 't2', type: 'expense', amount: 50, accountId: 'A'));
    await svc.deleteTransaction('t2');

    // Stored: 1000 +100 create, then edit delta +50 (original leg retained),
    // then -50 create, then delete delta +50 => 1150.
    final stored = (await db.query(Tables.bankAccounts,
            columns: ['balance'], where: 'id = ?', whereArgs: ['A']))
        .first['balance'] as double;
    expect(stored, 1150.0);

    final report = await LedgerBackfillService.reconcile(db, authorized: true);

    expect(report.applied, isTrue);
    expect(report.hardFailures, isEmpty,
        reason: 'G4 gap would hard-fail on reversal/correction rows');
    expect(report.accountParity, isNotEmpty);
    for (final p in report.accountParity) {
      expect(p.diff, lessThanOrEqualTo(LedgerBackfillService.tolerance));
    }

    // Idempotent: a second run adds no rows and still passes.
    final afterFirst = await _ledgerCount();
    final report2 = await LedgerBackfillService.reconcile(db, authorized: true);
    expect(report2.hardFailures, isEmpty);
    expect(await _ledgerCount(), afterFirst);
  });

  test('G4: backfill still FAILS on a genuine orphan (guard intact)', () async {
    await svc.createTransaction(_tx(id: 't1', type: 'income', amount: 100, accountId: 'A'));
    // A ledger row whose reference_id matches no known entity and is not part
    // of any reversal/correction trail must still be flagged as an orphan.
    await db.insert(Tables.ledgerTransactions, {
      'type': 'expense',
      'amount': 10.0,
      'date': DateTime(2026, 1, 1).toIso8601String(),
      'account_id': 'A',
      'reference_id': 'ghost-tx',
      'created_at': DateTime(2026, 1, 1).toIso8601String(),
    });

    final report = await LedgerBackfillService.reconcile(db, authorized: true);

    // A genuine orphan blocks execution (rolled back, not applied).
    expect(report.applied, isFalse);
    expect(report.hardFailures, isNotEmpty);
    expect(report.hardFailures.any((f) => f.contains('Orphan')), isTrue);
  });
}
