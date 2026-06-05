import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/transaction.dart';
import 'merchant_normalizer.dart';

/// Per-call rejection-log sampler. analyze() can fire many rejection
/// logs in one pass when scanning a long history; sampling at 20%
/// keeps the signal visible without flooding the debug console
/// during bulk imports. Release builds drop debugPrint regardless.
final math.Random _recurringLogSampler = math.Random();
const double _recurringLogSampleRate = 0.2;
bool get _logRecurring =>
    _recurringLogSampler.nextDouble() < _recurringLogSampleRate;

/// How often a recurring pattern repeats. Coarse buckets — finer
/// granularity isn't useful for user-facing labels.
enum RecurringPeriodicity { daily, weekly, monthly, irregular }

extension RecurringPeriodicityX on RecurringPeriodicity {
  String get label => switch (this) {
        RecurringPeriodicity.daily => 'Daily',
        RecurringPeriodicity.weekly => 'Weekly',
        RecurringPeriodicity.monthly => 'Monthly',
        RecurringPeriodicity.irregular => 'Irregular',
      };
}

/// A merchant–interval pattern detected in transaction history.
///
/// `confidence` is a single rolled-up score in [0, 1]:
///   +0.4 if [occurrences] ≥ 3
///   +0.4 if intervals are stable (every interval within ±3 days of avg)
///   +0.2 if amount coefficient of variation < 10%
///
/// Filter by `confidence ≥ 0.6` for "show in UI" — that requires at
/// minimum the count + one of (interval stability, amount stability).
class RecurringPattern {
  /// Lowercased + trimmed merchant identity used for grouping.
  final String merchantKey;

  /// Original casing — best to display this to the user.
  final String displayMerchant;

  /// 'income' or 'expense' — whichever type dominates this group.
  /// A salary credit pattern and a Netflix debit pattern look identical
  /// to the interval logic; the type tells the UI which lens to use.
  final String type;

  final double averageAmount;

  /// Coefficient of variation (stdev/mean) of amounts. ≥ 0 always.
  /// 0 → fixed amount; 0.05 → ±5% noise; 0.5 → highly variable.
  final double amountCv;

  /// Average gap between consecutive transactions.
  final Duration interval;
  final RecurringPeriodicity periodicity;

  final DateTime lastSeen;

  /// Naive projection: last seen + average interval. Useful for
  /// "Next expected: May 28" reminders.
  final DateTime nextExpected;

  final int occurrences;

  /// Rolled-up confidence in [0, 1]; rounded to 2 decimals so display
  /// is stable across recomputes.
  final double confidence;

  const RecurringPattern({
    required this.merchantKey,
    required this.displayMerchant,
    required this.type,
    required this.averageAmount,
    required this.amountCv,
    required this.interval,
    required this.periodicity,
    required this.lastSeen,
    required this.nextExpected,
    required this.occurrences,
    required this.confidence,
  });
}

/// Pure analyzer — no I/O, no caching.
///
/// `RecurringDetector.analyze(transactions)` returns the patterns found
/// in a snapshot. Cost is O(n log n) (sort) per merchant group, which is
/// well under 10ms for typical 500-txn histories. Caller decides when to
/// refresh (e.g. on app open, after N saves, lazy on analytics-screen
/// open) — running it on every parse would be wasteful.
class RecurringDetector {
  RecurringDetector._();

  /// Minimum sightings before a pattern is considered. Two transactions
  /// give us only one interval — not enough to claim recurrence.
  static const _minOccurrences = 3;

  /// Minimum total span (first → last) before a group can be classified
  /// as recurring. Three transactions inside 5 days is a burst, not a
  /// pattern — without this floor a flurry of test charges or a
  /// weekend trip could pose as "weekly".
  static const _minSpanDays = 7;

  /// How far an individual interval may deviate from the group average,
  /// in days. ±3 days covers month-length variation (28-31) and the
  /// occasional weekend-shifted weekly charge.
  static const _intervalToleranceDays = 3;

  /// Day-of-month tolerance for the calendar-anchored monthly check.
  /// Salary on the 1st that occasionally lands on the 28th (Friday
  /// before a Sunday-1st) still counts.
  static const _dayOfMonthToleranceDays = 3;

  /// Confidence floor for patterns to be reported. Below this the
  /// signal is too weak to act on.
  static const _confidenceFloor = 0.6;

