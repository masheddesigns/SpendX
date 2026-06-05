import 'dart:math' as math;

import '../models/transaction.dart';
import 'merchant_normalizer.dart';

/// How heavily a merchant is used. Coarse buckets are enough for UX
/// — "frequent" / "regular" / "occasional" maps to chip colors and
/// hierarchical placement in the merchants list.
enum MerchantFrequency { frequent, regular, occasional }

extension MerchantFrequencyX on MerchantFrequency {
  String get label => switch (this) {
        MerchantFrequency.frequent => 'Frequent',
        MerchantFrequency.regular => 'Regular',
        MerchantFrequency.occasional => 'Occasional',
      };
}

/// Direction of a merchant's recent activity vs the prior period.
/// `rising` / `falling` only fire on >20% deltas — a noise floor that
/// keeps random week-to-week jitter out of the UI.
enum MerchantTrend { rising, falling, steady }

extension MerchantTrendX on MerchantTrend {
  String get label => switch (this) {
        MerchantTrend.rising => 'Rising',
        MerchantTrend.falling => 'Falling',
        MerchantTrend.steady => 'Steady',
      };
}

/// Aggregated stats for one merchant.
///
/// Income and expense totals are kept separately so a single "Amazon"
/// row isn't polluted by the occasional refund — you almost always
/// want one or the other when ranking, never their net sum.
class MerchantStats {
  /// Canonical merchant identity from [MerchantNormalizer]. Dictionary
  /// aliases collapse to the same key — "Amazon Pay" / "AMAZON PAY
  /// INDIA" / "amazonpay" all share one stats row.
  final String merchantKey;

  /// Best-cased name to show — most common original casing wins, with
  /// dictionary canonicals taking precedence when applicable.
  String displayMerchant;

  int count;
  double expenseTotal;
  double incomeTotal;
  DateTime lastUsed;

  /// Distinct calendar days this merchant was used. Lets the UI tell
  /// "10 Swiggy orders in 2 days" (binge: activeDays.length=2) from
  /// "10 over a month" (habit: activeDays.length≈10). Stored as
  /// date-only DateTimes (year/month/day, no time component).
  final Set<DateTime> activeDays = {};

  /// Recent-vs-prior windowed totals used to derive [trend]. Public
  /// for transparency in tests / debug; consumers should read [trend].
  double recentTotal = 0;
  double priorTotal = 0;

  /// Direction of activity. Computed during build by comparing the
  /// last 30 days vs the preceding 30 days.
  MerchantTrend trend = MerchantTrend.steady;

  MerchantStats({
    required this.merchantKey,
    required this.displayMerchant,
    required this.lastUsed,
    this.count = 0,
    this.expenseTotal = 0,
    this.incomeTotal = 0,
  });

  /// Convenience: net flow (income − expense). Mostly diagnostic.
  double get net => incomeTotal - expenseTotal;

  /// Sign-agnostic "how much money moved through this merchant".
  /// Used as the default ranking signal — answers "biggest merchant
  /// by activity" cleanly for both spend and income contexts.
  double get totalActivity => expenseTotal + incomeTotal;

  /// Minimum sightings before [avgExpensePerTxn] / [avgActivityPerTxn]
  /// report a true mathematical mean. Below this, the "average" is
  /// dominated by sample noise — a single ₹500 transaction labelled
  /// as a "₹500 average" reads as stable behavior when it's just a
  /// one-off. Below the floor we surface the raw total instead so the
  /// caller can tell from the magnitude that history is thin.
  static const _minStableAvgSamples = 3;

  /// Average spend per transaction. Highlights expensive merchants
  /// independently of frequency — a single ₹50k furniture purchase
  /// outranks ten ₹500 coffees on this metric, which is exactly
  /// what "where did big chunks go" wants.
  ///
  /// For [count] < 3 returns the raw [expenseTotal] rather than a
  /// per-transaction mean — see [_minStableAvgSamples].
  double get avgExpensePerTxn {
    if (count == 0) return 0;
    if (count < _minStableAvgSamples) return expenseTotal;
    return expenseTotal / count;
  }

