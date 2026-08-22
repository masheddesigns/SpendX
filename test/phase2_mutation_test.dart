import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/ledger_repo.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/ledger_transaction.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/services/financial_transaction_service.dart';

Transaction _tx({
  required String id,
  required String type,
  required double amount,
  String? accountId,
  String? relatedEntityId,
  DateTime? date,
}) {
  return Transaction(
    id: id,
    userId: 'offline_user',
    type: type,
    amount: amount,
    accountId: accountId,
    relatedEntityId: relatedEntityId,
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
    await db.insert(Tables.bankAccounts, {
      'id': 'A',
      'user_id': 'offline_user',
      'name': 'A',
      'balance': 0.0,
      'created_at': DateTime(2026).toIso8601String(),
      'updated_at': DateTime(2026).toIso8601String(),
    });
    ledgerRepo = LedgerRepo(database: db);
    svc = FinancialTransactionService(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<double> _bankBalance() async {
    final r = await db.query(
      Tables.bankAccounts,
      columns: ['balance'],
      where: 'id = ?',
      whereArgs: ['A'],
    );
    return (r.first['balance'] as num).toDouble();
  }

  test('G3: source + ledger + balance commit atomically', () async {
    await svc.createExpense(_tx(id: 'x1', type: 'expense', amount: 200, accountId: 'A'));
    // Materialized balance equals the ledger-derived balance (account fully
    // journaled within this test).
    expect(await _bankBalance(), -200);
    expect(await ledgerRepo.getAccountBalance('A'), -200);
  });

  test('G3: duplicate PK rolls back source AND ledger (no partial write)', () async {
    await svc.createExpense(_tx(id: 'dup', type: 'expense', amount: 100, accountId: 'A'));
    expect((await db.query('transactions')).length, 1);
    expect((await db.query('ledger_transactions')).length, 1);

    // Second create with same id must fail and leave nothing behind.
    await expectLater(
      svc.createExpense(_tx(id: 'dup', type: 'expense', amount: 50, accountId: 'A')),
      throwsA(isA<DatabaseException>()),
    );

    expect((await db.query('transactions')).length, 1);
    expect((await db.query('ledger_transactions')).length, 1);
    expect(await _bankBalance(), -100);
  });

  test('G3: balance parity holds across mixed income/expense/transfer', () async {
    await svc.createIncome(_tx(id: 'i1', type: 'income', amount: 1000, accountId: 'A'));
    await svc.createExpense(_tx(id: 'e1', type: 'expense', amount: 300, accountId: 'A'));
    await svc.createExpense(_tx(id: 'e2', type: 'expense', amount: 150, accountId: 'A'));
    expect(await _bankBalance(), 550);
    expect(await ledgerRepo.getAccountBalance('A'), 550);
  });

  test('G3: edit keeps bank balance == ledger-derived (append-only)', () async {
    await svc.createExpense(_tx(id: 'e3', type: 'expense', amount: 400, accountId: 'A'));
    await svc.editTransaction(
      oldTransaction: _tx(id: 'e3', type: 'expense', amount: 400, accountId: 'A'),
      newTransaction: _tx(id: 'e3', type: 'expense', amount: 700, accountId: 'A'),
    );
    expect(await _bankBalance(), -700);
    expect(await ledgerRepo.getAccountBalance('A'), -700);
  });

  test('G3: ledger is the source of truth; cache is delta-maintained', () async {
    await svc.createIncome(_tx(id: 'i2', type: 'income', amount: 500, accountId: 'A'));
    expect(await _bankBalance(), 500);
    // Corrupt the cache out-of-band (simulating a legacy bug). The journal is
    // unaffected, so the canonical ledger-derived balance stays correct.
    await db.rawUpdate(
      'UPDATE ${Tables.bankAccounts} SET balance = 999 WHERE id = ?',
      ['A'],
    );
    // The next mutation applies its verified delta to the (corrupted) cache,
    // so the cache moves by exactly the journal delta. Self-healing the cache
    // to the full ledger derivation requires a complete backfill (G4), which
    // is intentionally deferred; the invariant the service enforces is that
    // each mutation's cache delta equals its journal delta.
    await svc.createExpense(_tx(id: 'e4', type: 'expense', amount: 100, accountId: 'A'));
    expect(await ledgerRepo.getAccountBalance('A'), 400); // ledger correct
    expect(await _bankBalance(), 899); // 999 - 100 (delta applied)
    // Cache delta equals the journal event delta:
    expect((await _bankBalance()) - 999, -100);
  });

  test('G3: concurrent mutations serialize and preserve the invariant', () async {
    final futures = <Future<void>>[];
    for (var i = 0; i < 20; i++) {
      futures.add(
        svc.createExpense(
          _tx(id: 'c$i', type: 'expense', amount: 10, accountId: 'A'),
        ),
      );
    }
    await Future.wait(futures);
    expect(await _bankBalance(), -200);
    expect(await ledgerRepo.getAccountBalance('A'), -200);
  });

  test('G2: credit side-effect journals purchase + adjusts card outstanding', () async {
    await db.insert(Tables.creditCards, {
      'id': 'C1',
      'user_id': 'offline_user',
      'name': 'C1',
      'used_amount': 0.0,
      'created_at': DateTime(2026).toIso8601String(),
    });
    final creditTxn = CreditTransaction(
      id: 'ct1',
      cardId: 'C1',
      amount: 1200,
      date: DateTime(2026, 1, 15),
      category: 'shopping',
      type: 'purchase',
      status: 'active',
    );
    final tx = _tx(id: 'p1', type: 'expense', amount: 1200, accountId: 'A')
        .copyWith(source: 'credit_card_purchase', relatedEntityId: 'C1');
    await svc.createTransaction(tx, creditTxn: creditTxn);

    // Bank balance untouched for a card purchase...
    expect(await _bankBalance(), 0);
    // ...but the card outstanding and the credit ledger are updated.
    expect(await ledgerRepo.getCreditOutstanding('C1'), 1200);
    final card = (await db.query(Tables.creditCards, where: 'id = ?', whereArgs: ['C1'])).first;
    expect((card['used_amount'] as num).toDouble(), 1200);
  });

  test('G2: loan payment side-effect reduces loan paid_amount', () async {
    await db.insert(Tables.loans, {
      'id': 'L1',
      'name': 'L1',
      'principal_amount': 100000.0,
      'total': 100000.0,
      'paid_amount': 0.0,
      'loan_status': 'active',
    });
    final tx = _tx(id: 'lp1', type: 'expense', amount: 5000, accountId: 'A');
    await svc.createTransaction(tx, loanId: 'L1', loanPaidDelta: 5000);

    final loan = (await db.query(Tables.loans, where: 'id = ?', whereArgs: ['L1'])).first;
    expect((loan['paid_amount'] as num).toDouble(), 5000);
    expect(await _bankBalance(), -5000);
  });

  test('G1: fuel_expense and refund journal correctly', () async {
    await svc.createTransaction(
      _tx(id: 'f1', type: 'fuel_expense', amount: 300, accountId: 'A'),
    );
    await svc.createTransaction(
      _tx(id: 'r1', type: 'refund', amount: 80, accountId: 'A'),
    );
    expect(await _bankBalance(), -220); // -300 + 80
    expect(await ledgerRepo.getAccountBalance('A'), -220);
  });

  test('G1: credit/loan bank-side legs update balance via appendLedger', () async {
    // Mirror CreditCardService.processPayment / LoanService.recordInstallmentPayment:
    // they journal a card/loan-side leg (no account) AND a bank-side expense leg.
    // Historically the bank-side leg was journaled but never applied to the
    // materialized balance. Routing through appendLedger fixes that.
    const pay = 250.0;
    await svc.appendLedger(LedgerTransaction(
      type: LedgerType.credit_payment,
      amount: pay,
      date: DateTime(2026, 1, 15),
      creditCardId: 'C1',
      referenceId: 'p1',
    ));
    await svc.appendLedger(LedgerTransaction(
      type: LedgerType.expense,
      amount: pay,
      date: DateTime(2026, 1, 15),
      accountId: 'A',
      referenceId: 'p1',
    ));

    expect(await _bankBalance(), -pay);
    expect(await ledgerRepo.getAccountBalance('A'), -pay);

    // Loan EMI payment side-effect (bank-side expense)
    const emi = 1200.0;
    await svc.appendLedger(LedgerTransaction(
      type: LedgerType.loan_payment,
      amount: emi,
      date: DateTime(2026, 1, 16),
      loanId: 'L1',
      referenceId: 'e1',
    ));
    await svc.appendLedger(LedgerTransaction(
      type: LedgerType.expense,
      amount: emi,
      date: DateTime(2026, 1, 16),
      accountId: 'A',
      referenceId: 'e1',
    ));

    expect(await _bankBalance(), -(pay + emi));
    expect(await ledgerRepo.getAccountBalance('A'), -(pay + emi));
  });
}