  /// Amount-variance tiers for the confidence bonus. Real-world
  /// subscriptions and salaries fluctuate (taxes, price hikes, bonuses)
  /// so a flat <10% gate rejects too many true positives. Tiered:
  ///   CV < 0.15 → +0.20 (tight)
  ///   CV < 0.25 → +0.10 (loose but stable)
  ///   else      → +0    (too noisy to trust amount as a signal)
  static const _amountCvTight = 0.15;
  static const _amountCvLoose = 0.25;

  /// Maximum tolerable ratio of unique-to-total intervals when neither
  /// the linear interval-stability nor calendar-anchored monthly check
  /// passed. Above this, the merchant looks like a random-occurrence
  /// pattern that just happens to average a periodic-looking gap.
  /// 0.6 → at least 40% of consecutive intervals must repeat.
  static const _uniqueIntervalCeiling = 0.6;

  /// Confidence penalty when the same merchant has both income and
  /// expense transactions. Mixed-direction histories almost always
  /// mean refunds + payments under one merchant key — the recurring
  /// signal weakens (you don't want "Amazon" classified as a monthly
  /// income from one stray refund).
  static const _mixedDirectionPenalty = 0.2;

  /// Tiered time-of-day consistency bonuses. ±1 hour is a strong
  /// auto-debit / salary signal (always the same minute, more or
  /// less); ±2 hours is the weaker "same time of day" cluster that's
  /// still useful but less specific. Tiers stack: a pattern that
  /// passes ±1 also passes ±2, so we choose the strongest applicable.
  static const _timeBonusTight = 0.1;
  static const _timeBonusLoose = 0.05;
  static const _timeToleranceTightHours = 1;
  static const _timeToleranceLooseHours = 2;

  /// Tiered weekday-consistency bonuses by periodicity.
  ///   weekly  → +0.10 (strong signal — that's literally what
  ///             "every Tuesday" means)
  ///   monthly → +0.05 (weak signal — month boundaries don't align
  ///             with weekdays, so coincidence is plausible at
  ///             3-4 sightings; reduced bonus reflects that)
  ///   daily / irregular → no bonus (weekday tautological / pattern
  ///             rejected)
  static const _weekdayBonusWeekly = 0.10;
  static const _weekdayBonusMonthly = 0.05;

  /// Soft cap when neither linear interval stability nor calendar-
  /// anchored monthly fired. Other bonuses (amount tightness, time-
  /// of-day, weekday) can lift such patterns above the badge floor,
  /// but without a real periodicity signal we don't want them
  /// claiming high confidence — cap below the 0.7 badge threshold so
  /// the UI gate naturally suppresses them.
  static const _mixedSignalConfidenceCap = 0.75;

  /// Confidence penalty for monthly patterns claimed on only 3
  /// sightings. Three points can accidentally land on similar dates;
  /// real monthly recurrence becomes credible at 4+.
  static const _smallSampleMonthlyPenalty = 0.1;

  /// Confidence penalty when a monthly pattern has at least one
  /// suspiciously short interval (< 20 days). Catches the "[30, 30,
  /// 5]" shape where calendar anchoring lets a long-term monthly
  /// claim survive even though one billing cycle was cut short — a
  /// real monthly never has a sub-20-day gap.
  static const _shortIntervalPenalty = 0.2;
  static const _monthlyMinIntervalDays = 20;

  /// Penalty when a "monthly" pattern has at least one weekly-shaped
  /// interval (6-8 days). Sparsely-sampled weekly transactions can
  /// produce average intervals in the monthly band — e.g. a weekend
  /// dinner sampled four times across a season might show as
  /// [28, 35, 28] which lands at avg 30.3 and passes monthly. The
  /// presence of any 6-8 day gap is the giveaway.
  static const _weeklyClusterPenalty = 0.15;

  /// Penalty when a single merchant produces wildly different
  /// amounts. (max−min)/avg > 0.75 typically means salary + bonus
  /// (or salary + reimbursement) being lumped under one employer
  /// merchant key. The recurring "salary" is real, but its average
  /// is meaningless when bonuses skew the spread, so the badge
  /// shouldn't claim high confidence. Only fires at occurrences ≥ 4
  /// — small samples have unstable spread by definition.
  static const _amountSpreadPenalty = 0.2;
  static const double _amountSpreadCeiling = 0.75;

