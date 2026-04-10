import '../core/app_database.dart';
import '../core/tables.dart';
import '../../models/analytics_bundle.dart';
import '../../models/transaction.dart';
import '../../models/bank_account.dart';
import '../../models/loan.dart';
import '../../models/credit_card.dart';
import '../../models/category.dart';
import '../../models/budget.dart';

class AnalyticsRepo {
  final _dbProvider = AppDatabase.instance;

  /// Fetches a complete snapshot of all core financial data in a single sequence.
  /// This optimizes performance by reusing the same database connection and
  /// reducing the number of round-trips between the app and SQLite.
  Future<AnalyticsBundle> getDashboardBundle() async {
    final db = await _dbProvider.database;

    // Fetch all tables in parallel-ish (sequentially on one connection but 
    // minimizing overhead or potentially using transaction for consistency)
    final results = await Future.wait([
      db.query(Tables.transactions, where: 'is_deleted = 0', orderBy: 'date DESC'),
      db.query(Tables.bankAccounts),
      db.query(Tables.loans),
      db.query(Tables.creditCards),
      db.query(Tables.categories),
      db.query(Tables.budgets),
    ]);

    return AnalyticsBundle(
      transactions: results[0].map((m) => Transaction.fromMap(m)).toList(),
      accounts: results[1].map((m) => BankAccount.fromMap(m)).toList(),
      loans: results[2].map((m) => Loan.fromMap(m)).toList(),
      cards: results[3].map((m) => CreditCard.fromMap(m)).toList(),
      categories: results[4].map((m) => Category.fromMap(m)).toList(),
      budgets: results[5].map((m) => Budget.fromMap(m)).toList(),
    );
  }
}
