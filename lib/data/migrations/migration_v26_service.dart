import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../core/tables_v26.dart';

/// Test failure points for validating transactional rollback and retry behavior.
/// Strictly restricted to test environments; compiled out in release builds.
enum MigrationV26FailurePoint {
  afterTableCreation,
  duringLegacyInsertion,
  afterPartialInsertion,
  duringMarkerCleanup,
}

/// Migration Service for SpendX Schema V26.
///
/// Implements:
/// 1. Creation of `evidence_reconciliations` table and unique indices.
/// 2. Deterministic, lossless migration of legacy reconciliation markers from `evidence.external_reference`.
/// 3. Strict reciprocal marker validation:
///    - Every `RECONCILED_TO:<inboxSourceId>` must have a verified counterpart inbox evidence
///      with `RECONCILED_FROM:<broadcastSourceId>`.
///    - Every `RECONCILED_FROM:<broadcastSourceId>` must have a verified counterpart broadcast evidence
///      with `RECONCILED_TO:<inboxSourceId>`.
///    - Any one-sided, mismatched, missing, or contradictory marker fatally fails the transaction.
/// 4. Strict conflict detection: any conflicting or ambiguous identities fatally fail the migration transaction.
/// 5. Atomic cleansing of `evidence.external_reference` strictly after durable preservation.
///
/// Transaction Ownership Contract:
/// - Accepts caller-provided [DatabaseExecutor] from `AppDatabase._applyUpgrades`.
/// - Strictly NEVER opens a nested transaction.
/// - Idempotent, atomic, and retry-safe.
class MigrationV26Service {
  static MigrationV26FailurePoint? _testFailurePoint;

  /// Test-only seam to inject failures at critical migration checkpoints.
  /// Strictly prohibited and disabled in product / release builds.
  @visibleForTesting
  static void setTestFailurePoint(MigrationV26FailurePoint? point) {
    if (const bool.fromEnvironment('dart.vm.product')) {
      throw UnsupportedError(
        'Migration failure injection is strictly prohibited in release/production builds.',
      );
    }
    _testFailurePoint = point;
  }

  /// Package-private getter for testing assertions.
  @visibleForTesting
  static MigrationV26FailurePoint? get testFailurePoint => _testFailurePoint;