  /// Penalty for monthly claims with a total span < 50 days. A real
  /// monthly pattern needs at least two full cycles between first and
  /// last sighting; a 7-day [_minSpanDays] floor prevents bursts but
  /// 3-4 transactions across 30 days can still fake monthly alignment
  /// without truly being monthly.
  static const _monthlyShortSpanPenalty = 0.2;
  static const _monthlyMinSpanDays = 50;

  /// Penalty when amounts alternate between two distinct clusters
  /// (e.g. [100, 200, 100, 200]). The interval signal can pass and
  /// CV stays moderate, but the underlying behavior is two
  /// interleaved billing cycles — not a single recurring stream.
  /// Surface that as reduced confidence so the chip doesn't claim a
  /// single average that's actually a midpoint between two charges.
  static const _alternatingAmountPenalty = 0.15;

  /// Cluster gap required before the alternating-amount check fires.
  /// Below 50% gap between high and low cluster averages, the
  /// "alternation" is just noise around the mean; above it, the two
  /// clusters are clearly distinct billing tiers.
  static const double _alternatingClusterGap = 0.5;

  /// Average-amount floor below which the amount-CV bonus is
  /// dampened. ₹10-50 transactions naturally have low CV (snacks,
  /// tea — small absolute swings) so a tight CV doesn't carry the
  /// same evidence weight it does for ₹500+ subscriptions.
  static const double _lowValueAmountCutoff = 100.0;
  static const double _lowValueAmountBonus = 0.05;

  /// Group, sort, and score. Returns patterns above [_confidenceFloor],
  /// sorted by confidence descending then occurrences descending.
  ///
  /// Each call generates a short traceId that's stamped into every
  /// rejection log, so all logs from one analyze() invocation can be
  /// grep-grouped together — useful when scanning large datasets
  /// where many merchants might reject in interleaved order.
  static List<RecurringPattern> analyze(List<Transaction> transactions) {
    if (transactions.isEmpty) return const [];

    final traceId = _shortTrace();

    // Group by canonical merchant key. Ignore deleted, ignore txns with
    // no merchant signal (notes empty) — those are noise for grouping.
    final groups = <String, List<Transaction>>{};
    for (final tx in transactions) {
      if (tx.isDeleted) continue;
      final key = _merchantKey(tx);
      if (key == null) continue;
      groups.putIfAbsent(key, () => []).add(tx);
    }

    final patterns = <RecurringPattern>[];
    groups.forEach((key, txns) {
      final pattern = _scoreGroup(key, txns, traceId);
      if (pattern != null && pattern.confidence >= _confidenceFloor) {
        patterns.add(pattern);
      }
    });

    patterns.sort((a, b) {
      final byConf = b.confidence.compareTo(a.confidence);
      if (byConf != 0) return byConf;
      return b.occurrences.compareTo(a.occurrences);
    });
    return patterns;
  }

  /// Compact trace id for log correlation — last 6 digits of
  /// microsecond timestamp. Doesn't need to be globally unique;
  /// enough to disambiguate logs within one debug session.
  static String _shortTrace() {
    final us = DateTime.now().microsecondsSinceEpoch;
    return (us % 1000000).toString().padLeft(6, '0');
  }

  // ── Internals ────────────────────────────────────────────────────

  /// Merchant grouping key. Notes is where the import flow stores the
  /// merchant; the canonical key resolves dictionary aliases so
  /// "Amazon Pay" / "AMAZON PAY INDIA" / "amazonpay" all collapse into
  /// the same bucket. Without this, the same monthly subscription would
  /// fragment across multiple keys and never reach _minOccurrences.
  static String? _merchantKey(Transaction tx) {
    final raw = tx.notes.trim();
    if (raw.isEmpty) return null;
    final key = MerchantNormalizer.canonicalKey(raw);
    return key.isEmpty ? null : key;
  }

