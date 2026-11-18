/// Inventory and containment policy for the legacy self-healing repairs that
/// still live in `LiveSmsService._repairOscillatingReconciliationAdjustments`.
///
/// These routines were written as one-off incident fixes between schema v7 and
/// schema v43. They are gated only by SharedPreferences booleans, so clearing
/// app data re-arms every routine and replays destructive SQL against a fresh
/// database. Several routines hardcode historical balances or delete ledger
/// rows, which is not safe to run automatically.
///
/// Phase 0 does **not** delete the routines (they remain available for manual
/// qualification against isolated fixtures). It records their inventory and
/// prevents [LegacyRepairRegistry] consumers from running any of them on
/// startup, resume, or pending-drain.
class LegacyRepairSpec {
  /// SharedPreferences key that used to gate the routine.
  final String prefFlag;

  /// Short human-readable title.
  final String title;

  /// Historical trigger / incident this routine was written for.
  final String trigger;

  /// Whether the routine deletes or rewrites financial state.
  final bool destructive;

  /// What the routine does, in audit terms.
  final String operations;

  /// Safe replacement path proposed for a future versioned migration.
  final String proposedMigration;

  const LegacyRepairSpec({
    required this.prefFlag,
    required this.title,
    required this.trigger,
    required this.destructive,
    required this.operations,
    required this.proposedMigration,
  });
}

class LegacyRepairRegistry {
  LegacyRepairRegistry._();

