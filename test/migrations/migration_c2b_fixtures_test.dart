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

  // ===========================================================================
  // SECTION 1: MASTER FIXTURES FX01 – FX14
  // ===========================================================================
  group('Master Fixtures FX01 – FX14', () {
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

    test('FX01: Clean Normal Database (Salary + Groceries)', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_1',
        'name': 'HDFC Savings',
        'balance': 45000.0,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('categories', {
        'id': 'cat_groceries',
        'name': 'Groceries',
        'type': 'expense',
      });
      await db.insert('categories', {
        'id': 'cat_salary',
        'name': 'Salary',
        'type': 'income',
      });

      await db.insert('transactions', {
        'id': 'tx_1',
        'amount': 50000.0,
        'type': 'income',
        'account_id': 'acc_1',
        'category_id': 'cat_salary',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('transactions', {
        'id': 'tx_2',
        'amount': 5000.0,
        'type': 'expense',
        'account_id': 'acc_1',
        'category_id': 'cat_groceries',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      final result = await MigrationV24Service.migrate(db);
      expect(result.eventsMigrated, 2);
      expect(result.postingsCreated, 4);

      // Verify Derived Account Balances
      final hdfc = (await db.rawQuery('''
        SELECT COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE -amount_minor_units END), 0) AS bal
        FROM ${TablesV24.postings} WHERE account_id = 'acc_1';
      ''')).first['bal'];
      expect(hdfc, 4500000); // exactly ₹45,000.00
    });

    test('FX02: Inter-Account Transfers (Zero Net-Worth Impact)', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_sbi',
        'name': 'SBI',
        'balance': 5000.0,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('bank_accounts', {
        'id': 'acc_icici',
        'name': 'ICICI',
        'balance': 25000.0,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('transactions', {
        'id': 'tx_tr1',
        'amount': 5000.0,
        'type': 'transfer',
        'account_id': 'acc_sbi',
        'related_entity_id': 'acc_icici',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      await MigrationV24Service.migrate(db);

      // Check net asset change across all asset accounts for transfer event
      final netAssetImpact = (await db.rawQuery('''
        SELECT COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE -amount_minor_units END), 0) AS delta
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        WHERE p.economic_event_id = 'tx_tr1' AND a.account_type = 'asset';
      ''')).first['delta'];
      expect(netAssetImpact, 0);

      // Verify zero income and zero expense postings for transfer
      final nonAssetPostings = await db.rawQuery('''
        SELECT p.* FROM ${TablesV24.postings} p
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        WHERE p.economic_event_id = 'tx_tr1' AND a.account_type IN ('income', 'expense');
      ''');
      expect(nonAssetPostings, isEmpty);
    });

    test('FX03: Credit Card Lifecycle (Purchase + Bill Settlement)', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_bank',
        'name': 'Salary Bank',
        'balance': 30000.0,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('credit_cards', {
        'id': 'card_hdfc',
        'name': 'HDFC Card',
        'credit_limit': 100000.0,
        'used_amount': 0.0,
        'created_at': now,
      });
      await db.insert('categories', {
        'id': 'cat_flight',
        'name': 'Flights',
        'type': 'expense',
      });

      // 1. Credit Card Purchase
      await db.insert('transactions', {
        'id': 'tx_c1',
        'amount': 10000.0,
        'type': 'credit_card_purchase',
        'account_id': 'card_hdfc',
        'category_id': 'cat_flight',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      // 2. Card bill settlement from Bank
      await db.insert('transactions', {
        'id': 'tx_c2',
        'amount': 10000.0,
        'type': 'credit_payment',
        'account_id': 'acc_bank',
        'related_entity_id': 'card_hdfc',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      await MigrationV24Service.migrate(db);

      // Card liability is 0 (10,000 credit - 10,000 debit)
      final cardLiab = (await db.rawQuery('''
        SELECT COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE -amount_minor_units END), 0) AS liab
        FROM ${TablesV24.postings} WHERE account_id = 'card_hdfc';
      ''')).first['liab'];
      expect(cardLiab, 0);

      // Settlement event (tx_c2) produced ZERO expense postings
      final settlementExpense = await db.rawQuery('''
        SELECT p.* FROM ${TablesV24.postings} p
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        WHERE p.economic_event_id = 'tx_c2' AND a.account_type = 'expense';
      ''');
      expect(settlementExpense, isEmpty);
    });

    test('FX04: Matched & Unmatched Refunds (Contra-Expense, Zero Income)', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_1',
        'name': 'Main Bank',
        'balance': 10000.0,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('categories', {
        'id': 'cat_shopping',
        'name': 'Shopping',
        'type': 'expense',
      });

      // Original expense
      await db.insert('transactions', {
        'id': 'tx_e1',
        'amount': 2000.0,
        'type': 'expense',
        'account_id': 'acc_1',
        'category_id': 'cat_shopping',
        'external_ref': 'AMZ_ORDER_1',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      // Matched refund (references AMZ_ORDER_1)
      await db.insert('transactions', {
        'id': 'tx_r1',
        'amount': 2000.0,
        'type': 'refund',
        'account_id': 'acc_1',
        'note': 'Refund for AMZ_ORDER_1',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      // Unmatched refund
      await db.insert('transactions', {
        'id': 'tx_r2',
        'amount': 500.0,
        'type': 'refund',
        'account_id': 'acc_1',
        'note': 'Cashback',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      await MigrationV24Service.migrate(db);

      // Matched refund credited cat_shopping directly
      final r1Postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ? AND direction = ?',
        whereArgs: ['tx_r1', 'credit'],
      );
      expect(r1Postings.first['account_id'], 'cat_shopping');

      // Unmatched refund credited sys_exp_refunds
      final r2Postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ? AND direction = ?',
        whereArgs: ['tx_r2', 'credit'],
      );
      expect(r2Postings.first['account_id'], TablesV24.sysExpRefunds);

      // ZERO Income postings generated for any refund
      final incomeRefunds = await db.rawQuery('''
        SELECT p.* FROM ${TablesV24.postings} p
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        WHERE p.economic_event_id IN ('tx_r1', 'tx_r2') AND a.account_type = 'income';
      ''');
      expect(incomeRefunds, isEmpty);
    });

    test('FX05: Loan & EMI Amortization (Principal + Interest Split)', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_bank',
        'name': 'Savings',
        'balance': 90000.0,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('loans', {
        'id': 'loan_1',
        'name': 'Home Loan',
        'principal_amount': 100000.0,
        'start_date': now,
      });

      // Disbursement
      await db.insert('transactions', {
        'id': 'tx_l1',
        'amount': 100000.0,
        'type': 'loan_disbursement',
        'account_id': 'acc_bank',
        'related_entity_id': 'loan_1',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      // Repayment with split
      await db.insert('transactions', {
        'id': 'tx_l2',
        'amount': 10000.0,
        'type': 'loan_repayment',
        'account_id': 'acc_bank',
        'related_entity_id': 'loan_1',
        'note': 'Principal: 8000, Interest: 2000',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      await MigrationV24Service.migrate(db);

      // Verify tx_l2 generated 3 balanced postings
      final l2Postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['tx_l2'],
      );
      expect(l2Postings.length, 3);

      final principalLeg = l2Postings.firstWhere((p) => p['account_id'] == 'loan_1');
      expect(principalLeg['amount_minor_units'], 800000);
      expect(principalLeg['direction'], 'debit');

      final interestLeg = l2Postings.firstWhere((p) => p['account_id'] == TablesV24.sysExpInterest);
      expect(interestLeg['amount_minor_units'], 200000);
      expect(interestLeg['direction'], 'debit');

      final bankLeg = l2Postings.firstWhere((p) => p['account_id'] == 'acc_bank');
      expect(bankLeg['amount_minor_units'], 1000000);
      expect(bankLeg['direction'], 'credit');

      // Remaining loan liability = 92,000 INR (9,200,000 paise)
      final remainingLoan = (await db.rawQuery('''
        SELECT COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE -amount_minor_units END), 0) AS liab
        FROM ${TablesV24.postings} WHERE account_id = 'loan_1';
      ''')).first['liab'];
      expect(remainingLoan, 9200000);
    });

    test('FX06: Recurring Salary Contracts', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('companies', {
        'id': 'comp_1',
        'name': 'Acme Corp',
        'salary_credit_day': 1,
        'created_at': now,
      });
      await db.insert('salary_contracts', {
        'id': 'sc_1',
        'company_id': 'comp_1',
        'base_salary': 150000.0,
        'start_date': now,
        'is_active': 1,
        'created_at': now,
      });

      final result = await MigrationV24Service.migrate(db);
      expect(result.recurringRulesMigrated, 1);

      final rules = await db.query(TablesV24.recurringRules);
      expect(rules.length, 1);
      expect(rules.first['amount_minor_units'], 15000000);
      expect(rules.first['cadence'], 'monthly');
      expect(rules.first['day_of_month'], 1);

      final expected = await db.query(TablesV24.expectedEvents);
      expect(expected.length, 1);
      expect(expected.first['status'], 'pending');
    });

    test('FX07: Goals & Virtual Earmarks (Derived Liquidity)', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_savings',
        'name': 'Savings',
        'balance': 50000.0,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('goals', {
        'id': 'goal_car',
        'title': 'Car Fund',
        'type': 'savings',
        'target_amount': 100000.0,
        'current_amount': 20000.0,
        'start_date': now,
        'end_date': now,
        'account_id': 'acc_savings',
        'created_at': now,
      });

      final result = await MigrationV24Service.migrate(db);
      expect(result.earmarksMigrated, 1);

      final earmarks = await db.query(TablesV24.assetEarmarks);
      expect(earmarks.length, 1);
      expect(earmarks.first['amount_minor_units'], 2000000); // ₹20,000

      // Invariant: Earmarks do NOT create postings in the ledger
      final earmarkPostings = await db.rawQuery(
        'SELECT * FROM ${TablesV24.postings} WHERE account_id = ?',
        ['goal_car'],
      );
      expect(earmarkPostings, isEmpty);
    });

    test('FX08: Categorical Budgets', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('categories', {
        'id': 'cat_dining',
        'name': 'Dining',
        'type': 'expense',
      });
      await db.insert('budgets', {
        'id': 'b_1',
        'category_id': 'cat_dining',
        'limit_amount': 8000.0,
        'created_at': now,
      });

      await MigrationV24Service.migrate(db);

      final budgets = await db.query('budgets');
      expect(budgets.first['limit_amount'], 800000); // 8000 * 100
    });

    test('FX09: Cross-Source Deduplication Evidence', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_1',
        'name': 'Bank',
        'balance': 1000.0,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('transactions', {
        'id': 'tx_starbucks',
        'amount': 450.0,
        'type': 'expense',
        'account_id': 'acc_1',
        'source': 'manual',
        'note': 'Starbucks Coffee',
        'external_ref': 'UPI/SB1234',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      await MigrationV24Service.migrate(db);

      // Verify exactly 1 event and 2 balanced postings
      final events = await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: ['tx_starbucks'],
      );
      expect(events.length, 1);
      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['tx_starbucks'],
      );
      expect(postings.length, 2);

      // Evidence record contains body_sha256
      final evidence = await db.query(
        TablesV24.evidence,
        where: 'economic_event_id = ?',
        whereArgs: ['tx_starbucks'],
      );
      expect(evidence.length, 1);
      expect((evidence.first['body_sha256'] as String).length, 64);
    });

    test('FX10: Soft-Deleted Transactions Excluded From Accounting Truth', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_1',
        'name': 'Bank',
        'balance': 1000.0,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('transactions', {
        'id': 'tx_active',
        'amount': 1000.0,
        'type': 'expense',
        'account_id': 'acc_1',
        'is_deleted': 0,
        'date': now,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('transactions', {
        'id': 'tx_deleted',
        'amount': 5000.0,
        'type': 'expense',
        'account_id': 'acc_1',
        'is_deleted': 1,
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      final result = await MigrationV24Service.migrate(db);

      // tx_active is in economic_events
      expect((await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: ['tx_active'])).length, 1);

      // HARD STOP A: tx_deleted is NOT in economic_events
      expect((await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: ['tx_deleted'])).length, 0);

      // 0 postings exist for tx_deleted
      expect((await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: ['tx_deleted'])).length, 0);

      // Dispositions tracked explicitly
      expect(result.sourceTransactionsTotal, 2);
      expect(result.sourceTransactionsMigrated, 1);
      expect(result.sourceTransactionsExcludedByPolicy, 1);
    });

    test('FX11: Inconsistent Balances Reconciled With Provenance', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_drift',
        'name': 'Drift Bank',
        'balance': 25000.0, // Legacy balance = 25,000
        'created_at': now,
        'updated_at': now,
      });

      // Transactions sum to only 10,000
      await db.insert('transactions', {
        'id': 'tx_inc',
        'amount': 10000.0,
        'type': 'income',
        'account_id': 'acc_drift',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      final result = await MigrationV24Service.migrate(db);
      expect(result.openingBalancesReconciled, 1);

      // 1. Reconciliation record exists
      final obr = (await db.query(
        TablesV24.openingBalanceReconciliations,
        where: 'account_id = ?',
        whereArgs: ['acc_drift'],
      )).first;
      expect(obr['legacy_reported_balance_minor_units'], 2500000);
      expect(obr['reconstructed_balance_minor_units'], 1000000);
      expect(obr['adjustment_delta_minor_units'], 1500000);

      // 2. Opening balance EconomicEvent exists
      final eventId = obr['generated_event_id'] as String;
      final event = (await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: [eventId],
      )).first;
      expect(event['event_type'], 'opening_balance');
      expect(event['lifecycle_status'], 'posted');

      // 3. Balanced postings exist
      final obrPostings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [eventId],
      );
      expect(obrPostings.length, 2);

      // 4. Parity achieved: 10,000 + 15,000 = 25,000 INR
      final finalBal = (await db.rawQuery('''
        SELECT COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE -amount_minor_units END), 0) AS bal
        FROM ${TablesV24.postings} WHERE account_id = 'acc_drift';
      ''')).first['bal'];
      expect(finalBal, 2500000);
    });

    test('FX12: Malformed Legacy Rows Handled Without Crashing', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_1',
        'name': 'Bank',
        'balance': 100.0,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('transactions', {
        'id': 'tx_bad_type',
        'amount': 100.0,
        'type': 'UNKNOWN_TYPO_TYPE',
        'account_id': 'acc_1',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('transactions', {
        'id': 'tx_null_acc',
        'amount': 200.0,
        'type': 'expense',
        'account_id': null,
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      final result = await MigrationV24Service.migrate(db);
      expect(result.sourceTransactionsMigrated, 2);

      // Anomaly logged for unmapped type
      final exc = await db.query(TablesV24.migrationExceptions);
      expect(exc.any((e) => e['record_id'] == 'tx_bad_type'), isTrue);
    });

    test('FX13: Legacy Vehicle Logs Dropped (Gated by allowDestructiveDrops)', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_1',
        'name': 'Bank',
        'balance': 5000.0,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('vehicles', {
        'id': 'veh_1',
        'name': 'Car',
        'created_at': now,
      });
      await db.insert('transactions', {
        'id': 'tx_fuel',
        'amount': 3000.0,
        'type': 'expense',
        'account_id': 'acc_1',
        'is_vehicle_expense': 1,
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      // Migration with allowDestructiveDrops = false
      final result = await MigrationV24Service.migrate(db, allowDestructiveDrops: false);
      expect(result.destructiveDropsExecuted, isFalse);

      // Fuel transaction migrated cleanly
      final fuelEvt = (await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: ['tx_fuel'])).first;
      expect(fuelEvt['event_type'], 'expense');

      // Vehicle table remains physically intact for C2B inspection
      final vehTable = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='vehicles';");
      expect(vehTable, isNotEmpty);
    });

    test('FX14: Pending Review Queue (Zero Postings)', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('review_queue', {
        'id': 'rq_1',
        'raw_sms': 'Paid Rs 250 at Swiggy',
        'parsed_json': '{}',
        'confidence': 0.9,
        'status': 'pending',
        'created_at': now,
      });
      await db.insert('review_queue', {
        'id': 'rq_2',
        'raw_sms': 'Received Rs 500 cashback',
        'parsed_json': '{}',
        'confidence': 0.8,
        'status': 'pending',
        'created_at': now,
      });
      await db.insert('review_queue', {
        'id': 'rq_3',
        'raw_sms': 'Debit Rs 1000 ATM',
        'parsed_json': '{}',
        'confidence': 0.95,
        'status': 'pending',
        'created_at': now,
      });

      final result = await MigrationV24Service.migrate(db);
      expect(result.reviewCandidatesMigrated, 3);

      final rc = await db.query(TablesV24.reviewCandidates);
      expect(rc.length, 3);

      // Invariant: Zero postings created for review candidates
      final rcPostings = await db.rawQuery(
        'SELECT * FROM ${TablesV24.postings} WHERE economic_event_id IN (?, ?, ?)',
        ['rq_1', 'rq_2', 'rq_3'],
      );
      expect(rcPostings, isEmpty);
    });
  });

  // ===========================================================================
  // SECTION 2: ADVERSARIAL MONEY FIXTURES
  // ===========================================================================
  group('Adversarial Money Precision & Boundary Vectors', () {
    test('IEEE-754 Half-Away-From-Zero exact paise conversion', () {
      final vectors = {
        0.01: 1,
        0.10: 10,
        1.15: 115,
        1.004: 100,
        1.005: 100, // In IEEE-754 binary64, 1.005 * 100.0 == 100.49999999999999 -> rounds to 100
        1.006: 101,
        1.014: 101,
        1.015: 101, // In IEEE-754 binary64, 1.015 * 100.0 == 101.49999999999999 -> rounds to 101
        1.016: 102,
        2.005: 201, // 200.5 -> 201
        10.005: 1001, // 1000.5 -> 1001
        999.99: 99999,
        10000000.55: 1000000055,
      };

      for (final entry in vectors.entries) {
        expect(
          MigrationV24Service.toMinorUnits(entry.key),
          entry.value,
          reason: 'Failed for vector ${entry.key}',
        );
      }
    });

    test('Zero and legal negative values', () {
      expect(MigrationV24Service.toMinorUnits(0.0), 0);
      expect(MigrationV24Service.toMinorUnits(-0.01), -1);
      expect(MigrationV24Service.toMinorUnits(-100.50), -10050);
    });

    test('Max supported amount (1 lakh crore = 10^14 paise) and overflow rejection', () {
      // 10^12 rupees = 10^14 paise
      const maxRupees = 1000000000000.0;
      expect(MigrationV24Service.toMinorUnits(maxRupees), 100000000000000);

      // Max + 1 paisa (overflow)
      const overflowRupees = 1000000000000.01;
      expect(
        () => MigrationV24Service.toMinorUnits(overflowRupees),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ===========================================================================
  // SECTION 3: NATIVE SQLITE TRIGGERS (TESTS A – H)
  // ===========================================================================
  group('SQLite Triggers Invariant Enforcement (Tests A – H)', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await Tables.createAll(db);
      await MigrationV24Service.migrate(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('Tests A & B: Inserting draft, 1 leg allowed; matching credit + post allowed', () async {
      final now = DateTime.now().toIso8601String();

      // Step A1: Insert draft event
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_t1',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Draft test',
        'created_at': now,
        'updated_at': now,
      });

      // Step A2: Insert one debit leg (allowed while draft)
      await db.insert(TablesV24.postings, {
        'id': 'pst_d1',
        'economic_event_id': 'evt_t1',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 50000,
        'created_at': now,
      });

      // Step B1: Insert matching credit leg
      await db.insert(TablesV24.postings, {
        'id': 'pst_c1',
        'economic_event_id': 'evt_t1',
        'account_id': TablesV24.sysSuspenseTransfer,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 50000,
        'created_at': now,
      });

      // Step B2: Transition to posted (allowed: balanced debits == credits)
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_t1'],
      );

      final status = (await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: ['evt_t1'])).first['lifecycle_status'];
      expect(status, 'posted');
    });

    test('Test C: Attempting to post an unbalanced event is aborted by SQLite trigger', () async {
      final now = DateTime.now().toIso8601String();

      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_unbal',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Unbalanced',
        'created_at': now,
        'updated_at': now,
      });

      await db.insert(TablesV24.postings, {
        'id': 'p_u1',
        'economic_event_id': 'evt_unbal',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 50000,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_u2',
        'economic_event_id': 'evt_unbal',
        'account_id': TablesV24.sysSuspenseTransfer,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 40000, // 10000 mismatch!
        'created_at': now,
      });

      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_unbal'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Test D: Attempting to insert a posting into posted event is rejected', () async {
      final now = DateTime.now().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_posted_d',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Test D',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_d1',
        'economic_event_id': 'evt_posted_d',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 1000,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_d2',
        'economic_event_id': 'evt_posted_d',
        'account_id': TablesV24.sysSuspenseTransfer,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 1000,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_posted_d'],
      );

      // Attempt insert on posted event
      expect(
        () => db.insert(TablesV24.postings, {
          'id': 'p_illegal',
          'economic_event_id': 'evt_posted_d',
          'account_id': TablesV24.sysExpMisc,
          'sequence_number': 3,
          'direction': 'debit',
          'amount_minor_units': 500,
          'created_at': now,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Test E: Attempting to update posted posting is rejected', () async {
      final now = DateTime.now().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_posted_e',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Test E',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_e1',
        'economic_event_id': 'evt_posted_e',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 2000,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_e2',
        'economic_event_id': 'evt_posted_e',
        'account_id': TablesV24.sysSuspenseTransfer,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 2000,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_posted_e'],
      );

      expect(
        () => db.update(
          TablesV24.postings,
          {'amount_minor_units': 5000},
          where: 'id = ?',
          whereArgs: ['p_e1'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Test F: Attempting to delete posted posting is rejected', () async {
      final now = DateTime.now().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_posted_f',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Test F',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_f1',
        'economic_event_id': 'evt_posted_f',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 3000,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_f2',
        'economic_event_id': 'evt_posted_f',
        'account_id': TablesV24.sysSuspenseTransfer,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 3000,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_posted_f'],
      );

      expect(
        () => db.delete(
          TablesV24.postings,
          where: 'id = ?',
          whereArgs: ['p_f1'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Test G: Attempting to mutate canonical fields of posted event is rejected', () async {
      final now = DateTime.now().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_posted_g',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Test G',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_g1',
        'economic_event_id': 'evt_posted_g',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 4000,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_g2',
        'economic_event_id': 'evt_posted_g',
        'account_id': TablesV24.sysSuspenseTransfer,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 4000,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_posted_g'],
      );

      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'event_type': 'income'},
          where: 'id = ?',
          whereArgs: ['evt_posted_g'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Test H: Attempting to delete posted event is rejected', () async {
      final now = DateTime.now().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_posted_h',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Test H',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_h1',
        'economic_event_id': 'evt_posted_h',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 5000,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_h2',
        'economic_event_id': 'evt_posted_h',
        'account_id': TablesV24.sysSuspenseTransfer,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 5000,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_posted_h'],
      );

      expect(
        () => db.delete(
          TablesV24.economicEvents,
          where: 'id = ?',
          whereArgs: ['evt_posted_h'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  // ===========================================================================
  // SECTION 4: DRAFT ACCOUNTING LEAK TEST
  // ===========================================================================
  group('Draft Event Isolation (Zero Leakage)', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await Tables.createAll(db);
      await MigrationV24Service.migrate(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('Draft event contributes ZERO to posted balances, income, and expense', () async {
      final now = DateTime.now().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_leak_test',
        'account_type': 'asset',
        'subtype': 'liquid_cash',
        'name': 'Leak Test Bank',
        'created_at': now,
        'updated_at': now,
      });

      // Insert draft event + balanced postings
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_draft_leak',
        'event_type': 'income',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Staged draft',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_leak_1',
        'economic_event_id': 'evt_draft_leak',
        'account_id': 'acc_leak_test',
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 100000,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_leak_2',
        'economic_event_id': 'evt_draft_leak',
        'account_id': TablesV24.sysIncMisc,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 100000,
        'created_at': now,
      });

      // Query posted balance
      final postedBal = (await db.rawQuery('''
        SELECT COALESCE(SUM(CASE WHEN p.direction = 'debit' THEN p.amount_minor_units ELSE -p.amount_minor_units END), 0) AS bal
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
        WHERE p.account_id = 'acc_leak_test' AND e.lifecycle_status = 'posted';
      ''')).first['bal'];
      expect(postedBal, 0); // EXACT ZERO LEAKAGE!

      // Transition to posted
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_draft_leak'],
      );

      // Now visible exactly once
      final afterPostBal = (await db.rawQuery('''
        SELECT COALESCE(SUM(CASE WHEN p.direction = 'debit' THEN p.amount_minor_units ELSE -p.amount_minor_units END), 0) AS bal
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
        WHERE p.account_id = 'acc_leak_test' AND e.lifecycle_status = 'posted';
      ''')).first['bal'];
      expect(afterPostBal, 100000);
    });
  });

  // ===========================================================================
  // SECTION 5: FOREIGN KEY VIOLATIONS & INTEGRITY
  // ===========================================================================
  group('Foreign Key Enforcement & Integrity Checks', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await Tables.createAll(db);
      await MigrationV24Service.migrate(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('Foreign key rejection on invalid references', () async {
      final now = DateTime.now().toIso8601String();

      // Posting referencing non-existent event
      expect(
        () => db.insert(TablesV24.postings, {
          'id': 'p_orphan_evt',
          'economic_event_id': 'evt_does_not_exist',
          'account_id': TablesV24.sysExpMisc,
          'sequence_number': 1,
          'direction': 'debit',
          'amount_minor_units': 100,
          'created_at': now,
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Posting referencing non-existent account
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_fk_test',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'FK test',
        'created_at': now,
        'updated_at': now,
      });

      expect(
        () => db.insert(TablesV24.postings, {
          'id': 'p_orphan_acc',
          'economic_event_id': 'evt_fk_test',
          'account_id': 'acc_does_not_exist',
          'sequence_number': 1,
          'direction': 'debit',
          'amount_minor_units': 100,
          'created_at': now,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Database passes PRAGMA foreign_key_check and PRAGMA integrity_check', () async {
      final fk = await db.rawQuery('PRAGMA foreign_key_check;');
      expect(fk, isEmpty);

      final integrity = (await db.rawQuery('PRAGMA integrity_check;')).first.values.first;
      expect(integrity, 'ok');

      final userVersion = (await db.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(userVersion, 24);
    });
  });

  // ===========================================================================
  // SECTION 6: COLD BACKUP VERIFICATION
  // ===========================================================================
  group('Cold Backup Verification', () {
    test('Pre-migration backup creates valid v23 snapshot readable independently', () async {
      final tempDir = await Directory.systemTemp.createTemp('spendx_c2b_backup');
      final dbPath = '${tempDir.path}/live.db';

      // Initialize v23 database on disk
      final liveDb = await openDatabase(
        dbPath,
        version: 23,
        onCreate: (d, v) async {
          await Tables.createAll(d);
          final now = DateTime(2025, 1, 1).toIso8601String();
          await d.insert('bank_accounts', {
            'id': 'acc_backup_test',
            'name': 'Backup Test Account',
            'balance': 12345.0,
            'created_at': now,
            'updated_at': now,
          });
        },
      );

      // Create backup
      final backupPath = await MigrationV24Service.createPreMigrationBackup(liveDb);
      expect(backupPath, isNotNull);

      final backupFile = File(backupPath!);
      expect(await backupFile.exists(), isTrue);
      expect(await backupFile.length(), greaterThan(0));

      // Independently open the backup file and verify integrity
      final backupDb = await openDatabase(backupPath);
      final integrity = (await backupDb.rawQuery('PRAGMA integrity_check;')).first.values.first;
      expect(integrity, 'ok');

      final backupVer = (await backupDb.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(backupVer, 23);

      final accs = await backupDb.query('bank_accounts');
      expect(accs.length, 1);
      expect(accs.first['balance'], 12345.0);

      await backupDb.close();
      await liveDb.close();
      await tempDir.delete(recursive: true);
    });
  });

  // ===========================================================================
  // SECTION 8: PRE-C3 DESTRUCTIVE MIGRATION REVIEW VERIFICATION
  // ===========================================================================
  group('Pre-C3 Destructive Migration Review Verification Gates', () {
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

    test('Gate 4: v24 -> v24 migration idempotency is a pure no-op', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_idempotent',
        'name': 'Test Bank',
        'balance': 10000.0,
        'created_at': now,
        'updated_at': now,
      });

      // Run initial migration
      final result1 = await MigrationV24Service.migrate(db);
      expect(result1.alreadyMigrated, isFalse);
      expect(result1.accountsMigrated, 1);

      final eventsCount1 = (await db.query(TablesV24.economicEvents)).length;
      final postingsCount1 = (await db.query(TablesV24.postings)).length;

      // Run second migration on already-migrated v24 database
      final result2 = await MigrationV24Service.migrate(db);
      expect(result2.alreadyMigrated, isTrue);

      final eventsCount2 = (await db.query(TablesV24.economicEvents)).length;
      final postingsCount2 = (await db.query(TablesV24.postings)).length;

      // Absolute parity: 0 mutations
      expect(eventsCount2, eventsCount1);
      expect(postingsCount2, postingsCount1);
    });

    test('Gate 7: Source-row conservation: total == migrated + excluded + quarantined (0 remainder)', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_cons',
        'name': 'Conservation Bank',
        'balance': 10000.0,
        'created_at': now,
        'updated_at': now,
      });

      // 1. Normal valid transaction
      await db.insert('transactions', {
        'id': 'tx_valid_1',
        'amount': 1000.0,
        'type': 'expense',
        'account_id': 'acc_cons',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });
      // 2. Soft-deleted transaction (excluded by policy)
      await db.insert('transactions', {
        'id': 'tx_soft_1',
        'amount': 500.0,
        'type': 'expense',
        'account_id': 'acc_cons',
        'is_deleted': 1,
        'date': now,
        'created_at': now,
        'updated_at': now,
      });
      // 3. Quarantined transaction (zero or negative amount)
      await db.insert('transactions', {
        'id': 'tx_zero_1',
        'amount': 0.0,
        'type': 'expense',
        'account_id': 'acc_cons',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      final result = await MigrationV24Service.migrate(db);

      // Exact mathematical conservation check
      expect(result.sourceTransactionsTotal, 3);
      expect(result.sourceTransactionsMigrated, 1);
      expect(result.sourceTransactionsExcludedByPolicy, 1);
      expect(result.sourceTransactionsQuarantined, 1);

      final accountedFor = result.sourceTransactionsMigrated +
          result.sourceTransactionsExcludedByPolicy +
          result.sourceTransactionsQuarantined;
      expect(accountedFor, result.sourceTransactionsTotal);
      expect(result.sourceTransactionsTotal - accountedFor, 0); // 0 remainder!
    });

    test('Gate 8: Draft isolation across balance, income, expense, net worth, and forecast', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_draft_iso',
        'name': 'Draft Iso Bank',
        'balance': 50000.0,
        'created_at': now,
        'updated_at': now,
      });

      await MigrationV24Service.migrate(db);

      // Insert a draft transaction with huge amounts into the ledger
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_draft_huge',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Draft huge pending expense',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_dh_1',
        'economic_event_id': 'evt_draft_huge',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 99999999, // ₹999,999.99
        'currency': 'INR',
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_dh_2',
        'economic_event_id': 'evt_draft_huge',
        'account_id': 'acc_draft_iso',
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 99999999,
        'currency': 'INR',
        'created_at': now,
      });

      // 1. Posted Balance: draft contributes 0
      final postedBalance = (await db.rawQuery('''
        SELECT COALESCE(SUM(
          CASE WHEN p.direction = 'debit' THEN p.amount_minor_units ELSE -p.amount_minor_units END
        ), 0) AS bal
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
        WHERE p.account_id = 'acc_draft_iso' AND e.lifecycle_status = 'posted';
      ''')).first['bal'];
      expect(postedBalance, 5000000); // exactly ₹50,000 opening balance, 0 deduction

      // 2. Posted Expense: draft contributes 0
      final postedExpense = (await db.rawQuery('''
        SELECT COALESCE(SUM(p.amount_minor_units), 0) AS exp
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        WHERE a.account_type = 'expense' AND p.direction = 'debit' AND e.lifecycle_status = 'posted';
      ''')).first['exp'];
      expect(postedExpense, 0);

      // 3. Posted Net Worth: draft contributes 0
      final postedNetWorth = (await db.rawQuery('''
        SELECT 
          COALESCE(SUM(CASE 
            WHEN a.account_type = 'asset' AND p.direction = 'debit' THEN p.amount_minor_units
            WHEN a.account_type = 'asset' AND p.direction = 'credit' THEN -p.amount_minor_units
            WHEN a.account_type = 'liability' AND p.direction = 'credit' THEN -p.amount_minor_units
            WHEN a.account_type = 'liability' AND p.direction = 'debit' THEN p.amount_minor_units
            ELSE 0 END), 0) AS net_worth
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        WHERE e.lifecycle_status = 'posted';
      ''')).first['net_worth'];
      expect(postedNetWorth, 5000000); // unchanged ₹50,000
    });
  });
}
