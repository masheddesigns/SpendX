import 'package:intl/intl.dart';

import '../models/company.dart';
import '../models/salary_contract.dart';
import '../models/salary_payment.dart';
import 'salary_service.dart';

class SalaryOverviewInsight {
  const SalaryOverviewInsight({
    required this.totalEarned,
    required this.totalPending,
    required this.totalPartial,
    required this.totalDelayedMonths,
  });

  final double totalEarned;
  final double totalPending;
  final double totalPartial;
  final int totalDelayedMonths;
}

class SalaryGrowthInsight {
  const SalaryGrowthInsight({
    required this.baseSalary,
    required this.currentSalary,
    required this.growthPercent,
  });

  final double baseSalary;
  final double currentSalary;
  final double growthPercent;
}

class SalaryReliabilityInsight {
  const SalaryReliabilityInsight({
    required this.score,
    required this.delayCount,
    required this.partialCount,
  });

  final double score;
  final int delayCount;
  final int partialCount;
}

class SalaryDelayInsight {
  const SalaryDelayInsight({
    required this.averageDelayDays,
    required this.maxDelayDays,
    required this.mostDelayedMonth,
  });

  final double averageDelayDays;
  final int maxDelayDays;
  final String mostDelayedMonth;
}

class IncrementTimelineItem {
  const IncrementTimelineItem({required this.label, required this.amount});

  final String label;
  final double amount;
}

class SalaryInsightsService {
  SalaryInsightsService._();
  static final instance = SalaryInsightsService._();

  Future<SalaryOverviewInsight> getSalarySummary(Company company) async {
    final payments = await SalaryService.instance.getPaymentsForCompany(
      company.id,
    );
    final totalEarned = payments.fold<double>(
      0,
      (sum, item) => sum + item.amountReceived,
    );
    final totalPending = payments.fold<double>(
      0,
      (sum, item) => sum + item.remainingAmount,
    );
    final totalPartial = payments
        .where((item) => item.status == SalaryPaymentStatus.partial)
        .fold<double>(0, (sum, item) => sum + item.remainingAmount);
    final totalDelayedMonths = payments
        .where((item) => item.status == SalaryPaymentStatus.delayed)
        .length;

    return SalaryOverviewInsight(
      totalEarned: totalEarned,
      totalPending: totalPending,
      totalPartial: totalPartial,
      totalDelayedMonths: totalDelayedMonths,
    );
  }

  Future<SalaryGrowthInsight> getSalaryGrowth(
    SalaryContract contract,
    Company company,
  ) async {
    final payments = await SalaryService.instance.getPaymentsForCompany(
      company.id,
    );
    final currentSalary = payments.isEmpty
        ? contract.baseSalary
        : payments
              .map((item) => item.totalAmount)
              .reduce((a, b) => a > b ? a : b);
    final growthPercent = contract.baseSalary == 0
        ? 0.0
        : ((currentSalary - contract.baseSalary) / contract.baseSalary) * 100;

    return SalaryGrowthInsight(
      baseSalary: contract.baseSalary,
      currentSalary: currentSalary,
      growthPercent: growthPercent,
    );
  }

  Future<SalaryReliabilityInsight> getSalaryReliability(Company company) async {
    final payments = await SalaryService.instance.getPaymentsForCompany(
      company.id,
    );
    final delayCount = payments
        .where((item) => item.status == SalaryPaymentStatus.delayed)
        .length;
    final partialCount = payments
        .where((item) => item.status == SalaryPaymentStatus.partial)
        .length;
    final score = (100 - (delayCount * 5) - (partialCount * 3))
        .clamp(0, 100)
        .toDouble();

    return SalaryReliabilityInsight(
      score: score,
      delayCount: delayCount,
      partialCount: partialCount,
    );
  }

  Future<List<IncrementTimelineItem>> getIncrementTimeline(
    Company company,
  ) async {
    final payments = await SalaryService.instance.getPaymentsForCompany(
      company.id,
    );
    final sorted = [...payments]..sort((a, b) => a.month.compareTo(b.month));
    final timeline = <IncrementTimelineItem>[];
    double? lastAmount;
    for (final payment in sorted) {
      if (lastAmount == null || payment.totalAmount != lastAmount) {
        timeline.add(
          IncrementTimelineItem(
            label: DateFormat('MMM').format(payment.month),
            amount: payment.totalAmount,
          ),
        );
        lastAmount = payment.totalAmount;
      }
    }
    return timeline.take(6).toList();
  }

  Future<SalaryDelayInsight> getDelayStats(Company company) async {
    final delayed = (await SalaryService.instance.getPaymentsForCompany(
      company.id,
    )).where((item) => item.status == SalaryPaymentStatus.delayed).toList();
    if (delayed.isEmpty) {
      return const SalaryDelayInsight(
        averageDelayDays: 0,
        maxDelayDays: 0,
        mostDelayedMonth: '-',
      );
    }

    final maxItem = delayed.reduce(
      (a, b) => a.delayedByDays >= b.delayedByDays ? a : b,
    );
    final avg =
        delayed.fold<int>(0, (sum, item) => sum + item.delayedByDays) /
        delayed.length;

    return SalaryDelayInsight(
      averageDelayDays: avg,
      maxDelayDays: maxItem.delayedByDays,
      mostDelayedMonth: DateFormat('MMM').format(maxItem.month),
    );
  }
}
