import '../data/repositories/account_repo.dart';
import '../data/repositories/loan_repo.dart';

class NetWorthService {
  final AccountRepo accountRepo;
  final LoanRepo loanRepo;

  NetWorthService(this.accountRepo, this.loanRepo);

  Future<({double assets, double liabilities, double netWorth})> calculate() async {
    final accounts = await accountRepo.getAccounts();
    final cards = await accountRepo.getCards();
    final loans = await loanRepo.getLoans();

    // Assets: Total balance from all bank accounts marked as assets
    final assets = accounts.where((a) => a.isAsset).fold<double>(
      0.0,
      (sum, a) => sum + a.balance,
    );

    // liabilities from accounts marked as liabilities
    final accountLiabilities = accounts.where((a) => !a.isAsset).fold<double>(
      0.0,
      (sum, a) => sum + a.balance,
    );

    // Credit Card Liabilities: Total outstanding (used amount)
    final creditUsed = cards.fold<double>(
      0.0,
      (sum, c) => sum + c.usedAmount,
    );

    // Loan Liabilities: Total principal amounts
    final loanTotal = loans.fold<double>(
      0.0,
      (sum, l) => sum + l.total,
    );

    final totalLiabilities = accountLiabilities + creditUsed + loanTotal;

    return (
      assets: assets,
      liabilities: totalLiabilities,
      netWorth: assets - totalLiabilities,
    );
  }

}
