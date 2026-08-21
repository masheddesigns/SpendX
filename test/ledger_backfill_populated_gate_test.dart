// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/migrations/ledger_backfill_service.dart';

/// Phase 1C — populated, real-schema gate.
///
/// Builds a realistic, *messy* SpendX database (the kind the empty device DB
/// could not exercise): multiple accounts, income/expense/transfer, lendings
/// with repayments, credit-card purchases/payments/refunds, a loan with paid
/// principal + interest + a pending installment, plus salary/EMI/credit-EMI
/// data that the engine is designed to IGNORE. The ledger table is created at
/// the v19 shape (no `category_id`) so the v20 migration fix is also exercised.
///
/// It then runs the FULL five-output validation and asserts the risky paths
/// (salary/EMI/loan/lending/credit) are all handled without hard failures.
void main() {
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await openDatabase(inMemoryDatabasePath);
    await Tables.createAll(db);

    // Simulate a real exported v19 database: ledger_transactions has no
    // category_id column (the shape that exposed the migration crash bug).
    await db.execute('ALTER TABLE ledger_transactions RENAME TO _lt_old');
    await db.execute('''
      CREATE TABLE ledger_transactions (
        id TEXT PRIMARY KEY, user_id TEXT, amount REAL NOT NULL,
        type TEXT NOT NULL, date TEXT NOT NULL, note TEXT,
        account_id TEXT, credit_card_id TEXT, loan_id TEXT,
        reference_id TEXT, created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      INSERT INTO ledger_transactions
        (id, user_id, amount, type, date, note, account_id,
         credit_card_id, loan_id, reference_id, created_at)
      SELECT id, user_id, amount, type, date, note, account_id,
             credit_card_id, loan_id, reference_id, created_at
      FROM _lt_old
    ''');
    await db.execute('DROP TABLE _lt_old');
  });

  tearDown(() async => db.close());

  test('populated real-world gate: migration + backfill handles all risk paths',
      () async {
    // ---- categories ----
    for (final c in const [
      {'id': 'cat_salary', 'name': 'Salary', 'type': 'income'},
      {'id': 'cat_food', 'name': 'Food', 'type': 'expense'},
      {'id': 'cat_util', 'name': 'Utilities', 'type': 'expense'},
    ]) {
      await db.insert('categories', {...c, 'is_preset': 0});
    }

    // ---- bank accounts (assets) ----
    await db.insert('bank_accounts', {
      'id': 'A', 'name': 'Savings', 'balance': 12000.0, 'is_asset': 1,
      'created_at': DateTime(2024, 1, 1).toIso8601String(),
      'updated_at': DateTime(2024, 1, 1).toIso8601String(),
    });
    await db.insert('bank_accounts', {
      'id': 'B', 'name': 'Checking', 'balance': 8000.0, 'is_asset': 1,
      'created_at': DateTime(2024, 1, 1).toIso8601String(),
      'updated_at': DateTime(2024, 1, 1).toIso8601String(),
    });

    // ---- transactions (engine-handled types only) ----
    await db.insert('transactions', {
      'id': 't_inc', 'amount': 5000.0, 'type': 'income',
      'account_id': 'A', 'category_id': 'cat_salary',
      'date': DateTime(2025, 5, 1).toIso8601String(),
      'created_at': DateTime(2025, 5, 1).toIso8601String(),
      'updated_at': DateTime(2025, 5, 1).toIso8601String(),
    });
    await db.insert('transactions', {
      'id': 't_exp1', 'amount': 1500.0, 'type': 'expense',
      'account_id': 'A', 'category_id': 'cat_food',
      'date': DateTime(2025, 5, 2).toIso8601String(),
      'created_at': DateTime(2025, 5, 2).toIso8601String(),
      'updated_at': DateTime(2025, 5, 2).toIso8601String(),
    });
    await db.insert('transactions', {
      'id': 't_tr', 'amount': 2000.0, 'type': 'transfer',
      'account_id': 'A', 'related_entity_id': 'B',
      'date': DateTime(2025, 5, 3).toIso8601String(),
      'created_at': DateTime(2025, 5, 3).toIso8601String(),
      'updated_at': DateTime(2025, 5, 3).toIso8601String(),
    });
    await db.insert('transactions', {
      'id': 't_exp2', 'amount': 300.0, 'type': 'expense',
      'account_id': 'B', 'category_id': 'cat_util',
      'date': DateTime(2025, 5, 4).toIso8601String(),
      'created_at': DateTime(2025, 5, 4).toIso8601String(),
      'updated_at': DateTime(2025, 5, 4).toIso8601String(),
    });

    // ---- lendings (one with repayments -> documented exception) ----
    await db.insert('lendings', {
      'id': 'L1', 'user_id': 'offline_user', 'person_name': 'Bob',
      'type': 'lent', 'original_amount': 2000.0, 'paid_amount': 0.0,
      'date': DateTime(2025, 1, 1).toIso8601String(), 'is_settled': 0,
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
      'updated_at': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.insert('lendings', {
      'id': 'L2', 'user_id': 'offline_user', 'person_name': 'Carol',
      'type': 'borrowed', 'original_amount': 1500.0, 'paid_amount': 500.0,
      'date': DateTime(2025, 1, 1).toIso8601String(), 'is_settled': 0,
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
      'updated_at': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.insert('lendings', {
      'id': 'L3', 'user_id': 'offline_user', 'person_name': 'Dan',
      'type': 'lent', 'original_amount': 1000.0, 'paid_amount': 1000.0,
      'date': DateTime(2025, 1, 1).toIso8601String(), 'is_settled': 1,
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
      'updated_at': DateTime(2025, 1, 1).toIso8601String(),
    });

    // ---- credit card + transactions ----
    await db.insert('credit_cards', {
      'id': 'C1', 'name': 'Visa', 'credit_limit': 50000.0,
      'used_amount': 0.0,
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.insert('credit_transactions', {
      'id': 'CT1', 'cardId': 'C1', 'amount': 100.0,
      'date': DateTime(2025, 2, 1).toIso8601String(),
      'category': 'Food', 'type': 'purchase', 'status': 'posted',
      'categoryId': 'cat_food',
    });
    await db.insert('credit_transactions', {
      'id': 'CT2', 'cardId': 'C1', 'amount': 40.0,
      'date': DateTime(2025, 3, 1).toIso8601String(),
      'category': 'Payment', 'type': 'payment', 'status': 'posted',
    });
    await db.insert('credit_transactions', {
      'id': 'CT3', 'cardId': 'C1', 'amount': 10.0,
      'date': DateTime(2025, 3, 5).toIso8601String(),
      'category': 'Refund', 'type': 'refund', 'status': 'posted',
    });

    // ---- loan with paid principal + interest + pending installment ----
    await db.insert('loans', {
      'id': 'LN1', 'name': 'Car Loan', 'total': 120000.0,
      'loan_status': 'active', 'start_date': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.insert('loan_installments', {
      'id': 'I1', 'loanId': 'LN1', 'dueDate': DateTime(2025, 2, 1).toIso8601String(),
      'amount': 60000.0, 'principalComponent': 50000.0,
      'interestComponent': 10000.0, 'status': 'paid',
      'paidDate': DateTime(2025, 2, 1).toIso8601String(),
    });
    await db.insert('loan_installments', {
      'id': 'I2', 'loanId': 'LN1', 'dueDate': DateTime(2025, 3, 1).toIso8601String(),
      'amount': 60000.0, 'principalComponent': 50000.0,
      'interestComponent': 10000.0, 'status': 'pending',
    });

    // ---- salary / EMI / credit-EMI data: MUST be ignored by the engine ----
    await db.insert('salary', {
      'id': 'S1', 'company_name': 'Acme', 'salary_month': '2025-05',
      'expected_date': DateTime(2025, 5, 1).toIso8601String(),
      'net_salary': 5000.0, 'amount_received': 5000.0, 'account_id': 'A',
      'linked_transaction_id': 't_inc',
      'created_at': DateTime(2025, 5, 1).toIso8601String(),
    });
    await db.insert('salary', {
      'id': 'S2', 'company_name': 'Acme', 'salary_month': '2025-06',
      'expected_date': DateTime(2025, 6, 1).toIso8601String(),
      'net_salary': 5000.0, 'amount_received': 0.0, 'account_id': 'A',
      'created_at': DateTime(2025, 6, 1).toIso8601String(),
    });
    await db.insert('companies', {
      'id': 'Co1', 'name': 'Acme',
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.insert('salary_contracts', {
      'id': 'K1', 'company_id': 'Co1', 'base_salary': 5000.0,
      'start_date': DateTime(2025, 1, 1).toIso8601String(),
      'default_account_id': 'A',
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.insert('salary_payments', {
      'id': 'SP1', 'contract_id': 'K1', 'month': '2025-05',
      'expected_date': DateTime(2025, 5, 1).toIso8601String(),
      'total_amount': 5000.0, 'account_id': 'A',
      'created_at': DateTime(2025, 5, 1).toIso8601String(),
    });
    await db.insert('credit_emis', {
      'id': 'CE1', 'cardId': 'C1', 'transactionId': 'CT1',
      'principalAmount': 100.0, 'interestRate': 18.0,
      'interestAmount': 5.0, 'processingFee': 0.0, 'tenureMonths': 3,
      'monthlyInstallment': 35.0,
      'startDate': DateTime(2025, 2, 1).toIso8601String(),
      'paidMonths': 1, 'remainingMonths': 2,
      'createdAt': DateTime(2025, 2, 1).toIso8601String(),
    });
    await db.insert('emi_installments', {
      'id': 'EI1', 'emiId': 'E1',
      'dueDate': DateTime(2025, 2, 1).toIso8601String(),
      'amount': 100.0, 'status': 'paid',
    });

    // ---- recurring template: must be ignored ----
    await db.insert('recurring_templates', {
      'id': 'RT1', 'name': 'Rent', 'amount': 2000.0, 'type': 'expense',
      'frequency': 'monthly', 'created_at': DateTime(2025, 1, 1).toIso8601String(),
    });

    // (1) + (2) before migration/backfill: tables + core counts.
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    )).map((r) => r['name']).toList();
    final coreCounts = <String, int>{};
    for (final t in const [
      'bank_accounts', 'transactions', 'credit_transactions', 'loans',
      'loan_installments', 'lendings', 'ledger_transactions', 'salary',
      'salary_payments', 'credit_emis', 'emi_installments', 'recurring_templates',
    ]) {
      coreCounts[t] = (await db.query(t)).length;
    }

    // Bring schema to current (exercises the v20 category_id fix on the
    // column-less v19 ledger_transactions).
    await AppDatabase.instance.migrateSchemaOnly(db, 19);

    // Seed a PRE-EXISTING legacy ledger row (proves idempotent skip path).
    await db.insert('ledger_transactions', {
      'id': 'legacy-exp2', 'type': 'expense', 'amount': 300.0,
      'date': DateTime(2025, 4, 1).toIso8601String(),
      'account_id': 'B', 'category_id': 'cat_util',
      'reference_id': 't_exp2',
      'created_at': DateTime(2025, 4, 1).toIso8601String(),
    });

    // (3) run the backfill (commit, in-memory).
    final report = await LedgerBackfillService.run(db);

    // (4) + (5) ledger distribution + detail.
    final distribution = await db.rawQuery(
      'SELECT type, COUNT(*) AS n FROM ledger_transactions GROUP BY type ORDER BY type',
    );
    final details = await db.query(
      'ledger_transactions',
      columns: ['type', 'account_id', 'credit_card_id', 'loan_id', 'reference_id', 'amount'],
      orderBy: 'type, reference_id',
    );

    // ---- print the five outputs ----
    print('=== (1) table count: ${tables.length} ===');
    print('=== (2) core counts ===');
    print(const JsonEncoder.withIndent('  ').convert(coreCounts));
    print('=== (3) BackfillReport ===');
    print(const JsonEncoder.withIndent('  ').convert(report.toSummary()));
    print('=== (4) ledger type distribution ===');
    print(const JsonEncoder.withIndent('  ').convert(distribution));
    print('=== (5) ledger movement/reference detail ===');
    print(const JsonEncoder.withIndent('  ').convert(details));

    // ---- assertions: risky paths all handled, zero hard failures ----
    expect(report.hardFailures, isEmpty,
        reason: 'No hard failures on a populated, messy DB.');
    expect(report.accountsExamined, 2);
    expect(report.accountsMigrated, 2);
    expect(report.openingBalancesCreated, 2);
    expect(report.lendingReconciled, 3);
    expect(report.creditReconciled, 3);
    expect(report.loanReconciled, 1);
    expect(report.loanParity.first.passed, isTrue,
        reason: 'Loan principal (interest excluded) reconciles.');
    expect(report.accountParity.every((p) => p.passed), isTrue,
        reason: 'Every account parity passes.');
    expect(report.existingLedgerSkipped, 1,
        reason: 'Pre-existing ledger row is not duplicated.');
    expect(report.ledgerEntriesCreated, greaterThanOrEqualTo(12));
    // The two lendings with repayments must surface as DOCUMENTED exceptions,
    // not hard failures, and salary/EMI must never appear in failures.
    expect(report.exceptions.where((e) => e.contains('repayments')).length, 2);
    expect(
      report.hardFailures.any((f) => f.toLowerCase().contains('salary')) ||
          report.hardFailures.any((f) => f.toLowerCase().contains('emi')),
      isFalse,
      reason: 'Salary/EMI data is safely ignored, never a hard failure.',
    );
    expect(
      report.verdict == 'PASS' ||
          report.verdict == 'EXECUTABLE_WITH_EXCEPTIONS',
      isTrue,
    );
  });
}
