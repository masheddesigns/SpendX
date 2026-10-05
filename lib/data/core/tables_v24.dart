import 'package:sqflite/sqflite.dart';

/// SpendX 2.0 Canonical Double-Entry SQLite Schema (v24).
///
/// Contains canonical table names, DDL creation statements, index DDLs,
/// trigger DDLs, and default system account identifiers.
class TablesV24 {
  // Table names
  static const accounts = 'accounts';
  static const economicEvents = 'economic_events';
  static const evidence = 'evidence';
  static const postings = 'postings';
  static const assetEarmarks = 'asset_earmarks';
  static const recurringRules = 'recurring_rules';
  static const expectedEvents = 'expected_events';
  static const reviewCandidates = 'review_candidates';
  static const openingBalanceReconciliations = 'opening_balance_reconciliations';
  static const migrationExceptions = 'migration_exceptions';

  // System Account Identifiers
  static const sysEquityOpening = 'sys_equity_opening';
  static const sysEquityAdj = 'sys_equity_adj';
  static const sysExpRefunds = 'sys_exp_refunds';
  static const sysExpMisc = 'sys_exp_misc';
  static const sysIncMisc = 'sys_inc_misc';
  static const sysExpInterest = 'sys_exp_interest';
  static const sysSuspenseTransfer = 'sys_suspense_transfer';
  static const sysSuspenseCard = 'sys_suspense_card';
  static const sysSuspenseLoan = 'sys_suspense_loan';

  // ============================================================================
  // 1. ACCOUNTS TABLE
  // ============================================================================
  static const createAccounts = '''
    CREATE TABLE IF NOT EXISTS $accounts (
      id TEXT PRIMARY KEY,
      account_type TEXT NOT NULL CHECK(account_type IN ('asset', 'liability', 'equity', 'income', 'expense')),
      subtype TEXT NOT NULL,
      name TEXT NOT NULL,
      currency TEXT NOT NULL DEFAULT 'INR',
      is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0, 1)),
      is_system INTEGER NOT NULL DEFAULT 0 CHECK(is_system IN (0, 1)),
      parent_account_id TEXT REFERENCES $accounts(id) ON DELETE RESTRICT,
      institution_name TEXT,
      account_number_last4 TEXT,
      color_hex TEXT,
      icon_name TEXT,
      credit_limit_minor_units INTEGER CHECK(credit_limit_minor_units IS NULL OR credit_limit_minor_units >= 0),
      billing_cycle_day INTEGER CHECK(billing_cycle_day IS NULL OR billing_cycle_day BETWEEN 1 AND 31),
      payment_due_day INTEGER CHECK(payment_due_day IS NULL OR payment_due_day BETWEEN 1 AND 31),
      principal_original_minor_units INTEGER CHECK(principal_original_minor_units IS NULL OR principal_original_minor_units >= 0),
      interest_rate_basis_points INTEGER CHECK(interest_rate_basis_points IS NULL OR interest_rate_basis_points >= 0),
      tenure_months INTEGER CHECK(tenure_months IS NULL OR tenure_months > 0),
      monthly_installment_minor_units INTEGER CHECK(monthly_installment_minor_units IS NULL OR monthly_installment_minor_units >= 0),
      start_date TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''';

  static const createAccountsTypeSubtypeIndex = '''
    CREATE INDEX IF NOT EXISTS idx_accounts_type_subtype ON $accounts(account_type, subtype);
  ''';

  static const createAccountsParentIndex = '''
    CREATE INDEX IF NOT EXISTS idx_accounts_parent ON $accounts(parent_account_id);
  ''';

  // ============================================================================
  // 2. ECONOMIC EVENTS TABLE
  // ============================================================================
  static const createEconomicEvents = '''
    CREATE TABLE IF NOT EXISTS $economicEvents (
      id TEXT PRIMARY KEY,
      event_type TEXT NOT NULL CHECK(event_type IN (
        'expense',
        'income',
        'transfer',
        'credit_purchase',
        'liability_settlement',
        'refund',
        'lending_disbursement',
        'lending_repayment',
        'borrowing_disbursement',
        'borrowing_repayment',
        'loan_disbursement',
        'loan_payment',
        'salary_receipt',
        'opening_balance',
        'adjustment'
      )),
      lifecycle_status TEXT NOT NULL DEFAULT 'draft' CHECK(lifecycle_status IN ('draft', 'posted', 'reversed', 'deleted')),
      timestamp TEXT NOT NULL,
      currency TEXT NOT NULL DEFAULT 'INR',
      description TEXT NOT NULL,
      merchant_normalized TEXT,
      category_id TEXT REFERENCES $accounts(id) ON DELETE RESTRICT,
      notes TEXT,
      reversal_of_event_id TEXT REFERENCES $economicEvents(id) ON DELETE RESTRICT,
      corrected_by_event_id TEXT REFERENCES $economicEvents(id) ON DELETE RESTRICT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''';

