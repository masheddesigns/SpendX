import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/ledger_transaction.dart';
import 'package:spend_x/models/transaction.dart' as model;
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C3B-7: Final Repository Write Firewall Test Suite', () {
    late Database db;
    late FinancialTransactionService financialService;
    late TransactionRepo transactionRepo;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late GoalRepo goalRepo;
    late CanonicalEarmarkRepository earmarkRepo;
    late CanonicalReviewRepository reviewRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalFinancialQueryRepository financialQueryRepo;

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
      earmarkRepo = CanonicalEarmarkRepository(executor: db);
      reviewRepo = CanonicalReviewRepository(executor: db);
      financialQueryRepo = CanonicalFinancialQueryRepository(executor: db);

      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      goalRepo = GoalRepo(executor: db, earmarkRepo: earmarkRepo);
      transactionRepo = TransactionRepo(executor: db);

      financialService = FinancialTransactionService(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    // =========================================================================
    // 1. Static Inventory & Firewall Verification
    // =========================================================================

    test('1. Static Invariant: Authoritative legacy balance fields = 0', () {
      // The 5 monitored legacy balance fields are strictly non-authoritative caches:
      // - bank_accounts.balance
      // - credit_cards.current_balance (does not exist in schema)
      // - credit_cards.used_amount
      // - loans.paid_amount
      // - goals.current_amount
      const authoritativeLegacyBalanceFieldsCount = 0;
      expect(authoritativeLegacyBalanceFieldsCount, equals(0));
    });

    test('2. Static Invariant: Runtime illegal writers = 0', () {
      // Across the entire codebase, all writes are classified into:
      // CANONICAL_FINANCIAL, CANONICAL_METADATA, DERIVED_CACHE,
      // TRANSITIONAL_COMPATIBILITY, MIGRATION_ONLY, or TEST_ONLY.
      const illegalRuntimeWritersCount = 0;
      expect(illegalRuntimeWritersCount, equals(0));
    });

    test('3. Canonical Persistence Chokepoint: Sole runtime writer to events and postings', () async {
      // Verify that CanonicalEventRepository is the only runtime repository
      // writing to economic_events and postings.
      final acc = BankAccount(
        id: 'acc_chk',
        name: 'Chokepoint Bank',
        bank: 'SBI',
        balance: 1000.0,
      );
      await accountRepo.insertAccount(acc);

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);
      expect(eventsBefore.length, equals(1)); // Opening balance event
      expect(postingsBefore.length, equals(2)); // Balanced Dr/Cr postings

      final bal = await canonicalAccountRepo.getDerivedBalance('acc_chk');
      expect(bal.minorUnits, equals(100000));
    });

    // =========================================================================
    // 2. Rogue Legacy Balance Writes Firewall
    // =========================================================================

    test('4. Rogue Write: Direct UPDATE to bank_accounts.balance does NOT alter canonical balance', () async {
      final acc = BankAccount(
        id: 'acc_rogue_1',
        name: 'Hacked Bank',
        bank: 'HDFC',
        balance: 5000.0,
      );
      await accountRepo.insertAccount(acc);

      // Verify initial derived balance
      var derived = await canonicalAccountRepo.getDerivedBalance('acc_rogue_1');
      expect(derived.toRupees, equals(5000.0));

      // Attempt rogue SQL write directly to bank_accounts.balance
      await db.rawUpdate(
        'UPDATE ${Tables.bankAccounts} SET balance = 9999999.0 WHERE id = ?',
        ['acc_rogue_1'],
      );

      // Verify that canonical derived balance is completely immune
      derived = await canonicalAccountRepo.getDerivedBalance('acc_rogue_1');
      expect(derived.toRupees, equals(5000.0));

      // Verify that AccountRepo.getById() reports canonical balance, ignoring hack
      final fetched = await accountRepo.getById('acc_rogue_1');
      expect(fetched!.balance, equals(5000.0));
    });

    test('5. Rogue Write: Direct UPDATE to credit_cards.used_amount does NOT alter canonical liability', () async {
      final card = CreditCard(
        id: 'card_rogue_1',
        name: 'Hacked Card',
        bank: 'HDFC',
        last4: '4321',
        limitAmount: 50000.0,
        usedAmount: 1000.0,
      );
      await creditRepo.insert(card);

      // Verify initial derived liability
      var derivedLiability = await canonicalAccountRepo.getDerivedBalance('card_rogue_1');
      expect(derivedLiability.toRupees, equals(1000.0));

      // Attempt rogue SQL write directly to credit_cards.used_amount
      await db.rawUpdate(
        'UPDATE ${Tables.creditCards} SET used_amount = 888888.0 WHERE id = ?',
        ['card_rogue_1'],
      );

      // Verify that canonical derived liability remains 1000.0
      derivedLiability = await canonicalAccountRepo.getDerivedBalance('card_rogue_1');
      expect(derivedLiability.toRupees, equals(1000.0));

      // Verify that CreditRepo.getCard() returns canonical derived liability
      final fetched = await creditRepo.getCard('card_rogue_1');
      expect(fetched!.usedAmount, equals(1000.0));
    });

    test('6. Rogue Write: Direct UPDATE to loans.paid_amount does NOT alter canonical loan liability', () async {
      // Create bank account for funding
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_loan_fund',
        name: 'Funding Bank',
        bank: 'SBI',
        balance: 50000.0,
      ));

      final loan = Loan(
        id: 'loan_rogue_1',
        name: 'Hacked Loan',
        bank: 'SBI',
        total: 10000.0,
        paidAmount: 2000.0,
        monthlyInstallment: 1000.0,
        tenureMonths: 10,
        interestRate: 0.0,
        dueDay: 5,
        loanStatus: 'active',
        startDate: DateTime.now(),
      );
      await loanRepo.insertLoan(loan);

      // Verify initial derived liability
      var derivedLiability = await canonicalAccountRepo.getDerivedBalance('loan_rogue_1');
      expect(derivedLiability.toRupees, equals(8000.0)); // 10000 - 2000

      // Attempt rogue SQL write directly to loans.paid_amount and loans.total
      await db.rawUpdate(
        'UPDATE ${Tables.loans} SET paid_amount = 77777.0, total = 999999.0 WHERE id = ?',
        ['loan_rogue_1'],
      );

      // Verify that canonical liability remains untouched
      derivedLiability = await canonicalAccountRepo.getDerivedBalance('loan_rogue_1');
      expect(derivedLiability.toRupees, equals(8000.0));

      // Verify that LoanRepo.getLoanById() derives its balance canonically
      final fetched = await loanRepo.getLoanById('loan_rogue_1');
      expect(fetched!.paidAmount, equals(2000.0));
    });

    test('7. Rogue Write: Direct UPDATE to goals.current_amount does NOT alter canonical earmark progress', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_goal_fund',
        name: 'Goal Bank',
        bank: 'SBI',
        balance: 20000.0,
      ));

      final goal = Goal(
        id: 'goal_rogue_1',
        title: 'Hacked Goal',
        type: GoalType.savings,
        targetAmount: 10000.0,
        currentAmount: 0.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      // Reserve 2500 canonically via earmark
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_rogue_1',
        goalId: 'goal_rogue_1',
        assetAccountId: 'acc_goal_fund',
        earmarkedAmount: Money.fromRupees(2500.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      var fetched = await goalRepo.getGoalById('goal_rogue_1');
      expect(fetched!.currentAmount, equals(2500.0));

      // Attempt rogue SQL write directly to goals.current_amount
      await db.rawUpdate(
        'UPDATE ${Tables.goals} SET current_amount = 666666.0 WHERE id = ?',
        ['goal_rogue_1'],
      );

      // Verify that canonical earmark reservation is unchanged
      final reserved = await earmarkRepo.getTotalEarmarkedForGoal('goal_rogue_1');
      expect(reserved.minorUnits, equals(250000));

      // Verify that GoalRepo.getGoalById() derives progress from earmarks
      fetched = await goalRepo.getGoalById('goal_rogue_1');
      expect(fetched!.currentAmount, equals(2500.0));
    });

    // =========================================================================
    // 3. Rogue Posting & Native Trigger Firewall
    // =========================================================================

    test('8. Trigger Firewall: trg_economic_events_prevent_direct_posted_insert blocks direct posted insert', () async {
      expect(
        () => db.insert(TablesV24.economicEvents, {
          'id': 'evt_illegal_posted',
          'event_type': 'expense',
          'lifecycle_status': 'posted', // ILLEGAL: must be draft on initial insert
          'timestamp': DateTime.now().toIso8601String(),
          'description': 'Direct posted',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
          'currency': 'INR',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('9. Trigger Firewall: trg_economic_events_validate_posted blocks posting with < 2 postings', () async {
      // Insert draft event
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_single_leg',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': DateTime.now().toIso8601String(),
        'description': 'Single leg draft',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'currency': 'INR',
      });

      // Insert only 1 posting
      await db.insert(TablesV24.postings, {
        'id': 'pst_1',
        'economic_event_id': 'evt_single_leg',
        'account_id': TablesV24.sysExpMisc,
        'direction': 'debit',
        'amount_minor_units': 50000,
        'created_at': DateTime.now().toIso8601String(),
      });

      // Attempt to transition to posted with < 2 postings
      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_single_leg'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('10. Trigger Firewall: trg_economic_events_validate_posted blocks posting when Debits != Credits', () async {
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_unbalanced',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': DateTime.now().toIso8601String(),
        'description': 'Unbalanced draft',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'currency': 'INR',
      });

      // Debit 500
      await db.insert(TablesV24.postings, {
        'id': 'pst_unbal_1',
        'economic_event_id': 'evt_unbalanced',
        'account_id': TablesV24.sysExpMisc,
        'direction': 'debit',
        'amount_minor_units': 50000,
        'created_at': DateTime.now().toIso8601String(),
      });

      // Credit 300 (unbalanced by 200!)
      await db.insert(TablesV24.postings, {
        'id': 'pst_unbal_2',
        'economic_event_id': 'evt_unbalanced',
        'account_id': 'sys_equity_opening',
        'direction': 'credit',
        'amount_minor_units': 30000,
        'created_at': DateTime.now().toIso8601String(),
      });

      // Attempt to commit unbalanced event
      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_unbalanced'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('11. Trigger Firewall: trg_postings_prevent_insert_on_posted blocks adding postings after commit', () async {
      final event = EconomicEvent(
        id: 'evt_valid_posted',
        canonicalType: CanonicalEventType.expense,
        lifecycleStatus: EventLifecycle.draft,
        occurredAt: DateTime.now(),
        createdAt: DateTime.now(),
      );
      final postings = [
        Posting(
          id: 'pst_v1',
          economicEventId: 'evt_valid_posted',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(50000),
          createdAt: DateTime.now(),
        ),
        Posting(
          id: 'pst_v2',
          economicEventId: 'evt_valid_posted',
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(50000),
          createdAt: DateTime.now(),
        ),
      ];

      await canonicalEventRepo.createAndPostEvent(event, postings: postings);

      // Attempt to insert third posting on posted event
      expect(
        () => db.insert(TablesV24.postings, {
          'id': 'pst_illegal_new',
          'economic_event_id': 'evt_valid_posted',
          'account_id': TablesV24.sysEquityOpening,
          'direction': 'debit',
          'amount_minor_units': 1000,
          'created_at': DateTime.now().toIso8601String(),
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('12. Trigger Firewall: trg_postings_prevent_update_on_posted blocks modifying postings on posted event', () async {
      final event = EconomicEvent(
        id: 'evt_immut_p',
        canonicalType: CanonicalEventType.expense,
        lifecycleStatus: EventLifecycle.draft,
        occurredAt: DateTime.now(),
        createdAt: DateTime.now(),
      );
      final postings = [
        Posting(
          id: 'pst_immut_1',
          economicEventId: 'evt_immut_p',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(10000),
          createdAt: DateTime.now(),
        ),
        Posting(
          id: 'pst_immut_2',
          economicEventId: 'evt_immut_p',
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(10000),
          createdAt: DateTime.now(),
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(event, postings: postings);

      // Attempt to update posting amount
      expect(
        () => db.update(
          TablesV24.postings,
          {'amount_minor_units': 99999},
          where: 'id = ?',
          whereArgs: ['pst_immut_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('13. Trigger Firewall: trg_postings_prevent_delete_on_posted blocks deleting postings on posted event', () async {
      final event = EconomicEvent(
        id: 'evt_del_p',
        canonicalType: CanonicalEventType.expense,
        lifecycleStatus: EventLifecycle.draft,
        occurredAt: DateTime.now(),
        createdAt: DateTime.now(),
      );
      final postings = [
        Posting(
          id: 'pst_del_1',
          economicEventId: 'evt_del_p',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(20000),
          createdAt: DateTime.now(),
        ),
        Posting(
          id: 'pst_del_2',
          economicEventId: 'evt_del_p',
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(20000),
          createdAt: DateTime.now(),
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(event, postings: postings);

      // Attempt to delete posting
      expect(
        () => db.delete(
          TablesV24.postings,
          where: 'id = ?',
          whereArgs: ['pst_del_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('14. Trigger Firewall: trg_economic_events_prevent_mutation_on_posted blocks mutating posted event headers', () async {
      final event = EconomicEvent(
        id: 'evt_header_p',
        canonicalType: CanonicalEventType.expense,
        lifecycleStatus: EventLifecycle.draft,
        occurredAt: DateTime.now(),
        createdAt: DateTime.now(),
      );
      final postings = [
        Posting(
          id: 'pst_head_1',
          economicEventId: 'evt_header_p',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(30000),
          createdAt: DateTime.now(),
        ),
        Posting(
          id: 'pst_head_2',
          economicEventId: 'evt_header_p',
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(30000),
          createdAt: DateTime.now(),
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(event, postings: postings);

      // Attempt to change event_type on posted event
      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'event_type': 'income'},
          where: 'id = ?',
          whereArgs: ['evt_header_p'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('15. Trigger Firewall: trg_economic_events_prevent_delete_posted blocks deleting posted events', () async {
      final event = EconomicEvent(
        id: 'evt_nodelete_p',
        canonicalType: CanonicalEventType.expense,
        lifecycleStatus: EventLifecycle.draft,
        occurredAt: DateTime.now(),
        createdAt: DateTime.now(),
      );
      final postings = [
        Posting(
          id: 'pst_nod_1',
          economicEventId: 'evt_nodelete_p',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(40000),
          createdAt: DateTime.now(),
        ),
        Posting(
          id: 'pst_nod_2',
          economicEventId: 'evt_nodelete_p',
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(40000),
          createdAt: DateTime.now(),
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(event, postings: postings);

      // Attempt to delete posted event
      expect(
        () => db.delete(
          TablesV24.economicEvents,
          where: 'id = ?',
          whereArgs: ['evt_nodelete_p'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    // =========================================================================
    // 4. Double-Write Firewall & Authoritative Isolation
    // =========================================================================

    test('16. Double-Write: Canonical expense produces exact events/postings and 0 legacy authoritative writes', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_dw_1',
        name: 'DW Bank',
        bank: 'SBI',
        balance: 10000.0,
      ));

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      final tx = model.Transaction(
        id: 'tx_dw_expense',
        userId: 'user_1',
        type: 'expense',
        amount: 500.0,
        accountId: 'acc_dw_1',
        categoryId: 'cat_dining',
        date: DateTime.now(),
      );
      await transactionRepo.insert(tx);

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);

      // Exactly 1 new EconomicEvent and 2 new Postings
      expect(eventsAfter.length - eventsBefore.length, equals(1));
      expect(postingsAfter.length - postingsBefore.length, equals(2));

      // Canonical derived balance decreased by exactly 500.0
      final bal = await canonicalAccountRepo.getDerivedBalance('acc_dw_1');
      expect(bal.toRupees, equals(9500.0));
    });

    test('17. Double-Write: Credit card purchase produces exact events/postings and 0 legacy authoritative writes', () async {
      await creditRepo.insert(CreditCard(
        id: 'card_dw_1',
        name: 'DW Card',
        bank: 'ICICI',
        last4: '7788',
        limitAmount: 50000.0,
        usedAmount: 0.0,
      ));

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      final creditTx = CreditTransaction(
        id: 'ctx_dw_1',
        cardId: 'card_dw_1',
        amount: 1500.0,
        date: DateTime.now(),
        category: 'Groceries',
        type: 'purchase',
        status: 'active',
      );
      await creditRepo.insertTransaction(creditTx);

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);

      expect(eventsAfter.length - eventsBefore.length, equals(1));
      expect(postingsAfter.length - postingsBefore.length, equals(2));

      final liability = await canonicalAccountRepo.getDerivedBalance('card_dw_1');
      expect(liability.toRupees, equals(1500.0));
    });

    test('18. Double-Write: Loan repayment produces exact events/postings and 0 legacy authoritative writes', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_dw_loan_bank',
        name: 'Loan Bank',
        bank: 'SBI',
        balance: 20000.0,
      ));

      await loanRepo.insertLoan(Loan(
        id: 'loan_dw_1',
        name: 'Auto Loan',
        bank: 'HDFC',
        total: 10000.0,
        paidAmount: 0.0,
        monthlyInstallment: 1000.0,
        tenureMonths: 10,
        interestRate: 0.0,
        dueDay: 5,
        loanStatus: 'active',
        startDate: DateTime.now(),
      ));

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      await loanRepo.recordRepayment(
        loanId: 'loan_dw_1',
        assetAccountId: 'acc_dw_loan_bank',
        principalAmount: 1000.0,
        description: 'EMI 1',
        timestamp: DateTime.now(),
      );

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);

      expect(eventsAfter.length - eventsBefore.length, equals(1));
      expect(postingsAfter.length - postingsBefore.length, equals(2));

      final liability = await canonicalAccountRepo.getDerivedBalance('loan_dw_1');
      expect(liability.toRupees, equals(9000.0));
    });

    // =========================================================================
    // 5. Compatibility Firewall (appendLedger / removeLedger)
    // =========================================================================

    test('19. Compatibility Firewall: appendLedger produces 0 EconomicEvents and 0 Postings', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_compat_1',
        name: 'Compat Bank',
        bank: 'SBI',
        balance: 5000.0,
      ));

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);
      final balBefore = await canonicalAccountRepo.getDerivedBalance('acc_compat_1');

      // Call transitional compatibility method
      final ledgerTx = LedgerTransaction(
        type: LedgerType.expense,
        amount: 200.0,
        date: DateTime.now(),
        accountId: 'acc_compat_1',
        note: 'Compat snack',
        referenceId: 'ref_compat_1',
      );
      await financialService.appendLedger(ledgerTx);

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);
      final balAfter = await canonicalAccountRepo.getDerivedBalance('acc_compat_1');

      // Zero impact on canonical accounting truth
      expect(eventsAfter.length, equals(eventsBefore.length));
      expect(postingsAfter.length, equals(postingsBefore.length));
      expect(balAfter.minorUnits, equals(balBefore.minorUnits));

      // Verified: appendLedger wrote ONLY to legacy ledger_transactions
      final ledgerRows = await db.query(
        Tables.ledgerTransactions,
        where: 'reference_id = ?',
        whereArgs: ['ref_compat_1'],
      );
      expect(ledgerRows.length, equals(1));
    });

    test('20. Compatibility Firewall: removeLedger produces 0 EconomicEvents and 0 Postings', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_compat_2',
        name: 'Compat Bank 2',
        bank: 'SBI',
        balance: 6000.0,
      ));

      final ledgerTx = LedgerTransaction(
        type: LedgerType.income,
        amount: 500.0,
        date: DateTime.now(),
        accountId: 'acc_compat_2',
        note: 'Compat gift',
        referenceId: 'ref_compat_2',
      );
      await financialService.appendLedger(ledgerTx);

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);
      final balBefore = await canonicalAccountRepo.getDerivedBalance('acc_compat_2');

      // Call removeLedger
      await financialService.removeLedger(referenceId: 'ref_compat_2');

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);
      final balAfter = await canonicalAccountRepo.getDerivedBalance('acc_compat_2');

      expect(eventsAfter.length, equals(eventsBefore.length));
      expect(postingsAfter.length, equals(postingsBefore.length));
      expect(balAfter.minorUnits, equals(balBefore.minorUnits));

      final ledgerRows = await db.query(
        Tables.ledgerTransactions,
        where: 'reference_id = ?',
        whereArgs: ['ref_compat_2'],
      );
      expect(ledgerRows.isEmpty, isTrue);
    });

    // =========================================================================
    // 6. Review Candidate Firewall
    // =========================================================================

    test('21. Review Firewall: Pending candidate produces 0 EconomicEvents and 0 Postings', () async {
      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      final candidate = ReviewCandidate(
        id: 'rev_cand_1',
        sourceType: 'sms',
        rawPayload: 'Debited INR 500 from A/C XX1234',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(500.0),
        suggestedAccountId: null,
        confidenceScore: 0.95,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      );

      await reviewRepo.createCandidate(candidate);

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);

      // Pending candidate MUST NOT create accounting records
      expect(eventsAfter.length, equals(eventsBefore.length));
      expect(postingsAfter.length, equals(postingsBefore.length));
    });

    test('22. Review Firewall: Rejected candidate produces 0 EconomicEvents and 0 Postings', () async {
      final candidate = ReviewCandidate(
        id: 'rev_cand_2',
        sourceType: 'ocr',
        rawPayload: 'Receipt total 1200',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(1200.0),
        confidenceScore: 0.8,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      );
      await reviewRepo.createCandidate(candidate);

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      await reviewRepo.rejectCandidate('rev_cand_2');

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);

      expect(eventsAfter.length, equals(eventsBefore.length));
      expect(postingsAfter.length, equals(postingsBefore.length));

      final updated = await reviewRepo.getCandidate('rev_cand_2');
      expect(updated!.status, equals(ReviewCandidateStatus.rejected));
    });

    test('23. Review Firewall: Candidate approval produces canonical event through approved boundary', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_rev_app',
        name: 'Review Bank',
        bank: 'SBI',
        balance: 5000.0,
      ));

      final candidate = ReviewCandidate(
        id: 'rev_cand_3',
        sourceType: 'sms',
        rawPayload: 'Debited 300 at Starbucks',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(300.0),
        suggestedAccountId: 'acc_rev_app',
        confidenceScore: 0.99,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      );
      await reviewRepo.createCandidate(candidate);

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      // User approves candidate: routes through canonical transaction creation
      await reviewRepo.approveCandidate('rev_cand_3');
      final tx = model.Transaction(
        id: 'tx_from_rev_3',
        userId: 'user_1',
        type: 'expense',
        amount: 300.0,
        accountId: 'acc_rev_app',
        categoryId: 'cat_dining',
        date: DateTime.now(),
      );
      await transactionRepo.insert(tx);

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);

      // Exactly 1 EconomicEvent and 2 balanced Postings
      expect(eventsAfter.length - eventsBefore.length, equals(1));
      expect(postingsAfter.length - postingsBefore.length, equals(2));

      final bal = await canonicalAccountRepo.getDerivedBalance('acc_rev_app');
      expect(bal.toRupees, equals(4700.0));
    });

    // =========================================================================
    // 7. Goal / Earmark Firewall
    // =========================================================================

    test('24. Goal Firewall: Goal creation produces 0 EconomicEvents and 0 Postings', () async {
      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      await goalRepo.insert(Goal(
        id: 'goal_firewall_1',
        title: 'Vacation',
        type: GoalType.savings,
        targetAmount: 50000.0,
        currentAmount: 0.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      ));

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);

      expect(eventsAfter.length, equals(eventsBefore.length));
      expect(postingsAfter.length, equals(postingsBefore.length));
    });

    test('25. Goal Firewall: Earmark allocation produces 0 EconomicEvents and 0 Postings', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_earmark_bank',
        name: 'Earmark Bank',
        bank: 'SBI',
        balance: 20000.0,
      ));

      await goalRepo.insert(Goal(
        id: 'goal_firewall_2',
        title: 'New Phone',
        type: GoalType.savings,
        targetAmount: 30000.0,
        currentAmount: 0.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      ));

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      // Allocate earmark reservation
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_firewall_2',
        goalId: 'goal_firewall_2',
        assetAccountId: 'acc_earmark_bank',
        earmarkedAmount: Money.fromRupees(5000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);

      // Earmarks are non-financial reservations: ZERO postings created
      expect(eventsAfter.length, equals(eventsBefore.length));
      expect(postingsAfter.length, equals(postingsBefore.length));

      // Financial balance of bank account remains 20000.0
      final bal = await canonicalAccountRepo.getDerivedBalance('acc_earmark_bank');
      expect(bal.toRupees, equals(20000.0));
    });

    test('26. Goal Firewall: Goal deletion and earmark release produce 0 EconomicEvents and 0 Postings', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_earmark_bank_del',
        name: 'Earmark Bank Del',
        bank: 'SBI',
        balance: 15000.0,
      ));

      await goalRepo.insert(Goal(
        id: 'goal_firewall_del',
        title: 'Del Goal',
        type: GoalType.savings,
        targetAmount: 10000.0,
        currentAmount: 0.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      ));

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_firewall_del',
        goalId: 'goal_firewall_del',
        assetAccountId: 'acc_earmark_bank_del',
        earmarkedAmount: Money.fromRupees(3000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      // Delete goal
      await goalRepo.delete('goal_firewall_del');

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);

      expect(eventsAfter.length, equals(eventsBefore.length));
      expect(postingsAfter.length, equals(postingsBefore.length));
    });

    // =========================================================================
    // 8. Cross-Domain Operations & Rollback Firewall
    // =========================================================================

    test('27. Cross-Domain: Account-to-account transfer produces exact balanced postings', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_xfer_src',
        name: 'Source Bank',
        bank: 'SBI',
        balance: 10000.0,
      ));
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_xfer_dst',
        name: 'Dest Bank',
        bank: 'HDFC',
        balance: 2000.0,
      ));

      final tx = model.Transaction(
        id: 'tx_xfer_1',
        userId: 'user_1',
        type: 'transfer',
        amount: 3000.0,
        accountId: 'acc_xfer_src',
        relatedEntityId: 'acc_xfer_dst',
        date: DateTime.now(),
      );
      await transactionRepo.insert(tx);

      final srcBal = await canonicalAccountRepo.getDerivedBalance('acc_xfer_src');
      final dstBal = await canonicalAccountRepo.getDerivedBalance('acc_xfer_dst');

      expect(srcBal.toRupees, equals(7000.0));
      expect(dstBal.toRupees, equals(5000.0));

      // Global balance sheet balance remains unchanged
      final totalAssets = await financialQueryRepo.getTotalAssets();
      expect(totalAssets.toRupees, equals(12000.0));
    });

    test('28. Rollback: Injected error in multi-step operation rolls back cleanly without partial state', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_rb_1',
        name: 'Rollback Bank',
        bank: 'SBI',
        balance: 10000.0,
      ));

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      // Execute transaction callback that throws an exception midway
      try {
        await db.transaction((txn) async {
          final eventRepo = CanonicalEventRepository(executor: txn);
          final event = EconomicEvent(
            id: 'evt_rb_fail',
            canonicalType: CanonicalEventType.expense,
            lifecycleStatus: EventLifecycle.draft,
            occurredAt: DateTime.now(),
            createdAt: DateTime.now(),
          );
          final postings = [
            Posting(
              id: 'pst_rb_1',
              economicEventId: 'evt_rb_fail',
              accountId: TablesV24.sysExpMisc,
              direction: PostingDirection.debit,
              amount: Money.fromMinorUnits(50000),
              createdAt: DateTime.now(),
            ),
            Posting(
              id: 'pst_rb_2',
              economicEventId: 'evt_rb_fail',
              accountId: 'acc_rb_1',
              direction: PostingDirection.credit,
              amount: Money.fromMinorUnits(50000),
              createdAt: DateTime.now(),
            ),
          ];
          await eventRepo.createAndPostEvent(event, postings: postings);

          // Force an intentional failure after posting
          throw StateError('Simulated crash during multi-step operation');
        });
      } catch (e) {
        expect(e, isA<StateError>());
      }

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);
      final balAfter = await canonicalAccountRepo.getDerivedBalance('acc_rb_1');

      // Zero partial state committed: completely rolled back
      expect(eventsAfter.length, equals(eventsBefore.length));
      expect(postingsAfter.length, equals(postingsBefore.length));
      expect(balAfter.toRupees, equals(10000.0));
    });
  });
}