  /// Average activity per transaction (signed magnitude). Useful when
  /// ranking generically without committing to expense vs income.
  ///
  /// For [count] < 3 returns the raw activity total — see
  /// [_minStableAvgSamples] for rationale.
  double get avgActivityPerTxn {
    if (count == 0) return 0;
    final total = expenseTotal + incomeTotal;
    if (count < _minStableAvgSamples) return total;
    return total / count;
  }

  /// Anti-burst frequency. Caps the raw [count] at twice the number
  /// of distinct active days, so 10 transactions in a single day
  /// can't out-rank genuinely habitual usage. The 2× factor allows
  /// for two transactions per active day before discounting kicks
  /// in — which is the typical "morning + evening" use case for the
  /// same merchant on the same day.
  ///
  /// Used by [topByCompositeScore] and the [frequency] tier so both
  /// ranking and labelling stay honest about how distributed the
  /// merchant's usage actually is.
  int get effectiveFrequency {
    final dayCap = activeDays.length * 2;
    if (dayCap <= 0) return count;
    return count < dayCap ? count : dayCap;
  }

  MerchantFrequency get frequency {
    final eff = effectiveFrequency;
    if (eff >= 10) return MerchantFrequency.frequent;
    if (eff >= 3) return MerchantFrequency.regular;
    return MerchantFrequency.occasional;
  }
}

/// Pure aggregator — no I/O, no caching, no sorting until asked.
///
/// `MerchantAggregator.build(transactions)` walks the list once and
/// returns a map keyed by canonical merchant. Sort/top/filter helpers
/// operate on the result without mutating it. Cost: O(n) build + O(m
/// log m) sort, where m is unique-merchant count — comfortably under
/// 10ms for 500-transaction histories.
class MerchantAggregator {
  MerchantAggregator._();

  /// Trend window — totals from the most recent 30 days are compared
  /// against the preceding 30. Wider windows smooth more but lag real
  /// shifts; 30 days is a clean monthly cadence that catches "Swiggy
  /// went up this month" without thrashing on day-to-day noise.
  static const _trendWindow = Duration(days: 30);

  /// Minimum relative change before [MerchantTrend.rising] /
  /// [MerchantTrend.falling] fire. 20% is the noise floor we landed on
  /// — under that, week-to-week variance dominates and the label flips
  /// for no real reason.
  static const _trendThreshold = 0.20;

  /// Minimum prior-period spend to qualify for trend classification.
  /// Without a floor, ₹50 → ₹70 (+40%) reads as "rising", which is
  /// noise — small bases swing wildly on the relative scale. Anything
  /// below this stays [MerchantTrend.steady].
  static const _trendMinBase = 500.0;

  /// Build a stats map from a transaction list. Skips deleted txns and
  /// transactions without a merchant signal (notes empty) — those
  /// would all collapse into one "Unknown" bucket and dominate the
  /// ranking, which isn't useful.
  ///
  /// [now] sets the reference time for trend computation. Default is
  /// `DateTime.now()`; tests pass a fixed value for determinism.
  static Map<String, MerchantStats> build(
    List<Transaction> transactions, {
    DateTime? now,
  }) {
    final stats = <String, MerchantStats>{};
    // Track casing frequency per key so displayMerchant falls back to
    // whichever original variant the user has used most when the
    // dictionary doesn't have a canonical.
    final casingCounts = <String, Map<String, int>>{};

    final ref = now ?? DateTime.now();
    final recentStart = ref.subtract(_trendWindow);
    final priorStart = ref.subtract(_trendWindow * 2);

    for (final tx in transactions) {
      if (tx.isDeleted) continue;
      final raw = tx.notes.trim();
      if (raw.isEmpty) continue;
      final key = MerchantNormalizer.canonicalKey(raw);
      if (key.isEmpty) continue;

      final entry = stats.putIfAbsent(
        key,
        () => MerchantStats(
          merchantKey: key,
          displayMerchant: MerchantNormalizer.canonicalDisplay(raw),
          lastUsed: tx.date,
        ),
      );
      entry.count++;
      final amt = tx.amount.abs();
      if (tx.type == 'expense') {
        entry.expenseTotal += amt;
      } else if (tx.type == 'income') {
        entry.incomeTotal += amt;
      }
      if (tx.date.isAfter(entry.lastUsed)) entry.lastUsed = tx.date;

      // Active-day signal: distinguishes "binge in 2 days" from
      // "spread over a month". Strip the time component so multiple
      // same-day transactions only count once.
      entry.activeDays
          .add(DateTime(tx.date.year, tx.date.month, tx.date.day));

      // Trend buckets — single pass, no rescan.
      if (tx.date.isAfter(recentStart)) {
        entry.recentTotal += amt;
      } else if (tx.date.isAfter(priorStart)) {
        entry.priorTotal += amt;
      }

      final caseMap = casingCounts.putIfAbsent(key, () => {});
      caseMap[raw] = (caseMap[raw] ?? 0) + 1;
    }

    // Resolve display casing for non-dictionary merchants. If the
    // canonical lookup found a dictionary entry, that already wins
    // (proper casing from the dictionary). Otherwise pick the most
    // common original.
    casingCounts.forEach((key, counts) {
      final canonical = MerchantNormalizer.lookupCanonical(key);
      if (canonical != null) {
        stats[key]!.displayMerchant = canonical;
        return;
      }
      String best = stats[key]!.displayMerchant;
      int bestN = counts[best] ?? 0;
      counts.forEach((variant, n) {
        if (n > bestN) {
          best = variant;
          bestN = n;
        }
      });
      stats[key]!.displayMerchant = best;
    });

    // Trend resolution. Done after aggregation so we have final
    // recent/prior totals.
    for (final s in stats.values) {
      s.trend = _classifyTrend(s.recentTotal, s.priorTotal);
    }

    return stats;
  }

