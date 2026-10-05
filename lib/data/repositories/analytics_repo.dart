import 'package:sqflite/sqflite.dart' hide Transaction;
import '../../models/analytics_bundle.dart';
import '../../models/transaction.dart';
import '../../models/bank_account.dart';
import '../../models/loan.dart';
import '../../models/credit_card.dart';
import '../../models/category.dart';
import '../../models/budget.dart';
import 'transaction_repo.dart';
import 'account_repo.dart';
import 'loan_repo.dart';
import 'credit_repo.dart';
import 'category_repo.dart';
import 'budget_repo.dart';

class AnalyticsRepo {
  final DatabaseExecutor? _customExecutor;

  AnalyticsRepo({DatabaseExecutor? executor}) : _customExecutor = executor;

  /// Fetches a complete snapshot of all core financial data in a single sequence.
  /// Derived strictly from canonical repositories and accounts.
  Future<AnalyticsBundle> getDashboardBundle({
    TransactionRepo? transactionRepo,
    AccountRepo? accountRepo,
    LoanRepo? loanRepo,
    CreditRepo? creditRepo,
    CategoryRepo? categoryRepo,
    BudgetRepo? budgetRepo,
  }) async {
    final txRepo = transactionRepo ?? TransactionRepo(executor: _customExecutor);
    final accRepo = accountRepo ?? AccountRepo(executor: _customExecutor);
    final lRepo = loanRepo ?? LoanRepo(executor: _customExecutor);
    final cRepo = creditRepo ?? CreditRepo(executor: _customExecutor);
    final catRepo = categoryRepo ?? CategoryRepo();
    final bRepo = budgetRepo ?? BudgetRepo(executor: _customExecutor);

    final results = await Future.wait<dynamic>([
      txRepo.getAll(),
      accRepo.getAccounts(),
      lRepo.getLoans(),
      cRepo.getAll(),
      catRepo.getAll(),
      bRepo.getAll(),
    ]);

    return AnalyticsBundle(
      transactions: results[0] as List<Transaction>,
      accounts: results[1] as List<BankAccount>,
      loans: results[2] as List<Loan>,
      cards: results[3] as List<CreditCard>,
      categories: results[4] as List<Category>,
      budgets: results[5] as List<Budget>,
    );
  }
}
