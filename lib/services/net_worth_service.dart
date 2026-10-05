import '../data/repositories/account_repo.dart';
import '../data/repositories/loan_repo.dart';
import '../data/repositories/canonical/canonical_financial_query_repository.dart';

class NetWorthService {
  final AccountRepo accountRepo;
  final LoanRepo loanRepo;
  final CanonicalFinancialQueryRepository _queryRepo;

  NetWorthService(
    this.accountRepo,
    this.loanRepo, {
    CanonicalFinancialQueryRepository? queryRepo,
  }) : _queryRepo = queryRepo ?? CanonicalFinancialQueryRepository();

  Future<({double assets, double liabilities, double netWorth})> calculate() async {
    final assetsMoney = await _queryRepo.getTotalAssets();
    final liabilitiesMoney = await _queryRepo.getTotalLiabilities();
    final netWorthMoney = await _queryRepo.getNetWorth();

    return (
      assets: assetsMoney.toRupees,
      liabilities: liabilitiesMoney.toRupees,
      netWorth: netWorthMoney.toRupees,
    );
  }
}
