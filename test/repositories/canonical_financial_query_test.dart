import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('CanonicalFinancialQueryRepository Tests', () {
    late Database db;
    late CanonicalAccountRepository accountRepo;
    late CanonicalEventRepository eventRepo;
    late CanonicalEarmarkRepository earmarkRepo;
    late CanonicalFinancialQueryRepository queryRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await TablesV24.createAllV24(db);
      await TablesV24.installTriggers(db);
      await TablesV24.seedSystemAccounts(db);

      accountRepo = CanonicalAccountRepository(executor: db);
      eventRepo = CanonicalEventRepository(executor: db);
      earmarkRepo = CanonicalEarmarkRepository(executor: db);
      queryRepo = CanonicalFinancialQueryRepository(executor: db);

      final now = DateTime.now();
      // Setup standard test chart of accounts
      await accountRepo.createAccount(Account(
        id: 'acc_bank_sbi',
        name: 'SBI Bank',
        type: AccountType.asset,
        category: 'bank',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_bank_hdfc',
        name: 'HDFC Bank',
        type: AccountType.asset,
        category: 'bank',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_card_one',
        name: 'OneCard',
        type: AccountType.liability,
        category: 'credit_card',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_salary',
        name: 'Salary',
        type: AccountType.income,
        category: 'salary',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_rent',
        name: 'Rent',
        type: AccountType.expense,
        category: 'rent',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_groceries',
        name: 'Groceries',
        type: AccountType.expense,
        category: 'groceries',
        createdAt: now,
        updatedAt: now,
      ));
    });

    tearDown(() async {
      await db.close();
    });

    test('Net Worth, Assets, Liabilities, Income, Expenses, and Cash Flow calculations', () async {
      final now = DateTime(2026, 1, 15);

      // Event 1: Income ₹1,00,000 received into SBI
      final p1 = [
        Posting(
          id: 'p1_1',
          economicEventId: 'evt_salary',
          accountId: 'acc_bank_sbi',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(10000000), // ₹1,00,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p1_2',
          economicEventId: 'evt_salary',
          accountId: 'acc_salary',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(10000000),
          createdAt: now,
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_salary',
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Salary',
          postings: p1,
          createdAt: now,
        ),
        postings: p1,
      );

      // Event 2: Rent expense ₹30,000 paid from SBI
      final p2 = [
        Posting(
          id: 'p2_1',
          economicEventId: 'evt_rent',
          accountId: 'acc_rent',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(3000000), // ₹30,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p2_2',
          economicEventId: 'evt_rent',
          accountId: 'acc_bank_sbi',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(3000000),
          createdAt: now,
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_rent',
          canonicalType: CanonicalEventType.expense,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Rent Payment',
          postings: p2,
          createdAt: now,
        ),
        postings: p2,
      );

      // Event 3: Grocery expense ₹10,000 paid on Credit Card
      final p3 = [
        Posting(
          id: 'p3_1',
          economicEventId: 'evt_groc_card',
          accountId: 'acc_groceries',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(1000000), // ₹10,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p3_2',
          economicEventId: 'evt_groc_card',
          accountId: 'acc_card_one',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(1000000),
          createdAt: now,
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_groc_card',
          canonicalType: CanonicalEventType.cardPurchase,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Groceries on Card',
          postings: p3,
          createdAt: now,
        ),
        postings: p3,
      );

      // Verify Total Assets:
      // SBI Bank: 1,00,000 - 30,000 = ₹70,000 (7000000 minor units)
      final totalAssets = await queryRepo.getTotalAssets();
      expect(totalAssets.minorUnits, 7000000);

      // Verify Total Liabilities:
      // OneCard: ₹10,000 (1000000 minor units)
      final totalLiabilities = await queryRepo.getTotalLiabilities();
      expect(totalLiabilities.minorUnits, 1000000);

      // Verify Net Worth = Assets - Liabilities = 70,000 - 10,000 = ₹60,000 (6000000 minor units)
      final netWorth = await queryRepo.getNetWorth();
      expect(netWorth.minorUnits, 6000000);

      // Verify Total Income = ₹1,00,000 (10000000 minor units)
      final totalIncome = await queryRepo.getTotalIncome();
      expect(totalIncome.minorUnits, 10000000);

      // Verify Total Expenses = Rent 30,000 + Groceries 10,000 = ₹40,000 (4000000 minor units)
      final totalExpenses = await queryRepo.getTotalExpenses();
      expect(totalExpenses.minorUnits, 4000000);

      // Verify Cash Flow = Net Liquid Cash Movement = ₹70,000 (Card purchase did not move cash)
      final cashFlow = await queryRepo.getCashFlow();
      expect(cashFlow.minorUnits, 7000000);

      // Verify Net Operating Income = Income - Expenses = ₹60,000
      final operatingIncome = await queryRepo.getNetOperatingIncome();
      expect(operatingIncome.minorUnits, 6000000);
      expect(netWorth.minorUnits, operatingIncome.minorUnits);

      // Event 4: Inter-account transfer of ₹20,000 from SBI to HDFC
      final p4 = [
        Posting(
          id: 'p4_1',
          economicEventId: 'evt_transfer',
          accountId: 'acc_bank_hdfc',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(2000000), // ₹20,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p4_2',
          economicEventId: 'evt_transfer',
          accountId: 'acc_bank_sbi',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(2000000),
          createdAt: now,
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_transfer',
          canonicalType: CanonicalEventType.transfer,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Internal Transfer',
          postings: p4,
          createdAt: now,
        ),
        postings: p4,
      );

      // Post-transfer verification:
      // Transfer must have EXACTLY ZERO impact on Net Worth, Income, Expenses, Cash Flow
      expect((await queryRepo.getTotalAssets()).minorUnits, 7000000); // SBI(50k) + HDFC(20k)
      expect((await queryRepo.getTotalLiabilities()).minorUnits, 1000000);
      expect((await queryRepo.getNetWorth()).minorUnits, 6000000);
      expect((await queryRepo.getTotalIncome()).minorUnits, 10000000);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 4000000);
      expect((await queryRepo.getCashFlow()).minorUnits, 7000000);
    });

    test('Zero Draft Leakage in Financial Queries', () async {
      final now = DateTime.now();

      // Post real initial salary ₹50,000
      final realPostings = [
        Posting(
          id: 'p_r1',
          economicEventId: 'evt_real',
          accountId: 'acc_bank_sbi',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(5000000),
          createdAt: now,
        ),
        Posting(
          id: 'p_r2',
          economicEventId: 'evt_real',
          accountId: 'acc_salary',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(5000000),
          createdAt: now,
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_real',
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Real Salary',
          postings: realPostings,
          createdAt: now,
        ),
        postings: realPostings,
      );

      // Stage massive draft events
      final draftPostings = [
        Posting(
          id: 'p_d1',
          economicEventId: 'evt_draft_massive',
          accountId: 'acc_bank_sbi',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(99999999), // ₹10,00,000
          createdAt: now,
        ),
        Posting(
          id: 'p_d2',
          economicEventId: 'evt_draft_massive',
          accountId: 'acc_salary',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(99999999),
          createdAt: now,
        ),
      ];
      await eventRepo.createDraftEvent(
        EconomicEvent(
          id: 'evt_draft_massive',
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.draft,
          occurredAt: now,
          description: 'Draft unconfirmed income',
          createdAt: now,
        ),
        postings: draftPostings,
      );

      // Financial queries must strictly report ONLY posted facts
      expect((await queryRepo.getTotalAssets()).minorUnits, 5000000);
      expect((await queryRepo.getTotalIncome()).minorUnits, 5000000);
      expect((await queryRepo.getNetWorth()).minorUnits, 5000000);
    });

    test('Safe-to-Spend liquidity calculation and deficit shortfall handling', () async {
      final now = DateTime.now();

      // SBI has ₹50,000 liquid cash
      final p = [
        Posting(
          id: 'p_s1',
          economicEventId: 'evt_init',
          accountId: 'acc_bank_sbi',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(5000000),
          createdAt: now,
        ),
        Posting(
          id: 'p_s2',
          economicEventId: 'evt_init',
          accountId: 'acc_salary',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(5000000),
          createdAt: now,
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_init',
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Initial',
          postings: p,
          createdAt: now,
        ),
        postings: p,
      );

      // Virtual earmark ₹20,000 for emergency fund
      await earmarkRepo.setEarmark(AssetEarmark(
        id: 'em_1',
        goalId: 'goal_emergency',
        assetAccountId: 'acc_bank_sbi',
        earmarkedAmount: Money.fromMinorUnits(2000000),
        createdAt: now,
        updatedAt: now,
      ));

      // 1. Normal surplus scenario:
      // Liquid = 50,000, Earmark = 20,000, Commitments14d = 10,000
      // Discretionary = 50,000 - 20,000 - 10,000 = 20,000
      // Safe to spend = 20,000, Shortfall = 0
      final surplusCalc = await queryRepo.getSafeToSpend(
        knownCommitments14d: Money.fromMinorUnits(1000000),
      );
      expect(surplusCalc.liquidAssets.minorUnits, 5000000);
      expect(surplusCalc.activeEarmarks.minorUnits, 2000000);
      expect(surplusCalc.discretionaryCash.minorUnits, 2000000);
      expect(surplusCalc.safeToSpend.minorUnits, 2000000);
      expect(surplusCalc.cashflowShortfall.minorUnits, 0);
      expect(surplusCalc.hasShortfall, isFalse);

      // 2. Deficit scenario:
      // Commitments14d = 40,000
      // Discretionary = 50,000 - 20,000 - 40,000 = -10,000
      // Safe to spend = 0 (floored)
      // Shortfall = 10,000 (positive magnitude)
      final deficitCalc = await queryRepo.getSafeToSpend(
        knownCommitments14d: Money.fromMinorUnits(4000000),
      );
      expect(deficitCalc.discretionaryCash.minorUnits, -1000000);
      expect(deficitCalc.safeToSpend.minorUnits, 0);
      expect(deficitCalc.cashflowShortfall.minorUnits, 1000000);
      expect(deficitCalc.hasShortfall, isTrue);
    });
  });
}
