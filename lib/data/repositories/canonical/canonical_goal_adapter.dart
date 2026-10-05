import 'package:sqflite/sqflite.dart';

import '../../../domain/finance/finance.dart';
import '../../../models/goal.dart';
import '../../core/tables.dart';

/// Adapter facilitating canonical asset earmark reservations, derived progress
/// calculations, and operational compatibility projections for [Goal].
///
/// CRITICAL ARCHITECTURAL INVARIANTS:
/// 1. Goals are NOT accounting entities. They produce ZERO economic events and ZERO postings.
/// 2. Asset earmarks are soft reservations on real asset accounts, NOT money movements.
/// 3. Earmark creation, modification, and removal have ZERO impact on ledger balances, net worth, income, or expense.
/// 4. Goal progress is derived dynamically from active asset earmarks (`TablesV24.assetEarmarks`).
/// 5. Legacy `goals.current_amount` is strictly a non-authoritative compatibility projection.
class CanonicalGoalAdapter {
  /// Calculates the derived progress (in major units, e.g. INR) of a goal
  /// by summing all active asset earmarks.
  static Future<double> getDerivedGoalProgress(
    DatabaseExecutor db,
    String goalId,
  ) async {
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(amount_minor_units), 0) AS total_minor
      FROM ${TablesV24.assetEarmarks}
      WHERE goal_id = ?
    ''', [goalId]);

    final totalMinor = (result.first['total_minor'] as num?)?.toInt() ?? 0;
    return totalMinor / 100.0;
  }

  /// Projects a database row from the legacy `goals` table into a domain [Goal]
  /// with dynamically derived progress.
  static Future<Goal> projectGoal(
    DatabaseExecutor db,
    Map<String, dynamic> row,
  ) async {
    final goalId = row['id'] as String;
    // Milestone C4-4: Canonical goal progress is derived dynamically and exclusively
    // from active asset earmarks (TablesV24.assetEarmarks).
    // Legacy goals.current_amount is strictly non-authoritative.
    final progress = await getDerivedGoalProgress(db, goalId);

    return Goal(
      id: goalId,
      title: row['title'] as String,
      type: GoalType.values.firstWhere(
        (e) => e.name == (row['type'] as String? ?? 'savings'),
        orElse: () => GoalType.savings,
      ),
      targetAmount: (row['target_amount'] as num).toDouble(),
      currentAmount: progress,
      startDate: DateTime.parse(row['start_date'] as String),
      endDate: DateTime.parse(row['end_date'] as String),
      categoryId: row['category_id'] as String?,
      accountId: row['account_id'] as String?,
      isActive: (row['is_active'] as int?) == 1,
      createdAt: row['created_at'] != null
          ? DateTime.parse(row['created_at'] as String)
          : DateTime.now(),
    );
  }

  /// Validates safety invariants for creating or updating an asset earmark:
  /// - Goal must exist and be active (if legacy `goals` table is present).
  /// - Asset account must exist and be an 'asset' account.
  /// - Amount must be strictly positive.
  static Future<void> validateEarmarkSafety(
    DatabaseExecutor db,
    AssetEarmark earmark,
  ) async {
    // 1. Validate goal existence and active status (when legacy goals table exists)
    final tableCheck = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [Tables.goals],
    );
    if (tableCheck.isNotEmpty) {
      final goalRows = await db.query(
        Tables.goals,
        columns: ['id', 'is_active'],
        where: 'id = ?',
        whereArgs: [earmark.goalId],
        limit: 1,
      );

      if (goalRows.isEmpty) {
        throw ArgumentError.value(
          earmark.goalId,
          'goalId',
          'Goal ${earmark.goalId} does not exist.',
        );
      }

      final isActive = (goalRows.first['is_active'] as int?) == 1;
      if (!isActive) {
        throw StateError(
          'Cannot earmark funds for inactive or archived goal ${earmark.goalId}.',
        );
      }
    }

    // 2. Validate asset account existence and account_type
    final accountRows = await db.query(
      TablesV24.accounts,
      columns: ['id', 'account_type', 'is_active'],
      where: 'id = ?',
      whereArgs: [earmark.assetAccountId],
      limit: 1,
    );

    if (accountRows.isEmpty) {
      throw ArgumentError.value(
        earmark.assetAccountId,
        'assetAccountId',
        'Account ${earmark.assetAccountId} does not exist in canonical accounts.',
      );
    }

    final accountType = accountRows.first['account_type'] as String;
    if (accountType != 'asset') {
      throw ArgumentError.value(
        earmark.assetAccountId,
        'assetAccountId',
        'Account ${earmark.assetAccountId} is a $accountType account; only asset accounts can be earmarked.',
      );
    }

    // 3. Amount positivity
    if (!earmark.earmarkedAmount.isPositive) {
      throw ArgumentError.value(
        earmark.earmarkedAmount,
        'earmarkedAmount',
        'Earmarked amount must be strictly positive minor units.',
      );
    }
  }

  /// Syncs the derived earmark progress into the legacy `goals.current_amount` column
  /// as an operational projection.
  static Future<void> syncGoalProjection(
    DatabaseExecutor db,
    String goalId,
  ) async {
    final tableCheck = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [Tables.goals],
    );
    if (tableCheck.isEmpty) return;

    final progress = await getDerivedGoalProgress(db, goalId);
    await db.update(
      Tables.goals,
      {'current_amount': progress},
      where: 'id = ?',
      whereArgs: [goalId],
    );
  }
}