  static const createEconomicEventsTimestampIndex = '''
    CREATE INDEX IF NOT EXISTS idx_events_timestamp ON $economicEvents(timestamp);
  ''';

  static const createEconomicEventsTypeStatusIndex = '''
    CREATE INDEX IF NOT EXISTS idx_events_type_status ON $economicEvents(event_type, lifecycle_status);
  ''';

  static const createEconomicEventsCategoryIndex = '''
    CREATE INDEX IF NOT EXISTS idx_events_category ON $economicEvents(category_id);
  ''';

  // ============================================================================
  // 3. EVIDENCE TABLE
  // ============================================================================
  static const createEvidence = '''
    CREATE TABLE IF NOT EXISTS $evidence (
      id TEXT PRIMARY KEY,
      economic_event_id TEXT REFERENCES $economicEvents(id) ON DELETE CASCADE,
      source_type TEXT NOT NULL CHECK(source_type IN (
        'sms', 'ocr', 'manual', 'import_csv', 'backup', 'system',
        'migration_v24_reconciliation', 'migration_v24_unbacked_balance'
      )),
      extracted_amount_minor_units INTEGER NOT NULL CHECK(extracted_amount_minor_units >= 0),
      extracted_timestamp TEXT NOT NULL,
      sender_address TEXT,
      external_reference TEXT,
      body_sha256 TEXT NOT NULL,
      raw_payload_encrypted TEXT,
      retention_expires_at TEXT,
      is_payload_purged INTEGER NOT NULL DEFAULT 0 CHECK(is_payload_purged IN (0, 1)),
      created_at TEXT NOT NULL
    );
  ''';

  static const createEvidenceEventIndex = '''
    CREATE INDEX IF NOT EXISTS idx_evidence_event_id ON $evidence(economic_event_id);
  ''';

  static const createEvidenceExternalRefIndex = '''
    CREATE INDEX IF NOT EXISTS idx_evidence_external_ref ON $evidence(external_reference);
  ''';

  static const createEvidenceBodyHashIndex = '''
    CREATE INDEX IF NOT EXISTS idx_evidence_body_hash ON $evidence(body_sha256);
  ''';

  static const createEvidenceRetentionIndex = '''
    CREATE INDEX IF NOT EXISTS idx_evidence_retention ON $evidence(retention_expires_at, is_payload_purged);
  ''';

  // ============================================================================
  // 4. POSTINGS TABLE
  // ============================================================================
  static const createPostings = '''
    CREATE TABLE IF NOT EXISTS $postings (
      id TEXT PRIMARY KEY,
      economic_event_id TEXT NOT NULL REFERENCES $economicEvents(id) ON DELETE CASCADE,
      account_id TEXT NOT NULL REFERENCES $accounts(id) ON DELETE RESTRICT,
      sequence_number INTEGER NOT NULL DEFAULT 1 CHECK(sequence_number >= 1),
      direction TEXT NOT NULL CHECK(direction IN ('debit', 'credit')),
      amount_minor_units INTEGER NOT NULL CHECK(amount_minor_units > 0),
      currency TEXT NOT NULL DEFAULT 'INR',
      created_at TEXT NOT NULL
    );
  ''';

  static const createPostingsEventIndex = '''
    CREATE INDEX IF NOT EXISTS idx_postings_event ON $postings(economic_event_id);
  ''';

  static const createPostingsAccountIndex = '''
    CREATE INDEX IF NOT EXISTS idx_postings_account ON $postings(account_id);
  ''';

  static const createPostingsAccountDirectionIndex = '''
    CREATE INDEX IF NOT EXISTS idx_postings_account_direction ON $postings(account_id, direction);
  ''';

