import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/features/accounts/providers/account_providers.dart';
import 'package:spend_x/features/transactions/providers/transaction_providers.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/transaction.dart' as model;
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C4-1: Accounts & Transactions Riverpod Read Migration Test Suite', () {
    late Database db;
    late AccountRepo accountRepo;
    late TransactionRepo transactionRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late ProviderContainer container;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );

      // Create full schema including v24 canonical tables & triggers
      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      accountRepo = AccountRepo(executor: db);
      transactionRepo = TransactionRepo(executor: db);

      container = ProviderContainer(
        overrides: [
          app_data.accountRepoProvider.overrideWithValue(accountRepo),
          app_data.transactionRepoProvider.overrideWithValue(transactionRepo),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Test 1: accountsProvider loads accounts with canonical derived balance
    // -------------------------------------------------------------------------
    test('1. accountsProvider loads accounts with canonical derived balance from postings', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_riverpod_1',
        name: 'HDFC Bank',
        bank: 'HDFC',
        balance: 10000.0,
      ));

      // Build accountsProvider
      final accounts = await container.read(accountsProvider.future);
      expect(accounts.length, equals(1));
      expect(accounts.first.id, equals('acc_riverpod_1'));
      expect(accounts.first.balance, equals(10000.0));

      // Verify derived balance from canonicalAccountRepo matches
      final derivedBalance = await canonicalAccountRepo.getDerivedBalance('acc_riverpod_1');
      expect(derivedBalance.toRupees, equals(10000.0));
    });

    // -------------------------------------------------------------------------
    // Test 2: Direct SQL UPDATE to bank_accounts.balance does NOT alter accountsProvider
    // -------------------------------------------------------------------------
    test('2. Direct SQL UPDATE to bank_accounts.balance does NOT alter accountsProvider', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_riverpod_2',
        name: 'SBI Bank',
        bank: 'SBI',
        balance: 25000.0,
      ));

      // Attempt rogue update to legacy table column
      await db.rawUpdate(
        'UPDATE ${Tables.bankAccounts} SET balance = 888888.0 WHERE id = ?',
        ['acc_riverpod_2'],
      );

      // Force reload/refresh
      await container.read(accountsProvider.notifier).refresh();
      final accounts = await container.read(accountsProvider.future);

      // Must remain canonical derived balance: ₹25,000.0
      expect(accounts.first.balance, equals(25000.0));
    });

    // -------------------------------------------------------------------------
    // Test 3: Posting canonical income updates accountsProvider
    // -------------------------------------------------------------------------
    test('3. Posting canonical income updates accountsProvider derived balance', () async {
      final now = DateTime.now();
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_riverpod_3',
        name: 'Salary Bank',
        bank: 'ICICI',
        balance: 10000.0,
      ));

      // Post income event of ₹15,000
      final incomePostings = [
        Posting(
          id: 'p_inc_dr',
          economicEventId: 'evt_inc_3',
          accountId: 'acc_riverpod_3',
          direction: PostingDirection.debit,
          amount: Money.fromRupees(15000.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_inc_cr',
          economicEventId: 'evt_inc_3',
          accountId: TablesV24.sysIncMisc,
          direction: PostingDirection.credit,
          amount: Money.fromRupees(15000.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_inc_3',
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Bonus credited',
          postings: incomePostings,
          createdAt: now,
        ),
        postings: incomePostings,
      );

      await container.read(accountsProvider.notifier).refresh();
      final accounts = await container.read(accountsProvider.future);
      expect(accounts.first.balance, equals(25000.0)); // 10,000 + 15,000
    });

    // -------------------------------------------------------------------------
    // Test 4: Posting canonical expense updates accountsProvider
    // -------------------------------------------------------------------------
    test('4. Posting canonical expense updates accountsProvider derived balance', () async {
      final now = DateTime.now();
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_riverpod_4',
        name: 'Spend Bank',
        bank: 'Axis',
        balance: 20000.0,
      ));

      // Post expense event of ₹4,500
      final expPostings = [
        Posting(
          id: 'p_exp_dr',
          economicEventId: 'evt_exp_4',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromRupees(4500.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_exp_cr',
          economicEventId: 'evt_exp_4',
          accountId: 'acc_riverpod_4',
          direction: PostingDirection.credit,
          amount: Money.fromRupees(4500.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_exp_4',
          canonicalType: CanonicalEventType.expense,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Grocery bill',
          postings: expPostings,
          createdAt: now,
        ),
        postings: expPostings,
      );

      await container.read(accountsProvider.notifier).refresh();
      final accounts = await container.read(accountsProvider.future);
      expect(accounts.first.balance, equals(15500.0)); // 20,000 - 4,500
    });

    // -------------------------------------------------------------------------
    // Test 5: Reversing a canonical event updates accountsProvider
    // -------------------------------------------------------------------------
    test('5. Reversing a canonical event updates accountsProvider derived balance', () async {
      final now = DateTime.now();
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_riverpod_5',
        name: 'Reversal Bank',
        bank: 'Kotak',
        balance: 30000.0,
      ));

      // Post expense of ₹5,000
      final expPostings = [
        Posting(
          id: 'p_e5_dr',
          economicEventId: 'evt_exp_5',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromRupees(5000.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_e5_cr',
          economicEventId: 'evt_exp_5',
          accountId: 'acc_riverpod_5',
          direction: PostingDirection.credit,
          amount: Money.fromRupees(5000.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_exp_5',
          canonicalType: CanonicalEventType.expense,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Mistaken charge',
          postings: expPostings,
          createdAt: now,
        ),
        postings: expPostings,
      );

      await container.read(accountsProvider.notifier).refresh();
      var accounts = await container.read(accountsProvider.future);
      expect(accounts.first.balance, equals(25000.0));

      // Now reverse the mistaken charge
      final revPostings = [
        Posting(
          id: 'p_r5_dr',
          economicEventId: 'evt_rev_5',
          accountId: 'acc_riverpod_5',
          direction: PostingDirection.debit,
          amount: Money.fromRupees(5000.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_r5_cr',
          economicEventId: 'evt_rev_5',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.credit,
          amount: Money.fromRupees(5000.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_rev_5',
          canonicalType: CanonicalEventType.adjustment,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'REVERSAL: evt_exp_5',
          postings: revPostings,
          createdAt: now,
        ),
        postings: revPostings,
      );

      await container.read(accountsProvider.notifier).refresh();
      accounts = await container.read(accountsProvider.future);
      expect(accounts.first.balance, equals(30000.0)); // Restored
    });

    // -------------------------------------------------------------------------
    // Test 6: transactionsProvider reads canonical posted events
    // -------------------------------------------------------------------------
    test('6. transactionsProvider reads canonical posted events and projects Transaction model', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_tx_read',
        name: 'Tx Bank',
        bank: 'SBI',
        balance: 0.0,
      ));

      // Insert transaction via TransactionRepo (which creates canonical event + postings)
      await transactionRepo.insert(model.Transaction(
        id: 'tx_c4_1',
        userId: 'user_1',
        type: 'expense',
        amount: 850.0,
        date: DateTime.now(),
        accountId: 'acc_tx_read',
        notes: 'Dinner with team',
      ));

      final txList = await container.read(transactionsProvider.future);
      expect(txList.length, equals(1));
      expect(txList.first.id, equals('tx_c4_1'));
      expect(txList.first.amount, equals(850.0));
      expect(txList.first.notes, equals('Dinner with team'));
    });

    // -------------------------------------------------------------------------
    // Test 7: Fake rows in legacy transactions table do NOT alter transactionsProvider
    // -------------------------------------------------------------------------
    test('7. Fake rows in legacy transactions table do NOT alter transactionsProvider', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_tx_ghost',
        name: 'Ghost Bank',
        bank: 'SBI',
        balance: 5000.0,
      ));

      // Direct rogue SQL write to legacy transactions table
      await db.insert(Tables.transactions, {
        'id': 'tx_ghost_rogue',
        'notes': 'Ghost Transaction',
        'amount': 99999.0,
        'type': 'expense',
        'account_id': 'acc_tx_ghost',
        'date': DateTime.now().toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      // transactionsProvider strictly projects from TablesV24.economicEvents
      final txList = await container.read(transactionsProvider.future);
      expect(txList.any((t) => t.id == 'tx_ghost_rogue'), isFalse);
    });

    // -------------------------------------------------------------------------
    // Test 8: Reversing a transaction excludes it from active transactionsProvider list
    // -------------------------------------------------------------------------
    test('8. Reversing a transaction excludes it from active transactionsProvider list', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_tx_rev',
        name: 'Rev Bank',
        bank: 'SBI',
        balance: 0.0,
      ));

      await transactionRepo.insert(model.Transaction(
        id: 'tx_will_reverse',
        userId: 'user_1',
        type: 'expense',
        amount: 1200.0,
        date: DateTime.now(),
        accountId: 'acc_tx_rev',
        notes: 'Book purchase',
      ));

      var txList = await container.read(transactionsProvider.future);
      expect(txList.length, equals(1));

      // Delete via transactionRepo (creates reversal event)
      await transactionRepo.delete('tx_will_reverse');

      await container.read(transactionsProvider.notifier).refresh();
      txList = await container.read(transactionsProvider.future);
      expect(txList.isEmpty, isTrue); // Reversal and original filtered from active list
    });

    // -------------------------------------------------------------------------
    // Test 9: Soft-deleted legacy transactions are ignored by transactionsProvider
    // -------------------------------------------------------------------------
    test('9. Soft-deleted legacy transactions are ignored by transactionsProvider', () async {
      await db.insert(Tables.transactions, {
        'id': 'tx_legacy_soft_del',
        'notes': 'Soft Deleted Tx',
        'amount': 1500.0,
        'type': 'expense',
        'account_id': 'acc_dummy',
        'date': DateTime.now().toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'is_deleted': 1,
      });

      final txList = await container.read(transactionsProvider.future);
      expect(txList.any((t) => t.id == 'tx_legacy_soft_del'), isFalse);
    });

    // -------------------------------------------------------------------------
    // Test 10: paginatedTransactionsProvider loads canonical transactions
    // -------------------------------------------------------------------------
    test('10. paginatedTransactionsProvider loads canonical transactions and is unaffected by legacy tables', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_paginated',
        name: 'Paginated Bank',
        bank: 'SBI',
        balance: 0.0,
      ));

      for (var i = 1; i <= 5; i++) {
        await transactionRepo.insert(model.Transaction(
          id: 'tx_page_$i',
          userId: 'user_1',
          type: 'expense',
          amount: (i * 100).toDouble(),
          date: DateTime.now().add(Duration(minutes: i)),
          accountId: 'acc_paginated',
          notes: 'Item $i',
        ));
      }

      // Rogue row in legacy table
      await db.insert(Tables.transactions, {
        'id': 'tx_page_rogue',
        'notes': 'Rogue Page Item',
        'amount': 999.0,
        'type': 'expense',
        'account_id': 'acc_paginated',
        'date': DateTime.now().toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      final paginatedNotifier = container.read(paginatedTransactionsProvider.notifier);
      await paginatedNotifier.refresh();

      final paginatedState = container.read(paginatedTransactionsProvider);
      expect(paginatedState.items.length, equals(5));
      expect(paginatedState.items.any((t) => t.id == 'tx_page_rogue'), isFalse);
    });

    // -------------------------------------------------------------------------
    // Test 11: addAccountProvider creates canonical account and updates accountsProvider
    // -------------------------------------------------------------------------
    test('11. addAccountProvider creates canonical account with opening balance and updates accountsProvider', () async {
      // Initialize provider
      await container.read(accountsProvider.future);

      final newAccount = BankAccount(
        id: 'acc_add_provider',
        name: 'New Savings Account',
        bank: 'SBI',
        balance: 12000.0,
      );

      final addAccount = container.read(addAccountProvider);
      await addAccount(newAccount);

      final accounts = container.read(accountsProvider).value ?? [];
      expect(accounts.any((a) => a.id == 'acc_add_provider'), isTrue);

      final derived = await canonicalAccountRepo.getDerivedBalance('acc_add_provider');
      expect(derived.toRupees, equals(12000.0));
    });

    // -------------------------------------------------------------------------
    // Test 12: Multi-account balances in accountsProvider match CanonicalAccountRepository
    // -------------------------------------------------------------------------
    test('12. Multi-account balances in accountsProvider match CanonicalAccountRepository.getDerivedBalances', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_multi_1',
        name: 'Account 1',
        bank: 'SBI',
        balance: 10000.0,
      ));
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_multi_2',
        name: 'Account 2',
        bank: 'HDFC',
        balance: 20000.0,
      ));
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_multi_3',
        name: 'Account 3',
        bank: 'ICICI',
        balance: 30000.0,
      ));

      await container.read(accountsProvider.notifier).refresh();
      final accounts = await container.read(accountsProvider.future);

      final derivedMap = await canonicalAccountRepo.getDerivedBalances([
        'acc_multi_1',
        'acc_multi_2',
        'acc_multi_3',
      ]);

      for (final acc in accounts) {
        expect(acc.balance, equals(derivedMap[acc.id]!.toRupees));
      }
    });
  });
}
