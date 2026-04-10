import 'transaction.dart';
import 'bank_account.dart';
import 'loan.dart';
import 'credit_card.dart';
import 'category.dart';
import 'budget.dart';

/// A Data Transfer Object (DTO) containing a snapshot of all core financial tables.
/// Used to pass raw data from AnalyticsRepo to AnalyticsService in a single object.
class AnalyticsBundle {
  final List<Transaction> transactions;
  final List<BankAccount> accounts;
  final List<Loan> loans;
  final List<CreditCard> cards;
  final List<Category> categories;
  final List<Budget> budgets;

  const AnalyticsBundle({
    required this.transactions,
    required this.accounts,
    required this.loans,
    required this.cards,
    required this.categories,
    required this.budgets,
  });

  factory AnalyticsBundle.empty() => const AnalyticsBundle(
        transactions: [],
        accounts: [],
        loans: [],
        cards: [],
        categories: [],
        budgets: [],
      );
}