  // ============================================================================
  // 5. ASSET EARMARKS TABLE
  // ============================================================================
  static const createAssetEarmarks = '''
    CREATE TABLE IF NOT EXISTS $assetEarmarks (
      id TEXT PRIMARY KEY,
      goal_id TEXT NOT NULL,
      asset_account_id TEXT NOT NULL REFERENCES $accounts(id) ON DELETE RESTRICT,
      amount_minor_units INTEGER NOT NULL CHECK(amount_minor_units >= 0),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CONSTRAINT uq_goal_account_earmark UNIQUE (goal_id, asset_account_id)
    );
  ''';

  static const createAssetEarmarksGoalIndex = '''
    CREATE INDEX IF NOT EXISTS idx_earmarks_goal ON $assetEarmarks(goal_id);
  ''';

  static const createAssetEarmarksAccountIndex = '''
    CREATE INDEX IF NOT EXISTS idx_earmarks_asset_account ON $assetEarmarks(asset_account_id);
  ''';

  // ============================================================================
  // 6. RECURRING RULES & EXPECTED EVENTS TABLES
  // ============================================================================
  static const createRecurringRules = '''
    CREATE TABLE IF NOT EXISTS $recurringRules (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      category_account_id TEXT REFERENCES $accounts(id) ON DELETE RESTRICT,
      target_account_id TEXT REFERENCES $accounts(id) ON DELETE RESTRICT,
      amount_minor_units INTEGER NOT NULL CHECK(amount_minor_units > 0),
      cadence TEXT NOT NULL CHECK(cadence IN ('daily', 'weekly', 'monthly', 'quarterly', 'yearly')),
      day_of_month INTEGER CHECK(day_of_month IS NULL OR day_of_month BETWEEN 1 AND 31),
      day_of_week INTEGER CHECK(day_of_week IS NULL OR day_of_week BETWEEN 1 AND 7),
      next_due_date TEXT NOT NULL,
      is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0, 1)),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''';

  static const createExpectedEvents = '''
    CREATE TABLE IF NOT EXISTS $expectedEvents (
      id TEXT PRIMARY KEY,
      rule_id TEXT REFERENCES $recurringRules(id) ON DELETE CASCADE,
      due_date TEXT NOT NULL,
      amount_minor_units INTEGER NOT NULL CHECK(amount_minor_units > 0),
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'fulfilled', 'overdue', 'dismissed')),
      fulfilled_event_id TEXT REFERENCES $economicEvents(id) ON DELETE SET NULL,
      created_at TEXT NOT NULL
    );
  ''';

  static const createExpectedEventsDueStatusIndex = '''
    CREATE INDEX IF NOT EXISTS idx_expected_due_status ON $expectedEvents(due_date, status);
  ''';

  // ============================================================================
  // 7. REVIEW CANDIDATES TABLE
  // ============================================================================
  static const createReviewCandidates = '''
    CREATE TABLE IF NOT EXISTS $reviewCandidates (
      id TEXT PRIMARY KEY,
      source_type TEXT NOT NULL,
      raw_payload TEXT,
      suggested_event_type TEXT NOT NULL,
      suggested_amount_minor_units INTEGER NOT NULL,
      suggested_account_id TEXT REFERENCES $accounts(id) ON DELETE SET NULL,
      suggested_category_id TEXT REFERENCES $accounts(id) ON DELETE SET NULL,
      confidence_score REAL NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'approved', 'rejected')),
      created_at TEXT NOT NULL
    );
  ''';

  // ============================================================================
  // 8. OPENING BALANCE RECONCILIATIONS TABLE
  // ============================================================================
  static const createOpeningBalanceReconciliations = '''
    CREATE TABLE IF NOT EXISTS $openingBalanceReconciliations (
      id TEXT PRIMARY KEY,
      account_id TEXT NOT NULL REFERENCES $accounts(id) ON DELETE CASCADE,
      legacy_reported_balance_minor_units INTEGER NOT NULL,
      reconstructed_balance_minor_units INTEGER NOT NULL,
      adjustment_delta_minor_units INTEGER NOT NULL,
      reconciliation_reason TEXT NOT NULL,
      provenance_source TEXT NOT NULL,
      status TEXT NOT NULL,
      generated_event_id TEXT REFERENCES $economicEvents(id) ON DELETE SET NULL,
      created_at TEXT NOT NULL
    );
  ''';

  static const createOpeningBalanceReconciliationsAccountIndex = '''
    CREATE INDEX IF NOT EXISTS idx_obr_account ON $openingBalanceReconciliations(account_id);
  ''';

