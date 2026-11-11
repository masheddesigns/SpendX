import 'package:uuid/uuid.dart';
import '../../models/credit_card.dart';
import '../../models/credit_transaction.dart';
import '../../models/credit_emi.dart';
import '../../models/emi_installment.dart';
import '../../models/card_statement.dart';
import '../../models/reminder_model.dart';
import '../../models/transaction.dart';
import '../../data/core/app_database.dart';
import '../../data/core/tables.dart';
import '../../data/repositories/credit_repo.dart';
import '../../data/repositories/ledger_repo.dart';
import '../../data/repositories/reminder_repo.dart';
import '../../models/ledger_transaction.dart';
import '../../services/financial_transaction_service.dart';

class CreditCardService {
  final CreditRepo _creditRepo;
  final ReminderRepo _reminderRepo;
  final FinancialTransactionService _svc;

  CreditCardService({
    CreditRepo? creditRepo,
    LedgerRepo? ledgerRepo,
    ReminderRepo? reminderRepo,
    FinancialTransactionService? financialService,
  })  : _creditRepo = creditRepo ?? CreditRepo(),
        _reminderRepo = reminderRepo ?? ReminderRepo(),
        _svc = financialService ?? FinancialTransactionService();

  Future<void> addCreditTransaction(CreditTransaction tx) async {
    await _creditRepo.insertTransaction(tx);

    await _svc.appendLedger(
      LedgerTransaction(
        type: LedgerType.credit_purchase,
        amount: tx.amount,
        date: tx.date,
        creditCardId: tx.cardId,
        note: tx.note,
        referenceId: tx.id,
        categoryId: tx.categoryId,
      ),
    );

    // Sync to Reminders
    final card = await _creditRepo.getCard(tx.cardId);
    if (card != null) {
      final nextDue = card.nextDueDate;
      final outstanding = await calculateOutstanding(card.id);
      
      await _reminderRepo.insertGlobalReminder(
        Reminder(
          id: 'credit_due_${card.id}',
          type: ReminderType.credit,
          title: 'Credit Card Due: ${card.name}',
          linkedEntityId: card.id,
          dueDate: nextDue,
          amount: outstanding,
          isActive: true,
          status: ReminderStatus.upcoming,
          recordStatus: ReminderRecordStatus.pending,
          sourceType: ReminderSourceType.credit,
          sourceId: card.id,
        ).toMap(),
      );
    }
  }

  /// Retrieves all transactions for a specific card
  Future<List<CreditTransaction>> getTransactionsForCard(String cardId) async {
    return _creditRepo.getTransactions(cardId);
  }

  Future<void> deleteCreditTransaction(String id) async {
    final txn = await _creditRepo.getTransactionById(id);
    if (txn == null) return;

    // 1. If it's a purchase converted to EMI, delete the EMI plan first
    if (txn.status == 'converted') {
      final emis = await _creditRepo.getEmis(txn.cardId);
      for (var emi in emis.where((e) => e.transactionId == id)) {
        await deleteCreditEMI(emi.id);
      }
    }

    // 2. Delete the credit transaction
    await _creditRepo.deleteTransaction(id);

    // 3. Delete from Ledger
    await _svc.removeLedger(referenceId: id);
  }

  Future<void> deleteCreditEMI(String emiId) async {
    final emi = await _creditRepo.getEMIById(emiId);
    if (emi == null) return;

    final originalTxnId = emi.transactionId;

    // Clean up installment reminders
    try {
      final installments = await _creditRepo.getInstallments(emiId);
      for (final inst in installments) {
        await _reminderRepo.deleteGlobalReminder('emi_inst_${inst.id}');
      }
    } catch (_) {}

    // 1. Delete all installments
    await _creditRepo.deleteInstallments(emiId);

    // 2. Delete EMI plan
    await _creditRepo.deleteEMI(emiId);

    // 3. Delete Ledger entries (emi_installment) linked to the original txn
    await _svc.removeLedger(
      referenceId: originalTxnId,
      type: LedgerType.emi_installment.name,
    );

    // 4. Restore original CreditTransaction status to 'active'
    await _creditRepo.updateTransactionStatus(originalTxnId, 'active');

    // 5. Restore Ledger entry for the original purchase
    final ctx = await _creditRepo.getTransactionById(originalTxnId);
    if (ctx != null) {
      await _svc.appendLedger(
        LedgerTransaction(
          type: LedgerType.credit_purchase,
          amount: ctx.amount,
          date: ctx.date,
          creditCardId: ctx.cardId,
          note: ctx.note ?? 'Restored Purchase',
          referenceId: ctx.id,
        ),
      );
    }
  }

