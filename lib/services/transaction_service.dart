import 'package:flutter/foundation.dart' show debugPrint;
import '../models/transaction.dart';
import '../data/repositories/transaction_repo.dart';

class TransactionService {
  final TransactionRepo transactionRepo;

  TransactionService({required this.transactionRepo});

  static final instance = TransactionService(
    transactionRepo: TransactionRepo(),
  );

  /// Get all transactions
  Future<List<Transaction>> getTransactions({int? limit, int? offset}) async {
    try {
      return await transactionRepo.getAll(limit: limit, offset: offset);
    } catch (e) {
      debugPrint('[TRANSACTION] getTransactions error: $e');
      return [];
    }
  }

  /// Search transactions
  Future<List<Transaction>> searchTransactions({
    String? query,
    String? type,
    String? categoryId,
    String? startDate,
    String? endDate,
  }) async {
    try {
      final all = await transactionRepo.getAll();
      return all.where((transaction) {
        final matchesQuery =
            query == null ||
            query.isEmpty ||
            transaction.notes.toLowerCase().contains(query.toLowerCase());
        final matchesType = type == null || transaction.type == type;
        final matchesCategory =
            categoryId == null || transaction.categoryId == categoryId;
        final matchesStart =
            startDate == null ||
            !transaction.date.isBefore(DateTime.parse(startDate));
        final matchesEnd =
            endDate == null ||
            !transaction.date.isAfter(DateTime.parse(endDate));
        return matchesQuery &&
            matchesType &&
            matchesCategory &&
            matchesStart &&
            matchesEnd;
      }).toList();
    } catch (e) {
      debugPrint('[TRANSACTION] searchTransactions error: $e');
      return [];
    }
  }
}
