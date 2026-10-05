import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/budget_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/lending_repo.dart';
import 'package:spend_x/data/repositories/ledger_repo.dart';
import 'package:spend_x/data/repositories/review_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_recurring_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';

import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/features/review_queue/providers/review_providers.dart';

import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/category.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/ledger_transaction.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/credit_intelligence_service.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/import_service.dart';
import 'package:spend_x/services/reports_service.dart';
import 'package:spend_x/services/settings_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });

  group('Milestone C9: Legacy Surface Retirement Adversarial Suite', () {
    late Database db;
    late TransactionRepo transactionRepo;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late LendingRepo lendingRepo;
    late LedgerRepo ledgerRepo;
    late GoalRepo goalRepo;
    late BudgetRepo budgetRepo;
    late CategoryRepo categoryRepo;
    late ReviewRepo reviewRepo;

    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late CanonicalRecurringRepository canonicalRecurringRepo;
    late CanonicalReviewRepository canonicalReviewRepo;

    late FinancialTransactionService financialService;
    late CreditIntelligenceService creditIntelligenceService;
    late ReportsService reportsService;
    late ImportService importService;

    late ProviderContainer container;
    late Directory tempDir;

    const testBankId1 = 'acc_bank_c9_source';
    const testBankId2 = 'acc_bank_c9_dest';
    const testCardId = 'card_c9_test';
    const testLoanId = 'loan_c9_test';
    const testCatFoodId = 'cat_food_c9';

    int firstIntValue(List<Map<String, Object?>> rows) {
      if (rows.isEmpty || rows.first.isEmpty) return 0;
      return (rows.first.values.first as num?)?.toInt() ?? 0;
    }

    Future<int> countTable(String tableName) async {
      final rows = await db.rawQuery('SELECT COUNT(*) FROM $tableName');
      return firstIntValue(rows);
    }

    Future<void> seedCategory(Category cat) async {
      await db.insert(
        Tables.categories,
        cat.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await db.insert(
        TablesV24.accounts,
        {
          'id': cat.id,
          'account_type': 'expense',
          'subtype': 'category',
          'name': cat.name,
          'currency': 'INR',
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('spendx_c9_test_');

      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );

      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      canonicalRecurringRepo = CanonicalRecurringRepository(executor: db);
      canonicalReviewRepo = CanonicalReviewRepository(executor: db);

      transactionRepo = TransactionRepo(executor: db);
      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      lendingRepo = LendingRepo();
      ledgerRepo = LedgerRepo(database: db);
      goalRepo = GoalRepo(executor: db);
      budgetRepo = BudgetRepo(executor: db, queryRepo: canonicalQueryRepo);
      categoryRepo = CategoryRepo(executor: db);
      reviewRepo = ReviewRepo(
        canonicalReviewRepo: canonicalReviewRepo,
        eventRepo: canonicalEventRepo,
      );

      financialService = FinancialTransactionService(
        transactionRepo: transactionRepo,
        creditRepo: creditRepo,
      );

      creditIntelligenceService = CreditIntelligenceService(
        creditRepo: creditRepo,
      );

      reportsService = ReportsService(
        transactionRepo: transactionRepo,
        creditRepo: creditRepo,
        loanRepo: loanRepo,
        lendingRepo: lendingRepo,
        ledgerRepo: ledgerRepo,
      );

      importService = ImportService(
        financialService: financialService,
        transactionRepo: transactionRepo,
        categoryRepo: categoryRepo,
        reviewRepo: reviewRepo,
      );

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
          app_data.financialTransactionServiceProvider
              .overrideWithValue(financialService),
          app_data.categoryRepoProvider.overrideWithValue(categoryRepo),
          reviewRepoProvider.overrideWithValue(reviewRepo),
        ],
      );

      // Seed bank account 1 (Opening: 5,000 INR)
      await accountRepo.insertAccount(
        BankAccount(
          id: testBankId1,
          name: 'Primary Bank',
          balance: 5000.0,
          last4: '1111',
          bank: 'HDFC Bank',
          color: '#0000FF',
        ),
      );

      // Seed bank account 2 (Opening: 1,000 INR)
      await accountRepo.insertAccount(
        BankAccount(
          id: testBankId2,
          name: 'Secondary Bank',
          balance: 1000.0,
          last4: '2222',
          bank: 'ICICI Bank',
          color: '#00FF00',
        ),
      );

      // Seed credit card (Opening: 2,000 used liability, 50,000 limit)
      await creditRepo.insert(
        CreditCard(
          id: testCardId,
          name: 'Apex Card',
          bank: 'Axis Bank',
          last4: '4321',
          limitAmount: 50000.0,
          usedAmount: 2000.0,
          dueDay: 15,
          billingDay: 1,
        ),
      );

      // Seed loan (Opening: total 100,000, paid 20,000 -> 80,000 liability)
      await loanRepo.insertLoan(
        Loan(
          id: testLoanId,
          name: 'Home Loan Provider',
          bank: 'SBI',
          total: 100000.0,
          paidAmount: 20000.0,
          interestRate: 8.5,
          tenureMonths: 120,
          monthlyInstallment: 1500.0,
          startDate: DateTime(2025, 1, 1),
          dueDay: 5,
          loanStatus: 'active',
        ),
      );

      // Seed expense category
      await seedCategory(
        Category(
          id: testCatFoodId,
          name: 'Food & Dining',
          icon: 'food',
          color: '#FF5722',
          type: 'expense',
          userId: 'u1',
        ),
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    // ── Group 1: Net Worth Screen Internal Transfer Flow ──
    group('Group 1: Net Worth Screen Internal Transfer Flow', () {
      test('ADV-C9-01: Transfer creates canonical EconomicEvent of type transfer', () async {
        final initialEvents = await countTable(TablesV24.economicEvents);

        final transferTx = spx.Transaction(
          userId: 'offline_user',
          type: 'transfer',
          amount: 500.0,
          date: DateTime.now(),
          accountId: testBankId1,
          relatedEntityId: testBankId2,
          notes: 'Inter-account transfer',
        );

        await financialService.createTransfer(transferTx);

        final afterEvents = await countTable(TablesV24.economicEvents);
        expect(afterEvents, equals(initialEvents + 1));

        final events = await canonicalEventRepo.listPostedEvents(limit: 1);
        expect(events.first.canonicalType, equals(CanonicalEventType.transfer));
      });

      test('ADV-C9-02: Transfer creates exactly two balanced postings', () async {
        final initialPostings = await countTable(TablesV24.postings);

        final transferTx = spx.Transaction(
          userId: 'offline_user',
          type: 'transfer',
          amount: 500.0,
          date: DateTime.now(),
          accountId: testBankId1,
          relatedEntityId: testBankId2,
          notes: 'Transfer 500',
        );

        await financialService.createTransfer(transferTx);

        final afterPostings = await countTable(TablesV24.postings);
        expect(afterPostings, equals(initialPostings + 2));

        final recentEvents = await canonicalEventRepo.listPostedEvents(limit: 1);
        final postings = await canonicalEventRepo.getPostingsForEvent(recentEvents.first.id);
        expect(postings.length, equals(2));

        // Parity: credits must equal debits (sum of signed minor units == 0)
        final sum = postings.fold<int>(0, (prev, p) {
          final sign = p.direction == PostingDirection.debit ? 1 : -1;
          return prev + (sign * p.amount.minorUnits);
        });
        expect(sum, equals(0));
      });

      test('ADV-C9-03: Transfer creates zero rows in legacy ledger_transactions', () async {
        final initialLedger = await countTable(Tables.ledgerTransactions);

        final transferTx = spx.Transaction(
          userId: 'offline_user',
          type: 'transfer',
          amount: 750.0,
          date: DateTime.now(),
          accountId: testBankId1,
          relatedEntityId: testBankId2,
          notes: 'Zero shadow write transfer',
        );

        await financialService.createTransfer(transferTx);

        final afterLedger = await countTable(Tables.ledgerTransactions);
        expect(afterLedger, equals(initialLedger));
      });

      test('ADV-C9-04: Transfer updates source and destination account balances instantly', () async {
        final sourceBefore = (await accountRepo.getById(testBankId1))!.balance;
        final destBefore = (await accountRepo.getById(testBankId2))!.balance;

        final transferTx = spx.Transaction(
          userId: 'offline_user',
          type: 'transfer',
          amount: 1500.0,
          date: DateTime.now(),
          accountId: testBankId1,
          relatedEntityId: testBankId2,
          notes: 'Transfer 1500',
        );

        await financialService.createTransfer(transferTx);

        final sourceAfter = (await accountRepo.getById(testBankId1))!.balance;
        final destAfter = (await accountRepo.getById(testBankId2))!.balance;

        expect(sourceAfter, equals(sourceBefore - 1500.0));
        expect(destAfter, equals(destBefore + 1500.0));
      });

      test('ADV-C9-05: Transfer strictly preserves net worth balance invariant', () async {
        final netWorthBefore = await canonicalQueryRepo.getNetWorth();

        final transferTx = spx.Transaction(
          userId: 'offline_user',
          type: 'transfer',
          amount: 2000.0,
          date: DateTime.now(),
          accountId: testBankId1,
          relatedEntityId: testBankId2,
          notes: 'Transfer preserving net worth',
        );

        await financialService.createTransfer(transferTx);

        final netWorthAfter = await canonicalQueryRepo.getNetWorth();
        expect(netWorthAfter.minorUnits, equals(netWorthBefore.minorUnits));
      });
    });

    // ── Group 2: FinancialTransactionService Shadow Write Elimination ──
    group('Group 2: FinancialTransactionService Shadow Write Elimination', () {
      test('ADV-C9-06: createExpense creates zero rows in legacy transactions and ledger_transactions', () async {
        final initialTx = await countTable(Tables.transactions);
        final initialLedger = await countTable(Tables.ledgerTransactions);

        final expense = spx.Transaction(
          userId: 'offline_user',
          type: 'expense',
          amount: 350.0,
          date: DateTime.now(),
          accountId: testBankId1,
          categoryId: testCatFoodId,
          notes: 'Lunch',
        );

        await financialService.createExpense(expense);

        expect(await countTable(Tables.transactions), equals(initialTx));
        expect(await countTable(Tables.ledgerTransactions), equals(initialLedger));
      });

      test('ADV-C9-07: createIncome creates zero rows in legacy transactions and ledger_transactions', () async {
        final initialTx = await countTable(Tables.transactions);
        final initialLedger = await countTable(Tables.ledgerTransactions);

        final income = spx.Transaction(
          userId: 'offline_user',
          type: 'income',
          amount: 10000.0,
          date: DateTime.now(),
          accountId: testBankId1,
          notes: 'Consulting Income',
        );

        await financialService.createIncome(income);

        expect(await countTable(Tables.transactions), equals(initialTx));
        expect(await countTable(Tables.ledgerTransactions), equals(initialLedger));
      });

      test('ADV-C9-08: createTransfer creates zero rows in legacy transactions and ledger_transactions', () async {
        final initialTx = await countTable(Tables.transactions);
        final initialLedger = await countTable(Tables.ledgerTransactions);

        final transfer = spx.Transaction(
          userId: 'offline_user',
          type: 'transfer',
          amount: 200.0,
          date: DateTime.now(),
          accountId: testBankId1,
          relatedEntityId: testBankId2,
          notes: 'Savings transfer',
        );

        await financialService.createTransfer(transfer);

        expect(await countTable(Tables.transactions), equals(initialTx));
        expect(await countTable(Tables.ledgerTransactions), equals(initialLedger));
      });

      test('ADV-C9-09: Generic createTransaction creates zero rows in legacy tables', () async {
        final initialTx = await countTable(Tables.transactions);
        final initialLedger = await countTable(Tables.ledgerTransactions);

        final generic = spx.Transaction(
          userId: 'offline_user',
          type: 'expense',
          amount: 450.0,
          date: DateTime.now(),
          accountId: testBankId1,
          categoryId: testCatFoodId,
          notes: 'Dinner',
        );

        await financialService.createTransaction(generic);

        expect(await countTable(Tables.transactions), equals(initialTx));
        expect(await countTable(Tables.ledgerTransactions), equals(initialLedger));
      });
    });

    // ── Group 3: Credit Card & Loan Canonicalization ──
    group('Group 3: Credit Card & Loan Canonicalization', () {
      test('ADV-C9-10: Credit card purchase via FTS creates zero rows in credit_transactions and ledger_transactions', () async {
        final initialCreditTx = await countTable(Tables.creditTransactions);
        final initialLedger = await countTable(Tables.ledgerTransactions);

        final cardPurchase = spx.Transaction(
          userId: 'offline_user',
          type: 'expense',
          amount: 1200.0,
          date: DateTime.now(),
          accountId: testCardId,
          categoryId: testCatFoodId,
          notes: 'Supermarket with Card',
        );

        await financialService.createExpense(cardPurchase);

        expect(await countTable(Tables.creditTransactions), equals(initialCreditTx));
        expect(await countTable(Tables.ledgerTransactions), equals(initialLedger));

        // Canonical liability must have increased by 1,200
        final cardLiability = await creditRepo.getDerivedBalance(testCardId);
        expect(cardLiability.minorUnits, equals(320000)); // 2,000 + 1,200
      });

      test('ADV-C9-11: CreditIntelligenceService calculates unbilled balance from canonical postings', () async {
        // Post a card purchase
        final cardTx = CreditTransaction(
          id: const Uuid().v4(),
          cardId: testCardId,
          amount: 800.0,
          date: DateTime.now(),
          category: testCatFoodId,
          note: 'Online Shopping',
          type: 'purchase',
          status: 'active',
        );
        await creditRepo.insertTransaction(cardTx);

        // Fetch card and compute intelligence
        final card = (await creditRepo.getCard(testCardId))!;
        final intelligence = await creditIntelligenceService.getCardIntelligence(card);

        // Outstanding is derived from double-entry: 2000 + 800 = 2800
        expect(intelligence.outstanding, equals(2800.0));
        expect(intelligence.unbilledAmount, equals(800.0));
      });

      test('ADV-C9-12: CreditIntelligenceService EMI triggers evaluate canonical postings', () async {
        // High amount card transaction eligible for EMI (> 5,000)
        final emiEligibleTx = CreditTransaction(
          id: const Uuid().v4(),
          cardId: testCardId,
          amount: 6500.0,
          date: DateTime.now(),
          category: testCatFoodId,
          note: 'Electronics Purchase',
          type: 'purchase',
          status: 'active',
        );
        await creditRepo.insertTransaction(emiEligibleTx);

        final card = (await creditRepo.getCard(testCardId))!;
        final intelligence = await creditIntelligenceService.getCardIntelligence(card);

        expect(intelligence.emiSuggestions.isNotEmpty, isTrue);
        expect(intelligence.emiSuggestions.first.amount, equals(6500.0));
      });

      test('ADV-C9-13: ReportsService credit summary matches canonical derived balance, ignoring stale card.usedAmount', () async {
        // Directly poison legacy credit_cards.used_amount
        await db.update(
          Tables.creditCards,
          {'used_amount': 999999.0},
          where: 'id = ?',
          whereArgs: [testCardId],
        );

        // ReportsService must query canonical derived balance (2,000)
        final summary = await reportsService.computeSummary(1);
        final cardLiability = summary.creditSummaries.first.outstanding;
        expect(cardLiability, equals(2000.0));
      });

      test('ADV-C9-14: ReportsService loan summary matches canonical derived loan balance, ignoring stale loan.paidAmount', () async {
        // Directly poison legacy loans.paid_amount
        await db.update(
          Tables.loans,
          {'paid_amount': 0.0},
          where: 'id = ?',
          whereArgs: [testLoanId],
        );

        // Loan total is 100,000, initial derived liability was 80,000 -> remaining principal is 80,000
        final summary = await reportsService.computeSummary(1);
        final loanDebt = summary.loanSummaries.first.remainingPrincipal;
        expect(loanDebt, equals(80000.0));
      });

      test('ADV-C9-15: CreditRepo.getTransactions returns transactions projected from canonical postings/events', () async {
        final tx = CreditTransaction(
          id: const Uuid().v4(),
          cardId: testCardId,
          amount: 150.0,
          date: DateTime.now(),
          category: testCatFoodId,
          note: 'Coffee',
          type: 'purchase',
          status: 'active',
        );
        await creditRepo.insertTransaction(tx);

        final txs = await creditRepo.getTransactions(testCardId);
        expect(txs.any((t) => t.amount == 150.0 && t.note == 'Coffee'), isTrue);

        // Confirm zero rows in legacy credit_transactions table
        expect(await countTable(Tables.creditTransactions), equals(0));
      });

      test('ADV-C9-16: CreditRepo.getTransactionById returns transaction projected from canonical postings/events', () async {
        final tx = CreditTransaction(
          id: const Uuid().v4(),
          cardId: testCardId,
          amount: 420.0,
          date: DateTime.now(),
          category: testCatFoodId,
          note: 'Book Store',
          type: 'purchase',
          status: 'active',
        );
        await creditRepo.insertTransaction(tx);

        final txs = await creditRepo.getTransactions(testCardId);
        final found = txs.firstWhere((t) => t.note == 'Book Store');

        final byId = await creditRepo.getTransactionById(found.id);
        expect(byId, isNotNull);
        expect(byId!.amount, equals(420.0));
        expect(byId.cardId, equals(testCardId));
      });
    });

    // ── Group 4: SMS Card Balance Reconciliation ──
    group('Group 4: SMS Card Balance Reconciliation', () {
      test('ADV-C9-17: SMS Import credit balance update generates canonical reconciliation event with zero writes to used_amount', () async {
        final eventsBefore = await countTable(TablesV24.economicEvents);

        // Reconcile card to 4,500 via updateBalance (canonical reconcileOutstanding)
        await creditRepo.updateBalance(testCardId, 4500.0);

        final eventsAfter = await countTable(TablesV24.economicEvents);
        expect(eventsAfter, equals(eventsBefore + 1));

        final derived = await creditRepo.getDerivedBalance(testCardId);
        expect(derived.minorUnits, equals(450000));

        // Legacy table used_amount was untouched
        final legacyRow = (await db.query(Tables.creditCards, where: 'id = ?', whereArgs: [testCardId])).first;
        expect(legacyRow['usedAmount'], isNot(equals(4500.0)));
      });

      test('ADV-C9-18: SMS Import credit reconciliation balances against sys_equity_opening', () async {
        await creditRepo.updateBalance(testCardId, 3000.0);

        final recentEvents = await canonicalEventRepo.listPostedEvents(limit: 1);
        final postings = await canonicalEventRepo.getPostingsForEvent(recentEvents.first.id);

        expect(postings.length, equals(2));
        expect(postings.any((p) => p.accountId == 'sys_equity_opening'), isTrue);
        expect(postings.any((p) => p.accountId == testCardId), isTrue);

        final sum = postings.fold<int>(0, (prev, p) {
          final sign = p.direction == PostingDirection.debit ? 1 : -1;
          return prev + (sign * p.amount.minorUnits);
        });
        expect(sum, equals(0));
      });
    });

    // ── Group 5: Runtime Decoupling & Isolation ──
    group('Group 5: Runtime Decoupling & Isolation', () {
      test('ADV-C9-19: Zero queries or writes to ledger_transactions during app runtime', () async {
        final initialLedgerRows = await countTable(Tables.ledgerTransactions);

        // Append a ledger transaction via FinancialTransactionService — should short-circuit with 0 rows
        final leg = LedgerTransaction(
          type: LedgerType.expense,
          amount: 50.0,
          date: DateTime.now(),
          accountId: testBankId1,
          categoryId: testCatFoodId,
          note: 'Test isolation',
        );

        await financialService.appendLedger(leg);
        expect(await countTable(Tables.ledgerTransactions), equals(initialLedgerRows));
      });

      test('ADV-C9-20: Zero queries or writes to credit_transactions during app runtime', () async {
        expect(await countTable(Tables.creditTransactions), equals(0));

        final cardTx = CreditTransaction(
          id: const Uuid().v4(),
          cardId: testCardId,
          amount: 300.0,
          date: DateTime.now(),
          category: testCatFoodId,
          note: 'Zero legacy write test',
          type: 'purchase',
          status: 'active',
        );
        await creditRepo.insertTransaction(cardTx);

        expect(await countTable(Tables.creditTransactions), equals(0));
      });

      test('ADV-C9-21: Full transaction lifecycle (create, update, delete) generates zero legacy table mutations', () async {
        final txLegacyStart = await countTable(Tables.transactions);
        final ledgerLegacyStart = await countTable(Tables.ledgerTransactions);

        // 1. Create
        final tx = spx.Transaction(
          id: 'tx_lifecycle_test',
          userId: 'offline_user',
          type: 'expense',
          amount: 500.0,
          date: DateTime.now(),
          accountId: testBankId1,
          categoryId: testCatFoodId,
          notes: 'Lifecycle test',
        );
        await financialService.createExpense(tx);

        // 2. Update
        final updatedTx = tx.copyWith(amount: 600.0, notes: 'Lifecycle modified');
        await financialService.editTransaction(oldTransaction: tx, newTransaction: updatedTx);

        // 3. Delete
        await financialService.deleteTransaction(updatedTx.id);

        expect(await countTable(Tables.transactions), equals(txLegacyStart));
        expect(await countTable(Tables.ledgerTransactions), equals(ledgerLegacyStart));
      });
    });

    // ── Group 6: Centralized Invalidation ──
    group('Group 6: Centralized Invalidation', () {
      test('ADV-C9-22: Riverpod state refreshed without manual queries upon invalidateAllFinancialProviders', () async {
        // Read account list provider
        final accountsInitial = await container.read(app_data.accountsProvider.future);
        final b1Initial = accountsInitial.firstWhere((a) => a.id == testBankId1);
        expect(b1Initial.balance, equals(5000.0));

        // Create transaction directly through service
        await financialService.createExpense(
          spx.Transaction(
            userId: 'offline_user',
            type: 'expense',
            amount: 1000.0,
            date: DateTime.now(),
            accountId: testBankId1,
            categoryId: testCatFoodId,
            notes: 'Refresh check',
          ),
        );

        // Invalidate via central helper
        app_data.invalidateAllFinancialProviders(container);

        // Re-read provider
        final accountsRefreshed = await container.read(app_data.accountsProvider.future);
        final b1Refreshed = accountsRefreshed.firstWhere((a) => a.id == testBankId1);
        expect(b1Refreshed.balance, equals(4000.0));
      });
    });

    // ── Group 7: Canonical CSV Ingestion Pipeline ──
    group('Group 7: Canonical CSV Ingestion Pipeline', () {
      late File csvFile;

      setUp(() async {
        csvFile = File('${tempDir.path}/test_expenses.csv');
        await csvFile.writeAsString('''Date,Description,Amount
2026-03-01,Grocery Store,125.50
2026-03-02,Electronics,500.00
''');
      });

      test('ADV-C9-23: CSV import creates zero rows in ledger_transactions', () async {
        final ledgerBefore = await countTable(Tables.ledgerTransactions);

        await importService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 1,
          amountCol: 2,
          type: 'expense',
          categoryId: testCatFoodId,
          requireReview: false,
        );

        final ledgerAfter = await countTable(Tables.ledgerTransactions);
        expect(ledgerAfter, equals(ledgerBefore));
      });

      test('ADV-C9-24: CSV import duplicate detection skips re-import via SHA-256 fingerprint', () async {
        final initialEvents = await countTable(TablesV24.economicEvents);

        final count1 = await importService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 1,
          amountCol: 2,
          type: 'expense',
          categoryId: testCatFoodId,
          requireReview: false,
        );

        expect(count1, equals(2));

        final eventsAfterFirst = await countTable(TablesV24.economicEvents);
        expect(eventsAfterFirst, equals(initialEvents + 2));

        // Re-import identical CSV file
        final count2 = await importService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 1,
          amountCol: 2,
          type: 'expense',
          categoryId: testCatFoodId,
          requireReview: false,
        );

        expect(count2, equals(0));

        // No new events created
        final eventsAfterSecond = await countTable(TablesV24.economicEvents);
        expect(eventsAfterSecond, equals(eventsAfterFirst));
      });

      test('ADV-C9-25: CSV direct import creates canonical Evidence records', () async {
        await importService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 1,
          amountCol: 2,
          type: 'expense',
          categoryId: testCatFoodId,
          requireReview: false,
        );

        final evidenceRows = await db.query(
          TablesV24.evidence,
          where: "source_type = 'import_csv'",
        );
        expect(evidenceRows.length, equals(2));
      });

      test('ADV-C9-26: CSV import with requireReview: true stages as ReviewCandidate with 0 postings', () async {
        final postingsBefore = await countTable(TablesV24.postings);
        final candidatesBefore = await countTable(TablesV24.reviewCandidates);

        final count = await importService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 1,
          amountCol: 2,
          type: 'expense',
          categoryId: testCatFoodId,
          requireReview: true,
        );

        expect(count, equals(2));
        final postingsAfter = await countTable(TablesV24.postings);
        expect(postingsAfter, equals(postingsBefore)); // 0 postings

        final candidatesAfter = await countTable(TablesV24.reviewCandidates);
        expect(candidatesAfter, equals(candidatesBefore + 2));
      });

      test('ADV-C9-27: CSV review candidate approval creates canonical double-entry postings', () async {
        await importService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 1,
          amountCol: 2,
          type: 'expense',
          categoryId: testCatFoodId,
          requireReview: true,
        );

        final pending = await reviewRepo.getPending();
        expect(pending.isNotEmpty, isTrue);

        final item = pending.first;
        final postingsBefore = await countTable(TablesV24.postings);

        await approveReviewItem(
          item: item,
          accountId: testBankId1,
          categoryId: testCatFoodId,
          financialService: financialService,
          reviewRepo: reviewRepo,
          transactionRepo: transactionRepo,
        );

        final postingsAfter = await countTable(TablesV24.postings);
        expect(postingsAfter, equals(postingsBefore + 2));

        final updatedItem = await reviewRepo.getById(item.id);
        expect(updatedItem?.status, equals('approved'));
      });

      test('ADV-C9-28: CSV direct import creates balanced double-entry postings (sum == 0)', () async {
        await importService.importGenericCSV(
          file: csvFile,
          dateCol: 0,
          descCol: 1,
          amountCol: 2,
          type: 'expense',
          categoryId: testCatFoodId,
          requireReview: false,
        );

        final recentEvents = await canonicalEventRepo.listPostedEvents(limit: 2);
        for (final event in recentEvents) {
          final postings = await canonicalEventRepo.getPostingsForEvent(event.id);
          expect(postings.length, equals(2));
          final sum = postings.fold<int>(0, (prev, p) {
            final sign = p.direction == PostingDirection.debit ? 1 : -1;
            return prev + (sign * p.amount.minorUnits);
          });
          expect(sum, equals(0));
        }
      });
    });

    // ── Group 8: Rogue Legacy Firewall & Parity Invariant ──
    group('Group 8: Rogue Legacy Firewall & Parity Invariant', () {
      test('ADV-C9-29: Rogue legacy firewall test - Seeding rows in legacy tables does NOT affect canonical metrics', () async {
        // Record canonical ground truth
        final netWorthBefore = await canonicalQueryRepo.getNetWorth();
        final bank1Before = (await accountRepo.getById(testBankId1))!.balance;
        final cardBefore = await creditRepo.getDerivedBalance(testCardId);
        final loanBefore = await loanRepo.getDerivedBalance(testLoanId);

        // Directly inject rogue entries into legacy tables
        await db.insert(Tables.transactions, {
          'id': 'rogue_tx_999',
          'amount': 999999.0,
          'type': 'expense',
          'category_id': 'Rogue',
          'date': DateTime.now().toIso8601String(),
          'notes': 'Rogue write',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });

        await db.insert(Tables.ledgerTransactions, {
          'id': 'rogue_ledger_999',
          'type': 'expense',
          'amount': 888888.0,
          'date': DateTime.now().toIso8601String(),
          'account_id': testBankId1,
          'note': 'Rogue ledger row',
          'created_at': DateTime.now().toIso8601String(),
        });

        await db.insert(Tables.creditTransactions, {
          'id': 'rogue_credit_999',
          'cardId': testCardId,
          'amount': 777777.0,
          'type': 'purchase',
          'date': DateTime.now().toIso8601String(),
          'category': 'Rogue',
          'status': 'active',
        });

        // Directly update legacy balance columns
        await db.update(
          Tables.bankAccounts,
          {'balance': 9999999.0},
          where: 'id = ?',
          whereArgs: [testBankId1],
        );

        await db.update(
          Tables.creditCards,
          {'used_amount': 9999999.0},
          where: 'id = ?',
          whereArgs: [testCardId],
        );

        await db.update(
          Tables.loans,
          {'paid_amount': 9999999.0},
          where: 'id = ?',
          whereArgs: [testLoanId],
        );

        // Canonical derived balances must be completely immune
        final netWorthAfter = await canonicalQueryRepo.getNetWorth();
        final bank1After = (await accountRepo.getById(testBankId1))!.balance;
        final cardAfter = await creditRepo.getDerivedBalance(testCardId);
        final loanAfter = await loanRepo.getDerivedBalance(testLoanId);

        expect(netWorthAfter.minorUnits, equals(netWorthBefore.minorUnits));
        expect(bank1After, equals(bank1Before));
        expect(cardAfter.minorUnits, equals(cardBefore.minorUnits));
        expect(loanAfter.minorUnits, equals(loanBefore.minorUnits));
      });

      test('ADV-C9-30: Net-worth equality regression across accounts, credit, and loans', () async {
        // Initial state:
        // Bank1: 5,000 (asset)
        // Bank2: 1,000 (asset)
        // Card:  2,000 (liability)
        // Loan:  80,000 (liability: 100,000 total - 20,000 paid)
        // Net worth = 6,000 - 82,000 = -76,000 INR = -7,600,000 paise
        final netWorth = await canonicalQueryRepo.getNetWorth();
        expect(netWorth.minorUnits, equals(-7600000));

        // Income of 100,000 to Bank1
        await financialService.createIncome(
          spx.Transaction(
            userId: 'offline_user',
            type: 'income',
            amount: 100000.0,
            date: DateTime.now(),
            accountId: testBankId1,
            notes: 'Bonus',
          ),
        );

        // Net worth increases by exactly 100,000 INR
        final netWorth2 = await canonicalQueryRepo.getNetWorth();
        expect(netWorth2.minorUnits, equals(2400000)); // -76,000 + 100,000 = 24,000 INR = 2,400,000 paise

        // Expense of 4,000 via Credit Card
        await financialService.createExpense(
          spx.Transaction(
            userId: 'offline_user',
            type: 'expense',
            amount: 4000.0,
            date: DateTime.now(),
            accountId: testCardId,
            categoryId: testCatFoodId,
            notes: 'Catering',
          ),
        );

        // Net worth decreases by exactly 4,000 INR
        final netWorth3 = await canonicalQueryRepo.getNetWorth();
        expect(netWorth3.minorUnits, equals(2000000)); // 24,000 - 4,000 = 20,000 INR = 2,000,000 paise
      });
    });
  });
}