  static RecurringPattern? _scoreGroup(
      String key, List<Transaction> txns, String traceId) {
    if (txns.length < _minOccurrences) return null;

    // Sort ascending by date to compute consecutive intervals.
    final sorted = [...txns]..sort((a, b) => a.date.compareTo(b.date));

    // Sufficient-span guard: 3 transactions inside a few days is a
    // burst, not a recurring pattern. Reject before we waste interval
    // math on it.
    final totalSpanDays =
        sorted.last.date.difference(sorted.first.date).inDays;
    if (totalSpanDays < _minSpanDays) {
      if (_logRecurring) {
        debugPrint('[Recurring][$traceId][Reject][Span] $key=${totalSpanDays}d');
      }
      return null;
    }

    // Intervals in days between consecutive transactions.
    final intervals = <int>[];
    for (var i = 1; i < sorted.length; i++) {
      intervals.add(
        sorted[i].date.difference(sorted[i - 1].date).inDays,
      );
    }
    if (intervals.isEmpty) return null;

    final avgIntervalDays =
        intervals.reduce((a, b) => a + b) / intervals.length;
    final intervalStable = intervals
        .every((d) => (d - avgIntervalDays).abs() <= _intervalToleranceDays);

    // Calendar-anchored monthly check — handles real-world cases where
    // raw day-interval stability fails:
    //   * Feb (28) + Mar (31) salary intervals oscillate
    //   * Weekend shifts move the actual debit by a day or two
    // If the day-of-month is consistent across all sightings AND the
    // average interval is in the monthly band, the pattern IS monthly
    // even when interval stability fails.
    final dates = sorted.map((t) => t.date).toList();
    final calendarMonthly = _isMonthlyByDayOfMonth(dates) &&
        avgIntervalDays >= 25 &&
        avgIntervalDays <= 35;

    // Random-pattern guard: when neither stability check passed AND
    // intervals are mostly distinct, this looks like a random merchant
    // (Swiggy ordering whenever) whose average interval coincidentally
    // landed in the weekly/monthly band. Reject before we mis-promote
    // it to a periodic pattern.
    if (!intervalStable && !calendarMonthly && intervals.length >= 3) {
      final uniqueRatio = intervals.toSet().length / intervals.length;
      if (uniqueRatio > _uniqueIntervalCeiling) {
        if (_logRecurring) {
          debugPrint('[Recurring][$traceId][Reject][UniqueRatio] $key=${uniqueRatio.toStringAsFixed(2)}');
        }
        return null;
      }
    }

    // Periodicity bucket — coarse so the label is meaningful.
    var periodicity = _classifyPeriodicity(avgIntervalDays);
    if (calendarMonthly) periodicity = RecurringPeriodicity.monthly;

    // Irregular patterns aren't actionable — short-circuit.
    if (periodicity == RecurringPeriodicity.irregular) {
      if (_logRecurring) {
        debugPrint('[Recurring][$traceId][Reject][Irregular] $key=${avgIntervalDays.toStringAsFixed(1)}d');
      }
      return null;
    }

    // Amount stats. Coefficient of variation = stdev/mean. Use absolute
    // values so income (positive) and expense (positive in storage) both
    // compare cleanly — sign is captured by `type`, not amount.
    final amounts = sorted.map((t) => t.amount.abs()).toList();
    final meanAmount = amounts.reduce((a, b) => a + b) / amounts.length;
    final amountCv = meanAmount == 0 ? 0.0 : _stdev(amounts) / meanAmount;

    // Type: pick whichever dominates. Salary will be 'income', Netflix
    // will be 'expense'. Mixed groups (rare) take the majority.
    final type = _dominantType(sorted);

    // Confidence rollup.
    //   +0.4 for hitting the occurrence floor
    //   +0.4 for stability (interval-based OR calendar-anchored monthly)
    //   tiered amount variance bonus — real subscriptions can drift 10-20%
    //   +0.1 if time-of-day clusters tightly (auto-debits / salary)
    //   −0.2 if the merchant has mixed income+expense direction
    //   −0.1 if claiming monthly on a 3-occurrence sample
    double confidence = 0;
    if (sorted.length >= _minOccurrences) confidence += 0.4;
    if (intervalStable || calendarMonthly) confidence += 0.4;
    // Tiered amount-CV bonus, with a low-value taper. Small-ticket
    // transactions (tea, snacks, coffee) have naturally low absolute
    // variance, so a tight CV there isn't the strong evidence it is
    // for ₹500+ subscriptions. Dampen accordingly.
    if (meanAmount < _lowValueAmountCutoff) {
      if (amountCv < _amountCvTight) confidence += _lowValueAmountBonus;
    } else {
      if (amountCv < _amountCvTight) {
        confidence += 0.2;
      } else if (amountCv < _amountCvLoose) {
        confidence += 0.1;
      }
    }
    // Graded time-of-day bonus: tight cluster gets the full 0.10,
    // looser cluster gets 0.05. Choose the strongest applicable —
    // no double-counting.
    if (_isTimeOfDayConsistent(dates, _timeToleranceTightHours)) {
      confidence += _timeBonusTight;
    } else if (_isTimeOfDayConsistent(dates, _timeToleranceLooseHours)) {
      confidence += _timeBonusLoose;
    }
    // Weekday bonus is periodicity-tiered: weekly patterns get the
    // full bonus (consistency IS the signal); monthly patterns get a
    // reduced bonus because weekday alignment is partially
    // coincidental (3-4 monthly sightings often share a weekday by
    // chance). Daily / irregular get nothing.
    if (_isWeekdayConsistent(dates)) {
      if (periodicity == RecurringPeriodicity.weekly) {
        confidence += _weekdayBonusWeekly;
      } else if (periodicity == RecurringPeriodicity.monthly) {
        confidence += _weekdayBonusMonthly;
      }
    }
    if (!_isDirectionConsistent(sorted)) {
      confidence -= _mixedDirectionPenalty;
    }
    if (sorted.length < 4 && periodicity == RecurringPeriodicity.monthly) {
      confidence -= _smallSampleMonthlyPenalty;
    }
    // Short-interval guard: a monthly claim with a sub-20-day gap
    // is almost certainly a billing anomaly or a misgrouping. Drop
    // confidence enough that borderline cases fall below the badge
    // floor without rejecting outright (the pattern might still be
    // real — just less certain).
    final minInterval = intervals.reduce(math.min);
    if (periodicity == RecurringPeriodicity.monthly &&
        minInterval < _monthlyMinIntervalDays) {
      confidence -= _shortIntervalPenalty;
    }

    // Weekly-cluster guard: a monthly claim that contains any
    // weekly-shaped interval (6-8 days) is suspicious. Real monthly
    // patterns produce ~28-31 day gaps even under weekend shifts —
    // a 7-day gap means weekly sampling that just happened to
    // average out to ~monthly. Penalize.
    if (periodicity == RecurringPeriodicity.monthly &&
        intervals.any((d) => d >= 6 && d <= 8)) {
      confidence -= _weeklyClusterPenalty;
    }

    // Monthly short-span guard: monthly claims need at least 50 days
    // of total history (≥ ~2 complete cycles) before we'll project
    // confidently. A 30-day span with 3-4 points can land in the
    // monthly band but doesn't yet prove the pattern continues.
    if (periodicity == RecurringPeriodicity.monthly &&
        totalSpanDays < _monthlyMinSpanDays) {
      confidence -= _monthlyShortSpanPenalty;
    }

    // Amount-spread guard: lumped salary + bonus / reimbursement
    // shows wildly different amounts under one merchant key. The
    // periodicity may still be real, but the average loses meaning
    // — drop confidence so the chip doesn't show a misleading
    // "Monthly ₹X" claim averaged across mixed payment types.
    if (sorted.length >= 4) {
      final maxAmount = amounts.reduce(math.max);
      final minAmount = amounts.reduce(math.min);
      if (meanAmount > 0) {
        final spread = (maxAmount - minAmount) / meanAmount;
        if (spread > _amountSpreadCeiling) {
          confidence -= _amountSpreadPenalty;
        }
      }
    }

    // Alternating-amount guard: detects two interleaved billing
    // cycles ([100, 200, 100, 200, ...]). The interval signal can
    // pass and CV stays moderate, but the "average" is meaningless
    // because it's a midpoint between two genuinely separate
    // payment streams. Penalize.
    if (_isAlternatingAmounts(amounts)) {
      confidence -= _alternatingAmountPenalty;
    }
    // Soft cap: if neither stability check passed, the pattern
    // shouldn't claim high confidence even when corroborating signals
    // pile up. Caps at 0.75 — borderline-acceptable for the detector
    // floor (0.6) but right at the badge floor (0.7), so the UI gate
    // naturally suppresses ambiguous cases.
    if (!intervalStable && !calendarMonthly) {
      confidence = math.min(confidence, _mixedSignalConfidenceCap);
    }
    confidence = confidence.clamp(0.0, 1.0);
    confidence = (confidence * 100).round() / 100;

    final intervalDays = avgIntervalDays.round();
    final lastSeen = sorted.last.date;
    // Monthly: project to the same calendar day next month rather than
    // last + 30 days. "Salary on the 5th" should predict the 5th, not
    // a drifting day-count offset.
    final nextExpected = periodicity == RecurringPeriodicity.monthly
        ? _nextMonthSameDay(lastSeen)
        : lastSeen.add(Duration(days: intervalDays));

    return RecurringPattern(
      merchantKey: key,
      displayMerchant: _bestDisplayName(sorted),
      type: type,
      averageAmount: meanAmount,
      amountCv: (amountCv * 100).round() / 100,
      interval: Duration(days: intervalDays),
      periodicity: periodicity,
      lastSeen: lastSeen,
      nextExpected: nextExpected,
      occurrences: sorted.length,
      confidence: confidence,
    );
  }

