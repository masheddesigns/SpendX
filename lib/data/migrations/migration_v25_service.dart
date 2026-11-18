import 'package:sqflite/sqflite.dart';
import '../core/tables_v25.dart';

/// Migration Service for SpendX Phase 1.4 (Migration V25).
///
/// Implements:
/// 1. Addition of durable `source_record_id` and unique index to `evidence`.
/// 2. Creation of `refund_allocations` table and indices.
/// 3. Creation of `migration_historical_baselines` snapshot table.
/// 4. Complete refund lifecycle trigger suite (Triggers 1 through 6).
/// 5. Capturing of one-time watermark snapshot.
///
/// Transaction Ownership Contract:
/// - Accepts caller-provided [DatabaseExecutor] from `AppDatabase._applyUpgrades`.
/// - Strictly NEVER opens a nested transaction.
/// - Any failure propagates to the caller to trigger outer transaction rollback.
class MigrationV25Service {
  /// Runs Migration V25 using the provided [executor] (supplied by onUpgrade).
  /// Never opens a nested transaction. Exceptions propagate to the caller.
  static Future<void> run(
    DatabaseExecutor executor, {
    int? watermarkSnapshotDate,
    int? watermarkSnapshotId,
  }) async {
    // Step 1: Ensure source_record_id column and index on evidence
    final cols = await executor.rawQuery('PRAGMA table_info(evidence);');
    final hasCol = cols.any((c) => c['name'] == 'source_record_id');
    if (!hasCol) {
      await executor.execute(TablesV25.addSourceRecordIdColumn);
    }
    await executor.execute(TablesV25.createEvidenceSourceRecordIdIndex);

    // Step 2: Create refund_allocations table and indices
    await executor.execute(TablesV25.createRefundAllocationsTable);
    await executor.execute(TablesV25.createRefundAllocationsOriginalIndex);
    await executor.execute(TablesV25.createRefundAllocationsRefundIndex);
    await executor.execute(TablesV25.createRefundAllocationsPairIndex);

    // Step 3: Create migration_historical_baselines table
    await executor.execute(TablesV25.createMigrationHistoricalBaselinesTable);

    // Step 4: Install Triggers 1 through 6
    await TablesV25.installTriggers(executor);

    // Step 5: Insert watermark baseline snapshot (one-time immutable historical record)
    final now = DateTime.now().toUtc().toIso8601String();
    await executor.insert(TablesV25.migrationHistoricalBaselines, {
      'id': 'V25_BASELINE',
      'migration_version': 25,
      'watermark_snapshot_date': watermarkSnapshotDate ?? 0,
      'watermark_snapshot_id': watermarkSnapshotId ?? 0,
      'created_at': now,
    });
  }
}