  /// Calculates the real-time outstanding balance directly from canonical liability
  Future<double> calculateOutstanding(String cardId) async {
    final card = await _creditRepo.getCard(cardId);
    return card?.usedAmount ?? 0.0;
  }

  /// Processes a payment, allocating it according to strict rules:
  /// Interest -> Processing Fees -> EMI Installments -> Statement Balance -> Remaining Balance
  Future<void> processPayment({
    required String cardId,
    required double paymentAmount,
    required DateTime date,
    String? accountId,
    String? note,
  }) async {
    final card = await _creditRepo.getCard(cardId);
    final cardName = card?.name ?? (card?.bank != null && card!.bank.isNotEmpty ? '${card.bank} Credit Card' : 'Credit Card');
    final defaultNote = note ?? 'Payment to $cardName';
    final txnId = const Uuid().v4();

    // 1. Create canonical transaction with double-entry postings:
    // Debits card liability, credits paying bank asset, inserts transaction, auto-settles reminders.
    final tx = Transaction(
      id: txnId,
      userId: 'offline_user',
      type: 'credit_payment',
      accountId: accountId,
      relatedEntityId: cardId,
      amount: paymentAmount,
      date: date,
      notes: defaultNote,
      source: 'credit_card_payment',
    );
    await _svc.createTransaction(tx);

    // 2. Decrement last_statement_balance in credit_cards table
    try {
      final db = await AppDatabase.instance.database;
      await db.rawUpdate(
        'UPDATE ${Tables.creditCards} SET last_statement_balance = MAX(0, last_statement_balance - ?) WHERE id = ?',
        [paymentAmount, cardId],
      );
    } catch (_) {}

    // 3. Sync to Reminders after payment
    try {
      final updatedCard = await _creditRepo.getCard(cardId);
      if (updatedCard != null) {
        final remainingDue = updatedCard.lastStatementBalance > 0
            ? updatedCard.lastStatementBalance
            : updatedCard.outstanding;
        final isPaid = remainingDue <= 0.01;

        await _reminderRepo.insertGlobalReminder(
          Reminder(
            id: 'credit_due_${updatedCard.id}',
            type: ReminderType.credit,
            title: 'Credit Card Due: ${updatedCard.name}',
            linkedEntityId: updatedCard.id,
            dueDate: updatedCard.nextDueDate,
            amount: isPaid ? 0.0 : remainingDue,
            isActive: !isPaid,
            status: isPaid ? ReminderStatus.inactive : ReminderStatus.upcoming,
            recordStatus: isPaid ? ReminderRecordStatus.done : ReminderRecordStatus.pending,
            sourceType: ReminderSourceType.credit,
            sourceId: updatedCard.id,
          ).toMap(),
        );

        final all = await _reminderRepo.getAll();
        for (final r in all) {
          if (r.id == 'credit_due_${updatedCard.id}') continue;
          final isLinked = r.linkedEntityId == updatedCard.id ||
              r.sourceId == updatedCard.id ||
              r.id.contains(updatedCard.id);
          if (isLinked) {
            final updated = r.copyWith(
              isActive: !isPaid,
              status: isPaid ? ReminderStatus.inactive : ReminderStatus.upcoming,
              recordStatus: isPaid ? ReminderRecordStatus.done : ReminderRecordStatus.pending,
              amount: isPaid ? 0.0 : remainingDue,
            );
            await _reminderRepo.upsert(updated);
          }
        }
      }
    } catch (_) {
      // Non-fatal if reminder sync fails
    }
  }