  /// All legacy repair gates found in `live_sms_service.dart` as of
  /// 2026-11-17. v44 is included because it is present in the source even
  /// though the November audit listed 15 routines.
  static const List<LegacyRepairSpec> repairs = [
    LegacyRepairSpec(
      prefFlag: 'repair_historical_sms_dates_v7',
      title: 'Clear misdated transactions',
      trigger: '12 Nov SMS date bug (v7)',
      destructive: true,
      operations:
          'PRAGMA foreign_keys=OFF; deletes ALL postings, evidence, opening '
          'balance reconciliations and economic events, then resets event '
          'lifecycle flags.',
      proposedMigration:
          'Versioned repair that only re-dates SMS-backed events whose '
          'evidence contains a provable message timestamp; never truncate '
          'the ledger.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_reconciliation_adjustments_v8',
      title: 'Purge spurious reconciliation openings',
      trigger: 'Oscillating opening-balance adjustments (v8)',
      destructive: true,
      operations:
          'Deletes opening_balance events/postings/evidence, deletes ALL '
          'sms_balance evidence, inserts hardcoded card offsets, deletes '
          'wallet accounts matching "22".',
      proposedMigration:
          'Deduplicate opening_balance events by (account_id, amount, source '
          'evidence) with a reversal entry, keeping the audit trail.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_credit_and_transfers_v16',
      title: 'Clean fake Cred/BBPS events and pair transfers',
      trigger: 'Fake ₹31,000 Cred/Amazon Pay expenses (v16)',
      destructive: true,
      operations:
          'Deletes matching events/postings/evidence/transactions, deletes '
          '₹43,000 transactions by amount, rewrites event descriptions, then '
          'hardcodes Federal/Jio/SBI/CSB/ICICI balances.',
      proposedMigration:
          'Migration keyed by evidence fingerprint (Cred/BBPS sender + ref id) '
          'that reverses only positively identified events; balances derived '
          'from the ledger, never hardcoded.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_restore_federal_bank_v24',
      title: 'Restore Federal Bank account / remove duplicate card',
      trigger: 'Federal Bank account lost during v24 migration',
      destructive: true,
      operations:
          'Rewrites account_type/subtype, repoints transactions, postings and '
          'evidence to the Federal account, deletes a credit card row and '
          'deactivates its canonical account.',
      proposedMigration:
          'One-off data-repair script requiring explicit operator invocation '
          'with a backup and before/after counts.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_restore_accounts_v27',
      title: 'Restore accounts after v27 import',
      trigger: 'Accounts missing after a v27 import',
      destructive: true,
      operations:
          'Deletes reconciliation/opening-balance transactions, rewrites '
          'events, deletes duplicate events, and hardcodes five balances.',
      proposedMigration:
          'Idempotent account re-link migration driven by evidence sender + '
          'last4; no fixed amounts.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_dedup_and_balances_v29',
      title: 'Deduplicate transactions and reset balances',
      trigger: 'Duplicate imports and balance drift (v29)',
      destructive: true,
      operations:
          'Deletes transactions/events by amount/notes patterns, deletes '
          'reconciliation rows, inserts a synthetic ₹43,000 transfer, then '
          'hardcodes balances.',
      proposedMigration:
          'Generic duplicate detector on (external_ref) with user-visible '
          'review candidates instead of silent deletion.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_canonical_balances_v30',
      title: 'Reconcile canonical balances',
      trigger: 'Legacy balance drift after canonical migration (v30)',
      destructive: true,
      operations:
          'Deletes reconciliation transactions and evidence, then rewrites '
          'balances to fixed historical values.',
      proposedMigration:
          'Rebuild balances from postings and compare with stored balances; '
          'record discrepancies as review items.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_icici_clean_balance_v32',
      title: 'Clean ICICI balance',
      trigger: 'ICICI reconciliation noise (v32)',
      destructive: true,
      operations:
          'Deletes/updates ICICI-related events and sets ICICI balance to '
          '₹25,010.35.',
      proposedMigration:
          'Issuer-scoped ledger rebuild for ICICI accounts using latest '
          'verified statement evidence.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_foreign_currency_and_merchant_v33',
      title: 'Normalise foreign-currency merchants',
      trigger: 'Foreign-currency merchant parsing (v33)',
      destructive: false,
      operations:
          'Rewrites transaction notes/merchant text and currency metadata; '
          'does not delete ledger rows.',
      proposedMigration:
          'Text-only migration keyed by event id; safe to version once the '
          'mapping is frozen.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_icici_live_outstanding_v34',
      title: 'Set ICICI live outstanding',
      trigger: 'ICICI outstanding mismatch (v34)',
      destructive: true,
      operations:
          'Sets the ICICI card outstanding to a fixed historical amount.',
      proposedMigration:
          'Use the latest verified ICICI statement/available-limit evidence '
          'and reconcile by posting deltas.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_credit_cards_and_accounting_v35',
      title: 'Rebuild credit-card accounting',
      trigger: 'Card accounting mismatch (v35)',
      destructive: true,
      operations:
          'Deletes/rewrites card events, postings and transactions, then '
          'writes fixed balances for multiple instruments.',
      proposedMigration:
          'Card-liability rebuild from immutable postings, with a reversal '
          'event for any correction.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_dedup_and_timestamps_v37',
      title: 'Deduplicate and normalise timestamps',
      trigger: 'Duplicate events with stale timestamps (v37)',
      destructive: true,
      operations:
          'Deletes duplicate transactions/events and rewrites timestamps in '
          'place.',
      proposedMigration:
          'Timestamp-only migration plus review-queue duplicates; do not '
          'delete ledger rows automatically.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_dedup_and_instant_delete_v38',
      title: 'Instant duplicate deletion',
      trigger: 'Duplicates created during live ingestion (v38)',
      destructive: true,
      operations:
          'Deletes duplicate transactions/events/postings/evidence immediately '
          'based on heuristic matches.',
      proposedMigration:
          'Insert review candidates and let the user confirm duplicate '
          'deletion; preserve postings until confirmation.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_card_outstandings_v43',
      title: 'Reset card outstandings',
      trigger: 'Card outstanding drift (v43)',
      destructive: true,
      operations:
          'Reconciles/deletes card statement and outstanding state, with '
          'hardcoded balances.',
      proposedMigration:
          'Statement-driven reconciliation using `card_statements` and '
          'repayment evidence, producing adjustments as review items.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_purge_phantom_liabilities_v44',
      title: 'Purge phantom reminders/liabilities',
      trigger: 'Stale Groww SIP / test reminders (v44)',
      destructive: true,
      operations:
          'Marks reminders matching Groww/SIP/test/amount>50000 and every '
          'reminder older than 3 days as completed.',
      proposedMigration:
          'Reminder-only cleanup scoped to explicit source ids, keeping '
          'user-created reminders intact.',
    ),
    LegacyRepairSpec(
      prefFlag: 'repair_oscillating_reconciliation_v5',
      title: 'Purge oscillating reconciliation loop',
      trigger: '+6000 / -6000 reconciliation loop',
      destructive: true,
      operations:
          'Deletes reconciliation adjustments, deletes duplicate same-amount '
          'income within 2 days, re-links a ₹6,000 income, and sets the Jio '
          'account balance to ₹12,742.91.',
      proposedMigration:
          'Detect reconciliation pairs by source evidence and post a single '
          'balanced reversal; never delete legitimate income by amount alone.',
    ),
  ];

  /// Repairs that mutate ledger/accounting state and must never run
  /// automatically on startup, resume, or drain.
  static List<LegacyRepairSpec> get destructiveRepairs =>
      repairs.where((r) => r.destructive).toList(growable: false);

  /// Repairs whose operations are text-only and could be promoted to a
  /// versioned migration after review.
  static List<LegacyRepairSpec> get nonDestructiveRepairs =>
      repairs.where((r) => !r.destructive).toList(growable: false);

  /// Phase 0 policy: no legacy repair is allowed to auto-execute.
  ///
  /// Even the text-only v33 routine is blocked because it uses the same
  /// SharedPreferences gate and has no idempotency/audit record.
  static bool get autoExecutionAllowed => false;

  static LegacyRepairSpec? byFlag(String flag) {
    for (final repair in repairs) {
      if (repair.prefFlag == flag) return repair;
    }
    return null;
  }
}
