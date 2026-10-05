import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('CanonicalAccountRepository Tests', () {
    late Database db;
    late CanonicalAccountRepository accountRepo;
    late CanonicalEventRepository eventRepo;

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
    });

    tearDown(() async {
      await db.close();
    });

    test('Account CRUD and archiving lifecycle', () async {
      final now = DateTime.now();
      final acc = Account(
        id: 'acc_icici',
        name: 'ICICI Savings',
        type: AccountType.asset,
        category: 'bank',
        createdAt: now,
        updatedAt: now,
      );

      await accountRepo.createAccount(acc);

      final retrieved = await accountRepo.getAccount('acc_icici');
      expect(retrieved, isNotNull);
      expect(retrieved!.name, 'ICICI Savings');
      expect(retrieved.type, AccountType.asset);
      expect(retrieved.isActive, isTrue);

      // Update name
      final updatedAcc = retrieved.copyWith(name: 'ICICI Salary Account');
      await accountRepo.updateAccount(updatedAcc);
      final afterUpdate = await accountRepo.getAccount('acc_icici');
      expect(afterUpdate!.name, 'ICICI Salary Account');

      // Archive
      await accountRepo.archiveAccount('acc_icici');
      final archived = await accountRepo.getAccount('acc_icici');
      expect(archived!.isActive, isFalse);

      final activeList = await accountRepo.listAccounts(isActive: true);
      expect(activeList.any((a) => a.id == 'acc_icici'), isFalse);
    });

    test('Derived balance calculates correctly across normal debit and credit accounts', () async {
      final now = DateTime.now();

      // Create Asset (Bank), Liability (Credit Card), Expense (Groceries), Income (Salary)
      final bank = Account(
        id: 'acc_bank_test',
        name: 'SBI Bank',
        type: AccountType.asset,
        category: 'bank',
        createdAt: now,
        updatedAt: now,
      );
      final card = Account(
        id: 'acc_card_test',
        name: 'HDFC Regalia',
        type: AccountType.liability,
        category: 'credit_card',
        createdAt: now,
        updatedAt: now,
      );
      final groceries = Account(
        id: 'acc_groc_test',
        name: 'Groceries',
        type: AccountType.expense,
        category: 'groceries',
        createdAt: now,
        updatedAt: now,
      );
      final salary = Account(
        id: 'acc_sal_test',
        name: 'Salary',
        type: AccountType.income,
        category: 'salary',
        createdAt: now,
        updatedAt: now,
      );

      await accountRepo.createAccount(bank);
      await accountRepo.createAccount(card);
      await accountRepo.createAccount(groceries);
      await accountRepo.createAccount(salary);

      // 1. Initial balances must be zero
      expect((await accountRepo.getDerivedBalance('acc_bank_test')).minorUnits, 0);
      expect((await accountRepo.getDerivedBalance('acc_card_test')).minorUnits, 0);
      expect((await accountRepo.getDerivedBalance('acc_groc_test')).minorUnits, 0);
      expect((await accountRepo.getDerivedBalance('acc_sal_test')).minorUnits, 0);

      // 2. Post Income: Debit Bank 50,000, Credit Salary 50,000
      final incomePostings = [
        Posting(
          id: 'p_inc_1',
          economicEventId: 'evt_inc',
          accountId: 'acc_bank_test',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(5000000), // ₹50,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p_inc_2',
          economicEventId: 'evt_inc',
          accountId: 'acc_sal_test',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(5000000),
          createdAt: now,
        ),
      ];
      final incomeEvt = EconomicEvent(
        id: 'evt_inc',
        canonicalType: CanonicalEventType.income,
        lifecycleStatus: EventLifecycle.posted,
        occurredAt: now,
        description: 'Salary',
        postings: incomePostings,
        createdAt: now,
      );
      await eventRepo.createAndPostEvent(incomeEvt, postings: incomePostings);

      expect((await accountRepo.getDerivedBalance('acc_bank_test')).minorUnits, 5000000);
      expect((await accountRepo.getDerivedBalance('acc_sal_test')).minorUnits, 5000000);

      // 3. Post Credit Card Purchase: Debit Groceries 12,000, Credit Card 12,000
      final cardPostings = [
        Posting(
          id: 'p_card_1',
          economicEventId: 'evt_card_spend',
          accountId: 'acc_groc_test',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(1200000), // ₹12,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p_card_2',
          economicEventId: 'evt_card_spend',
          accountId: 'acc_card_test',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(1200000),
          createdAt: now,
        ),
      ];
      final cardEvt = EconomicEvent(
        id: 'evt_card_spend',
        canonicalType: CanonicalEventType.cardPurchase,
        lifecycleStatus: EventLifecycle.posted,
        occurredAt: now,
        description: 'Grocery shopping on Card',
        postings: cardPostings,
        createdAt: now,
      );
      await eventRepo.createAndPostEvent(cardEvt, postings: cardPostings);

      expect((await accountRepo.getDerivedBalance('acc_groc_test')).minorUnits, 1200000);
      // Liability has normal credit balance: 1200000
      expect((await accountRepo.getDerivedBalance('acc_card_test')).minorUnits, 1200000);

      // 4. Pay Credit Card Bill: Debit Card 12,000, Credit Bank 12,000
      final payPostings = [
        Posting(
          id: 'p_pay_1',
          economicEventId: 'evt_bill_pay',
          accountId: 'acc_card_test',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(1200000),
          createdAt: now,
        ),
        Posting(
          id: 'p_pay_2',
          economicEventId: 'evt_bill_pay',
          accountId: 'acc_bank_test',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(1200000),
          createdAt: now,
        ),
      ];
      final payEvt = EconomicEvent(
        id: 'evt_bill_pay',
        canonicalType: CanonicalEventType.cardPayment,
        lifecycleStatus: EventLifecycle.posted,
        occurredAt: now,
        description: 'Regalia CC settlement',
        postings: payPostings,
        createdAt: now,
      );
      await eventRepo.createAndPostEvent(payEvt, postings: payPostings);

      // Bank: 50,000 - 12,000 = 38,000
      expect((await accountRepo.getDerivedBalance('acc_bank_test')).minorUnits, 3800000);
      // Card: 12,000 credit - 12,000 debit = 0
      expect((await accountRepo.getDerivedBalance('acc_card_test')).minorUnits, 0);

      // Check batch derived balances
      final balances = await accountRepo.getDerivedBalances([
        'acc_bank_test',
        'acc_card_test',
        'acc_groc_test',
      ]);
      expect(balances['acc_bank_test']!.minorUnits, 3800000);
      expect(balances['acc_card_test']!.minorUnits, 0);
      expect(balances['acc_groc_test']!.minorUnits, 1200000);
    });

    test('Zero Draft Leakage: Draft event postings never alter derived balances', () async {
      final now = DateTime.now();
      final bank = Account(
        id: 'acc_bank_leak_check',
        name: 'Canara Bank',
        type: AccountType.asset,
        createdAt: now,
        updatedAt: now,
      );
      await accountRepo.createAccount(bank);

      // Create draft event with postings
      final draftEvt = EconomicEvent(
        id: 'evt_draft_leak',
        canonicalType: CanonicalEventType.expense,
        lifecycleStatus: EventLifecycle.draft,
        occurredAt: now,
        description: 'Unposted staging expense',
        createdAt: now,
      );
      final draftPostings = [
        Posting(
          id: 'p_dl_1',
          economicEventId: 'evt_draft_leak',
          accountId: 'acc_bank_leak_check',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(9999999), // Massive amount
          createdAt: now,
        ),
      ];

      await eventRepo.createDraftEvent(draftEvt, postings: draftPostings);

      // Derived balance must remain strictly ZERO
      final balance = await accountRepo.getDerivedBalance('acc_bank_leak_check');
      expect(balance.minorUnits, 0);

      // Raw debit credit must also be ZERO
      final raw = await accountRepo.getRawDebitCredit('acc_bank_leak_check');
      expect(raw.debits.minorUnits, 0);
      expect(raw.credits.minorUnits, 0);
    });
  });
}
