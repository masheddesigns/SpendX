import 'package:sqflite/sqflite.dart';
import '../core/logging/app_logger.dart';
import '../data/core/app_database.dart';
import '../data/core/tables_v24.dart';

/// EvidencePruningService — Enforces privacy retention by purging raw SMS/evidence payloads
/// whose 30-day retention has expired, while strictly preserving forensic metadata.
///
/// CRITICAL ARCHITECTURAL INVARIANTS:
/// 1. IDEMPOTENT: Executing multiple times produces identical results.
/// 2. ZERO ACCOUNTING MUTATIONS: Writes 0 EconomicEvents and 0 Postings.
/// 3. FORENSIC INTEGRITY: Preserves `id`, `economic_event_id`, `body_sha256`,
///    `external_reference`, `source_type`, `extracted_amount_minor_units`,
///    `extracted_timestamp`, `sender_address`, `retention_expires_at`, and `created_at`.
/// 4. TARGETED PURGE: Sets `raw_payload_encrypted = NULL` and `is_payload_purged = 1`.
class EvidencePruningService {
  EvidencePruningService._();
  static final EvidencePruningService instance = EvidencePruningService._();

  /// Prunes raw evidence payloads whose retention period has expired.
  ///
  /// If [referenceTime] is not provided, defaults to UTC now.
  /// If [executor] is not provided, uses the active [AppDatabase.instance.database].
  ///
  /// Returns the number of evidence records purged.
  Future<int> pruneExpiredEvidence({
    DateTime? referenceTime,
    DatabaseExecutor? executor,
  }) async {
    final cutoff = (referenceTime ?? DateTime.now().toUtc()).toIso8601String();
    final db = executor ?? await AppDatabase.instance.database;

    final updatedCount = await db.rawUpdate('''
      UPDATE ${TablesV24.evidence}
      SET raw_payload_encrypted = NULL,
          is_payload_purged = 1
      WHERE retention_expires_at IS NOT NULL
        AND retention_expires_at <= ?
        AND is_payload_purged = 0;
    ''', [cutoff]);

    if (updatedCount > 0) {
      AppLogger.d(
        '[EVIDENCE_PRUNING] Purged $updatedCount expired raw evidence payloads (cutoff: $cutoff)',
      );
    }
    return updatedCount;
  }
}