  // ============================================================================
  // 9. MIGRATION EXCEPTIONS AUDIT TABLE
  // ============================================================================
  static const createMigrationExceptions = '''
    CREATE TABLE IF NOT EXISTS $migrationExceptions (
      id TEXT PRIMARY KEY,
      record_id TEXT,
      table_name TEXT,
      error_code TEXT NOT NULL,
      raw_payload TEXT,
      message TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
  ''';

  // ============================================================================
  // 10. NATIVE SQLITE TRIGGERS (5 + 2 Immutability Suite)
  // ============================================================================
  static const trgEconomicEventsPreventDirectPostedInsert = '''
    CREATE TRIGGER IF NOT EXISTS trg_economic_events_prevent_direct_posted_insert
    BEFORE INSERT ON $economicEvents
    FOR EACH ROW
    WHEN NEW.lifecycle_status = 'posted'
    BEGIN
      SELECT RAISE(ABORT, 'EconomicEvents must be created with lifecycle_status = "draft".');
    END;
  ''';

  static const trgEconomicEventsValidatePosted = '''
    CREATE TRIGGER IF NOT EXISTS trg_economic_events_validate_posted
    BEFORE UPDATE OF lifecycle_status ON $economicEvents
    FOR EACH ROW
    WHEN NEW.lifecycle_status = 'posted' AND OLD.lifecycle_status != 'posted'
    BEGIN
      SELECT CASE
        WHEN (
          SELECT COUNT(*) FROM $postings WHERE economic_event_id = NEW.id
        ) < 2
        THEN RAISE(ABORT, 'Accounting Invariant Violation: Event must have at least 2 postings before commit.')
        WHEN (
          SELECT COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE -amount_minor_units END), 0)
          FROM $postings
          WHERE economic_event_id = NEW.id
        ) != 0
        THEN RAISE(ABORT, 'Accounting Invariant Violation: Sum(Debits) != Sum(Credits).')
      END;
    END;
  ''';

  static const trgPostingsPreventInsertOnPosted = '''
    CREATE TRIGGER IF NOT EXISTS trg_postings_prevent_insert_on_posted
    BEFORE INSERT ON $postings
    FOR EACH ROW
    WHEN (SELECT lifecycle_status FROM $economicEvents WHERE id = NEW.economic_event_id) = 'posted'
    BEGIN
      SELECT RAISE(ABORT, 'Cannot add postings to an already-posted EconomicEvent.');
    END;
  ''';

  static const trgPostingsPreventUpdateOnPosted = '''
    CREATE TRIGGER IF NOT EXISTS trg_postings_prevent_update_on_posted
    BEFORE UPDATE ON $postings
    FOR EACH ROW
    WHEN (SELECT lifecycle_status FROM $economicEvents WHERE id = OLD.economic_event_id) = 'posted'
    BEGIN
      SELECT RAISE(ABORT, 'Postings of a posted EconomicEvent are immutable.');
    END;
  ''';

  static const trgPostingsPreventDeleteOnPosted = '''
    CREATE TRIGGER IF NOT EXISTS trg_postings_prevent_delete_on_posted
    BEFORE DELETE ON $postings
    FOR EACH ROW
    WHEN (SELECT lifecycle_status FROM $economicEvents WHERE id = OLD.economic_event_id) = 'posted'
    BEGIN
      SELECT RAISE(ABORT, 'Postings of a posted EconomicEvent cannot be deleted.');
    END;
  ''';

  static const trgEconomicEventsPreventMutationOnPosted = '''
    CREATE TRIGGER IF NOT EXISTS trg_economic_events_prevent_mutation_on_posted
    BEFORE UPDATE OF event_type, timestamp, currency ON $economicEvents
    FOR EACH ROW
    WHEN OLD.lifecycle_status = 'posted'
    BEGIN
      SELECT RAISE(ABORT, 'Posted EconomicEvents cannot be mutated.');
    END;
  ''';

  static const trgEconomicEventsPreventDeletePosted = '''
    CREATE TRIGGER IF NOT EXISTS trg_economic_events_prevent_delete_posted
    BEFORE DELETE ON $economicEvents
    FOR EACH ROW
    WHEN OLD.lifecycle_status = 'posted'
    BEGIN
      SELECT RAISE(ABORT, 'Posted EconomicEvents cannot be deleted. Create a reversal event instead.');
    END;
  ''';

