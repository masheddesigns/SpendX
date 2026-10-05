import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/ledger_repo.dart';
import 'package:spend_x/models/ledger_transaction.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/services/financial_transaction_service.dart';

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

    // Seed test bank account with initial balance 5000.0
    await db.insert(Tables.bankAccounts, {
      'id': 'acc_main',
      'user_id': 'offline_user',
      'name': 'Main Checking',
      'balance': 5000.0,
      'created_at': DateTime(2026, 1, 1).toIso8601String(),
      'updated_at': DateTime(2026, 1, 1).toIso8601String(),
    });

    // Seed Transport & Fuel categories
    await db.insert(Tables.categories, {
      'id': 'cat_transport',
      'name': 'Transport',
      'type': 'expense',
      'icon': 'directions_car',
      'color': '#4CAF50',
    });

    await db.insert(Tables.categories, {
      'id': 'cat_fuel',
      'name': 'Fuel',
      'type': 'expense',
      'icon': 'local_gas_station',
      'color': '#FF9800',
    });

    ledgerRepo = LedgerRepo(database: db);
    svc = FinancialTransactionService(database: db);
  });

  tearDown(() async => db.close());

  Future<double> getAccountBalance(String id) async {
    final rows = await db.query(
      Tables.bankAccounts,
      columns: ['balance'],
      where: 'id = ?',
      whereArgs: [id],
    );
    return (rows.first['balance'] as num).toDouble();
  }

  test('ordinary Fuel expense creates and journals cleanly without vehicle entity', () async {
    // Create an ordinary fuel expense (₹2,500.00 for petrol fill-up)
    final fuelExpense = Transaction(
      id: 'tx_fuel_001',
      userId: 'offline_user',
      type: 'expense',
      categoryId: 'cat_fuel',
      accountId: 'acc_main',
      amount: 2500.0,
      date: DateTime(2026, 3, 15, 10, 30),
      notes: 'Shell petrol station fill-up',
      tags: ['fuel', 'transport'],
    );

    // 1. Commit mutation through FinancialTransactionService
    await svc.createExpense(fuelExpense);

    // 2. Verify transaction record exists in transactions table
    final rows = await db.query(
      Tables.transactions,
      where: 'id = ?',
      whereArgs: ['tx_fuel_001'],
    );
    expect(rows.length, 1);
    final stored = Transaction.fromMap(rows.first);
    expect(stored.amount, 2500.0);
    expect(stored.categoryId, 'cat_fuel');
    expect(stored.notes, 'Shell petrol station fill-up');
    expect(stored.tags, contains('fuel'));

    // 3. Verify ledger entry created with mathematical integrity
    final ledgerEntries = await db.query(
      Tables.ledgerTransactions,
      where: 'reference_id = ?',
      whereArgs: ['tx_fuel_001'],
    );
    expect(ledgerEntries.length, 1);
    expect((ledgerEntries.first['amount'] as num).toDouble(), 2500.0);
    expect(ledgerEntries.first['type'], LedgerType.expense.name);
    expect(ledgerEntries.first['account_id'], 'acc_main');

    // 4. Verify account balance reflects the expense
    final remainingBalance = await getAccountBalance('acc_main');
    expect(remainingBalance, 2500.0); // 5000 - 2500

    // 5. Verify ledger-derived balance matches delta
    final ledgerBalance = await ledgerRepo.getAccountBalance('acc_main');
    expect(ledgerBalance, -2500.0); // Starting from zero ledger transactions, delta is -2500
  });

  test('ordinary Transport expense with fuel keywords creates and journals correctly', () async {
    final transportExpense = Transaction(
      id: 'tx_transport_002',
      userId: 'offline_user',
      type: 'expense',
      categoryId: 'cat_transport',
      accountId: 'acc_main',
      amount: 850.0,
      date: DateTime(2026, 3, 20),
      notes: 'Highway toll and fuel top-up',
    );

    await svc.createExpense(transportExpense);

    final rows = await db.query(
      Tables.transactions,
      where: 'id = ?',
      whereArgs: ['tx_transport_002'],
    );
    expect(rows.length, 1);
    final stored = Transaction.fromMap(rows.first);
    expect(stored.amount, 850.0);
    expect(stored.categoryId, 'cat_transport');

    final balance = await getAccountBalance('acc_main');
    expect(balance, 4150.0); // 5000 - 850
  });
}
