import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_opening_balance_repository.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/credit_emi.dart';
import 'package:spend_x/models/card_statement.dart';
import 'package:spend_x/models/transaction.dart' as model;
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C3B-3: CreditRepo Canonical Migration Suite', () {
    late Database db;
    late CreditRepo creditRepo;
    late AccountRepo accountRepo;
    late TransactionRepo transactionRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalOpeningBalanceRepository canonicalOpeningBalanceRepo;

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

      creditRepo = CreditRepo(executor: db);
      accountRepo = AccountRepo(executor: db);
      transactionRepo = TransactionRepo(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalOpeningBalanceRepo = CanonicalOpeningBalanceRepository(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    test('1. card_creation_zero_balance: Creates canonical liability account with 0 balance and 0 postings', () async {
      final card = CreditCard(
        id: 'card_zero',
        name: 'Zero Balance Card',
        bank: 'HDFC Bank',
        last4: '1234',
        limitAmount: 100000.0,
        usedAmount: 0.0,
        billingDay: 15,
        dueDay: 5,
        cardType: 'visa',
        color: '#1E88E5',
      );

      final returnedId = await creditRepo.insert(card);
      expect(returnedId, 'card_zero');

      // Canonical account row exists with type liability and category credit_card
      final canonicalAcc = await canonicalAccountRepo.getAccount('card_zero');
      expect(canonicalAcc, isNotNull);
      expect(canonicalAcc!.name, 'Zero Balance Card');
      expect(canonicalAcc.type, AccountType.liability);
      expect(canonicalAcc.category, 'credit_card');
      expect(canonicalAcc.isActive, isTrue);

      // 0 financial postings
      final postings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['card_zero'],
      );
      expect(postings, isEmpty, reason: 'Zero-balance card creation produces 0 financial postings');

      // Derived balance is exactly 0
      final fetched = await creditRepo.getCard('card_zero');
      expect(fetched, isNotNull);
      expect(fetched!.usedAmount, 0.0);
    });

    test('2. card_creation_non_zero_balance: Posts opening balance event (Cr Liability, Dr sys_equity_opening) with provenance', () async {
      final card = CreditCard(
        id: 'card_initial',
        name: 'Opening Balance Card',
        bank: 'ICICI Bank',
        last4: '5678',
        limitAmount: 200000.0,
        usedAmount: 25000.0, // ₹25,000.00 outstanding liability
        billingDay: 20,
        dueDay: 10,
      );

      await creditRepo.insert(card);

      // Canonical account exists
      final canonicalAcc = await canonicalAccountRepo.getAccount('card_initial');
      expect(canonicalAcc, isNotNull);

      // Opening balance event posted
      final events = await canonicalEventRepo.listPostedEvents();
      final obEvent = events.firstWhere(
        (e) => e.canonicalType == CanonicalEventType.openingBalance && e.description.contains('Opening Balance Card'),
      );
      expect(obEvent.lifecycleStatus, EventLifecycle.posted);

      // Postings: Cr Card (Liability), Dr sys_equity_opening
      final postings = await canonicalEventRepo.getPostingsForEvent(obEvent.id);
      expect(postings.length, 2);

      final cardPosting = postings.firstWhere((p) => p.accountId == 'card_initial');
      expect(cardPosting.direction, PostingDirection.credit);
      expect(cardPosting.amount.minorUnits, 2500000); // ₹25,000.00

      final equityPosting = postings.firstWhere((p) => p.accountId == TablesV24.sysEquityOpening);
      expect(equityPosting.direction, PostingDirection.debit);
      expect(equityPosting.amount.minorUnits, 2500000);

      // Reconciliation provenance recorded
      final reconciliations = await canonicalOpeningBalanceRepo.listReconciliations();
      final rec = reconciliations.firstWhere((r) => r.accountId == 'card_initial');
      expect(rec.provenanceSource, 'manual_card_creation');
      expect(rec.legacyReportedBalance.minorUnits, 2500000);

      // Derived liability balance is ₹25,000.00
      final fetched = await creditRepo.getCard('card_initial');
      expect(fetched!.usedAmount, 25000.0);
    });

    test('3. card_purchase_accounting: Dr Expense, Cr Card Liability increases liability balance', () async {
      final card = CreditCard(
        id: 'card_shopping',
        name: 'Amazon ICICI',
        bank: 'ICICI Bank',
        limitAmount: 100000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);

      // Make a purchase of ₹4,999.00
      final purchase = CreditTransaction(
        id: 'tx_purchase_1',
        cardId: 'card_shopping',
        amount: 4999.0,
        date: DateTime.now(),
        category: 'Shopping',
        note: 'Amazon Retail',
        categoryId: 'exp_shopping',
        type: 'purchase',
        status: 'active',
      );
      await creditRepo.insertTransaction(purchase);

      // Check postings
      final postings = await canonicalEventRepo.getPostingsForEvent('tx_purchase_1');
      expect(postings.length, 2);

      // Dr Expense, Cr Card Liability
      final expPosting = postings.firstWhere((p) => p.accountId == 'exp_shopping');
      expect(expPosting.direction, PostingDirection.debit);
      expect(expPosting.amount.minorUnits, 499900);

      final cardPosting = postings.firstWhere((p) => p.accountId == 'card_shopping');
      expect(cardPosting.direction, PostingDirection.credit);
      expect(cardPosting.amount.minorUnits, 499900);

      // Card liability balance increased to ₹4,999.00
      final fetched = await creditRepo.getCard('card_shopping');
      expect(fetched!.usedAmount, 4999.0);

      // Expense account balance increased
      final expBalance = await canonicalAccountRepo.getDerivedBalance('exp_shopping');
      expect(expBalance.toRupees, 4999.0);
    });

    test('4. card_payment_accounting: Dr Card Liability, Cr Bank Asset (0 expense, 0 income)', () async {
      // 1. Create bank account with ₹50,000.00
      final bank = BankAccount(
        id: 'bank_salary',
        name: 'Salary Account',
        bank: 'HDFC Bank',
        balance: 50000.0,
      );
      await accountRepo.create(bank);

      // 2. Create card with ₹15,000.00 used amount
      final card = CreditCard(
        id: 'card_rewards',
        name: 'Rewards Card',
        bank: 'Axis Bank',
        limitAmount: 100000.0,
        usedAmount: 15000.0,
      );
      await creditRepo.insert(card);

      // 3. Pay ₹10,000.00 towards card bill from bank account
      final payment = CreditTransaction(
        id: 'tx_pay_1',
        cardId: 'card_rewards',
        amount: 10000.0,
        date: DateTime.now(),
        category: 'Payment',
        note: 'Credit Card Bill Payment',
        categoryId: 'bank_salary', // paying bank account
        type: 'payment',
        status: 'active',
      );
      await creditRepo.insertTransaction(payment);

      // Check postings: Dr Card (Liability reduced), Cr Bank (Asset reduced)
      final postings = await canonicalEventRepo.getPostingsForEvent('tx_pay_1');
      expect(postings.length, 2);

      final cardPosting = postings.firstWhere((p) => p.accountId == 'card_rewards');
      expect(cardPosting.direction, PostingDirection.debit);
      expect(cardPosting.amount.minorUnits, 1000000);

      final bankPosting = postings.firstWhere((p) => p.accountId == 'bank_salary');
      expect(bankPosting.direction, PostingDirection.credit);
      expect(bankPosting.amount.minorUnits, 1000000);

      // Derived card liability is now ₹15,000 - ₹10,000 = ₹5,000.00
      final fetchedCard = await creditRepo.getCard('card_rewards');
      expect(fetchedCard!.usedAmount, 5000.0);

      // Bank asset balance is now ₹50,000 - ₹10,000 = ₹40,000.00
      final fetchedBank = await accountRepo.getById('bank_salary');
      expect(fetchedBank!.balance, 40000.0);

      // Verify ZERO impact on income and expense accounts
      final expAccounts = await db.query(
        TablesV24.accounts,
        where: "account_type = 'expense'",
      );
      for (final acc in expAccounts) {
        final bal = await canonicalAccountRepo.getDerivedBalance(acc['id'] as String);
        expect(bal.minorUnits, 0, reason: 'Card payment must have zero expense impact');
      }
    });

    test('5. card_refund_accounting: Dr Card Liability, Cr Contra-Expense (0 income)', () async {
      final card = CreditCard(
        id: 'card_refund_test',
        name: 'Online Card',
        bank: 'SBI',
        limitAmount: 50000.0,
        usedAmount: 10000.0,
      );
      await creditRepo.insert(card);

      // Process a refund of ₹2,000.00 against shopping
      final refund = CreditTransaction(
        id: 'tx_refund_1',
        cardId: 'card_refund_test',
        amount: 2000.0,
        date: DateTime.now(),
        category: 'Refund',
        note: 'Flipkart Refund',
        categoryId: 'exp_shopping',
        type: 'refund',
        status: 'active',
      );
      await creditRepo.insertTransaction(refund);

      final postings = await canonicalEventRepo.getPostingsForEvent('tx_refund_1');
      expect(postings.length, 2);

      // Dr Card (reduces liability), Cr Contra-Expense
      final cardPosting = postings.firstWhere((p) => p.accountId == 'card_refund_test');
      expect(cardPosting.direction, PostingDirection.debit);
      expect(cardPosting.amount.minorUnits, 200000);

      final refundPosting = postings.firstWhere((p) => p.accountId == 'exp_shopping');
      expect(refundPosting.direction, PostingDirection.credit);
      expect(refundPosting.amount.minorUnits, 200000);

      // Derived liability reduced to ₹8,000.00
      final fetchedCard = await creditRepo.getCard('card_refund_test');
      expect(fetchedCard!.usedAmount, 8000.0);

      // Income accounts remain completely untouched
      final incAccounts = await db.query(
        TablesV24.accounts,
        where: "account_type = 'income'",
      );
      for (final acc in incAccounts) {
        final bal = await canonicalAccountRepo.getDerivedBalance(acc['id'] as String);
        expect(bal.minorUnits, 0, reason: 'Card refund must have zero income impact');
      }
    });

    test('6. unmatched_refund_accounting: Refund without category credits sys_exp_refunds', () async {
      final card = CreditCard(
        id: 'card_unmatched',
        name: 'Generic Card',
        bank: 'Axis Bank',
        limitAmount: 50000.0,
        usedAmount: 5000.0,
      );
      await creditRepo.insert(card);

      // Refund without categoryId
      final refund = CreditTransaction(
        id: 'tx_unmatched_1',
        cardId: 'card_unmatched',
        amount: 1500.0,
        date: DateTime.now(),
        category: 'Refund',
        note: 'Merchant Refund',
        type: 'refund',
        status: 'active',
      );
      await creditRepo.insertTransaction(refund);

      final postings = await canonicalEventRepo.getPostingsForEvent('tx_unmatched_1');
      expect(postings.length, 2);

      final contraPosting = postings.firstWhere((p) => p.accountId == TablesV24.sysExpRefunds);
      expect(contraPosting.direction, PostingDirection.credit);
      expect(contraPosting.amount.minorUnits, 150000);

      // Card liability reduced by ₹1,500.00
      final fetchedCard = await creditRepo.getCard('card_unmatched');
      expect(fetchedCard!.usedAmount, 3500.0);
    });

    test('7. derived_liability_balance: Sequence of purchases, payments, and refunds derives credits - debits', () async {
      final card = CreditCard(
        id: 'card_seq',
        name: 'Sequence Card',
        bank: 'HDFC',
        limitAmount: 200000.0,
        usedAmount: 10000.0, // Opening: +10,000 (Cr)
      );
      await creditRepo.insert(card);

      // Purchase: +5,000 (Cr)
      await creditRepo.insertTransaction(CreditTransaction(
        id: 'tx_seq_p1',
        cardId: 'card_seq',
        amount: 5000.0,
        date: DateTime.now(),
        category: 'Groceries',
        type: 'purchase',
        status: 'active',
      ));

      // Purchase: +3,000 (Cr)
      await creditRepo.insertTransaction(CreditTransaction(
        id: 'tx_seq_p2',
        cardId: 'card_seq',
        amount: 3000.0,
        date: DateTime.now(),
        category: 'Fuel',
        type: 'purchase',
        status: 'active',
      ));

      // Payment: -8,000 (Dr)
      await creditRepo.insertTransaction(CreditTransaction(
        id: 'tx_seq_pay',
        cardId: 'card_seq',
        amount: 8000.0,
        date: DateTime.now(),
        category: 'Payment',
        type: 'payment',
        status: 'active',
      ));

      // Refund: -2,000 (Dr)
      await creditRepo.insertTransaction(CreditTransaction(
        id: 'tx_seq_ref',
        cardId: 'card_seq',
        amount: 2000.0,
        date: DateTime.now(),
        category: 'Refund',
        type: 'refund',
        status: 'active',
      ));

      // Math: 10,000 + 5,000 + 3,000 - 8,000 - 2,000 = 8,000
      final derivedBalance = await canonicalAccountRepo.getDerivedBalance('card_seq');
      expect(derivedBalance.toRupees, 8000.0);

      final fetchedCard = await creditRepo.getCard('card_seq');
      expect(fetchedCard!.usedAmount, 8000.0);
    });

    test('8. draft_isolation: Draft credit events contribute 0 to derived balance until posted', () async {
      final card = CreditCard(
        id: 'card_draft_test',
        name: 'Draft Test Card',
        bank: 'SBI',
        limitAmount: 100000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);

      final now = DateTime.now();
      // Create a draft purchase event directly
      final draftEvent = EconomicEvent.draft(
        id: 'ev_draft_credit',
        canonicalType: CanonicalEventType.cardPurchase,
        occurredAt: now,
        createdAt: now,
        description: 'Draft Purchase',
      );
      final draftPostings = [
        Posting(
          id: 'post_draft_exp',
          economicEventId: 'ev_draft_credit',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(1500000),
          createdAt: now,
        ),
        Posting(
          id: 'post_draft_card',
          economicEventId: 'ev_draft_credit',
          accountId: 'card_draft_test',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(1500000),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createDraftEvent(draftEvent, postings: draftPostings);

      // Derived balance remains 0 while event is in draft
      final balBefore = await canonicalAccountRepo.getDerivedBalance('card_draft_test');
      expect(balBefore.minorUnits, 0);

      final cardBefore = await creditRepo.getCard('card_draft_test');
      expect(cardBefore!.usedAmount, 0.0);

      // Post the draft event
      await canonicalEventRepo.postEvent('ev_draft_credit');

      // Now derived balance reflects the purchase: ₹15,000.00
      final balAfter = await canonicalAccountRepo.getDerivedBalance('card_draft_test');
      expect(balAfter.toRupees, 15000.0);

      final cardAfter = await creditRepo.getCard('card_draft_test');
      expect(cardAfter!.usedAmount, 15000.0);
    });

    test('9. posted_immutability: SQLite triggers reject UPDATE or DELETE on posted events and postings', () async {
      final card = CreditCard(
        id: 'card_locked',
        name: 'Locked Card',
        bank: 'HDFC',
        limitAmount: 100000.0,
        usedAmount: 5000.0,
      );
      await creditRepo.insert(card);

      final tx = CreditTransaction(
        id: 'tx_immutable_1',
        cardId: 'card_locked',
        amount: 2500.0,
        date: DateTime.now(),
        category: 'Shopping',
        type: 'purchase',
        status: 'active',
      );
      await creditRepo.insertTransaction(tx);

      // Direct SQL UPDATE on posted economic_event must fail
      expect(
        () async => await db.rawUpdate(
          'UPDATE ${TablesV24.economicEvents} SET currency = ? WHERE id = ?',
          ['USD', 'tx_immutable_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Direct SQL DELETE on posted economic_event must fail
      expect(
        () async => await db.rawDelete(
          'DELETE FROM ${TablesV24.economicEvents} WHERE id = ?',
          ['tx_immutable_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Direct SQL UPDATE on posted posting must fail
      expect(
        () async => await db.rawUpdate(
          'UPDATE ${TablesV24.postings} SET amount_minor_units = ? WHERE economic_event_id = ?',
          [999999, 'tx_immutable_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Direct SQL DELETE on posted posting must fail
      expect(
        () async => await db.rawDelete(
          'DELETE FROM ${TablesV24.postings} WHERE economic_event_id = ?',
          ['tx_immutable_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('10. historical_card_archival: Cards with postings are soft-archived; clean cards are deleted', () async {
      // 1. Card with history
      final cardWithHistory = CreditCard(
        id: 'card_with_history',
        name: 'History Card',
        bank: 'SBI',
        limitAmount: 50000.0,
        usedAmount: 1000.0,
      );
      await creditRepo.insert(cardWithHistory);

      await creditRepo.delete('card_with_history');

      // Canonical account row still exists but has is_active = 0
      final accountRow = await canonicalAccountRepo.getAccount('card_with_history');
      expect(accountRow, isNotNull);
      expect(accountRow!.isActive, isFalse);

      // getAll() excludes inactive cards
      final activeCards = await creditRepo.getAll();
      expect(activeCards.any((c) => c.id == 'card_with_history'), isFalse);

      // 2. Card with NO history
      final cleanCard = CreditCard(
        id: 'card_clean',
        name: 'Clean Card',
        bank: 'Axis',
        limitAmount: 50000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(cleanCard);

      await creditRepo.delete('card_clean');

      // Clean card is physically deleted from canonical accounts
      final cleanRow = await canonicalAccountRepo.getAccount('card_clean');
      expect(cleanRow, isNull);
    });

    test('11. adjust_outstandings_reconciliation: Reconciles deltas against sys_equity_opening', () async {
      final card = CreditCard(
        id: 'card_adj',
        name: 'Adjustable Card',
        bank: 'Kotak',
        limitAmount: 100000.0,
        usedAmount: 10000.0,
      );
      await creditRepo.insert(card);

      // Adjust outstanding by +₹2,500.00
      await creditRepo.adjustOutstandings({'card_adj': 2500.0});

      // Derived liability balance is now ₹12,500.00
      final fetched = await creditRepo.getCard('card_adj');
      expect(fetched!.usedAmount, 12500.0);

      // Reconciliations record created
      final recs = await canonicalOpeningBalanceRepo.listReconciliations();
      final rec = recs.firstWhere((r) => r.accountId == 'card_adj' && r.provenanceSource == 'card_reconciliation_delta');
      expect(rec.adjustmentDelta.minorUnits, 250000); // +₹2,500.00
      expect(rec.legacyReportedBalance.minorUnits, 1250000); // ₹12,500.00
    });

    test('12. credit_transaction_compatibility: insertTransaction / getTransactions works seamlessly', () async {
      final card = CreditCard(
        id: 'card_compat',
        name: 'Compat Card',
        bank: 'HDFC',
        limitAmount: 100000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);

      final tx1 = CreditTransaction(
        id: 'tx_c1',
        cardId: 'card_compat',
        amount: 1200.0,
        date: DateTime.parse('2026-03-01T10:00:00.000'),
        category: 'Food',
        note: 'Swiggy',
        type: 'purchase',
        status: 'active',
      );
      final tx2 = CreditTransaction(
        id: 'tx_c2',
        cardId: 'card_compat',
        amount: 800.0,
        date: DateTime.parse('2026-03-02T10:00:00.000'),
        category: 'Food',
        note: 'Zomato',
        type: 'purchase',
        status: 'active',
      );

      await creditRepo.insertTransactions([tx1, tx2]);

      final txList = await creditRepo.getTransactions('card_compat');
      expect(txList.length, 2);
      expect(txList.map((t) => t.id), containsAll(['tx_c1', 'tx_c2']));

      final fetchedTx = await creditRepo.getTransactionById('tx_c1');
      expect(fetchedTx, isNotNull);
      expect(fetchedTx!.note, 'Swiggy');

      // Delete transaction posts double-entry reversal
      await creditRepo.deleteTransaction('tx_c1');

      // Derived balance reflects only tx2 (₹800.00)
      final cardAfter = await creditRepo.getCard('card_compat');
      expect(cardAfter!.usedAmount, 800.0);
    });

    test('13. emi_metadata_isolation: Operational EMI methods operate without corrupting canonical ledger', () async {
      final card = CreditCard(
        id: 'card_emi_test',
        name: 'EMI Card',
        bank: 'ICICI',
        limitAmount: 200000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);

      final now = DateTime.now();
      final emi = CreditEMI(
        id: 'emi_1',
        cardId: 'card_emi_test',
        transactionId: 'tx_emi_orig',
        principalAmount: 120000.0,
        interestRate: 14.0,
        interestAmount: 8400.0,
        processingFee: 199.0,
        tenureMonths: 12,
        monthlyInstallment: 10000.0,
        startDate: DateTime.parse('2026-01-01'),
        paidMonths: 2,
        remainingMonths: 10,
        createdAt: now,
      );

      await creditRepo.insertEMI(emi);

      final emis = await creditRepo.getEmis('card_emi_test');
      expect(emis.length, 1);
      expect(emis.first.principalAmount, 120000.0);

      // Canonical postings remain 0
      final postings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['card_emi_test'],
      );
      expect(postings, isEmpty, reason: 'EMI metadata operations must not write spurious postings');
    });

    test('14. statement_metadata: Statement insertions do not directly mutate accounting ledger', () async {
      final card = CreditCard(
        id: 'card_stmt',
        name: 'Statement Card',
        bank: 'SBI',
        limitAmount: 50000.0,
        usedAmount: 12000.0,
      );
      await creditRepo.insert(card);

      final stmt = CardStatement(
        id: 'stmt_1',
        cardId: 'card_stmt',
        startDate: DateTime.parse('2026-02-01'),
        endDate: DateTime.parse('2026-03-01'),
        statementAmount: 12000.0,
        minimumDue: 600.0,
        generatedDate: DateTime.parse('2026-03-02'),
      );

      await creditRepo.insertStatement(stmt);

      final stmts = await creditRepo.getStatements('card_stmt');
      expect(stmts.length, 1);
      expect(stmts.first.statementAmount, 12000.0);

      // Ledger balance remains unaffected
      final fetchedCard = await creditRepo.getCard('card_stmt');
      expect(fetchedCard!.usedAmount, 12000.0);
    });

    test('15. legacy_balance_firewall: Direct writes to credit_cards.used_amount do NOT alter canonical truth', () async {
      final card = CreditCard(
        id: 'card_tamper',
        name: 'Tamper Card',
        bank: 'HDFC',
        limitAmount: 100000.0,
        usedAmount: 15000.0,
      );
      await creditRepo.insert(card);

      // Directly tamper with legacy transitional table
      await db.update(
        Tables.creditCards,
        {'used_amount': 999999.0},
        where: 'id = ?',
        whereArgs: ['card_tamper'],
      );

      // CreditRepo must ignore the fake balance and derive truth from postings
      final fetched = await creditRepo.getCard('card_tamper');
      expect(fetched!.usedAmount, 15000.0);

      final allCards = await creditRepo.getAll();
      final inList = allCards.firstWhere((c) => c.id == 'card_tamper');
      expect(inList.usedAmount, 15000.0);
    });

    test('16. cross_repo_purchase_payment: TransactionRepo and CreditRepo interop correctly', () async {
      // 1. Bank account with ₹30,000.00
      final bank = BankAccount(
        id: 'bank_salary_cross',
        name: 'Salary Bank',
        bank: 'SBI',
        balance: 30000.0,
      );
      await accountRepo.create(bank);

      // 2. Card with ₹0.00
      final card = CreditCard(
        id: 'card_cross',
        name: 'Cross Card',
        bank: 'ICICI',
        limitAmount: 50000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);

      // 3. Purchase on card via CreditRepo: ₹6,000.00
      await creditRepo.insertTransaction(CreditTransaction(
        id: 'tx_cross_p',
        cardId: 'card_cross',
        amount: 6000.0,
        date: DateTime.now(),
        category: 'Electronics',
        type: 'purchase',
        status: 'active',
      ));

      // 4. Pay ₹6,000.00 bill via CreditRepo using bank_salary_cross
      await creditRepo.insertTransaction(CreditTransaction(
        id: 'tx_cross_pay',
        cardId: 'card_cross',
        amount: 6000.0,
        date: DateTime.now(),
        category: 'Payment',
        categoryId: 'bank_salary_cross',
        type: 'payment',
        status: 'active',
      ));

      // 5. Verify balances:
      // Card liability is back to 0
      final fetchedCard = await creditRepo.getCard('card_cross');
      expect(fetchedCard!.usedAmount, 0.0);

      // Bank asset is 30,000 - 6,000 = 24,000
      final fetchedBank = await accountRepo.getById('bank_salary_cross');
      expect(fetchedBank!.balance, 24000.0);
    });

    test('17. accounting_equation_preserved: Assets - Liabilities = Equity holds after credit card ops', () async {
      // Create Bank (Asset: +50k)
      await accountRepo.create(BankAccount(
        id: 'eq_bank',
        name: 'Equation Bank',
        bank: 'HDFC',
        balance: 50000.0,
      ));

      // Create Card (Liability: +20k)
      await creditRepo.insert(CreditCard(
        id: 'eq_card',
        name: 'Equation Card',
        bank: 'SBI',
        limitAmount: 100000.0,
        usedAmount: 20000.0,
      ));

      // Card Purchase of ₹5,000 (Expense: +5k, Liability: +5k)
      await creditRepo.insertTransaction(CreditTransaction(
        id: 'eq_tx_p',
        cardId: 'eq_card',
        amount: 5000.0,
        date: DateTime.now(),
        category: 'Shopping',
        type: 'purchase',
        status: 'active',
      ));

      // Card Payment of ₹10,000 from eq_bank (Asset: -10k, Liability: -10k)
      await creditRepo.insertTransaction(CreditTransaction(
        id: 'eq_tx_pay',
        cardId: 'eq_card',
        amount: 10000.0,
        date: DateTime.now(),
        category: 'Payment',
        categoryId: 'eq_bank',
        type: 'payment',
        status: 'active',
      ));

      // Card Refund of ₹2,000 (Contra-Expense: +2k, Liability: -2k)
      await creditRepo.insertTransaction(CreditTransaction(
        id: 'eq_tx_ref',
        cardId: 'eq_card',
        amount: 2000.0,
        date: DateTime.now(),
        category: 'Refund',
        type: 'refund',
        status: 'active',
      ));

      // Sum all debits and credits across all accounts in the ledger
      final sumRes = await db.rawQuery(
        'SELECT direction, SUM(amount_minor_units) as total FROM ${TablesV24.postings} GROUP BY direction',
      );
      int totalDebits = 0;
      int totalCredits = 0;
      for (final r in sumRes) {
        if (r['direction'] == 'debit') {
          totalDebits = (r['total'] as num).toInt();
        } else if (r['direction'] == 'credit') {
          totalCredits = (r['total'] as num).toInt();
        }
      }

      // Fundamental double-entry equation: Total Debits == Total Credits
      expect(totalDebits, totalCredits, reason: 'Ledger debits must exactly equal credits');
      expect(totalDebits, greaterThan(0));
    });

    test('18. idempotency: Repeated card lookups and balance updates are fully deterministic', () async {
      final card = CreditCard(
        id: 'card_idemp',
        name: 'Idempotent Card',
        bank: 'Axis',
        limitAmount: 50000.0,
        usedAmount: 5000.0,
      );
      await creditRepo.insert(card);

      final val1 = await creditRepo.getCard('card_idemp');
      final val2 = await creditRepo.getCard('card_idemp');
      final val3 = await creditRepo.getCard('card_idemp');

      expect(val1!.usedAmount, 5000.0);
      expect(val2!.usedAmount, 5000.0);
      expect(val3!.usedAmount, 5000.0);
    });

    test('19. c3b_1_regression: TransactionRepo works seamlessly alongside CreditRepo', () async {
      final bank = BankAccount(
        id: 'bank_reg_c3b1',
        name: 'Reg Bank C3B1',
        bank: 'SBI',
        balance: 10000.0,
      );
      await accountRepo.create(bank);

      final tx = model.Transaction(
        id: 'tx_c3b1_exp',
        userId: 'user_1',
        accountId: 'bank_reg_c3b1',
        amount: 2000.0,
        type: 'expense',
        categoryId: 'exp_food',
        date: DateTime.now(),
      );
      await transactionRepo.insert(tx);

      final fetchedBank = await accountRepo.getById('bank_reg_c3b1');
      expect(fetchedBank!.balance, 8000.0);
    });

    test('20. c3b_2_regression: AccountRepo works seamlessly alongside CreditRepo', () async {
      final bank = BankAccount(
        id: 'bank_reg_c3b2',
        name: 'Reg Bank C3B2',
        bank: 'ICICI',
        balance: 15000.0,
      );
      await accountRepo.create(bank);

      await accountRepo.adjustBalance('bank_reg_c3b2', 5000.0);

      final fetchedBank = await accountRepo.getById('bank_reg_c3b2');
      expect(fetchedBank!.balance, 20000.0);
    });

    test('21. metadata_safety: update(card metadata) does NOT create reconciliation from stale usedAmount', () async {
      final card = CreditCard(
        id: 'card_meta_safe',
        name: 'Initial Name',
        bank: 'HDFC',
        limitAmount: 100000.0,
        usedAmount: 10000.0,
      );
      await creditRepo.insert(card);

      final recsBefore = await canonicalOpeningBalanceRepo.listReconciliations();
      final countBefore = recsBefore.length;

      // Edit metadata only (e.g. name, color), but provide a drastically different usedAmount in model
      final editedCard = card.copyWith(
        name: 'New Brand Name',
        color: '#FF0000',
        usedAmount: 999999.0, // STALE / UNTRUSTED BALANCE
      );
      await creditRepo.update(editedCard);

      // 1. Name is updated
      final fetched = await creditRepo.getCard('card_meta_safe');
      expect(fetched!.name, 'New Brand Name');
      expect(fetched.color, '#FF0000');

      // 2. Financial derived balance remains strictly 10,000.0 (stale 999999.0 is ignored)
      expect(fetched.usedAmount, 10000.0);

      // 3. ZERO new reconciliation events or postings created
      final recsAfter = await canonicalOpeningBalanceRepo.listReconciliations();
      expect(recsAfter.length, countBefore, reason: 'Metadata update must NEVER create reconciliation records');
    });

    test('22. explicit_reconciliation: reconcileOutstanding updates derived balance with provenance', () async {
      final card = CreditCard(
        id: 'card_explicit_rec',
        name: 'Explicit Rec Card',
        bank: 'ICICI',
        limitAmount: 50000.0,
        usedAmount: 5000.0,
      );
      await creditRepo.insert(card);

      // Call dedicated explicit reconciliation method
      await creditRepo.reconcileOutstanding(
        'card_explicit_rec',
        8500.0,
        reason: 'Monthly statement bill sync',
        provenance: 'sms_statement_sync',
      );

      // 1. Derived balance is now ₹8,500.00
      final fetched = await creditRepo.getCard('card_explicit_rec');
      expect(fetched!.usedAmount, 8500.0);

      // 2. Reconciliations provenance record created with exact delta
      final recs = await canonicalOpeningBalanceRepo.listReconciliations();
      final rec = recs.firstWhere(
        (r) => r.accountId == 'card_explicit_rec' && r.provenanceSource == 'sms_statement_sync',
      );
      expect(rec.adjustmentDelta.minorUnits, 350000); // +₹3,500.00
      expect(rec.legacyReportedBalance.minorUnits, 850000); // ₹8,500.00
      expect(rec.reconstructedBalanceFromTxns.minorUnits, 500000); // ₹5,000.00
    });

    test('23. rollback_safety: Failed adjustment in batch leaves 0 partial postings', () async {
      final card = CreditCard(
        id: 'card_rb_1',
        name: 'Rollback Card 1',
        bank: 'Axis',
        limitAmount: 50000.0,
        usedAmount: 1000.0,
      );
      await creditRepo.insert(card);

      final postingsBefore = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['card_rb_1'],
      );
      final countBefore = postingsBefore.length;

      // Batch adjustment where second entry targets a non-existent card triggering FK error
      expect(
        () async => await creditRepo.adjustOutstandings({
          'card_rb_1': 500.0, // Valid
          'card_non_existent': 1000.0, // Will fail FK check in postings
        }),
        throwsA(isA<Exception>()),
      );

      // Verify atomic rollback: card_rb_1 postings count is untouched
      final postingsAfter = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['card_rb_1'],
      );
      expect(postingsAfter.length, countBefore, reason: 'Failed batch adjustment must roll back cleanly leaving 0 partial state');
    });
  });
}