  static const allTableCreateQueries = <String>[
    createAccounts,
    createAccountsTypeSubtypeIndex,
    createAccountsParentIndex,
    createEconomicEvents,
    createEconomicEventsTimestampIndex,
    createEconomicEventsTypeStatusIndex,
    createEconomicEventsCategoryIndex,
    createEvidence,
    createEvidenceEventIndex,
    createEvidenceExternalRefIndex,
    createEvidenceBodyHashIndex,
    createEvidenceRetentionIndex,
    createPostings,
    createPostingsEventIndex,
    createPostingsAccountIndex,
    createPostingsAccountDirectionIndex,
    createAssetEarmarks,
    createAssetEarmarksGoalIndex,
    createAssetEarmarksAccountIndex,
    createRecurringRules,
    createExpectedEvents,
    createExpectedEventsDueStatusIndex,
    createReviewCandidates,
    createOpeningBalanceReconciliations,
    createOpeningBalanceReconciliationsAccountIndex,
    createMigrationExceptions,
  ];

  static const allTriggerCreateQueries = <String>[
    trgEconomicEventsPreventDirectPostedInsert,
    trgEconomicEventsValidatePosted,
    trgPostingsPreventInsertOnPosted,
    trgPostingsPreventUpdateOnPosted,
    trgPostingsPreventDeleteOnPosted,
    trgEconomicEventsPreventMutationOnPosted,
    trgEconomicEventsPreventDeletePosted,
  ];

  static const allTriggerDropQueries = <String>[
    'DROP TRIGGER IF EXISTS trg_economic_events_prevent_direct_posted_insert;',
    'DROP TRIGGER IF EXISTS trg_economic_events_validate_posted;',
    'DROP TRIGGER IF EXISTS trg_postings_prevent_insert_on_posted;',
    'DROP TRIGGER IF EXISTS trg_postings_prevent_update_on_posted;',
    'DROP TRIGGER IF EXISTS trg_postings_prevent_delete_on_posted;',
    'DROP TRIGGER IF EXISTS trg_economic_events_prevent_mutation_on_posted;',
    'DROP TRIGGER IF EXISTS trg_economic_events_prevent_delete_posted;',
  ];

  /// Creates all v24 canonical tables and indexes.
  static Future<void> createAllV24(DatabaseExecutor db) async {
    for (final q in allTableCreateQueries) {
      await db.execute(q);
    }
  }

  /// Installs the native SQLite lifecycle & immutability trigger suite.
  static Future<void> installTriggers(DatabaseExecutor db) async {
    for (final q in allTriggerCreateQueries) {
      await db.execute(q);
    }
  }

  /// Drops the trigger suite (e.g. during bulk migration steps if needed).
  static Future<void> dropTriggers(DatabaseExecutor db) async {
    for (final q in allTriggerDropQueries) {
      await db.execute(q);
    }
  }

  /// Seeds core system accounts required for balancing and contra-expenses.
  static Future<void> seedSystemAccounts(DatabaseExecutor db) async {
    final now = DateTime.now().toIso8601String();
    final systemAccounts = <Map<String, dynamic>>[
      {
        'id': sysEquityOpening,
        'account_type': 'equity',
        'subtype': 'opening_balance',
        'name': 'Equity:OpeningBalance',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': sysEquityAdj,
        'account_type': 'equity',
        'subtype': 'reconciliation_adjustment',
        'name': 'Equity:ReconciliationAdjustment',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': sysExpRefunds,
        'account_type': 'expense',
        'subtype': 'contra_expense',
        'name': 'Expense:General:Refunds',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': sysExpMisc,
        'account_type': 'expense',
        'subtype': 'general',
        'name': 'Expense:General:Miscellaneous',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': sysIncMisc,
        'account_type': 'income',
        'subtype': 'general',
        'name': 'Income:General:Miscellaneous',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': sysExpInterest,
        'account_type': 'expense',
        'subtype': 'financial_interest',
        'name': 'Expense:Financial:Interest',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': sysSuspenseTransfer,
        'account_type': 'asset',
        'subtype': 'suspense',
        'name': 'Asset:Suspense:UnknownTransferTarget',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': sysSuspenseCard,
        'account_type': 'liability',
        'subtype': 'suspense',
        'name': 'Liability:Suspense:UnlinkedCreditCard',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': sysSuspenseLoan,
        'account_type': 'liability',
        'subtype': 'suspense',
        'name': 'Liability:Suspense:UnlinkedLoan',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
    ];

    for (final acc in systemAccounts) {
      await db.insert(
        accounts,
        acc,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }
}