  /// Coarse periodicity classification by average interval.
  static RecurringPeriodicity _classifyPeriodicity(double avgDays) {
    if (avgDays >= 28 && avgDays <= 31) return RecurringPeriodicity.monthly;
    if (avgDays >= 6 && avgDays <= 8) return RecurringPeriodicity.weekly;
    if (avgDays >= 1 && avgDays <= 2) return RecurringPeriodicity.daily;
    return RecurringPeriodicity.irregular;
  }

  /// True when every transaction landed on roughly the same day of
  /// month — within ±[_dayOfMonthToleranceDays] of some reference day,
  /// measured circularly so month-end wraparound (Jan 31 ↔ Feb 1) is
  /// treated as a 1-day shift instead of a 30-day jump.
  ///
  /// Reference-day search: tests every observed day as the candidate
  /// anchor and accepts if any anchor satisfies the tolerance for all
  /// dates. This handles patterns like:
  ///   * 28 Feb / 31 Mar / 30 Apr — month-end rent (anchored at 30)
  ///   * 1 Jan / 31 Jan / 1 Mar  — weekend-shifted salary (anchored at 1)
  /// without the linear-average bias of comparing against the mean.
  static bool _isMonthlyByDayOfMonth(List<DateTime> dates) {
    if (dates.length < _minOccurrences) return false;
    final days = dates.map((d) => d.day).toList();
    for (final ref in days) {
      final ok = days.every((d) =>
          _circularDayDiff(d, ref) <= _dayOfMonthToleranceDays);
      if (ok) return true;
    }
    return false;
  }

