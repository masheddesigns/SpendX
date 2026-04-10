import '../data/repositories/ledger_repo.dart';
import '../models/ledger_transaction.dart';

class LedgerService {
  final LedgerRepo ledgerRepo;

  LedgerService({required this.ledgerRepo});

  static final LedgerService instance = LedgerService(ledgerRepo: LedgerRepo());

  /// Double-entry transfer between two accounts
  List<LedgerTransaction> buildTransferTransactions({
    required String sourceAccountId,
    required String destinationAccountId,
    required double amount,
    required DateTime date,
    String? note,
  }) {
    return [
      LedgerTransaction(
        type: LedgerType.transfer,
        amount: amount,
        date: date,
        accountId: sourceAccountId,
        note: note ?? 'Transfer to Account',
        referenceId: destinationAccountId,
      ),
      LedgerTransaction(
        type: LedgerType.income,
        amount: amount,
        date: date,
        accountId: destinationAccountId,
        note: note ?? 'Transfer from Account',
        referenceId: sourceAccountId,
      ),
    ];
  }

  Future<List<LedgerTransaction>> getTransactions({
    DateTime? start,
    DateTime? end,
    LedgerType? type,
    String? accountId,
    String? creditCardId,
    String? loanId,
    String? referenceId,
  }) async {
    return ledgerRepo.getAll(
      start: start,
      end: end,
      type: type,
      accountId: accountId,
      creditCardId: creditCardId,
      loanId: loanId,
      referenceId: referenceId,
    );
  }

  Future<double> getAccountBalance(String accountId) async {
    return ledgerRepo.getAccountBalance(accountId);
  }

  Future<double> getCreditOutstanding(String cardId) async {
    return ledgerRepo.getCreditOutstanding(cardId);
  }

  Future<double> getLoanBalance(String loanId) async {
    return ledgerRepo.getLoanBalance(loanId);
  }

  Future<double> getLoanRemaining(String loanId, double principal) async {
    final balance = await ledgerRepo.getLoanBalance(loanId);
    return principal - balance.abs(); // Basic remaining logic
  }
}
