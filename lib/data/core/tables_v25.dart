import 'package:sqflite/sqflite.dart';

/// SpendX 2.0 Canonical Double-Entry SQLite Schema Extension (v25).
///
/// Single source of truth for all V25 table DDL constants, index definitions,
/// and Triggers 1 through 6. Reused by both the production migration runner
/// [MigrationV25Service] and the fresh-install bootstrap path.
class TablesV25 {
  // Table names
  static const refundAllocations = 'refund_allocations';
  static const migrationHistoricalBaselines = 'migration_historical_baselines';

  // ============================================================================
  // 1. EVIDENCE TABLE ALTERATION & INDEX
  // ============================================================================
  static const addSourceRecordIdColumn = '''
    ALTER TABLE evidence ADD COLUMN source_record_id TEXT;
  ''';

  static const createEvidenceSourceRecordIdIndex = '''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_evidence_source_record 
    ON evidence(source_record_id);
  ''';

  // ============================================================================
  // 2. REFUND ALLOCATIONS TABLE & INDICES
  // ============================================================================
  static const createRefundAllocationsTable = '''
    CREATE TABLE IF NOT EXISTS refund_allocations (
      id TEXT PRIMARY KEY,
      refund_event_id TEXT NOT NULL REFERENCES economic_events(id) ON DELETE RESTRICT,
      original_event_id TEXT NOT NULL REFERENCES economic_events(id) ON DELETE RESTRICT,
      allocated_amount_minor_units INTEGER NOT NULL CHECK(allocated_amount_minor_units > 0),
      created_at TEXT NOT NULL
    );
  ''';

  static const createRefundAllocationsOriginalIndex = '''
    CREATE INDEX IF NOT EXISTS idx_refund_alloc_original 
    ON refund_allocations(original_event_id);
  ''';

  static const createRefundAllocationsRefundIndex = '''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_refund_alloc_refund 
    ON refund_allocations(refund_event_id);
  ''';

  static const createRefundAllocationsPairIndex = '''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_refund_alloc_pair 
    ON refund_allocations(refund_event_id, original_event_id);
  ''';

  // ============================================================================
  // 3. MIGRATION HISTORICAL BASELINES TABLE
  // ============================================================================
  static const createMigrationHistoricalBaselinesTable = '''
    CREATE TABLE IF NOT EXISTS migration_historical_baselines (
      id TEXT PRIMARY KEY,
      migration_version INTEGER NOT NULL,
      watermark_snapshot_date INTEGER,
      watermark_snapshot_id INTEGER,
      created_at TEXT NOT NULL
    );
  ''';

  // ============================================================================
  // 4. REFUND LIFECYCLE & IMMUTABILITY TRIGGER SUITE (Triggers 1 - 6)
  // ============================================================================

  /// Trigger 1: Validate Allocation Insert (Draft Status, Types, Structure, and Cap)
  static const trgRefundAllocationsValidateInsert = '''
    CREATE TRIGGER IF NOT EXISTS trg_refund_allocations_validate_insert
    BEFORE INSERT ON refund_allocations
    BEGIN
      -- A. Enforce that refund_event_id is currently in 'draft' status
      SELECT CASE
        WHEN (SELECT lifecycle_status FROM economic_events WHERE id = NEW.refund_event_id) != 'draft'
        THEN RAISE(ABORT, 'REFUND_ALLOCATION_NOT_DRAFT: allocations can only be attached to draft refund events.')
      END;

      -- B. Enforce that refund_event_id references an event with event_type = 'refund'
      SELECT CASE
        WHEN (SELECT event_type FROM economic_events WHERE id = NEW.refund_event_id) != 'refund'
        THEN RAISE(ABORT, 'REFUND_ALLOCATION_INVALID_EVENT_TYPE: refund_event_id must be event_type refund')
      END;

      -- C. Enforce that original_event_id is strictly an eligible merchant debit ('expense' or 'credit_purchase')
      SELECT CASE
        WHEN (SELECT event_type FROM economic_events WHERE id = NEW.original_event_id) 
             NOT IN ('expense', 'credit_purchase')
        THEN RAISE(ABORT, 'REFUND_ALLOCATION_INVALID_PARENT_TYPE: original_event_id must be an expense or credit_purchase')
      END;

      -- D. Enforce that the parent purchase has EXACTLY ONE asset/liability credit posting (structural validity)
      SELECT CASE
        WHEN (
          SELECT COUNT(*)
          FROM postings p
          JOIN accounts a ON p.account_id = a.id
          WHERE p.economic_event_id = NEW.original_event_id
            AND a.account_type IN ('asset', 'liability')
            AND p.direction = 'credit'
        ) != 1
        THEN RAISE(ABORT, 'PARENT_PURCHASE_AMBIGUOUS_STRUCTURE: parent event must have exactly one asset/liability credit posting')
      END;

      -- E. Enforce cumulative allocated cap against the unique parent purchase amount
      SELECT CASE
        WHEN (
          COALESCE((
            SELECT SUM(ra.allocated_amount_minor_units)
            FROM refund_allocations ra
            JOIN economic_events ee ON ra.refund_event_id = ee.id
            WHERE ra.original_event_id = NEW.original_event_id
              AND ee.lifecycle_status = 'posted'
          ), 0) + NEW.allocated_amount_minor_units
        ) > (
          SELECT p.amount_minor_units
          FROM postings p
          JOIN accounts a ON p.account_id = a.id
          WHERE p.economic_event_id = NEW.original_event_id
            AND a.account_type IN ('asset', 'liability')
            AND p.direction = 'credit'
        )
        THEN RAISE(ABORT, 'REFUND_ALLOCATION_EXCEEDS_ORIGINAL_AMOUNT: cumulative allocations exceed original purchase amount')
      END;
    END;
  ''';

