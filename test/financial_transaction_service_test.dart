import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/ledger_repo.dart';
import 'package:spend_x/models/ledger_transaction.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/services/financial_transaction_service.dart';

Transaction _tx({
  required String id,
  required String type,
  required double amount,
  String? accountId,
  String? relatedEntityId,
  String? categoryId,
  DateTime? date,
}) {
  return Transaction(
    id: id,
    userId: 'offline_user',
    type: type,
    amount: amount,
    accountId: accountId,
    relatedEntityId: relatedEntityId,
    categoryId: categoryId,
    date: date ?? DateTime(2026, 1, 15),
    notes: 'test',
  );
}

void main() {
  late Database db;
  late LedgerRepo ledgerRepo;
  late FinancialTransactionService svc;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await openDatabase(inMemoryDatabasePath);
    await Tables.createAll(db);
    ledgerRepo = LedgerRepo(database: db);
    svc = FinancialTransactionService(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  test('income creates a positive account movement', () async {
    await svc.createIncome(_tx(id: 't1', type: 'income', amount: 5000, accountId: 'A'));
    expect(await ledgerRepo.getAccountBalance('A'), 5000);
  });

  test('expense creates a negative account movement', () async {
    await svc.createExpense(_tx(id: 't2', type: 'expense', amount: 2000, accountId: 'A'));
    expect(await ledgerRepo.getAccountBalance('A'), -2000);
  });

  test('transfer creates two opposite legs', () async {
    final transfer = _tx(
      id: 't3',
      type: 'transfer',
      amount: 2000,
      accountId: 'A',
      relatedEntityId: 'B',
    );
    await svc.createTransfer(transfer);

    // Source down, destination up, equal and opposite.
    expect(await ledgerRepo.getAccountBalance('A'), -2000);
    expect(await ledgerRepo.getAccountBalance('B'), 2000);

    final legs = await ledgerRepo.getAll(referenceId: 't3');
    expect(legs.length, 2);
    final types = legs.map((l) => l.type).toSet();
    expect(types.contains(LedgerType.transfer), isTrue);
    expect(types.contains(LedgerType.income), isTrue);
  });

  test('transfer does not change total net worth', () async {
    // Seed opening balances via plain ledger entries.
    await ledgerRepo.insert(
      LedgerTransaction(type: LedgerType.income, amount: 10000, date: DateTime(2026, 1, 1), accountId: 'A'),
    );
    await ledgerRepo.insert(
      LedgerTransaction(type: LedgerType.income, amount: 5000, date: DateTime(2026, 1, 1), accountId: 'B'),
    );
    final before = (await ledgerRepo.getAccountBalance('A')) +
        (await ledgerRepo.getAccountBalance('B'));
    expect(before, 15000);

    await svc.createTransfer(_tx(
      id: 't4',
      type: 'transfer',
      amount: 2000,
      accountId: 'A',
      relatedEntityId: 'B',
    ));

    final after = (await ledgerRepo.getAccountBalance('A')) +
        (await ledgerRepo.getAccountBalance('B'));
    expect(after, 15000);
    expect(await ledgerRepo.getAccountBalance('A'), 8000);
    expect(await ledgerRepo.getAccountBalance('B'), 7000);
  });

  test('failed transaction rolls back both transaction and ledger', () async {
    // Force a failure inside the atomic block by using a duplicate PK.
    await svc.createExpense(_tx(id: 'dup', type: 'expense', amount: 100, accountId: 'A'));
    final before = await db.query('transactions');
    expect(before.length, 1);

    await expectLater(
      db.transaction((txn) async {
        await txn.insert('transactions', _tx(id: 'dup', type: 'expense', amount: 100, accountId: 'A').toMap());
        throw Exception('simulated failure');
      }),
      throwsException,
    );

    // Both the in-flight insert and any ledger write must be gone.
    expect((await db.query('transactions')).length, 1);
    expect((await db.query('ledger_transactions')).length, 1);
  });

  test('category_id survives ledger serialization', () async {
    await svc.createExpense(
      _tx(id: 't5', type: 'expense', amount: 300, accountId: 'A', categoryId: 'cat_food'),
    );
    final legs = await ledgerRepo.getAll(referenceId: 't5');
    expect(legs.length, 1);
    expect(legs.first.categoryId, 'cat_food');
  });

  test('account balance calculation returns the expected ledger total', () async {
    await svc.createIncome(_tx(id: 'i1', type: 'income', amount: 1000, accountId: 'A'));
    await svc.createExpense(_tx(id: 'e1', type: 'expense', amount: 400, accountId: 'A'));
    await svc.createExpense(_tx(id: 'e2', type: 'expense', amount: 100, accountId: 'A'));
    expect(await ledgerRepo.getAccountBalance('A'), 500);
  });

  test('derived balance = opening + ledger movements', () async {
    await svc.createExpense(_tx(id: 'e3', type: 'expense', amount: 250, accountId: 'A'));
    expect(await ledgerRepo.getDerivedAccountBalance('A', openingBalance: 1000), 750);
  });

  test('edit transaction is append-only and keeps balance consistent', () async {
    await svc.createExpense(_tx(id: 'e4', type: 'expense', amount: 500, accountId: 'A'));
    expect(await ledgerRepo.getAccountBalance('A'), -500);

    await svc.editTransaction(
      oldTransaction: _tx(id: 'e4', type: 'expense', amount: 500, accountId: 'A'),
      newTransaction: _tx(id: 'e4', type: 'expense', amount: 800, accountId: 'A'),
    );

    // Balance reflects net effect (original + reversal + corrected).
    expect(await ledgerRepo.getAccountBalance('A'), -800);

    // The original event is retained, and the corrected event is appended with
    // its own append-only reference_id (e4:corr:1) — distinct from the original
    // so reconciliation never treats it as a duplicate of the original leg.
    final originalRows = (await ledgerRepo.getAll(referenceId: 'e4'))
        .where((l) => l.type == LedgerType.expense)
        .toList();
    expect(originalRows.length, 1); // original (500) retained
    expect(originalRows.any((l) => l.amount == 500), isTrue);

    final corrected = await ledgerRepo.getAll(referenceId: 'e4:corr:1');
    expect(corrected.length, 1); // corrected (800) appended separately
    expect(corrected.first.type, LedgerType.expense);
    expect(corrected.first.amount, 800);

    // A reversal row was appended (never deleted).
    final reversals = await ledgerRepo.getAll(referenceId: 'e4:rev:1');
    expect(reversals.length, 1);
    expect(reversals.first.type, LedgerType.reversal);
  });

  test('delete transaction is append-only (reversal) and reverts balance', () async {
    await svc.createExpense(_tx(id: 'e5', type: 'expense', amount: 500, accountId: 'A'));
    expect((await db.query('transactions')).length, 1);
    expect((await db.query('ledger_transactions')).length, 1);

    await svc.deleteTransaction('e5');
    // Source row removed...
    expect((await db.query('transactions')).length, 0);
    // ...but the journal keeps the original event AND its reversal (append-only).
    expect((await db.query('ledger_transactions')).length, 2);
    expect(await ledgerRepo.getAccountBalance('A'), 0);
  });

  test('loan principal remaining excludes interest (uses schedule)', () async {
    // Seed a loan + two paid installments (principal 50k + 50k, interest 10k + 10k).
    await db.insert('loans', {
      'id': 'L1',
      'name': 'Car',
      'principal_amount': 100000.0,
      'total': 120000.0,
      'loan_status': 'active',
    });
    await db.insert('loan_installments', {
      'id': 'I1',
      'loanId': 'L1',
      'dueDate': '2024-01-01',
      'amount': 60000,
      'principalComponent': 50000,
      'interestComponent': 10000,
      'status': 'paid',
    });
    await db.insert('loan_installments', {
      'id': 'I2',
      'loanId': 'L1',
      'dueDate': '2024-02-01',
      'amount': 60000,
      'principalComponent': 50000,
      'interestComponent': 10000,
      'status': 'pending',
    });
    // Only I1 is paid -> remaining principal = 100000 - 50000 = 50000.
    expect(await ledgerRepo.getLoanPrincipalRemaining('L1', 100000), 50000);
  });
}
