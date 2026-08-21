// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/migrations/ledger_backfill_dry_run.dart';

Future<void> _seedAccount(Database db, String id, double balance) async {
  await db.insert('bank_accounts', {
    'id': id,
    'name': 'Account $id',
    'balance': balance,
    'is_asset': 1,
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

  test('Phase 1C dry-run on realistic data: non-mutating, classified report',
      () async {
    // --- realistic fixture (what a real SpendX DB might contain) ---
    await _seedAccount(db, 'A', 2000);
    await _seedAccount(db, 'B', 1000);
    // Legacy "opening balance" faked as an income row (no reference_id).
    await db.insert('ledger_transactions', {
      'id': 'legacy-open-A',
      'type': 'income',
      'amount': 1500.0,
      'date': DateTime(2024, 1, 1).toIso8601String(),
      'account_id': 'A',
      'created_at': DateTime(2024, 1, 1).toIso8601String(),
    });
    await _seedTxn(db, 'inc1', 'income', 800, accountId: 'A');
    await _seedTxn(db, 'exp1', 'expense', 300, accountId: 'A');
    await _seedTxn(db, 'tx1', 'expense', 50, accountId: 'A', categoryId: 'cat_food');
    await _seedTxn(db, 'tr1', 'transfer', 200,
        accountId: 'A', relatedEntityId: 'B');
    await _seedTxn(db, 'incB', 'income', 1000, accountId: 'B');

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

    await db.insert('loans', {
      'id': 'L1',
      'name': 'Car',
      'total': 120000.0,
      'loan_status': 'active',
      'start_date': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.insert('loan_installments', {
      'id': 'I1',
      'loanId': 'L1',
      'dueDate': DateTime(2025, 2, 1).toIso8601String(),
      'amount': 60000.0,
      'principalComponent': 50000.0,
      'interestComponent': 10000.0,
      'status': 'paid',
      'paidDate': DateTime(2025, 2, 1).toIso8601String(),
    });

    // Lending WITH a repayment -> must remain a VISIBLE EXCEPTION.
    await db.insert('lendings', {
      'id': 'LEND1',
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

    // --- dry-run must NOT mutate the database ---
    final before = (await db.query('ledger_transactions')).length;
    final report = await dryRun(db);
    final after = (await db.query('ledger_transactions')).length;
    expect(before, after, reason: 'dry-run must not persist any rows');

    // --- acceptance gate checks ---
    expect(report.accountParity.every((p) => p.passed), isTrue,
        reason: 'every account must reconcile');
    expect(report.creditParity.every((p) => p.passed), isTrue,
        reason: 'every card must reconcile');
    expect(report.loanParity.every((p) => p.passed), isTrue,
        reason: 'every loan must reconcile');
    expect(report.lendingReconciled, 1);
    expect(report.lendingParity.first.passed, isTrue);

    // The lending repayment is a known, deferred exception (not a hard fail).
    expect(report.hardFailures.isEmpty, isTrue);
    expect(report.exceptions.join('\n'), contains('repayment'));
    expect(report.openingBalancesCreated, greaterThan(0));
    expect(report.verdict, 'PASS WITH DOCUMENTED MIGRATION EXCEPTIONS');

    // Surface the full classified report for Phase 1C verification.
    print(const JsonEncoder.withIndent('  ').convert(report.toSummary()));
  });

  test('Phase 1C execute persists and preserves category_id', () async {
    await _seedAccount(db, 'A', 2000);
    await db.insert('ledger_transactions', {
      'id': 'legacy-open-A',
      'type': 'income',
      'amount': 1500.0,
      'date': DateTime(2024, 1, 1).toIso8601String(),
      'account_id': 'A',
      'created_at': DateTime(2024, 1, 1).toIso8601String(),
    });
    await _seedTxn(db, 'inc1', 'income', 800, accountId: 'A');
    await _seedTxn(db, 'exp1', 'expense', 300, accountId: 'A');
    await _seedTxn(db, 'catx', 'expense', 50, accountId: 'A', categoryId: 'cat_food');

    final report = await execute(db);
    expect(report.passed, isTrue);

    final rows = await db.query('ledger_transactions',
        where: 'reference_id = ?', whereArgs: ['catx']);
    expect(rows.length, 1);
    expect(rows.first['category_id'], 'cat_food');
  });

  test('Phase 1C dry-run surfaces a hard failure without mutating', () async {
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

    final before = (await db.query('ledger_transactions')).length;
    final report = await dryRun(db);
    final after = (await db.query('ledger_transactions')).length;

    expect(before, after, reason: 'dry-run must not persist');
    expect(report.verdict, 'FAIL — ROLLED BACK');
    expect(report.orphanCount, greaterThanOrEqualTo(1));
    expect(report.hardFailures.isNotEmpty, isTrue);
  });
}