  /// Trigger 2: Complete Immutability of Refund Allocations
  static const trgRefundAllocationsPreventUpdate = '''
    CREATE TRIGGER IF NOT EXISTS trg_refund_allocations_prevent_update
    BEFORE UPDATE ON refund_allocations
    BEGIN
      SELECT RAISE(ABORT, 'IMMUTABILITY_VIOLATION: refund_allocations rows are strictly immutable.');
    END;
  ''';

  /// Trigger 3: Prevent Direct Deletion of Refund Allocations
  static const trgRefundAllocationsPreventDelete = '''
    CREATE TRIGGER IF NOT EXISTS trg_refund_allocations_prevent_delete
    BEFORE DELETE ON refund_allocations
    BEGIN
      SELECT RAISE(ABORT, 'IMMUTABILITY_VIOLATION: direct deletion of refund_allocations is prohibited.');
    END;
  ''';

  /// Trigger 4: Prevent Direct Insertion of Already-Posted Refund
  static const trgEconomicEventsPreventDirectPostedRefund = '''
    CREATE TRIGGER IF NOT EXISTS trg_economic_events_prevent_direct_posted_refund
    BEFORE INSERT ON economic_events
    WHEN NEW.event_type = 'refund' AND NEW.lifecycle_status = 'posted'
    BEGIN
      SELECT RAISE(ABORT, 'REFUND_INSERT_VIOLATION: refund events must be inserted as draft before posting.');
    END;
  ''';

  /// Trigger 5: Protect Parent Purchases from Deletion or Invalidation
  static const trgEconomicEventsProtectRefundedParents = '''
    CREATE TRIGGER IF NOT EXISTS trg_economic_events_protect_refunded_parents
    BEFORE UPDATE OF event_type, lifecycle_status ON economic_events
    WHEN OLD.id IN (SELECT original_event_id FROM refund_allocations)
    BEGIN
      SELECT CASE
        WHEN NEW.event_type NOT IN ('expense', 'credit_purchase')
        THEN RAISE(ABORT, 'REFUND_PARENT_TYPE_VIOLATION: cannot change event_type of an event with active refund allocations')
      END;

      SELECT CASE
        WHEN NEW.lifecycle_status IN ('reversed', 'deleted') AND EXISTS (
          SELECT 1 
          FROM refund_allocations ra
          JOIN economic_events ee ON ra.refund_event_id = ee.id
          WHERE ra.original_event_id = OLD.id
            AND ee.lifecycle_status = 'posted'
        )
        THEN RAISE(ABORT, 'CANNOT_REVERSE_PARENT_WITH_ACTIVE_REFUNDS: active refund allocations must be reversed/deleted before parent purchase.')
      END;
    END;
  ''';

