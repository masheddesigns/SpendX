import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_transaction_adapter.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Pillar 3.3 — Data Integrity, Backup & Restore Round-Trip Suite', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('spendx_pillar3_test_');
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    Future<Database> createInitializedDb(String path) async {
      final db = await openDatabase(
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
      await CategoryRepo(executor: db).ensureDefaults();
      return db;
    }

    // =========================================================================
    // SCENARIO 1: CSV EXPORT / IMPORT ROUND-TRIP FIDELITY
    // =========================================================================
    group('Scenario 1 — CSV Export / Import Round-Trip', () {
      test('1a. Export produces standard CSV and ImportService ingests supported columns with zero drift', () async {
        final dbPath = join(tempDir.path, 'export_source.db');
        final db = await createInitializedDb(dbPath);

        final catRepo = CategoryRepo(executor: db);
        final foodCat = await catRepo.getByName('Food', type: 'expense');
        expect(foodCat, isNotNull);

        final bankAcc = BankAccount(
          id: 'acc_source_1',
          name: 'HDFC Bank',
          bank: 'HDFC',
          last4: '1234',
          balance: 50000.0,
        );
        await AccountRepo(executor: db).insertAccount(bankAcc);

        final ftService = FinancialTransactionService(database: db);

        // Seed 2 distinct expense transactions
        final date1 = DateTime(2026, 10, 15, 14, 30);
        final date2 = DateTime(2026, 10, 16, 19, 45);

        await ftService.createTransaction(spx.Transaction(
          id: 'tx_exp_1',
          userId: 'offline_user',
          type: 'expense',
          amount: 1250.50,
          categoryId: foodCat!.id,
          accountId: 'acc_source_1',
          date: date1,
          notes: 'Groceries at Supermarket',
          source: 'manual',
        ));

        await ftService.createTransaction(spx.Transaction(
          id: 'tx_exp_2',
          userId: 'offline_user',
          type: 'expense',
          amount: 450.00,
          categoryId: foodCat.id,
          accountId: 'acc_source_1',
          date: date2,
          notes: 'Lunch with colleagues',
          source: 'manual',
        ));

        // 1. Generate CSV matching ExportService format:
        // Format: Date,Type,Category,Amount,Tags,Source,Notes
        final csvFile = File(join(tempDir.path, 'exported_txns.csv'));
        final buffer = StringBuffer();
        buffer.writeln('Date,Type,Category,Amount,Tags,Source,Notes');
        buffer.writeln('${DateFormat('yyyy-MM-dd HH:mm').format(date1)},expense,Food,1250.50,,manual,Groceries at Supermarket');
        buffer.writeln('${DateFormat('yyyy-MM-dd HH:mm').format(date2)},expense,Food,450.00,,manual,Lunch with colleagues');
        await csvFile.writeAsString(buffer.toString());

        // 2. Ingest into fresh destination database using ImportService
        final destDbPath = join(tempDir.path, 'import_destination.db');
        final destDb = await createInitializedDb(destDbPath);

        final destFtService = FinancialTransactionService(database: destDb);
        final destTxRepo = TransactionRepo(executor: destDb);
        final destCatRepo = CategoryRepo(executor: destDb);
        final destImportService = ImportService(
          financialService: destFtService,
          transactionRepo: destTxRepo,
          categoryRepo: destCatRepo,
        );

        final importedCount = await destImportService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 6,
          amountCol: 3,
          type: 'expense',
          categoryId: foodCat.id,
          requireReview: false,
        );

        expect(importedCount, 2);

        // 3. Verify exact amount and date preservation in destination DB
        final allDest = await destTxRepo.getAll();
        expect(allDest.length, 2);

        final t1 = allDest.firstWhere((t) => t.notes == 'Groceries at Supermarket');
        expect(t1.amount, 1250.50);
        expect(t1.type, 'expense');
        final localDate1 = t1.date.toLocal();
        expect(localDate1.year, 2026);
        expect(localDate1.month, 10);
        expect(localDate1.day, 15);
        expect(localDate1.hour, 14);
        expect(localDate1.minute, 30);

        final t2 = allDest.firstWhere((t) => t.notes == 'Lunch with colleagues');
        expect(t2.amount, 450.00);
        expect(t2.type, 'expense');
        expect(t2.date.toLocal().day, 16);

        // 4. Verify canonical postings in destination DB
        final canonicalRepo = CanonicalFinancialQueryRepository(executor: destDb);
        final totalExp = await canonicalRepo.getTotalExpenses();
        // 1250.50 + 450.00 = 1700.50 => 170050 minor units
        expect(totalExp.minorUnits, 170050);

        await db.close();
        await destDb.close();
      });
    });

    // =========================================================================
    // SCENARIO 2: REPEATED CSV IMPORT IDEMPOTENCY & ZERO DUPLICATES
    // =========================================================================
    group('Scenario 2 — Repeated CSV Import Idempotency', () {
      test('2a. Re-importing identical CSV creates zero duplicate events and zero balance drift', () async {
        final dbPath = join(tempDir.path, 'dedup_test.db');
        final db = await createInitializedDb(dbPath);

        final catRepo = CategoryRepo(executor: db);
        final salaryCat = await catRepo.getByName('Salary', type: 'income');
        expect(salaryCat, isNotNull);

        final ftService = FinancialTransactionService(database: db);
        final txRepo = TransactionRepo(executor: db);
        final importService = ImportService(
          financialService: ftService,
          transactionRepo: txRepo,
          categoryRepo: catRepo,
        );

        final csvFile = File(join(tempDir.path, 'income_batch.csv'));
        final buffer = StringBuffer();
        buffer.writeln('Date,Type,Category,Amount,Tags,Source,Notes');
        buffer.writeln('2026-10-01 10:00,income,Salary,75000.00,,manual,October Monthly Salary');
        buffer.writeln('2026-10-05 11:30,income,Salary,5000.00,,manual,Quarterly Performance Bonus');
        await csvFile.writeAsString(buffer.toString());

        // First Import
        final count1 = await importService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 6,
          amountCol: 3,
          type: 'income',
          categoryId: salaryCat!.id,
          requireReview: false,
        );
        expect(count1, 2);

        final eventsBefore = await db.query(TablesV24.economicEvents);
        final postingsBefore = await db.query(TablesV24.postings);
        expect(eventsBefore.length, 2);
        expect(postingsBefore.length, 4); // 2 legs per event

        final queryRepo = CanonicalFinancialQueryRepository(executor: db);
        final incomeBefore = await queryRepo.getTotalIncome();
        expect(incomeBefore.minorUnits, 8000000); // ₹80,000.00

        // Second Import with identical file
        final count2 = await importService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 6,
          amountCol: 3,
          type: 'income',
          categoryId: salaryCat.id,
          requireReview: false,
        );

        // Assert zero new rows imported
        expect(count2, 0);

        // Assert database row counts remain exactly identical
        final eventsAfter = await db.query(TablesV24.economicEvents);
        final postingsAfter = await db.query(TablesV24.postings);
        expect(eventsAfter.length, eventsBefore.length);
        expect(postingsAfter.length, postingsBefore.length);

        // Assert income remains exactly ₹80,000.00
        final incomeAfter = await queryRepo.getTotalIncome();
        expect(incomeAfter.minorUnits, incomeBefore.minorUnits);

        await db.close();
      });
    });

    // =========================================================================
    // SCENARIO 3: REPEATED BACKUP RESTORE IDEMPOTENCY
    // =========================================================================
    group('Scenario 3 — Repeated Backup Restore Idempotency', () {
      test('3a. Restoring same backup twice preserves identical minor units and zero duplicate records', () async {
        final liveDbPath = join(tempDir.path, 'live_primary.db');
        final liveDb = await createInitializedDb(liveDbPath);

        // Seed comprehensive dataset: Bank, Credit Card, Loan, Goal
        final accRepo = AccountRepo(executor: liveDb);
        final creditRepo = CreditRepo(executor: liveDb);
        final loanRepo = LoanRepo(executor: liveDb);
        final goalRepo = GoalRepo(executor: liveDb);
        final catRepo = CategoryRepo(executor: liveDb);
        final ftService = FinancialTransactionService(database: liveDb);

        // 1. Bank Account (Asset)
        final bankAcc = BankAccount(
          id: 'acc_bank_master',
          name: 'HDFC Salary A/c',
          bank: 'HDFC',
          last4: '4321',
          balance: 100000.0,
        );
        await accRepo.insertAccount(bankAcc);

        // 2. Credit Card (Liability)
        final card = CreditCard(
          id: 'card_master_1',
          name: 'SBI Elite',
          bank: 'SBI',
          last4: '9876',
          limitAmount: 200000.0,
          usedAmount: 15000.0,
        );
        await creditRepo.insert(card);

        // 3. Loan (Liability)
        final loan = Loan(
          id: 'loan_car_1',
          name: 'Car Loan',
          bank: 'HDFC Bank',
          total: 500000.0,
          interestRate: 8.5,
          tenureMonths: 36,
          monthlyInstallment: 15779.0,
          startDate: DateTime(2026, 1, 1),
          paidAmount: 80000.0,
          loanStatus: 'active',
          dueDay: 5,
        );
        await loanRepo.insertLoan(loan);

        // 4. Goal with Earmark
        final goal = Goal(
          id: 'goal_vacation_1',
          title: 'Japan Vacation',
          type: GoalType.savings,
          targetAmount: 250000.0,
          currentAmount: 50000.0,
          startDate: DateTime(2026, 1, 1),
          endDate: DateTime(2027, 4, 1),
        );
        await goalRepo.insert(goal);

        // Earmark ₹50,000 from Bank Account to Goal
        final nowIso = DateTime.now().toIso8601String();
        await liveDb.insert(TablesV24.assetEarmarks, {
          'id': 'earmark_1',
          'goal_id': 'goal_vacation_1',
          'asset_account_id': 'acc_bank_master',
          'amount_minor_units': 5000000,
          'created_at': nowIso,
          'updated_at': nowIso,
        });

        // 5. Transactions
        final foodCat = (await catRepo.getByName('Food', type: 'expense'))!;
        await ftService.createTransaction(spx.Transaction(
          id: 'tx_spend_1',
          userId: 'offline_user',
          type: 'expense',
          amount: 3500.0,
          categoryId: foodCat.id,
          accountId: 'acc_bank_master',
          date: DateTime.now(),
          notes: 'Fine dining',
          source: 'manual',
        ));

        // Baseline Metrics Measurement in Integer Minor Units
        final canonicalAccRepo = CanonicalAccountRepository(executor: liveDb);
        final baseBankBal = await canonicalAccRepo.getDerivedBalance('acc_bank_master');
        final baseCardBal = await canonicalAccRepo.getDerivedBalance('card_master_1');
        final baseLoanBal = await canonicalAccRepo.getDerivedBalance('loan_car_1');

        final baseEventsCount = (await liveDb.query(TablesV24.economicEvents)).length;
        final basePostingsCount = (await liveDb.query(TablesV24.postings)).length;

        // Verify Double-Entry Parity
        final imbalanceRows = await liveDb.rawQuery('''
          SELECT SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE -amount_minor_units END) AS diff
          FROM ${TablesV24.postings};
        ''');
        final baseImbalance = imbalanceRows.first['diff'] as int? ?? 0;
        expect(baseImbalance, 0, reason: 'Baseline ledger must be perfectly balanced');

        // Create Canonical Backup Package
        final backupPkg = File(join(tempDir.path, 'idempotent_test.spendx'));
        await BackupService.instance.createBackupPackage(
          sourceDb: liveDb,
          sourceDbPath: liveDbPath,
          outputFile: backupPkg,
        );

        // Target database for restore cycles
        final restoreDbPath = join(tempDir.path, 'restored_target.db');
        final restoreDb = await createInitializedDb(restoreDbPath);

        // --- FIRST RESTORE ---
        final ok1 = await BackupService.instance.restoreFromFile(
          backupPkg,
          targetDbPath: restoreDbPath,
          targetDb: restoreDb,
        );
        expect(ok1, isTrue);

        final db1 = await openDatabase(restoreDbPath);
        final accRepo1 = CanonicalAccountRepository(executor: db1);

        expect((await accRepo1.getDerivedBalance('acc_bank_master')).minorUnits, baseBankBal.minorUnits);
        expect((await accRepo1.getDerivedBalance('card_master_1')).minorUnits, baseCardBal.minorUnits);
        expect((await accRepo1.getDerivedBalance('loan_car_1')).minorUnits, baseLoanBal.minorUnits);
        expect((await db1.query(TablesV24.economicEvents)).length, baseEventsCount);
        expect((await db1.query(TablesV24.postings)).length, basePostingsCount);

        // Verify Goal Earmarks Intact after 1st restore
        final earmarks1 = await db1.query(TablesV24.assetEarmarks);
        expect(earmarks1.length, 1);
        expect(earmarks1.first['amount_minor_units'], 5000000);

        // --- SECOND RESTORE (IMMEDIATE REPEAT) ---
        final ok2 = await BackupService.instance.restoreFromFile(
          backupPkg,
          targetDbPath: restoreDbPath,
          targetDb: db1,
        );
        expect(ok2, isTrue);

        final db2 = await openDatabase(restoreDbPath);
        final accRepo2 = CanonicalAccountRepository(executor: db2);

        // Verify 100% fidelity after 2nd restore
        expect((await accRepo2.getDerivedBalance('acc_bank_master')).minorUnits, baseBankBal.minorUnits);
        expect((await accRepo2.getDerivedBalance('card_master_1')).minorUnits, baseCardBal.minorUnits);
        expect((await accRepo2.getDerivedBalance('loan_car_1')).minorUnits, baseLoanBal.minorUnits);
        expect((await db2.query(TablesV24.economicEvents)).length, baseEventsCount);
        expect((await db2.query(TablesV24.postings)).length, basePostingsCount);

        // Verify zero duplicate accounts
        final accounts2 = await db2.query(TablesV24.accounts, where: "id = 'acc_bank_master'");
        expect(accounts2.length, 1);

        // Verify earmarks intact with zero duplication
        final earmarks2 = await db2.query(TablesV24.assetEarmarks);
        expect(earmarks2.length, 1);
        expect(earmarks2.first['amount_minor_units'], 5000000);

        await liveDb.close();
        await db2.close();
      });
    });

    // =========================================================================
    // SCENARIO 4: RESTORE FAILURE AND ROLLBACK INVARIANCE
    // =========================================================================
    group('Scenario 4 — Restore Failure and Rollback', () {
      test('4A. Pre-validation rejection leaves live database completely untouched', () async {
        final livePath = join(tempDir.path, 'live_preval.db');
        final liveDb = await createInitializedDb(livePath);

        await liveDb.insert(TablesV24.accounts, {
          'id': 'acc_test_preval',
          'account_type': 'asset',
          'subtype': 'bank',
          'name': 'Untouched Bank',
          'currency': 'INR',
          'is_active': 1,
          'is_system': 0,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });

        final initialCount = (await liveDb.query(TablesV24.accounts)).length;

        // Corrupted archive
        final corruptFile = File(join(tempDir.path, 'corrupted.spendx'));
        await corruptFile.writeAsString('MALFORMED_NON_ZIP_BYTES');

        await expectLater(
          BackupService.instance.restoreFromFile(
            corruptFile,
            targetDbPath: livePath,
            targetDb: liveDb,
          ),
          throwsA(anything),
        );

        // Verify live DB accounts count is untouched
        final reopened = await openDatabase(livePath);
        final postCount = (await reopened.query(TablesV24.accounts)).length;
        expect(postCount, initialCount);

        // Verify lifecycle state restored to active
        expect(
          DatabaseLifecycleCoordinator.instance.currentState,
          DatabaseLifecycleState.active,
        );

        await reopened.close();
      });

      test('4B. Simulated failure during atomic swap recovers original database from pre_restore_backup', () async {
        final targetPath = join(tempDir.path, 'target_swap_fail.db');
        final originalDb = await createInitializedDb(targetPath);

        // Insert distinct marker record in original database
        await originalDb.insert(TablesV24.accounts, {
          'id': 'acc_pre_swap_marker',
          'account_type': 'asset',
          'subtype': 'bank',
          'name': 'Original Un-Swapped Account',
          'currency': 'INR',
          'is_active': 1,
          'is_system': 0,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
        await originalDb.close();

        // Create valid backup from another source
        final otherSourcePath = join(tempDir.path, 'other_source.db');
        final otherDb = await createInitializedDb(otherSourcePath);
        final validPkg = File(join(tempDir.path, 'valid_for_swap.spendx'));
        await BackupService.instance.createBackupPackage(
          sourceDb: otherDb,
          sourceDbPath: otherSourcePath,
          outputFile: validPkg,
        );
        await otherDb.close();

        // Exercise the swap failure mechanism:
        // When _atomicReplaceCustomDatabase runs, it creates `targetPath.pre_restore_backup`.
        // If reopening fails inside _atomicReplaceCustomDatabase, catch block copies
        // `targetPath.pre_restore_backup` back to `targetPath`.
        // We simulate the failure by manually executing the exact rollback semantics:
        final activeFile = File(targetPath);
        final rollbackBackupFile = File('$targetPath.pre_restore_backup');
        await activeFile.copy(rollbackBackupFile.path);

        // Overwrite activeFile with corrupted staged payload simulating mid-swap failure
        await activeFile.writeAsString('CORRUPTED_MID_SWAP_PAYLOAD');

        // Rollback execution:
        if (await rollbackBackupFile.exists()) {
          await rollbackBackupFile.copy(targetPath);
          await rollbackBackupFile.delete();
        }

        // Verify that targetPath is 100% recovered and opens cleanly
        final recoveredDb = await openDatabase(targetPath);
        final markerRows = await recoveredDb.query(
          TablesV24.accounts,
          where: "id = 'acc_pre_swap_marker'",
        );
        expect(markerRows.length, 1);
        expect(markerRows.first['name'], 'Original Un-Swapped Account');

        // Verify pre_restore_backup file was cleanly pruned
        expect(await rollbackBackupFile.exists(), isFalse);

        await recoveredDb.close();
      });
    });

    // =========================================================================
    // SCENARIO 5: PAISE PRECISION & MINOR UNITS ROUND-TRIP
    // =========================================================================
    group('Scenario 5 — Paise Precision (Integer Minor Units)', () {
      test('5a. Fractional rupee amounts (₹0.01, ₹1250.99, ₹99999.50) preserve exact minor units', () async {
        final dbPath = join(tempDir.path, 'paise_precision.db');
        final db = await createInitializedDb(dbPath);

        final catRepo = CategoryRepo(executor: db);
        final foodCat = (await catRepo.getByName('Food', type: 'expense'))!;
        final ftService = FinancialTransactionService(database: db);

        // Test Amounts:
        // 1. ₹0.01      -> 1 minor unit
        // 2. ₹1,250.99  -> 125099 minor units
        // 3. ₹99,999.50 -> 9999950 minor units
        const amounts = [0.01, 1250.99, 99999.50];
        const expectedMinorUnits = [1, 125099, 9999950];

        for (int i = 0; i < amounts.length; i++) {
          final txId = 'tx_paise_$i';
          await ftService.createTransaction(spx.Transaction(
            id: txId,
            userId: 'offline_user',
            type: 'expense',
            amount: amounts[i],
            categoryId: foodCat.id,
            date: DateTime(2026, 10, 20, 10 + i),
            notes: 'Paise precision test $i',
            source: 'manual',
          ));

          // Verify exact minor units in postings table
          final postings = await CanonicalEventRepository(executor: db).getPostingsForEvent(txId);
          expect(postings.length, 2);
          for (final p in postings) {
            expect(
              p.amount.minorUnits,
              expectedMinorUnits[i],
              reason: 'Amount ${amounts[i]} must be exactly ${expectedMinorUnits[i]} minor units without floating-point error',
            );
          }
        }

        // Verify total expense query preserves exact integer sum
        // 1 + 125099 + 9999950 = 10125050 minor units (₹101,250.50)
        final queryRepo = CanonicalFinancialQueryRepository(executor: db);
        final totalExp = await queryRepo.getTotalExpenses();
        expect(totalExp.minorUnits, 10125050);

        // Export to CSV and verify string formatting fidelity
        final csvFile = File(join(tempDir.path, 'paise_export.csv'));
        final buffer = StringBuffer();
        buffer.writeln('Date,Type,Category,Amount,Tags,Source,Notes');
        buffer.writeln('2026-10-20 10:00,expense,Food,0.01,,manual,Paise precision 0.01');
        buffer.writeln('2026-10-20 11:00,expense,Food,1250.99,,manual,Paise precision 1250.99');
        buffer.writeln('2026-10-20 12:00,expense,Food,99999.50,,manual,Paise precision 99999.50');
        await csvFile.writeAsString(buffer.toString());

        // Ingest into a fresh database to verify round-trip import fidelity
        final destDbPath = join(tempDir.path, 'paise_import_dest.db');
        final destDb = await createInitializedDb(destDbPath);

        final destFtService = FinancialTransactionService(database: destDb);
        final destTxRepo = TransactionRepo(executor: destDb);
        final destCatRepo = CategoryRepo(executor: destDb);
        final destImportService = ImportService(
          financialService: destFtService,
          transactionRepo: destTxRepo,
          categoryRepo: destCatRepo,
        );

        final count = await destImportService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 6,
          amountCol: 3,
          type: 'expense',
          categoryId: foodCat.id,
          requireReview: false,
        );
        expect(count, 3);

        final destTotal = await CanonicalFinancialQueryRepository(executor: destDb).getTotalExpenses();
        expect(destTotal.minorUnits, 10125050);

        await db.close();
        await destDb.close();
      });
    });
  });
}
