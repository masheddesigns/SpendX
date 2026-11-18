import 'package:sqflite/sqflite.dart';

/// SpendX 2.0 Canonical Double-Entry SQLite Schema Extension (v26).
///
/// Dedicated table and indices for durable cross-channel evidence reconciliation.
/// Separates reconciliation metadata from genuine financial external references (UTR/RRN).
class TablesV26 {
  // Table name
  static const evidenceReconciliations = 'evidence_reconciliations';

  // ============================================================================
  // 1. EVIDENCE RECONCILIATIONS TABLE & INDICES
  // ============================================================================
  static const createEvidenceReconciliationsTable = '''
    CREATE TABLE IF NOT EXISTS evidence_reconciliations (
      id TEXT PRIMARY KEY,
      broadcast_source_record_id TEXT NOT NULL UNIQUE,
      inbox_source_record_id TEXT NOT NULL UNIQUE,
      reconciliation_method TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
  ''';

  static const createEvidenceReconciliationsBroadcastIndex = '''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_evidence_reconciliations_broadcast 
    ON evidence_reconciliations(broadcast_source_record_id);
  ''';

  static const createEvidenceReconciliationsInboxIndex = '''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_evidence_reconciliations_inbox 
    ON evidence_reconciliations(inbox_source_record_id);
  ''';

  /// Creates all V26 canonical tables and indexes.
  static Future<void> createAllV26(DatabaseExecutor db) async {
    await db.execute(createEvidenceReconciliationsTable);
    await db.execute(createEvidenceReconciliationsBroadcastIndex);
    await db.execute(createEvidenceReconciliationsInboxIndex);
  }
}