  /// Trigger 6: Complete Refund Posting & Restoration Validation
  static const trgEconomicEventsValidateRefundPosted = '''
    CREATE TRIGGER IF NOT EXISTS trg_economic_events_validate_refund_posted
    BEFORE UPDATE OF lifecycle_status ON economic_events
    FOR EACH ROW
    WHEN NEW.lifecycle_status = 'posted' AND OLD.lifecycle_status != 'posted' AND NEW.event_type = 'refund'
    BEGIN
      SELECT CASE
        WHEN (
          SELECT COUNT(*)
          FROM refund_allocations ra
          WHERE ra.refund_event_id = NEW.id
        ) != 1
        THEN RAISE(ABORT, 'REFUND_POST_VIOLATION: posted refund event must have exactly one row in refund_allocations')
      END;

      SELECT CASE
        WHEN (
          SELECT COUNT(*)
          FROM postings p
          JOIN accounts a ON p.account_id = a.id
          WHERE p.economic_event_id = NEW.id
            AND a.account_type IN ('asset', 'liability')
            AND p.direction = 'debit'
        ) != 1
        THEN RAISE(ABORT, 'REFUND_AMBIGUOUS_STRUCTURE: refund event must have exactly one asset/liability debit posting')
      END;

      SELECT CASE
        WHEN (
          SELECT ra.allocated_amount_minor_units
          FROM refund_allocations ra
          WHERE ra.refund_event_id = NEW.id
        ) != (
          SELECT p.amount_minor_units
          FROM postings p
          JOIN accounts a ON p.account_id = a.id
          WHERE p.economic_event_id = NEW.id
            AND a.account_type IN ('asset', 'liability')
            AND p.direction = 'debit'
          LIMIT 1
        )
        THEN RAISE(ABORT, 'REFUND_POST_AMOUNT_MISMATCH: allocated_amount_minor_units must equal refund debit posting amount')
      END;

      SELECT CASE
        WHEN (
          COALESCE((
            SELECT SUM(ra.allocated_amount_minor_units)
            FROM refund_allocations ra
            JOIN economic_events ee ON ra.refund_event_id = ee.id
            WHERE ra.original_event_id = (SELECT original_event_id FROM refund_allocations WHERE refund_event_id = NEW.id)
              AND ee.lifecycle_status = 'posted'
              AND ee.id != NEW.id
          ), 0) + (
            SELECT ra.allocated_amount_minor_units
            FROM refund_allocations ra
            WHERE ra.refund_event_id = NEW.id
          )
        ) > (
          SELECT p.amount_minor_units
          FROM postings p
          JOIN accounts a ON p.account_id = a.id
          WHERE p.economic_event_id = (SELECT original_event_id FROM refund_allocations WHERE refund_event_id = NEW.id)
            AND a.account_type IN ('asset', 'liability')
            AND p.direction = 'credit'
        )
        THEN RAISE(ABORT, 'REFUND_RESTORATION_EXCEEDS_CAP: activating refund violates original purchase cumulative cap')
      END;
    END;
  ''';

  // ============================================================================
  // 5. QUERY LISTS
  // ============================================================================

  static const allTableCreateQueries = <String>[
    createRefundAllocationsTable,
    createRefundAllocationsOriginalIndex,
    createRefundAllocationsRefundIndex,
    createRefundAllocationsPairIndex,
    createMigrationHistoricalBaselinesTable,
  ];

  static const allTriggerCreateQueries = <String>[
    trgRefundAllocationsValidateInsert,
    trgRefundAllocationsPreventUpdate,
    trgRefundAllocationsPreventDelete,
    trgEconomicEventsPreventDirectPostedRefund,
    trgEconomicEventsProtectRefundedParents,
    trgEconomicEventsValidateRefundPosted,
  ];

  static const allTriggerDropQueries = <String>[
    'DROP TRIGGER IF EXISTS trg_refund_allocations_validate_insert;',
    'DROP TRIGGER IF EXISTS trg_refund_allocations_prevent_update;',
    'DROP TRIGGER IF EXISTS trg_refund_allocations_prevent_delete;',
    'DROP TRIGGER IF EXISTS trg_economic_events_prevent_direct_posted_refund;',
    'DROP TRIGGER IF EXISTS trg_economic_events_protect_refunded_parents;',
    'DROP TRIGGER IF EXISTS trg_economic_events_validate_refund_posted;',
  ];

  // ============================================================================
  // 6. LIFECYCLE HELPERS
  // ============================================================================

  /// Creates all V25 canonical tables and indexes, ensuring `evidence.source_record_id` exists.
  static Future<void> createAllV25(DatabaseExecutor db) async {
    // 1. Ensure source_record_id column exists on evidence
    final cols = await db.rawQuery('PRAGMA table_info(evidence);');
    final hasCol = cols.any((c) => c['name'] == 'source_record_id');
    if (!hasCol) {
      await db.execute(addSourceRecordIdColumn);
    }
    await db.execute(createEvidenceSourceRecordIdIndex);

    // 2. Create tables & indexes
    for (final q in allTableCreateQueries) {
      await db.execute(q);
    }
  }

  /// Installs the V25 refund lifecycle trigger suite.
  static Future<void> installTriggers(DatabaseExecutor db) async {
    for (final q in allTriggerCreateQueries) {
      await db.execute(q);
    }
  }

  /// Drops the V25 trigger suite.
  static Future<void> dropTriggers(DatabaseExecutor db) async {
    for (final q in allTriggerDropQueries) {
      await db.execute(q);
    }
  }
}
