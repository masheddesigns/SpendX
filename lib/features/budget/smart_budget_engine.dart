import '../../models/category.dart';
import '../../models/transaction.dart';

/// An auto-generated budget for a single category.
class SmartBudget {
  final String categoryId;
  final String categoryName;
  final String categoryColor;
  final double limit;
  final double spent;

  const SmartBudget({
    required this.categoryId,
    required this.categoryName,
    required this.categoryColor,
    required this.limit,
    required this.spent,
  });

  double get remaining => (limit - spent).clamp(0, double.infinity);
  double get usagePct => limit > 0 ? spent / limit : 0;
  bool get isOverBudget => spent > limit;
}

/// Generates category-wise budgets from historical spending.
/// Pure computation — no DB, no async, no side effects.
class SmartBudgetEngine {
  // Category priority weights: lower = more aggressive cuts
  static const _weights = <String, double>{
    'Rent': 1.0,
    'EMI': 1.0,
    'Bills': 0.95,
    'Insurance': 0.95,
    'Education': 0.95,
    'Health': 0.9,
    'Groceries': 0.9,
    'Food': 0.85,
    'Transport': 0.85,
    'Shopping': 0.7,
    'Entertainment': 0.6,
    'Subscriptions': 0.8,
    'Travel': 0.65,
  };

  List<SmartBudget> generate({
    required List<Transaction> transactions,
    required double monthlyIncome,
    required List<Category> categories,
  }) {
    final now = DateTime.now();
    final catMap = {for (final c in categories) c.id: c};

    // ── Step 1: Last 3 months category averages ──────────────────────
    final threeMonthsAgo = DateTime(now.year, now.month - 3, 1);
    final startOfMonth = DateTime(now.year, now.month, 1);

    final monthlySpend = <String, List<double>>{}; // categoryId -> per-month totals
    for (final tx in transactions) {
      if (tx.type != 'expense' || tx.categoryId == null) continue;
      if (tx.date.isBefore(threeMonthsAgo)) continue;
      if (!tx.date.isBefore(startOfMonth)) continue; // exclude current month

      monthlySpend.putIfAbsent(tx.categoryId!, () => []);
    }

    // Simpler: just total per category over 3 months, divide by 3
    final categoryTotal = <String, double>{};
    for (final tx in transactions) {
      if (tx.type != 'expense' || tx.categoryId == null) continue;
      if (tx.date.isBefore(threeMonthsAgo)) continue;
      if (!tx.date.isBefore(startOfMonth)) continue;
      categoryTotal[tx.categoryId!] =
          (categoryTotal[tx.categoryId!] ?? 0) + tx.amount;
    }

    final monthCount = _countMonths(threeMonthsAgo, startOfMonth);

    // ── Step 2: Current month spend ──────────────────────────────────
    final currentSpend = <String, double>{};
    for (final tx in transactions) {
      if (tx.type != 'expense' || tx.categoryId == null) continue;
      if (tx.date.isBefore(startOfMonth)) continue;
      currentSpend[tx.categoryId!] =
          (currentSpend[tx.categoryId!] ?? 0) + tx.amount;
    }

    // ── Step 3: Generate budgets ─────────────────────────────────────
    final budgets = <SmartBudget>[];
    double totalBudget = 0;

    for (final entry in categoryTotal.entries) {
      final cat = catMap[entry.key];
      if (cat == null || cat.type != 'expense') continue;

      final avg = entry.value / monthCount;
      if (avg < 100) continue; // Skip trivial categories

      // Apply category weight
      final weight = _weights[cat.name] ?? 0.8;
      var limit = avg * weight;

      // Clamp minimum
      limit = limit.clamp(500, double.infinity);

      budgets.add(SmartBudget(
        categoryId: entry.key,
        categoryName: cat.name,
        categoryColor: cat.color,
        limit: limit,
        spent: currentSpend[entry.key] ?? 0,
      ));
      totalBudget += limit;
    }

    // ── Step 4: Income constraint — total ≤ 70% of income ────────────
    if (monthlyIncome > 0 && totalBudget > monthlyIncome * 0.7) {
      final scale = (monthlyIncome * 0.7) / totalBudget;
      return budgets.map((b) => SmartBudget(
        categoryId: b.categoryId,
        categoryName: b.categoryName,
        categoryColor: b.categoryColor,
        limit: (b.limit * scale).clamp(500, double.infinity),
        spent: b.spent,
      )).toList()
        ..sort((a, b) => b.spent.compareTo(a.spent));
    }

    budgets.sort((a, b) => b.spent.compareTo(a.spent));
    return budgets;
  }

  int _countMonths(DateTime from, DateTime to) {
    final months = (to.year - from.year) * 12 + (to.month - from.month);
    return months.clamp(1, 12);
  }
}
