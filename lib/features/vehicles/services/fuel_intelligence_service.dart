import '../../../models/vehicle.dart';
import '../../../services/notification_service_v2.dart';

/// Mileage display rule: only show when BOTH prev and current entries were full tanks.
/// All calculations happen internally regardless of tank type.

enum InsightSeverity { info, warning, alert }

class FuelInsight {
  final InsightSeverity severity;
  final String title;
  final String message;
  final String icon;

  const FuelInsight({
    required this.severity,
    required this.title,
    required this.message,
    required this.icon,
  });
}

class FuelPrediction {
  final double nextFillCost;
  final double monthlyEstimate;
  final double? nextFillLitres;
  final int? daysToNextFill;

  const FuelPrediction({
    required this.nextFillCost,
    required this.monthlyEstimate,
    this.nextFillLitres,
    this.daysToNextFill,
  });
}

class MonthlyData {
  final String label; // "Jan 2025"
  final double cost;
  final double km;
  final double? avgMileage;
  final double? costPerKm;
  final int fillUps;

  const MonthlyData({
    required this.label,
    required this.cost,
    required this.km,
    this.avgMileage,
    this.costPerKm,
    required this.fillUps,
  });
}

class ServiceAlert {
  final int remainingKm;
  final bool isOverdue;
  final String message;

  const ServiceAlert({
    required this.remainingKm,
    required this.isOverdue,
    required this.message,
  });
}

class FuelIntelligenceService {
  FuelIntelligenceService._();
  static final FuelIntelligenceService instance = FuelIntelligenceService._();

  // ─────────────────────── Mileage Engine ────────────────────────

  /// Core rule: only compute displayable mileage for full→full tank pairs.
  /// Returns null if either entry is a partial fill.
  double? getDisplayedEfficiency(FuelLog prev, FuelLog current) {
    if (!prev.isFullTank || !current.isFullTank) return null;
    final km = current.odometer - prev.odometer;
    if (km <= 0 || current.litres <= 0) return null;
    return km / current.litres;
  }

  /// Always-computed internal mileage (regardless of full/partial).
  double? computeInternalEfficiency(FuelLog prev, FuelLog current) {
    final km = current.odometer - prev.odometer;
    if (km <= 0 || current.litres <= 0) return null;
    return km / current.litres;
  }

  /// Recompute efficiency for all logs in sorted order.
  /// Returns a new list with `efficiency` field correctly set.
  List<FuelLog> recomputeEfficiencies(List<FuelLog> logs) {
    // Sort ascending by date
    final sorted = [...logs]..sort((a, b) => a.date.compareTo(b.date));
    final result = <FuelLog>[];

    for (int i = 0; i < sorted.length; i++) {
      if (i == 0) {
        result.add(sorted[i]); // first entry — no efficiency
        continue;
      }
      final prev = sorted[i - 1];
      final current = sorted[i];
      final eff = getDisplayedEfficiency(prev, current);
      result.add(
        FuelLog(
          id: current.id,
          vehicleId: current.vehicleId,
          odometer: current.odometer,
          litres: current.litres,
          pricePerLitre: current.pricePerLitre,
          totalCost: current.totalCost,
          efficiency: eff,
          date: current.date,
          location: current.location,
          isFullTank: current.isFullTank,
          fuelType: current.fuelType,
          notes: current.notes,
        ),
      );
    }
    return result;
  }

  // ─────────────────────── Stats Helpers ─────────────────────────

  double getAvgMileage(List<FuelLog> logs) {
    final withEff = logs.where((l) => l.efficiency != null).toList();
    if (withEff.isEmpty) return 0;
    return withEff.fold(0.0, (s, l) => s + l.efficiency!) / withEff.length;
  }

  double getTotalKm(List<FuelLog> logs) {
    if (logs.length < 2) return 0;
    final sorted = [...logs]..sort((a, b) => a.odometer.compareTo(b.odometer));
    return sorted.last.odometer - sorted.first.odometer;
  }

