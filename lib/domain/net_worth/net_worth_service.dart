import '../../data/repositories/account_repo.dart';
import '../../data/repositories/credit_repo.dart';
import '../../data/repositories/lending_repo.dart';
import '../../data/repositories/loan_repo.dart';
import '../../models/ledger_transaction.dart';
import '../../models/net_worth_summary.dart';
import '../../services/ledger_service.dart';
import '../credit/credit_card_service.dart';
import '../loans/loan_service.dart';

class NetWorthService {
  static final NetWorthService instance = NetWorthService();

  final AccountRepo _accountRepo;
  final LendingRepo _lendingRepo;
  final CreditRepo _creditRepo;
  final LoanRepo _loanRepo;
  final CreditCardService _creditService;
  final LoanService _loanService;

  NetWorthService({
    AccountRepo? accountRepo,
    LendingRepo? lendingRepo,
    CreditRepo? creditRepo,
    LoanRepo? loanRepo,
    CreditCardService? creditService,
    LoanService? loanService,
  }) : _accountRepo = accountRepo ?? AccountRepo(),
       _lendingRepo = lendingRepo ?? LendingRepo(),
       _creditRepo = creditRepo ?? CreditRepo(),
       _loanRepo = loanRepo ?? LoanRepo(),
       _creditService = creditService ?? CreditCardService(),
       _loanService = loanService ?? LoanService();

  Future<NetWorthSummary> calculateNetWorth() async {
    double assets = 0.0;
    double liabilities = 0.0;

    final accounts = await _accountRepo.getAccounts();
    for (final acc in accounts) {
      final balance = await LedgerService.instance.getAccountBalance(acc.id);
      if (acc.isAsset) {
        assets += balance;
      } else {
        liabilities += balance;
      }
    }

    final lendings = await _lendingRepo.getAll(settledFilter: false);
    for (final lending in lendings) {
      final balance = await LedgerService.instance
          .getTransactions(referenceId: lending.id)
          .then((txs) {
            double total = 0.0;
            for (final tx in txs) {
              if (tx.type == LedgerType.lending_given) total += tx.amount;
              if (tx.type == LedgerType.lending_received) total -= tx.amount;
            }
            return total;
          });

      if (balance > 0) {
        assets += balance;
      } else if (balance < 0) {
        liabilities += balance.abs();
      }
    }

    final cards = await _creditRepo.getAll();
    for (final card in cards) {
      final outstanding = await _creditService.calculateOutstanding(card.id);
      if (outstanding > 0) {
        liabilities += outstanding;
      }
    }

    final loans = await _loanRepo.getLoans();
    for (final loan in loans.where((loan) => loan.loanStatus != 'closed')) {
      final remaining = await _loanService.getRemainingBalance(loan.id);
      if (remaining > 0) {
        liabilities += remaining;
      }
    }

    return NetWorthSummary(
      totalAssets: assets,
      totalLiabilities: liabilities,
      netWorth: assets - liabilities,
    );
  }
}