  /// Converts an existing purchase to an EMI plan
  Future<void> convertPurchaseToEMI({
    required CreditTransaction purchase,
    required double interestRate,
    required int tenureMonths,
    required double processingFee,
  }) async {
    if (purchase.type != 'purchase') throw Exception('Only purchases can be converted to EMI.');
    if (purchase.status != 'active') throw Exception('Transaction is not active.');

    // 1. Update original transaction status
    await _creditRepo.updateTransactionStatus(purchase.id, 'converted');

    // 2. Ledger Consistency: Remove original credit_purchase from ledger
    await _svc.removeLedger(
      referenceId: purchase.id,
      type: LedgerType.credit_purchase.name,
    );

    // 3. Add processing fee transaction
    if (processingFee > 0) {
      final feeId = const Uuid().v4();
      final feeTxn = CreditTransaction(
        id: feeId,
        cardId: purchase.cardId,
        amount: processingFee,
        date: DateTime.now(),
        category: 'fee',
        type: 'processing_fee',
        status: 'active',
        note: 'EMI Processing Fee for ${purchase.id}',
      );
      await _creditRepo.insertTransaction(feeTxn);

      await _svc.appendLedger(
        LedgerTransaction(
          type: LedgerType.processing_fee,
          amount: processingFee,
          date: DateTime.now(),
          creditCardId: purchase.cardId,
          note: 'EMI Processing Fee for ${purchase.id}',
          referenceId: feeId,
        ),
      );
    }

    // EMI Math
    final double principal = purchase.amount;
    final double interestAmount = principal * (interestRate / 100) * (tenureMonths / 12);
    final double totalAmount = principal + interestAmount;
    final double emiAmount = totalAmount / tenureMonths;

    final emiId = const Uuid().v4();
    final emiPlan = CreditEMI(
      id: emiId,
      cardId: purchase.cardId,
      transactionId: purchase.id,
      principalAmount: principal,
      interestRate: interestRate,
      interestAmount: interestAmount,
      processingFee: processingFee,
      tenureMonths: tenureMonths,
      monthlyInstallment: emiAmount,
      startDate: DateTime.now(),
      paidMonths: 0,
      remainingMonths: tenureMonths,
      createdAt: DateTime.now(),
    );

    await _creditRepo.insertEMI(emiPlan);

    // Generate upcoming installments
    for (int i = 1; i <= tenureMonths; i++) {
      final now = DateTime.now();
      final dueDate = CreditCard.safeDate(now.year, now.month + i, now.day);
      final instId = const Uuid().v4();
      final inst = EMIInstallment(
        id: instId,
        emiId: emiId,
        dueDate: dueDate,
        amount: emiAmount,
        status: 'pending',
      );
      await _creditRepo.insertInstallment(inst);

      // Sync to Reminders
      await _reminderRepo.insertGlobalReminder(
        Reminder(
          id: 'emi_inst_$instId',
          type: ReminderType.emi,
          title: 'Credit EMI Due',
          linkedEntityId: instId,
          dueDate: dueDate,
          amount: emiAmount,
          isActive: true,
          status: ReminderStatus.upcoming,
          recordStatus: ReminderRecordStatus.pending,
          sourceType: ReminderSourceType.credit,
          sourceId: instId,
        ).toMap(),
      );

      // Ledger entries
      await _svc.appendLedger(
        LedgerTransaction(
          type: LedgerType.emi_installment,
          amount: emiAmount,
          date: dueDate,
          creditCardId: purchase.cardId,
          note: 'EMI Installment $i/$tenureMonths for ${purchase.category}',
          referenceId: purchase.id,
        ),
      );
    }
  }

