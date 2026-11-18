import 'package:flutter_test/flutter_test.dart';

import 'package:spend_x/services/legacy_repair_registry.dart';

void main() {
  group('Phase 0 legacy repair containment registry', () {
    test('inventories every repair gate found in live_sms_service', () {
      const expected = [
        'repair_historical_sms_dates_v7',
        'repair_reconciliation_adjustments_v8',
        'repair_credit_and_transfers_v16',
        'repair_restore_federal_bank_v24',
        'repair_restore_accounts_v27',
        'repair_dedup_and_balances_v29',
        'repair_canonical_balances_v30',
        'repair_icici_clean_balance_v32',
        'repair_foreign_currency_and_merchant_v33',
        'repair_icici_live_outstanding_v34',
        'repair_credit_cards_and_accounting_v35',
        'repair_dedup_and_timestamps_v37',
        'repair_dedup_and_instant_delete_v38',
        'repair_card_outstandings_v43',
        'repair_purge_phantom_liabilities_v44',
        'repair_oscillating_reconciliation_v5',
      ];

      final actual =
          LegacyRepairRegistry.repairs.map((r) => r.prefFlag).toList();
      expect(actual, expected);
      expect(actual.toSet().length, actual.length,
          reason: 'each repair flag must be unique');
    });

    test('all automatic execution is disabled', () {
      expect(LegacyRepairRegistry.autoExecutionAllowed, isFalse);
    });

    test('destructive routines are explicitly classified', () {
      final destructive = LegacyRepairRegistry.destructiveRepairs
          .map((r) => r.prefFlag)
          .toSet();

      expect(destructive, contains('repair_historical_sms_dates_v7'));
      expect(destructive, contains('repair_reconciliation_adjustments_v8'));
      expect(destructive, contains('repair_credit_and_transfers_v16'));
      expect(destructive, contains('repair_dedup_and_instant_delete_v38'));
      expect(destructive, contains('repair_oscillating_reconciliation_v5'));
      expect(destructive, contains('repair_purge_phantom_liabilities_v44'));
      expect(destructive.length, greaterThanOrEqualTo(14));
    });

    test('the text-only routine is the only non-destructive entry', () {
      final safe = LegacyRepairRegistry.nonDestructiveRepairs;
      expect(safe.length, 1);
      expect(safe.single.prefFlag, 'repair_foreign_currency_and_merchant_v33');
    });

    test('each routine carries a proposed migration path', () {
      for (final repair in LegacyRepairRegistry.repairs) {
        expect(repair.proposedMigration.trim(), isNotEmpty,
            reason: '${repair.prefFlag} needs a migration proposal');
        expect(repair.operations.trim(), isNotEmpty);
        expect(repair.trigger.trim(), isNotEmpty);
      }
    });

    test('lookup by flag works and unknown flags return null', () {
      expect(
        LegacyRepairRegistry.byFlag('repair_oscillating_reconciliation_v5')
            ?.destructive,
        isTrue,
      );
      expect(LegacyRepairRegistry.byFlag('not_a_repair'), isNull);
    });
  });
}