  /// Runs Migration V26 using the provided [executor] (supplied by onUpgrade).
  /// Never opens a nested transaction. Exceptions propagate to caller to trigger rollback.
  static Future<void> run(DatabaseExecutor executor) async {
    // Step 1: Create evidence_reconciliations table and unique indices
    await TablesV26.createAllV26(executor);

    if (!const bool.fromEnvironment('dart.vm.product') &&
        _testFailurePoint == MigrationV26FailurePoint.afterTableCreation) {
      throw StateError('Simulated failure after table creation');
    }

    // Step 2: Query ALL evidence rows that have reconciliation markers
    final markerRows = await executor.rawQuery(
      '''
      SELECT id, source_record_id, external_reference, created_at
      FROM evidence
      WHERE external_reference LIKE 'RECONCILED_%'
      ORDER BY id ASC
      ''',
    );

    // Track rows whose reconciliation relationship has been verified/persisted
    // and are therefore safe to cleanse.
    final List<String> rowsToCleanse = [];
    int insertedCount = 0;

    for (final row in markerRows) {
      final rowId = row['id'] as String;
      final sourceRecordId = (row['source_record_id'] as String?)?.trim();
      final extRef = (row['external_reference'] as String?)?.trim();
      final createdAt = row['created_at'] as String? ?? DateTime.now().toUtc().toIso8601String();

      if (sourceRecordId == null || sourceRecordId.isEmpty) {
        throw StateError(
          'Migration v26 failed: evidence row "$rowId" has marker "$extRef" '
          'but missing or empty source_record_id.',
        );
      }

      if (extRef == null || extRef.isEmpty) {
        throw StateError(
          'Migration v26 failed: evidence row "$rowId" has empty external_reference.',
        );
      }

      final String broadcastSourceId;
      final String inboxSourceId;

      if (extRef.startsWith('RECONCILED_TO:')) {
        final targetInbox = extRef.substring('RECONCILED_TO:'.length).trim();
        if (targetInbox.isEmpty) {
          throw StateError(
            'Migration v26 failed: Malformed or incomplete RECONCILED_TO marker in evidence "$rowId": "$extRef".',
          );
        }
        broadcastSourceId = sourceRecordId;
        inboxSourceId = targetInbox;

        // Reciprocal Verification:
        // Find corresponding inbox evidence using source_record_id.
        // Verify its external_reference contains expected RECONCILED_FROM:<broadcastSourceId>.
        final counterpartRows = await executor.query(
          'evidence',
          columns: ['id', 'source_record_id', 'external_reference'],
          where: 'source_record_id = ?',
          whereArgs: [inboxSourceId],
        );

        if (counterpartRows.isEmpty) {
          throw StateError(
            'Migration v26 failed: Missing referenced inbox evidence "$inboxSourceId" '
            'for broadcast marker in evidence "$rowId" ("$extRef").',
          );
        }

        final expectedFrom = 'RECONCILED_FROM:$broadcastSourceId';
        for (final cp in counterpartRows) {
          final cpRef = (cp['external_reference'] as String?)?.trim();
          if (cpRef != expectedFrom) {
            throw StateError(
              'Migration v26 failed: Reciprocal marker mismatch. Broadcast evidence "$rowId" has '
              '"$extRef", but corresponding inbox evidence "${cp['id']}" has '
              'external_reference "$cpRef" (expected "$expectedFrom").',
            );
          }
        }
      } else if (extRef.startsWith('RECONCILED_FROM:')) {
        final targetBroadcast = extRef.substring('RECONCILED_FROM:'.length).trim();
        if (targetBroadcast.isEmpty) {
          throw StateError(
            'Migration v26 failed: Malformed or incomplete RECONCILED_FROM marker in evidence "$rowId": "$extRef".',
          );
        }
        broadcastSourceId = targetBroadcast;
        inboxSourceId = sourceRecordId;

        // Reciprocal Verification:
        // Find corresponding broadcast evidence using source_record_id.
        // Verify its external_reference contains expected RECONCILED_TO:<inboxSourceId>.
        final counterpartRows = await executor.query(
          'evidence',
          columns: ['id', 'source_record_id', 'external_reference'],
          where: 'source_record_id = ?',
          whereArgs: [broadcastSourceId],
        );

        if (counterpartRows.isEmpty) {
          throw StateError(
            'Migration v26 failed: Missing referenced broadcast evidence "$broadcastSourceId" '
            'for inbox marker in evidence "$rowId" ("$extRef").',
          );
        }

        final expectedTo = 'RECONCILED_TO:$inboxSourceId';
        for (final cp in counterpartRows) {
          final cpRef = (cp['external_reference'] as String?)?.trim();
          if (cpRef != expectedTo) {
            throw StateError(
              'Migration v26 failed: Reciprocal marker mismatch. Inbox evidence "$rowId" has '
              '"$extRef", but corresponding broadcast evidence "${cp['id']}" has '
              'external_reference "$cpRef" (expected "$expectedTo").',
            );
          }
        }
      } else {
        throw StateError(
          'Migration v26 failed: Unrecognized or malformed reconciliation marker in evidence "$rowId": "$extRef".',
        );
      }

      // Check existing relationships in evidence_reconciliations
      final existingByBroadcast = await executor.query(
        TablesV26.evidenceReconciliations,
        where: 'broadcast_source_record_id = ?',
        whereArgs: [broadcastSourceId],
      );

      final existingByInbox = await executor.query(
        TablesV26.evidenceReconciliations,
        where: 'inbox_source_record_id = ?',
        whereArgs: [inboxSourceId],
      );

      final hasExistingBroadcast = existingByBroadcast.isNotEmpty;
      final hasExistingInbox = existingByInbox.isNotEmpty;

      if (hasExistingBroadcast && hasExistingInbox) {
        final bInbox = existingByBroadcast.first['inbox_source_record_id'] as String;
        final iBroadcast = existingByInbox.first['broadcast_source_record_id'] as String;

        if (bInbox == inboxSourceId && iBroadcast == broadcastSourceId) {
          // Exact relationship already exists. Idempotent and safe to clear marker.
          rowsToCleanse.add(rowId);
        } else if (bInbox != inboxSourceId && iBroadcast != broadcastSourceId) {
          // Both identities conflict with different existing relationships!
          throw StateError(
            'Migration v26 conflict: Dual identity conflict in evidence "$rowId". '
            'Broadcast "$broadcastSourceId" already linked to "$bInbox" (cannot link to "$inboxSourceId"), '
            'and inbox "$inboxSourceId" already linked to "$iBroadcast" (cannot link to "$broadcastSourceId").',
          );
        } else if (bInbox != inboxSourceId) {
          throw StateError(
            'Migration v26 conflict: Broadcast identity "$broadcastSourceId" in evidence "$rowId" '
            'already belongs to different inbox identity "$bInbox" (cannot link to "$inboxSourceId").',
          );
        } else {
          throw StateError(
            'Migration v26 conflict: Inbox identity "$inboxSourceId" in evidence "$rowId" '
            'already belongs to different broadcast identity "$iBroadcast" (cannot link to "$broadcastSourceId").',
          );
        }
      } else if (hasExistingBroadcast) {
        final bInbox = existingByBroadcast.first['inbox_source_record_id'] as String;
        if (bInbox == inboxSourceId) {
          rowsToCleanse.add(rowId);
        } else {
          throw StateError(
            'Migration v26 conflict: Broadcast identity "$broadcastSourceId" in evidence "$rowId" '
            'already belongs to different inbox identity "$bInbox" (cannot link to "$inboxSourceId").',
          );
        }
      } else if (hasExistingInbox) {
        final iBroadcast = existingByInbox.first['broadcast_source_record_id'] as String;
        if (iBroadcast == broadcastSourceId) {
          rowsToCleanse.add(rowId);
        } else {
          throw StateError(
            'Migration v26 conflict: Inbox identity "$inboxSourceId" in evidence "$rowId" '
            'already belongs to different broadcast identity "$iBroadcast" (cannot link to "$broadcastSourceId").',
          );
        }
      } else {
        // Neither exists: Insert durable relationship
        if (!const bool.fromEnvironment('dart.vm.product') &&
            _testFailurePoint == MigrationV26FailurePoint.duringLegacyInsertion) {
          throw StateError('Simulated failure during legacy relationship insertion');
        }

        await executor.insert(
          TablesV26.evidenceReconciliations,
          {
            'id': const Uuid().v4(),
            'broadcast_source_record_id': broadcastSourceId,
            'inbox_source_record_id': inboxSourceId,
            'reconciliation_method': 'MIGRATED_FROM_EXTERNAL_REFERENCE_V25',
            'created_at': createdAt,
          },
        );
        insertedCount++;

        if (!const bool.fromEnvironment('dart.vm.product') &&
            _testFailurePoint == MigrationV26FailurePoint.afterPartialInsertion &&
            insertedCount > 0) {
          throw StateError('Simulated failure after some relationships have been inserted');
        }

        rowsToCleanse.add(rowId);
      }
    }

    if (!const bool.fromEnvironment('dart.vm.product') &&
        _testFailurePoint == MigrationV26FailurePoint.duringMarkerCleanup) {
      throw StateError('Simulated failure during marker cleanup');
    }

    // Step 3: Only cleanse markers for rows whose relationship has been durably preserved
    for (final rowId in rowsToCleanse) {
      await executor.update(
        'evidence',
        {'external_reference': null},
        where: 'id = ?',
        whereArgs: [rowId],
      );
    }

    // Final safety verification: Ensure NO reconciliation markers remain uncleared
    final uncleared = await executor.rawQuery(
      '''
      SELECT id, external_reference FROM evidence
      WHERE external_reference LIKE 'RECONCILED_%'
      ''',
    );
    if (uncleared.isNotEmpty) {
      throw StateError(
        'Migration v26 verification failed: ${uncleared.length} reconciliation marker(s) '
        'were not safely durably preserved and remained uncleared.',
      );
    }
  }
}
