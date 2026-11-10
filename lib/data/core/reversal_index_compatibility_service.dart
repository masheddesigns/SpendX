import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'tables_v24.dart';

/// Status result from checking/applying the reversal unique index.
enum ReversalIndexStatus {
  /// Unique index was already installed; no action needed.
  alreadyInstalled,

  /// Clean database; unique index was created successfully.
  created,

  /// Existing database contains duplicate reversals; index creation was deferred
  /// to prevent database lockout, and warning was logged to migration_exceptions.
  deferredDueToDuplicates,
}

/// Result of a controlled remediation run.
class ReversalRemediationResult {
  final bool success;
  final int groupsRemediated;
  final int duplicatesNeutralized;
  final List<String> compensatingEventIds;
  final bool uniqueIndexCreated;
  final String? errorMessage;

  const ReversalRemediationResult({
    required this.success,
    required this.groupsRemediated,
    required this.duplicatesNeutralized,
    required this.compensatingEventIds,
    required this.uniqueIndexCreated,
    this.errorMessage,
  });
}

/// Compatibility service to safely manage the lifecycle and installation of
/// [TablesV24.createEconomicEventsUniqueReversalIndex] without locking out
/// existing user databases containing historical duplicate reversals.
class ReversalIndexCompatibilityService {
  /// Ensures the partial unique index is installed safely.
  ///
  /// If no duplicate non-null reversal references exist, installs the unique index.
  /// If duplicates exist, preserves all financial records, defers index installation,
  /// and logs an auditable entry in `migration_exceptions` to allow startup to succeed.
  static Future<ReversalIndexStatus> ensureReversalIndex(DatabaseExecutor db) async {
    // 1. Check if index already exists
    final indexCheck = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_events_unique_reversal';",
    );
    if (indexCheck.isNotEmpty) {
      return ReversalIndexStatus.alreadyInstalled;
    }

    // 2. Check for duplicate non-null reversal_of_event_id references
    final duplicateGroups = await getDuplicateReversalGroups(db);

    if (duplicateGroups.isEmpty) {
      // Clean database: safe to create unique index
      await db.execute(TablesV24.createEconomicEventsUniqueReversalIndex);
      return ReversalIndexStatus.created;
    }

