import 'package:uuid/uuid.dart';
import '../../models/loan.dart';
import '../../models/loan_installment.dart';
import '../../models/reminder_model.dart';
import '../../data/repositories/loan_repo.dart';
import '../../data/repositories/ledger_repo.dart';
import '../../data/repositories/reminder_repo.dart';
import '../../models/ledger_transaction.dart';
import '../../services/notification_service_v2.dart';
import 'dart:math';

class LoanService {
  final LoanRepo _loanRepo;
  final LedgerRepo _ledgerRepo;
  final ReminderRepo _reminderRepo;

  LoanService({
    LoanRepo? loanRepo,
    LedgerRepo? ledgerRepo,
    ReminderRepo? reminderRepo,
  })  : _loanRepo = loanRepo ?? LoanRepo(),
        _ledgerRepo = ledgerRepo ?? LedgerRepo(),
        _reminderRepo = reminderRepo ?? ReminderRepo();

  /// Create a new Loan and generate its amortization schedule
  Future<void> createLoan({required Loan loan}) async {
    await _loanRepo.insertLoan(loan);

    // Ledger Record for disbursement
    await _ledgerRepo.insert(
      LedgerTransaction(
        type: LedgerType.loan_disbursement,
        amount: loan.principalAmount,
        date: loan.startDate,
        loanId: loan.id,
        note: 'Loan Disbursement: ${loan.name}',
        referenceId: loan.id,
      ),
    );

    // Generate amortization schedule
    await _generateAmortizationSchedule(loan);
    
    // Schedule first reminder (non-fatal — loan still created if this fails)
    try {
      final firstInstDate = DateTime(loan.startDate.year, loan.startDate.month + 1, loan.startDate.day);
      await NotificationServiceV2().scheduleNotification(
        id: loan.id.hashCode,
        title: "Loan Payment Due",
        body: "Your EMI of ₹${loan.monthlyInstallment.toStringAsFixed(0)} is due tomorrow",
        scheduledDate: firstInstDate.subtract(const Duration(days: 1)),
        category: 'loanDue',
      );
    } catch (e) {
      // Notification scheduling can fail if timezone not initialized — non-fatal
    }
  }

  /// Calculates the monthly payment for a loan using the standard formula
  double calculateMonthlyInstallment(double principal, double annualInterestRate, int tenureMonths) {
    if (annualInterestRate == 0) return principal / tenureMonths;
    final r = (annualInterestRate / 100) / 12; // monthly interest rate
    final p = principal;
    final n = tenureMonths;
    final emi = (p * r * pow(1 + r, n)) / (pow(1 + r, n) - 1);
    return emi;
  }

  Future<void> generateInstallments(String loanId, double amount, int months, DateTime startDate, double interest) async {
    await _generateAmortizationScheduleParams(loanId, amount, months, startDate, interest);
  }

  Future<void> _generateAmortizationSchedule(Loan loan) async {
    await _generateAmortizationScheduleParams(
      loan.id,
      loan.principalAmount,
      loan.tenureMonths,
      loan.startDate,
      loan.interestRate,
      type: loan.type,
      monthlyInstallment: loan.monthlyInstallment,
    );
  }

  Future<void> _generateAmortizationScheduleParams(
    String loanId, double principal, int tenureMonths, DateTime startDate, double interestRate, {
    LoanType type = LoanType.reducing,
    double? monthlyInstallment,
  }) async {
    final double emi = monthlyInstallment ?? calculateMonthlyInstallment(principal, interestRate, tenureMonths);
    final monthlyRate = (interestRate / 100) / 12;
    double balance = principal;

    for (int i = 1; i <= tenureMonths; i++) {
        double interestComp = 0;
        double principalComp = 0;
        double currentEmi = emi;

        switch (type) {
          case LoanType.reducing:
            interestComp = balance * monthlyRate;
            principalComp = emi - interestComp;
            if (i == tenureMonths) {
                principalComp = balance;
                currentEmi = principalComp + interestComp;
            }
            break;
          case LoanType.flat:
            final totalInterest = principal * (interestRate / 100) * (tenureMonths / 12);
            interestComp = totalInterest / tenureMonths;
            principalComp = principal / tenureMonths;
            break;
          case LoanType.interestOnly:
            interestComp = principal * (interestRate / 100) / 12;
            if (i == tenureMonths) {
              principalComp = principal;
              currentEmi = principal + interestComp;
            } else {
              principalComp = 0;
              currentEmi = interestComp;
            }
            break;
        }

        final installmentDate = DateTime(startDate.year, startDate.month + i, startDate.day);
        final installment = LoanInstallment(
            id: const Uuid().v4(),
            loanId: loanId,
            dueDate: installmentDate,
            amount: currentEmi,
            principalComponent: principalComp,
            interestComponent: interestComp,
            status: 'pending',
        );

        await _loanRepo.insertInstallment(installment);
        
        await _reminderRepo.insertGlobalReminder(
          Reminder(
            id: 'loan_inst_${installment.id}',
            type: ReminderType.loan,
            title: 'Loan EMI Due',
            linkedEntityId: installment.id,
            dueDate: installment.dueDate,
            amount: installment.amount,
            isActive: true,
            status: ReminderStatus.upcoming,
            recordStatus: ReminderRecordStatus.pending,
            sourceType: ReminderSourceType.loan,
            sourceId: installment.id,
          ).toMap(),
        );

        balance -= principalComp;
    }
  }

  Future<double> getRemainingBalance(String loanId) async {
    return _ledgerRepo.getLoanBalance(loanId);
  }

  Future<void> recordInstallmentPayment(String installmentId, {String? accountId, bool isManual = false}) async {
    final inst = await _loanRepo.getInstallmentById(installmentId);
    if (inst == null || inst.status == 'paid') return;

    // Update Installment
    await _loanRepo.updateInstallmentStatus(installmentId, 'paid', DateTime.now());

    // TODO: rewire reminder completion through the unified reminder flow.

    if (!isManual) {
      // Ledger Record (Loan Side - Reduces Debt)
      await _ledgerRepo.insert(
        LedgerTransaction(
          type: LedgerType.loan_payment,
          amount: inst.amount,
          date: DateTime.now(),
          loanId: inst.loanId,
          note: 'EMI Repayment: ${inst.id.substring(0, 8)}',
          referenceId: inst.id,
        ),
      );

      // Ledger Record (Bank Account Side - Reduces Balance)
      if (accountId != null) {
        await _ledgerRepo.insert(
          LedgerTransaction(
            type: LedgerType.expense,
            amount: inst.amount,
            date: DateTime.now(),
            accountId: accountId,
            note: 'Loan EMI: ${inst.id.substring(0, 8)}',
            referenceId: inst.id,
          ),
        );
      }
    }

    final loan = await _loanRepo.getLoanById(inst.loanId);
    if (loan != null) {
        final newPaid = loan.paidAmount + inst.principalComponent;
        String newStatus = loan.loanStatus;
        if (newPaid >= loan.principalAmount) {
            newStatus = 'closed';
        }

        await _loanRepo.updateLoanProgress(loan.id, newPaid, newStatus);

        if (newStatus == 'active') {
           final nextInst = await _loanRepo.getNextPendingInstallment(loan.id);
           if (nextInst != null) {
             await NotificationServiceV2().scheduleNotification(
               id: inst.loanId.hashCode,
               title: "Loan Payment Due",
               body: "Your EMI of ₹${inst.amount.toStringAsFixed(0)} is due tomorrow",
               scheduledDate: nextInst.dueDate.subtract(const Duration(days: 1)),
               category: 'loanDue',
             );
           }
        }
    }
  }
}
