import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/migrations/migration_v24_service.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_opening_balance_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('C2B Full Fixture Parity Audit Suite (FX01–FX14)', () {
    late Database db;
    late CanonicalFinancialQueryRepository queryRepo;
    late CanonicalAccountRepository accountRepo;
    late CanonicalEventRepository eventRepo;
    late CanonicalEarmarkRepository earmarkRepo;
    late CanonicalOpeningBalanceRepository obrRepo;
    late CanonicalReviewRepository reviewRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await Tables.createAll(db);

      queryRepo = CanonicalFinancialQueryRepository(executor: db);
      accountRepo = CanonicalAccountRepository(executor: db);
      eventRepo = CanonicalEventRepository(executor: db);
      earmarkRepo = CanonicalEarmarkRepository(executor: db);
      obrRepo = CanonicalOpeningBalanceRepository(executor: db);
      reviewRepo = CanonicalReviewRepository(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // FX01: Clean Normal Database (Salary + Groceries)
    // -------------------------------------------------------------------------
    test('FX01: Clean Normal Database Parity', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_1',
        'name': 'HDFC Savings',
        'balance': 45000.0,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('categories', {
        'id': 'cat_groc',
        'name': 'Groceries',
        'type': 'expense',
      });
      await db.insert('categories', {
        'id': 'cat_sal',
        'name': 'Salary',
        'type': 'income',
      });

      await db.insert('transactions', {
        'id': 'tx_1',
        'amount': 50000.0,
        'type': 'income',
        'account_id': 'acc_1',
        'category_id': 'cat_sal',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('transactions', {
        'id': 'tx_2',
        'amount': 5000.0,
        'type': 'expense',
        'account_id': 'acc_1',
        'category_id': 'cat_groc',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      await MigrationV24Service.migrate(db);

      // Raw SQLite Parity vs Canonical Repositories
      expect((await accountRepo.getDerivedBalance('acc_1')).minorUnits, 4500000);
      expect((await queryRepo.getTotalAssets()).minorUnits, 4500000);
      expect((await queryRepo.getTotalLiabilities()).minorUnits, 0);
      expect((await queryRepo.getTotalIncome()).minorUnits, 5000000);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 500000);
      expect((await queryRepo.getNetWorth()).minorUnits, 4500000);
      expect((await queryRepo.getCashFlow()).minorUnits, 4500000);

      final postedEvents = await eventRepo.listPostedEvents();
      expect(postedEvents.length, 2);
      final totalPostings = (await db.rawQuery('SELECT COUNT(*) AS c FROM ${TablesV24.postings};')).first['c'] as int;
      expect(totalPostings, 4);
    });

    // -------------------------------------------------------------------------
    // FX02: Inter-Account Transfers
    // -------------------------------------------------------------------------
    test('FX02: Inter-Account Transfers Parity', () async {
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

      expect((await accountRepo.getDerivedBalance('acc_sbi')).minorUnits, 500000);
      expect((await accountRepo.getDerivedBalance('acc_icici')).minorUnits, 2500000);
      expect((await queryRepo.getTotalAssets()).minorUnits, 3000000);
      expect((await queryRepo.getTotalLiabilities()).minorUnits, 0);
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 0);
      expect((await queryRepo.getNetWorth()).minorUnits, 3000000);
      expect((await queryRepo.getCashFlow()).minorUnits, 0); // Transfer generates ₹0 net liquid cash flow
    });

    // -------------------------------------------------------------------------
    // FX03: Credit Card Lifecycle
    // -------------------------------------------------------------------------
    test('FX03: Credit Card Lifecycle Parity', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_bank',
        'name': 'Salary Bank',
        'balance': 50000.0,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('credit_cards', {
        'id': 'card_hdfc',
        'name': 'HDFC Diners',
        'credit_limit': 200000.0,
        'used_amount': 0.0,
        'created_at': now,
      });
      await db.insert('categories', {
        'id': 'cat_flight',
        'name': 'Flights',
        'type': 'expense',
      });

      // 1. CC Purchase
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

      // 2. CC Bill Settlement
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

      // Card liability is 0 (10k credit - 10k debit)
      expect((await accountRepo.getDerivedBalance('card_hdfc')).minorUnits, 0);
      expect((await queryRepo.getTotalLiabilities()).minorUnits, 0);
      // Flight expense is 10k
      expect((await queryRepo.getTotalExpenses()).minorUnits, 1000000);
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      // Bank balance: Reconciled to match legacy snapshot 50k
      expect((await accountRepo.getDerivedBalance('acc_bank')).minorUnits, 5000000);
      expect((await queryRepo.getTotalAssets()).minorUnits, 5000000);
      expect((await queryRepo.getNetWorth()).minorUnits, 5000000);
    });

    // -------------------------------------------------------------------------
    // FX04: Matched & Unmatched Refunds
    // -------------------------------------------------------------------------
    test('FX04: Matched & Unmatched Refunds Parity', () async {
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

      // Expense 2,000
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

      // Matched refund 2,000
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

      // Unmatched refund 500
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

      // Shopping expense: 2000 Dr - 2000 Cr = 0
      expect((await accountRepo.getDerivedBalance('cat_shopping')).minorUnits, 0);
      // sysExpRefunds: 500 Cr = -500 Dr
      expect((await accountRepo.getDerivedBalance(TablesV24.sysExpRefunds)).minorUnits, -50000);
      // Net expenses = -500 (contra-expense)
      expect((await queryRepo.getTotalExpenses()).minorUnits, -50000);
      // Zero income
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      // Bank balance: 10,000 (reconciled opening 9,500 + net refunds 500 = 10,000)
      expect((await accountRepo.getDerivedBalance('acc_1')).minorUnits, 1000000);
      expect((await queryRepo.getTotalAssets()).minorUnits, 1000000);
    });

    // -------------------------------------------------------------------------
    // FX05: Loan & EMI Amortization
    // -------------------------------------------------------------------------
    test('FX05: Loan & EMI Amortization Parity', () async {
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

      // Disbursement 100,000
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

      // Repayment 10,000 (8k principal, 2k interest)
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

      // Loan liability: 100k Cr - 8k Dr = 92k Cr (9,200,000 minor units)
      expect((await accountRepo.getDerivedBalance('loan_1')).minorUnits, 9200000);
      expect((await queryRepo.getTotalLiabilities()).minorUnits, 9200000);
      // Interest expense = 2k
      expect((await queryRepo.getTotalExpenses()).minorUnits, 200000);
      // Zero income
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      // Bank: 90,000 (9,000,000 minor units)
      expect((await accountRepo.getDerivedBalance('acc_bank')).minorUnits, 9000000);
      expect((await queryRepo.getTotalAssets()).minorUnits, 9000000);
      // Net Worth = Assets (90k) - Liabilities (92k) = -2k (-200,000 minor units)
      expect((await queryRepo.getNetWorth()).minorUnits, -200000);
    });

    // -------------------------------------------------------------------------
    // FX06: Recurring Salary Contracts
    // -------------------------------------------------------------------------
    test('FX06: Recurring Salary Contracts Parity', () async {
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

      // Invariant: Recurring rule generates 0 accounting postings
      final postings = await db.query(TablesV24.postings);
      expect(postings, isEmpty);
    });

    // -------------------------------------------------------------------------
    // FX07: Goals & Virtual Earmarks
    // -------------------------------------------------------------------------
    test('FX07: Goals & Virtual Earmarks Parity', () async {
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

      // Verify via Canonical Earmark Repository
      final earmarks = await earmarkRepo.getEarmarksForGoal('goal_car');
      expect(earmarks.length, 1);
      expect(earmarks.first.earmarkedAmount.minorUnits, 2000000);

      // Invariant: Account balance is 50,000 (earmark does not deduct ledger balance)
      expect((await accountRepo.getDerivedBalance('acc_savings')).minorUnits, 5000000);
      // Safe to spend reflects earmark deduction: 50,000 - 20,000 = 30,000
      final sts = await queryRepo.getSafeToSpend();
      expect(sts.liquidAssets.minorUnits, 5000000);
      expect(sts.activeEarmarks.minorUnits, 2000000);
      expect(sts.safeToSpend.minorUnits, 3000000);
    });

    // -------------------------------------------------------------------------
    // FX08: Categorical Budgets
    // -------------------------------------------------------------------------
    test('FX08: Categorical Budgets Parity', () async {
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
      expect(budgets.first['limit_amount'], 800000); // 8,000 * 100 paise

      // Invariant: Budgets generate 0 accounting postings
      expect(await db.query(TablesV24.postings), isEmpty);
    });

    // -------------------------------------------------------------------------
    // FX09: Cross-Source Deduplication Evidence
    // -------------------------------------------------------------------------
    test('FX09: Cross-Source Deduplication Evidence Parity', () async {
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

      final evidence = await eventRepo.getEvidenceForEvent('tx_starbucks');
      expect(evidence.length, 1);
      expect(evidence.first.bodyFingerprint!.length, 64);
      expect(evidence.first.externalReference, 'UPI/SB1234');

      expect((await accountRepo.getDerivedBalance('acc_1')).minorUnits, 100000);
    });

    // -------------------------------------------------------------------------
    // FX10: Soft-Deleted Transactions Excluded
    // -------------------------------------------------------------------------
    test('FX10: Soft-Deleted Transactions Excluded From Accounting Truth Parity', () async {
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

      await MigrationV24Service.migrate(db);

      // tx_deleted is strictly excluded from canonical events and postings
      expect(await eventRepo.getEvent('tx_deleted'), isNull);
      final deletedPostings = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: ['tx_deleted']);
      expect(deletedPostings, isEmpty);

      // Only tx_active affects expenses: ₹1,000
      expect((await queryRepo.getTotalExpenses()).minorUnits, 100000);
      expect((await accountRepo.getDerivedBalance('acc_1')).minorUnits, 100000);
    });

    // -------------------------------------------------------------------------
    // FX11: Inconsistent Balances Reconciled With Provenance
    // -------------------------------------------------------------------------
    test('FX11: Inconsistent Balances Reconciled With Provenance Parity', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_drift',
        'name': 'Drift Bank',
        'balance': 25000.0, // Legacy = 25,000
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('transactions', {
        'id': 'tx_inc',
        'amount': 10000.0, // Txns = 10,000
        'type': 'income',
        'account_id': 'acc_drift',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      await MigrationV24Service.migrate(db);

      // Provenance record exists
      final obr = await obrRepo.getReconciliationForAccount('acc_drift');
      expect(obr, isNotNull);
      expect(obr!.adjustmentDelta.minorUnits, 1500000); // ₹15,000 adjustment

      // Derived balance exactly equals legacy balance: 25,000 (2,500,000 minor units)
      expect((await accountRepo.getDerivedBalance('acc_drift')).minorUnits, 2500000);
      expect((await queryRepo.getTotalAssets()).minorUnits, 2500000);
      // Income only includes tx_inc (₹10,000); the ₹15,000 equity delta is NOT income
      expect((await queryRepo.getTotalIncome()).minorUnits, 1000000);
      // Base equity contains the ₹15,000 delta
      expect((await queryRepo.getBaseEquity()).minorUnits, 1500000);
      // Total equity = Base (15k) + Retained (10k) = 25k = Net Worth
      expect((await queryRepo.getTotalEquity()).minorUnits, 2500000);
      expect((await queryRepo.getNetWorth()).minorUnits, 2500000);
    });

    // -------------------------------------------------------------------------
    // FX12: Malformed Legacy Rows Handled Without Crashing
    // -------------------------------------------------------------------------
    test('FX12: Malformed Legacy Rows Handled Without Crashing Parity', () async {
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

      await MigrationV24Service.migrate(db);

      // Both bad rows migrated to suspense/fallback accounts without crashing
      final postedEvents = await eventRepo.listPostedEvents();
      expect(postedEvents.length, 3); // 2 txns + 1 opening balance
      expect((await accountRepo.getDerivedBalance('acc_1')).minorUnits, 10000);
    });

    // -------------------------------------------------------------------------
    // FX13: Legacy Vehicle Logs Dropped (Gated)
    // -------------------------------------------------------------------------
    test('FX13: Legacy Vehicle Logs Dropped Parity', () async {
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

      await MigrationV24Service.migrate(db, allowDestructiveDrops: false);

      // Fuel transaction persisted as ordinary expense
      final fuelEvt = await eventRepo.getEvent('tx_fuel');
      expect(fuelEvt, isNotNull);
      expect(fuelEvt!.canonicalType, CanonicalEventType.expense);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 300000);
      expect((await accountRepo.getDerivedBalance('acc_1')).minorUnits, 500000);
    });

    // -------------------------------------------------------------------------
    // FX14: Pending Review Queue (Zero Postings)
    // -------------------------------------------------------------------------
    test('FX14: Pending Review Queue Parity (Zero Postings in Ledger)', () async {
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

      await MigrationV24Service.migrate(db);

      // Staged in review candidates
      final candidates = await reviewRepo.listCandidates();
      expect(candidates.length, 3);
      for (final c in candidates) {
        expect(c.status, ReviewCandidateStatus.pending);
      }

      // Invariant: ZERO ledger postings generated for review candidates
      final postings = await db.query(TablesV24.postings);
      expect(postings, isEmpty);

      // Invariant: All financial aggregates are strictly zero
      expect((await queryRepo.getTotalAssets()).minorUnits, 0);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 0);
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      expect((await queryRepo.getNetWorth()).minorUnits, 0);
    });
  });
}
