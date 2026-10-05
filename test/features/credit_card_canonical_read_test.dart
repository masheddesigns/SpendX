import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/features/liabilities/providers/liabilities_providers.dart';
import 'package:spend_x/features/liabilities/providers/credit_health_providers.dart';
import 'package:spend_x/services/credit_intelligence_service.dart';
import 'package:spend_x/domain/credit/credit_card_service.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C4-3: Credit Card Screens Read Migration Test Suite', () {
    late Database db;
    late CreditRepo creditRepo;
    late AccountRepo accountRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late CreditCardService creditCardService;
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

      creditRepo = CreditRepo(executor: db);
      accountRepo = AccountRepo(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      creditCardService = CreditCardService(creditRepo: creditRepo);

      container = ProviderContainer(
        overrides: [
          app_data.creditRepoProvider.overrideWithValue(creditRepo),
          app_data.accountRepoProvider.overrideWithValue(accountRepo),
          app_data.canonicalFinancialQueryRepositoryProvider
              .overrideWithValue(canonicalQueryRepo),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Invariant 1: Rogue mutation of credit_cards.used_amount cannot change displayed outstanding
    // -------------------------------------------------------------------------
    test('1. Rogue mutation of credit_cards.used_amount has ZERO effect on displayed outstanding', () async {
      // Create card with ₹10,000 initial outstanding (generates canonical opening balance event)
      final card = CreditCard(
        id: 'card_inv_1',
        name: 'HDFC Regalia Gold',
        bank: 'HDFC Bank',
        last4: '1234',
        limitAmount: 100000.0,
        billingDay: 1,
        dueDay: 20,
        usedAmount: 10000.0,
      );
      await creditRepo.insert(card);

      // Verify canonical derived liability is ₹10,000
      final balanceBefore = await canonicalAccountRepo.getDerivedBalance('card_inv_1');
      expect(balanceBefore.toRupees, 10000.0);

      // Perform rogue direct SQL mutation to legacy table
      await db.rawUpdate(
        'UPDATE ${Tables.creditCards} SET used_amount = 999999.0 WHERE id = ?',
        ['card_inv_1'],
      );

      // Verify legacy row now has rogue balance
      final rogueRow = await db.query(
        Tables.creditCards,
        where: 'id = ?',
        whereArgs: ['card_inv_1'],
      );
      expect(rogueRow.first['used_amount'], 999999.0);

      // 1. Verify cardsProvider
      final cards = await container.read(app_data.cardsProvider.future);
      final cardFromCards = cards.firstWhere((c) => c.id == 'card_inv_1');
      expect(cardFromCards.usedAmount, 10000.0);
      expect(cardFromCards.outstanding, 10000.0);

      // 2. Verify creditCardsProvider
      final creditCards = await container.read(creditCardsProvider.future);
      final cardFromCreditCards = creditCards.firstWhere((c) => c.id == 'card_inv_1');
      expect(cardFromCreditCards.usedAmount, 10000.0);

      // 3. Verify cardByIdProvider
      final cardById = container.read(cardByIdProvider('card_inv_1'));
      expect(cardById, isNotNull);
      expect(cardById!.usedAmount, 10000.0);

      // 4. Verify creditOutstandingProvider
      final outstanding = await container.read(creditOutstandingProvider('card_inv_1').future);
      expect(outstanding, 10000.0);

      // 5. Verify CreditIntelligenceService
      final intel = await CreditIntelligenceService.instance.getCardIntelligence(cardFromCards);
      expect(intel.outstanding, 10000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 2: Canonical card purchase increases liability
    // -------------------------------------------------------------------------
    test('2. Canonical card purchase increases liability across all providers', () async {
      final card = CreditCard(
        id: 'card_inv_2',
        name: 'ICICI Sapphiro',
        bank: 'ICICI Bank',
        last4: '5678',
        limitAmount: 200000.0,
        billingDay: 5,
        dueDay: 25,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);

      // Purchase: ₹3,500
      final purchase = CreditTransaction(
        id: 'tx_purchase_1',
        cardId: 'card_inv_2',
        amount: 3500.0,
        date: DateTime.now(),
        category: 'cat_dining',
        type: 'purchase',
        status: 'active',
        note: 'Dinner with team',
      );
      await creditRepo.insertTransaction(purchase);

      // Invalidate providers
      container.invalidate(app_data.cardsProvider);

      // 1. Verify canonical liability derived balance
      final balance = await canonicalAccountRepo.getDerivedBalance('card_inv_2');
      expect(balance.toRupees, 3500.0);

      // 2. Verify creditOutstandingProvider
      final outstanding = await container.read(creditOutstandingProvider('card_inv_2').future);
      expect(outstanding, 3500.0);

      // 3. Verify cardsProvider & creditCardsProvider
      final cards = await container.read(creditCardsProvider.future);
      final cardData = cards.firstWhere((c) => c.id == 'card_inv_2');
      expect(cardData.usedAmount, 3500.0);
      expect(cardData.availableLimit, 196500.0);

      // 4. Verify double-entry postings (Dr Expense, Cr Card Liability)
      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['tx_purchase_1'],
      );
      expect(postings.length, 2);
      final cardPosting = postings.firstWhere((p) => p['account_id'] == 'card_inv_2');
      expect(cardPosting['direction'], 'credit'); // Credit increases liability
      expect(cardPosting['amount_minor_units'], 350000);
    });

    // -------------------------------------------------------------------------
    // Invariant 3: Card payment decreases liability and does not create expense
    // -------------------------------------------------------------------------
    test('3. Card payment decreases liability with ₹0 expense / income impact', () async {
      // 1. Create funding bank account (₹50,000)
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_bank_pay',
        name: 'Salary Account',
        bank: 'Axis Bank',
        balance: 50000.0,
      ));

      // 2. Create card with ₹20,000 initial liability
      final card = CreditCard(
        id: 'card_inv_3',
        name: 'Axis Magnus',
        bank: 'Axis Bank',
        last4: '9999',
        limitAmount: 300000.0,
        usedAmount: 20000.0,
      );
      await creditRepo.insert(card);

      // 3. Process payment of ₹8,000 from bank account
      final payment = CreditTransaction(
        id: 'tx_pay_1',
        cardId: 'card_inv_3',
        amount: 8000.0,
        date: DateTime.now(),
        category: 'payment',
        categoryId: 'acc_bank_pay',
        type: 'payment',
        status: 'active',
        note: 'Credit Card Bill Payment',
      );
      await creditRepo.insertTransaction(payment);

      container.invalidate(app_data.cardsProvider);

      // Verify card liability decreased from ₹20,000 to ₹12,000
      final cardLiability = await canonicalAccountRepo.getDerivedBalance('card_inv_3');
      expect(cardLiability.toRupees, 12000.0);

      // Verify bank account asset decreased from ₹50,000 to ₹42,000
      final bankAsset = await canonicalAccountRepo.getDerivedBalance('acc_bank_pay');
      expect(bankAsset.toRupees, 42000.0);

      // Verify outstanding in providers
      final outstanding = await container.read(creditOutstandingProvider('card_inv_3').future);
      expect(outstanding, 12000.0);

      // Verify postings: Dr Card Liability, Cr Bank Asset (NO expense, NO income)
      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['tx_pay_1'],
      );
      expect(postings.length, 2);

      for (final p in postings) {
        final accId = p['account_id'] as String;
        expect(accId == 'card_inv_3' || accId == 'acc_bank_pay', isTrue);
      }
    });

    // -------------------------------------------------------------------------
    // Invariant 4: Refund semantics remain correct (contra-expense / liability decrease, ₹0 income)
    // -------------------------------------------------------------------------
    test('4. Card refund reduces liability with ₹0 income impact', () async {
      final card = CreditCard(
        id: 'card_inv_4',
        name: 'SBI Cashback',
        bank: 'SBI Card',
        last4: '4321',
        limitAmount: 50000.0,
        usedAmount: 5000.0,
      );
      await creditRepo.insert(card);

      // Refund: ₹1,500
      final refund = CreditTransaction(
        id: 'tx_refund_1',
        cardId: 'card_inv_4',
        amount: 1500.0,
        date: DateTime.now(),
        category: 'refund',
        categoryId: TablesV24.sysExpRefunds,
        type: 'refund',
        status: 'active',
        note: 'Amazon return refund',
      );
      await creditRepo.insertTransaction(refund);

      container.invalidate(app_data.cardsProvider);

      // Liability drops from ₹5,000 to ₹3,500
      final liability = await canonicalAccountRepo.getDerivedBalance('card_inv_4');
      expect(liability.toRupees, 3500.0);

      final outstanding = await container.read(creditOutstandingProvider('card_inv_4').future);
      expect(outstanding, 3500.0);

      // Verify postings: Dr Card Liability, Cr Contra-Expense (NO income postings)
      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['tx_refund_1'],
      );
      expect(postings.length, 2);

      final cardPosting = postings.firstWhere((p) => p['account_id'] == 'card_inv_4');
      expect(cardPosting['direction'], 'debit'); // Debit reduces liability

      final contraPosting = postings.firstWhere((p) => p['account_id'] == TablesV24.sysExpRefunds);
      expect(contraPosting['direction'], 'credit'); // Credit to contra-expense
    });

    // -------------------------------------------------------------------------
    // Invariant 5: Credit limit remains contractual metadata, never confused with liability
    // -------------------------------------------------------------------------
    test('5. Credit limit is contractual metadata, immune to liability confusion and generates 0 postings', () async {
      final card = CreditCard(
        id: 'card_inv_5',
        name: 'OneCard Metal',
        bank: 'Federal Bank',
        last4: '0001',
        limitAmount: 50000.0,
        usedAmount: 15000.0,
      );
      await creditRepo.insert(card);

      final initialPostingsCount = (await db.rawQuery(
        'SELECT COUNT(*) as cnt FROM ${TablesV24.postings}',
      )).first['cnt'] as int;

      // Update credit limit metadata to ₹120,000
      final updatedCard = card.copyWith(limitAmount: 120000.0, name: 'OneCard Metal Upgraded');
      await creditRepo.update(updatedCard);

      final afterPostingsCount = (await db.rawQuery(
        'SELECT COUNT(*) as cnt FROM ${TablesV24.postings}',
      )).first['cnt'] as int;

      // Postings count MUST be identical (0 postings for metadata edits)
      expect(afterPostingsCount, initialPostingsCount);

      // Read from repo & providers
      final fetchedCard = await creditRepo.getCard('card_inv_5');
      expect(fetchedCard, isNotNull);
      expect(fetchedCard!.limitAmount, 120000.0);
      expect(fetchedCard.usedAmount, 15000.0); // Liability untouched!
      expect(fetchedCard.availableLimit, 105000.0); // 120,000 - 15,000
      expect(fetchedCard.utilizationPct, closeTo(12.5, 0.01)); // 15,000 / 120,000 * 100
    });

    // -------------------------------------------------------------------------
    // Invariant 6: Statement/due metadata does not become accounting truth
    // -------------------------------------------------------------------------
    test('6. Statement metadata does not alter derived liability', () async {
      final card = CreditCard(
        id: 'card_inv_6',
        name: 'Standard Chartered Ultimate',
        bank: 'StanC',
        last4: '7777',
        limitAmount: 100000.0,
        usedAmount: 4000.0,
        lastStatementBalance: 4000.0,
      );
      await creditRepo.insert(card);

      // Rogue direct update to last_statement_balance and billing_day in legacy table
      await db.rawUpdate(
        'UPDATE ${Tables.creditCards} SET last_statement_balance = 88000.0, billing_day = 15 WHERE id = ?',
        ['card_inv_6'],
      );

      // Canonical derived balance is still strictly ₹4,000
      final derivedBalance = await canonicalAccountRepo.getDerivedBalance('card_inv_6');
      expect(derivedBalance.toRupees, 4000.0);

      final fetched = await creditRepo.getCard('card_inv_6');
      expect(fetched, isNotNull);
      expect(fetched!.usedAmount, 4000.0); // Canonical liability preserved
      expect(fetched.lastStatementBalance, 88000.0); // Metadata safely read without corrupting liability
    });

    // -------------------------------------------------------------------------
    // Invariant 7: Legacy credit_transactions cannot override canonical liability
    // -------------------------------------------------------------------------
    test('7. Rogue direct SQL INSERT into credit_transactions cannot alter canonical card liability', () async {
      final card = CreditCard(
        id: 'card_inv_7',
        name: 'Kotak White',
        bank: 'Kotak Mahindra',
        last4: '8888',
        limitAmount: 200000.0,
        usedAmount: 5000.0,
      );
      await creditRepo.insert(card);

      // Rogue raw insert into credit_transactions bypassing canonical event repo
      await db.rawInsert(
        'INSERT INTO ${Tables.creditTransactions} (id, cardId, amount, date, category, type, status) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['rogue_tx_999', 'card_inv_7', 75000.0, DateTime.now().toIso8601String(), 'fake_cat', 'purchase', 'active'],
      );

      // Verify row exists in legacy table
      final rogueTx = await creditRepo.getTransactionById('rogue_tx_999');
      expect(rogueTx, isNotNull);

      // Canonical postings and derived balance must remain EXACTLY ₹5,000
      final liability = await canonicalAccountRepo.getDerivedBalance('card_inv_7');
      expect(liability.toRupees, 5000.0);

      final outstanding = await container.read(creditOutstandingProvider('card_inv_7').future);
      expect(outstanding, 5000.0);

      final cards = await container.read(creditCardsProvider.future);
      final cardFromProvider = cards.firstWhere((c) => c.id == 'card_inv_7');
      expect(cardFromProvider.usedAmount, 5000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 8: Card transaction history remains consistent with canonical events
    // -------------------------------------------------------------------------
    test('8. Card transaction history reflects legitimate transactions in order', () async {
      final card = CreditCard(
        id: 'card_inv_8',
        name: 'IndusInd Legend',
        bank: 'IndusInd',
        last4: '2222',
        limitAmount: 100000.0,
      );
      await creditRepo.insert(card);

      final now = DateTime.now();
      final tx1 = CreditTransaction(
        id: 'legit_tx_1',
        cardId: 'card_inv_8',
        amount: 2500.0,
        date: now.subtract(const Duration(days: 2)),
        category: 'shopping',
        type: 'purchase',
        status: 'active',
      );
      final tx2 = CreditTransaction(
        id: 'legit_tx_2',
        cardId: 'card_inv_8',
        amount: 1500.0,
        date: now.subtract(const Duration(days: 1)),
        category: 'fuel',
        type: 'purchase',
        status: 'active',
      );
      await creditRepo.insertTransaction(tx1);
      await creditRepo.insertTransaction(tx2);

      // Verify creditTransactionsProvider
      final txns = await container.read(app_data.creditTransactionsProvider('card_inv_8').future);
      expect(txns.length, 2);
      expect(txns.first.id, 'legit_tx_2'); // DESC order by date
      expect(txns.last.id, 'legit_tx_1');

      // Verify creditRecentTransactionsProvider
      final recent = await container.read(creditRecentTransactionsProvider('card_inv_8').future);
      expect(recent.length, 2);
      expect(recent.first.id, 'legit_tx_2');
    });

    // -------------------------------------------------------------------------
    // Invariant 9: Available credit is derived from canonical outstanding + contractual credit limit
    // -------------------------------------------------------------------------
    test('9. Available credit dynamically derives as clamp(0, limit - canonical liability)', () async {
      final card = CreditCard(
        id: 'card_inv_9',
        name: 'RBL World Safari',
        bank: 'RBL Bank',
        last4: '3333',
        limitAmount: 100000.0,
        usedAmount: 40000.0,
      );
      await creditRepo.insert(card);

      // Rogue update: credit_cards.used_amount set to 0.0
      await db.rawUpdate(
        'UPDATE ${Tables.creditCards} SET used_amount = 0.0 WHERE id = ?',
        ['card_inv_9'],
      );

      final cards = await container.read(creditCardsProvider.future);
      final c = cards.firstWhere((x) => x.id == 'card_inv_9');

      // Available credit must derive from CANONICAL outstanding (₹40,000), NOT rogue 0.0!
      expect(c.usedAmount, 40000.0);
      expect(c.availableLimit, 60000.0); // 100,000 - 40,000
      expect(c.utilizationPct, 40.0); // 40,000 / 100,000 * 100
    });

    // -------------------------------------------------------------------------
    // Invariant 10: Dynamic card deletion/archival maintains canonical accounting integrity
    // -------------------------------------------------------------------------
    test('10. Card deletion soft-archives if postings exist, preserving immutable ledger audit history', () async {
      final card = CreditCard(
        id: 'card_inv_10',
        name: 'IDFC FIRST Wealth',
        bank: 'IDFC FIRST',
        last4: '4444',
        limitAmount: 500000.0,
        usedAmount: 10000.0, // has opening balance postings
      );
      await creditRepo.insert(card);

      // Verify card is active
      var activeCards = await creditRepo.getAll();
      expect(activeCards.any((c) => c.id == 'card_inv_10'), isTrue);

      // Delete card with historical postings
      await creditRepo.delete('card_inv_10');

      // 1. Must be soft-archived (is_active = 0 in accounts)
      final accountRow = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: ['card_inv_10'],
      );
      expect(accountRow.isNotEmpty, isTrue);
      expect(accountRow.first['is_active'], 0);

      // 2. Postings must be completely preserved for auditability
      final postings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['card_inv_10'],
      );
      expect(postings.isNotEmpty, isTrue);

      // 3. Must be excluded from active providers
      container.invalidate(app_data.cardsProvider);
      final cardsAfter = await container.read(creditCardsProvider.future);
      expect(cardsAfter.any((c) => c.id == 'card_inv_10'), isFalse);
    });

    // -------------------------------------------------------------------------
    // Additional Test 11: CreditHealthProvider aggregates canonical liability across all cards
    // -------------------------------------------------------------------------
    test('11. CreditHealthProvider aggregates strictly canonical liability across cards', () async {
      final cardA = CreditCard(
        id: 'card_health_a',
        name: 'Card A',
        bank: 'Bank A',
        limitAmount: 100000.0,
        usedAmount: 25000.0,
        dueDay: 15,
      );
      final cardB = CreditCard(
        id: 'card_health_b',
        name: 'Card B',
        bank: 'Bank B',
        limitAmount: 50000.0,
        usedAmount: 10000.0,
        dueDay: 20,
      );
      await creditRepo.insert(cardA);
      await creditRepo.insert(cardB);

      // Corrupt both legacy rows
      await db.rawUpdate('UPDATE ${Tables.creditCards} SET used_amount = 0.0');

      final health = await container.read(creditHealthProvider.future);

      // Must be 25,000 + 10,000 = 35,000
      expect(health.totalOutstanding, 35000.0);
      expect(health.totalLimit, 150000.0);
      expect(health.totalAvailable, 115000.0);
    });

    // -------------------------------------------------------------------------
    // Additional Test 12: CreditCardService.calculateOutstanding derives canonical liability
    // -------------------------------------------------------------------------
    test('12. CreditCardService.calculateOutstanding returns canonical derived balance', () async {
      final card = CreditCard(
        id: 'card_svc_test',
        name: 'Amazon ICICI',
        bank: 'ICICI',
        limitAmount: 50000.0,
        usedAmount: 8500.0,
      );
      await creditRepo.insert(card);

      final outstanding = await creditCardService.calculateOutstanding('card_svc_test');
      expect(outstanding, 8500.0);
    });
  });
}
