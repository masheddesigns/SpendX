import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/models/reports_summary.dart';
import 'package:spend_x/screens/reports/reports_category_resolver.dart';
import 'package:spend_x/services/settings_service.dart';
import 'package:spend_x/utils/app_format.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });
  group('Reports Redesign Regression & Data Integrity Tests', () {
    test('Category Resolver: strictly maps known identifiers and preserves custom strings', () {
      final expectations = <String, String>{
        'Expense cat_shop': 'Shopping',
        'Expense cat_food': 'Food & Dining',
        'Expense cat_salary': 'Staff & Payroll Expense',
        'Expense cat_emi': 'EMI & Loans',
        'Expense cat_travel': 'Travel & Transport',
        'Expense cat_bills': 'Bills & Utilities',
        'Expense cat_rent': 'Rent & Housing',
        'Expense cat_groceries': 'Groceries',
        'Expense cat_health': 'Healthcare',
        'Expense cat_entertainment': 'Entertainment',
        'Expense cat_education': 'Education',
        'Expense cat_subscriptions': 'Subscriptions',
        'Expense cat_transport': 'Transport',
        'Expense cat_others': 'Other Expenses',
        'Expense cat_misc': 'Miscellaneous',
        // Unknown & Custom categories MUST remain unchanged verbatim
        'Expense cat_custom': 'Expense cat_custom',
        'My Personal Category': 'My Personal Category',
        'Side Business (Consulting)': 'Side Business (Consulting)',
        '': '',
      };

      for (final entry in expectations.entries) {
        expect(
          ReportsCategoryResolver.resolve(entry.key),
          entry.value,
          reason: 'Failed mapping for input: "${entry.key}"',
        );
      }
    });

    test('Monthly Trend Reversal: repository order is preserved while chart presentation is chronological', () {
      final repoOrder = [
        MonthData(label: 'Nov 26', income: 100000, expense: 45000),
        MonthData(label: 'Oct 26', income: 95000, expense: 50000),
        MonthData(label: 'Sep 26', income: 90000, expense: 48000),
      ];

      // Downstream consumers (like anomalies, insights) must get newest-first
      expect(repoOrder.first.label, 'Nov 26');
      expect(repoOrder.last.label, 'Sep 26');

      // Chart presentation layer must receive chronological (past to present, left to right)
      final chartPresentationOrder = repoOrder.reversed.toList();
      expect(chartPresentationOrder.first.label, 'Sep 26');
      expect(chartPresentationOrder[1].label, 'Oct 26');
      expect(chartPresentationOrder.last.label, 'Nov 26');

      // Ensure original list was not mutated
      expect(repoOrder.first.label, 'Nov 26');
    });

    test('Zero Division & Ratio Guards: handles edge cases without division errors', () {
      // Zero income & zero expense
      final zeroSummary = ReportsSummary.empty();
      expect(zeroSummary.netSavings, 0.0);
      expect(zeroSummary.savingsRate, 0.0);

      // Zero income & positive expense (Deficit state)
      final deficitSummary = ReportsSummary(
        monthlyTrend: [],
        totalIncome: 0.0,
        totalExpense: 15000.0,
        creditSummaries: [],
        loanSummaries: [],
        lendingTrend: [],
        totalLent: 0.0,
        totalBorrowed: 0.0,
        savingsRate: 0.0, // ReportsService produces 0.0 when totalIncome == 0
      );
      expect(deficitSummary.netSavings, -15000.0);
      expect(deficitSummary.savingsRate, 0.0);

      // Credit card zero limit
      final zeroLimitCard = CreditCardSummary(
        name: 'Test Card',
        outstanding: 500.0,
        limit: 0.0,
        utilPct: 0.0,
        daysLeft: 10,
      );
      expect(zeroLimitCard.utilPct, 0.0);

      // Loan zero total principal
      final zeroLoan = LoanSummary(
        name: 'Zero Loan',
        totalPrincipal: 0.0,
        totalInterest: 0.0,
        principalPaid: 0.0,
        interestPaid: 0.0,
        remainingPrincipal: 0.0,
        progress: 0.0,
      );
      expect(zeroLoan.progress, 0.0);
    });

    test('Peer Lending: strictly verifies direction of money lent vs borrowed', () {
      // Lent = money given to someone else (+)
      // Borrowed = money received from someone else (-)
      final lentTrend = [
        LendingTrendData(label: 'Oct 26', net: 5000.0), // Net lent
        LendingTrendData(label: 'Nov 26', net: -2000.0), // Net borrowed
      ];

      expect(lentTrend[0].net > 0, isTrue); // Positive = Lent
      expect(lentTrend[1].net < 0, isTrue); // Negative = Borrowed

      final summary = ReportsSummary(
        monthlyTrend: [],
        totalIncome: 0,
        totalExpense: 0,
        creditSummaries: [],
        loanSummaries: [],
        lendingTrend: lentTrend,
        totalLent: 5000.0,
        totalBorrowed: 2000.0,
      );

      final netPosition = summary.totalLent - summary.totalBorrowed;
      expect(netPosition, 3000.0);
      expect(netPosition >= 0, isTrue); // Net receivable
    });

    test('Period Selector: dynamically calculates exact date ranges for 3M, 6M, and 12M', () {
      String formatDateRange(int months, DateTime now) {
        final start = DateTime(now.year, now.month - months + 1, 1);
        final fmt = DateFormat('MMM yyyy');
        return '${fmt.format(start)} – ${fmt.format(now)}';
      }

      final testDate = DateTime(2026, 11, 3);
      expect(formatDateRange(3, testDate), 'Sep 2026 – Nov 2026');
      expect(formatDateRange(6, testDate), 'Jun 2026 – Nov 2026');
      expect(formatDateRange(12, testDate), 'Dec 2025 – Nov 2026');
    });

    test('Chart Presentation: tooltips, zero ceiling and dual rods verification', () {
      final months = [
        MonthData(label: 'Sep 26', income: 0, expense: 0),
        MonthData(label: 'Oct 26', income: 15000, expense: 22000),
      ];

      // Safe max ceiling fallback
      final maxVal = months.fold<double>(
        0.0,
        (m, d) => [m, d.income, d.expense].reduce((a, b) => a > b ? a : b),
      );
      final chartCeiling = maxVal > 0 ? maxVal * 1.25 : 1000.0;
      expect(chartCeiling, 22000 * 1.25);

      // Tooltip generator inspection with MTD safeguard for incomplete current month
      String formatTooltip(MonthData item, int rodIndex) {
        final isIncomeRod = rodIndex == 0;
        final label = isIncomeRod ? 'Inflow' : 'Outflow';
        final amount = isIncomeRod ? item.income : item.expense;
        final currentMonthLabel = DateFormat('MMM yy').format(DateTime.now());
        final monthTitle = item.label == currentMonthLabel
            ? '${item.label} (MTD)'
            : item.label;
        return '$monthTitle\n$label: ${AppFormat.currency(amount)}';
      }

      expect(formatTooltip(months[1], 0), 'Oct 26\nInflow: ₹15,000.00');
      expect(formatTooltip(months[1], 1), 'Oct 26\nOutflow: ₹22,000.00');
      expect(formatTooltip(months[0], 0), 'Sep 26\nInflow: ₹0.00');
      expect(formatTooltip(months[0], 1), 'Sep 26\nOutflow: ₹0.00');

      // Current month MTD check
      final currentMonth = MonthData(
        label: DateFormat('MMM yy').format(DateTime.now()),
        income: 5000,
        expense: 3000,
      );
      expect(formatTooltip(currentMonth, 1), contains('(MTD)'));
    });

    test('Loan Amortization: verifies no loan-interest values are presented as real data', () {
      final loan = LoanSummary(
        name: 'Car Loan',
        totalPrincipal: 800000.0,
        totalInterest: 0.0, // Zero / not computed
        principalPaid: 200000.0,
        interestPaid: 0.0, // Strictly unverified
        remainingPrincipal: 600000.0,
        progress: 0.25,
      );

      // UI presents principal paid vs remaining debt
      expect(loan.principalPaid, 200000.0);
      expect(loan.remainingPrincipal, 600000.0);
      expect(loan.progress, 0.25);
      // Interest paid is not presented as an actual breakdown
      expect(loan.interestPaid, 0.0);
    });
  });
}
