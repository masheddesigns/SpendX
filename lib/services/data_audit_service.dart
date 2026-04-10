import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/utils/merchant_normalizer.dart';
import '../data/repositories/transaction_repo.dart';
import '../utils/app_format.dart';

/// Severity levels for audit issues.
enum AuditSeverity { low, medium, high }

/// A detected data integrity issue with impact messaging.
class AuditIssue {
  final String type;
  final String title;
  final String description;
  final String? impact; // "Missing ₹2,300 from reports"
  final AuditSeverity severity;
  final List<String> transactionIds;
  final int count;

  const AuditIssue({
    required this.type,
    required this.title,
    required this.description,
    this.impact,
    required this.severity,
    this.transactionIds = const [],
    this.count = 0,
  });
}

/// Data integrity audit engine with caching.
///
/// Detects:
///   1. Uncategorized transactions (ratio-based severity)
///   2. Unassigned account transactions (scaled severity)
///   3. Possible duplicates (merchant-aware)
///   4. Abnormal amounts (per-category context)
///   5. Future-dated transactions
class DataAuditService {
  DataAuditService._();
  static final instance = DataAuditService._();

  // ── Cache ──────────────────────────────────────────────
  List<AuditIssue>? _cache;
  DateTime? _cacheTime;
  static const _cacheDuration = Duration(minutes: 5);

  bool get _isCacheValid =>
      _cache != null &&
      _cacheTime != null &&
      DateTime.now().difference(_cacheTime!) < _cacheDuration;

  /// Invalidate cache (call after transaction changes).
  void invalidateCache() {
    _cache = null;
    _cacheTime = null;
  }

  /// Dismiss a transaction from audit (user verified it's correct).
  /// Dismissed IDs expire after 30 days to prevent unbounded growth.
  Future<void> dismissTransaction(String transactionId) async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getStringList('audit_dismissed') ?? [];
    final timestamps = prefs.getStringList('audit_dismissed_ts') ?? [];

