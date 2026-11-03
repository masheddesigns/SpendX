import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';

/// Unit test testing the display name resolver function
String resolveAccountDisplayName(String rawName) {
  final trimmed = rawName.trim();
  if (trimmed == 'acc_bank_default' || trimmed == 'Asset acc_bank_default') {
    return 'Primary Operating Account';
  }
  final generatedKeyPattern = RegExp(r'^Asset acc_[a-zA-Z0-9_\-]+$');
  if (generatedKeyPattern.hasMatch(trimmed)) {
    final sub = trimmed.substring('Asset acc_'.length);
    if (sub.isNotEmpty) {
      return '${sub[0].toUpperCase()}${sub.substring(1)} Account';
    }
    return 'Operating Account';
  }
  return rawName;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Accounts Conversion and Identity Regression Suite', () {
    late Database db;
    late AccountRepo accountRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        onCreate: (db, version) async {
          await TablesV24.createAllV24(db);
          await TablesV24.installTriggers(db);
          await TablesV24.seedSystemAccounts(db);

          await db.execute('''
            CREATE TABLE ${Tables.bankAccounts} (
              id TEXT PRIMARY KEY,
              user_id TEXT NOT NULL,
              name TEXT NOT NULL,
              bank TEXT NOT NULL,
              account_type TEXT NOT NULL,
              balance REAL NOT NULL,
              color TEXT NOT NULL,
              icon TEXT NOT NULL,
              is_asset INTEGER NOT NULL,
              last4 TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE ${Tables.creditCards} (
              id TEXT PRIMARY KEY,
              user_id TEXT NOT NULL,
              name TEXT NOT NULL,
              bank TEXT NOT NULL,
              last4 TEXT,
              limit_amount REAL NOT NULL,
              billing_day INTEGER NOT NULL,
              due_day INTEGER NOT NULL,
              card_type TEXT NOT NULL,
              color TEXT NOT NULL,
              used_amount REAL NOT NULL,
              last_statement_balance REAL NOT NULL,
              created_at TEXT NOT NULL
            )
          ''');
        },
      );
      accountRepo = AccountRepo(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    test('1. Bank Account to Credit Card conversion preserves identity and deletes source', () async {
      final bank = BankAccount(
        id: 'test_bank_convert',
        name: 'Disposable Bank',
        bank: 'TestBank',
        accountType: 'savings',
        balance: 1500.0,
      );
      await accountRepo.insertAccount(bank);

      // Verify inserted
      final accountsBefore = await accountRepo.getAccounts();
      expect(accountsBefore.any((a) => a.id == 'test_bank_convert'), isTrue);

      // Execute conversion
      final newCardId = await accountRepo.convertAccountToCard(bank);
      expect(newCardId, isNotEmpty);

      // Verify bank account removed
      final accountsAfter = await accountRepo.getAccounts();
      expect(accountsAfter.any((a) => a.id == 'test_bank_convert'), isFalse);

      // Verify credit card created with converted attributes
      final cards = await accountRepo.getCards();
      final card = cards.firstWhere((c) => c.id == newCardId);
      expect(card.name, 'Disposable Bank');
      expect(card.bank, 'TestBank');
      expect(card.usedAmount, 1500.0);
    });

    test('2. Credit Card to Bank Account conversion preserves identity and deletes source', () async {
      final card = CreditCard(
        id: 'test_card_convert',
        name: 'Disposable Card',
        bank: 'TestBank',
        limitAmount: 50000.0,
        usedAmount: 12000.0,
      );
      await db.insert(Tables.creditCards, card.toMap());

      // Verify card exists
      final cardsBefore = await accountRepo.getCards();
      expect(cardsBefore.any((c) => c.id == 'test_card_convert'), isTrue);

      // Execute conversion
      final newAccountId = await accountRepo.convertCardToAccount(card);
      expect(newAccountId, isNotEmpty);

      // Verify credit card removed
      final cardsAfter = await accountRepo.getCards();
      expect(cardsAfter.any((c) => c.id == 'test_card_convert'), isFalse);

      // Verify bank account created
      final accounts = await accountRepo.getAccounts();
      final account = accounts.firstWhere((a) => a.id == newAccountId);
      expect(account.name, 'Disposable Card');
      expect(account.bank, 'TestBank');
      expect(account.accountType, 'savings');
    });

    test('3. Credit card utilization handles zero limits and unusual balances safely', () {
      // Zero limit card
      final zeroLimitCard = CreditCard(
        name: 'Zero Limit',
        bank: 'Bank',
        limitAmount: 0.0,
        usedAmount: 100.0,
      );
      expect(zeroLimitCard.utilizationPct, 0.0);
      expect(zeroLimitCard.availableLimit, 0.0);

      // Negative used amount (credit balance / overpayment)
      final overpaidCard = CreditCard(
        name: 'Overpaid',
        bank: 'Bank',
        limitAmount: 10000.0,
        usedAmount: -500.0,
      );
      expect(overpaidCard.utilizationPct, 0.0);
      expect(overpaidCard.availableLimit, 10500.0);

      // Overlimit card (used > limit)
      final overLimitCard = CreditCard(
        name: 'Overlimit',
        bank: 'Bank',
        limitAmount: 10000.0,
        usedAmount: 15000.0,
      );
      expect(overLimitCard.utilizationPct, 100.0); // Clamped to 100%
      expect(overLimitCard.availableLimit, 0.0); // Clamped to 0
    });

    test('4. Display name resolver strictly targets database artifacts and preserves user names', () {
      // Default auto-created identifiers
      expect(resolveAccountDisplayName('acc_bank_default'), 'Primary Operating Account');
      expect(resolveAccountDisplayName('Asset acc_bank_default'), 'Primary Operating Account');
      expect(resolveAccountDisplayName('Asset acc_hdfc_primary'), 'Hdfc_primary Account');

      // Genuine user-entered accounts that should NOT be modified
      expect(resolveAccountDisplayName('Asset Allocation'), 'Asset Allocation');
      expect(resolveAccountDisplayName('Asset Holding Account'), 'Asset Holding Account');
      expect(resolveAccountDisplayName('Assets & Cash'), 'Assets & Cash');
      expect(resolveAccountDisplayName('SBI Savings'), 'SBI Savings');
      expect(resolveAccountDisplayName('Axis Bank'), 'Axis Bank');
      expect(resolveAccountDisplayName('Cash Wallet'), 'Cash Wallet');
    });
  });
}
