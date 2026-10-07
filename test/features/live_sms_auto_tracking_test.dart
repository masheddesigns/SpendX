import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/features/merchant_rules/data/merchant_rule_repo.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/smart_category_classifier.dart';
import 'package:spend_x/core/utils/category_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/core/utils/category_classifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Live SMS Auto-Tracking & Technical Verification', () {
    late Database db;

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

      // Seed categories
      await CategoryRepo(executor: db).ensureDefaults();
    });

    tearDown(() async {
      await db.close();
    });

    group('1. Category Resolution Priority', () {
      test('1a. Learns merchant memory and subsequent lookups use learned category', () async {
        // Learn that "Cafe Coffee Day" is "Food"
        await SmartCategoryClassifier.instance.learn(
          rawText: 'Spent at Cafe Coffee Day',
          merchant: 'Cafe Coffee Day',
          category: 'Food',
        );

        final resolution = await resolveCategoryForText(
          rawText: 'Spent Rs 250 at Cafe Coffee Day with card 1234',
          merchant: 'Cafe Coffee Day',
          type: 'expense',
          executor: db,
        );

        expect(resolution.name, 'Food');
        expect(resolution.id, isNotNull);
      });

      test('1b. MerchantRuleRepo keyword match takes precedence when classifier misses', () async {
        final catRepo = CategoryRepo(executor: db);
        final transportCat = await catRepo.getByName('Transport', type: 'expense');
        expect(transportCat, isNotNull);

        // Upsert merchant rule for keyword "metro"
        await MerchantRuleRepo(executor: db).upsert(
          'metro',
          transportCat!.id,
        );

        final resolution = await resolveCategoryForText(
          rawText: 'Paid Rs 40 at Metro Rail Station',
          merchant: 'Metro Rail',
          type: 'expense',
          executor: db,
        );

        expect(resolution.name, 'Transport');
        expect(resolution.id, transportCat.id);
      });

      test('1c. Deterministic keyword matching classifies Fuel and Food', () {
        expect(
          CategoryClassifier.detect(text: 'HPCL Fuel Station', type: 'expense'),
          'Transport',
        );
        expect(
          CategoryClassifier.detect(text: 'Swiggy order #1234', type: 'expense'),
          'Food',
        );
      });

      test('1d. Unrecognized merchant falls back to Miscellaneous category', () async {
        final resolution = await resolveCategoryForText(
          rawText: 'Paid Rs 999 to XYZQWERTYUKLM',
          merchant: 'XYZQWERTYUKLM',
          type: 'expense',
          executor: db,
        );

        expect(resolution.name, 'Miscellaneous');
        expect(resolution.id, isNotNull);
      });
    });

    group('2. Financial Ledger & Safe Unknown Instrument Handling', () {
      test('2a. Unknown instrument (no card/wallet/bank match) leaves accountId null and uses suspense', () async {
        final tx = Transaction(
          id: 'tx_unknown_inst',
          userId: 'offline_user',
          type: 'expense',
          amount: 500,
          categoryId: TablesV24.sysExpMisc,
          accountId: null, // Unknown instrument
          date: DateTime.now(),
          notes: 'Ambiguous merchant payment',
          source: 'sms',
        );

        final ftService = FinancialTransactionService(database: db);
        await ftService.createTransaction(tx);

        final txRepo = TransactionRepo(executor: db);
        final txns = await txRepo.getAll();
        expect(txns.any((t) => t.id == 'tx_unknown_inst'), isTrue);

        // Verify that no registered bank accounts were created or modified
        final accRepo = AccountRepo(executor: db);
        final accounts = await accRepo.getAll();
        expect(accounts.isEmpty, isTrue);
      });

      test('2b. Bank transaction with resolved account posts and modifies derived balance', () async {
        final accRepo = AccountRepo(executor: db);
        final bankAcc = BankAccount(
          id: 'acc_hdfc_1234',
          name: 'HDFC Bank',
          bank: 'HDFC',
          last4: '1234',
          accountType: 'savings',
          balance: 10000,
        );
        await accRepo.insertAccount(bankAcc);

        final tx = Transaction(
          id: 'tx_bank_debit',
          userId: 'offline_user',
          type: 'expense',
          amount: 1500,
          categoryId: TablesV24.sysExpMisc,
          accountId: 'acc_hdfc_1234',
          date: DateTime.now(),
          notes: 'Grocery store debit',
          source: 'sms',
        );

        final ftService = FinancialTransactionService(database: db);
        await ftService.createTransaction(tx);

        // Verify derived balance reduced by 1500
        final canonicalAccRepo = CanonicalAccountRepository(executor: db);
        final derived = await canonicalAccRepo.getDerivedBalance('acc_hdfc_1234');
        expect(derived.toRupees, 8500.0);
      });

      test('2c. Credit card purchase routes to card liability and increases card balance', () async {
        final creditRepo = CreditRepo(executor: db);
        final card = CreditCard(
          id: 'card_sbi_5678',
          name: 'SBI SimplyClick',
          bank: 'SBI',
          last4: '5678',
          limitAmount: 50000,
          usedAmount: 0,
        );
        await creditRepo.insert(card);

        final tx = Transaction(
          id: 'tx_cc_purchase',
          userId: 'offline_user',
          type: 'expense',
          amount: 3200,
          categoryId: TablesV24.sysExpMisc,
          accountId: 'card_sbi_5678',
          date: DateTime.now(),
          notes: 'Amazon purchase via Credit Card',
          source: 'credit_card_purchase',
        );

        final ftService = FinancialTransactionService(database: db);
        await ftService.createTransaction(tx);

        // Verify credit card used amount increased by 3200
        final cards = await creditRepo.getAll();
        final updatedCard = cards.where((c) => c.id == 'card_sbi_5678').firstOrNull;
        expect(updatedCard, isNotNull);
        expect(updatedCard!.usedAmount, 3200.0);
      });

      test('2d. Deduplication prevents inserting duplicate transaction with same externalRef', () async {
        final txRepo = TransactionRepo(executor: db);
        final tx1 = Transaction(
          id: 'tx_dedup_1',
          userId: 'offline_user',
          type: 'expense',
          amount: 450,
          externalRef: 'UPI_REF_12345678',
          date: DateTime.now(),
          notes: 'Tea stall',
        );

        await txRepo.insert(tx1);

        final exists = await txRepo.existsByExternalRef('UPI_REF_12345678');
        expect(exists, isTrue);

        // Second insert with same externalRef is skipped
        await txRepo.insertAll([
          Transaction(
            id: 'tx_dedup_2',
            userId: 'offline_user',
            type: 'expense',
            amount: 450,
            externalRef: 'UPI_REF_12345678',
            date: DateTime.now(),
            notes: 'Tea stall duplicate',
          ),
        ]);
        final all = await txRepo.getAll();
        expect(all.where((t) => t.externalRef == 'UPI_REF_12345678').length, 1);
      });
    });
  });
}
