import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/lending_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/reminder_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/lending.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/models/reminder_model.dart';
import 'package:spend_x/models/transaction.dart' as model;
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Canonical Demo Dummy Data & Full Suite Verification', () {
    late Database db;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late LendingRepo lendingRepo;
    late GoalRepo goalRepo;
    late ReminderRepo reminderRepo;
    late TransactionRepo transactionRepo;
    late FinancialTransactionService ftService;
    late CanonicalFinancialQueryRepository queryRepo;

    setUp(() async {
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

      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      lendingRepo = LendingRepo();
      goalRepo = GoalRepo(executor: db);
      reminderRepo = ReminderRepo(database: db);
      transactionRepo = TransactionRepo(executor: db);
      ftService = FinancialTransactionService(
        database: db,
      );
      queryRepo = CanonicalFinancialQueryRepository(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    test('E2E: Seed full realistic financial portfolio and verify calculations', () async {
      final now = DateTime.now();

      // ── 1. Create Bank Accounts & Cash ────────────────────────────────────
      final hdfcId = await accountRepo.insertAccount(
        BankAccount(
          name: 'HDFC Salary Account',
          bank: 'HDFC',
          last4: '1024',
          balance: 65000.0,
          accountType: 'savings',
        ),
      );

      final sbiId = await accountRepo.insertAccount(
        BankAccount(
          name: 'SBI Emergency Fund',
          bank: 'SBI',
          last4: '8842',
          balance: 25000.0,
          accountType: 'savings',
        ),
      );

      final cashId = await accountRepo.insertAccount(
        BankAccount(
          name: 'Cash in Wallet',
          bank: 'Cash',
          balance: 4500.0,
          accountType: 'cash',
        ),
      );

      // Verify accounts and opening balances
      final accounts = await accountRepo.getAll();
      expect(accounts.length, 3);
      final totalLiquidCash = await queryRepo.getLiquidAssets();
      // 65,000 + 25,000 + 4,500 = 94,500
      expect(totalLiquidCash.toRupees, 94500.0);

      // ── 2. Create Credit Cards ───────────────────────────────────────────
      final regaliaId = await creditRepo.insert(
        CreditCard(
          name: 'HDFC Regalia Gold',
          bank: 'HDFC',
          last4: '4545',
          limitAmount: 150000.0,
          usedAmount: 12500.0,
          billingDay: 15,
          dueDay: now.day + 4 > 28 ? 5 : now.day + 4,
          cardType: 'visa',
        ),
      );

      final coralId = await creditRepo.insert(
        CreditCard(
          name: 'ICICI Coral',
          bank: 'ICICI Bank',
          last4: '5007',
          limitAmount: 75000.0,
          usedAmount: 4200.0,
          billingDay: 1,
          dueDay: now.day + 12 > 28 ? 10 : now.day + 12,
          cardType: 'mastercard',
        ),
      );

      final cards = await creditRepo.getAll();
      expect(cards.length, 2);

      // ── 3. Create Home Loan ──────────────────────────────────────────────
      await loanRepo.insertLoan(
        Loan(
          id: 'loan_home_1',
          name: 'SBI Home Loan',
          bank: 'State Bank of India',
          total: 2500000.0,
          interestRate: 8.5,
          tenureMonths: 240,
          monthlyInstallment: 21696.0,
          startDate: now.subtract(const Duration(days: 120)),
          paidAmount: 86784.0,
          loanStatus: 'active',
          dueDay: now.day + 7 > 28 ? 8 : now.day + 7,
          type: LoanType.reducing,
        ),
      );

      final loans = await loanRepo.getLoans();
      expect(loans.length, 1);
      final remainingLoan = loans.first.total - loans.first.paidAmount;
      expect(remainingLoan, 2500000.0 - 86784.0);

      // ── 4. Create Personal Lending & Borrowing ───────────────────────────
      await db.insert(
        'lendings',
        Lending(
          id: 'lend_rahul',
          personName: 'Rahul Sharma',
          type: 'lent',
          originalAmount: 5000.0,
          paidAmount: 0.0,
          date: now.subtract(const Duration(days: 3)),
          dueDate: now.add(const Duration(days: 10)),
        ).toMap(),
      );

      await db.insert(
        'lendings',
        Lending(
          id: 'borrow_amit',
          personName: 'Amit Patel',
          type: 'borrowed',
          originalAmount: 2000.0,
          paidAmount: 0.0,
          date: now.subtract(const Duration(days: 5)),
          dueDate: now.add(const Duration(days: 15)),
        ).toMap(),
      );

      // ── 5. Create Financial Goals ────────────────────────────────────────
      await goalRepo.insert(
        Goal(
          id: 'goal_emergency',
          title: 'Emergency Buffer',
          targetAmount: 100000.0,
          currentAmount: 10000.0,
          type: GoalType.savings,
          startDate: now,
          endDate: now.add(const Duration(days: 180)),
          isActive: true,
        ),
      );

      // ── 6. Create Upcoming Reminders / Commitments (Within 14 Days) ───────
      await reminderRepo.insertGlobalReminder(
        Reminder(
          id: 'rem_electricity',
          title: 'Electricity Bill',
          amount: 2100.0,
          dueDate: now.add(const Duration(days: 6)),
          type: ReminderType.custom,
          status: ReminderStatus.upcoming,
          isActive: true,
        ).toMap(),
      );

      await reminderRepo.insertGlobalReminder(
        Reminder(
          id: 'rem_loan_emi',
          title: 'Home Loan EMI',
          amount: 21696.0,
          dueDate: now.add(const Duration(days: 7)),
          type: ReminderType.loan,
          status: ReminderStatus.upcoming,
          linkedEntityId: 'loan_home_1',
          isActive: true,
        ).toMap(),
      );

      // ── 7. Create Recent Transactions via FinancialTransactionService ────
      // Salary Income
      await ftService.createTransaction(
        model.Transaction(
          userId: 'user_1',
          notes: 'Monthly Salary Credit',
          amount: 85000.0,
          type: 'income',
          accountId: hdfcId,
          categoryId: 'cat_salary',
          date: now.subtract(const Duration(days: 5)),
        ),
      );

      // House Rent
      await ftService.createTransaction(
        model.Transaction(
          userId: 'user_1',
          notes: 'Apartment Rent',
          amount: 22000.0,
          type: 'expense',
          accountId: hdfcId,
          categoryId: 'cat_rent',
          date: now.subtract(const Duration(days: 4)),
        ),
      );

      // Grocery Shopping
      await ftService.createTransaction(
        model.Transaction(
          userId: 'user_1',
          notes: 'Nature Basket Groceries',
          amount: 3450.0,
          type: 'expense',
          accountId: hdfcId,
          categoryId: 'cat_food',
          date: now.subtract(const Duration(days: 2)),
        ),
      );

      // Credit Card Spend
      await ftService.createTransaction(
        model.Transaction(
          userId: 'user_1',
          notes: 'Amazon Electronics',
          amount: 2499.0,
          type: 'expense',
          accountId: regaliaId,
          categoryId: 'cat_shop',
          date: now.subtract(const Duration(days: 1)),
        ),
      );

      // ── 8. Verify Authoritative Ledger State ──────────────────────────────
      final updatedLiquid = await queryRepo.getLiquidAssets();
      // Starting liquid: 94,500 + Salary(85,000) - Rent(22,000) - Groceries(3,450) = 1,54,050
      expect(updatedLiquid.toRupees, 154050.0);

      final totalLiabilities = await queryRepo.getTotalLiabilities();
      // Credit Cards: 12,500 + 4,200 + 2,499 = 19,199
      // Loans: 25,00,000 - 86,784 = 24,13,216
      // Total liabilities = 24,32,415
      expect(totalLiabilities.toRupees, 19199.0 + (2500000.0 - 86784.0));

      // ── 9. Verify Safe to Spend Calculation ───────────────────────────────
      final safeToSpendCalc = await queryRepo.getSafeToSpend();
      expect(safeToSpendCalc.liquidAssets.toRupees, 154050.0);

      // 14-day commitments: Electricity(2,100) + Loan EMI(21,696) + CC Liability(19,199) = 42,995
      expect(safeToSpendCalc.knownCommitments14d.toRupees, 42995.0);

      // Safe to spend = 1,54,050 - 42,995 = 1,11,055
      expect(safeToSpendCalc.safeToSpend.toRupees, 154050.0 - 42995.0);
      expect(safeToSpendCalc.hasShortfall, isFalse);

      // ── 10. Verify Net Worth Calculation ──────────────────────────────────
      final netWorth = await queryRepo.getNetWorth();
      final assets = await queryRepo.getTotalAssets();

      expect(netWorth.toRupees, assets.toRupees - totalLiabilities.toRupees);
      expect(assets.toRupees, 154050.0); // Bank + Cash
    });
  });
}
