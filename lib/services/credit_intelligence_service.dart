import '../models/ledger_transaction.dart';
import '../models/credit_card.dart';
import '../services/ledger_service.dart';

class CreditIntelligenceService {
  CreditIntelligenceService._();
  static final CreditIntelligenceService instance =
      CreditIntelligenceService._();

  /// Represents the calculated intelligence for a specific card
  Future<CreditIntelligenceData> getCardIntelligence(CreditCard card) async {
    final ledgerTxns = await LedgerService.instance.getTransactions(
      creditCardId: card.id,
    );

    // 1. Billing Cycle Detection
    final cycle = _calculateBillingCycle(card);

    // 2. Outstanding Balance (Corrected for Ledger-First)
    final double outstanding = await LedgerService.instance
        .getCreditOutstanding(card.id);

    // 3. Utilization
    final double utilization = card.creditLimit > 0
        ? (outstanding / card.creditLimit)
        : 0.0;

    // 4. Unbilled Amount (Transactions since last statement or start of cycle)
    final double unbilled = await _calculateUnbilled(card, ledgerTxns, cycle);

    // 5. Due Date Status
    final upcomingDueDays = _calculateUpcomingDueDays(card, outstanding);
    final dueStatus = _calculateDueStatus(card, outstanding);

    // 6. Smart Advice
    final advice = _generateAdvice(card, cycle, utilization, outstanding);

    // 7. EMI Suggestions
    final currentCycleTxns = ledgerTxns
        .where(
          (t) => t.date.isAfter(
            cycle.startDate.subtract(const Duration(seconds: 1)),
          ),
        )
        .toList();
    final emiSuggestions = _checkEmiTrigger(currentCycleTxns, utilization);

    return CreditIntelligenceData(
      cardId: card.id,
      cycle: cycle,
      utilization: utilization,
      outstanding: outstanding,
      unbilled: unbilled,
      lastStatementBalance: card.lastStatementBalance,
      upcomingDueDays: upcomingDueDays,
      dueStatus: dueStatus,
      advice: advice,
      emiSuggestions: emiSuggestions,
    );
  }

  BillingCycle _calculateBillingCycle(CreditCard card) {
    final now = DateTime.now();
    final int billingDay = card.billingDay;

    DateTime start;
    DateTime end;

    if (now.day >= billingDay) {
      start = DateTime(now.year, now.month, billingDay);
      end = DateTime(
        now.year,
        now.month + 1,
        billingDay,
      ).subtract(const Duration(days: 1));
    } else {
      start = DateTime(now.year, now.month - 1, billingDay);
      end = DateTime(
        now.year,
        now.month,
        billingDay,
      ).subtract(const Duration(days: 1));
    }

    final daysRemaining = end.difference(now).inDays;

    return BillingCycle(
      startDate: start,
      endDate: end,
      daysRemaining: daysRemaining,
    );
  }

  Future<double> _calculateUnbilled(
    CreditCard card,
    List<LedgerTransaction> txns,
    BillingCycle cycle,
  ) async {
    // Sum all txns in current cycle that don't belong to a statement yet
    // For simplicity, we filter by date >= cycle.startDate
    double total = 0;
    for (var t in txns) {
      if (t.date.isAfter(
        cycle.startDate.subtract(const Duration(seconds: 1)),
      )) {
        if ([
          LedgerType.credit_purchase,
          LedgerType.emi_installment,
          LedgerType.processing_fee,
          LedgerType.interest_charge,
        ].contains(t.type)) {
          total += t.amount;
        } else if ([
          LedgerType.credit_payment,
          LedgerType.refund,
        ].contains(t.type)) {
          total -= t.amount;
        }
      }
    }
    return total;
  }

