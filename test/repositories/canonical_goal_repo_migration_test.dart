import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/transaction.dart' as model;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C3B-5: GoalRepo Canonical Migration Suite', () {
    late Database db;
    late GoalRepo goalRepo;
    late CanonicalEarmarkRepository earmarkRepo;
    late AccountRepo accountRepo;
    late TransactionRepo transactionRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalFinancialQueryRepository financialQueryRepo;

    // Helper: count rows in economic_events
    Future<int> countEvents() async {
      final res = await db.rawQuery('SELECT COUNT(*) AS c FROM ${TablesV24.economicEvents}');
      return (res.first['c'] as num).toInt();
    }

    // Helper: count rows in postings
    Future<int> countPostings() async {
      final res = await db.rawQuery('SELECT COUNT(*) AS c FROM ${TablesV24.postings}');
      return (res.first['c'] as num).toInt();
    }

    // Helper: setup standard asset bank account
    Future<void> setupBankAccount(String accountId, double initialBalance) async {
      await accountRepo.insertAccount(BankAccount(
        id: accountId,
        name: 'Primary Savings',
        balance: initialBalance,
        accountType: 'savings',
        isAsset: true,
        bank: 'HDFC',
        last4: '1234',
        color: '#000000',
        icon: 'bank',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ));
    }

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );

      // Create full schemas
      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      earmarkRepo = CanonicalEarmarkRepository(executor: db);
      goalRepo = GoalRepo(executor: db, earmarkRepo: earmarkRepo);
      accountRepo = AccountRepo(executor: db);
      transactionRepo = TransactionRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      financialQueryRepo = CanonicalFinancialQueryRepository(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    // ── 1. Goal Lifecycle (Tests 1 - 5) ───────────────────────────────────

    test('1. create goal -> zero events and zero postings', () async {
      final eventsBefore = await countEvents();
      final postingsBefore = await countPostings();

      final goal = Goal(
        id: 'goal_vacation',
        title: 'Europe Trip',
        type: GoalType.savings,
        targetAmount: 200000.0,
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2026, 12, 31),
      );

      await goalRepo.insert(goal);

      final eventsAfter = await countEvents();
      final postingsAfter = await countPostings();

      expect(eventsAfter, equals(eventsBefore));
      expect(postingsAfter, equals(postingsBefore));

      final fetched = await goalRepo.getGoalById('goal_vacation');
      expect(fetched, isNotNull);
      expect(fetched!.title, equals('Europe Trip'));
      expect(fetched.currentAmount, equals(0.0));
    });

    test('2. update goal -> zero events and zero postings', () async {
      final goal = Goal(
        id: 'goal_car',
        title: 'New Car',
        type: GoalType.savings,
        targetAmount: 500000.0,
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2027, 1, 1),
      );
      await goalRepo.insert(goal);

      final eventsBefore = await countEvents();
      final postingsBefore = await countPostings();

      final updated = goal.copyWith(targetAmount: 600000.0, title: 'EV Car');
      await goalRepo.update(updated);

      final eventsAfter = await countEvents();
      final postingsAfter = await countPostings();

      expect(eventsAfter, equals(eventsBefore));
      expect(postingsAfter, equals(postingsBefore));

      final fetched = await goalRepo.getGoalById('goal_car');
      expect(fetched!.title, equals('EV Car'));
      expect(fetched.targetAmount, equals(600000.0));
    });

    test('3. archive/delete goal -> zero events and zero postings', () async {
      final goal = Goal(
        id: 'goal_emergency',
        title: 'Emergency Fund',
        type: GoalType.savings,
        targetAmount: 100000.0,
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2026, 6, 30),
      );
      await goalRepo.insert(goal);

      final eventsBefore = await countEvents();
      final postingsBefore = await countPostings();

      await goalRepo.delete('goal_emergency');

      final eventsAfter = await countEvents();
      final postingsAfter = await countPostings();

      expect(eventsAfter, equals(eventsBefore));
      expect(postingsAfter, equals(postingsBefore));

      final fetched = await goalRepo.getGoalById('goal_emergency');
      expect(fetched, isNull);
    });

    test('4. goal with accounting history remains safe', () async {
      await setupBankAccount('bank_acc_1', 50000.0);
      final eventsBefore = await countEvents();

      final goal = Goal(
        id: 'goal_laptop',
        title: 'MacBook Pro',
        type: GoalType.savings,
        targetAmount: 150000.0,
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2026, 12, 31),
      );
      await goalRepo.insert(goal);

      // Create earmark
      await goalRepo.createEarmark(AssetEarmark(
        id: 'earmark_1',
        goalId: 'goal_laptop',
        assetAccountId: 'bank_acc_1',
        earmarkedAmount: Money.fromRupees(20000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Check accounting history is unchanged
      final eventsAfter = await countEvents();
      expect(eventsAfter, equals(eventsBefore));

      // Account balance remains exactly 50,000.0
      final balance = (await accountRepo.getById('bank_acc_1'))!.balance;
      expect(balance, equals(50000.0));
    });

    test('5. goal deletion does not delete accounting history', () async {
      await setupBankAccount('bank_acc_main', 80000.0);

      // Create a financial transaction
      await transactionRepo.insert(model.Transaction(
        id: 'tx_salary',
        userId: 'test_user',
        accountId: 'bank_acc_main',
        amount: 20000.0,
        type: 'income',
        date: DateTime.now(),
        notes: 'Monthly Salary',
      ));

      final eventsBefore = await countEvents();
      final postingsBefore = await countPostings();

      final goal = Goal(
        id: 'goal_retire',
        title: 'Retirement',
        type: GoalType.savings,
        targetAmount: 10000000.0,
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2050, 1, 1),
      );
      await goalRepo.insert(goal);
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_retire',
        goalId: 'goal_retire',
        assetAccountId: 'bank_acc_main',
        earmarkedAmount: Money.fromRupees(50000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Delete the goal
      await goalRepo.delete('goal_retire');

      // Accounting ledger MUST be strictly preserved
      final eventsAfter = await countEvents();
      final postingsAfter = await countPostings();
      expect(eventsAfter, equals(eventsBefore));
      expect(postingsAfter, equals(postingsBefore));

      // Verify the transaction still exists and is queryable
      final tx = await transactionRepo.getById('tx_salary');
      expect(tx, isNotNull);
      expect(tx!.amount, equals(20000.0));
    });

    // ── 2. Earmarks (Tests 6 - 16) ────────────────────────────────────────

    test('6. create earmark -> zero events and zero postings', () async {
      await setupBankAccount('bank_e6', 10000.0);
      final goal = Goal(
        id: 'goal_e6',
        title: 'Goal E6',
        type: GoalType.savings,
        targetAmount: 10000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      final eventsBefore = await countEvents();
      final postingsBefore = await countPostings();

      await goalRepo.createEarmark(AssetEarmark(
        id: 'earmark_e6',
        goalId: 'goal_e6',
        assetAccountId: 'bank_e6',
        earmarkedAmount: Money.fromRupees(5000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final eventsAfter = await countEvents();
      final postingsAfter = await countPostings();

      expect(eventsAfter, equals(eventsBefore));
      expect(postingsAfter, equals(postingsBefore));

      // Progress is derived as 5,000.0
      expect(await goalRepo.getDerivedProgress('goal_e6'), equals(5000.0));
    });

    test('7. update earmark -> zero events and zero postings', () async {
      await setupBankAccount('bank_e7', 20000.0);
      final goal = Goal(
        id: 'goal_e7',
        title: 'Goal E7',
        type: GoalType.savings,
        targetAmount: 20000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      final earmark = AssetEarmark(
        id: 'earmark_e7',
        goalId: 'goal_e7',
        assetAccountId: 'bank_e7',
        earmarkedAmount: Money.fromRupees(5000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await goalRepo.createEarmark(earmark);

      final eventsBefore = await countEvents();
      final postingsBefore = await countPostings();

      final updatedEarmark = earmark.copyWith(
        earmarkedAmount: Money.fromRupees(8000.0),
        updatedAt: DateTime.now(),
      );
      await earmarkRepo.updateEarmark(updatedEarmark);

      final eventsAfter = await countEvents();
      final postingsAfter = await countPostings();

      expect(eventsAfter, equals(eventsBefore));
      expect(postingsAfter, equals(postingsBefore));
      expect(await goalRepo.getDerivedProgress('goal_e7'), equals(8000.0));
    });

    test('8. delete earmark -> zero events and zero postings', () async {
      await setupBankAccount('bank_e8', 30000.0);
      final goal = Goal(
        id: 'goal_e8',
        title: 'Goal E8',
        type: GoalType.savings,
        targetAmount: 30000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'earmark_e8',
        goalId: 'goal_e8',
        assetAccountId: 'bank_e8',
        earmarkedAmount: Money.fromRupees(12000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final eventsBefore = await countEvents();
      final postingsBefore = await countPostings();

      await goalRepo.deleteEarmark('earmark_e8');

      final eventsAfter = await countEvents();
      final postingsAfter = await countPostings();

      expect(eventsAfter, equals(eventsBefore));
      expect(postingsAfter, equals(postingsBefore));
      expect(await goalRepo.getDerivedProgress('goal_e8'), equals(0.0));
    });

    test('9. duplicate (goal_id, account_id) rejected', () async {
      await setupBankAccount('bank_e9', 15000.0);
      final goal = Goal(
        id: 'goal_e9',
        title: 'Goal E9',
        type: GoalType.savings,
        targetAmount: 15000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'earmark_e9_1',
        goalId: 'goal_e9',
        assetAccountId: 'bank_e9',
        earmarkedAmount: Money.fromRupees(5000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Attempt second earmark for same goal and account pair
      final duplicate = AssetEarmark(
        id: 'earmark_e9_2',
        goalId: 'goal_e9',
        assetAccountId: 'bank_e9',
        earmarkedAmount: Money.fromRupees(3000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(
        () async => await goalRepo.createEarmark(duplicate),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('10. negative earmark rejected', () async {
      await setupBankAccount('bank_e10', 10000.0);
      final goal = Goal(
        id: 'goal_e10',
        title: 'Goal E10',
        type: GoalType.savings,
        targetAmount: 10000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      // Domain Money/AssetEarmark constructor rejects non-positive minor units
      expect(
        () => AssetEarmark(
          id: 'earmark_e10',
          goalId: 'goal_e10',
          assetAccountId: 'bank_e10',
          earmarkedAmount: Money.fromMinorUnits(-500),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        throwsA(isA<ArgumentError>()),
      );

      // Raw SQLite insert with negative amount is also rejected by CHECK constraint
      expect(
        () async => await db.insert(TablesV24.assetEarmarks, {
          'id': 'raw_neg_earmark',
          'goal_id': 'goal_e10',
          'asset_account_id': 'bank_e10',
          'amount_minor_units': -5000,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('11. invalid goal FK rejected', () async {
      await setupBankAccount('bank_e11', 10000.0);

      final earmark = AssetEarmark(
        id: 'earmark_e11',
        goalId: 'non_existent_goal',
        assetAccountId: 'bank_e11',
        earmarkedAmount: Money.fromRupees(2000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(
        () async => await goalRepo.createEarmark(earmark),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('12. invalid account FK rejected', () async {
      final goal = Goal(
        id: 'goal_e12',
        title: 'Goal E12',
        type: GoalType.savings,
        targetAmount: 10000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      final earmark = AssetEarmark(
        id: 'earmark_e12',
        goalId: 'goal_e12',
        assetAccountId: 'non_existent_account',
        earmarkedAmount: Money.fromRupees(2000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(
        () async => await goalRepo.createEarmark(earmark),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('13. multiple accounts -> one goal', () async {
      await setupBankAccount('bank_e13_a', 20000.0);
      await setupBankAccount('bank_e13_b', 30000.0);

      final goal = Goal(
        id: 'goal_e13',
        title: 'House Downpayment',
        type: GoalType.savings,
        targetAmount: 50000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 100)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_13_a',
        goalId: 'goal_e13',
        assetAccountId: 'bank_e13_a',
        earmarkedAmount: Money.fromRupees(15000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_13_b',
        goalId: 'goal_e13',
        assetAccountId: 'bank_e13_b',
        earmarkedAmount: Money.fromRupees(20000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Derived total progress sums both accounts
      final progress = await goalRepo.getDerivedProgress('goal_e13');
      expect(progress, equals(35000.0));

      final earmarks = await goalRepo.getEarmarks('goal_e13');
      expect(earmarks.length, equals(2));
    });

    test('14. multiple goals -> one account', () async {
      await setupBankAccount('bank_e14', 50000.0);

      final goal1 = Goal(
        id: 'goal_e14_1',
        title: 'Goal 1',
        type: GoalType.savings,
        targetAmount: 20000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      final goal2 = Goal(
        id: 'goal_e14_2',
        title: 'Goal 2',
        type: GoalType.savings,
        targetAmount: 30000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 60)),
      );
      await goalRepo.insert(goal1);
      await goalRepo.insert(goal2);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_14_1',
        goalId: 'goal_e14_1',
        assetAccountId: 'bank_e14',
        earmarkedAmount: Money.fromRupees(10000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_14_2',
        goalId: 'goal_e14_2',
        assetAccountId: 'bank_e14',
        earmarkedAmount: Money.fromRupees(15000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Check total reservations against the single bank account
      final totalEarmarked = await goalRepo.getTotalEarmarkedForAccount('bank_e14');
      expect(totalEarmarked.toRupees, equals(25000.0));

      // Independent goal progress
      expect(await goalRepo.getDerivedProgress('goal_e14_1'), equals(10000.0));
      expect(await goalRepo.getDerivedProgress('goal_e14_2'), equals(15000.0));
    });

    test('15. derived total earmark amount matches minor units sum', () async {
      await setupBankAccount('bank_e15', 100000.0);

      final goal = Goal(
        id: 'goal_e15',
        title: 'Investment Goal',
        type: GoalType.savings,
        targetAmount: 100000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 90)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_15',
        goalId: 'goal_e15',
        assetAccountId: 'bank_e15',
        earmarkedAmount: Money.fromMinorUnits(452550), // 4,525.50
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final progress = await goalRepo.getDerivedProgress('goal_e15');
      expect(progress, equals(4525.50));
    });

    test('16. archived goal cannot retain active earmark', () async {
      await setupBankAccount('bank_e16', 50000.0);

      final goal = Goal(
        id: 'goal_e16',
        title: 'Goal to Archive',
        type: GoalType.savings,
        targetAmount: 20000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_16',
        goalId: 'goal_e16',
        assetAccountId: 'bank_e16',
        earmarkedAmount: Money.fromRupees(10000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Deleting/archiving the goal releases its active earmarks
      await goalRepo.delete('goal_e16');

      final remainingEarmarks = await earmarkRepo.getEarmarksForGoal('goal_e16');
      expect(remainingEarmarks, isEmpty);

      final totalEarmarked = await goalRepo.getTotalEarmarkedForAccount('bank_e16');
      expect(totalEarmarked.toRupees, equals(0.0));

      // Re-inserting with is_active = 0 and trying to earmark is rejected
      await db.insert(Tables.goals, goal.copyWith(isActive: false).toMap());
      final attemptArchived = AssetEarmark(
        id: 'em_16_fail',
        goalId: 'goal_e16',
        assetAccountId: 'bank_e16',
        earmarkedAmount: Money.fromRupees(5000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(
        () async => await goalRepo.createEarmark(attemptArchived),
        throwsA(isA<StateError>()),
      );
    });

    // ── 3. Accounting Separation (Tests 17 - 24) ──────────────────────────

    test('17. earmark does not change account balance', () async {
      await setupBankAccount('bank_e17', 50000.0);
      final balanceBefore = (await accountRepo.getById('bank_e17'))!.balance;

      final goal = Goal(
        id: 'goal_e17',
        title: 'Goal E17',
        type: GoalType.savings,
        targetAmount: 50000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_17',
        goalId: 'goal_e17',
        assetAccountId: 'bank_e17',
        earmarkedAmount: Money.fromRupees(30000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final balanceAfter = (await accountRepo.getById('bank_e17'))!.balance;
      expect(balanceAfter, equals(balanceBefore));
    });

    test('18. earmark does not change net worth', () async {
      await setupBankAccount('bank_e18', 60000.0);
      final netWorthBefore = await financialQueryRepo.getNetWorth();

      final goal = Goal(
        id: 'goal_e18',
        title: 'Goal E18',
        type: GoalType.savings,
        targetAmount: 60000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_18',
        goalId: 'goal_e18',
        assetAccountId: 'bank_e18',
        earmarkedAmount: Money.fromRupees(25000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final netWorthAfter = await financialQueryRepo.getNetWorth();
      expect(netWorthAfter.toRupees, equals(netWorthBefore.toRupees));
    });

    test('19. earmark does not change income', () async {
      await setupBankAccount('bank_e19', 40000.0);
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, 1);
      final end = DateTime(now.year, now.month + 1, 0);

      final incomeBefore = await financialQueryRepo.getTotalIncome(startDate: start, endDate: end);

      final goal = Goal(
        id: 'goal_e19',
        title: 'Goal E19',
        type: GoalType.savings,
        targetAmount: 40000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_19',
        goalId: 'goal_e19',
        assetAccountId: 'bank_e19',
        earmarkedAmount: Money.fromRupees(20000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final incomeAfter = await financialQueryRepo.getTotalIncome(startDate: start, endDate: end);
      expect(incomeAfter.toRupees, equals(incomeBefore.toRupees));
    });

    test('20. earmark does not change expense', () async {
      await setupBankAccount('bank_e20', 40000.0);
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, 1);
      final end = DateTime(now.year, now.month + 1, 0);

      final expenseBefore = await financialQueryRepo.getTotalExpenses(startDate: start, endDate: end);

      final goal = Goal(
        id: 'goal_e20',
        title: 'Goal E20',
        type: GoalType.savings,
        targetAmount: 40000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_20',
        goalId: 'goal_e20',
        assetAccountId: 'bank_e20',
        earmarkedAmount: Money.fromRupees(15000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final expenseAfter = await financialQueryRepo.getTotalExpenses(startDate: start, endDate: end);
      expect(expenseAfter.toRupees, equals(expenseBefore.toRupees));
    });

    test('21. earmark does not create economic event', () async {
      await setupBankAccount('bank_e21', 10000.0);
      final goal = Goal(
        id: 'goal_e21',
        title: 'Goal E21',
        type: GoalType.savings,
        targetAmount: 10000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      final eventsBefore = await countEvents();

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_21',
        goalId: 'goal_e21',
        assetAccountId: 'bank_e21',
        earmarkedAmount: Money.fromRupees(5000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final eventsAfter = await countEvents();
      expect(eventsAfter, equals(eventsBefore));
    });

    test('22. earmark does not create posting', () async {
      await setupBankAccount('bank_e22', 10000.0);
      final goal = Goal(
        id: 'goal_e22',
        title: 'Goal E22',
        type: GoalType.savings,
        targetAmount: 10000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      final postingsBefore = await countPostings();

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_22',
        goalId: 'goal_e22',
        assetAccountId: 'bank_e22',
        earmarkedAmount: Money.fromRupees(4000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final postingsAfter = await countPostings();
      expect(postingsAfter, equals(postingsBefore));
    });

    test('23. actual transfer remains a canonical transfer', () async {
      await setupBankAccount('bank_src', 50000.0);
      await setupBankAccount('bank_dst', 10000.0);

      final eventsBefore = await countEvents();
      final postingsBefore = await countPostings();

      // Real transfer of funds between accounts
      await transactionRepo.insert(model.Transaction(
        id: 'tx_transfer_1',
        userId: 'test_user',
        accountId: 'bank_src',
        relatedEntityId: 'bank_dst',
        amount: 20000.0,
        type: 'transfer',
        date: DateTime.now(),
        notes: 'Move funds to savings',
      ));

      final eventsAfter = await countEvents();
      final postingsAfter = await countPostings();

      // Canonical transfer creates 1 event and 2 postings
      expect(eventsAfter, equals(eventsBefore + 1));
      expect(postingsAfter, equals(postingsBefore + 2));

      // Balances update accurately
      expect((await accountRepo.getById('bank_src'))!.balance, equals(30000.0));
      expect((await accountRepo.getById('bank_dst'))!.balance, equals(30000.0));
    });

    test('24. transfer + earmark remain separate concepts', () async {
      await setupBankAccount('bank_checking', 50000.0);
      await setupBankAccount('bank_savings', 0.0);

      // 1. Move real money to savings account
      await transactionRepo.insert(model.Transaction(
        id: 'tx_xfer_24',
        userId: 'test_user',
        accountId: 'bank_checking',
        relatedEntityId: 'bank_savings',
        amount: 25000.0,
        type: 'transfer',
        date: DateTime.now(),
        notes: 'Fund savings for goal',
      ));

      final eventsAfterXfer = await countEvents();
      final postingsAfterXfer = await countPostings();

      // 2. Set goal earmark on savings account
      final goal = Goal(
        id: 'goal_e24',
        title: 'New Computer',
        type: GoalType.savings,
        targetAmount: 25000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 60)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_24',
        goalId: 'goal_e24',
        assetAccountId: 'bank_savings',
        earmarkedAmount: Money.fromRupees(25000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Earmark created ZERO additional events or postings
      expect(await countEvents(), equals(eventsAfterXfer));
      expect(await countPostings(), equals(postingsAfterXfer));

      // Bank savings still physically holds 25,000.0
      expect((await accountRepo.getById('bank_savings'))!.balance, equals(25000.0));
      // Goal progress derived is 25,000.0
      expect(await goalRepo.getDerivedProgress('goal_e24'), equals(25000.0));
    });

    // ── 4. Legacy Compatibility (Tests 25 - 27) ───────────────────────────

    test('25. current_amount cannot become financial truth', () async {
      await setupBankAccount('bank_e25', 40000.0);
      final goal = Goal(
        id: 'goal_e25',
        title: 'Goal E25',
        type: GoalType.savings,
        targetAmount: 50000.0,
        currentAmount: 10000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      // Create earmark of 15,000.0
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_25',
        goalId: 'goal_e25',
        assetAccountId: 'bank_e25',
        earmarkedAmount: Money.fromRupees(15000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Derived progress from earmarks overrides legacy column
      final fetched = await goalRepo.getGoalById('goal_e25');
      expect(fetched!.currentAmount, equals(15000.0));

      // Directly hacking goals.current_amount does NOT alter derived progress
      await db.rawUpdate(
        'UPDATE ${Tables.goals} SET current_amount = 999999.0 WHERE id = ?',
        ['goal_e25'],
      );

      final progress = await goalRepo.getDerivedProgress('goal_e25');
      expect(progress, equals(15000.0));
    });

    test('26. legacy projection remains consistent', () async {
      await setupBankAccount('bank_e26', 30000.0);
      final goal = Goal(
        id: 'goal_e26',
        title: 'Goal E26',
        type: GoalType.savings,
        targetAmount: 30000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_26',
        goalId: 'goal_e26',
        assetAccountId: 'bank_e26',
        earmarkedAmount: Money.fromRupees(12000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // getAll() and getActive() return projected goals with derived progress
      final allGoals = await goalRepo.getAll();
      final targetGoal = allGoals.firstWhere((g) => g.id == 'goal_e26');
      expect(targetGoal.currentAmount, equals(12000.0));

      final activeGoals = await goalRepo.getActive();
      final activeTarget = activeGoals.firstWhere((g) => g.id == 'goal_e26');
      expect(activeTarget.currentAmount, equals(12000.0));
    });

    test('27. no legacy balance mutation can alter canonical accounting', () async {
      await setupBankAccount('bank_e27', 50000.0);
      final eventsBefore = await countEvents();
      final postingsBefore = await countPostings();

      final goal = Goal(
        id: 'goal_e27',
        title: 'Goal E27',
        type: GoalType.savings,
        targetAmount: 50000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      // Mutate legacy current_amount directly
      await goalRepo.updateProgress('goal_e27', 45000.0);

      // Verify ZERO accounting side effects
      expect(await countEvents(), equals(eventsBefore));
      expect(await countPostings(), equals(postingsBefore));

      // Account balance remains exactly 50,000.0
      expect((await accountRepo.getById('bank_e27'))!.balance, equals(50000.0));
    });

    // ── 5. Atomicity (Tests 28 - 30) ──────────────────────────────────────

    test('28. earmark creation rollback on error leaves zero partial state', () async {
      await setupBankAccount('bank_e28', 20000.0);
      final goal = Goal(
        id: 'goal_e28',
        title: 'Goal E28',
        type: GoalType.savings,
        targetAmount: 20000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      final earmark = AssetEarmark(
        id: 'em_28',
        goalId: 'goal_e28',
        assetAccountId: 'bank_e28',
        earmarkedAmount: Money.fromRupees(5000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Execute transaction with failure after earmark creation
      try {
        await db.transaction((txn) async {
          await goalRepo.createEarmark(earmark, txn: txn);
          // Trigger failure
          throw Exception('Forced rollback');
        });
      } catch (_) {}

      // Earmark was rolled back cleanly
      final fetched = await earmarkRepo.getEarmark('em_28');
      expect(fetched, isNull);
      expect(await goalRepo.getDerivedProgress('goal_e28'), equals(0.0));
    });

    test('29. earmark update rollback leaves original state intact', () async {
      await setupBankAccount('bank_e29', 20000.0);
      final goal = Goal(
        id: 'goal_e29',
        title: 'Goal E29',
        type: GoalType.savings,
        targetAmount: 20000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      final earmark = AssetEarmark(
        id: 'em_29',
        goalId: 'goal_e29',
        assetAccountId: 'bank_e29',
        earmarkedAmount: Money.fromRupees(5000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await goalRepo.createEarmark(earmark);

      // Attempt update with transaction failure
      try {
        await db.transaction((txn) async {
          final updated = earmark.copyWith(
            earmarkedAmount: Money.fromRupees(15000.0),
            updatedAt: DateTime.now(),
          );
          await earmarkRepo.updateEarmark(updated, txn: txn);
          throw Exception('Forced update rollback');
        });
      } catch (_) {}

      // Original earmark amount remains 5,000.0
      final fetched = await earmarkRepo.getEarmark('em_29');
      expect(fetched!.earmarkedAmount.toRupees, equals(5000.0));
      expect(await goalRepo.getDerivedProgress('goal_e29'), equals(5000.0));
    });

    test('30. goal deletion rollback preserves goal and earmarks', () async {
      await setupBankAccount('bank_e30', 20000.0);
      final goal = Goal(
        id: 'goal_e30',
        title: 'Goal E30',
        type: GoalType.savings,
        targetAmount: 20000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_30',
        goalId: 'goal_e30',
        assetAccountId: 'bank_e30',
        earmarkedAmount: Money.fromRupees(7000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Attempt goal deletion in a failing transaction
      try {
        await db.transaction((txn) async {
          await goalRepo.delete('goal_e30', txn: txn);
          throw Exception('Forced delete rollback');
        });
      } catch (_) {}

      // Both goal and earmark still exist
      final fetchedGoal = await goalRepo.getGoalById('goal_e30');
      expect(fetchedGoal, isNotNull);

      final fetchedEarmark = await earmarkRepo.getEarmark('em_30');
      expect(fetchedEarmark, isNotNull);
      expect(await goalRepo.getDerivedProgress('goal_e30'), equals(7000.0));
    });

    // ── 6. Regressions (Tests 31 - 34) ────────────────────────────────────

    test('31. C3B-1 regression: TransactionRepo operations alongside GoalRepo', () async {
      await setupBankAccount('bank_reg_31', 50000.0);
      final goal = Goal(
        id: 'goal_reg_31',
        title: 'Goal 31',
        type: GoalType.savings,
        targetAmount: 20000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      // Create earmark
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_reg_31',
        goalId: 'goal_reg_31',
        assetAccountId: 'bank_reg_31',
        earmarkedAmount: Money.fromRupees(10000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Perform standard transaction
      await transactionRepo.insert(model.Transaction(
        id: 'tx_reg_31',
        userId: 'test_user',
        accountId: 'bank_reg_31',
        amount: 5000.0,
        type: 'expense',
        date: DateTime.now(),
        notes: 'Dinner',
      ));

      // Ledger balance decreases by 5,000.0
      expect((await accountRepo.getById('bank_reg_31'))!.balance, equals(45000.0));
      // Earmark progress remains intact
      expect(await goalRepo.getDerivedProgress('goal_reg_31'), equals(10000.0));
    });

    test('32. C3B-2 regression: AccountRepo operations alongside GoalRepo', () async {
      await setupBankAccount('bank_reg_32', 30000.0);
      final goal = Goal(
        id: 'goal_reg_32',
        title: 'Goal 32',
        type: GoalType.savings,
        targetAmount: 30000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_reg_32',
        goalId: 'goal_reg_32',
        assetAccountId: 'bank_reg_32',
        earmarkedAmount: Money.fromRupees(15000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Account reconciliation via updateBalance
      await accountRepo.updateBalance('bank_reg_32', 35000.0);

      // Account balance reconciled
      expect((await accountRepo.getById('bank_reg_32'))!.balance, equals(35000.0));
      // Earmark still intact
      expect(await goalRepo.getDerivedProgress('goal_reg_32'), equals(15000.0));
    });

    test('33. C3B-3 regression: CreditRepo operations alongside GoalRepo', () async {
      await setupBankAccount('bank_reg_33', 50000.0);
      await creditRepo.insert(CreditCard(
        id: 'card_reg_33',
        name: 'Axis Bank Card',
        bank: 'Axis',
        last4: '9999',
        limitAmount: 100000.0,
        billingDay: 15,
        dueDay: 5,
        color: '#000000',
        createdAt: DateTime.now(),
      ));

      final goal = Goal(
        id: 'goal_reg_33',
        title: 'Goal 33',
        type: GoalType.savings,
        targetAmount: 20000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_reg_33',
        goalId: 'goal_reg_33',
        assetAccountId: 'bank_reg_33',
        earmarkedAmount: Money.fromRupees(10000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Card transaction
      await creditRepo.insertTransaction(CreditTransaction(
        id: 'ctx_reg_33',
        cardId: 'card_reg_33',
        amount: 8000.0,
        type: 'purchase',
        status: 'active',
        category: 'Travel',
        date: DateTime.now(),
      ));

      // Card liability is 8,000.0
      expect((await canonicalAccountRepo.getDerivedBalance('card_reg_33')).toRupees, equals(8000.0));
      // Bank balance is unaffected
      expect((await accountRepo.getById('bank_reg_33'))!.balance, equals(50000.0));
      // Goal progress is unaffected
      expect(await goalRepo.getDerivedProgress('goal_reg_33'), equals(10000.0));
    });

    test('34. C3B-4 regression: LoanRepo operations alongside GoalRepo', () async {
      await setupBankAccount('bank_reg_34', 60000.0);

      // Create loan
      await loanRepo.insertLoan(Loan(
        id: 'loan_701',
        name: 'Personal Loan',
        bank: 'SBI',
        total: 100000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 8800.0,
        startDate: DateTime.now(),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 5,
      ));

      final goal = Goal(
        id: 'goal_reg_34',
        title: 'Goal 34',
        type: GoalType.savings,
        targetAmount: 30000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_reg_34',
        goalId: 'goal_reg_34',
        assetAccountId: 'bank_reg_34',
        earmarkedAmount: Money.fromRupees(20000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Loan repayment from bank account
      await loanRepo.recordRepayment(
        loanId: 'loan_701',
        assetAccountId: 'bank_reg_34',
        principalAmount: 15000.0,
        timestamp: DateTime.now(),
      );

      // Loan liability reduces to 85,000.0
      expect((await loanRepo.getDerivedBalance('loan_701')).toRupees, equals(85000.0));
      // Bank balance reduces to 45,000.0
      expect((await accountRepo.getById('bank_reg_34'))!.balance, equals(45000.0));
      // Goal progress remains 20,000.0
      expect(await goalRepo.getDerivedProgress('goal_reg_34'), equals(20000.0));
    });
  });
}