    if (!dismissed.contains(transactionId)) {
      dismissed.add(transactionId);
      timestamps.add(DateTime.now().millisecondsSinceEpoch.toString());
      await prefs.setStringList('audit_dismissed', dismissed);
      await prefs.setStringList('audit_dismissed_ts', timestamps);
    }
    invalidateCache();
  }

  /// Get dismissed transaction IDs, pruning expired entries (>30 days).
  Future<Set<String>> _getDismissedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getStringList('audit_dismissed') ?? [];
    final timestamps = prefs.getStringList('audit_dismissed_ts') ?? [];

    if (dismissed.isEmpty) return {};

    final now = DateTime.now().millisecondsSinceEpoch;
    const expiryMs = 30 * 24 * 60 * 60 * 1000; // 30 days

    final validIds = <String>{};
    final prunedIds = <String>[];
    final prunedTs = <String>[];

    for (int i = 0; i < dismissed.length; i++) {
      final ts = i < timestamps.length
          ? int.tryParse(timestamps[i]) ?? 0
          : 0;
      if (now - ts < expiryMs) {
        validIds.add(dismissed[i]);
        prunedIds.add(dismissed[i]);
        prunedTs.add(timestamps.length > i ? timestamps[i] : '0');
      }
    }

    // Prune expired entries from storage
    if (prunedIds.length != dismissed.length) {
      await prefs.setStringList('audit_dismissed', prunedIds);
      await prefs.setStringList('audit_dismissed_ts', prunedTs);
    }

    return validIds;
  }

  /// Run all audit checks. Uses 5-minute cache.
  Future<List<AuditIssue>> runAudit({bool force = false}) async {
    if (!force && _isCacheValid) return _cache!;

    final sw = Stopwatch()..start();
    final issues = <AuditIssue>[];
    final repo = TransactionRepo();

    final dismissed = await _getDismissedIds();
    final allTxns = await repo.getAll();
    if (allTxns.isEmpty) {
      _cache = issues;
      _cacheTime = DateTime.now();
      return issues;
    }

    final totalCount = allTxns.length;

    // ── 1. Uncategorized (ratio-based severity) ───────────
    final uncategorized = allTxns
        .where((t) => t.categoryId == null || t.categoryId!.isEmpty)
        .toList();
    if (uncategorized.isNotEmpty) {
      final ratio = uncategorized.length / totalCount;
      final missingAmount =
          uncategorized.fold<double>(0, (s, t) => s + t.amount);
      issues.add(AuditIssue(
        type: 'uncategorized',
        title: '${uncategorized.length} uncategorized',
        description: 'Won\'t appear in spending breakdown or reports.',
        impact: 'Missing ${AppFormat.currency(missingAmount)} from category reports',
        severity: ratio > 0.2
            ? AuditSeverity.high
            : ratio > 0.1
                ? AuditSeverity.medium
                : AuditSeverity.low,
        transactionIds: uncategorized.map((t) => t.id).toList(),
        count: uncategorized.length,
      ));
    }

    // ── 2. Unassigned account (scaled severity) ───────────
    final noAccount = allTxns
        .where((t) => t.accountId == null || t.accountId!.isEmpty)
        .toList();
    if (noAccount.isNotEmpty) {
      final missingAmount =
          noAccount.fold<double>(0, (s, t) => s + t.amount);
      issues.add(AuditIssue(
        type: 'no_account',
        title: '${noAccount.length} without account',
        description: 'Not reflected in account balances or net worth.',
        impact: '${AppFormat.currency(missingAmount)} not tracked in any account',
        severity: noAccount.length > 20
            ? AuditSeverity.high
            : noAccount.length > 5
                ? AuditSeverity.medium
                : AuditSeverity.low,
        transactionIds: noAccount.map((t) => t.id).toList(),
        count: noAccount.length,
      ));
    }

    // ── 3. Duplicates (hash-based grouping — O(n) per group) ─────
    final dupeIds = <String>{};
    // Group by rounded amount (key = amount as string with 2 decimals)
    final amountGroups = <String, List<int>>{};
    final recentTxns = allTxns.take(500).toList(); // check more with O(n)
    for (int i = 0; i < recentTxns.length; i++) {
      final key = '${recentTxns[i].amount.toStringAsFixed(2)}_${recentTxns[i].type}';
      amountGroups.putIfAbsent(key, () => []).add(i);
    }

    // Only check within same-amount groups (O(n) amortized)
    for (final group in amountGroups.values) {
      if (group.length < 2) continue;
      for (int gi = 0; gi < group.length; gi++) {
        for (int gj = gi + 1; gj < group.length; gj++) {
          final a = recentTxns[group[gi]];
          final b = recentTxns[group[gj]];

          final timeDiff = a.date.difference(b.date).inMinutes.abs();
          if (timeDiff > 10) continue; // max window

          final noteA = MerchantNormalizer.normalize(a.notes);
          final noteB = MerchantNormalizer.normalize(b.notes);
          final merchantMatch = noteA.isNotEmpty &&
              noteB.isNotEmpty &&
              (noteA.toLowerCase() == noteB.toLowerCase() ||
               noteA.toLowerCase().contains(noteB.toLowerCase()) ||
               noteB.toLowerCase().contains(noteA.toLowerCase()));

          final differentSource = a.source != b.source;
          final crossSourceWindow = differentSource && timeDiff <= 10;

          if (merchantMatch || timeDiff <= 2 || crossSourceWindow) {
            dupeIds.add(a.id);
            dupeIds.add(b.id);
          }
        }
      }
    }
    dupeIds.removeWhere((id) => dismissed.contains(id));
    if (dupeIds.isNotEmpty) {
      final dupeCount = dupeIds.length ~/ 2;
      final dupeAmount = allTxns
          .where((t) => dupeIds.contains(t.id))
          .fold<double>(0, (s, t) => s + t.amount) / 2;
      issues.add(AuditIssue(
        type: 'duplicate',
        title: '$dupeCount possible duplicate${dupeCount == 1 ? '' : 's'}',
        description: 'Same amount and time — may be double-counted.',
        impact: 'Potentially ${AppFormat.currency(dupeAmount)} over-counted',
        severity: AuditSeverity.high,
        transactionIds: dupeIds.toList(),
        count: dupeCount,
      ));
    }

    // ── 4. Abnormal amounts (per-category context) ────────
    final expenses = allTxns.where((t) => t.type == 'expense').toList();
    if (expenses.length >= 10) {
      // Build per-category averages
      final catTotals = <String, List<double>>{};
      for (final t in expenses) {
        final cat = t.categoryId ?? '_global';
        catTotals.putIfAbsent(cat, () => []).add(t.amount);
      }

      final globalAvg =
          expenses.fold<double>(0, (s, t) => s + t.amount) / expenses.length;

      final abnormal = <String>[];
      for (final t in expenses) {
        final cat = t.categoryId ?? '_global';
        final catAmounts = catTotals[cat] ?? [];
        final avg = catAmounts.length >= 3
            ? catAmounts.fold<double>(0, (s, a) => s + a) / catAmounts.length
            : globalAvg;
        // Dynamic floor: max(3x category avg, ₹1000) — prevents trivial flags
        final threshold = (avg * 3).clamp(1000.0, double.infinity);
        if (t.amount > threshold) {
          abnormal.add(t.id);
        }
      }

      // Remove dismissed
      abnormal.removeWhere((id) => dismissed.contains(id));
      if (abnormal.isNotEmpty) {
        issues.add(AuditIssue(
          type: 'abnormal_amount',
          title: '${abnormal.length} unusually large',
          description: 'Transactions exceeding 3x their category average.',
          severity: AuditSeverity.medium,
          transactionIds: abnormal,
          count: abnormal.length,
        ));
      }
    }

    // ── 5. Future-dated ───────────────────────────────────
    final now = DateTime.now();
    final future = allTxns
        .where((t) =>
            t.date.isAfter(now.add(const Duration(hours: 24))) &&
            t.source != 'recurring' &&
            t.source != 'scheduled')
        .toList();
    if (future.isNotEmpty) {
      issues.add(AuditIssue(
        type: 'future_dated',
        title: '${future.length} future-dated',
        description: 'Dated in the future — may be incorrect.',
        severity: AuditSeverity.medium,
        transactionIds: future.map((t) => t.id).toList(),
        count: future.length,
      ));
    }

    // ── Cache + log ──────────────────────────────────────
    _cache = issues;
    _cacheTime = DateTime.now();
    sw.stop();
    debugPrint('\u{1F50D} Audit: ${issues.length} issues, '
        '${allTxns.length} txns (${sw.elapsedMilliseconds}ms)');
    return issues;
  }

  /// Compute Data Health Score (0-100).
  Future<DataHealthScore> getHealthScore() async {
    final issues = await runAudit();
    final repo = TransactionRepo();
    final allTxns = await repo.getAll();
    final totalCount = allTxns.length;
    if (totalCount == 0) {
      return const DataHealthScore(score: 100, label: 'No Data', breakdown: []);
    }

    double score = 100;
    final breakdown = <ScoreBreakdownItem>[];

    for (final issue in issues) {
      final ratio = issue.count / totalCount;
      double penalty;
      switch (issue.type) {
        case 'duplicate':
          penalty = (ratio * 100).clamp(0, 25);
        case 'uncategorized':
          penalty = (ratio * 100).clamp(0, 20);
        case 'no_account':
          penalty = (ratio * 50).clamp(0, 10);
        case 'abnormal_amount':
          penalty = (ratio * 100).clamp(0, 10);
        case 'future_dated':
          penalty = (ratio * 100).clamp(0, 5);
        default:
          penalty = 0;
      }
      if (penalty > 0) {
        score -= penalty;
        breakdown.add(ScoreBreakdownItem(
          type: issue.type,
          title: issue.title,
          penalty: penalty,
        ));
      }
    }

    score = score.clamp(0, 100);
    final label = score >= 90
        ? 'Excellent'
        : score >= 75
            ? 'Good'
            : score >= 60
                ? 'Needs Attention'
                : 'Risky';

    return DataHealthScore(
        score: score.roundToDouble(), label: label, breakdown: breakdown);
  }

  /// Quick count for badge display. Uses cache.
  Future<int> getIssueCount() async {
    final issues = await runAudit();
    // Only count MEDIUM and HIGH for badge
    return issues
        .where((i) => i.severity != AuditSeverity.low)
        .fold<int>(0, (sum, i) => sum + i.count);
  }
}

/// Data Health Score (0-100) with breakdown.
class DataHealthScore {
  final double score;
  final String label;
  final List<ScoreBreakdownItem> breakdown;

  const DataHealthScore({
    required this.score,
    required this.label,
    required this.breakdown,
  });
}

class ScoreBreakdownItem {
  final String type;
  final String title;
  final double penalty;

  const ScoreBreakdownItem({
    required this.type,
    required this.title,
    required this.penalty,
  });
}