  /// Circular distance between two days-of-month on a 31-day cycle.
  /// `_circularDayDiff(31, 1) == 1`, `_circularDayDiff(15, 5) == 10`.
  /// 31 is used as the cycle length to bound the worst-case wrap;
  /// shorter months stay correct because we're measuring distance, not
  /// indexing into a calendar.
  static int _circularDayDiff(int a, int b) {
    final raw = (a - b).abs();
    return math.min(raw, 31 - raw);
  }

  /// Project [last] forward by one calendar month, preserving day of
  /// month where possible. When the source day overflows the target
  /// month (e.g. the 31st in a 30-day month), clamp to the target
  /// month's last day rather than letting Dart's DateTime overflow
  /// silently roll into the following month.
  static DateTime _nextMonthSameDay(DateTime last) {
    var nextMonth = last.month + 1;
    var nextYear = last.year;
    if (nextMonth > 12) {
      nextMonth -= 12;
      nextYear += 1;
    }
    // Last day of the target month — DateTime(year, month + 1, 0) gives
    // the previous month's last day.
    final lastDayOfNextMonth = DateTime(nextYear, nextMonth + 1, 0).day;
    final day = last.day > lastDayOfNextMonth ? lastDayOfNextMonth : last.day;
    return DateTime(nextYear, nextMonth, day);
  }

  /// Sample standard deviation (n-1 denominator). Returns 0 for groups
  /// of size 1 to keep `_scoreGroup` arithmetic well-defined.
  static double _stdev(List<double> values) {
    if (values.length <= 1) return 0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values
            .map((v) => (v - mean) * (v - mean))
            .reduce((a, b) => a + b) /
        (values.length - 1);
    return math.sqrt(variance);
  }

