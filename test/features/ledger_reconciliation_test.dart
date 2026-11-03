import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/lending_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/lending.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/settings_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });

  group('Pillar 1: Ledger Reconciliation & Accounting Invariants Suite', () {
    late Database db;
    late TransactionRepo transactionRepo;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late LendingRepo lendingRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;

    int firstIntValue(List<Map<String, Object?>> rows) {
      if (rows.isEmpty || rows.first.isEmpty) return 0;
      return (rows.first.values.first as num?)?.toInt() ?? 0;
    }

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );

      // Initialize legacy and canonical schema v24
      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      transactionRepo = TransactionRepo(executor: db);
      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      lendingRepo = LendingRepo();
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 1: REFUND HANDLING (Bank, Credit Card, Multiple Partials, & Sys)
    // ─────────────────────────────────────────────────────────────────────────
    group('Scenario 1: Refund Handling & Contra-Expense Accounting', () {
      test('1a. Bank Purchase -> Partial Refund -> Second Partial Refund returns to baseline', () async {
        final now = DateTime(2026, 11, 1, 10, 0);

        // 1. Create bank account with opening balance ₹50,000.00
        final bank = BankAccount(
          id: 'acc_bank_s1',
          userId: 'offline_user',
          name: 'HDFC Savings',
          bank: 'HDFC',
          balance: 50000.0,
          accountType: 'savings',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // Initial check: 50,000 INR = 5,000,000 paise
        final initialBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_s1');
        expect(initialBal.minorUnits, 5000000);

        // 2. Incur ₹10,000.00 expense in cat_electronics
        final expTx = spx.Transaction(
          id: 'tx_s1_exp',
          userId: 'offline_user',
          amount: 10000.0,
          type: 'expense',
          accountId: 'acc_bank_s1',
          categoryId: 'cat_electronics',
          date: now.add(const Duration(hours: 1)),
          notes: 'Camera purchase',
          source: 'manual',
        );
        await transactionRepo.insert(expTx);

        // Post-purchase checks
        final balAfterBuy = await canonicalAccountRepo.getDerivedBalance('acc_bank_s1');
        expect(balAfterBuy.minorUnits, 4000000); // ₹40,000.00
        final catExpAfterBuy = await canonicalQueryRepo.getCategorySpending('cat_electronics');
        expect(catExpAfterBuy.minorUnits, 1000000); // ₹10,000.00
        final totalExpAfterBuy = await canonicalQueryRepo.getTotalExpenses();
        expect(totalExpAfterBuy.minorUnits, 1000000);

        // 3. First partial refund of ₹3,000.00 to Bank
        final refTx1 = spx.Transaction(
          id: 'tx_s1_ref1',
          userId: 'offline_user',
          amount: 3000.0,
          type: 'refund',
          accountId: 'acc_bank_s1',
          categoryId: 'cat_electronics',
          date: now.add(const Duration(hours: 2)),
          notes: 'Camera partial accessory return',
          source: 'manual',
        );
        await transactionRepo.insert(refTx1);

        final balAfterRef1 = await canonicalAccountRepo.getDerivedBalance('acc_bank_s1');
        expect(balAfterRef1.minorUnits, 4300000); // ₹43,000.00
        final catExpAfterRef1 = await canonicalQueryRepo.getCategorySpending('cat_electronics');
        expect(catExpAfterRef1.minorUnits, 700000); // ₹7,000.00
        final totalExpAfterRef1 = await canonicalQueryRepo.getTotalExpenses();
        expect(totalExpAfterRef1.minorUnits, 700000);

        // 4. Second partial refund of ₹7,000.00 completing 100% reversal
        final refTx2 = spx.Transaction(
          id: 'tx_s1_ref2',
          userId: 'offline_user',
          amount: 7000.0,
          type: 'refund',
          accountId: 'acc_bank_s1',
          categoryId: 'cat_electronics',
          date: now.add(const Duration(hours: 3)),
          notes: 'Camera main unit return',
          source: 'manual',
        );
        await transactionRepo.insert(refTx2);

        // Net checks: Return to baseline exactly
        final balFinal = await canonicalAccountRepo.getDerivedBalance('acc_bank_s1');
        expect(balFinal.minorUnits, 5000000); // Exact baseline: ₹50,000.00
        final catExpFinal = await canonicalQueryRepo.getCategorySpending('cat_electronics');
        expect(catExpFinal.minorUnits, 0); // Exact net expense: ₹0.00
        final totalExpFinal = await canonicalQueryRepo.getTotalExpenses();
        expect(totalExpFinal.minorUnits, 0); // Exact total expense: ₹0.00

        // Invariant: Refunds NEVER register as earned income
        final totalIncome = await canonicalQueryRepo.getTotalIncome();
        expect(totalIncome.minorUnits, 0);
      });

      test('1b. Credit Card Purchase -> Partial Refund -> Remainder Refund', () async {
        final now = DateTime(2026, 11, 1, 12, 0);

        // 1. Create credit card with 0 initial outstanding
        final card = CreditCard(
          id: 'card_s1_cc',
          userId: 'offline_user',
          name: 'Amazon ICICI',
          bank: 'ICICI',
          last4: '1234',
          limitAmount: 100000.0,
          usedAmount: 0.0,
          createdAt: now,
        );
        await creditRepo.insert(card);

        // 2. Card purchase ₹15,000.00
        await creditRepo.insertTransaction(
          CreditTransaction(
            id: 'ctx_s1_buy',
            cardId: 'card_s1_cc',
            amount: 15000.0,
            date: now.add(const Duration(hours: 1)),
            type: 'purchase',
            category: 'Travel',
            categoryId: 'cat_travel',
            status: 'active',
            note: 'Flight ticket',
          ),
        );

        final liabAfterBuy = await creditRepo.getDerivedBalance('card_s1_cc');
        expect(liabAfterBuy.minorUnits, 1500000); // ₹15,000.00 liability
        final expAfterBuy = await canonicalQueryRepo.getTotalExpenses();
        expect(expAfterBuy.minorUnits, 1500000);

        // 3. Partial card refund ₹5,000.00
        await creditRepo.insertTransaction(
          CreditTransaction(
            id: 'ctx_s1_ref1',
            cardId: 'card_s1_cc',
            amount: 5000.0,
            date: now.add(const Duration(hours: 2)),
            type: 'refund',
            category: 'Travel',
            categoryId: 'cat_travel',
            status: 'active',
            note: 'Flight partial refund',
          ),
        );

        final liabAfterRef1 = await creditRepo.getDerivedBalance('card_s1_cc');
        expect(liabAfterRef1.minorUnits, 1000000); // ₹10,000.00 liability
        final expAfterRef1 = await canonicalQueryRepo.getTotalExpenses();
        expect(expAfterRef1.minorUnits, 1000000);

        // 4. Remainder card refund ₹10,000.00
        await creditRepo.insertTransaction(
          CreditTransaction(
            id: 'ctx_s1_ref2',
            cardId: 'card_s1_cc',
            amount: 10000.0,
            date: now.add(const Duration(hours: 3)),
            type: 'refund',
            category: 'Travel',
            categoryId: 'cat_travel',
            status: 'active',
            note: 'Flight full cancellation remainder',
          ),
        );

        final liabFinal = await creditRepo.getDerivedBalance('card_s1_cc');
        expect(liabFinal.minorUnits, 0); // ₹0.00 liability
        final expFinal = await canonicalQueryRepo.getTotalExpenses();
        expect(expFinal.minorUnits, 0); // ₹0.00 net expenses
      });

      test('1c. Refund without explicit category credits sys_exp_refunds', () async {
        final now = DateTime(2026, 11, 1, 14, 0);

        final bank = BankAccount(
          id: 'acc_bank_s1c',
          userId: 'offline_user',
          name: 'SBI Bank',
          bank: 'SBI',
          balance: 20000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // Expense of ₹4,000 in cat_groceries
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s1c_exp',
            userId: 'offline_user',
            amount: 4000.0,
            type: 'expense',
            accountId: 'acc_bank_s1c',
            categoryId: 'cat_groceries',
            date: now.add(const Duration(hours: 1)),
            notes: 'Grocery store',
            source: 'manual',
          ),
        );

        // Refund of ₹1,000 with null categoryId
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s1c_ref_nocat',
            userId: 'offline_user',
            amount: 1000.0,
            type: 'refund',
            accountId: 'acc_bank_s1c',
            categoryId: null, // No explicit category
            date: now.add(const Duration(hours: 2)),
            notes: 'Cashback refund without category',
            source: 'manual',
          ),
        );

        // Total net expenses are properly reduced: 4000 - 1000 = 3000 INR
        final totalExp = await canonicalQueryRepo.getTotalExpenses();
        expect(totalExp.minorUnits, 300000); // ₹3,000.00

        // But specific cat_groceries spending remains 4,000 because refund hit sys_exp_refunds
        final catGroceriesExp = await canonicalQueryRepo.getCategorySpending('cat_groceries');
        expect(catGroceriesExp.minorUnits, 400000);

        // The contra-expense account sys_exp_refunds holds the negative balance
        final sysRefundBal = await canonicalAccountRepo.getDerivedBalance(TablesV24.sysExpRefunds);
        expect(sysRefundBal.minorUnits, -100000); // -₹1,000.00
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 2: CREDIT CARD PURCHASE -> FULL BILL SETTLEMENT
    // ─────────────────────────────────────────────────────────────────────────
    group('Scenario 2: Credit Card Settlement & Zero Double-Expense', () {
      test('Card purchase followed by full settlement does NOT double-count expenses', () async {
        final now = DateTime(2026, 11, 1, 9, 0);

        // Bank: ₹50,000.00 opening balance
        final bank = BankAccount(
          id: 'acc_bank_s2',
          userId: 'offline_user',
          name: 'HDFC Bank',
          bank: 'HDFC',
          balance: 50000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // Credit Card: ₹0.00 initial outstanding
        final card = CreditCard(
          id: 'card_s2',
          userId: 'offline_user',
          name: 'Regalia CC',
          bank: 'HDFC',
          last4: '9999',
          limitAmount: 200000.0,
          usedAmount: 0.0,
          createdAt: now,
        );
        await creditRepo.insert(card);

        final initialNetWorth = await canonicalQueryRepo.getNetWorth();
        expect(initialNetWorth.minorUnits, 5000000); // ₹50,000.00

        // Step 1: Card purchase ₹15,000.00
        final buyTx = spx.Transaction(
          id: 'tx_s2_buy',
          userId: 'offline_user',
          amount: 15000.0,
          type: 'credit_card_purchase',
          accountId: 'card_s2',
          categoryId: 'cat_gadgets',
          date: now.add(const Duration(days: 1)),
          notes: 'Smartphone purchase',
          source: 'credit_card_purchase',
        );
        await transactionRepo.insert(buyTx);

        // Verify Step 1 metrics
        final bankBal1 = await canonicalAccountRepo.getDerivedBalance('acc_bank_s2');
        expect(bankBal1.minorUnits, 5000000); // Bank untouched: ₹50,000.00
        final cardLiab1 = await creditRepo.getDerivedBalance('card_s2');
        expect(cardLiab1.minorUnits, 1500000); // Card debt: ₹15,000.00
        final exp1 = await canonicalQueryRepo.getTotalExpenses();
        expect(exp1.minorUnits, 1500000); // Expense recognized once: ₹15,000.00
        final netWorth1 = await canonicalQueryRepo.getNetWorth();
        expect(netWorth1.minorUnits, 3500000); // Assets 50k - Liab 15k = 35k
        final cashFlow1 = await canonicalQueryRepo.getCashFlow();
        expect(cashFlow1.minorUnits, 0); // ₹0 cash moved

        // Step 2: Full bill payment of ₹15,000.00 from Bank to Card
        final payTx = spx.Transaction(
          id: 'tx_s2_pay',
          userId: 'offline_user',
          amount: 15000.0,
          type: 'credit_payment',
          accountId: 'acc_bank_s2',
          relatedEntityId: 'card_s2',
          date: now.add(const Duration(days: 15)),
          notes: 'Autopay CC bill payment',
          source: 'credit_card_payment',
        );
        await transactionRepo.insert(payTx);

        // Verify Step 2 metrics:
        // CRITICAL INVARIANT: Bill payment MUST NOT be counted as an expense!
        final exp2 = await canonicalQueryRepo.getTotalExpenses();
        expect(exp2.minorUnits, 1500000); // STILL exactly ₹15,000.00, NOT ₹30,000.00!

        // Bank balance decreased
        final bankBal2 = await canonicalAccountRepo.getDerivedBalance('acc_bank_s2');
        expect(bankBal2.minorUnits, 3500000); // ₹35,000.00 (decreased by 15,000)

        // Card liability extinguished
        final cardLiab2 = await creditRepo.getDerivedBalance('card_s2');
        expect(cardLiab2.minorUnits, 0); // EXACTLY ₹0.00

        // Net Worth is unchanged by the settlement itself:
        // Before pay: Assets 50k - Liab 15k = 35k.
        // After pay: Assets 35k - Liab 0 = 35k.
        final netWorth2 = await canonicalQueryRepo.getNetWorth();
        expect(netWorth2.minorUnits, 3500000);

        // Cash flow reflects the actual bank cash outflow
        final cashFlow2 = await canonicalQueryRepo.getCashFlow();
        expect(cashFlow2.minorUnits, -1500000); // -₹15,000.00
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 3: PARTIAL CREDIT CARD BILL SETTLEMENT
    // ─────────────────────────────────────────────────────────────────────────
    group('Scenario 3: Partial Settlement & Residual Liability', () {
      test('Partial card payment reduces liability to exact residual amount', () async {
        final now = DateTime(2026, 11, 1, 10, 0);

        final bank = BankAccount(
          id: 'acc_bank_s3',
          userId: 'offline_user',
          name: 'Kotak Bank',
          bank: 'Kotak',
          balance: 80000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        final card = CreditCard(
          id: 'card_s3',
          userId: 'offline_user',
          name: 'Kotak White CC',
          bank: 'Kotak',
          last4: '4444',
          limitAmount: 150000.0,
          usedAmount: 0.0,
          createdAt: now,
        );
        await creditRepo.insert(card);

        // Card purchase of ₹25,000.00
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s3_buy',
            userId: 'offline_user',
            amount: 25000.0,
            type: 'credit_card_purchase',
            accountId: 'card_s3',
            categoryId: 'cat_appliances',
            date: now.add(const Duration(hours: 1)),
            notes: 'Refrigerator purchase',
          ),
        );

        // Partial payment of ₹10,000.00
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s3_part_pay',
            userId: 'offline_user',
            amount: 10000.0,
            type: 'credit_payment',
            accountId: 'acc_bank_s3',
            relatedEntityId: 'card_s3',
            date: now.add(const Duration(days: 5)),
            notes: 'Partial card bill payment',
          ),
        );

        // Assertions:
        // Remaining liability = 25,000 - 10,000 = 15,000 INR = 1,500,000 paise
        final remainingLiab = await creditRepo.getDerivedBalance('card_s3');
        expect(remainingLiab.minorUnits, 1500000);

        // Bank balance = 80,000 - 10,000 = 70,000 INR = 7,000,000 paise
        final bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_s3');
        expect(bankBal.minorUnits, 7000000);

        // Expense remains strictly ₹25,000.00
        final totalExp = await canonicalQueryRepo.getTotalExpenses();
        expect(totalExp.minorUnits, 2500000);

        // Net Worth = Assets 70k - Liabilities 15k = 55,000 INR
        final netWorth = await canonicalQueryRepo.getNetWorth();
        expect(netWorth.minorUnits, 5500000);
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 4: INTER-ACCOUNT TRANSFER PARITY
    // ─────────────────────────────────────────────────────────────────────────
    group('Scenario 4: Inter-Account Transfer Parity Across Banks', () {
      test('Transfer between Bank A and Bank B preserves total liquid assets and net worth', () async {
        final now = DateTime(2026, 11, 1, 8, 0);

        final bankA = BankAccount(
          id: 'acc_bank_a',
          userId: 'offline_user',
          name: 'HDFC Bank',
          bank: 'HDFC',
          balance: 100000.0, // 100,000 INR
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bankA);

        final bankB = BankAccount(
          id: 'acc_bank_b',
          userId: 'offline_user',
          name: 'SBI Bank',
          bank: 'SBI',
          balance: 20000.0, // 20,000 INR
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bankB);

        // Before transfer
        final initialAssets = await canonicalQueryRepo.getLiquidAssets();
        expect(initialAssets.minorUnits, 12000000); // 120,000 INR
        final initialNetWorth = await canonicalQueryRepo.getNetWorth();
        expect(initialNetWorth.minorUnits, 12000000);

        // Transfer ₹35,000.00 from Bank A to Bank B
        final transferTx = spx.Transaction(
          id: 'tx_s4_xfer',
          userId: 'offline_user',
          amount: 35000.0,
          type: 'transfer',
          accountId: 'acc_bank_a',
          relatedEntityId: 'acc_bank_b',
          date: now.add(const Duration(hours: 2)),
          notes: 'Fund transfer to SBI',
        );
        await transactionRepo.insert(transferTx);

        // Individual account checks
        final balA = await canonicalAccountRepo.getDerivedBalance('acc_bank_a');
        expect(balA.minorUnits, 6500000); // 100,000 - 35,000 = 65,000 INR
        final balB = await canonicalAccountRepo.getDerivedBalance('acc_bank_b');
        expect(balB.minorUnits, 5500000); // 20,000 + 35,000 = 55,000 INR

        // Parity invariants
        final totalLiquid = await canonicalQueryRepo.getLiquidAssets();
        expect(totalLiquid.minorUnits, 12000000); // Exactly unchanged: 120,000 INR
        final netWorth = await canonicalQueryRepo.getNetWorth();
        expect(netWorth.minorUnits, 12000000); // Exactly unchanged
        final cashFlow = await canonicalQueryRepo.getCashFlow();
        expect(cashFlow.minorUnits, 0); // Transfer generates ₹0 net cash flow
        final expenses = await canonicalQueryRepo.getTotalExpenses();
        expect(expenses.minorUnits, 0); // Transfer is NOT an expense
        final income = await canonicalQueryRepo.getTotalIncome();
        expect(income.minorUnits, 0); // Transfer is NOT income
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 5: FULL TRANSACTION LIFECYCLE & IMMUTABLE REVERSAL HISTORY
    // ─────────────────────────────────────────────────────────────────────────
    group('Scenario 5: Transaction Create -> Edit -> Delete Lifecycle', () {
      test('Lifecycle creates immutable reversal history and restores exact baseline', () async {
        final now = DateTime(2026, 11, 1, 10, 0);

        final bank = BankAccount(
          id: 'acc_bank_s5',
          userId: 'offline_user',
          name: 'Axis Bank',
          bank: 'Axis',
          balance: 50000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // 1. Create expense ₹6,000 in cat_dining
        final tx = spx.Transaction(
          id: 'tx_s5_lifecycle',
          userId: 'offline_user',
          amount: 6000.0,
          type: 'expense',
          accountId: 'acc_bank_s5',
          categoryId: 'cat_dining',
          date: now.add(const Duration(hours: 1)),
          notes: 'Dinner with team',
        );
        await transactionRepo.insert(tx);

        final bal1 = await canonicalAccountRepo.getDerivedBalance('acc_bank_s5');
        expect(bal1.minorUnits, 4400000); // 44,000 INR
        final dining1 = await canonicalQueryRepo.getCategorySpending('cat_dining');
        expect(dining1.minorUnits, 600000); // 6,000 INR

        // 2. Edit expense: change amount to ₹8,000 and category to cat_groceries
        final editedTx = tx.copyWith(
          amount: 8000.0,
          categoryId: 'cat_groceries',
          notes: 'Correction: actually groceries',
        );
        await transactionRepo.update(editedTx);

        final bal2 = await canonicalAccountRepo.getDerivedBalance('acc_bank_s5');
        expect(bal2.minorUnits, 4200000); // 50,000 - 8,000 = 42,000 INR
        final dining2 = await canonicalQueryRepo.getCategorySpending('cat_dining');
        expect(dining2.minorUnits, 0); // Dining neutralized to 0
        final groceries2 = await canonicalQueryRepo.getCategorySpending('cat_groceries');
        expect(groceries2.minorUnits, 800000); // Groceries becomes 8,000

        // Fetch the currently active transaction from the repository.
        // TransactionRepo.update created a replacement event with ID "${tx.id}:corr:<timestamp>".
        final activeTxList = await transactionRepo.getAll();
        final currentActiveTx = activeTxList.firstWhere((t) => t.id.startsWith(tx.id));

        // 3. Delete the currently active transaction
        await transactionRepo.delete(currentActiveTx.id);

        // Assert baseline is 100% restored
        final balFinal = await canonicalAccountRepo.getDerivedBalance('acc_bank_s5');
        expect(balFinal.minorUnits, 5000000); // Exactly restored: ₹50,000.00
        final diningFinal = await canonicalQueryRepo.getCategorySpending('cat_dining');
        expect(diningFinal.minorUnits, 0); // Neutralized: ₹0.00
        final groceriesFinal = await canonicalQueryRepo.getCategorySpending('cat_groceries');
        expect(groceriesFinal.minorUnits, 0); // Neutralized: ₹0.00
        final totalExpFinal = await canonicalQueryRepo.getTotalExpenses();
        expect(totalExpFinal.minorUnits, 0); // Overall expenses: ₹0.00

        // Verify native SQLite immutability:
        // No posted events were deleted in place; history was preserved via reversal
        final eventCount = firstIntValue(
          await db.rawQuery("SELECT COUNT(*) FROM ${TablesV24.economicEvents}"),
        );
        // Expect at least 4 events: opening balance + original + reversal of orig + replacement + reversal of replacement
        expect(eventCount, greaterThanOrEqualTo(4));
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 6: LOAN DISBURSEMENT & COMBINED EMI (Principal vs Interest)
    // ─────────────────────────────────────────────────────────────────────────
    group('Scenario 6: Loan Principal & Interest Independent Accounting', () {
      test('EMI repayment reduces debt principal while interest is recognized as expense', () async {
        final now = DateTime(2026, 11, 1, 9, 0);

        final bank = BankAccount(
          id: 'acc_bank_s6',
          userId: 'offline_user',
          name: 'HDFC Salary Acc',
          bank: 'HDFC',
          balance: 30000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        final loan = Loan(
          id: 'loan_s6_car',
          name: 'HDFC Car Loan',
          bank: 'HDFC',
          total: 500000.0, // ₹5,00,000.00 principal
          interestRate: 8.5,
          tenureMonths: 60,
          monthlyInstallment: 10258.0,
          startDate: now,
          paidAmount: 0.0,
          loanStatus: 'active',
          dueDay: 5,
        );
        await loanRepo.insertLoan(loan);

        // Initial check: Loan liability is 5,00,000 INR
        final initialDebt = await loanRepo.getDerivedBalance('loan_s6_car');
        expect(initialDebt.minorUnits, 50000000);

        // Record Combined EMI Payment of ₹10,000:
        // Principal: ₹7,500.00, Interest: ₹2,500.00
        // Bank cash outflow: ₹10,000.00
        await loanRepo.recordCombinedPayment(
          loanId: 'loan_s6_car',
          assetAccountId: 'acc_bank_s6',
          principalAmount: 7500.0,
          interestAmount: 2500.0,
          timestamp: now.add(const Duration(days: 30)),
          description: 'Car Loan EMI 1',
        );

        // 1. Bank cash decreases by FULL EMI ₹10,000.00: 30k - 10k = 20k
        final bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_s6');
        expect(bankBal.minorUnits, 2000000); // 20,000 INR

        // 2. Loan principal liability decreases ONLY by principal ₹7,500.00:
        // 500,000 - 7,500 = 492,500 INR = 49,250,000 paise
        final remainingDebt = await loanRepo.getDerivedBalance('loan_s6_car');
        expect(remainingDebt.minorUnits, 49250000);

        // 3. Interest expense recognized ONLY for interest portion ₹2,500.00
        final interestExp = await canonicalAccountRepo.getDerivedBalance(TablesV24.sysExpInterest);
        expect(interestExp.minorUnits, 250000); // 2,500 INR = 250,000 paise

        // 4. Total expenses for period is STRICTLY ₹2,500.00 (Principal is NOT an expense)
        final totalExp = await canonicalQueryRepo.getTotalExpenses();
        expect(totalExp.minorUnits, 250000);

        // 5. Net worth impact:
        // Before EMI: Assets 30k - Liabilities 500k = -470,000 INR
        // After EMI: Assets 20k - Liabilities 492.5k = -472,500 INR
        // Net worth decreases by EXACTLY ₹2,500.00 (the interest expense)
        final netWorth = await canonicalQueryRepo.getNetWorth();
        expect(netWorth.minorUnits, -47250000);
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 7: SUSPENSE ACCOUNT ISOLATION
    // ─────────────────────────────────────────────────────────────────────────
    group('Scenario 7: Suspense Account Isolation from Liquid Cash & Safe-to-Spend', () {
      test('Unresolved debit creates negative suspense balance but is excluded from liquid cash', () async {
        final now = DateTime(2026, 11, 1, 10, 0);

        // Bank Account with ₹40,000 liquid cash
        final bank = BankAccount(
          id: 'acc_bank_s7',
          userId: 'offline_user',
          name: 'SBI Operating',
          bank: 'SBI',
          balance: 40000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // Ingest unresolvable SMS debit of ₹3,000 (accountId is null, routes to sys_suspense_transfer)
        final unlinkedTx = spx.Transaction(
          id: 'tx_s7_suspense',
          userId: 'offline_user',
          amount: 3000.0,
          type: 'expense',
          accountId: null, // Unknown instrument
          categoryId: 'cat_misc',
          date: now.add(const Duration(hours: 1)),
          notes: 'Unrecognized SMS transaction',
          source: 'sms',
        );
        await transactionRepo.insert(unlinkedTx);

        // 1. Suspense account derived balance is -₹3,000.00 (-300,000 paise)
        final suspenseBal = await canonicalAccountRepo.getDerivedBalance(TablesV24.sysSuspenseTransfer);
        expect(suspenseBal.minorUnits, -300000);

        // 2. Liquid assets strictly excludes suspense accounts: remains ₹40,000.00
        final liquidAssets = await canonicalQueryRepo.getLiquidAssets();
        expect(liquidAssets.minorUnits, 4000000); // 40,000 INR

        // 3. Safe-to-Spend is NOT depleted by the unresolved suspense balance
        final safeToSpend = await canonicalQueryRepo.getSafeToSpend();
        expect(safeToSpend.safeToSpend.minorUnits, 4000000); // Exactly ₹40,000.00
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 8: FORENSIC DEDUPLICATION VIA SHA-256 / EXTERNAL REFERENCES
    // ─────────────────────────────────────────────────────────────────────────
    group('Scenario 8: External Reference Deduplication', () {
      test('Duplicate external references are rejected or deduplicated', () async {
        final now = DateTime(2026, 11, 1, 11, 0);

        final bank = BankAccount(
          id: 'acc_bank_s8',
          userId: 'offline_user',
          name: 'ICICI Bank',
          bank: 'ICICI',
          balance: 20000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        const refKey = 'UPI/20261101/987654321/ICICI';

        final tx1 = spx.Transaction(
          id: 'tx_s8_first',
          userId: 'offline_user',
          amount: 1500.0,
          type: 'expense',
          accountId: 'acc_bank_s8',
          categoryId: 'cat_food',
          date: now,
          notes: 'Lunch at Cafe',
          externalRef: refKey,
          source: 'sms',
        );
        await transactionRepo.insert(tx1);

        // First insert succeeds and registers externalRef in Evidence
        final exists = await transactionRepo.existsByExternalRef(refKey);
        expect(exists, isTrue);

        // Attempting batch or duplicate insert skips the second transaction
        final tx2Duplicate = spx.Transaction(
          id: 'tx_s8_duplicate',
          userId: 'offline_user',
          amount: 1500.0,
          type: 'expense',
          accountId: 'acc_bank_s8',
          categoryId: 'cat_food',
          date: now,
          notes: 'Duplicate SMS delivery',
          externalRef: refKey,
          source: 'sms',
        );

        final inserted = await transactionRepo.insertAllReturningRefsWithTxn(
          db,
          [tx2Duplicate],
        );
        expect(inserted, isEmpty); // Skipped duplicate

        // Bank balance reduced ONLY once by ₹1,500.00: 20,000 - 1,500 = 18,500 INR
        final bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_s8');
        expect(bankBal.minorUnits, 1850000);

        // Different reference is accepted
        const refKey2 = 'UPI/20261101/111222333/ICICI';
        final tx3Different = spx.Transaction(
          id: 'tx_s8_distinct',
          userId: 'offline_user',
          amount: 500.0,
          type: 'expense',
          accountId: 'acc_bank_s8',
          categoryId: 'cat_food',
          date: now.add(const Duration(hours: 1)),
          notes: 'Coffee',
          externalRef: refKey2,
          source: 'sms',
        );
        final inserted2 = await transactionRepo.insertAllReturningRefsWithTxn(
          db,
          [tx3Different],
        );
        expect(inserted2, contains(refKey2));

        final bankBalAfterDistinct = await canonicalAccountRepo.getDerivedBalance('acc_bank_s8');
        expect(bankBalAfterDistinct.minorUnits, 1800000); // 18,000 INR
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 9: GLOBAL MATHEMATICAL CONSERVATION (Multi-Day Interleaved)
    // ─────────────────────────────────────────────────────────────────────────
    group('Scenario 9: Multi-Day Interleaved Global Conservation', () {
      test('Multi-day complex transaction sequence maintains exact mathematical conservation', () async {
        final d1 = DateTime(2026, 11, 1, 9, 0);

        // 1. Initial Position:
        // Bank 1 (HDFC): ₹1,00,000.00
        // Bank 2 (ICICI): ₹50,000.00
        // Credit Card 1 (OneCard): ₹0.00
        // Credit Card 2 (Axis): ₹0.00
        // Loan (SBI Car Loan): ₹4,00,000.00
        await accountRepo.insertAccount(
          BankAccount(
            id: 'acc_hdfc',
            userId: 'offline_user',
            name: 'HDFC Bank',
            bank: 'HDFC',
            balance: 100000.0,
            createdAt: d1,
            updatedAt: d1,
          ),
        );
        await accountRepo.insertAccount(
          BankAccount(
            id: 'acc_icici',
            userId: 'offline_user',
            name: 'ICICI Bank',
            bank: 'ICICI',
            balance: 50000.0,
            createdAt: d1,
            updatedAt: d1,
          ),
        );
        await creditRepo.insert(
          CreditCard(
            id: 'card_onecard',
            userId: 'offline_user',
            name: 'OneCard Metal',
            bank: 'Federal',
            last4: '1111',
            limitAmount: 100000.0,
            usedAmount: 0.0,
            createdAt: d1,
          ),
        );
        await creditRepo.insert(
          CreditCard(
            id: 'card_axis',
            userId: 'offline_user',
            name: 'Axis Flipkart',
            bank: 'Axis',
            last4: '2222',
            limitAmount: 80000.0,
            usedAmount: 0.0,
            createdAt: d1,
          ),
        );
        await loanRepo.insertLoan(
          Loan(
            id: 'loan_sbi_car',
            name: 'SBI Car Loan',
            bank: 'SBI',
            total: 400000.0,
            interestRate: 8.0,
            tenureMonths: 48,
            monthlyInstallment: 9765.0,
            startDate: d1,
            paidAmount: 0.0,
            loanStatus: 'active',
            dueDay: 5,
          ),
        );

        // Record a peer lending entry in the database (verifying it remains outside double-entry)
        await db.insert(
          Tables.lendings,
          Lending(
            id: 'lend_friend_bob',
            personName: 'Bob',
            type: 'lent',
            originalAmount: 5000.0,
            date: d1,
            notes: 'Friendly loan outside bank ledger',
          ).toMap(),
        );

        // Sequence of 7 multi-day operations:
        // Op 1: Day 1 - Salary Income ₹80,000.00 into HDFC
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_seq_salary',
            userId: 'offline_user',
            amount: 80000.0,
            type: 'income',
            accountId: 'acc_hdfc',
            categoryId: 'cat_salary',
            date: d1.add(const Duration(hours: 1)),
            notes: 'Monthly Salary',
          ),
        );

        // Op 2: Day 2 - OneCard purchase ₹12,000.00 (Shopping)
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_seq_buy1',
            userId: 'offline_user',
            amount: 12000.0,
            type: 'credit_card_purchase',
            accountId: 'card_onecard',
            categoryId: 'cat_shopping',
            date: d1.add(const Duration(days: 1)),
            notes: 'Clothes shopping',
          ),
        );

        // Op 3: Day 3 - Axis Card purchase ₹6,000.00 (Electronics)
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_seq_buy2',
            userId: 'offline_user',
            amount: 6000.0,
            type: 'credit_card_purchase',
            accountId: 'card_axis',
            categoryId: 'cat_electronics',
            date: d1.add(const Duration(days: 2)),
            notes: 'Headphones',
          ),
        );

        // Op 4: Day 4 - Transfer ₹20,000.00 from HDFC to ICICI
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_seq_xfer',
            userId: 'offline_user',
            amount: 20000.0,
            type: 'transfer',
            accountId: 'acc_hdfc',
            relatedEntityId: 'acc_icici',
            date: d1.add(const Duration(days: 3)),
            notes: 'Savings transfer',
          ),
        );

        // Op 5: Day 5 - Full OneCard payment of ₹12,000.00 from ICICI
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_seq_pay_onecard',
            userId: 'offline_user',
            amount: 12000.0,
            type: 'credit_payment',
            accountId: 'acc_icici',
            relatedEntityId: 'card_onecard',
            date: d1.add(const Duration(days: 4)),
            notes: 'Pay OneCard bill',
          ),
        );

        // Op 6: Day 6 - Partial refund of ₹2,000.00 on Axis Card (returned item)
        await creditRepo.insertTransaction(
          CreditTransaction(
            id: 'ctx_seq_refund_axis',
            cardId: 'card_axis',
            amount: 2000.0,
            date: d1.add(const Duration(days: 5)),
            type: 'refund',
            category: 'Electronics',
            categoryId: 'cat_electronics',
            status: 'active',
            note: 'Headphones accessory refund',
          ),
        );

        // Op 7: Day 7 - Car Loan EMI of ₹9,765.00 from HDFC (Principal ₹7,098.00, Interest ₹2,667.00)
        await loanRepo.recordCombinedPayment(
          loanId: 'loan_sbi_car',
          assetAccountId: 'acc_hdfc',
          principalAmount: 7098.0,
          interestAmount: 2667.0,
          timestamp: d1.add(const Duration(days: 6)),
          description: 'SBI Car Loan EMI 1',
        );

        // ─────────────────────────────────────────────────────────────────────
        // INDEPENDENT EXPECTED VALUE CALCULATIONS (Ground Truth):
        // ─────────────────────────────────────────────────────────────────────
        // HDFC:
        // Initial: 100,000
        // + Salary: 80,000
        // - Transfer to ICICI: 20,000
        // - Loan EMI: 9,765
        // Expected HDFC = 100,000 + 80,000 - 20,000 - 9,765 = 150,235 INR = 15,023,500 paise
        const expectedHdfcPaise = 15023500;

        // ICICI:
        // Initial: 50,000
        // + Transfer from HDFC: 20,000
        // - OneCard payment: 12,000
        // Expected ICICI = 50,000 + 20,000 - 12,000 = 58,000 INR = 5,800,000 paise
        const expectedIciciPaise = 5800000;

        // OneCard:
        // Purchase: 12,000
        // Payment: -12,000
        // Expected OneCard Liability = 0 paise
        const expectedOneCardPaise = 0;

        // Axis Card:
        // Purchase: 6,000
        // Refund: -2,000
        // Expected Axis Liability = 4,000 INR = 400,000 paise
        const expectedAxisPaise = 400000;

        // Loan:
        // Initial: 400,000
        // Principal Repaid: -7,098
        // Expected Loan Principal = 400,000 - 7,098 = 392,902 INR = 39,290,200 paise
        const expectedLoanPaise = 39290200;

        // Total Assets:
        // HDFC (150,235) + ICICI (58,000) = 208,235 INR = 20,823,500 paise
        const expectedTotalAssetsPaise = 20823500;

        // Total Liabilities:
        // OneCard (0) + Axis (4,000) + Loan (392,902) = 396,902 INR = 39,690,200 paise
        const expectedTotalLiabilitiesPaise = 39690200;

        // Net Worth:
        // Total Assets (208,235) - Total Liabilities (396,902) = -188,667 INR = -18,866,700 paise
        const expectedNetWorthPaise = -18866700;

        // Income:
        // Salary = 80,000 INR = 8,000,000 paise
        const expectedIncomePaise = 8000000;

        // Expenses:
        // Shopping (12,000) + Electronics net (6,000 - 2,000 = 4,000) + Interest (2,667)
        // Expected Expenses = 12,000 + 4,000 + 2,667 = 18,667 INR = 1,866,700 paise
        const expectedExpensesPaise = 1866700;

        // Physical Cash Flow:
        // Bank Inflows: Salary (+80,000)
        // Bank Outflows: OneCard bill (-12,000), Car Loan EMI (-9,765)
        // Transfer between HDFC & ICICI net cash flow: 0
        // Expected Net Cash Flow = 80,000 - 12,000 - 9,765 = 58,235 INR = 5,823,500 paise
        const expectedCashFlowPaise = 5823500;

        // ─────────────────────────────────────────────────────────────────────
        // RUN ASSERTIONS AGAINST REPOSITORIES:
        // ─────────────────────────────────────────────────────────────────────
        final actualHdfc = await canonicalAccountRepo.getDerivedBalance('acc_hdfc');
        expect(actualHdfc.minorUnits, expectedHdfcPaise);

        final actualIcici = await canonicalAccountRepo.getDerivedBalance('acc_icici');
        expect(actualIcici.minorUnits, expectedIciciPaise);

        final actualOneCard = await creditRepo.getDerivedBalance('card_onecard');
        expect(actualOneCard.minorUnits, expectedOneCardPaise);

        final actualAxis = await creditRepo.getDerivedBalance('card_axis');
        expect(actualAxis.minorUnits, expectedAxisPaise);

        final actualLoan = await loanRepo.getDerivedBalance('loan_sbi_car');
        expect(actualLoan.minorUnits, expectedLoanPaise);

        final actualAssets = await canonicalQueryRepo.getTotalAssets();
        expect(actualAssets.minorUnits, expectedTotalAssetsPaise);

        final actualLiabilities = await canonicalQueryRepo.getTotalLiabilities();
        expect(actualLiabilities.minorUnits, expectedTotalLiabilitiesPaise);

        final actualNetWorth = await canonicalQueryRepo.getNetWorth();
        expect(actualNetWorth.minorUnits, expectedNetWorthPaise);

        final actualIncome = await canonicalQueryRepo.getTotalIncome();
        expect(actualIncome.minorUnits, expectedIncomePaise);

        final actualExpenses = await canonicalQueryRepo.getTotalExpenses();
        expect(actualExpenses.minorUnits, expectedExpensesPaise);

        final actualCashFlow = await canonicalQueryRepo.getCashFlow();
        expect(actualCashFlow.minorUnits, expectedCashFlowPaise);

        // Safe-to-Spend equals liquid assets when no 14d obligations remain
        final actualSafeToSpend = await canonicalQueryRepo.getSafeToSpend();
        expect(actualSafeToSpend.liquidAssets.minorUnits, expectedTotalAssetsPaise);

        // Peer lending remains completely outside double-entry ledger
        final lendingRows = await db.query(Tables.lendings);
        expect(lendingRows.length, 1);
        final lendingPostings = await db.rawQuery(
          "SELECT COUNT(*) FROM ${TablesV24.postings} WHERE account_id LIKE '%bob%'",
        );
        expect(firstIntValue(lendingPostings), 0);

        // Fundamental Double-Entry Accounting Conservation Check:
        // Sum(All Debits) - Sum(All Credits) across all postings in database MUST BE ZERO
        final conservationSum = firstIntValue(
          await db.rawQuery('''
            SELECT COALESCE(
              SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE -amount_minor_units END), 0
            )
            FROM ${TablesV24.postings} p
            JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
            WHERE e.lifecycle_status = 'posted';
          '''),
        );
        expect(conservationSum, 0);

        // Fundamental Balance Equation Check:
        // Net Worth = Base Equity + (Income - Expenses)
        // Base Equity = Initial Assets (150,000) - Initial Liabilities (400,000) = -250,000 INR
        // Retained Earnings = Income (80,000) - Expenses (18,667) = +61,333 INR
        // Net Worth = -250,000 + 61,333 = -188,667 INR!
        final baseEquity = await canonicalQueryRepo.getBaseEquity();
        expect(baseEquity.minorUnits, -25000000);
        final totalEquity = await canonicalQueryRepo.getTotalEquity();
        expect(totalEquity.minorUnits, expectedNetWorthPaise);
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 10: REMEDIATION VERIFICATION — getStatsForRange() & IDEMPOTENT DELETE
    // ─────────────────────────────────────────────────────────────────────────
    group('Scenario 10: Remediation Verification — getStatsForRange & Idempotent Deletion', () {
      test('10a. Create expense -> Delete -> Verify both reporting methods return zero and category totals net to 0', () async {
        final now = DateTime(2026, 11, 2, 12, 0);

        final bank = BankAccount(
          id: 'acc_bank_s10',
          userId: 'offline_user',
          name: 'HDFC Test',
          bank: 'HDFC',
          balance: 30000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // Step 1: Create and post an expense of ₹5,000.00
        final expTx = spx.Transaction(
          id: 'tx_s10_test_exp',
          userId: 'offline_user',
          amount: 5000.0,
          type: 'expense',
          accountId: 'acc_bank_s10',
          categoryId: 'cat_dining',
          date: now,
          notes: 'Team lunch',
          source: 'manual',
        );
        await transactionRepo.insert(expTx);

        // Step 2: Record baseline reporting stats while posted
        final start = DateTime(2026, 11, 1);
        final end = DateTime(2026, 11, 30);

        final statsBefore = await transactionRepo.getStatsForRange(start, end);
        expect(statsBefore['expense'], 5000.0);
        expect(statsBefore['txn_count'], 1);
        expect(statsBefore['biggest_expense'], 5000.0);

        final monthlyBefore = await transactionRepo.getMonthlyStats(1);
        expect(monthlyBefore.first['expense'], 5000.0);

        final derivedBefore = await canonicalAccountRepo.getDerivedBalance('cat_dining');
        expect(derivedBefore.minorUnits, 500000);

        // Step 3: Delete the expense through the supported workflow
        final deleteResult = await transactionRepo.delete('tx_s10_test_exp');
        expect(deleteResult, 1); // Exactly 1 row/event deleted

        // Step 4: Verify canonical ledger truth
        final derivedAfter = await canonicalAccountRepo.getDerivedBalance('cat_dining');
        expect(derivedAfter.minorUnits, 0); // Canonical derived balance is 0

        // Step 5: Query getMonthlyStats()
        final monthlyAfter = await transactionRepo.getMonthlyStats(1);
        final monthlyExpenseAfter = (monthlyAfter.first['expense'] as num).toDouble();
        expect(monthlyExpenseAfter, 0.0); // getMonthlyStats() correctly nets to 0.0

        // Step 6: Query getStatsForRange() — REMEDIATED
        final statsAfter = await transactionRepo.getStatsForRange(start, end);
        final rangeExpenseAfter = statsAfter['expense'] as double;
        final rangeTxnCountAfter = statsAfter['txn_count'] as int;
        final rangeBiggestExpAfter = statsAfter['biggest_expense'] as double;
        final topCategoriesAfter = statsAfter['top_categories'] as List;

        // Verified: getStatsForRange now correctly reports 0.0 expense
        expect(rangeExpenseAfter, 0.0);
        expect(rangeTxnCountAfter, 0);
        expect(rangeBiggestExpAfter, 0.0);
        expect(topCategoriesAfter, isEmpty);
      });

      test('10b. Delete idempotency: Repeated deletion returns 0 and does NOT post duplicate reversal', () async {
        final now = DateTime(2026, 11, 2, 14, 0);

        final bank = BankAccount(
          id: 'acc_bank_s10b',
          userId: 'offline_user',
          name: 'SBI Test',
          bank: 'SBI',
          balance: 20000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        final expTx = spx.Transaction(
          id: 'tx_s10b_repeat',
          userId: 'offline_user',
          amount: 4000.0,
          type: 'expense',
          accountId: 'acc_bank_s10b',
          categoryId: 'cat_shopping',
          date: now,
          notes: 'Shoes',
          source: 'manual',
        );
        await transactionRepo.insert(expTx);

        // First deletion: must succeed and return 1
        final del1 = await transactionRepo.delete('tx_s10b_repeat');
        expect(del1, 1);

        // Count reversals in database
        final reversalsCount1 = firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM ${TablesV24.economicEvents} WHERE description LIKE 'REVERSAL: tx_s10b_repeat%'",
          ),
        );
        expect(reversalsCount1, 1);

        // Second deletion on the same ID: must return 0 (no-op)
        final del2 = await transactionRepo.delete('tx_s10b_repeat');
        expect(del2, 0);

        // Third deletion: still 0
        final del3 = await transactionRepo.delete('tx_s10b_repeat');
        expect(del3, 0);

        // Count reversals in database: MUST REMAIN EXACTLY 1!
        final reversalsCountFinal = firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM ${TablesV24.economicEvents} WHERE description LIKE 'REVERSAL: tx_s10b_repeat%'",
          ),
        );
        expect(reversalsCountFinal, 1);

        // Bank balance must be restored to exactly ₹20,000.00 (not ₹24,000 or ₹28,000)
        final finalBankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_s10b');
        expect(finalBankBal.minorUnits, 2000000);
      });

      test('10c. Repeated deletion after simulated app restart preserves idempotency', () async {
        final now = DateTime(2026, 11, 2, 15, 0);

        final bank = BankAccount(
          id: 'acc_bank_s10c',
          userId: 'offline_user',
          name: 'Axis Test',
          bank: 'Axis',
          balance: 15000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        final expTx = spx.Transaction(
          id: 'tx_s10c_restart',
          userId: 'offline_user',
          amount: 2500.0,
          type: 'expense',
          accountId: 'acc_bank_s10c',
          categoryId: 'cat_fuel',
          date: now,
          notes: 'Petrol',
          source: 'manual',
        );
        await transactionRepo.insert(expTx);

        // Delete in first session
        final del1 = await transactionRepo.delete('tx_s10c_restart');
        expect(del1, 1);

        // Simulate app restart: Instantiate a brand new TransactionRepo
        final freshRepoAfterRestart = TransactionRepo(executor: db);

        // Repeated delete on restarted repo
        final delAfterRestart = await freshRepoAfterRestart.delete('tx_s10c_restart');
        expect(delAfterRestart, 0); // Idempotent across sessions

        final reversalsCount = firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM ${TablesV24.economicEvents} WHERE description LIKE 'REVERSAL: tx_s10c_restart%'",
          ),
        );
        expect(reversalsCount, 1);
      });

      test('10d. Concurrent deletion calls create exactly 1 reversal', () async {
        final now = DateTime(2026, 11, 2, 16, 0);

        final bank = BankAccount(
          id: 'acc_bank_s10d',
          userId: 'offline_user',
          name: 'Kotak Test',
          bank: 'Kotak',
          balance: 25000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        final expTx = spx.Transaction(
          id: 'tx_s10d_concurrent',
          userId: 'offline_user',
          amount: 3500.0,
          type: 'expense',
          accountId: 'acc_bank_s10d',
          categoryId: 'cat_dining',
          date: now,
          notes: 'Dinner',
          source: 'manual',
        );
        await transactionRepo.insert(expTx);

        // Dispatch concurrent delete calls
        final results = await Future.wait([
          transactionRepo.delete('tx_s10d_concurrent'),
          transactionRepo.delete('tx_s10d_concurrent'),
          transactionRepo.delete('tx_s10d_concurrent'),
        ]);

        // Exactly one call returns 1, others return 0
        final successCount = results.where((r) => r == 1).length;
        final noopCount = results.where((r) => r == 0).length;
        expect(successCount, 1);
        expect(noopCount, 2);

        // Exactly one reversal exists in the database
        final reversalsCount = firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM ${TablesV24.economicEvents} WHERE description LIKE 'REVERSAL: tx_s10d_concurrent%'",
          ),
        );
        expect(reversalsCount, 1);

        // Bank balance returns to exactly ₹25,000.00
        final bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_s10d');
        expect(bal.minorUnits, 2500000);
      });

      test('10e. Active ordinary expenses are correctly counted in getStatsForRange', () async {
        final now = DateTime(2026, 11, 2, 17, 0);

        final bank = BankAccount(
          id: 'acc_bank_s10e',
          userId: 'offline_user',
          name: 'HDFC Active',
          bank: 'HDFC',
          balance: 50000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // 1 active expense of ₹3,000
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10e_active',
            userId: 'offline_user',
            amount: 3000.0,
            type: 'expense',
            accountId: 'acc_bank_s10e',
            categoryId: 'cat_groceries',
            date: now,
            notes: 'Active grocery run',
          ),
        );

        // 1 deleted expense of ₹7,000
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10e_deleted',
            userId: 'offline_user',
            amount: 7000.0,
            type: 'expense',
            accountId: 'acc_bank_s10e',
            categoryId: 'cat_electronics',
            date: now.add(const Duration(minutes: 5)),
            notes: 'Canceled electronic gadget',
          ),
        );
        await transactionRepo.delete('tx_s10e_deleted');

        // Query date range stats
        final start = DateTime(2026, 11, 1);
        final end = DateTime(2026, 11, 30);
        final stats = await transactionRepo.getStatsForRange(start, end);

        // Assert: Expense is STRICTLY ₹3,000.00 (the deleted ₹7,000 is netted to 0)
        expect(stats['expense'], 3000.0);
        expect(stats['txn_count'], 1); // Only the active transaction counted
        expect(stats['biggest_expense'], 3000.0);

        // Top categories contains only cat_groceries, cat_electronics is excluded
        final topCats = stats['top_categories'] as List<Map<String, dynamic>>;
        expect(topCats.length, 1);
        expect(topCats.first['category_id'], 'cat_groceries');
        expect(topCats.first['total'], 3000.0);
      });

      test('10f. Mixed expenses, refunds, and deleted transactions maintain consistency between getMonthlyStats and getStatsForRange', () async {
        final now = DateTime(2026, 11, 2, 18, 0);

        final bank = BankAccount(
          id: 'acc_bank_s10f',
          userId: 'offline_user',
          name: 'SBI Mixed',
          bank: 'SBI',
          balance: 60000.0,
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // 1. Earned Income: ₹40,000
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10f_inc',
            userId: 'offline_user',
            amount: 40000.0,
            type: 'income',
            accountId: 'acc_bank_s10f',
            categoryId: 'cat_salary',
            date: now,
            notes: 'Freelance payment',
          ),
        );

        // 2. Active Expense: ₹10,000
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10f_exp1',
            userId: 'offline_user',
            amount: 10000.0,
            type: 'expense',
            accountId: 'acc_bank_s10f',
            categoryId: 'cat_travel',
            date: now.add(const Duration(hours: 1)),
            notes: 'Train tickets',
          ),
        );

        // 3. Partial Refund against Travel: ₹2,000
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10f_ref',
            userId: 'offline_user',
            amount: 2000.0,
            type: 'refund',
            accountId: 'acc_bank_s10f',
            categoryId: 'cat_travel',
            date: now.add(const Duration(hours: 2)),
            notes: 'Ticket partial refund',
          ),
        );

        // 4. Expense created and then deleted: ₹5,000
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10f_del',
            userId: 'offline_user',
            amount: 5000.0,
            type: 'expense',
            accountId: 'acc_bank_s10f',
            categoryId: 'cat_shopping',
            date: now.add(const Duration(hours: 3)),
            notes: 'Canceled clothes',
          ),
        );
        await transactionRepo.delete('tx_s10f_del');

        // Net expected values:
        // Income = ₹40,000.00
        // Expense = 10,000 - 2,000 (refund) + 5,000 - 5,000 (deleted) = ₹8,000.00
        const expectedIncome = 40000.0;
        const expectedExpense = 8000.0;

        final start = DateTime(2026, 11, 1);
        final end = DateTime(2026, 11, 30);

        final rangeStats = await transactionRepo.getStatsForRange(start, end);
        final monthlyStats = await transactionRepo.getMonthlyStats(1);

        // Both methods must return identical numbers
        expect(rangeStats['income'], expectedIncome);
        expect(rangeStats['expense'], expectedExpense);

        expect((monthlyStats.first['income'] as num).toDouble(), expectedIncome);
        expect((monthlyStats.first['expense'] as num).toDouble(), expectedExpense);

        // Canonical derived query repo must also agree
        final canonicalIncome = await canonicalQueryRepo.getTotalIncome();
        final canonicalExpense = await canonicalQueryRepo.getTotalExpenses();
        expect(canonicalIncome.minorUnits, (expectedIncome * 100).round());
        expect(canonicalExpense.minorUnits, (expectedExpense * 100).round());
      });

      test('10g. SQL LIKE Wildcard and Prefix Immunity: tx_prefix_1 vs tx_prefix_10 vs tx_prefix_1_special', () async {
        final now = DateTime.now();

        await accountRepo.insertAccount(
          BankAccount(
            id: 'acc_bank_s10g',
            userId: 'offline_user',
            name: 'Wildcard Test Bank',
            bank: 'HDFC',
            balance: 50000.0,
            accountType: 'savings',
            createdAt: now,
            updatedAt: now,
          ),
        );

        // Seed 3 transactions with similar prefix and SQL wildcard characters
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_prefix_1',
            userId: 'offline_user',
            amount: 1000.0,
            type: 'expense',
            accountId: 'acc_bank_s10g',
            categoryId: 'cat_food',
            date: now.subtract(const Duration(minutes: 10)),
            notes: 'Prefix 1 expense',
          ),
        );
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_prefix_10',
            userId: 'offline_user',
            amount: 2000.0,
            type: 'expense',
            accountId: 'acc_bank_s10g',
            categoryId: 'cat_food',
            date: now.subtract(const Duration(minutes: 5)),
            notes: 'Prefix 10 expense',
          ),
        );
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_prefix_1_special',
            userId: 'offline_user',
            amount: 3000.0,
            type: 'expense',
            accountId: 'acc_bank_s10g',
            categoryId: 'cat_travel',
            date: now.subtract(const Duration(minutes: 2)),
            notes: 'Prefix 1 special expense',
          ),
        );

        // Delete only tx_prefix_10
        final delResult10 = await transactionRepo.delete('tx_prefix_10');
        expect(delResult10, 1);

        // Verification: tx_prefix_1 must NOT be affected by tx_prefix_10 deletion
        final tx1 = await transactionRepo.getById('tx_prefix_1');
        expect(tx1, isNotNull, reason: 'tx_prefix_1 must not be falsely matched as deleted by tx_prefix_10 reversal');
        expect(tx1!.amount, 1000.0);

        final allActive = await transactionRepo.getAll();
        final activeIds = allActive.map((t) => t.id).toSet();
        expect(activeIds.contains('tx_prefix_1'), isTrue);
        expect(activeIds.contains('tx_prefix_1_special'), isTrue);
        expect(activeIds.contains('tx_prefix_10'), isFalse);

        // Range stats verification
        final start = DateTime(now.year, now.month, 1);
        final end = DateTime(now.year, now.month + 1, 1);
        final stats = await transactionRepo.getStatsForRange(start, end);

        // tx_prefix_1 (1000) + tx_prefix_1_special (3000) = 4000.0
        expect(stats['expense'], 4000.0);
        expect(stats['txn_count'], 2, reason: 'Must count only the 2 active non-reversed transactions');
        expect(stats['biggest_expense'], 3000.0);

        // Now delete tx_prefix_1_special
        final delResultSpecial = await transactionRepo.delete('tx_prefix_1_special');
        expect(delResultSpecial, 1);

        final statsAfterSpecial = await transactionRepo.getStatsForRange(start, end);
        expect(statsAfterSpecial['expense'], 1000.0);
        expect(statsAfterSpecial['txn_count'], 1);
        expect(statsAfterSpecial['biggest_expense'], 1000.0);
      });

      test('10h. Reversal Event Cannot Be Deleted or Reversed', () async {
        final now = DateTime(2026, 11, 15, 12, 0);

        await accountRepo.insertAccount(
          BankAccount(
            id: 'acc_bank_s10h',
            userId: 'offline_user',
            name: 'Reversal Protection Bank',
            bank: 'HDFC',
            balance: 50000.0,
            accountType: 'savings',
            createdAt: now,
            updatedAt: now,
          ),
        );

        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_del_target_10h',
            userId: 'offline_user',
            amount: 2500.0,
            type: 'expense',
            accountId: 'acc_bank_s10h',
            categoryId: 'cat_food',
            date: now,
            notes: 'Target to delete',
          ),
        );

        final delSuccess = await transactionRepo.delete('tx_del_target_10h');
        expect(delSuccess, 1);

        // Query the reversal event created for tx_del_target_10h
        final reversalRows = await db.rawQuery(
          "SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = 'tx_del_target_10h' LIMIT 1;",
        );
        expect(reversalRows, isNotEmpty);
        final reversalId = reversalRows.first['id'] as String;

        // Attempting to delete a reversal event must return 0
        final delReversalResult = await transactionRepo.delete(reversalId);
        expect(delReversalResult, 0, reason: 'Reversal events cannot themselves be deleted/reversed');

        // Verify no child reversal was created
        final childReversals = await db.rawQuery(
          'SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ?;',
          [reversalId],
        );
        expect(childReversals, isEmpty);
      });

      test('10i. Structured Reversal Relationship Verification in SQLite', () async {
        final now = DateTime(2026, 11, 15, 14, 0);

        await accountRepo.insertAccount(
          BankAccount(
            id: 'acc_bank_s10i',
            userId: 'offline_user',
            name: 'Structured Verification Bank',
            bank: 'HDFC',
            balance: 50000.0,
            accountType: 'savings',
            createdAt: now,
            updatedAt: now,
          ),
        );

        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_struct_test_10i',
            userId: 'offline_user',
            amount: 1800.0,
            type: 'expense',
            accountId: 'acc_bank_s10i',
            categoryId: 'cat_food',
            date: now,
            notes: 'Structured test',
          ),
        );

        await transactionRepo.delete('tx_struct_test_10i');

        final reversalRow = await db.rawQuery(
          "SELECT id, reversal_of_event_id, description FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = 'tx_struct_test_10i';",
        );
        expect(reversalRow.length, 1);
        expect(reversalRow.first['reversal_of_event_id'], 'tx_struct_test_10i');
        expect(reversalRow.first['description'], startsWith('REVERSAL: tx_struct_test_10i'));
      });

      test('10j. Category Totals: Net-Zero, Net-Negative, and Uncategorized Refunds (HAVING total > 0)', () async {
        final now = DateTime(2026, 11, 16, 10, 0);

        await accountRepo.insertAccount(
          BankAccount(
            id: 'acc_bank_s10j',
            userId: 'offline_user',
            name: 'Category Test Bank',
            bank: 'HDFC',
            balance: 50000.0,
            accountType: 'savings',
            createdAt: now,
            updatedAt: now,
          ),
        );

        // 1. Net-Zero Category (cat_food): ₹2,000 expense, followed by ₹2,000 refund
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10j_food_exp',
            userId: 'offline_user',
            amount: 2000.0,
            type: 'expense',
            accountId: 'acc_bank_s10j',
            categoryId: 'cat_food',
            date: now,
            notes: 'Food expense',
          ),
        );
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10j_food_ref',
            userId: 'offline_user',
            amount: 2000.0,
            type: 'refund',
            accountId: 'acc_bank_s10j',
            categoryId: 'cat_food',
            date: now.add(const Duration(hours: 1)),
            notes: 'Food refund',
          ),
        );

        // 2. Net-Negative Category (cat_shopping): ₹1,000 expense, followed by ₹1,500 refund
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10j_shop_exp',
            userId: 'offline_user',
            amount: 1000.0,
            type: 'expense',
            accountId: 'acc_bank_s10j',
            categoryId: 'cat_shopping',
            date: now.add(const Duration(hours: 2)),
            notes: 'Shopping expense',
          ),
        );
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10j_shop_ref',
            userId: 'offline_user',
            amount: 1500.0,
            type: 'refund',
            accountId: 'acc_bank_s10j',
            categoryId: 'cat_shopping',
            date: now.add(const Duration(hours: 3)),
            notes: 'Shopping oversized refund',
          ),
        );

        // 3. Uncategorized refund: ₹800 (routes to sys_exp_refunds)
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10j_uncat_ref',
            userId: 'offline_user',
            amount: 800.0,
            type: 'refund',
            accountId: 'acc_bank_s10j',
            categoryId: null, // No category
            date: now.add(const Duration(hours: 4)),
            notes: 'Uncategorized bank refund',
          ),
        );

        // 4. Net-Positive Category (cat_travel): ₹3,500 expense, followed by ₹500 partial refund
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10j_travel_exp',
            userId: 'offline_user',
            amount: 3500.0,
            type: 'expense',
            accountId: 'acc_bank_s10j',
            categoryId: 'cat_travel',
            date: now.add(const Duration(hours: 5)),
            notes: 'Flight ticket',
          ),
        );
        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_s10j_travel_ref',
            userId: 'offline_user',
            amount: 500.0,
            type: 'refund',
            accountId: 'acc_bank_s10j',
            categoryId: 'cat_travel',
            date: now.add(const Duration(hours: 6)),
            notes: 'Flight meal cancel refund',
          ),
        );

        // Query getStatsForRange
        final start = DateTime(2026, 11, 16, 0, 0);
        final end = DateTime(2026, 11, 16, 23, 59);
        final stats = await transactionRepo.getStatsForRange(start, end);

        // Overall net expense:
        // Food: 2000 - 2000 = 0
        // Shopping: 1000 - 1500 = -500
        // Uncategorized: -800
        // Travel: 3500 - 500 = 3000
        // Total = 0 - 500 - 800 + 3000 = 1700.0
        const expectedExpense = 1700.0;
        expect(stats['expense'], expectedExpense);

        // Top categories verification:
        // HAVING total > 0 must exclude:
        // - cat_food (total = 0.0)
        // - cat_shopping (total = -500.0)
        // - sys_exp_refunds (total = -800.0)
        // It must include ONLY cat_travel with total = 3000.0
        final topCats = stats['top_categories'] as List<Map<String, dynamic>>;
        expect(topCats.length, 1);
        expect(topCats.first['category_id'], 'cat_travel');
        expect(topCats.first['total'], 3000.0);
      });

      test('10k. Concurrent Deletion Stress Test: 5 simultaneous calls yield exactly 1 reversal', () async {
        final now = DateTime(2026, 11, 17, 10, 0);

        await accountRepo.insertAccount(
          BankAccount(
            id: 'acc_bank_s10k',
            userId: 'offline_user',
            name: 'Concurrency Bank',
            bank: 'HDFC',
            balance: 20000.0,
            accountType: 'savings',
            createdAt: now,
            updatedAt: now,
          ),
        );

        await transactionRepo.insert(
          spx.Transaction(
            id: 'tx_concurrent_5x',
            userId: 'offline_user',
            amount: 4500.0,
            type: 'expense',
            accountId: 'acc_bank_s10k',
            categoryId: 'cat_food',
            date: now,
            notes: 'High concurrency deletion test',
          ),
        );

        // Execute 5 concurrent delete operations
        final results = await Future.wait([
          transactionRepo.delete('tx_concurrent_5x'),
          transactionRepo.delete('tx_concurrent_5x'),
          transactionRepo.delete('tx_concurrent_5x'),
          transactionRepo.delete('tx_concurrent_5x'),
          transactionRepo.delete('tx_concurrent_5x'),
        ]);

        expect(results.where((r) => r == 1).length, 1, reason: 'Exactly one delete call must succeed');
        expect(results.where((r) => r == 0).length, 4, reason: 'Exactly four delete calls must be idempotent no-ops');

        // Verify in SQLite that exactly 1 reversal event was created
        final reversals = await db.rawQuery(
          "SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = 'tx_concurrent_5x';",
        );
        expect(reversals.length, 1);
      });
    });
  });
}