  DueStatus _calculateDueStatus(CreditCard card, double outstanding) {
    if (outstanding <= 0) return DueStatus.safe;

    final now = DateTime.now();
    final int dueDay = card.dueDay;

    // Find next due date
    DateTime nextDue;
    if (now.day <= dueDay) {
      nextDue = DateTime(now.year, now.month, dueDay);
    } else {
      nextDue = DateTime(now.year, now.month + 1, dueDay);
    }

    final daysLeft = nextDue.difference(now).inDays;

    if (daysLeft <= 2) return DueStatus.critical;
    if (daysLeft <= 5) return DueStatus.warning;
    return DueStatus.safe;
  }

  int? _calculateUpcomingDueDays(CreditCard card, double outstanding) {
    if (outstanding <= 0) return null;

    final now = DateTime.now();
    final dueDay = card.dueDay;

    final nextDue = now.day <= dueDay
        ? DateTime(now.year, now.month, dueDay)
        : DateTime(now.year, now.month + 1, dueDay);

    return nextDue.difference(now).inDays;
  }

  List<String> _generateAdvice(
    CreditCard card,
    BillingCycle cycle,
    double utilization,
    double outstanding,
  ) {
    final List<String> advice = [];

    if (utilization > 0.7) {
      advice.add('High utilization — consider making a partial payment now.');
    } else if (utilization > 0.3) {
      advice.add('Moderate usage. Keep spend below 30% for best credit score.');
    } else {
      advice.add('Excellent utilization! You are in the green zone.');
    }

    if (cycle.daysRemaining <= 3 && utilization > 0.5) {
      advice.add(
        'Only ${cycle.daysRemaining} days until next bill. Wait if planning a large purchase.',
      );
    }

    final safeToSpend = (card.creditLimit * 0.3) - card.outstanding;
    if (safeToSpend > 0) {
      advice.add(
        'You can safely spend ₹${safeToSpend.round()} more while staying below 30% utilization.',
      );
    }

    return advice;
  }

  List<EmiSuggestion> _checkEmiTrigger(
    List<LedgerTransaction> txns,
    double utilization,
  ) {
    final suggestions = <EmiSuggestion>[];

    // Trigger on large transactions (> 5000)
    for (var t in txns) {
      if (t.amount >= 5000 &&
          t.type != LedgerType.credit_payment &&
          t.type != LedgerType.emi_installment) {
        suggestions.add(
          EmiSuggestion(
            transactionId: t.id?.toString() ?? '',
            amount: t.amount,
            reason: 'Large purchase detected',
          ),
        );
      }
    }

    if (utilization > 0.75) {
      suggestions.add(
        EmiSuggestion(
          transactionId: 'utilization_alert',
          amount: 0,
          reason: 'High utilization — convert existing bills to EMI?',
        ),
      );
    }

    return suggestions;
  }
}

class CreditIntelligenceData {
  final String cardId;
  final BillingCycle cycle;
  final double utilization; // 0.0 to 1.0
  final double outstanding;
  final double unbilled;
  final double lastStatementBalance;
  final int? upcomingDueDays;
  final DueStatus dueStatus;
  final List<String> advice;
  final List<EmiSuggestion> emiSuggestions;
  final int? rewardPoints;

  CreditIntelligenceData({
    required this.cardId,
    required this.cycle,
    required this.utilization,
    required this.outstanding,
    required this.unbilled,
    required this.lastStatementBalance,
    this.upcomingDueDays,
    required this.dueStatus,
    required this.advice,
    required this.emiSuggestions,
    this.rewardPoints,
  });

  double get unbilledAmount => unbilled;
  bool get isOverlimit => utilization > 1.0;
}

class BillingCycle {
  final DateTime startDate;
  final DateTime endDate;
  final int daysRemaining;

  BillingCycle({
    required this.startDate,
    required this.endDate,
    required this.daysRemaining,
  });
}

enum DueStatus { safe, warning, critical }

class EmiSuggestion {
  final String transactionId;
  final double amount;
  final String reason;

  EmiSuggestion({
    required this.transactionId,
    required this.amount,
    required this.reason,
  });
}