  /// Translate window totals into a coarse trend label.
  ///   prior 0, recent 0  → steady (no activity)
  ///   prior 0, recent >0 → rising (newly active)
  ///   prior < base floor → steady (small-base noise; +40% on ₹50 is
  ///                                 not a real shift)
  ///   else                → ±20% relative change vs prior
  static MerchantTrend _classifyTrend(double recent, double prior) {
    if (prior == 0 && recent == 0) return MerchantTrend.steady;
    if (prior == 0) return MerchantTrend.rising;
    if (prior < _trendMinBase) return MerchantTrend.steady;
    final delta = (recent - prior) / prior;
    if (delta > _trendThreshold) return MerchantTrend.rising;
    if (delta < -_trendThreshold) return MerchantTrend.falling;
    return MerchantTrend.steady;
  }

  /// Top [n] merchants by expense total. Sorted descending.
  /// Use this for "where your money went" views.
  static List<MerchantStats> topByExpense(
    Map<String, MerchantStats> stats, {
    int n = 5,
  }) {
    final list = stats.values.where((s) => s.expenseTotal > 0).toList()
      ..sort((a, b) => b.expenseTotal.compareTo(a.expenseTotal));
    return list.take(n).toList();
  }

  /// Top [n] merchants by income total. Sorted descending.
  /// Use this for "where money came from" views (employers, refunds).
  static List<MerchantStats> topByIncome(
    Map<String, MerchantStats> stats, {
    int n = 5,
  }) {
    final list = stats.values.where((s) => s.incomeTotal > 0).toList()
      ..sort((a, b) => b.incomeTotal.compareTo(a.incomeTotal));
    return list.take(n).toList();
  }

  /// Top [n] merchants by frequency (effective count, day-capped).
  /// Sorted descending. Useful for "your habits" type insights.
  /// Same-day bursts can't dominate the ranking — see
  /// [MerchantStats.effectiveFrequency].
  static List<MerchantStats> topByFrequency(
    Map<String, MerchantStats> stats, {
    int n = 5,
  }) {
    final list = stats.values.toList()
      ..sort((a, b) => b.effectiveFrequency.compareTo(a.effectiveFrequency));
    return list.take(n).toList();
  }

  /// How quickly a merchant fades from "active" once it stops being
  /// used. 60 days = full decay window; lastUsed today returns 1.0,
  /// 60+ days ago plateaus at 0.5 via the quadratic shape in
  /// [_recencyWeight]. Tuned so a merchant from last quarter stays
  /// partially visible but never blocks newer activity.
  static const int _recencyDecayDays = 60;

