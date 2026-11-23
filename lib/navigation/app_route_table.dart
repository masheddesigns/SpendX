import 'package:flutter/material.dart';

import '../features/home/screens/home_screen.dart';
import '../screens/bank/account_list_screen.dart';
import '../screens/expense/add_expense_screen.dart';
import '../screens/goals/goals_screen.dart';
import '../screens/home/transactions_screen.dart';
import '../screens/reports_screen.dart';

/// Named routes and URI normalization for SpendX app links.
class AppRouteTable {
  AppRouteTable._();

  static const home = '/home';
  static const transactions = '/transactions';
  static const accounts = '/accounts';
  static const goals = '/goals';
  static const reports = '/reports';
  static const addExpense = '/add-expense';

  static Map<String, WidgetBuilder> get routes => {
    home: (_) => const HomeScreen(),
    // A directly routed activity page must provide its own scaffold;
    // embedded mode is only used inside the bottom-navigation shell.
    transactions: (_) => const TransactionListScreen(isFullScreen: true),
    accounts: (_) => const AccountListScreen(),
    goals: (_) => const GoalsScreen(),
    reports: (_) => const ReportsScreen(),
    addExpense: (_) => const AddExpenseScreen(),
  };

  /// Maps `spendx://transactions` and `spendx:///transactions` to `/transactions`.
  static String normalize(String? location) {
    if (location == null || location.isEmpty) return home;
    final uri = Uri.tryParse(location);
    if (uri == null) return location;
    if (uri.scheme != 'spendx') {
      final path = uri.path.isEmpty ? location : uri.path;
      return routes.containsKey(path) ? path : home;
    }

    final routePath = uri.host.isNotEmpty
        ? '/${uri.host}${uri.path == '/' ? '' : uri.path}'
        : uri.path;
    final normalized = routePath.isEmpty ? home : routePath;
    return routes.containsKey(normalized) ? normalized : home;
  }
}