  double? getCostPerKm(List<FuelLog> logs) {
    final totalKm = getTotalKm(logs);
    if (totalKm <= 0) return null;
    final totalCost = logs.fold(0.0, (s, l) => s + l.totalCost);
    return totalCost / totalKm;
  }

  // ─────────────────────── Smart Fuel Intelligence ────────────────────────

  List<FuelLog> cleanLogs(List<FuelLog> logs) {
    if (logs.isEmpty) return [];

    // Filter basics: odometer > 0, litres > 0
    final baseValid = logs
        .where((l) => l.odometer > 0 && l.litres > 0)
        .toList();
    if (baseValid.isEmpty) return [];

    final sorted = [...baseValid]
      ..sort((a, b) => a.odometer.compareTo(b.odometer));
    final valid = <FuelLog>[];

    for (int i = 0; i < sorted.length; i++) {
      final l = sorted[i];
      if (valid.isNotEmpty) {
        final dist = l.odometer - valid.last.odometer;
        if (dist < 5) continue; // Spec: ignore distance < 5 km
      }
      valid.add(l);
    }
    return valid;
  }

  double? getLastFullTankMileage(List<FuelLog> logs) {
    final cleaned = cleanLogs(logs);
    final fullLogs = cleaned.where((l) => l.isFullTank).toList();
    if (fullLogs.length < 2) return null;

    final last = fullLogs.last;
    final prev = fullLogs[fullLogs.length - 2];

    final distance = last.odometer - prev.odometer;
    if (distance <= 0) return null;

    final idxStart = cleaned.indexOf(prev);
    final idxEnd = cleaned.indexOf(last);

    double fuelBetween = 0;
    for (int i = idxStart + 1; i <= idxEnd; i++) {
      fuelBetween += cleaned[i].litres;
    }

    if (fuelBetween <= 0) return null;
    return distance / fuelBetween;
  }

  List<double> getRollingMileageList(List<FuelLog> logs) {
    final cleaned = cleanLogs(logs);
    final result = <double>[];
    if (cleaned.length < 2) return result;

    for (int i = 1; i < cleaned.length; i++) {
      final dist = cleaned[i].odometer - cleaned[i - 1].odometer;
      final fuel = cleaned[i].litres;
      if (dist > 5 && fuel > 0) {
        result.add(dist / fuel);
      }
    }
    return result;
  }

  double? getSmartAverageMileage(List<FuelLog> logs) {
    final rolling = getRollingMileageList(logs);
    if (rolling.isEmpty) return null;

    final rawAvg = rolling.reduce((a, b) => a + b) / rolling.length;

    // Spec: flag spike if lastMileage > avgMileage * 1.5 -> drop from average
    final filtered = rolling.where((m) => m <= rawAvg * 1.5).toList();
    if (filtered.isEmpty) return rawAvg;

    return filtered.reduce((a, b) => a + b) / filtered.length;
  }

  double? getOverallMileage(List<FuelLog> logs) {
    final cleaned = cleanLogs(logs);
    if (cleaned.length < 2) return null;

    final distance = cleaned.last.odometer - cleaned.first.odometer;
    double totalFuel = 0;
    // skip first log's litres as they belong to previous unknown distance
    for (int i = 1; i < cleaned.length; i++) {
      totalFuel += cleaned[i].litres;
    }

    if (totalFuel <= 0) return null;
    return distance / totalFuel;
  }

  Future<void> detectMileageDrop(List<FuelLog> logs) async {
    final cleaned = cleanLogs(logs);
    if (cleaned.length < 2) return;

    final lastMileage =
        getLastFullTankMileage(cleaned) ??
        (getRollingMileageList(cleaned).isNotEmpty
            ? getRollingMileageList(cleaned).last
            : null);
    if (lastMileage == null) return;

    final avgMileage = getSmartAverageMileage(cleaned);
    if (avgMileage == null) return;

    if (lastMileage < avgMileage * 0.8) {
      final dropPct = ((avgMileage - lastMileage) / avgMileage * 100).round();
      await NotificationServiceV2().showInstant(
        title: 'Efficiency Drop',
        body: 'Fuel efficiency dropped by $dropPct%',
      );
    }
  }

