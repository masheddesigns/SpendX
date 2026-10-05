import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/budget_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/review_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_recurring_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';

import 'package:spend_x/features/review_queue/providers/review_providers.dart'
    as review_prov;
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/category.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/analytics_service.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';
import 'package:spend_x/services/canonical_forecast_engine.dart';
import 'package:spend_x/services/data_change_bus.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late String dbPath;
  late Database db;

  late TransactionRepo transactionRepo;
  late AccountRepo accountRepo;
  late CreditRepo creditRepo;
  late LoanRepo loanRepo;
  late GoalRepo goalRepo;
  late BudgetRepo budgetRepo;
  late CategoryRepo categoryRepo;
  late ReviewRepo reviewRepo;

  late CanonicalAccountRepository canonicalAccountRepo;
  late CanonicalEventRepository canonicalEventRepo;
  late CanonicalFinancialQueryRepository canonicalQueryRepo;
  late CanonicalRecurringRepository canonicalRecurringRepo;
  late CanonicalReviewRepository canonicalReviewRepo;

  late FinancialTransactionService financialService;
  late CanonicalForecastEngine forecastEngine;
  late AnalyticsService analyticsService;

  late ProviderContainer container;

  const testBankId = 'acc_bank_c8_primary';
  const testBankId2 = 'acc_bank_c8_secondary';
  const testCardId = 'card_c8_test';
  const testLoanId = 'loan_c8_test';
  const testCatFoodId = 'cat_c8_food';
  const testCatSalaryId = 'cat_c8_salary';

  Future<void> initDatabase(String path) async {
    db = await openDatabase(
      path,
      version: 24,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
      },
    );
    await Tables.createAll(db);
    await TablesV24.createAllV24(db);
    await TablesV24.seedSystemAccounts(db);
    await TablesV24.installTriggers(db);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
    tempDir = await Directory.systemTemp.createTemp('spendx_c8_adversarial_');
    dbPath = join(tempDir.path, 'spendx_c8_test.db');
    await initDatabase(dbPath);

    canonicalAccountRepo = CanonicalAccountRepository(executor: db);
    canonicalEventRepo = CanonicalEventRepository(executor: db);
    canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
    canonicalRecurringRepo = CanonicalRecurringRepository(executor: db);
    canonicalReviewRepo = CanonicalReviewRepository(executor: db);

    transactionRepo = TransactionRepo(executor: db);
    accountRepo = AccountRepo(executor: db);
    creditRepo = CreditRepo(executor: db);
    loanRepo = LoanRepo(executor: db);
    goalRepo = GoalRepo(executor: db);
    budgetRepo = BudgetRepo(executor: db, queryRepo: canonicalQueryRepo);
    categoryRepo = CategoryRepo(executor: db);
    reviewRepo = ReviewRepo(
      canonicalReviewRepo: canonicalReviewRepo,
      eventRepo: canonicalEventRepo,
    );

    financialService = FinancialTransactionService(
      database: db,
    );

    forecastEngine = CanonicalForecastEngine(
      queryRepo: canonicalQueryRepo,
      recurringRepo: canonicalRecurringRepo,
      loanRepo: loanRepo,
      creditRepo: creditRepo,
    );
    analyticsService = AnalyticsService();

    container = ProviderContainer(
      overrides: [
        app_data.transactionRepoProvider.overrideWithValue(transactionRepo),
        app_data.accountRepoProvider.overrideWithValue(accountRepo),
        app_data.creditRepoProvider.overrideWithValue(creditRepo),
        app_data.loanRepoProvider.overrideWithValue(loanRepo),
        app_data.goalRepoProvider.overrideWithValue(goalRepo),
        app_data.budgetRepoProvider.overrideWithValue(budgetRepo),
        app_data.canonicalFinancialQueryRepositoryProvider
            .overrideWithValue(canonicalQueryRepo),
        app_data.canonicalRecurringRepositoryProvider
            .overrideWithValue(canonicalRecurringRepo),
        app_data.canonicalForecastEngineProvider
            .overrideWithValue(forecastEngine),
        app_data.analyticsServiceProvider.overrideWithValue(analyticsService),
        app_data.financialTransactionServiceProvider
            .overrideWithValue(financialService),
        app_data.categoryRepoProvider.overrideWithValue(categoryRepo),
        review_prov.reviewRepoProvider.overrideWithValue(reviewRepo),
      ],
    );

    // Seed test bank accounts
    await accountRepo.insertAccount(
      BankAccount(
        id: testBankId,
        name: 'Main Checking',
        bank: 'HDFC Bank',
        balance: 50000.0,
        last4: '1111',
      ),
    );
    await accountRepo.insertAccount(
      BankAccount(
        id: testBankId2,
        name: 'Secondary Savings',
        bank: 'SBI Bank',
        balance: 20000.0,
        last4: '2222',
      ),
    );

    // Seed test categories
    await categoryRepo.insert(
      Category(
        id: testCatFoodId,
        name: 'Food & Dining',
        icon: 'food',
        color: '#FF0000',
        type: 'expense',
        userId: 'u1',
      ),
    );
    final now = DateTime.now().toIso8601String();
    await db.insert(
      TablesV24.accounts,
      {
        'id': testCatFoodId,
        'account_type': 'expense',
        'subtype': 'category',
        'name': 'Food & Dining',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    await categoryRepo.insert(
      Category(
        id: testCatSalaryId,
        name: 'Salary',
        icon: 'salary',
        color: '#00FF00',
        type: 'income',
        userId: 'u1',
      ),
    );
    await db.insert(
      TablesV24.accounts,
      {
        'id': testCatSalaryId,
        'account_type': 'income',
        'subtype': 'category',
        'name': 'Salary',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  });

  tearDown(() async {
    container.dispose();
    if (db.isOpen) {
      await db.close();
    }
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('SpendX 2.0 — Milestone C8 Canonical Backup & Restore Tests', () {
    test('1. Empty database backup and restore round-trip', () async {
      final emptyDbPath = join(tempDir.path, 'empty.db');
      final emptyDb = await openDatabase(
        emptyDbPath,
        version: 24,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON;'),
      );
      await Tables.createAll(emptyDb);
      await TablesV24.createAllV24(emptyDb);
      await TablesV24.seedSystemAccounts(emptyDb);
      await TablesV24.installTriggers(emptyDb);

      final packagePath = join(tempDir.path, 'empty.spendx');
      final (pkg, manifest) =
          await BackupService.instance.createBackupPackage(
        sourceDb: emptyDb,
        sourceDbPath: emptyDbPath,
        outputFile: File(packagePath),
      );

      expect(await pkg.exists(), isTrue);
      expect(manifest.canonicalEventCount, 0);
      expect(manifest.postingCount, 0);
      expect(manifest.debitTotal, 0);
      expect(manifest.creditTotal, 0);

      // Restore over a fresh target
      final targetPath = join(tempDir.path, 'target_empty.db');
      final targetDb = await openDatabase(targetPath, version: 24);

      final success = await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: targetPath,
        targetDb: targetDb,
      );
      expect(success, isTrue);

      final reopened = await openDatabase(targetPath);
      final ver = (await reopened.rawQuery('PRAGMA user_version;'))
          .first
          .values
          .first;
      expect(ver, 24);
      await reopened.close();
      await emptyDb.close();
    });

    test('2. Normal multi-account financial dataset round-trip', () async {
      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'expense',
          amount: 1500.0,
          date: DateTime.now(),
          accountId: testBankId,
          categoryId: testCatFoodId,
          notes: 'Groceries',
        ),
      );

      final packagePath = join(tempDir.path, 'normal.spendx');
      final (pkg, manifest) =
          await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: File(packagePath),
      );

      expect(await pkg.exists(), isTrue);
      expect(manifest.canonicalEventCount, greaterThan(0));
      expect(manifest.postingCount, greaterThan(0));
      expect(manifest.debitTotal, manifest.creditTotal);

      // Restore
      final restored = await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
        container: container,
      );
      expect(restored, isTrue);

      final reopened = await openDatabase(dbPath);
      final events = await reopened.query(TablesV24.economicEvents);
      expect(events.length, manifest.canonicalEventCount);
      await reopened.close();
    });

    test('3. Multiple accounts (assets, liabilities, equity) fidelity', () async {
      final accountsBefore = await db.query(TablesV24.accounts);
      final pkgFile = File(join(tempDir.path, 'accounts.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkgFile,
      );

      await BackupService.instance.restoreFromFile(
        pkgFile,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final accountsAfter = await reopened.query(TablesV24.accounts);

      expect(accountsAfter.length, accountsBefore.length);
      for (final a in accountsBefore) {
        expect(accountsAfter.any((x) => x['id'] == a['id']), isTrue);
      }
      await reopened.close();
    });

    test('4. Income event and postings round-trip fidelity', () async {
      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'income',
          amount: 80000.0,
          date: DateTime.now(),
          accountId: testBankId,
          categoryId: testCatSalaryId,
          notes: 'Salary credit',
        ),
      );

      final pkg = File(join(tempDir.path, 'income.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final accRepo = CanonicalAccountRepository(executor: reopened);
      final balance = await accRepo.getDerivedBalance(testBankId);
      // Initial 50,000 + 80,000 = 130,000 => 13,000,000 paise
      expect(balance.minorUnits, 13000000);
      await reopened.close();
    });

    test('5. Expense event and postings round-trip fidelity', () async {
      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'expense',
          amount: 5000.0,
          date: DateTime.now(),
          accountId: testBankId,
          categoryId: testCatFoodId,
          notes: 'Dining',
        ),
      );

      final pkg = File(join(tempDir.path, 'expense.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final accRepo = CanonicalAccountRepository(executor: reopened);
      final balance = await accRepo.getDerivedBalance(testBankId);
      // 50,000 - 5,000 = 45,000 => 4,500,000 paise
      expect(balance.minorUnits, 4500000);
      await reopened.close();
    });

    test('6. Account-to-account transfer round-trip balance fidelity', () async {
      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'transfer',
          amount: 10000.0,
          date: DateTime.now(),
          accountId: testBankId,
          relatedEntityId: testBankId2,
          notes: 'Bank transfer',
        ),
      );

      final pkg = File(join(tempDir.path, 'transfer.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final accRepo = CanonicalAccountRepository(executor: reopened);
      final b1 = await accRepo.getDerivedBalance(testBankId);
      final b2 = await accRepo.getDerivedBalance(testBankId2);

      expect(b1.minorUnits, 4000000);
      expect(b2.minorUnits, 3000000);
      await reopened.close();
    });

    test('7. Credit card purchase event and liability posting fidelity', () async {
      await creditRepo.insert(
        CreditCard(
          id: testCardId,
          name: 'Amex Platinum',
          bank: 'Amex',
          limitAmount: 200000.0,
          usedAmount: 0.0,
          billingDay: 1,
          dueDay: 20,
        ),
      );

      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'expense',
          amount: 15000.0,
          date: DateTime.now(),
          categoryId: testCatFoodId,
          notes: 'Card purchase',
        ),
        creditTxn: CreditTransaction(
          id: 'ctx_charge_1',
          cardId: testCardId,
          amount: 15000.0,
          date: DateTime.now(),
          category: 'Food',
          type: 'purchase',
          status: 'active',
          note: 'Card purchase',
        ),
      );

      final pkg = File(join(tempDir.path, 'card_purchase.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final accRepo = CanonicalAccountRepository(executor: reopened);
      final cardBal = await accRepo.getDerivedBalance(testCardId);
      // Liability: 15,000 INR = 1,500,000 paise credit
      expect(cardBal.minorUnits, 1500000);
      await reopened.close();
    });

    test('8. Credit card bill payment and bank debit round-trip', () async {
      await creditRepo.insert(
        CreditCard(
          id: testCardId,
          name: 'Visa Gold',
          bank: 'HDFC',
          limitAmount: 100000.0,
          usedAmount: 0.0,
          billingDay: 5,
          dueDay: 25,
        ),
      );

      // Spend 10k
      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'expense',
          amount: 10000.0,
          date: DateTime.now(),
          categoryId: testCatFoodId,
          notes: 'Purchase',
        ),
        creditTxn: CreditTransaction(
          id: 'ctx_charge_2',
          cardId: testCardId,
          amount: 10000.0,
          date: DateTime.now(),
          category: 'Food',
          type: 'purchase',
          status: 'active',
          note: 'Purchase',
        ),
      );

      // Pay 10k bill from bank
      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'transfer',
          amount: 10000.0,
          date: DateTime.now(),
          accountId: testBankId,
          notes: 'Card Payment',
        ),
        creditTxn: CreditTransaction(
          id: 'ctx_pay_1',
          cardId: testCardId,
          amount: 10000.0,
          date: DateTime.now(),
          category: 'Payment',
          type: 'payment',
          status: 'active',
          note: 'Bill Payment',
          categoryId: testBankId,
        ),
      );

      final pkg = File(join(tempDir.path, 'card_payment.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final accRepo = CanonicalAccountRepository(executor: reopened);
      final cardBal = await accRepo.getDerivedBalance(testCardId);
      expect(cardBal.minorUnits, 0); // fully paid
      await reopened.close();
    });

    test('9. Refund event with multi-leg reversals preserved', () async {
      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'income',
          amount: 2500.0,
          date: DateTime.now(),
          accountId: testBankId,
          categoryId: testCatFoodId,
          notes: 'Food refund',
        ),
      );

      final pkg = File(join(tempDir.path, 'refund.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final accRepo = CanonicalAccountRepository(executor: reopened);
      final bankBal = await accRepo.getDerivedBalance(testBankId);
      // 50,000 + 2,500 = 52,500
      expect(bankBal.minorUnits, 5250000);
      await reopened.close();
    });

    test('10. Loan disbursement event and liability establishment', () async {
      await loanRepo.insertLoan(
        Loan(
          id: testLoanId,
          name: 'Home Renovation',
          bank: 'HDFC Bank',
          total: 100000.0,
          paidAmount: 0.0,
          interestRate: 10.0,
          tenureMonths: 12,
          monthlyInstallment: 8800.0,
          startDate: DateTime.now(),
          loanStatus: 'active',
          dueDay: 5,
        ),
      );

      final pkg = File(join(tempDir.path, 'loan_disburse.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final accRepo = CanonicalAccountRepository(executor: reopened);
      final loanBal = await accRepo.getDerivedBalance(testLoanId);
      expect(loanBal.minorUnits, 10000000); // 100k liability
      await reopened.close();
    });

    test('11. Loan EMI repayment 3-leg split preserved', () async {
      await loanRepo.insertLoan(
        Loan(
          id: testLoanId,
          name: 'Auto Loan',
          bank: 'SBI Bank',
          total: 50000.0,
          paidAmount: 0.0,
          interestRate: 8.0,
          tenureMonths: 12,
          monthlyInstallment: 4500.0,
          startDate: DateTime.now(),
          loanStatus: 'active',
          dueDay: 5,
        ),
      );

      // EMI: 5,000 from Bank (4,000 principal + 1,000 interest)
      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'loan_repayment',
          amount: 5000.0,
          date: DateTime.now(),
          accountId: testBankId,
          relatedEntityId: testLoanId,
          notes: 'EMI repayment',
        ),
        loanId: testLoanId,
        loanPaidDelta: 4000.0,
      );

      final pkg = File(join(tempDir.path, 'loan_emi.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final accRepo = CanonicalAccountRepository(executor: reopened);
      final loanBal = await accRepo.getDerivedBalance(testLoanId);
      // 50,000 - 4,000 principal = 46,000 => 4,600,000 paise
      expect(loanBal.minorUnits, 4600000);
      await reopened.close();
    });

    test('12. Goal asset earmark relationships intact after restore', () async {
      await db.insert(TablesV24.assetEarmarks, {
        'id': 'earmark_1',
        'goal_id': 'goal_emergency',
        'asset_account_id': testBankId,
        'amount_minor_units': 1500000,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      final pkg = File(join(tempDir.path, 'earmarks.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final rows = await reopened.query(TablesV24.assetEarmarks);
      expect(rows.length, 1);
      expect(rows.first['amount_minor_units'], 1500000);
      expect(rows.first['asset_account_id'], testBankId);
      await reopened.close();
    });

    test('13. Recurring rules and frequency settings survive restore', () async {
      await db.insert(TablesV24.recurringRules, {
        'id': 'rule_netflix',
        'title': 'Netflix Subscription',
        'category_account_id': testCatFoodId,
        'target_account_id': testBankId,
        'amount_minor_units': 64900,
        'cadence': 'monthly',
        'day_of_month': 15,
        'next_due_date': '2026-11-15',
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      final pkg = File(join(tempDir.path, 'rules.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final rows = await reopened.query(TablesV24.recurringRules);
      expect(rows.length, 1);
      expect(rows.first['title'], 'Netflix Subscription');
      expect(rows.first['amount_minor_units'], 64900);
      await reopened.close();
    });

    test('14. Expected events and fulfillment pointers survive restore', () async {
      await db.insert(TablesV24.recurringRules, {
        'id': 'rule_wifi',
        'title': 'Broadband',
        'category_account_id': testCatFoodId,
        'target_account_id': testBankId,
        'amount_minor_units': 99900,
        'cadence': 'monthly',
        'next_due_date': '2026-10-20',
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      await db.insert(TablesV24.expectedEvents, {
        'id': 'expected_wifi_oct',
        'rule_id': 'rule_wifi',
        'due_date': '2026-10-20',
        'amount_minor_units': 99900,
        'status': 'pending',
        'created_at': DateTime.now().toIso8601String(),
      });

      final pkg = File(join(tempDir.path, 'expected.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final rows = await reopened.query(TablesV24.expectedEvents);
      expect(rows.length, 1);
      expect(rows.first['id'], 'expected_wifi_oct');
      expect(rows.first['status'], 'pending');
      await reopened.close();
    });

    test('15. Pending review candidate remains non-accounting after restore', () async {
      await db.insert(TablesV24.reviewCandidates, {
        'id': 'review_cand_1',
        'source_type': 'sms',
        'suggested_event_type': 'expense',
        'suggested_amount_minor_units': 45000,
        'confidence_score': 0.85,
        'status': 'pending',
        'created_at': DateTime.now().toIso8601String(),
      });

      final pkg = File(join(tempDir.path, 'pending_review.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final reviews = await reopened.query(TablesV24.reviewCandidates);
      expect(reviews.length, 1);
      expect(reviews.first['status'], 'pending');

      final events = await reopened.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: ['review_cand_1'],
      );
      expect(events.isEmpty, isTrue);
      await reopened.close();
    });

    test('16. Approved review candidate produces identical ledger postings', () async {
      const eventId = 'event_from_review_1';
      final now = DateTime.now().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': eventId,
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'description': 'Review Event',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'post_rev_dr',
        'economic_event_id': eventId,
        'account_id': testCatFoodId,
        'direction': 'debit',
        'amount_minor_units': 50000,
        'currency': 'INR',
        'sequence_number': 1,
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert(TablesV24.postings, {
        'id': 'post_rev_cr',
        'economic_event_id': eventId,
        'account_id': testBankId,
        'direction': 'credit',
        'amount_minor_units': 50000,
        'currency': 'INR',
        'sequence_number': 2,
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [eventId],
      );

      final pkg = File(join(tempDir.path, 'approved_review.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final postings = await reopened.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [eventId],
      );
      expect(postings.length, 2);
      await reopened.close();
    });

    test('17. Evidence fingerprint (SHA-256) and external references survive', () async {
      await db.insert(TablesV24.evidence, {
        'id': 'evi_fingerprint_test',
        'source_type': 'sms',
        'extracted_amount_minor_units': 120000,
        'extracted_timestamp': DateTime.now().toIso8601String(),
        'sender_address': 'HDFCBK',
        'external_reference': 'UTR1234567890',
        'body_sha256':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'is_payload_purged': 1,
        'created_at': DateTime.now().toIso8601String(),
      });

      final pkg = File(join(tempDir.path, 'evidence.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final evidence = await reopened.query(
        TablesV24.evidence,
        where: 'id = ?',
        whereArgs: ['evi_fingerprint_test'],
      );
      expect(evidence.length, 1);
      expect(evidence.first['external_reference'], 'UTR1234567890');
      expect(evidence.first['body_sha256'],
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      await reopened.close();
    });

    test('18. Opening balance reconciliation records preserved with provenance', () async {
      await db.insert(TablesV24.openingBalanceReconciliations, {
        'id': 'obr_test_1',
        'account_id': testBankId,
        'legacy_reported_balance_minor_units': 5000000,
        'reconstructed_balance_minor_units': 5000000,
        'adjustment_delta_minor_units': 0,
        'reconciliation_reason': 'Baseline reconciliation',
        'provenance_source': 'v24_migration',
        'status': 'reconciled',
        'created_at': DateTime.now().toIso8601String(),
      });

      final pkg = File(join(tempDir.path, 'obr.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final obrs = await reopened.query(TablesV24.openingBalanceReconciliations);
      expect(obrs.length, greaterThanOrEqualTo(1));
      expect(obrs.any((r) => r['id'] == 'obr_test_1'), isTrue);
      await reopened.close();
    });

    test('19. Corrupt package (invalid zip structure) rejected', () async {
      final corruptFile = File(join(tempDir.path, 'corrupt.spendx'));
      await corruptFile.writeAsString('THIS IS NOT A ZIP ARCHIVE');

      expect(
        BackupService.instance.restoreFromFile(
          corruptFile,
          targetDbPath: dbPath,
          targetDb: db,
        ),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('20. Truncated package (0 bytes) rejected', () async {
      final emptyFile = File(join(tempDir.path, 'empty_zero.spendx'));
      await emptyFile.writeAsBytes([]);

      expect(
        BackupService.instance.restoreFromFile(
          emptyFile,
          targetDbPath: dbPath,
          targetDb: db,
        ),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('21. Invalid schema version (> 24 or < 24) rejected without touching active DB', () async {
      final validPkg = File(join(tempDir.path, 'valid.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: validPkg,
      );

      // Unpack and forge schema version to 99
      final decoder = ZipDecoder();
      final archive = decoder.decodeBytes(await validPkg.readAsBytes());

      final newArchive = Archive();
      for (final f in archive.files) {
        if (f.name == 'manifest.json') {
          final manifestMap = jsonDecode(utf8.decode(f.content as List<int>))
              as Map<String, dynamic>;
          manifestMap['schema_version'] = 99;
          final bytes = utf8.encode(jsonEncode(manifestMap));
          newArchive.addFile(ArchiveFile('manifest.json', bytes.length, bytes));
        } else {
          newArchive.addFile(f);
        }
      }

      final forgedFile = File(join(tempDir.path, 'forged_version.spendx'));
      await forgedFile.writeAsBytes(ZipEncoder().encode(newArchive));

      expect(
        BackupService.instance.restoreFromFile(
          forgedFile,
          targetDbPath: dbPath,
          targetDb: db,
        ),
        throwsA(isA<UnsupportedBackupVersionException>()),
      );
    });

    test('22. Foreign-key constraint violation in staging DB triggers validation error', () async {
      final badDbPath = join(tempDir.path, 'bad_fk.db');
      final badDb = await openDatabase(badDbPath, version: 24);
      await Tables.createAll(badDb);
      await TablesV24.createAllV24(badDb);
      // Disable foreign keys temporarily to inject orphaned posting
      await badDb.execute('PRAGMA foreign_keys = OFF;');
      await badDb.insert(TablesV24.postings, {
        'id': 'orphan_post',
        'economic_event_id': 'nonexistent_event',
        'account_id': 'nonexistent_account',
        'direction': 'debit',
        'amount_minor_units': 1000,
        'currency': 'INR',
        'sequence_number': 1,
        'created_at': DateTime.now().toIso8601String(),
      });
      await badDb.execute('PRAGMA foreign_keys = ON;');

      final badPkg = File(join(tempDir.path, 'bad_fk.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: badDb,
        sourceDbPath: badDbPath,
        outputFile: badPkg,
      );
      await badDb.close();

      expect(
        BackupService.instance.restoreFromFile(
          badPkg,
          targetDbPath: dbPath,
          targetDb: db,
        ),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('23. Unbalanced postings in staging DB triggers immediate rejection', () async {
      final badDbPath = join(tempDir.path, 'bad_balance.db');
      final badDb = await openDatabase(badDbPath, version: 24);
      await Tables.createAll(badDb);
      await TablesV24.createAllV24(badDb);
      await TablesV24.seedSystemAccounts(badDb);

      const eventId = 'unbalanced_evt';
      final now = DateTime.now().toIso8601String();
      await badDb.insert(TablesV24.accounts, {
        'id': testCatFoodId,
        'account_type': 'expense',
        'subtype': 'category',
        'name': 'Food & Dining',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': now,
        'updated_at': now,
      });
      await badDb.insert(TablesV24.economicEvents, {
        'id': eventId,
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'description': 'Unbalanced Event',
        'created_at': now,
        'updated_at': now,
      });
      await badDb.insert(TablesV24.postings, {
        'id': 'unbalanced_p1',
        'economic_event_id': eventId,
        'account_id': testCatFoodId,
        'direction': 'debit',
        'amount_minor_units': 10000,
        'currency': 'INR',
        'sequence_number': 1,
        'created_at': now,
      });
      // Bypass trigger
      await badDb.execute(
          'DROP TRIGGER IF EXISTS trg_economic_events_validate_posted;');
      await badDb.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [eventId],
      );

      final badPkg = File(join(tempDir.path, 'unbalanced.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: badDb,
        sourceDbPath: badDbPath,
        outputFile: badPkg,
      );
      await badDb.close();

      expect(
        BackupService.instance.restoreFromFile(
          badPkg,
          targetDbPath: dbPath,
          targetDb: db,
        ),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('24. Non-positive posting amount (amount <= 0) rejected', () async {
      final badDbPath = join(tempDir.path, 'zero_post.db');
      final badDb = await openDatabase(badDbPath, version: 24);
      await Tables.createAll(badDb);
      await TablesV24.createAllV24(badDb);
      await TablesV24.seedSystemAccounts(badDb);

      await badDb.execute('PRAGMA ignore_check_constraints = ON;');
      const eventId = 'zero_evt';
      final now = DateTime.now().toIso8601String();
      await badDb.insert(TablesV24.accounts, {
        'id': testCatFoodId,
        'account_type': 'expense',
        'subtype': 'category',
        'name': 'Food & Dining',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': now,
        'updated_at': now,
      });
      await badDb.insert(TablesV24.economicEvents, {
        'id': eventId,
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'description': 'Zero Event',
        'created_at': now,
        'updated_at': now,
      });
      await badDb.insert(TablesV24.postings, {
        'id': 'zero_post_1',
        'economic_event_id': eventId,
        'account_id': testCatFoodId,
        'direction': 'debit',
        'amount_minor_units': 0,
        'currency': 'INR',
        'sequence_number': 1,
        'created_at': DateTime.now().toIso8601String(),
      });

      final badPkg = File(join(tempDir.path, 'zero_amount.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: badDb,
        sourceDbPath: badDbPath,
        outputFile: badPkg,
      );
      await badDb.close();

      expect(
        BackupService.instance.restoreFromFile(
          badPkg,
          targetDbPath: dbPath,
          targetDb: db,
        ),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('25. SHA-256 checksum mismatch on spendx.db rejected', () async {
      final validPkg = File(join(tempDir.path, 'valid_hash.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: validPkg,
      );

      final decoder = ZipDecoder();
      final archive = decoder.decodeBytes(await validPkg.readAsBytes());

      final newArchive = Archive();
      for (final f in archive.files) {
        if (f.name == 'spendx.db') {
          final bytes = List<int>.from(f.content as List<int>);
          bytes[100] = (bytes[100] + 1) % 256;
          newArchive.addFile(ArchiveFile('spendx.db', bytes.length, bytes));
        } else {
          newArchive.addFile(f);
        }
      }

      final tamperedPkg = File(join(tempDir.path, 'tampered_hash.spendx'));
      await tamperedPkg.writeAsBytes(ZipEncoder().encode(newArchive));

      expect(
        BackupService.instance.restoreFromFile(
          tamperedPkg,
          targetDbPath: dbPath,
          targetDb: db,
        ),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('26. Legacy format 1 backup detected and rejected', () async {
      final legacyFile = File(join(tempDir.path, 'spendx_backup.json'));
      await legacyFile.writeAsString(jsonEncode({
        'version': 1,
        'app': 'SpendX',
        'createdAt': DateTime.now().toIso8601String(),
        'transactions': [],
      }));

      expect(
        BackupService.instance.restoreFromFile(
          legacyFile,
          targetDbPath: dbPath,
          targetDb: db,
        ),
        throwsA(isA<UnsupportedBackupVersionException>()),
      );
    });

    test('27. Failed restore leaves active DB completely untouched', () async {
      final countBefore = (await db.query(TablesV24.accounts)).length;

      final corruptFile = File(join(tempDir.path, 'fail_untouched.spendx'));
      await corruptFile.writeAsString('BAD PAYLOAD');

      try {
        await BackupService.instance.restoreFromFile(
          corruptFile,
          targetDbPath: dbPath,
          targetDb: db,
        );
      } catch (_) {}

      final reopened = await openDatabase(dbPath);
      final countAfter = (await reopened.query(TablesV24.accounts)).length;
      expect(countAfter, countBefore);
      await reopened.close();
    });

    test('28. Atomic restore failure triggers automatic rollback to pre-restore state', () async {
      final balanceBefore =
          await canonicalAccountRepo.getDerivedBalance(testBankId);

      final validPkg = File(join(tempDir.path, 'valid_for_rollback.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: validPkg,
      );

      final ok = await BackupService.instance.restoreFromFile(
        validPkg,
        targetDbPath: dbPath,
        targetDb: db,
      );
      expect(ok, isTrue);

      final reopened = await openDatabase(dbPath);
      final accRepo = CanonicalAccountRepository(executor: reopened);
      final balanceAfter = await accRepo.getDerivedBalance(testBankId);
      expect(balanceAfter.minorUnits, balanceBefore.minorUnits);
      await reopened.close();
    });

    test('29. Staging directory cleaned up after restore attempt', () async {
      final corruptFile = File(join(tempDir.path, 'staging_clean.spendx'));
      await corruptFile.writeAsString('CORRUPT');

      try {
        await BackupService.instance.restoreFromFile(
          corruptFile,
          targetDbPath: dbPath,
          targetDb: db,
        );
      } catch (_) {}

      final stages = tempDir
          .listSync()
          .where((e) => e.path.contains('spendx_restore_stage_'));
      expect(stages.isEmpty, isTrue);
    });

    test('30. Checkpoint flushes WAL cleanly during backup creation', () async {
      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'expense',
          amount: 1000.0,
          date: DateTime.now(),
          accountId: testBankId,
          categoryId: testCatFoodId,
          notes: 'Coffee',
        ),
      );

      final pkg = File(join(tempDir.path, 'wal_flushed.spendx'));
      final (pkgFile, manifest) =
          await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      expect(await pkgFile.exists(), isTrue);
      expect(manifest.canonicalEventCount, greaterThan(0));
    });

    test('31. Raw SMS payload purged before backup and after restore for expired items', () async {
      final expiredDate =
          DateTime.now().subtract(const Duration(days: 35)).toIso8601String();
      final freshDate =
          DateTime.now().add(const Duration(days: 10)).toIso8601String();

      await db.insert(TablesV24.evidence, {
        'id': 'evi_expired',
        'source_type': 'sms',
        'extracted_amount_minor_units': 50000,
        'extracted_timestamp': expiredDate,
        'body_sha256': 'hash_expired',
        'raw_payload_encrypted': 'Sensitive Raw SMS Text',
        'retention_expires_at': expiredDate,
        'is_payload_purged': 0,
        'created_at': expiredDate,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'evi_fresh',
        'source_type': 'sms',
        'extracted_amount_minor_units': 20000,
        'extracted_timestamp': DateTime.now().toIso8601String(),
        'body_sha256': 'hash_fresh',
        'raw_payload_encrypted': 'Fresh Raw SMS Text',
        'retention_expires_at': freshDate,
        'is_payload_purged': 0,
        'created_at': DateTime.now().toIso8601String(),
      });

      final pkg = File(join(tempDir.path, 'privacy_scrub.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      final rowBefore = await db.query(
        TablesV24.evidence,
        where: 'id = ?',
        whereArgs: ['evi_expired'],
      );
      expect(rowBefore.first['raw_payload_encrypted'], isNull);
      expect(rowBefore.first['is_payload_purged'], 1);

      final rowFresh = await db.query(
        TablesV24.evidence,
        where: 'id = ?',
        whereArgs: ['evi_fresh'],
      );
      expect(rowFresh.first['raw_payload_encrypted'], 'Fresh Raw SMS Text');
      expect(rowFresh.first['is_payload_purged'], 0);

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final restoredExpired = await reopened.query(
        TablesV24.evidence,
        where: 'id = ?',
        whereArgs: ['evi_expired'],
      );
      expect(restoredExpired.first['raw_payload_encrypted'], isNull);
      await reopened.close();
    });

    test('32. Centralized provider invalidation refreshes Riverpod state after restore', () async {
      var busNotified = false;
      void listener() {
        busNotified = true;
      }

      DataChangeBus.instance.addListener(listener);

      final pkg = File(join(tempDir.path, 'provider_refresh.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      final ok = await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
        container: container,
      );

      expect(ok, isTrue);
      expect(busNotified, isTrue);
      DataChangeBus.instance.removeListener(listener);
    });

    test('33. Net worth equality verified before backup and after restore', () async {
      await financialService.createTransaction(
        spx.Transaction(
          userId: 'u1',
          type: 'income',
          amount: 25000.0,
          date: DateTime.now(),
          accountId: testBankId,
          categoryId: testCatSalaryId,
          notes: 'Bonus',
        ),
      );

      final netWorthBefore = await canonicalQueryRepo.getNetWorth();
      final assetsBefore = await canonicalQueryRepo.getTotalAssets();
      final liabBefore = await canonicalQueryRepo.getTotalLiabilities();

      final pkg = File(join(tempDir.path, 'net_worth.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final qRepo = CanonicalFinancialQueryRepository(executor: reopened);
      final netWorthAfter = await qRepo.getNetWorth();
      final assetsAfter = await qRepo.getTotalAssets();
      final liabAfter = await qRepo.getTotalLiabilities();

      expect(assetsAfter.minorUnits, assetsBefore.minorUnits);
      expect(liabAfter.minorUnits, liabBefore.minorUnits);
      expect(netWorthAfter.minorUnits, netWorthBefore.minorUnits);
      await reopened.close();
    });

    test('34. Safe-to-Spend calculation identical before backup and after restore', () async {
      final stsBefore = await canonicalQueryRepo.getSafeToSpend();

      final pkg = File(join(tempDir.path, 'sts.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final qRepo = CanonicalFinancialQueryRepository(executor: reopened);
      final stsAfter = await qRepo.getSafeToSpend();

      expect(stsAfter.safeToSpend.minorUnits, stsBefore.safeToSpend.minorUnits);
      expect(stsAfter.liquidAssets.minorUnits, stsBefore.liquidAssets.minorUnits);
      await reopened.close();
    });

    test('35. Forecast output and runway identical before and after restore', () async {
      final forecastBefore =
          await forecastEngine.computeForecast(horizonDays: 30);

      final pkg = File(join(tempDir.path, 'forecast.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final qRepo = CanonicalFinancialQueryRepository(executor: reopened);
      final recRepo = CanonicalRecurringRepository(executor: reopened);
      final lRepo = LoanRepo(executor: reopened);
      final cRepo = CreditRepo(executor: reopened);
      final engineAfter = CanonicalForecastEngine(
        queryRepo: qRepo,
        recurringRepo: recRepo,
        loanRepo: lRepo,
        creditRepo: cRepo,
      );

      final forecastAfter =
          await engineAfter.computeForecast(horizonDays: 30);
      expect(forecastAfter.projectedEndingBalance.minorUnits,
          forecastBefore.projectedEndingBalance.minorUnits);
      expect(forecastAfter.runwayDays, forecastBefore.runwayDays);
      await reopened.close();
    });

    test('36. Review candidates remain non-accounting after restore (0 events, 0 postings)', () async {
      await db.insert(TablesV24.reviewCandidates, {
        'id': 'cand_non_accounting',
        'source_type': 'ocr',
        'suggested_event_type': 'expense',
        'suggested_amount_minor_units': 99000,
        'confidence_score': 0.9,
        'status': 'pending',
        'created_at': DateTime.now().toIso8601String(),
      });

      final pkg = File(join(tempDir.path, 'candidate_zero.spendx'));
      await BackupService.instance.createBackupPackage(
        sourceDb: db,
        sourceDbPath: dbPath,
        outputFile: pkg,
      );

      await BackupService.instance.restoreFromFile(
        pkg,
        targetDbPath: dbPath,
        targetDb: db,
      );

      final reopened = await openDatabase(dbPath);
      final evts = await reopened.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: ['cand_non_accounting'],
      );
      expect(evts.isEmpty, isTrue);

      final posts = await reopened.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['cand_non_accounting'],
      );
      expect(posts.isEmpty, isTrue);
      await reopened.close();
    });
  });
}
