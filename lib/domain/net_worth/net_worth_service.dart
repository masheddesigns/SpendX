import '../../data/repositories/account_repo.dart';
import '../../data/repositories/canonical/canonical_financial_query_repository.dart';
import '../../data/repositories/credit_repo.dart';
import '../../data/repositories/lending_repo.dart';
import '../../data/repositories/loan_repo.dart';
import '../../models/net_worth_summary.dart';
import '../credit/credit_card_service.dart';
import '../loans/loan_service.dart';

class NetWorthService {
  static final NetWorthService instance = NetWorthService();

  final CanonicalFinancialQueryRepository _queryRepo;

  NetWorthService({
    AccountRepo? accountRepo,
    LendingRepo? lendingRepo,
    CreditRepo? creditRepo,
    LoanRepo? loanRepo,
    CreditCardService? creditService,
    LoanService? loanService,
    CanonicalFinancialQueryRepository? queryRepo,
  }) : _queryRepo = queryRepo ?? CanonicalFinancialQueryRepository();

  Future<NetWorthSummary> calculateNetWorth() async {
    final assetsMoney = await _queryRepo.getTotalAssets();
    final liabilitiesMoney = await _queryRepo.getTotalLiabilities();
    final netWorthMoney = await _queryRepo.getNetWorth();

    return NetWorthSummary(
      totalAssets: assetsMoney.toRupees,
      totalLiabilities: liabilitiesMoney.toRupees,
      netWorth: netWorthMoney.toRupees,
    );
  }
}
