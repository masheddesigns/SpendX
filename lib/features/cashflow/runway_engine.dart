import '../../models/bank_account.dart';
import '../../models/transaction.dart';

enum RunwayStatus { safe, warning, critical }

/// Predicted cashflow runway.
class Runway {
  final double totalBalance;
  final double dailyBurn;
  final int daysLeft;
  final DateTime runwayDate;
  final RunwayStatus status;

  const Runway({
    required this.totalBalance,
    required this.dailyBurn,
    required this.daysLeft,
    required this.runwayDate,
    required this.status,
  });
}

/// Calculates how many days the user can survive at current spending.
/// Pure computation — no DB, no async.
class RunwayEngine {
  Runway calculate({
    required List<BankAccount> accounts,
    required List<Transaction> transactions,
  }) {
    // ── Step 1: Total liquid balance (assets only, no credit cards) ──
    final totalBalance = accounts
        .where((a) => a.isAsset)
        .fold<double>(0, (sum, a) => sum + a.balance);

    // ── Step 2: Daily burn from last 7 days ─────────────────────────
    final now = DateTime.now();
    final sevenDaysAgo = now.subtract(const Duration(days: 7));
    double recentExpenses = 0;
    int daysWithData = 0;

    for (final tx in transactions) {
      if (tx.type != 'expense') continue;
      if (tx.date.isBefore(sevenDaysAgo)) continue;
      recentExpenses += tx.amount;
    }

    // Count actual days with expenses for more accurate average
    final daysSinceStart = now.difference(sevenDaysAgo).inDays;
    daysWithData = daysSinceStart.clamp(1, 7);

    var dailyBurn = recentExpenses / daysWithData;

    // ── Step 3: Safety floor ────────────────────────────────────────
    if (dailyBurn < 50) dailyBurn = 50;

    // ── Step 4: Days left ───────────────────────────────────────────
    final daysLeft = totalBalance > 0
        ? (totalBalance / dailyBurn).floor().clamp(0, 365)
        : 0;

    // ── Step 5: Runway date ─────────────────────────────────────────
    final runwayDate = now.add(Duration(days: daysLeft));

    // ── Step 6: Status ──────────────────────────────────────────────
    final RunwayStatus status;
    if (daysLeft < 5) {
      status = RunwayStatus.critical;
    } else if (daysLeft < 15) {
      status = RunwayStatus.warning;
    } else {
      status = RunwayStatus.safe;
    }

    return Runway(
      totalBalance: totalBalance,
      dailyBurn: dailyBurn,
      daysLeft: daysLeft,
      runwayDate: runwayDate,
      status: status,
    );
  }
}