  /// Top [n] merchants by a composite of expense total, count, and
  /// recency.
  ///
  /// Pure-total ranking lets a single high-ticket purchase dominate
  /// over genuine habits; pure-count ranking lets a string of small
  /// transactions outrank meaningful spend; either one alone keeps
  /// stale merchants pinned to the top long after the user moved on.
  /// Blending all three surfaces merchants that are expensive,
  /// frequent, AND recent — usually what "show me my biggest
  /// merchants" actually wants.
  ///
  /// Each axis is min-max normalized against the cohort so the weights
  /// (0.7 spend, 0.3 frequency) are meaningful regardless of absolute
  /// rupee scale or transaction volume. Denominators are clamped to
  /// at least 1 so single-merchant cohorts and degenerate spreads
  /// don't produce divide-by-zero. Recency is then applied as a
  /// multiplicative weight (1.0 → 0.5) so old merchants fade
  /// proportionally rather than disappearing abruptly.
  static List<MerchantStats> topByCompositeScore(
    Map<String, MerchantStats> stats, {
    int n = 5,
    double spendWeight = 0.7,
    double frequencyWeight = 0.3,
    DateTime? now,
  }) {
    final values = stats.values.where((s) => s.expenseTotal > 0).toList();
    if (values.isEmpty) return const [];

    double minTotal = double.infinity;
    double maxTotal = 0;
    int minCount = 1 << 30;
    int maxCount = 0;
    for (final s in values) {
      if (s.expenseTotal < minTotal) minTotal = s.expenseTotal;
      if (s.expenseTotal > maxTotal) maxTotal = s.expenseTotal;
      // Use effectiveFrequency (day-capped) instead of raw count so
      // 10 same-day transactions don't masquerade as habitual use.
      final eff = s.effectiveFrequency;
      if (eff < minCount) minCount = eff;
      if (eff > maxCount) maxCount = eff;
    }
    final totalRange = math.max(maxTotal - minTotal, 1.0);
    final countRange = math.max((maxCount - minCount).toDouble(), 1.0);
    final ref = now ?? DateTime.now();

    double score(MerchantStats s) {
      final spend = (s.expenseTotal - minTotal) / totalRange;
      final freq = (s.effectiveFrequency - minCount) / countRange;
      final base = spend * spendWeight + freq * frequencyWeight;
      // Diminishing-returns compression. sqrt(x) for x ∈ [0,1] is a
      // gentle concave curve — top scores get pushed closer together
      // while still preserving order. Prevents one merchant with
      // pathologically high spend AND count from making everyone
      // else look near-zero in small datasets, where a single
      // outlier would otherwise dominate the ranking.
      final compressed = math.sqrt(base);
      return compressed * _recencyWeight(s.lastUsed, ref);
    }

    values.sort((a, b) => score(b).compareTo(score(a)));
    return values.take(n).toList();
  }

  /// Quadratic-eased decay from 1.0 (today) to 0.5 at
  /// [_recencyDecayDays] days old; constant 0.5 afterwards. The
  /// quadratic shape (1 - 0.5·t²) means recent activity barely
  /// decays at first and accelerates as the merchant goes stale —
  /// avoids the abrupt "jump" that pure linear decay produces right
  /// at the cutoff and feels more natural to users:
  ///
  ///   day 0  → 1.00
  ///   day 15 → 0.97  (linear would be 0.875)
  ///   day 30 → 0.875 (linear would be 0.75)
  ///   day 45 → 0.72  (linear would be 0.625)
  ///   day 60 → 0.50
  static double _recencyWeight(DateTime lastUsed, DateTime now) {
    final days = now.difference(lastUsed).inDays;
    if (days <= 0) return 1.0;
    final t = math.min(days / _recencyDecayDays, 1.0);
    return 1.0 - (0.5 * t * t);
  }

  /// Filter the stats map to a date window (inclusive). Common case:
  /// "this month". Caller passes the original transactions; we rebuild
  /// from the slice rather than mutating the existing map — keeps the
  /// aggregator pure.
  static Map<String, MerchantStats> buildForRange(
    List<Transaction> transactions, {
    required DateTime from,
    required DateTime to,
  }) {
    final inRange = transactions.where((t) {
      if (t.isDeleted) return false;
      return !t.date.isBefore(from) && !t.date.isAfter(to);
    }).toList();
    return build(inRange);
  }
}