  Future<void> updateCreditEMI({
    required String emiId,
    required int tenureMonths,
    required double interestRate,
  }) async {
    final oldEmi = await _creditRepo.getEMIById(emiId);
    if (oldEmi == null) return;

    // 2. Recalculate
    final double principal = oldEmi.principalAmount;
    final double interestAmount = principal * (interestRate / 100) * (tenureMonths / 12);
    final double totalAmount = principal + interestAmount;
    final double emiAmount = totalAmount / tenureMonths;

    final updatedEmi = CreditEMI(
      id: oldEmi.id,
      cardId: oldEmi.cardId,
      transactionId: oldEmi.transactionId,
      principalAmount: principal,
      interestRate: interestRate,
      interestAmount: interestAmount,
      processingFee: oldEmi.processingFee,
      tenureMonths: tenureMonths,
      monthlyInstallment: emiAmount,
      startDate: oldEmi.startDate,
      paidMonths: 0,
      remainingMonths: tenureMonths,
      createdAt: oldEmi.createdAt,
    );

    // 3. Update DB
    await _creditRepo.updateEMI(updatedEmi);

    // Clean up old installment reminders
    try {
      final oldInstallments = await _creditRepo.getInstallments(emiId);
      for (final inst in oldInstallments) {
        await _reminderRepo.deleteGlobalReminder('emi_inst_${inst.id}');
      }
    } catch (_) {}

    // 4. Regenerate Installments
    await _creditRepo.deleteInstallments(emiId);

    // 5. Update Ledger (Delete old emi_installments and add new ones)
    await _svc.removeLedger(
      referenceId: oldEmi.transactionId,
      type: LedgerType.emi_installment.name,
    );

    for (int i = 1; i <= tenureMonths; i++) {
      final dueDate = CreditCard.safeDate(
        oldEmi.startDate.year,
        oldEmi.startDate.month + i,
        oldEmi.startDate.day,
      );
      final instId = const Uuid().v4();
      final inst = EMIInstallment(
        id: instId,
        emiId: emiId,
        dueDate: dueDate,
        amount: emiAmount,
        status: 'pending',
      );
      await _creditRepo.insertInstallment(inst);

      await _svc.appendLedger(
        LedgerTransaction(
          type: LedgerType.emi_installment,
          amount: emiAmount,
          date: dueDate,
          creditCardId: oldEmi.cardId,
          note: 'EMI Installment $i/$tenureMonths (Updated)',
          referenceId: oldEmi.transactionId,
        ),
      );
    }
  }

  /// Locks transactions for a specific cycle and generates a statement
  Future<CardStatement> generateStatement(
    String cardId,
    DateTime startDate,
    DateTime endDate,
  ) async {
    final txns = await getTransactionsForCard(cardId);

    final unbilledTxns = txns.where((t) =>
              t.statementId == null &&
              t.status == 'active' &&
              t.date.isAfter(startDate.subtract(const Duration(seconds: 1))) &&
              t.date.isBefore(endDate.add(const Duration(seconds: 1))),
        ).toList();

    double statementAmount = 0.0;
    for (var t in unbilledTxns) {
      if (['purchase', 'emi_installment', 'processing_fee', 'interest_charge'].contains(t.type)) {
        statementAmount += t.amount;
      } else if (['payment', 'refund'].contains(t.type)) {
        statementAmount -= t.amount;
      }
    }

    // Minimum due logic (safe against statementAmount < 200)
    double minimumDue = statementAmount <= 0
        ? 0.0
        : (statementAmount <= 200.0
            ? statementAmount
            : (statementAmount * 0.05).clamp(200.0, statementAmount));

    final statement = CardStatement(
      id: const Uuid().v4(),
      cardId: cardId,
      startDate: startDate,
      endDate: endDate,
      statementAmount: statementAmount,
      minimumDue: minimumDue,
      generatedDate: DateTime.now(),
    );

    await _creditRepo.insertStatement(statement);
    await _creditRepo.assignTransactionsToStatement(
      statementId: statement.id,
      transactionIds: unbilledTxns.map((t) => t.id).toList(),
    );

    // Sync to Reminders
    await _reminderRepo.insertGlobalReminder(
      Reminder(
        id: 'credit_statement_${statement.id}',
        type: ReminderType.credit,
        title: 'Credit Card Bill Due',
        linkedEntityId: statement.id,
        dueDate: statement.endDate.add(const Duration(days: 20)),
        amount: statement.statementAmount,
        isActive: true,
        status: ReminderStatus.upcoming,
        recordStatus: ReminderRecordStatus.pending,
        sourceType: ReminderSourceType.credit,
        sourceId: statement.id,
      ).toMap(),
    );

    return statement;
  }
}
