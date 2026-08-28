import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/ledger_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/reminder_repo.dart';
import 'package:spend_x/domain/credit/credit_card_service.dart';
import 'package:spend_x/domain/loans/loan_service.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/loan_installment.dart';
import 'package:spend_x/services/financial_transaction_service.dart';

void main() {
  late Database db;
  late LedgerRepo ledgerRepo;

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
    ledgerRepo = LedgerRepo(database: db);
  });

  tearDown(() async => db.close());

  Future<double> _bankBalance() async {
    final r = await db.query(
      Tables.bankAccounts,
      columns: ['balance'],
      where: 'id = ?',
      whereArgs: ['A'],
    );
    return (r.first['balance'] as num).toDouble();
  }

  test('INTEGRATION: CreditCardService.processPayment moves bank balance', () async {
    await db.insert(Tables.creditCards, {
      'id': 'C1',
      'user_id': 'offline_user',
      'name': 'C1',
      'used_amount': 0.0,
      'created_at': DateTime(2026).toIso8601String(),
    });

    final svc = CreditCardService(
      creditRepo: CreditRepo(database: db),
      ledgerRepo: ledgerRepo,
      reminderRepo: ReminderRepo(database: db),
      financialService: FinancialTransactionService(database: db),
    );

    await svc.processPayment(
      cardId: 'C1',
      paymentAmount: 250,
      date: DateTime(2026, 2, 1),
      accountId: 'A',
    );

    // The bank-side expense leg must now reduce the materialized balance.
    expect(await _bankBalance(), 750.0);
    expect(await ledgerRepo.getAccountBalance('A'), -250.0);

    // Credit outstanding must have dropped by the payment.
    expect(await ledgerRepo.getCreditOutstanding('C1'), -250.0);
  });

  test('INTEGRATION: LoanService.recordInstallmentPayment moves bank balance', () async {
    final loanRepo = LoanRepo(database: db);
    await loanRepo.insertLoan(Loan(
      id: 'L1',
      name: 'L1',
      bank: 'Bank',
      total: 100000,
      interestRate: 10,
      tenureMonths: 12,
      monthlyInstallment: 5000,
      startDate: DateTime(2026, 1, 1),
      paidAmount: 0,
      loanStatus: 'active',
      dueDay: 5,
    ));
    await loanRepo.insertInstallment(LoanInstallment(
      id: 'inst000001',
      loanId: 'L1',
      dueDate: DateTime(2026, 2, 1),
      amount: 5000,
      principalComponent: 4200,
      interestComponent: 800,
      status: 'pending',
    ));

    final svc = LoanService(
      loanRepo: loanRepo,
      ledgerRepo: ledgerRepo,
      reminderRepo: ReminderRepo(database: db),
      financialService: FinancialTransactionService(database: db),
    );

    await svc.recordInstallmentPayment('inst000001', accountId: 'A');

    // The bank-side expense leg must reduce the materialized balance.
    expect(await _bankBalance(), -4000.0);
    expect(await ledgerRepo.getAccountBalance('A'), -5000.0);

    // Loan paid_amount must reflect the principal component.
    final loan = (await db.query(Tables.loans, where: 'id = ?', whereArgs: ['L1'])).first;
    expect((loan['paid_amount'] as num).toDouble(), 4200.0);
  });
}