  // ─────────────────────── AI Prediction ─────────────────────────

  FuelPrediction? predictNextFill(List<FuelLog> logs) {
    if (logs.length < 2) return null;

    final sorted = [...logs]..sort((a, b) => a.date.compareTo(b.date));

    // Weighted moving average: more recent = more weight
    final recent = sorted.reversed.take(5).toList();
    double totalWeight = 0;
    double weightedCost = 0;
    double weightedLitres = 0;

    for (int i = 0; i < recent.length; i++) {
      final weight = (recent.length - i)
          .toDouble(); // most recent = highest weight
      weightedCost += recent[i].totalCost * weight;
      weightedLitres += recent[i].litres * weight;
      totalWeight += weight;
    }

    final nextCost = weightedCost / totalWeight;
    final nextLitres = weightedLitres / totalWeight;

    // Avg days between fills
    int avgDays = 0;
    if (sorted.length >= 2) {
      final totalDays = sorted.last.date.difference(sorted.first.date).inDays;
      avgDays = (totalDays / (sorted.length - 1)).round();
    }

    // Monthly cost extrapolation
    double monthlyEstimate = 0;
    if (avgDays > 0) {
      final fillsPerMonth = 30.0 / avgDays;
      monthlyEstimate = nextCost * fillsPerMonth;
    } else {
      // Fallback: simple avg per month
      final firstDate = sorted.first.date;
      final lastDate = sorted.last.date;
      final months = (lastDate.difference(firstDate).inDays / 30.0).clamp(
        1.0,
        double.infinity,
      );
      monthlyEstimate = logs.fold(0.0, (s, l) => s + l.totalCost) / months;
    }

    return FuelPrediction(
      nextFillCost: nextCost,
      monthlyEstimate: monthlyEstimate,
      nextFillLitres: nextLitres,
      daysToNextFill: avgDays > 0 ? avgDays : null,
    );
  }

  // ─────────────────────── Driving Behavior Insights ─────────────

  List<FuelInsight> generateFuelInsights(List<FuelLog> logs) {
    if (logs.length < 2) return [];

    final cleaned = cleanLogs(logs);
    if (cleaned.length < 2) return [];

    final sorted = [...cleaned]..sort((a, b) => a.date.compareTo(b.date));
    final insights = <FuelInsight>[];

    // 1. Mileage Drop Context (Strict Rules applied)
    final avgMileage = getSmartAverageMileage(cleaned);
    final lastMileage =
        getLastFullTankMileage(cleaned) ??
        (getRollingMileageList(cleaned).isNotEmpty
            ? getRollingMileageList(cleaned).last
            : null);

    if (avgMileage != null && lastMileage != null) {
      if (lastMileage < (avgMileage * 0.8)) {
        final dropPct = ((avgMileage - lastMileage) / avgMileage * 100).round();
        insights.add(
          FuelInsight(
            severity: InsightSeverity.alert,
            title: 'Efficiency Warning',
            message:
                'Your mileage dropped by $dropPct% compared to your average. Check tyre pressure or riding style.',
            icon: '📉',
          ),
        );
      } else if (lastMileage > (avgMileage * 1.1)) {
        final incPct = ((lastMileage - avgMileage) / avgMileage * 100).round();
        insights.add(
          FuelInsight(
            severity: InsightSeverity.info,
            title: 'Great Efficiency',
            message:
                'Your mileage improved by $incPct% compared to your average.',
            icon: '📈',
          ),
        );
      }
    }

    // 2. Cost Increase Context
    final now = DateTime.now();
    final thisMonthLogs = sorted
        .where((l) => l.date.year == now.year && l.date.month == now.month)
        .toList();
    final lastMonthLogs = sorted
        .where(
          (l) =>
              l.date.year == (now.month == 1 ? now.year - 1 : now.year) &&
              l.date.month == (now.month == 1 ? 12 : now.month - 1),
        )
        .toList();

    if (thisMonthLogs.isNotEmpty && lastMonthLogs.isNotEmpty) {
      final thisMonthCost = thisMonthLogs.fold(0.0, (s, l) => s + l.totalCost);
      final lastMonthCost = lastMonthLogs.fold(0.0, (s, l) => s + l.totalCost);

      if (thisMonthCost > lastMonthCost * 1.2) {
        final diff = thisMonthCost - lastMonthCost;
        insights.add(
          FuelInsight(
            severity: InsightSeverity.warning,
            title: 'Cost Increase',
            message:
                'Fuel cost increased by ₹${diff.toStringAsFixed(0)} this month compared to last month.',
            icon: '💸',
          ),
        );
      }
    }

    // 3. Unusual Refuel Pattern Context
    if (sorted.length >= 4) {
      final totalDays = sorted.last.date.difference(sorted.first.date).inDays;
      final avgInterval = totalDays / (sorted.length - 1);
      final recentInterval = sorted.last.date
          .difference(sorted[sorted.length - 2].date)
          .inDays;

      if (avgInterval > 0 && recentInterval < (avgInterval * 0.5)) {
        insights.add(
          FuelInsight(
            severity: InsightSeverity.warning,
            title: 'Unusual Pattern',
            message:
                'You are refueling more frequently than usual (~$recentInterval days vs average ${avgInterval.round()} days).',
            icon: '⛽',
          ),
        );
      }
    }

    return insights;
  }

