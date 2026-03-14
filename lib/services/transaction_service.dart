import '../models/transaction.dart';
import 'database_helper.dart';
import 'cloud_backup_service.dart';

class TransactionService {
  // Private constructor
  TransactionService._();

  static final TransactionService instance = TransactionService._();

  /// Initialize the service (ensure DB is open)
  Future<void> init() async {
    await DatabaseHelper.instance.database;
  }

  /// Get all transactions
  Future<List<Transaction>> getTransactions({int? limit, int? offset}) async {
    return await DatabaseHelper.instance.getAllTransactions(limit: limit, offset: offset);
  }

  /// Save a new transaction
  Future<void> addTransaction(Transaction transaction) async {
    await DatabaseHelper.instance.insertTransaction(transaction);
  }

  /// Update an existing transaction
  Future<void> updateTransaction(Transaction transaction) async {
    final oldTxn = await DatabaseHelper.instance.getTransactionById(transaction.id);
    
    // Reverse old
    if (oldTxn != null && oldTxn.source == 'bank_account' && oldTxn.relatedEntityId != null) {
      final bank = await DatabaseHelper.instance.getBankAccountById(oldTxn.relatedEntityId!);
      if (bank != null) {
        final double reverseAdj = oldTxn.type == 'income' ? -oldTxn.amount : oldTxn.amount;
        await DatabaseHelper.instance.updateBankAccount(bank.copyWith(balance: bank.balance + reverseAdj));
      }
    }

    // Apply new
    await DatabaseHelper.instance.updateTransaction(transaction);
    if (transaction.source == 'bank_account' && transaction.relatedEntityId != null) {
      final bank = await DatabaseHelper.instance.getBankAccountById(transaction.relatedEntityId!);
      if (bank != null) {
        final double adjustment = transaction.type == 'income' ? transaction.amount : -transaction.amount;
        await DatabaseHelper.instance.updateBankAccount(bank.copyWith(balance: bank.balance + adjustment));
      }
    }
    CloudBackupService.instance.triggerAutoBackup();
  }

  /// Delete a transaction by id
  Future<void> deleteTransaction(String id) async {
    final oldTxn = await DatabaseHelper.instance.getTransactionById(id);
    if (oldTxn != null && oldTxn.source == 'bank_account' && oldTxn.relatedEntityId != null) {
      final bank = await DatabaseHelper.instance.getBankAccountById(oldTxn.relatedEntityId!);
      if (bank != null) {
        final double reverseAdj = oldTxn.type == 'income' ? -oldTxn.amount : oldTxn.amount;
        await DatabaseHelper.instance.updateBankAccount(bank.copyWith(balance: bank.balance + reverseAdj));
      }
    }
    await DatabaseHelper.instance.deleteTransaction(id);
  }

  /// Search transactions
  Future<List<Transaction>> searchTransactions({
    String? query,
    String? type,
    String? categoryId,
    String? startDate,
    String? endDate,
  }) async {
    return await DatabaseHelper.instance.searchTransactions(
      query: query,
      type: type,
      categoryId: categoryId,
      startDate: startDate,
    );
  }

  /// Get aggregated daily spending for a specific year
  Future<Map<DateTime, double>> getDailySpendingForYear(int year) async {
    final startOfYear = DateTime(year, 1, 1).toIso8601String();
    final endOfYear = DateTime(year, 12, 31, 23, 59, 59).toIso8601String();
    
    final txns = await DatabaseHelper.instance.searchTransactions(
      startDate: startOfYear,
      endDate: endOfYear,
      type: 'expense',
    );

    final Map<DateTime, double> dailySpending = {};
    for (var t in txns) {
      final date = DateTime(t.date.year, t.date.month, t.date.day);
      dailySpending[date] = (dailySpending[date] ?? 0) + t.amount;
    }
    return dailySpending;
  }
}
