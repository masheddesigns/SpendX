import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/lending_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/category.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/lending.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/backup_file_service.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('Generate validated Track 1B canonical backup fixture', () async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();

    final scratchDir = Directory('/Users/sivek/.gemini/antigravity/brain/0b4f624c-ef34-4803-a00a-54c2a352048b/scratch');
    if (!scratchDir.existsSync()) {
      scratchDir.createSync(recursive: true);
    }

    final dbPath = join(scratchDir.path, 'spendx_track1b_synthetic.db');
    final dbFile = File(dbPath);
    if (dbFile.existsSync()) dbFile.deleteSync();

    final db = await openDatabase(
      dbPath,
      version: 24,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
      },
    );

    await Tables.createAll(db);
    await TablesV24.createAllV24(db);
    await TablesV24.seedSystemAccounts(db);
    await TablesV24.installTriggers(db);

    final accountRepo = AccountRepo(executor: db);
    final categoryRepo = CategoryRepo(executor: db);
    final creditRepo = CreditRepo(executor: db);
    final lendingRepo = LendingRepo(executor: db);
    final transactionRepo = TransactionRepo(executor: db);
    final canonicalAccountRepo = CanonicalAccountRepository(executor: db);
    final canonicalEventRepo = CanonicalEventRepository(executor: db);
    final canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
    final financialService = FinancialTransactionService(database: db);

    const sbiAccountId = 'acc_sbi_savings';
    const hdfcCardId = 'card_hdfc_regalia';
    const catSalaryId = 'cat_salary_primary';
    const catGroceriesId = 'cat_groceries';
    const catDiningId = 'cat_dining';

    // 1. Bank Account (SBI Savings)
    await accountRepo.insertAccount(
      BankAccount(
        id: sbiAccountId,
        name: 'SBI Savings Account',
        bank: 'State Bank of India',
        balance: 0.0,
        last4: '1234',
        accountType: 'savings',
      ),
    );

    // 2. Credit Card (HDFC Regalia)
    await creditRepo.insert(
      CreditCard(
        id: hdfcCardId,
        name: 'HDFC Regalia',
        bank: 'HDFC',
        last4: '4321',
        limitAmount: 100000.0,
        usedAmount: 0.0,
        billingDay: 1,
        dueDay: 20,
      ),
    );

    // 3. Categories
    final categories = [
      Category(id: catSalaryId, name: 'Salary', icon: 'salary', color: '#10B981', type: 'income', userId: 'u1'),
      Category(id: catGroceriesId, name: 'Groceries', icon: 'groceries', color: '#F59E0B', type: 'expense', userId: 'u1'),
      Category(id: catDiningId, name: 'Dining & Entertainment', icon: 'dining', color: '#EF4444', type: 'expense', userId: 'u1'),
    ];
    for (final cat in categories) {
      await categoryRepo.insert(cat);
      final nowStr = DateTime.now().toUtc().toIso8601String();
      await db.insert(
        TablesV24.accounts,
        {
          'id': cat.id,
          'account_type': cat.type,
          'subtype': 'category',
          'name': cat.name,
          'currency': 'INR',
          'is_active': 1,
          'is_system': 0,
          'created_at': nowStr,
          'updated_at': nowStr,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    // 4. Peer Lending record (Personal loan: borrowed 50k, repaid 10k, remaining 40k)
    final lendingDate = DateTime.now().subtract(const Duration(days: 30));
    await lendingRepo.insert(
      Lending(
        id: 'lending_personal_01',
        userId: 'u1',
        personName: 'Ramesh Sharma',
        type: 'borrowed',
        originalAmount: 50000.0,
        paidAmount: 10000.0,
        date: lendingDate,
        dueDate: lendingDate.add(const Duration(days: 90)),
        notes: 'Personal emergency loan',
        isSettled: false,
      ),
    );

    // 5. Canonical Transactions & Balanced Postings
    final t1Date = DateTime.now().subtract(const Duration(days: 20));
    await financialService.createTransaction(
      spx.Transaction(
        id: 'tx_opening_balance',
        userId: 'u1',
        type: 'income',
        amount: 25000.0,
        date: t1Date,
        accountId: sbiAccountId,
        categoryId: catSalaryId,
        notes: 'Opening Balance',
      ),
    );

    final t2Date = DateTime.now().subtract(const Duration(days: 15));
    await financialService.createTransaction(
      spx.Transaction(
        id: 'tx_salary_deposit',
        userId: 'u1',
        type: 'income',
        amount: 60000.0,
        date: t2Date,
        accountId: sbiAccountId,
        categoryId: catSalaryId,
        notes: 'Monthly Salary Credit',
      ),
    );

    final t3Date = DateTime.now().subtract(const Duration(days: 10));
    await financialService.createTransaction(
      spx.Transaction(
        id: 'tx_grocery_shopping',
        userId: 'u1',
        type: 'expense',
        amount: 4500.0,
        date: t3Date,
        accountId: sbiAccountId,
        categoryId: catGroceriesId,
        notes: 'Supermarket Groceries',
      ),
    );

    final t4Date = DateTime.now().subtract(const Duration(days: 5));
    await financialService.createTransaction(
      spx.Transaction(
        id: 'ctx_dining_purchase',
        userId: 'u1',
        type: 'expense',
        amount: 12000.0,
        date: t4Date,
        accountId: hdfcCardId,
        categoryId: catDiningId,
        notes: 'Electronics & Dining',
      ),
    );

    // Verify Financial Integrity
    final netWorth = await canonicalQueryRepo.getNetWorth();
    final assets = await canonicalQueryRepo.getTotalAssets();
    final liabilities = await canonicalQueryRepo.getTotalLiabilities();
    final safeToSpend = await canonicalQueryRepo.getSafeToSpend();

    print('--- PRE-FIXTURE FINANCIAL INVARIANTS ---');
    print('ASSETS: ${assets.minorUnits} (${assets.minorUnits / 100})');
    print('LIABILITIES: ${liabilities.minorUnits} (${liabilities.minorUnits / 100})');
    print('NET_WORTH: ${netWorth.minorUnits} (${netWorth.minorUnits / 100})');
    print('SAFE_TO_SPEND: ${safeToSpend.safeToSpend.minorUnits} (${safeToSpend.safeToSpend.minorUnits / 100})');

    expect(assets.minorUnits, equals(8050000)); // ₹80,500.00
    expect(liabilities.minorUnits, equals(1200000)); // ₹12,000.00
    expect(netWorth.minorUnits, equals(6850000)); // ₹68,500.00
    expect(safeToSpend.safeToSpend.minorUnits, equals(6850000)); // ₹68,500.00

    // 6. Generate canonical .spendx package
    final fixturePackageFile = File(join(scratchDir.path, 'spendx_track1b_fixture.spendx'));
    if (fixturePackageFile.existsSync()) fixturePackageFile.deleteSync();

    final (packageFile, manifest) = await BackupService.instance.createBackupPackage(
      sourceDb: db,
      sourceDbPath: dbPath,
      outputFile: fixturePackageFile,
    );

    await db.close();

    final packageBytes = await packageFile.readAsBytes();
    final packageSha256 = sha256.convert(packageBytes).toString();

    print('--- CANONICAL FIXTURE PACKAGE GENERATED ---');
    print('FIXTURE_PATH: ${packageFile.path}');
    print('FIXTURE_SIZE_BYTES: ${packageBytes.length}');
    print('FIXTURE_SHA256: $packageSha256');
    print('MANIFEST_FORMAT_VERSION: ${manifest.formatVersion}');
    print('MANIFEST_SCHEMA_VERSION: ${manifest.schemaVersion}');
    print('MANIFEST_APP_VERSION: ${manifest.appVersion}');
    print('MANIFEST_DEBIT_TOTAL: ${manifest.debitTotal}');
    print('MANIFEST_CREDIT_TOTAL: ${manifest.creditTotal}');
    print('MANIFEST_CANONICAL_EVENTS: ${manifest.canonicalEventCount}');
    print('MANIFEST_POSTINGS: ${manifest.postingCount}');
    print('MANIFEST_RECORD_COUNTS: ${jsonEncode(manifest.recordCounts)}');

    expect(manifest.debitTotal, equals(manifest.creditTotal));
    expect(manifest.debitTotal, greaterThan(0));
    expect(manifest.formatVersion, equals(2));
    expect(manifest.schemaVersion, equals(24));
    expect(await packageFile.exists(), isTrue);

    // 7. Verify package integrity via extractPackage & validateStagedDatabase
    final stagingDir = await Directory.systemTemp.createTemp('spendx_fixture_verify_');
    try {
      final staged = await BackupFileService.instance.extractPackage(
        packageFile: packageFile,
        stagingDir: stagingDir,
      );

      final verifyDb = await openDatabase(
        staged.stagedDbFile.path,
        readOnly: false,
      );
      await CanonicalBackupValidator.validateStagedDatabase(verifyDb, staged.manifest);
      await verifyDb.close();
      print('FIXTURE_INTEGRITY: 100% VALIDATED (SHA-256 MATCH & DOUBLE-ENTRY PARITY CONFIRMED)');
    } finally {
      if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
    }
  });
}
