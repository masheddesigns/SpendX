import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'salary_ledger_models.dart';
import 'salary_ledger_notifier.dart';

/// Re-export for backward compatibility.
typedef SalaryInsights = SalaryReport;

/// Insights provider — just reads the pre-computed report.
final salaryInsightsProvider = Provider<SalaryReport>((ref) {
  return ref.watch(salaryReportProvider);
});

/// Predict next salary date from payment history.
DateTime predictNextSalary(List<SalaryMonthView> months) {
  final paidDates = months
      .where((m) => m.payments.isNotEmpty)
      .expand((m) => m.payments)
      .map((p) => p.paidDate)
      .toList()
    ..sort((a, b) => b.compareTo(a));

  if (paidDates.length < 2) {
    final now = DateTime.now();
    return DateTime(now.year, now.month + 1, 5);
  }

  final avgDay =
      paidDates.map((d) => d.day).reduce((a, b) => a + b) ~/
          paidDates.length;

  final now = DateTime.now();
  return DateTime(
      now.year, now.month + (now.day > avgDay ? 1 : 0), avgDay);
}
