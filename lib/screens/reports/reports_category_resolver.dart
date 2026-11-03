/// Exact dictionary resolver for known internal/seeded category account identifiers.
/// Preserves custom user-created category names verbatim without string manipulation.
class ReportsCategoryResolver {
  ReportsCategoryResolver._();

  static const Map<String, String> _knownCategoryLabels = {
    'Expense cat_shop': 'Shopping',
    'Expense cat_food': 'Food & Dining',
    'Expense cat_travel': 'Travel & Transport',
    'Expense cat_bills': 'Bills & Utilities',
    'Expense cat_emi': 'EMI & Loans',
    'Expense cat_rent': 'Rent & Housing',
    'Expense cat_groceries': 'Groceries',
    'Expense cat_health': 'Healthcare',
    'Expense cat_entertainment': 'Entertainment',
    'Expense cat_education': 'Education',
    'Expense cat_subscriptions': 'Subscriptions',
    'Expense cat_transport': 'Transport',
    'Expense cat_salary': 'Staff & Payroll Expense',
    'Expense cat_others': 'Other Expenses',
    'Expense cat_misc': 'Miscellaneous',
  };

  /// Resolves known seeded category identifiers to human-readable names.
  /// If the input is not in the exact dictionary, returns [rawName] unchanged.
  static String resolve(String rawName) {
    return _knownCategoryLabels[rawName] ?? rawName;
  }
}
