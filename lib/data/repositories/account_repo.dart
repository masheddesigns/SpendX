import 'package:sqflite/sqflite.dart' show DatabaseExecutor;

import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class AccountRepo {
  final db = AppDatabase.instance;

  Future<void> create(BankAccount account) async {
    await insertAccount(account);
  }

  Future<List<BankAccount>> getAll() async {
    return getAccounts();
  }

  Future<List<BankAccount>> getAccounts() async {
    final database = await db.database;
    final res = await database.query(Tables.bankAccounts);

    return res.map((e) => BankAccount.fromMap(e)).toList();
  }

  Future<BankAccount?> getById(String? id) async {
    if (id == null || id.isEmpty) return null;

    final database = await db.database;
    final results = await database.query(
      Tables.bankAccounts,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (results.isEmpty) return null;
    return BankAccount.fromMap(results.first);
  }

  Future<String> insertAccount(BankAccount account) async {
    final database = await db.database;
    await database.insert(Tables.bankAccounts, account.toMap());
    return account.id;
  }

  Future<int> updateAccount(BankAccount account) async {
    final database = await db.database;
    return await database.update(
      Tables.bankAccounts,
      account.toMap(),
      where: 'id = ?',
      whereArgs: [account.id],
    );
  }

  Future<void> updateBalance(String id, double balance) async {
    final database = await db.database;
    await database.update(
      Tables.bankAccounts,
      {
        'balance': balance,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Atomically adjust balance by a delta amount using SQL arithmetic.
  /// Positive delta = increase, negative delta = decrease.
  Future<void> adjustBalance(String id, double delta) async {
    if (delta == 0) return;
    final database = await db.database;
    await database.rawUpdate(
      'UPDATE ${Tables.bankAccounts} SET balance = balance + ?, updated_at = ? WHERE id = ?',
      [delta, DateTime.now().toIso8601String(), id],
    );
  }

  /// Batch-adjust balances for multiple accounts in a single transaction.
  Future<void> adjustBalances(Map<String, double> deltas) async {
    if (deltas.isEmpty) return;
    final database = await db.database;
    await adjustBalancesWithTxn(database, deltas);
  }

  /// Batch-adjust within an existing [DatabaseExecutor] (DB transaction).
  Future<void> adjustBalancesWithTxn(
    DatabaseExecutor txn,
    Map<String, double> deltas,
  ) async {
    if (deltas.isEmpty) return;
    final batch = txn.batch();
    final now = DateTime.now().toIso8601String();
    for (final entry in deltas.entries) {
      if (entry.value == 0) continue;
      batch.rawUpdate(
        'UPDATE ${Tables.bankAccounts} SET balance = balance + ?, updated_at = ? WHERE id = ?',
        [entry.value, now, entry.key],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<int> deleteAccount(String id) async {
    final database = await db.database;
    return await database.delete(
      Tables.bankAccounts,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<CreditCard>> getCards() async {
    final database = await db.database;
    final res = await database.query(Tables.creditCards);

    return res.map((e) => CreditCard.fromMap(e)).toList();
  }

  Future<String> insertCard(CreditCard card) async {
    final database = await db.database;
    await database.insert(Tables.creditCards, card.toMap());
    return card.id;
  }

  Future<int> updateCard(CreditCard card) async {
    final database = await db.database;
    return await database.update(
      Tables.creditCards,
      card.toMap(),
      where: 'id = ?',
      whereArgs: [card.id],
    );
  }

  Future<int> deleteCard(String id) async {
    final database = await db.database;
    return await database.delete(
      Tables.creditCards,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Convert a bank account to a credit card.
  /// Deletes the account and creates a credit card with the same bank/name.
  /// Returns the new CreditCard id.
  Future<String> convertAccountToCard(BankAccount account) async {
    final card = CreditCard(
      name: account.name,
      bank: account.bank,
      limitAmount: 0,
      usedAmount: account.balance.abs(),
    );
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete(
        Tables.bankAccounts,
        where: 'id = ?',
        whereArgs: [account.id],
      );
      await txn.insert(Tables.creditCards, card.toMap());
    });
    return card.id;
  }

  /// Convert a credit card to a bank account.
  /// Deletes the card and creates a bank account with the same bank/name.
  /// Returns the new BankAccount id.
  Future<String> convertCardToAccount(CreditCard card) async {
    final account = BankAccount(
      name: card.name,
      bank: card.bank,
      balance: 0,
      accountType: 'savings',
    );
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete(
        Tables.creditCards,
        where: 'id = ?',
        whereArgs: [card.id],
      );
      await txn.insert(Tables.bankAccounts, account.toMap());
    });
    return account.id;
  }
}