  /// Most-common casing wins. Stable when tied — first-seen wins,
  /// which feels right because that's usually the cleanest entry.
  static String _bestDisplayName(List<Transaction> txns) {
    final counts = <String, int>{};
    for (final t in txns) {
      final n = t.notes.trim();
      if (n.isEmpty) continue;
      counts[n] = (counts[n] ?? 0) + 1;
    }
    if (counts.isEmpty) return txns.first.notes.trim();
    String best = counts.keys.first;
    int bestN = counts[best]!;
    counts.forEach((k, v) {
      if (v > bestN) {
        best = k;
        bestN = v;
      }
    });
    return best;
  }

  /// Whichever type appears most often. Mixed-type merchants (rare —
  /// e.g. someone uses "Amazon" for both purchases and refunds) get
  /// labelled by majority; the user can still drill in.
  static String _dominantType(List<Transaction> txns) {
    int income = 0;
    int expense = 0;
    for (final t in txns) {
      if (t.type == 'income') {
        income++;
      } else if (t.type == 'expense') {
        expense++;
      }
    }
    return income > expense ? 'income' : 'expense';
  }

  /// True when every transaction in the group flows the same way
  /// (all income OR all expense). Mixed direction usually means
  /// refunds + payments are sharing a merchant key — a real recurring
  /// pattern would be one-directional, so we apply a confidence
  /// penalty rather than rejecting outright.
  static bool _isDirectionConsistent(List<Transaction> txns) {
    int income = 0;
    int expense = 0;
    for (final t in txns) {
      if (t.type == 'income') {
        income++;
      } else if (t.type == 'expense') {
        expense++;
      }
    }
    return income == 0 || expense == 0;
  }

  /// True when every transaction landed within ±[toleranceHours] of
  /// the group's average hour-of-day. Tolerance-parameterized so the
  /// caller can probe both the strong (±1) and loose (±2) clusters
  /// for graded confidence scoring.
  static bool _isTimeOfDayConsistent(
    List<DateTime> dates,
    int toleranceHours,
  ) {
    if (dates.length < _minOccurrences) return false;
    final hours = dates.map((d) => d.hour).toList();
    final avg = hours.reduce((a, b) => a + b) / hours.length;
    return hours.every((h) => (h - avg).abs() <= toleranceHours);
  }

  /// True when every transaction landed on the same weekday.
  /// Independent of [_isTimeOfDayConsistent] — both can stack as
  /// separate bonuses. Especially valuable for weekly patterns and
  /// weekend-shifted salary (Friday-anchored when the calendar 1st
  /// hits a Sunday).
  static bool _isWeekdayConsistent(List<DateTime> dates) {
    if (dates.length < _minOccurrences) return false;
    final first = dates.first.weekday;
    return dates.every((d) => d.weekday == first);
  }

  /// True when amounts alternate between two distinct clusters
  /// position-by-position (ABABAB shape) AND the clusters are
  /// meaningfully separated. Splits at the median so cluster
  /// membership is unambiguous; requires both:
  ///   * Strict positional alternation (no two adjacent items in
  ///     the same cluster)
  ///   * High-cluster vs low-cluster mean gap ≥ 50% of the low mean
  /// Both checks are needed — pure noise around the median can
  /// produce alternation by chance, while large gaps can exist
  /// without strict alternation.
  static bool _isAlternatingAmounts(List<double> amounts) {
    if (amounts.length < 4) return false;
    final sorted = [...amounts]..sort();
    final median = sorted[sorted.length ~/ 2];
    // Classify each amount: high (>median) or low (≤median)
    final classes = amounts.map((a) => a > median ? 1 : 0).toList();
    for (var i = 1; i < classes.length; i++) {
      if (classes[i] == classes[i - 1]) return false;
    }
    final highs = amounts.where((a) => a > median).toList();
    final lows = amounts.where((a) => a <= median).toList();
    if (highs.isEmpty || lows.isEmpty) return false;
    final avgHigh = highs.reduce((a, b) => a + b) / highs.length;
    final avgLow = lows.reduce((a, b) => a + b) / lows.length;
    if (avgLow <= 0) return false;
    return (avgHigh - avgLow) / avgLow >= _alternatingClusterGap;
  }
}
