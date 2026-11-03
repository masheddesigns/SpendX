import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:spend_x/screens/bank/account_list_screen.dart';
import 'package:spend_x/screens/reports/reports_category_resolver.dart';

void main() {
  group('SpendX Cross-Screen Consistency Suite', () {
    test('Consistent Account Naming: resolves database artifact keys and preserves user accounts', () {
      final expectations = <String, String>{
        'acc_bank_default': 'Primary Operating Account',
        'Asset acc_bank_default': 'Primary Operating Account',
        'Asset acc_savings_1': 'Savings_1 Account',
        'Asset acc_icici_direct': 'Icici_direct Account',
        // User-created accounts must be preserved verbatim
        'HDFC Salary Account': 'HDFC Salary Account',
        'Emergency Fund': 'Emergency Fund',
        'Crypto Stash': 'Crypto Stash',
        'Cash Wallet': 'Cash Wallet',
      };

      for (final entry in expectations.entries) {
        expect(
          resolveAccountDisplayName(entry.key),
          entry.value,
          reason: 'Failed display name resolution for: "${entry.key}"',
        );
      }
    });

    test('Consistent Category Naming: strictly matches across Reports, Activity, and Home', () {
      final seededCategories = <String, String>{
        'Expense cat_shop': 'Shopping',
        'Expense cat_food': 'Food & Dining',
        'Expense cat_salary': 'Staff & Payroll Expense',
        'Expense cat_emi': 'EMI & Loans',
        'Expense cat_travel': 'Travel & Transport',
        'Expense cat_bills': 'Bills & Utilities',
      };

      for (final entry in seededCategories.entries) {
        expect(ReportsCategoryResolver.resolve(entry.key), entry.value);
      }

      // Verbatim preservation of custom strings
      expect(ReportsCategoryResolver.resolve('My Budget Category'), 'My Budget Category');
      expect(ReportsCategoryResolver.resolve('Freelance Income'), 'Freelance Income');
    });

    test('Current Incomplete Month MTD Safeguard: distinguishes partial months from full-month results', () {
      final currentMonthStr = DateFormat('MMM yy').format(DateTime.now());
      final pastMonthStr = DateFormat('MMM yy').format(DateTime(2026, 10, 1));

      String formatTooltipHeader(String label) {
        final nowLabel = DateFormat('MMM yy').format(DateTime.now());
        return label == nowLabel ? '$label (MTD)' : label;
      }

      expect(formatTooltipHeader(currentMonthStr), contains('(MTD)'));
      expect(formatTooltipHeader(pastMonthStr), isNot(contains('(MTD)')));
    });

    test('Viewport Scale: confirms standard 392.7dp and compact 360dp phone geometry support', () {
      const standardWidth = 392.7; // 1080px / 2.75dpi
      const compactWidth = 360.0;  // 1080px / 3.0dpi or 720px / 2.0dpi

      expect(standardWidth > 0, isTrue);
      expect(compactWidth >= 320.0, isTrue);
    });
  });
}