    // 3. Duplicates detected: defer index creation to avoid startup crash.
    // Preserve all financial records intact and log auditable warning to migration_exceptions.
    for (final group in duplicateGroups) {
      final reversalTargetId = group['reversal_of_event_id'] as String;
      final dupCount = (group['duplicate_count'] as num).toInt();

      // Ensure we don't insert duplicate exception records on repeated database opens
      final existingException = await db.query(
        TablesV24.migrationExceptions,
        where: 'record_id = ? AND error_code = ?',
        whereArgs: [reversalTargetId, 'ERR_DUPLICATE_REVERSAL_DEFERRED_INDEX'],
        limit: 1,
      );

      if (existingException.isEmpty) {
        await db.insert(
          TablesV24.migrationExceptions,
          {
            'id': 'exc_rev_dup_${reversalTargetId}_${DateTime.now().millisecondsSinceEpoch}',
            'record_id': reversalTargetId,
            'table_name': TablesV24.economicEvents,
            'error_code': 'ERR_DUPLICATE_REVERSAL_DEFERRED_INDEX',
            'raw_payload': jsonEncode({
              'reversal_of_event_id': reversalTargetId,
              'duplicate_count': dupCount,
            }),
            'message': 'Deferred unique index creation: economic_events contains $dupCount '
                'duplicate reversals for target event $reversalTargetId. Write guards active.',
            'created_at': DateTime.now().toUtc().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }

    return ReversalIndexStatus.deferredDueToDuplicates;
  }

  /// Queries all duplicate reversal groups in [TablesV24.economicEvents].
  static Future<List<Map<String, Object?>>> getDuplicateReversalGroups(
      DatabaseExecutor db) async {
    return await db.rawQuery('''
      SELECT reversal_of_event_id, COUNT(*) AS duplicate_count
      FROM ${TablesV24.economicEvents}
      WHERE reversal_of_event_id IS NOT NULL
      GROUP BY reversal_of_event_id
      HAVING COUNT(*) > 1;
    ''');
  }

  /// Controlled append-only remediation path:
  /// Neutralizes financial drift from duplicate reversals without modifying any posted events.
  /// 
  /// 1. Identifies the canonical reversal (earliest created).
  /// 2. For each extraneous duplicate reversal:
  ///    a. Uses deterministic compensation ID: `comp_rev_${dupId}`.
  ///    b. Validates existing compensation contents if present (idempotent retry).
  ///    c. Generates a balanced compensating adjustment event to neutralize balance drift.
  ///    d. Leaves original duplicate reversal, its pointer, and postings 100% untouched.
  /// 3. Preserves deferred unique-index state on databases retaining duplicate pointers.
  static Future<ReversalRemediationResult> remediateDuplicateReversals(
      Database db) async {
    return await db.transaction<ReversalRemediationResult>((txn) async {
      final duplicateGroups = await getDuplicateReversalGroups(txn);
      if (duplicateGroups.isEmpty) {
        final idxStatus = await ensureReversalIndex(txn);
        return ReversalRemediationResult(
          success: true,
          groupsRemediated: 0,
          duplicatesNeutralized: 0,
          compensatingEventIds: const [],
          uniqueIndexCreated: idxStatus == ReversalIndexStatus.created ||
              idxStatus == ReversalIndexStatus.alreadyInstalled,
        );
      }

      int groupsRemediated = 0;
      int duplicatesNeutralized = 0;
      final compensatingEventIds = <String>[];
      final nowUtc = DateTime.now().toUtc();
      final nowStr = nowUtc.toIso8601String();

      for (final group in duplicateGroups) {
        final targetEventId = group['reversal_of_event_id'] as String;

        // Query all reversal events for this target, ordered by creation time
        final reversals = await txn.query(
          TablesV24.economicEvents,
          where: 'reversal_of_event_id = ?',
          whereArgs: [targetEventId],
          orderBy: 'created_at ASC, id ASC',
        );

        if (reversals.length <= 1) continue;

        final canonicalReversal = reversals.first;
        final canonicalId = canonicalReversal['id'] as String;
        final duplicateEvents = reversals.skip(1);

        for (final dup in duplicateEvents) {
          final dupId = dup['id'] as String;
          final compEventId = 'comp_rev_$dupId';

          // Query postings for this duplicate reversal
          final dupPostings = await txn.query(
            TablesV24.postings,
            where: 'economic_event_id = ?',
            whereArgs: [dupId],
            orderBy: 'sequence_number ASC',
          );

          if (dupPostings.isEmpty) {
            throw StateError(
              'Cannot remediate duplicate reversal $dupId: no postings found.',
            );
          }

          // Check whether deterministic compensation event already exists
          final existingCompRows = await txn.query(
            TablesV24.economicEvents,
            where: 'id = ?',
            whereArgs: [compEventId],
          );

          if (existingCompRows.isNotEmpty) {
            // Validate existing compensation record contents
            final compRow = existingCompRows.first;
            if (compRow['event_type'] != 'adjustment' ||
                compRow['lifecycle_status'] != 'posted') {
              throw StateError(
                'Invalid existing compensation record $compEventId: unexpected event_type or lifecycle_status.',
              );
            }

            final compNotes = compRow['notes'] as String?;
            Map<String, dynamic> notesMap = {};
            if (compNotes != null && compNotes.isNotEmpty) {
              try {
                notesMap = jsonDecode(compNotes) as Map<String, dynamic>;
              } catch (_) {}
            }

            if (notesMap['action'] != 'DEF-504_remediation' ||
                notesMap['compensates_event_id'] != dupId ||
                notesMap['original_target_event_id'] != targetEventId) {
              throw StateError(
                'Invalid existing compensation record $compEventId: provenance metadata mismatch.',
              );
            }

            // Validate postings parity
            final existingCompPostings = await txn.query(
              TablesV24.postings,
              where: 'economic_event_id = ?',
              whereArgs: [compEventId],
              orderBy: 'sequence_number ASC',
            );
            if (existingCompPostings.length != dupPostings.length) {
              throw StateError(
                'Invalid existing compensation record $compEventId: posting count mismatch (${existingCompPostings.length} vs ${dupPostings.length}).',
              );
            }

            for (int i = 0; i < dupPostings.length; i++) {
              final dp = dupPostings[i];
              final cp = existingCompPostings[i];
              final expectedOpposite = dp['direction'] == 'debit' ? 'credit' : 'debit';
              if (cp['account_id'] != dp['account_id'] ||
                  cp['direction'] != expectedOpposite ||
                  cp['amount_minor_units'] != dp['amount_minor_units']) {
                throw StateError(
                  'Invalid existing compensation record $compEventId: posting leg $i mismatch.',
                );
              }
            }

            // Valid pre-existing compensation; idempotent retry
            compensatingEventIds.add(compEventId);
            duplicatesNeutralized++;
            continue;
          }

          // 1. Create compensating event in draft status with deterministic ID
          await txn.insert(TablesV24.economicEvents, {
            'id': compEventId,
            'event_type': 'adjustment',
            'lifecycle_status': 'draft',
            'timestamp': nowStr,
            'currency': 'INR',
            'description': 'Compensating adjustment for redundant duplicate reversal $dupId',
            'notes': jsonEncode({
              'action': 'DEF-504_remediation',
              'compensates_event_id': dupId,
              'original_target_event_id': targetEventId,
              'canonical_reversal_id': canonicalId,
              'created_at': nowStr,
            }),
            'created_at': nowStr,
            'updated_at': nowStr,
          });

          // 2. Insert equal & opposite postings
          int seq = 1;
          for (final p in dupPostings) {
            final origDirection = p['direction'] as String;
            final oppositeDirection = origDirection == 'debit' ? 'credit' : 'debit';
            await txn.insert(TablesV24.postings, {
              'id': 'pos_${compEventId}_$seq',
              'economic_event_id': compEventId,
              'account_id': p['account_id'],
              'sequence_number': seq,
              'direction': oppositeDirection,
              'amount_minor_units': p['amount_minor_units'],
              'currency': 'INR',
              'created_at': nowStr,
            });
            seq++;
          }

          // 3. Post the compensating event (enforcing SQLite immutability & balance triggers)
          await txn.update(
            TablesV24.economicEvents,
            {
              'lifecycle_status': 'posted',
              'updated_at': nowStr,
            },
            where: 'id = ? AND lifecycle_status = ?',
            whereArgs: [compEventId, 'draft'],
          );
          compensatingEventIds.add(compEventId);

          // ABSOLUTE IMMUTABILITY:
          // The duplicate reversal event dup and its postings are NOT modified.
          // Historical records remain 100% byte-for-byte unchanged.

          // 4. Audit log remediation in migration_exceptions
          await txn.insert(
            TablesV24.migrationExceptions,
            {
              'id': 'exc_rem_${dupId}_${nowUtc.millisecondsSinceEpoch}',
              'record_id': dupId,
              'table_name': TablesV24.economicEvents,
              'error_code': 'ERR_DUPLICATE_REVERSAL_REMEDIATED_APPEND_ONLY',
              'raw_payload': jsonEncode({
                'duplicate_event_id': dupId,
                'target_event_id': targetEventId,
                'canonical_reversal_id': canonicalId,
                'compensating_event_id': compEventId,
              }),
              'message': 'Duplicate reversal $dupId neutralized via append-only compensating adjustment $compEventId. Historical records preserved intact.',
              'created_at': nowStr,
            },
          );

          duplicatesNeutralized++;
        }
        groupsRemediated++;
      }

      // DO NOT force unique index creation where original duplicate pointers remain.
      // Index remains deferred on this database to preserve historical duplicate pointers.

      return ReversalRemediationResult(
        success: true,
        groupsRemediated: groupsRemediated,
        duplicatesNeutralized: duplicatesNeutralized,
        compensatingEventIds: compensatingEventIds,
        uniqueIndexCreated: false,
      );
    });
  }
}
