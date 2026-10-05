import 'package:sqflite/sqflite.dart';
import '../../models/budget.dart';
import '../core/app_database.dart';
import '../core/tables.dart';
import 'canonical/canonical_financial_query_repository.dart';

class BudgetRepo {
  final db = AppDatabase.instance;
  final DatabaseExecutor? _customExecutor;
  final CanonicalFinancialQueryRepository? _queryRepo;

  BudgetRepo({
    DatabaseExecutor? executor,
    CanonicalFinancialQueryRepository? queryRepo,
  })  : _customExecutor = executor,
        _queryRepo = queryRepo;

  Future<DatabaseExecutor> get _db async =>
      _customExecutor ?? await db.database;

  CanonicalFinancialQueryRepository _getQueryRepo(DatabaseExecutor executor) =>
      _queryRepo ?? CanonicalFinancialQueryRepository(executor: executor);

  Future<List<Budget>> getAll() async {
    final database = await _db;
    final res = await database.query(Tables.budgets);
    return res.map((e) => Budget.fromMap(e)).toList();
  }

  Future<String> insert(Budget budget) async {
    final database = await _db;
    await database.insert(Tables.budgets, budget.toMap());
    return budget.id;
  }

  Future<int> update(Budget budget) async {
    final database = await _db;
    return await database.update(
      Tables.budgets,
      budget.toMap(),
      where: 'id = ?',
      whereArgs: [budget.id],
    );
  }

  Future<int> delete(String id) async {
    final database = await _db;
    return await database.delete(
      Tables.budgets,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Calculates total expense spending for a specific category within a date range.
  /// Derived strictly from canonical double-entry postings (Debits - Credits on expense accounts).
  Future<double> getSpentForCategory(
    String categoryId,
    DateTime start,
    DateTime end,
  ) async {
    final database = await _db;
    final queryRepo = _getQueryRepo(database);
    final spent = await queryRepo.getCategorySpending(
      categoryId,
      startDate: start,
      endDate: end,
    );
    return spent.toRupees;
  }

  /// Calculates category spending grouped by category within a date range.
  /// Derived strictly from canonical double-entry postings (Debits - Credits on expense accounts).
  Future<Map<String, double>> getCategorySpending(
    DateTime start,
    DateTime end,
  ) async {
    final database = await _db;
    final queryRepo = _getQueryRepo(database);
    final map = await queryRepo.getAllCategorySpending(
      startDate: start,
      endDate: end,
    );
    return map.map((key, value) => MapEntry(key, value.toRupees));
  }
}
