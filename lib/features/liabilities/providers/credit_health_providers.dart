import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/credit_intelligence_service.dart';
import '../../dashboard/insights_providers.dart';
import 'liabilities_providers.dart';

// ── Aggregated Credit Health ──────────────────────────────────────────────

/// Combined credit health across ALL cards.
class CreditHealthSummary {
  final double totalOutstanding;
  final double totalLimit;
  final double totalAvailable;
  final double utilizationPct;
  final List<CardDueInfo> upcomingDues;
  final double estimatedInterest;
  final int cardsAtRisk; // utilization > 80%

  const CreditHealthSummary({
    required this.totalOutstanding,
    required this.totalLimit,
    required this.totalAvailable,
    required this.utilizationPct,
    required this.upcomingDues,
    required this.estimatedInterest,
    required this.cardsAtRisk,
  });
}

class CardDueInfo {
  final String cardName;
  final String bank;
  final double outstanding;
  final double minimumDue;
  final int daysUntilDue;
  final DueStatus status;

  const CardDueInfo({
    required this.cardName,
    required this.bank,
    required this.outstanding,
    required this.minimumDue,
    required this.daysUntilDue,
    required this.status,
  });
}

final creditHealthProvider = FutureProvider<CreditHealthSummary>((ref) async {
  final cards = await ref.watch(creditCardsProvider.future);
  if (cards.isEmpty) {
    return const CreditHealthSummary(
      totalOutstanding: 0,
      totalLimit: 0,
      totalAvailable: 0,
      utilizationPct: 0,
      upcomingDues: [],
      estimatedInterest: 0,
      cardsAtRisk: 0,
    );
  }

  double totalOutstanding = 0;
  double totalLimit = 0;
  int cardsAtRisk = 0;
  double estimatedInterest = 0;
  final dues = <CardDueInfo>[];

  for (final card in cards) {
    final outstanding = card.usedAmount;
    totalOutstanding += outstanding;
    totalLimit += card.limitAmount;

    final utilPct = card.limitAmount > 0
        ? outstanding / card.limitAmount
        : 0.0;
    if (utilPct > 0.8) cardsAtRisk++;

    // Estimated monthly interest (typical 3.5% monthly / 42% APR)
    if (outstanding > 0) {
      estimatedInterest += outstanding * 0.035;
    }

    if (outstanding > 0) {
      final daysLeft = card.daysUntilDue;
      final DueStatus status;
      if (daysLeft <= 2) {
        status = DueStatus.critical;
      } else if (daysLeft <= 5) {
        status = DueStatus.warning;
      } else {
        status = DueStatus.safe;
      }

      dues.add(CardDueInfo(
        cardName: card.name,
        bank: card.bank,
        outstanding: outstanding,
        minimumDue: (outstanding * 0.05).clamp(100, outstanding),
        daysUntilDue: daysLeft,
        status: status,
      ));
    }
  }

  dues.sort((a, b) => a.daysUntilDue.compareTo(b.daysUntilDue));

  return CreditHealthSummary(
    totalOutstanding: totalOutstanding,
    totalLimit: totalLimit,
    totalAvailable: (totalLimit - totalOutstanding).clamp(0, double.infinity),
    utilizationPct: totalLimit > 0
        ? (totalOutstanding / totalLimit * 100).clamp(0, 100)
        : 0,
    upcomingDues: dues,
    estimatedInterest: estimatedInterest,
    cardsAtRisk: cardsAtRisk,
  );
});

// ── EMI Load ─────────────────────────────────────────────────────────────

class EmiLoadSummary {
  final double totalMonthlyEmi;
  final List<EmiItem> activeEmis;
  final int totalActive;

  const EmiLoadSummary({
    required this.totalMonthlyEmi,
    required this.activeEmis,
    required this.totalActive,
  });
}

class EmiItem {
  final String name;
  final String bank;
  final double monthlyAmount;
  final int paidMonths;
  final int totalMonths;
  final double remainingAmount;

  const EmiItem({
    required this.name,
    required this.bank,
    required this.monthlyAmount,
    required this.paidMonths,
    required this.totalMonths,
    required this.remainingAmount,
  });

  double get progressPct =>
      totalMonths > 0 ? paidMonths / totalMonths : 0;
}

final emiLoadProvider = FutureProvider<EmiLoadSummary>((ref) async {
  final loans = await ref.watch(loansProvider.future);
  final activeLoans = loans.where((l) => l.loanStatus == 'active').toList();

  double totalEmi = 0;
  final items = <EmiItem>[];

  for (final loan in activeLoans) {
    totalEmi += loan.monthlyInstallment;

    final paidMonths = loan.monthlyInstallment > 0
        ? (loan.paidAmount / loan.monthlyInstallment).floor()
        : 0;

    items.add(EmiItem(
      name: loan.name,
      bank: loan.bank,
      monthlyAmount: loan.monthlyInstallment,
      paidMonths: paidMonths,
      totalMonths: loan.tenureMonths,
      remainingAmount: (loan.total - loan.paidAmount).clamp(0, double.infinity),
    ));
  }

  return EmiLoadSummary(
    totalMonthlyEmi: totalEmi,
    activeEmis: items,
    totalActive: items.length,
  );
});

// ── Financial Pressure ───────────────────────────────────────────────────

enum PressureLevel { healthy, moderate, high }

class FinancialPressure {
  final double monthlyObligations; // EMI + min card dues
  final double monthlyIncome;
  final double pressureRatio; // obligations / income
  final PressureLevel level;

  const FinancialPressure({
    required this.monthlyObligations,
    required this.monthlyIncome,
    required this.pressureRatio,
    required this.level,
  });
}

final financialPressureProvider = FutureProvider<FinancialPressure>((ref) async {
  final emiLoad = await ref.watch(emiLoadProvider.future);
  final creditHealth = await ref.watch(creditHealthProvider.future);
  final monthStats = await ref.watch(currentMonthStatsProvider.future);

  final monthlyIncome = monthStats?.income ?? 0;
  // Obligations = total EMIs + minimum dues on cards
  final minCardDue = creditHealth.upcomingDues.fold<double>(
    0,
    (sum, d) => sum + d.minimumDue,
  );
  final obligations = emiLoad.totalMonthlyEmi + minCardDue;

  final ratio = monthlyIncome > 0 ? obligations / monthlyIncome : 0.0;

  final PressureLevel level;
  if (ratio < 0.3) {
    level = PressureLevel.healthy;
  } else if (ratio < 0.6) {
    level = PressureLevel.moderate;
  } else {
    level = PressureLevel.high;
  }

  return FinancialPressure(
    monthlyObligations: obligations,
    monthlyIncome: monthlyIncome,
    pressureRatio: ratio,
    level: level,
  );
});

// ── Upcoming Dues (next 7 days) ──────────────────────────────────────────

final upcomingDuesProvider = FutureProvider<List<CardDueInfo>>((ref) async {
  final health = await ref.watch(creditHealthProvider.future);
  return health.upcomingDues
      .where((d) => d.daysUntilDue <= 7)
      .toList();
});
