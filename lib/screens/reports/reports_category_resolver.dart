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
  /// Formats hierarchical canonical account names (e.g. "Expense:General:Miscellaneous" -> "Miscellaneous").
  /// Replaces raw UUID strings with a clean category label.
  /// Preserves custom user-created category names verbatim.
  static String resolve(String rawName) {
    final trimmed = rawName.trim();
    if (_knownCategoryLabels.containsKey(trimmed)) {
      return _knownCategoryLabels[trimmed]!;
    }

    // Handle hierarchical canonical account names: "Expense:General:Miscellaneous" -> "Miscellaneous"
    if (trimmed.contains(':')) {
      final parts = trimmed.split(':');
      final last = parts.last.trim();
      if (last.isNotEmpty &&
          last.toLowerCase() != 'general' &&
          last.toLowerCase() != 'expense' &&
          last.toLowerCase() != 'income') {
        return last;
      }
    }

    // Handle sys_ accounts: "sys_exp_misc" -> "Miscellaneous"
    if (trimmed.startsWith('sys_exp_') || trimmed.startsWith('sys_inc_')) {
      final key = trimmed.replaceFirst(RegExp(r'^sys_(?:exp|inc)_'), '');
      if (key == 'misc') return 'Miscellaneous';
      if (key == 'refunds') return 'Refunds';
      if (key == 'interest') return 'Interest';
      if (key.isNotEmpty) {
        return key[0].toUpperCase() + key.substring(1);
      }
    }

    // If it is a raw UUID, fallback to a clean label
    final uuidRegex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    if (uuidRegex.hasMatch(trimmed)) {
      return 'General Expense';
    }

    return rawName;
  }
}
