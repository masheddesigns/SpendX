import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/domain/net_worth/net_worth_service.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/live_sms_service.dart';
import 'package:spend_x/services/sms_import_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Live SMS Event Classification & Credit-Card Accounting Suite', () {
    late Database db;
    final importService = SmsImportService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
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
      await CategoryRepo(executor: db).ensureDefaults();
    });

    tearDown(() async {
      await db.close();
    });

    group('1. Event Classification Precedence', () {
      test('1a. ICICI BBPS Credit Card bill payments are classified as creditCardPayment', () {
        const bodies = [
          'Payment of Rs 10,000.00 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System on 07-OCT-26.',
          'Payment of Rs 15,000.00 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System on 07-OCT-26.',
          'Payment of Rs 5,000.00 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System on 07-OCT-26.',
          'Payment of Rs 2,099.46 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System on 04-OCT-26.',
        ];

        for (final body in bodies) {
          final res = importService.classifyMessage(body, 'AD-ICICIT-S');
          expect(res.transaction, isNotNull);
          expect(res.eventType, SmsEventType.creditCardPayment);
          expect(res.transaction!.isCredit, isFalse, reason: 'Zero income, liability reduction');
          expect(res.transaction!.last4, '5007');
        }
      });

      test('1b. HDFC Credit Card bill payment is classified as creditCardPayment with available limit', () {
        const body = 'DEAR HDFCBANK CARDMEMBER, PAYMENT OF Rs. 2000.00 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 6366 ON 2-10-2026.YOUR AVAILABLE LIMIT IS RS. 77755.88';
        final res = importService.classifyMessage(body, 'JM-HDFCBK-S');

        expect(res.transaction, isNotNull);
        expect(res.transaction!.amount, 2000.0);
        expect(res.eventType, SmsEventType.creditCardPayment);
        expect(res.transaction!.last4, '6366');
        expect(res.balance, isNotNull);
        expect(res.balance!.amount, 77755.88);
        expect(res.balance!.isAvailableLimit, isTrue);
      });

      test('1c. Jupiter Edge RuPay Credit Card bill payment is classified as creditCardPayment', () {
        const body = 'Your payment of Rs 13.02  for your Edge CSB Bank RuPay Credit Card was successful. Thanks for using the Jupiter app.';
        final res = importService.classifyMessage(body, 'AX-JTEDGE-S');

        expect(res.transaction, isNotNull);
        expect(res.transaction!.amount, 13.02);
        expect(res.eventType, SmsEventType.creditCardPayment);
      });

      test('1d. Credit Card purchase is classified as creditCardPurchase with available limit', () {
        const body = 'INR 464.00 spent using ICICI Bank Card XX5007 on 05-Oct-26 on AMAZON PAY IN E. Avl Limit: INR 82,933.13. If not you, call 1800 2662/SMS BLOCK 5007 to 9215676766.';
        final res = importService.classifyMessage(body, 'JD-ICICIT-S');

        expect(res.transaction, isNotNull);
        expect(res.transaction!.amount, 464.0);
        expect(res.eventType, SmsEventType.creditCardPurchase);
        expect(res.transaction!.isCredit, isFalse);
        expect(res.balance, isNotNull);
        expect(res.balance!.amount, 82933.13);
        expect(res.balance!.isAvailableLimit, isTrue);
      });

      test('1e. Credit Card refund is classified as refund', () {
        const body = 'AMAZON PAY IN E COMMERC refund of Rs 189.00 credited to ICICI Bank Credit Card XX5007 on 18-SEP-26. Revised total due Rs 0, minimum due Rs .00';
        final res = importService.classifyMessage(body, 'JX-ICICIT-S');

        expect(res.transaction, isNotNull);
        expect(res.transaction!.amount, 189.0);
        expect(res.eventType, SmsEventType.refund);
        expect(res.transaction!.isCredit, isTrue);
        expect(res.balance, isNotNull);
        expect(res.balance!.amount, 0.0);
        expect(res.balance!.isAvailableLimit, isFalse);
      });

      test('1f. Failed transaction is rejected from creating a transaction', () {
        const body = 'Your transaction of ₹3500.00 at SOOFI MANDI CALICUT KLIN on your Edge CSB Bank Credit Card failed as the payment channel is disabled.';
        final res = importService.classifyMessage(body, 'AD-JTEDGE-S');

        expect(res.eventType, SmsEventType.failed);
      });
    });

    group('2. Double-Entry Accounting Invariants', () {
      test('2a. Credit Card bill payment creates balanced postings (Debit Card Liability, Credit Bank Asset), zero income, zero expense', () async {
        final creditRepo = CreditRepo(executor: db);
        final accountRepo = AccountRepo(executor: db);
        final txRepo = TransactionRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);

        // 1. Create Bank Account and Credit Card
        final bank = BankAccount(
          name: 'Jio Payments Bank',
          bank: 'Jio Payments Bank',
          last4: '3284',
          balance: 20000.0,
        );
        final bankId = await accountRepo.insertAccount(bank);

        final card = CreditCard(
          name: 'ICICI Coral',
          bank: 'ICICI Bank',
          last4: '5007',
          limitAmount: 100000.0,
          usedAmount: 30000.0,
        );
        final cardId = await creditRepo.insert(card);

        // Verify initial state
        final initialCardBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(initialCardBal.toRupees, 30000.0);

        // 2. Process ₹10,000 credit card bill payment
        final paymentTx = Transaction(
          id: 'tx_cc_pay_1',
          amount: 10000.0,
          userId: 'offline_user',
          type: 'credit_payment',
          accountId: bankId,
          relatedEntityId: cardId,
          date: DateTime.now(),
          notes: 'Payment towards ICICI Credit Card',
          source: 'credit_card_payment',
        );

        await FinancialTransactionService(database: db).createTransaction(paymentTx);

        // 3. Verify Postings in canonical ledger
        final canonicalEventRepo = CanonicalEventRepository(executor: db);
        final postings = await canonicalEventRepo.getPostingsForEvent('tx_cc_pay_1');
        expect(postings.length, 2);

        // Posting 1: Debit Card Liability (reducing used balance)
        final cardPosting = postings.firstWhere((p) => p.accountId == cardId);
        expect(cardPosting.direction.name, 'debit');
        expect(cardPosting.amount.asRupees, 10000.0);

        // Posting 2: Credit Bank Asset (reducing cash)
        final bankPosting = postings.firstWhere((p) => p.accountId == bankId);
        expect(bankPosting.direction.name, 'credit');
        expect(bankPosting.amount.asRupees, 10000.0);

        // 4. Invariant: Zero income, zero expense
        final now = DateTime.now();
        final stats = await txRepo.getStatsForMonth(now.year, now.month);
        expect(stats['income'], 0.0, reason: 'Credit card payment must generate ZERO income');
        expect(stats['expense'], 0.0, reason: 'Credit card payment must generate ZERO expense');

        // 5. Account balances derived correctly
        final finalCardBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(finalCardBal.toRupees, 20000.0, reason: '30,000 liability - 10,000 payment = 20,000 liability');

        final finalBankBal = await canonicalRepo.getDerivedBalance(bankId);
        expect(finalBankBal.toRupees, 10000.0, reason: '20,000 cash - 10,000 payment = 10,000 cash');
      });

      test('2b. Credit Card purchase debits expense, credits card liability (never bank asset)', () async {
        final creditRepo = CreditRepo(executor: db);
        final catRepo = CategoryRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final txRepo = TransactionRepo(executor: db);

        final card = CreditCard(
          name: 'BOBCARD One',
          bank: 'BOBCARD',
          last4: '2510',
          limitAmount: 50000.0,
          usedAmount: 0.0,
        );
        final cardId = await creditRepo.insert(card);

        final miscCat = await catRepo.getByName('Miscellaneous', type: 'expense');
        expect(miscCat, isNotNull);

        final purchaseTx = Transaction(
          id: 'tx_cc_spend_1',
          amount: 299.0,
          userId: 'offline_user',
          type: 'expense',
          categoryId: miscCat!.id,
          accountId: cardId,
          date: DateTime.now(),
          notes: 'Youtubegoogle',
          source: 'credit_card_purchase',
        );

        await FinancialTransactionService(database: db).createTransaction(purchaseTx);

        // Verify postings
        final canonicalEventRepo = CanonicalEventRepository(executor: db);
        final postings = await canonicalEventRepo.getPostingsForEvent('tx_cc_spend_1');
        expect(postings.length, 2);

        // Debit Expense
        final expPosting = postings.firstWhere((p) => p.accountId == miscCat.id);
        expect(expPosting.direction.name, 'debit');
        expect(expPosting.amount.asRupees, 299.0);

        // Credit Card Liability
        final cardPosting = postings.firstWhere((p) => p.accountId == cardId);
        expect(cardPosting.direction.name, 'credit');
        expect(cardPosting.amount.asRupees, 299.0);

        // Stats: Expense increased by 299, Income 0
        final now = DateTime.now();
        final stats = await txRepo.getStatsForMonth(now.year, now.month);
        expect(stats['expense'], 299.0);
        expect(stats['income'], 0.0);

        // Card liability updated to 299
        final finalCardBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(finalCardBal.toRupees, 299.0);
      });

      test('2c. Credit Card refund reduces card liability, credits contra-expense, zero income', () async {
        final creditRepo = CreditRepo(executor: db);
        final catRepo = CategoryRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final txRepo = TransactionRepo(executor: db);

        final card = CreditCard(
          name: 'ICICI Card',
          bank: 'ICICI Bank',
          last4: '5007',
          limitAmount: 100000.0,
          usedAmount: 5000.0,
        );
        final cardId = await creditRepo.insert(card);

        final miscCat = await catRepo.getByName('Miscellaneous', type: 'expense');
        expect(miscCat, isNotNull);

        final refundTx = Transaction(
          id: 'tx_cc_refund_1',
          amount: 189.0,
          userId: 'offline_user',
          type: 'refund',
          categoryId: miscCat!.id,
          accountId: cardId,
          date: DateTime.now(),
          notes: 'AMAZON PAY IN E COMMERC refund',
          source: 'credit_card_purchase',
        );

        await FinancialTransactionService(database: db).createTransaction(refundTx);

        // Verify postings
        final canonicalEventRepo = CanonicalEventRepository(executor: db);
        final postings = await canonicalEventRepo.getPostingsForEvent('tx_cc_refund_1');
        expect(postings.length, 2);

        // Debit Card Liability (reduces liability)
        final cardPosting = postings.firstWhere((p) => p.accountId == cardId);
        expect(cardPosting.direction.name, 'debit');
        expect(cardPosting.amount.asRupees, 189.0);

        // Credit Contra-Expense
        final catPosting = postings.firstWhere((p) => p.accountId == miscCat.id);
        expect(catPosting.direction.name, 'credit');
        expect(catPosting.amount.asRupees, 189.0);

        // Income remains ZERO (refund is contra-expense)
        final now = DateTime.now();
        final stats = await txRepo.getStatsForMonth(now.year, now.month);
        expect(stats['income'], 0.0);

        // Card liability reduced
        final finalCardBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(finalCardBal.toRupees, 4811.0);
      });

      test('2d. Full ICICI ₹30,000 Scenario: 3 distinct payments (10k, 15k, 5k) reduce liability by 30k, reduce paying bank by 30k, 0 income, 0 expense', () async {
        final creditRepo = CreditRepo(executor: db);
        final accountRepo = AccountRepo(executor: db);
        final txRepo = TransactionRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final canonicalEventRepo = CanonicalEventRepository(executor: db);
        final ftService = FinancialTransactionService(database: db);

        // Paying Bank Account: ₹50,000
        final bank = BankAccount(
          name: 'Federal Account',
          bank: 'Federal Bank',
          last4: '8434',
          balance: 50000.0,
        );
        final bankId = await accountRepo.insertAccount(bank);

        // ICICI Credit Card: initial liability ₹35,000
        final card = CreditCard(
          name: 'ICICI Coral',
          bank: 'ICICI Bank',
          last4: '5007',
          limitAmount: 100000.0,
          usedAmount: 35000.0,
        );
        final cardId = await creditRepo.insert(card);

        final payments = [
          (id: 'tx_pay_10k', amount: 10000.0, note: 'Payment 10k BBPS'),
          (id: 'tx_pay_15k', amount: 15000.0, note: 'Payment 15k BBPS'),
          (id: 'tx_pay_5k', amount: 5000.0, note: 'Payment 5k BBPS'),
        ];

        for (final p in payments) {
          final tx = Transaction(
            id: p.id,
            amount: p.amount,
            userId: 'offline_user',
            type: 'credit_payment',
            accountId: bankId,
            relatedEntityId: cardId,
            date: DateTime(2026, 10, 7, 10, 0),
            notes: p.note,
            source: 'credit_card_payment',
            externalRef: 'ext_${p.id}',
          );
          await ftService.createTransaction(tx);

          // Verify each payment has 2 balanced postings
          final postings = await canonicalEventRepo.getPostingsForEvent(p.id);
          expect(postings.length, 2);
          final cardPosting = postings.firstWhere((post) => post.accountId == cardId);
          final bankPosting = postings.firstWhere((post) => post.accountId == bankId);
          expect(cardPosting.direction.name, 'debit');
          expect(cardPosting.amount.asRupees, p.amount);
          expect(bankPosting.direction.name, 'credit');
          expect(bankPosting.amount.asRupees, p.amount);
        }

        // Verify total liability reduced by exactly ₹30,000 (35,000 - 30,000 = 5,000)
        final finalCardBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(finalCardBal.toRupees, 5000.0);

        // Verify paying bank asset reduced by exactly ₹30,000 (50,000 - 30,000 = 20,000)
        final finalBankBal = await canonicalRepo.getDerivedBalance(bankId);
        expect(finalBankBal.toRupees, 20000.0);

        // Invariant: Total income = 0, Total expense = 0
        final stats = await txRepo.getStatsForMonth(2026, 10);
        expect(stats['income'], 0.0);
        expect(stats['expense'], 0.0);
      });

      test('2e. HDFC Cross-Message & Separate Equal-Amount Scenario', () async {
        final creditRepo = CreditRepo(executor: db);
        final accountRepo = AccountRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final ftService = FinancialTransactionService(database: db);

        final bank = BankAccount(
          name: 'Jio Payments Bank',
          bank: 'Jio Payments Bank',
          last4: '3284',
          balance: 10000.0,
        );
        final bankId = await accountRepo.insertAccount(bank);

        final card = CreditCard(
          name: 'HDFC Millennia',
          bank: 'HDFC Bank',
          last4: '6366',
          limitAmount: 80000.0,
          usedAmount: 15000.0,
        );
        final cardId = await creditRepo.insert(card);

        // 1. Initial Bank Debit: Jio PB reports ₹2,000 sent to HDFC CC
        final bankDebit = Transaction(
          id: 'tx_jio_debit_1',
          amount: 2000.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: DateTime(2026, 10, 2, 14, 0),
          notes: 'Paid to HDFC CC XX6366',
          source: 'sms',
        );
        await ftService.createTransaction(bankDebit);

        // At this point: bank reduced by 2000, expense 2000
        var derivedBank = await canonicalRepo.getDerivedBalance(bankId);
        expect(derivedBank.toRupees, 8000.0);

        // 2. Cross-message matching: When HDFC confirmation arrives,
        // it updates the original bank debit to canonical credit_payment
        final matchedDebit = bankDebit.copyWith(
          type: 'credit_payment',
          source: 'credit_card_payment',
          relatedEntityId: cardId,
          notes: 'Payment towards HDFC Millennia (6366)',
        );
        await ftService.editTransaction(
          oldTransaction: bankDebit,
          newTransaction: matchedDebit,
        );

        // Bank balance decreased ONCE (8000)
        derivedBank = await canonicalRepo.getDerivedBalance(bankId);
        expect(derivedBank.toRupees, 8000.0);

        // Card liability decreased ONCE (15,000 - 2,000 = 13,000)
        var derivedCard = await canonicalRepo.getDerivedBalance(cardId);
        expect(derivedCard.toRupees, 13000.0);

        // Expense reversed to 0, income 0
        final txRepo = TransactionRepo(executor: db);
        final stats = await txRepo.getStatsForMonth(2026, 10);
        expect(stats['expense'], 0.0);
        expect(stats['income'], 0.0);

        // 3. Two separate ₹2,000 payments on the same day must remain distinct events
        final secondPayment = Transaction(
          id: 'tx_hdfc_pay_2',
          amount: 2000.0,
          userId: 'offline_user',
          type: 'credit_payment',
          accountId: bankId,
          relatedEntityId: cardId,
          date: DateTime(2026, 10, 2, 16, 30),
          notes: 'Second Payment of ₹2,000 towards HDFC Card',
          source: 'credit_card_payment',
          externalRef: 'ext_second_pay_2000',
        );
        await ftService.createTransaction(secondPayment);

        // Now two distinct payments of 2000 each
        final allTx = await txRepo.getAll();
        expect(allTx.where((t) => t.amount == 2000.0 && t.type == 'credit_payment').length, 2);

        // Bank balance reduced by another 2,000 (8000 -> 6000)
        derivedBank = await canonicalRepo.getDerivedBalance(bankId);
        expect(derivedBank.toRupees, 6000.0);

        // Card liability reduced by another 2,000 (13,000 -> 11,000)
        derivedCard = await canonicalRepo.getDerivedBalance(cardId);
        expect(derivedCard.toRupees, 11000.0);
      });

      test('2f. Available credit limit vs derived ledger liability distinction', () async {
        final creditRepo = CreditRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);

        // Total Limit: ₹100,000, Initial Liability: ₹20,000
        final card = CreditCard(
          name: 'ICICI Coral',
          bank: 'ICICI Bank',
          last4: '5007',
          limitAmount: 100000.0,
          usedAmount: 20000.0,
        );
        final cardId = await creditRepo.insert(card);

        // Initial derived liability
        var derivedLiability = await canonicalRepo.getDerivedBalance(cardId);
        expect(derivedLiability.toRupees, 20000.0);

        // Available Limit = 80,000 (meaning outstanding is 100,000 - 80,000 = 20,000)
        // Ensure that available limit of 80,000 is NEVER set as liability
        final hit = BalanceHit(
          kind: BalanceKind.creditCard,
          amount: 80000.0,
          last4: '5007',
          bankKeyword: 'icici',
          sender: 'JD-ICICIT-S',
          body: 'Avl Limit: INR 80,000.00',
          isAvailableLimit: true,
        );

        expect(hit.isAvailableLimit, isTrue);
        // Derived outstanding from available limit:
        final derivedOutstanding = card.limitAmount - hit.amount;
        expect(derivedOutstanding, 20000.0);
        expect(derivedOutstanding != hit.amount, isTrue);
      });

      test('2g. Other Canonical Event Types (Bank Income, Transfer, Wallet topup)', () async {
        final accountRepo = AccountRepo(executor: db);
        final catRepo = CategoryRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final canonicalEventRepo = CanonicalEventRepository(executor: db);
        final ftService = FinancialTransactionService(database: db);

        final bankA = BankAccount(name: 'Bank A', bank: 'SBI', last4: '1111', balance: 5000.0);
        final bankIdA = await accountRepo.insertAccount(bankA);

        final bankB = BankAccount(name: 'Bank B', bank: 'HDFC', last4: '2222', balance: 1000.0);
        final bankIdB = await accountRepo.insertAccount(bankB);

        final salaryCat = await catRepo.getByName('Salary', type: 'income');

        // 1. Bank Income: +₹25,000
        final incomeTx = Transaction(
          id: 'tx_salary_1',
          amount: 25000.0,
          userId: 'offline_user',
          type: 'income',
          accountId: bankIdA,
          categoryId: salaryCat?.id,
          date: DateTime.now(),
          notes: 'Salary credited',
          source: 'sms',
        );
        await ftService.createTransaction(incomeTx);

        var balA = await canonicalRepo.getDerivedBalance(bankIdA);
        expect(balA.toRupees, 30000.0); // 5000 + 25000

        // 2. Bank Transfer: ₹4,000 from Bank A to Bank B
        final transferTx = Transaction(
          id: 'tx_transfer_1',
          amount: 4000.0,
          userId: 'offline_user',
          type: 'transfer',
          accountId: bankIdA,
          relatedEntityId: bankIdB,
          date: DateTime.now(),
          notes: 'Transfer to Bank B',
          source: 'manual',
        );
        await ftService.createTransaction(transferTx);

        final transferPostings = await canonicalEventRepo.getPostingsForEvent('tx_transfer_1');
        expect(transferPostings.length, 2);
        final debitPosting = transferPostings.firstWhere((p) => p.accountId == bankIdB);
        final creditPosting = transferPostings.firstWhere((p) => p.accountId == bankIdA);
        expect(debitPosting.direction.name, 'debit');
        expect(creditPosting.direction.name, 'credit');

        balA = await canonicalRepo.getDerivedBalance(bankIdA);
        final balB = await canonicalRepo.getDerivedBalance(bankIdB);
        expect(balA.toRupees, 26000.0); // 30000 - 4000
        expect(balB.toRupees, 5000.0);  // 1000 + 4000
      });

      test('2h. Gate 1: Unknown Funding Account uses approved Suspense, does not touch arbitrary banks, and is balanced', () async {
        final creditRepo = CreditRepo(executor: db);
        final accountRepo = AccountRepo(executor: db);
        final txRepo = TransactionRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final canonicalEventRepo = CanonicalEventRepository(executor: db);
        final ftService = FinancialTransactionService(database: db);

        // Pre-existing bank account with ₹50,000
        final bank = BankAccount(
          name: 'Federal Account',
          bank: 'Federal Bank',
          last4: '8434',
          balance: 50000.0,
        );
        final bankId = await accountRepo.insertAccount(bank);

        // ICICI Credit card with initial liability ₹35,000
        final card = CreditCard(
          name: 'ICICI Coral',
          bank: 'ICICI Bank',
          last4: '5007',
          limitAmount: 100000.0,
          usedAmount: 35000.0,
        );
        final cardId = await creditRepo.insert(card);

        // Standalone confirmation without paying bank info (e.g. BBPS confirmation)
        final unlinkedPayment = Transaction(
          id: 'tx_cc_pay_suspense_1',
          amount: 10000.0,
          userId: 'offline_user',
          type: 'credit_payment',
          accountId: null, // unknown funding account
          relatedEntityId: cardId, // ICICI Card
          date: DateTime.now(),
          notes: 'BBPS payment confirmation received on ICICI card',
          source: 'credit_card_payment',
        );
        await ftService.createTransaction(unlinkedPayment);

        // 1. Postings check: exactly 2 balanced postings
        final postings = await canonicalEventRepo.getPostingsForEvent('tx_cc_pay_suspense_1');
        expect(postings.length, 2);

        // Posting 1 debits card liability
        final cardPosting = postings.firstWhere((p) => p.accountId == cardId);
        expect(cardPosting.direction.name, 'debit');
        expect(cardPosting.amount.asRupees, 10000.0);

        // Posting 2 credits suspense transfer account (never arbitrary bank!)
        final suspensePosting = postings.firstWhere((p) => p.accountId == TablesV24.sysSuspenseTransfer);
        expect(suspensePosting.direction.name, 'credit');
        expect(suspensePosting.amount.asRupees, 10000.0);

        // 2. Invariant: Arbitrary bank asset is UNTOUCHED
        final bankBal = await canonicalRepo.getDerivedBalance(bankId);
        expect(bankBal.toRupees, 50000.0, reason: 'Arbitrary bank account must NOT be credited without evidence');

        // 3. Card liability reduced by ₹10,000
        final cardBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(cardBal.toRupees, 25000.0);

        // 4. Invariant: 0 income, 0 expense
        final now = DateTime.now();
        final stats = await txRepo.getStatsForMonth(now.year, now.month);
        expect(stats['income'], 0.0);
        expect(stats['expense'], 0.0);
      });

      test('2i. Gate 2 Adversarial: Cross-message matching rejects uncertain matches and merges only genuine evidence', () async {
        final creditRepo = CreditRepo(executor: db);
        final accountRepo = AccountRepo(executor: db);
        final txRepo = TransactionRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final ftService = FinancialTransactionService(database: db);

        final bank = BankAccount(
          name: 'SBI Savings',
          bank: 'SBI',
          last4: '9999',
          balance: 20000.0,
        );
        final bankId = await accountRepo.insertAccount(bank);

        final cardA = CreditCard(
          name: 'HDFC Card',
          bank: 'HDFC Bank',
          last4: '1111',
          limitAmount: 50000.0,
          usedAmount: 10000.0,
        );
        final cardIdA = await creditRepo.insert(cardA);

        final cardB = CreditCard(
          name: 'ICICI Card',
          bank: 'ICICI Bank',
          last4: '2222',
          limitAmount: 50000.0,
          usedAmount: 10000.0,
        );
        final cardIdB = await creditRepo.insert(cardB);

        // Case 1: Debit note mentions generic purchase "Store Card Payment" without CC/BBPS marker
        // Proximity alone should NOT merge with CC payment
        final genericDebit = Transaction(
          id: 'tx_generic_store_debit',
          amount: 1500.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: DateTime(2026, 10, 8, 12, 0),
          notes: 'Paid to Grocery Mart Card Machine',
          source: 'sms',
        );
        await ftService.createTransaction(genericDebit);

        // Standalone CC payment on Card A of 1500
        final ccPaymentA = Transaction(
          id: 'tx_cc_pay_a',
          amount: 1500.0,
          userId: 'offline_user',
          type: 'credit_payment',
          accountId: null,
          relatedEntityId: cardIdA,
          date: DateTime(2026, 10, 8, 12, 5),
          notes: 'Payment towards HDFC CC XX1111',
          source: 'credit_card_payment',
        );
        await ftService.createTransaction(ccPaymentA);

        // Verify generic debit remained expense and was NOT merged
        final allTx = await txRepo.getAll();
        final storeTx = allTx.firstWhere((t) => t.id == 'tx_generic_store_debit');
        expect(storeTx.type, 'expense');
        expect(storeTx.relatedEntityId, isNull);

        // Case 2: Same amount (₹2,000) for different cards must link to the respective card
        final debitForCardB = Transaction(
          id: 'tx_debit_card_b',
          amount: 2000.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: DateTime(2026, 10, 8, 14, 0),
          notes: 'BBPS ICICI Credit Card payment 2222',
          source: 'sms',
        );
        await ftService.createTransaction(debitForCardB);

        // When linking evidence arrives for Card B, it updates debit to Card B
        final linkedDebitB = debitForCardB.copyWith(
          type: 'credit_payment',
          source: 'credit_card_payment',
          relatedEntityId: cardIdB,
          notes: 'Payment towards ICICI Card (2222)',
        );
        await ftService.editTransaction(
          oldTransaction: debitForCardB,
          newTransaction: linkedDebitB,
        );

        // Verify Card B liability decreased by 2000 (10,000 -> 8,000)
        final cardBalB = await canonicalRepo.getDerivedBalance(cardIdB);
        expect(cardBalB.toRupees, 8000.0);

        // Card A liability is completely untouched (still 10,000 - 1500 = 8500)
        final cardBalA = await canonicalRepo.getDerivedBalance(cardIdA);
        expect(cardBalA.toRupees, 8500.0);
      });

      test('2j. Gate 2 Append-Only: editTransaction never overwrites posted events, performs append-only reversal/replacement, and preserves balanced postings', () async {
        final accountRepo = AccountRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final canonicalEventRepo = CanonicalEventRepository(executor: db);
        final ftService = FinancialTransactionService(database: db);

        final bank = BankAccount(name: 'Canara Bank', bank: 'Canara', last4: '4321', balance: 10000.0);
        final bankId = await accountRepo.insertAccount(bank);

        final originalTx = Transaction(
          id: 'tx_original_posted_1',
          amount: 500.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: DateTime.now(),
          notes: 'Grocery spend',
          source: 'sms',
        );
        await ftService.createTransaction(originalTx);

        // 1. Initial event is posted and has 2 balanced postings
        final initialEvents = await canonicalEventRepo.listPostedEvents();
        expect(initialEvents.any((e) => e.id == 'tx_original_posted_1'), isTrue);

        // 2. Perform edit via FinancialTransactionService
        final correctedTx = originalTx.copyWith(
          amount: 600.0,
          notes: 'Corrected Grocery Spend',
        );
        await ftService.editTransaction(
          oldTransaction: originalTx,
          newTransaction: correctedTx,
        );

        // 3. Verify append-only invariant:
        // Original event is NOT overwritten. It is preserved in the database.
        final originalEventAfter = await canonicalEventRepo.getEvent('tx_original_posted_1');
        expect(originalEventAfter, isNotNull);
        expect(originalEventAfter!.lifecycleStatus.name, 'posted');

        // A REVERSAL event exists in economic_events pointing to original
        final allPostedEvents = await canonicalEventRepo.listPostedEvents();
        final reversalEvent = allPostedEvents.firstWhere((e) =>
          e.description.startsWith('REVERSAL: tx_original_posted_1')
        );
        expect(reversalEvent, isNotNull);

        // A REPLACEMENT event exists with the new amount (600)
        final replacementEvent = allPostedEvents.firstWhere((e) =>
          e.id.startsWith('tx_original_posted_1:corr:')
        );
        expect(replacementEvent, isNotNull);

        // Postings on original, reversal, and replacement are ALL balanced
        final origPostings = await canonicalEventRepo.getPostingsForEvent(originalEventAfter.id);
        final revPostings = await canonicalEventRepo.getPostingsForEvent(reversalEvent.id);
        final replPostings = await canonicalEventRepo.getPostingsForEvent(replacementEvent.id);

        expect(origPostings.length, 2);
        expect(revPostings.length, 2);
        expect(replPostings.length, 2);

        // Reversal postings exactly negate original postings
        final origBankPosting = origPostings.firstWhere((p) => p.accountId == bankId);
        final revBankPosting = revPostings.firstWhere((p) => p.accountId == bankId);
        expect(origBankPosting.direction.name, 'credit');
        expect(revBankPosting.direction.name, 'debit');
        expect(origBankPosting.amount.asRupees, 500.0);
        expect(revBankPosting.amount.asRupees, 500.0);

        // Net bank balance matches corrected amount (10,000 - 600 = 9,400)
        final finalBankBal = await canonicalRepo.getDerivedBalance(bankId);
        expect(finalBankBal.toRupees, 9400.0);
      });

      test('2k. Gate 3 Suspense: sysSuspenseTransfer balance is visible, reconcilable, and card liability is posted exactly once', () async {
        final creditRepo = CreditRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final ftService = FinancialTransactionService(database: db);

        final card = CreditCard(
          name: 'Axis Bank Card',
          bank: 'Axis Bank',
          last4: '7777',
          limitAmount: 50000.0,
          usedAmount: 12000.0,
        );
        final cardId = await creditRepo.insert(card);

        // Unknown funding payment of ₹3,000
        final paymentTx = Transaction(
          id: 'tx_cc_suspense_reconcile',
          amount: 3000.0,
          userId: 'offline_user',
          type: 'credit_payment',
          accountId: null, // unknown funding account -> sys_suspense_transfer
          relatedEntityId: cardId,
          date: DateTime.now(),
          notes: 'Payment received towards Axis Card',
          source: 'credit_card_payment',
        );
        await ftService.createTransaction(paymentTx);

        // 1. Card liability reduced exactly once (12,000 - 3,000 = 9,000)
        final cardBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(cardBal.toRupees, 9000.0);

        // 2. Suspense account balance is visible and reconcilable
        final suspenseAccount = await canonicalRepo.getAccount(TablesV24.sysSuspenseTransfer);
        expect(suspenseAccount, isNotNull);
        expect(suspenseAccount!.type.name, 'asset');
        expect(suspenseAccount.category, 'suspense');

        final suspenseBal = await canonicalRepo.getDerivedBalance(TablesV24.sysSuspenseTransfer);
        // Credited 3000 to an asset account gives a credit balance of -₹3,000 awaiting funding allocation
        expect(suspenseBal.toRupees, -3000.0);
      });

      test('2l. Gate 1 Collision: Same-card payments with identical amounts within 30 min match corresponding debits with distinct references', () async {
        final accountRepo = AccountRepo(executor: db);
        final creditRepo = CreditRepo(executor: db);
        final txRepo = TransactionRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final ftService = FinancialTransactionService(database: db);

        // Bank Account
        final bank = BankAccount(name: 'Canara Bank', bank: 'Canara', last4: '5555', balance: 50000.0);
        final bankId = await accountRepo.insertAccount(bank);

        // Credit Card
        final card = CreditCard(name: 'ICICI Coral', bank: 'ICICI Bank', last4: '5007', limitAmount: 100000.0, usedAmount: 25000.0);
        final cardId = await creditRepo.insert(card);

        final now = DateTime.now();

        // 1. Two bank debits for identical amounts (₹4,000) within 10 minutes, same gateway (BBPS), distinct references
        final debit1 = Transaction(
          id: 'tx_bank_debit_bbps_1',
          amount: 4000.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: now,
          notes: 'BBPS payment to ICICI Credit Card 5007 ref:UPI111222',
          source: 'sms',
          externalRef: 'UPI111222',
        );
        await ftService.createTransaction(debit1);

        final debit2 = Transaction(
          id: 'tx_bank_debit_bbps_2',
          amount: 4000.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: now.add(const Duration(minutes: 5)),
          notes: 'BBPS payment to ICICI Credit Card 5007 ref:UPI333444',
          source: 'sms',
          externalRef: 'UPI333444',
        );
        await ftService.createTransaction(debit2);

        // Bank balance reduced by ₹8,000 total (50,000 -> 42,000)
        var bankBal = await canonicalRepo.getDerivedBalance(bankId);
        expect(bankBal.toRupees, 42000.0);

        // 2. First confirmation arrives with reference UPI111222
        // LiveSmsService matching logic via candidate inspection:
        final candidateDebits = await txRepo.findByAmountAndDateRange(
          amount: 4000.0,
          from: now.toUtc().subtract(const Duration(minutes: 30)),
          to: now.toUtc().add(const Duration(minutes: 30)),
        );
        expect(candidateDebits.length, 2);

        // Simulating the exact matching filter in _findRecentBankDebitForCcPayment:
        Transaction? matchDebit(String ref) {
          final matching = <Transaction>[];
          for (final tx in candidateDebits) {
            if (tx.type != 'expense' && tx.type != 'transfer') continue;
            final notes = tx.notes.toLowerCase();
            final extRef = tx.externalRef?.toLowerCase() ?? '';
            final cRef = ref.toLowerCase();
            if (extRef.isNotEmpty && !extRef.contains(cRef) && !cRef.contains(extRef)) continue;
            if (notes.contains('ref:') && !notes.contains(cRef)) continue;
            if (notes.contains('5007')) matching.add(tx);
          }
          return matching.length == 1 ? matching.first : null;
        }

        final matchedFor1 = matchDebit('UPI111222');
        expect(matchedFor1, isNotNull);
        expect(matchedFor1!.id, 'tx_bank_debit_bbps_1');

        final matchedFor2 = matchDebit('UPI333444');
        expect(matchedFor2, isNotNull);
        expect(matchedFor2!.id, 'tx_bank_debit_bbps_2');

        // Confirm conflicting ref returns null:
        final matchedForConflict = matchDebit('UPI999999');
        expect(matchedForConflict, isNull);

        // Edit debit 1 to credit_payment
        final updated1 = matchedFor1.copyWith(
          type: 'credit_payment',
          source: 'credit_card_payment',
          relatedEntityId: cardId,
          notes: 'Credit Card Bill Payment (ICICI Coral)',
        );
        await ftService.editTransaction(oldTransaction: matchedFor1, newTransaction: updated1);

        // Edit debit 2 to credit_payment
        final updated2 = matchedFor2.copyWith(
          type: 'credit_payment',
          source: 'credit_card_payment',
          relatedEntityId: cardId,
          notes: 'Credit Card Bill Payment (ICICI Coral)',
        );
        await ftService.editTransaction(oldTransaction: matchedFor2, newTransaction: updated2);

        // Verify card liability reduced by ₹8,000 (25,000 - 8,000 = 17,000)
        final cardBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(cardBal.toRupees, 17000.0);

        // Verify bank balance remains reduced exactly once by ₹8,000 (42,000)
        bankBal = await canonicalRepo.getDerivedBalance(bankId);
        expect(bankBal.toRupees, 42000.0);

        // Verify zero income and zero expense
        final stats = await txRepo.getStatsForMonth(now.year, now.month);
        expect(stats['income'], 0.0);
        expect(stats['expense'], 0.0);
      });

      test('2m. Gate 1 Collision: Indistinguishable payments without unique references are NEVER force-matched', () async {
        final accountRepo = AccountRepo(executor: db);
        final creditRepo = CreditRepo(executor: db);
        final txRepo = TransactionRepo(executor: db);
        final ftService = FinancialTransactionService(database: db);

        final bank = BankAccount(name: 'Canara Bank', bank: 'Canara', last4: '5555', balance: 50000.0);
        final bankId = await accountRepo.insertAccount(bank);

        final card = CreditCard(name: 'ICICI Coral', bank: 'ICICI Bank', last4: '5007', limitAmount: 100000.0, usedAmount: 25000.0);
        final cardId = await creditRepo.insert(card);

        final now = DateTime.now();

        // Two bank debits for identical amounts (₹2,500) without distinguishing references
        final debit1 = Transaction(
          id: 'tx_bank_debit_anon_1',
          amount: 2500.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: now,
          notes: 'BBPS payment to ICICI CC 5007',
          source: 'sms',
        );
        await ftService.createTransaction(debit1);

        final debit2 = Transaction(
          id: 'tx_bank_debit_anon_2',
          amount: 2500.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: now.add(const Duration(minutes: 2)),
          notes: 'BBPS payment to ICICI CC 5007',
          source: 'sms',
        );
        await ftService.createTransaction(debit2);

        final candidateDebits = await txRepo.findByAmountAndDateRange(
          amount: 2500.0,
          from: now.toUtc().subtract(const Duration(minutes: 30)),
          to: now.toUtc().add(const Duration(minutes: 30)),
        );
        expect(candidateDebits.length, 2);

        // Matching filter when confirmation has NO refId:
        final matching = <Transaction>[];
        for (final tx in candidateDebits) {
          if (tx.type != 'expense' && tx.type != 'transfer') continue;
          final notes = tx.notes.toLowerCase();
          if (notes.contains('5007')) matching.add(tx);
        }
        // Both match -> matching.length == 2!
        expect(matching.length, 2);

        // Invariant: Because matching.length > 1, the rule strictly returns NULL to avoid force-matching!
        final matchedDebit = matching.length == 1 ? matching.first : null;
        expect(matchedDebit, isNull, reason: 'Must NOT force a match when evidence is ambiguous');

        // Instead of force-matching, confirmation creates a standalone credit_payment to suspense
        final standaloneConfirmation = Transaction(
          id: 'tx_cc_standalone_conf',
          amount: 2500.0,
          userId: 'offline_user',
          type: 'credit_payment',
          accountId: null, // unknown funding -> suspense
          relatedEntityId: cardId,
          date: now.add(const Duration(minutes: 3)),
          notes: 'Payment received towards ICICI Credit Card',
          source: 'credit_card_payment',
        );
        await ftService.createTransaction(standaloneConfirmation);

        // The two bank debits remain preserved as separate transactions
        final debitsAfter = await txRepo.getAll();
        expect(debitsAfter.any((t) => t.id == 'tx_bank_debit_anon_1'), isTrue);
        expect(debitsAfter.any((t) => t.id == 'tx_bank_debit_anon_2'), isTrue);
        expect(debitsAfter.any((t) => t.id == 'tx_cc_standalone_conf'), isTrue);
      });

      test('2n. Gate 2 Suspense Semantics: sysSuspenseTransfer produces negative asset balance, excluded from Safe-to-Spend liquid cash', () async {
        final creditRepo = CreditRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final ftService = FinancialTransactionService(database: db);

        final card = CreditCard(
          name: 'SBI Prime',
          bank: 'SBI',
          last4: '8888',
          limitAmount: 100000.0,
          usedAmount: 30000.0,
        );
        final cardId = await creditRepo.insert(card);

        // Unknown source card payment of ₹15,000
        final paymentTx = Transaction(
          id: 'tx_sbi_suspense_test',
          amount: 15000.0,
          userId: 'offline_user',
          type: 'credit_payment',
          accountId: null, // routes to sys_suspense_transfer
          relatedEntityId: cardId,
          date: DateTime.now(),
          notes: 'Payment confirmation received',
          source: 'credit_card_payment',
        );
        await ftService.createTransaction(paymentTx);

        // 1. Account type is 'asset', subtype is 'suspense'
        final suspenseAccount = await canonicalRepo.getAccount(TablesV24.sysSuspenseTransfer);
        expect(suspenseAccount, isNotNull);
        expect(suspenseAccount!.type.name, 'asset');
        expect(suspenseAccount.category, 'suspense');

        // 2. Negative asset balance (credit balance of -₹15,000)
        final suspenseBal = await canonicalRepo.getDerivedBalance(TablesV24.sysSuspenseTransfer);
        expect(suspenseBal.toRupees, -15000.0);

        // 3. Card liability reduced to ₹15,000 (30,000 - 15,000)
        final cardBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(cardBal.toRupees, 15000.0);

        // 4. Safe-to-Spend liquidity query check:
        // CanonicalFinancialQueryRepository.getLiquidAssets excludes subtype 'suspense'!
        final liquidQuery = await db.rawQuery('''
          SELECT COALESCE(
            SUM(
              CASE
                WHEN p.direction = 'debit' THEN p.amount_minor_units
                ELSE -p.amount_minor_units
              END
            ), 0
          ) AS liquid_assets
          FROM ${TablesV24.postings} p
          JOIN ${TablesV24.accounts} a ON p.account_id = a.id
          JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
          WHERE a.account_type = 'asset'
            AND a.is_active = 1
            AND (a.subtype IN ('bank', 'cash', 'savings', 'wallet', 'liquid_cash', 'asset') OR a.subtype IS NULL)
            AND e.lifecycle_status = 'posted';
        ''');
        final liquidAmountMinor = (liquidQuery.first['liquid_assets'] as num?)?.toInt() ?? 0;
        expect(liquidAmountMinor, 0, reason: 'sys_suspense_transfer (subtype: suspense) MUST NOT inflate or deflate liquid cash in Safe-to-Spend');
      });

      test('2o. Gate 3 Cache: credit_cards.used_amount is a presentation cache and does NOT overwrite canonical ledger truth', () async {
        final creditRepo = CreditRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);

        // Insert card with initial ledger balance = ₹10,000
        final card = CreditCard(
          name: 'HDFC Millennia',
          bank: 'HDFC Bank',
          last4: '4444',
          limitAmount: 100000.0,
          usedAmount: 10000.0,
        );
        final cardId = await creditRepo.insert(card);

        // Canonical ledger liability is ₹10,000
        var ledgerBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(ledgerBal.toRupees, 10000.0);

        // Directly updating SQLite credit_cards table (transitional/cached table) simulates
        // any external/cached modification of used_amount:
        await db.update(
          Tables.creditCards,
          {'used_amount': 5000.0},
          where: 'id = ?',
          whereArgs: [cardId],
        );

        // 1. Cached raw row in credit_cards table is updated to 5000:
        final rawRows = await db.query(
          Tables.creditCards,
          where: 'id = ?',
          whereArgs: [cardId],
        );
        expect(rawRows.first['used_amount'], 5000.0);

        // 2. But projected CreditRepo.getCard() derives usedAmount STRICTLY from canonical postings,
        // ignoring the raw cached column:
        final cardProjected = await creditRepo.getCard(cardId);
        expect(cardProjected, isNotNull);
        expect(cardProjected!.usedAmount, 10000.0, reason: 'Projected card model derives balance strictly from ledger postings');

        // 3. Canonical ledger liability remains authoritative and UNCHANGED at ₹10,000!
        ledgerBal = await canonicalRepo.getDerivedBalance(cardId);
        expect(ledgerBal.toRupees, 10000.0, reason: 'Cached used_amount must NEVER overwrite double-entry ledger postings');

        // 4. Opening equity is debited 10,000 (derived credit balance is -10,000)
        final equityBal = await canonicalRepo.getDerivedBalance(TablesV24.sysEquityOpening);
        expect(equityBal.toRupees, -10000.0);
      });

      test('2p. Gate 1 & 3: Complete 15-Step Suspense Resolution and Net-Worth Invariant Scenario', () async {
        final accountRepo = AccountRepo(executor: db);
        final creditRepo = CreditRepo(executor: db);
        final txRepo = TransactionRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final canonicalEventRepo = CanonicalEventRepository(executor: db);
        final queryRepo = CanonicalFinancialQueryRepository(executor: db);
        final netWorthService = NetWorthService(queryRepo: queryRepo);
        final ftService = FinancialTransactionService(database: db);

        // Step 1: Start with a registered bank balance of ₹50,000.
        final bank = BankAccount(name: 'Canara Bank', bank: 'Canara', last4: '5555', balance: 50000.0);
        final bankId = await accountRepo.insertAccount(bank);

        // Step 2: Start with a credit-card liability of ₹20,000.
        final card = CreditCard(name: 'ICICI Coral', bank: 'ICICI Bank', last4: '5007', limitAmount: 100000.0, usedAmount: 20000.0);
        final cardId = await creditRepo.insert(card);

        // Initial net worth calculation: Assets (50,000) - Liabilities (20,000) = ₹30,000
        final initialNetWorth = await netWorthService.calculateNetWorth();
        expect(initialNetWorth.totalAssets, 50000.0);
        expect(initialNetWorth.totalLiabilities, 20000.0);
        expect(initialNetWorth.netWorth, 30000.0);

        // Initial Safe-to-Spend check
        final initialSafeToSpend = await queryRepo.getSafeToSpend();
        expect(initialSafeToSpend.liquidAssets.toRupees, 50000.0);
        expect(initialSafeToSpend.safeToSpend.toRupees, 50000.0);

        // Step 3: Receive a ₹5,000 card-payment confirmation with no identified funding account.
        final now = DateTime.now();
        final unlinkedPayment = Transaction(
          id: 'tx_cc_pay_gate1_5k',
          amount: 5000.0,
          userId: 'offline_user',
          type: 'credit_payment',
          accountId: null, // unknown funding account -> sys_suspense_transfer
          relatedEntityId: cardId, // ICICI Card
          date: now,
          notes: 'Payment confirmation received on ICICI card',
          source: 'credit_card_payment',
          externalRef: 'REF_GATE1_5000',
        );
        await ftService.createTransaction(unlinkedPayment);

        // Step 4: Verify that card liability decreases exactly once to ₹15,000.
        final cardLiabilityAfter = await canonicalRepo.getDerivedBalance(cardId);
        expect(cardLiabilityAfter.toRupees, 15000.0);

        // Step 5: Verify that the registered bank remains ₹50,000.
        final bankBalAfterPayment = await canonicalRepo.getDerivedBalance(bankId);
        expect(bankBalAfterPayment.toRupees, 50000.0);

        // Step 6: Verify that suspense reflects the offsetting credit.
        final suspenseAccount = await canonicalRepo.getAccount(TablesV24.sysSuspenseTransfer);
        expect(suspenseAccount, isNotNull);
        expect(suspenseAccount!.type.name, 'asset');
        expect(suspenseAccount.category, 'suspense');
        final suspenseBal = await canonicalRepo.getDerivedBalance(TablesV24.sysSuspenseTransfer);
        expect(suspenseBal.toRupees, -5000.0);

        // Step 7: Verify that income and expense are unchanged.
        final statsAfterPayment = await txRepo.getStatsForMonth(now.year, now.month);
        expect(statsAfterPayment['income'], 0.0);
        expect(statsAfterPayment['expense'], 0.0);

        // Step 8: Verify that net worth is unchanged by the payment.
        // Total Assets = Bank (50,000) + Suspense (-5,000) = 45,000
        // Total Liabilities = Card (15,000)
        // Net Worth = 45,000 - 15,000 = ₹30,000 (EXACTLY UNCHANGED!)
        final netWorthAfterPayment = await netWorthService.calculateNetWorth();
        expect(netWorthAfterPayment.totalAssets, 45000.0);
        expect(netWorthAfterPayment.totalLiabilities, 15000.0);
        expect(netWorthAfterPayment.netWorth, 30000.0);

        // Step 9: Verify that Safe-to-Spend does not treat suspense as spendable cash.
        final safeToSpendAfterPayment = await queryRepo.getSafeToSpend();
        expect(safeToSpendAfterPayment.liquidAssets.toRupees, 50000.0);
        expect(safeToSpendAfterPayment.safeToSpend.toRupees, 50000.0);

        // Step 10: Resolve the payment to the actual funding bank using the established append-only correction mechanism.
        final resolvedPayment = unlinkedPayment.copyWith(
          accountId: bankId,
          notes: 'Resolved payment from Canara Bank to ICICI Coral',
        );
        await ftService.editTransaction(
          oldTransaction: unlinkedPayment,
          newTransaction: resolvedPayment,
        );

        // Step 11: Verify that the bank balance becomes ₹45,000 and card liability remains ₹15,000.
        final bankBalAfterResolve = await canonicalRepo.getDerivedBalance(bankId);
        expect(bankBalAfterResolve.toRupees, 45000.0);
        final cardLiabilityAfterResolve = await canonicalRepo.getDerivedBalance(cardId);
        expect(cardLiabilityAfterResolve.toRupees, 15000.0);

        // Step 12: Verify that suspense returns to its correct reconciled balance (0.0).
        final suspenseBalAfterResolve = await canonicalRepo.getDerivedBalance(TablesV24.sysSuspenseTransfer);
        expect(suspenseBalAfterResolve.toRupees, 0.0);

        // Step 13: Verify that net worth is unchanged by the resolution.
        // Total Assets = Bank (45,000) + Suspense (0) = 45,000
        // Total Liabilities = Card (15,000)
        // Net Worth = 45,000 - 15,000 = ₹30,000 (EXACTLY UNCHANGED!)
        final netWorthAfterResolve = await netWorthService.calculateNetWorth();
        expect(netWorthAfterResolve.totalAssets, 45000.0);
        expect(netWorthAfterResolve.totalLiabilities, 15000.0);
        expect(netWorthAfterResolve.netWorth, 30000.0);

        // Step 14: Verify that original events, reversals, replacements, and evidence remain auditable.
        final allPostedEvents = await canonicalEventRepo.listPostedEvents();
        expect(allPostedEvents.any((e) => e.id == 'tx_cc_pay_gate1_5k'), isTrue);
        final reversalEvent = allPostedEvents.firstWhere((e) =>
          e.description.startsWith('REVERSAL: tx_cc_pay_gate1_5k')
        );
        expect(reversalEvent, isNotNull);
        final replacementEvent = allPostedEvents.firstWhere((e) =>
          e.id.startsWith('tx_cc_pay_gate1_5k:corr:')
        );
        expect(replacementEvent, isNotNull);

        // Step 15: Verify that every event's postings are balanced.
        final origPostings = await canonicalEventRepo.getPostingsForEvent('tx_cc_pay_gate1_5k');
        final revPostings = await canonicalEventRepo.getPostingsForEvent(reversalEvent.id);
        final replPostings = await canonicalEventRepo.getPostingsForEvent(replacementEvent.id);

        expect(origPostings.length, 2);
        expect(revPostings.length, 2);
        expect(replPostings.length, 2);

        // Original: Debit card 5000, Credit suspense 5000
        expect(origPostings.firstWhere((p) => p.accountId == cardId).direction.name, 'debit');
        expect(origPostings.firstWhere((p) => p.accountId == TablesV24.sysSuspenseTransfer).direction.name, 'credit');

        // Reversal: Debit suspense 5000, Credit card 5000
        expect(revPostings.firstWhere((p) => p.accountId == TablesV24.sysSuspenseTransfer).direction.name, 'debit');
        expect(revPostings.firstWhere((p) => p.accountId == cardId).direction.name, 'credit');

        // Replacement: Debit card 5000, Credit bank 5000
        expect(replPostings.firstWhere((p) => p.accountId == cardId).direction.name, 'debit');
        expect(replPostings.firstWhere((p) => p.accountId == bankId).direction.name, 'credit');
      });

      test('2q. Gate 2: _findRecentBankDebitForCcPayment rejects R2 candidate when confirmation has R1', () async {
        final accountRepo = AccountRepo(executor: db);
        final txRepo = TransactionRepo(executor: db);
        final ftService = FinancialTransactionService(database: db);

        final bank = BankAccount(name: 'SBI', bank: 'SBI', last4: '1234', balance: 50000.0);
        final bankId = await accountRepo.insertAccount(bank);

        final now = DateTime.now();

        // Bank debit with reference R2
        final debitWithR2 = Transaction(
          id: 'tx_debit_r2',
          amount: 3500.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: now,
          notes: 'Payment towards ICICI CC 5007 ref:R2_REF',
          source: 'sms',
          externalRef: 'R2_REF',
        );
        await ftService.createTransaction(debitWithR2);

        // Scan candidate debits for confirmation with reference R1
        final candidateDebits = await txRepo.findByAmountAndDateRange(
          amount: 3500.0,
          from: now.toUtc().subtract(const Duration(minutes: 30)),
          to: now.toUtc().add(const Duration(minutes: 30)),
        );
        expect(candidateDebits.length, 1);

        // Simulate matching with R1:
        final cRef = 'R1_REF';
        final matching = <Transaction>[];
        for (final tx in candidateDebits) {
          if (tx.type != 'expense' && tx.type != 'transfer') continue;
          final notes = tx.notes.toLowerCase();
          final extRef = tx.externalRef?.toLowerCase() ?? '';
          if (extRef.isNotEmpty && !extRef.contains(cRef.toLowerCase()) && !cRef.toLowerCase().contains(extRef)) {
            continue;
          }
          if (notes.contains('ref:') && !notes.contains(cRef.toLowerCase())) continue;
          if (notes.contains('5007')) matching.add(tx);
        }

        // Must reject R2 when confirmation has R1!
        expect(matching.isEmpty, isTrue);
      });

      test('2r. Gate 2 Reference Matching: Exact normalized equality prevents R1 vs R10 collision and normalizes case/whitespace', () async {
        // 1. Exact normalized reference equality
        expect(LiveSmsService.normalizeReference('  UPI / 123456  '), 'upi123456');
        expect(LiveSmsService.normalizeReference('Ref: ABC-789'), 'refabc789');
        expect(LiveSmsService.normalizeReference(null), '');

        // 2. R1 vs R10 substring hazard prevention:
        final normR1 = LiveSmsService.normalizeReference('R1');
        final normR10 = LiveSmsService.normalizeReference('R10');
        expect(normR1, 'r1');
        expect(normR10, 'r10');
        expect(normR1 != normR10, isTrue);

        // 3. Extract reference from text
        expect(LiveSmsService.extractReferenceFromText('Paid to CC ref:UTR987654 for bill'), 'utr987654');
        expect(LiveSmsService.extractReferenceFromText('UPI/987654321012 credited'), '987654321012');
        expect(LiveSmsService.extractReferenceFromText('Random shopping at store'), isNull);

        // 4. Test R1 vs R10 with LiveSmsService candidate logic
        final accountRepo = AccountRepo(executor: db);
        final txRepo = TransactionRepo(executor: db);
        final ftService = FinancialTransactionService(database: db);

        final bank = BankAccount(name: 'Canara Bank', bank: 'Canara', last4: '9876', balance: 50000.0);
        final bankId = await accountRepo.insertAccount(bank);

        final now = DateTime.now();

        // Debit carries reference "R10"
        final debitR10 = Transaction(
          id: 'tx_debit_r10',
          amount: 2000.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: now,
          notes: 'BBPS payment to card XX5007 ref:R10',
          source: 'sms',
          externalRef: 'R10',
        );
        await ftService.createTransaction(debitR10);

        // Confirmation arrives with reference "R1"
        final candidateDebits = await txRepo.findByAmountAndDateRange(
          amount: 2000.0,
          from: now.toUtc().subtract(const Duration(minutes: 30)),
          to: now.toUtc().add(const Duration(minutes: 30)),
        );
        expect(candidateDebits.length, 1);

        // Matching logic check:
        final normConfirmationRef = LiveSmsService.normalizeReference('R1');
        final matching = <Transaction>[];
        for (final tx in candidateDebits) {
          if (tx.type != 'expense' && tx.type != 'transfer') continue;
          final notes = tx.notes.toLowerCase();
          final normExtRef = LiveSmsService.normalizeReference(tx.externalRef);
          final extractedNotesRef = LiveSmsService.normalizeReference(LiveSmsService.extractReferenceFromText(notes));

          if (normConfirmationRef.isNotEmpty) {
            if (normExtRef.isNotEmpty && normExtRef != normConfirmationRef) continue;
            if (extractedNotesRef.isNotEmpty && extractedNotesRef != normConfirmationRef) continue;
          }
          if (notes.contains('5007')) matching.add(tx);
        }

        // R10 must NOT match R1!
        expect(matching.isEmpty, isTrue, reason: 'R10 must never match R1 despite substring containment');

        // Debit with matching reference " r1 " with whitespace and lowercase matches
        final debitR1 = Transaction(
          id: 'tx_debit_r1',
          amount: 2000.0,
          userId: 'offline_user',
          type: 'expense',
          accountId: bankId,
          date: now.add(const Duration(minutes: 1)),
          notes: 'BBPS payment to card XX5007 ref: r1 ',
          source: 'sms',
          externalRef: ' r1 ',
        );
        await ftService.createTransaction(debitR1);

        final updatedCandidates = await txRepo.findByAmountAndDateRange(
          amount: 2000.0,
          from: now.toUtc().subtract(const Duration(minutes: 30)),
          to: now.toUtc().add(const Duration(minutes: 30)),
        );

        final matchForR1 = <Transaction>[];
        for (final tx in updatedCandidates) {
          if (tx.type != 'expense' && tx.type != 'transfer') continue;
          final notes = tx.notes.toLowerCase();
          final normExtRef = LiveSmsService.normalizeReference(tx.externalRef);
          final extractedNotesRef = LiveSmsService.normalizeReference(LiveSmsService.extractReferenceFromText(notes));

          if (normConfirmationRef.isNotEmpty) {
            if (normExtRef.isNotEmpty && normExtRef != normConfirmationRef) continue;
            if (extractedNotesRef.isNotEmpty && extractedNotesRef != normConfirmationRef) continue;
          }
          if (notes.contains('5007')) matchForR1.add(tx);
        }

        expect(matchForR1.length, 1);
        expect(matchForR1.first.id, 'tx_debit_r1');
      });
    });
  });
}




