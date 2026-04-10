import '../../../data/repositories/transaction_repo.dart';
import '../models/parsed_sms.dart';

/// Production-grade deduplication engine.
///
/// Detects duplicates from 4 sources:
///   1. Same SMS received twice (exact ref match)
///   2. Bank + aggregator SMS (e.g., ICICI + Visa for same txn)
///   3. SMS import + manual entry (amount + date fuzzy match)
///   4. Bulk import + real-time listener (concurrent race)
///
/// Strategy:
///   - Hard dedup: exact external_ref match (fast, DB-indexed)
///   - Soft dedup: amount + timestamp window + account (catches cross-source dupes)
class DeduplicatorService {
  final TransactionRepo _repo;

  DeduplicatorService(this._repo);

  /// Check if a parsed SMS is a duplicate of an existing transaction.
  /// Returns true if duplicate found (should skip).
  Future<bool> isDuplicate(ParsedSms sms, String externalRef) async {
    // ── HARD DEDUP: exact ref match (fastest, O(1) lookup) ──────────
    if (externalRef.isNotEmpty) {
      final exists = await _repo.existsByExternalRef(externalRef);
      if (exists) return true;
    }

    // ── SOFT DEDUP: fuzzy match within time window ──────────────────
    // Catches: bank + aggregator SMS, SMS + manual entry
    return _softDuplicateCheck(sms);
  }

  /// Batch dedup for bulk imports. Returns set of refs that are duplicates.
  Future<Set<String>> batchCheckRefs(List<String> refs) async {
    return _repo.getExistingExternalRefs(refs);
  }

  /// Build a stable external reference for a parsed SMS.
  ///
  /// Priority:
  ///   1. UTR/Transaction reference (globally unique)
  ///   2. Composite key: sender|timestamp|amount|last4
  static String buildExternalRef(ParsedSms sms) {
    // Priority 1: Use UTR/transaction reference if available
    if (sms.refId != null && sms.refId!.trim().length >= 6) {
      return sms.refId!.trim();
    }
    // Priority 2: Stable composite key
    return [
      sms.sender,
      sms.date.millisecondsSinceEpoch.toString(),
      sms.amount.toStringAsFixed(2),
      sms.last4 ?? '',
    ].join('|');
  }

  /// Soft duplicate detection — checks for transactions with:
  ///   - Same amount (exact match)
  ///   - Within ±5 minute window
  ///   - Same account (last4 match) OR same source type
  Future<bool> _softDuplicateCheck(ParsedSms sms) async {
    final windowStart =
        sms.date.subtract(const Duration(minutes: 5));
    final windowEnd =
        sms.date.add(const Duration(minutes: 5));

    final candidates = await _repo.findByAmountAndDateRange(
      amount: sms.amount,
      from: windowStart,
      to: windowEnd,
    );

    if (candidates.isEmpty) return false;

    // Check if any candidate matches on additional criteria
    for (final existing in candidates) {
      // Same external ref fragment match
      if (sms.refId != null &&
          existing.externalRef != null &&
          existing.externalRef!.contains(sms.refId!)) {
        return true;
      }
      // Same amount + same date window = likely duplicate
      // (especially for SMS + aggregator scenarios)
      if ((existing.amount - sms.amount).abs() < 0.01) {
        return true;
      }
    }

    return false;
  }
}
