import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/net_worth_repo.dart';
import '../../features/categories/providers/category_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../../models/net_worth_snapshot_record.dart';

// ── Net Worth Timeline ────────────────────────────────────────────────

final netWorthRepoProvider = Provider<NetWorthRepo>((ref) => NetWorthRepo());

/// Net worth snapshots for the last N days (default 30).
final netWorthTimelineProvider = FutureProvider.family<
    List<NetWorthSnapshotRecord>, int>((ref, days) async {
  final repo = ref.watch(netWorthRepoProvider);
  final to = DateTime.now();
  final from = to.subtract(Duration(days: days));
  return repo.getRange(from: from, to: to);
});

/// Last 7 days of net worth for the sparkline on home.
final netWorthSparklineProvider =
    FutureProvider<List<NetWorthSnapshotRecord>>((ref) async {
  final repo = ref.watch(netWorthRepoProvider);
  final to = DateTime.now();
  final from = to.subtract(const Duration(days: 7));
  return repo.getRange(from: from, to: to);
});

/// Net worth change: current vs 30 days ago.
final netWorthChangeProvider =
    FutureProvider<({double current, double change, double changePct})>(
        (ref) async {
  final repo = ref.watch(netWorthRepoProvider);
  final latest = await repo.getLatest();
  if (latest == null) return (current: 0.0, change: 0.0, changePct: 0.0);

  final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30));
  final oldSnapshots = await repo.getRange(
    from: thirtyDaysAgo.subtract(const Duration(days: 2)),
    to: thirtyDaysAgo.add(const Duration(days: 2)),
  );

  final current = latest.netWorth;
  if (oldSnapshots.isEmpty) {
    return (current: current, change: 0.0, changePct: 0.0);
  }

  final old = oldSnapshots.first.netWorth;
  final change = current - old;
  final changePct = old != 0 ? (change / old.abs()) * 100 : 0.0;

  return (current: current, change: change, changePct: changePct);
});

// ── Monthly Stats ─────────────────────────────────────────────────────

/// Monthly income/expense stats for the last N months.
final monthlyStatsProvider =
    FutureProvider<List<MonthlyStats>>((ref) async {
  final txRepo = ref.watch(transactionRepoProvider);
  final raw = await txRepo.getMonthlyStats(12);

  return raw.map((row) {
    return MonthlyStats(
      month: row['month'] as String,
      income: (row['income'] as num?)?.toDouble() ?? 0,
      expense: (row['expense'] as num?)?.toDouble() ?? 0,
    );
  }).toList();
});

class MonthlyStats {
  final String month; // "2026-03"
  final double income;
  final double expense;

  const MonthlyStats({
    required this.month,
    required this.income,
    required this.expense,
  });

  double get savings => income - expense;
  double get savingsRate => income > 0 ? savings / income : 0;
}

/// Current month stats (convenience).
final currentMonthStatsProvider = FutureProvider<MonthlyStats?>((ref) async {
  final stats = await ref.watch(monthlyStatsProvider.future);
  if (stats.isEmpty) return null;
  final now = DateTime.now();
  final currentMonth =
      '${now.year}-${now.month.toString().padLeft(2, '0')}';
  return stats.where((s) => s.month == currentMonth).firstOrNull;
});

/// Previous month stats (for comparison).
final previousMonthStatsProvider = FutureProvider<MonthlyStats?>((ref) async {
  final stats = await ref.watch(monthlyStatsProvider.future);
  if (stats.isEmpty) return null;
  final prev = DateTime(DateTime.now().year, DateTime.now().month - 1);
  final prevMonth =
      '${prev.year}-${prev.month.toString().padLeft(2, '0')}';
  return stats.where((s) => s.month == prevMonth).firstOrNull;
});

// ── Top Categories ────────────────────────────────────────────────────

/// Top spending categories for the current month.
final topCategoriesProvider =
    FutureProvider<List<CategorySpend>>((ref) async {
  final transactions = await ref.watch(transactionsProvider.future);
  final categories = await ref.watch(categoriesProvider.future);
  final catMap = {for (final c in categories) c.id: c};

  final now = DateTime.now();
  final startOfMonth = DateTime(now.year, now.month, 1);

  final spending = <String, double>{};
  for (final tx in transactions) {
    if (tx.type == 'expense' &&
        !tx.date.isBefore(startOfMonth) &&
        tx.categoryId != null) {
      spending[tx.categoryId!] =
          (spending[tx.categoryId!] ?? 0) + tx.amount;
    }
  }

  final sorted = spending.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  double totalExpense = 0;
  for (final e in sorted) {
    totalExpense += e.value;
  }

  return sorted.take(5).map((e) {
    final cat = catMap[e.key];
    return CategorySpend(
      categoryId: e.key,
      categoryName: cat?.name ?? 'Unknown',
      categoryIcon: cat?.icon ?? 'help',
      categoryColor: cat?.color ?? '#888888',
      amount: e.value,
      percentage: totalExpense > 0 ? e.value / totalExpense : 0,
    );
  }).toList();
});

class CategorySpend {
  final String categoryId;
  final String categoryName;
  final String categoryIcon;
  final String categoryColor;
  final double amount;
  final double percentage;

  const CategorySpend({
    required this.categoryId,
    required this.categoryName,
    required this.categoryIcon,
    required this.categoryColor,
    required this.amount,
    required this.percentage,
  });
}
