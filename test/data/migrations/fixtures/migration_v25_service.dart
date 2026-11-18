import 'package:spend_x/data/core/tables_v25.dart';
import 'package:sqflite/sqflite.dart';

/// Steps in Migration V25 used for deterministic failure injection testing.
enum MigrationV25Step {
  addColumn,
  createRefundAllocations,
  createBaselineTable,
  installTrigger3,
  installTriggers,
  insertSnapshot,
}

/// Migration Service Fixture for SpendX Phase 1.4 (Migration V25).
///
/// Reuses canonical SQL definitions from [TablesV25] as the single source
/// of truth while maintaining the failure-injection harness for Stage 1
/// rollback testing.
///
/// Transaction Ownership Contract:
/// - Accepts caller-provided [DatabaseExecutor].
/// - NEVER opens a nested transaction.
/// - Any failure propagates to the caller to trigger outer transaction rollback.
class MigrationV25Service {
  /// Test-only failure injector hook for Stage 1 atomicity verification.
  static void Function(MigrationV25Step step)? testFailureInjector;

  // ============================================================================
  // SQL DDL CONSTANTS (Delegated to TablesV25 Single Source of Truth)
  // ============================================================================

  static const addSourceRecordIdColumn = TablesV25.addSourceRecordIdColumn;
  static const createSourceRecordIdIndex = TablesV25.createEvidenceSourceRecordIdIndex;
  static const createRefundAllocationsTable = TablesV25.createRefundAllocationsTable;
  static const createRefundAllocationsOriginalIndex = TablesV25.createRefundAllocationsOriginalIndex;
  static const createRefundAllocationsRefundIndex = TablesV25.createRefundAllocationsRefundIndex;
  static const createRefundAllocationsPairIndex = TablesV25.createRefundAllocationsPairIndex;
  static const createMigrationHistoricalBaselinesTable = TablesV25.createMigrationHistoricalBaselinesTable;

  // ============================================================================
  // SQL TRIGGER SUITE (Delegated to TablesV25 Single Source of Truth)
  // ============================================================================

  static const trgRefundAllocationsValidateInsert = TablesV25.trgRefundAllocationsValidateInsert;
  static const trgRefundAllocationsPreventUpdate = TablesV25.trgRefundAllocationsPreventUpdate;
  static const trgRefundAllocationsPreventDelete = TablesV25.trgRefundAllocationsPreventDelete;
  static const trgEconomicEventsPreventDirectPostedRefund = TablesV25.trgEconomicEventsPreventDirectPostedRefund;
  static const trgEconomicEventsProtectRefundedParents = TablesV25.trgEconomicEventsProtectRefundedParents;
  static const trgEconomicEventsValidateRefundPosted = TablesV25.trgEconomicEventsValidateRefundPosted;

  // ============================================================================
  // MIGRATION RUNNER WITH FAILURE INJECTION
  // ============================================================================

  /// Runs Migration V25 using the provided [executor] (supplied by onUpgrade).
  /// Never opens a nested transaction. Exceptions propagate to the caller.
  static Future<void> run(
    DatabaseExecutor executor, {
    int? watermarkSnapshotDate,
    int? watermarkSnapshotId,
  }) async {
    // Step 1: Add source_record_id column and index
    await executor.execute(addSourceRecordIdColumn);
    await executor.execute(createSourceRecordIdIndex);
    testFailureInjector?.call(MigrationV25Step.addColumn);

    // Step 2: Create refund_allocations table and indices
    await executor.execute(createRefundAllocationsTable);
    await executor.execute(createRefundAllocationsOriginalIndex);
    await executor.execute(createRefundAllocationsRefundIndex);
    await executor.execute(createRefundAllocationsPairIndex);
    testFailureInjector?.call(MigrationV25Step.createRefundAllocations);

    // Step 3: Create migration_historical_baselines table
    await executor.execute(createMigrationHistoricalBaselinesTable);
    testFailureInjector?.call(MigrationV25Step.createBaselineTable);

    // Step 4: Install triggers
    await executor.execute(trgRefundAllocationsValidateInsert);
    await executor.execute(trgRefundAllocationsPreventUpdate);
    await executor.execute(trgRefundAllocationsPreventDelete);
    testFailureInjector?.call(MigrationV25Step.installTrigger3);

    await executor.execute(trgEconomicEventsPreventDirectPostedRefund);
    await executor.execute(trgEconomicEventsProtectRefundedParents);
    await executor.execute(trgEconomicEventsValidateRefundPosted);
    testFailureInjector?.call(MigrationV25Step.installTriggers);

    // Step 5: Insert watermark baseline snapshot
    final now = DateTime.now().toUtc().toIso8601String();
    await executor.insert('migration_historical_baselines', {
      'id': 'V25_BASELINE',
      'migration_version': 25,
      'watermark_snapshot_date': watermarkSnapshotDate ?? 0,
      'watermark_snapshot_id': watermarkSnapshotId ?? 0,
      'created_at': now,
    });
    testFailureInjector?.call(MigrationV25Step.insertSnapshot);
  }
}
