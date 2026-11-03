import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/screens/reports/reports_category_resolver.dart';

void main() {
  group('ReportsCategoryResolver Tests', () {
    test('resolves known seeded identifiers accurately', () {
      expect(ReportsCategoryResolver.resolve('Expense cat_shop'), 'Shopping');
      expect(ReportsCategoryResolver.resolve('Expense cat_food'), 'Food & Dining');
      expect(ReportsCategoryResolver.resolve('Expense cat_salary'), 'Staff & Payroll Expense');
      expect(ReportsCategoryResolver.resolve('Expense cat_emi'), 'EMI & Loans');
      expect(ReportsCategoryResolver.resolve('Expense cat_travel'), 'Travel & Transport');
      expect(ReportsCategoryResolver.resolve('Expense cat_bills'), 'Bills & Utilities');
      expect(ReportsCategoryResolver.resolve('Expense cat_rent'), 'Rent & Housing');
      expect(ReportsCategoryResolver.resolve('Expense cat_groceries'), 'Groceries');
      expect(ReportsCategoryResolver.resolve('Expense cat_health'), 'Healthcare');
      expect(ReportsCategoryResolver.resolve('Expense cat_entertainment'), 'Entertainment');
      expect(ReportsCategoryResolver.resolve('Expense cat_education'), 'Education');
      expect(ReportsCategoryResolver.resolve('Expense cat_subscriptions'), 'Subscriptions');
      expect(ReportsCategoryResolver.resolve('Expense cat_transport'), 'Transport');
      expect(ReportsCategoryResolver.resolve('Expense cat_others'), 'Other Expenses');
      expect(ReportsCategoryResolver.resolve('Expense cat_misc'), 'Miscellaneous');
    });

    test('preserves unknown or custom user categories verbatim without alteration', () {
      expect(ReportsCategoryResolver.resolve('Expense cat_custom'), 'Expense cat_custom');
      expect(ReportsCategoryResolver.resolve('My Personal Category'), 'My Personal Category');
      expect(ReportsCategoryResolver.resolve('Groceries (Local Market)'), 'Groceries (Local Market)');
      expect(ReportsCategoryResolver.resolve('Office Expense'), 'Office Expense');
      expect(ReportsCategoryResolver.resolve(''), '');
    });
  });
}