  // ─────────────────────── Service Alert ─────────────────────────

  ServiceAlert? getServiceAlert(Vehicle vehicle, double currentOdo) {
    final interval = vehicle.serviceIntervalKm;
    final lastServiceOdo = vehicle.lastServiceOdometer;
    if (interval == null || lastServiceOdo == null) return null;

    final kmSinceService = currentOdo - lastServiceOdo;
    final remaining = (interval - kmSinceService).round();

    return ServiceAlert(
      remainingKm: remaining,
      isOverdue: remaining <= 0,
      message: remaining <= 0
          ? 'Service is overdue by ${(-remaining).abs()} km!'
          : remaining <= 500
          ? 'Service due in $remaining km — schedule soon'
          : 'Service due in $remaining km',
    );
  }

  // ─────────────────────── Monthly Breakdown ─────────────────────

  List<MonthlyData> getMonthlyBreakdown(List<FuelLog> logs) {
    final Map<String, List<FuelLog>> monthly = {};
    for (final log in logs) {
      final key =
          '${log.date.year}-${log.date.month.toString().padLeft(2, '0')}';
      monthly.putIfAbsent(key, () => []).add(log);
    }

    final result = monthly.entries.map((e) {
      final mLogs = e.value..sort((a, b) => a.date.compareTo(b.date));
      final cost = mLogs.fold(0.0, (s, l) => s + l.totalCost);
      double km = 0;
      if (mLogs.length >= 2) {
        km = mLogs.last.odometer - mLogs.first.odometer;
      }
      final withEff = mLogs.where((l) => l.efficiency != null).toList();
      final avgMileage = withEff.isEmpty
          ? null
          : withEff.fold(0.0, (s, l) => s + l.efficiency!) / withEff.length;
      final costPerKm = km > 0 ? cost / km : null;
      final parts = e.key.split('-');
      final dt = DateTime(int.parse(parts[0]), int.parse(parts[1]));
      final label = _monthLabel(dt);

      return MonthlyData(
        label: label,
        cost: cost,
        km: km,
        avgMileage: avgMileage,
        costPerKm: costPerKm,
        fillUps: mLogs.length,
      );
    }).toList();

    result.sort((a, b) => a.label.compareTo(b.label));
    return result;
  }

  String _monthLabel(DateTime dt) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.year}';
  }
}
