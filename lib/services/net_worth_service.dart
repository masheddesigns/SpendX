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

    final rawAssets = assetsMoney.toRupees;
    final rawLiabilities = liabilitiesMoney.toRupees;
    final netWorth = netWorthMoney.toRupees;

    // Financial invariant: Gross Assets cannot be negative in accounting presentation.
    // If net asset balance is negative (e.g. overdrawn checking or unbacked expenses),
    // the negative portion is classified as an overdraft liability.
    final double displayAssets;
    final double displayLiabilities;
    if (rawAssets < 0) {
      displayAssets = 0.0;
      displayLiabilities = rawLiabilities + rawAssets.abs();
    } else {
      displayAssets = rawAssets;
      displayLiabilities = rawLiabilities;
    }

    return (
      assets: displayAssets,
      liabilities: displayLiabilities,
      netWorth: netWorth,
    );
  }
}
