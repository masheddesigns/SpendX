import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  group('Evidence & OpeningBalanceReconciliation Domain Tests', () {
    final now = DateTime(2026, 10, 3, 16, 0);

    test('Evidence 30-day purge clears raw body but preserves forensic fingerprint', () {
      final evidence = Evidence(
        id: 'ev_1',
        sourceType: 'sms',
        sourceIdentifier: 'VM-HDFCBK',
        sourceTimestamp: now.subtract(const Duration(days: 35)),
        bodyFingerprint: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        extractedAmount: Money.fromRupees(1500),
        extractedMerchant: 'Swiggy',
        externalReference: 'HDFC12345678',
        accountContext: 'XX4092',
        rawPayloadEncrypted: 'EncryptedPayloadCiphertext==',
        retentionExpiresAt: now.subtract(const Duration(days: 5)),
        isPayloadPurged: false,
        createdAt: now.subtract(const Duration(days: 35)),
      );

      expect(evidence.isPayloadPurged, isFalse);
      expect(evidence.rawPayloadEncrypted, isNotNull);

      final purged = evidence.purgeRawPayload();

      // INVARIANT: Raw payload is null and purged flag is true
      expect(purged.isPayloadPurged, isTrue);
      expect(purged.rawPayloadEncrypted, isNull);

      // INVARIANT: Forensic and canonical extraction fields survive!
      expect(purged.bodyFingerprint, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(purged.extractedAmount, Money.fromRupees(1500));
      expect(purged.extractedMerchant, 'Swiggy');
      expect(purged.externalReference, 'HDFC12345678');
      expect(purged.accountContext, 'XX4092');
      expect(purged.sourceIdentifier, 'VM-HDFCBK');
    });

    test('OpeningBalanceReconciliation accurately computes adjustment delta', () {
      final recon = OpeningBalanceReconciliation(
        id: 'rec_1',
        accountId: 'acc_sbi',
        legacyReportedBalance: Money.fromRupees(50000),      // Displayed: ₹50,000
        reconstructedBalanceFromTxns: Money.fromRupees(35000), // Txn Sum: ₹35,000
        reconciliationReason: 'Unbacked opening balance from pre-app savings',
        provenanceSource: 'migration_v24_reconciliation',
        status: ReconciliationStatus.equityAdjustmentRequired,
        createdAt: now,
      );

      // Delta must be 50,000 - 35,000 = +15,000
      expect(recon.adjustmentDelta, Money.fromRupees(15000));
      expect(recon.hasDelta, isTrue);
      expect(recon.status.requiresEquityAdjustment, isTrue);
    });

    test('OpeningBalanceReconciliation rejects empty reason (generic adjustment prohibition)', () {
      expect(
        () => OpeningBalanceReconciliation(
          id: 'rec_bad',
          accountId: 'acc_1',
          legacyReportedBalance: Money.fromRupees(100),
          reconstructedBalanceFromTxns: Money.zero,
          reconciliationReason: '   ', // Blank reason forbidden
          provenanceSource: 'migration_v24',
          status: ReconciliationStatus.equityAdjustmentRequired,
          createdAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('OpeningBalanceReconciliation rejects empty provenance source', () {
      expect(
        () => OpeningBalanceReconciliation(
          id: 'rec_bad',
          accountId: 'acc_1',
          legacyReportedBalance: Money.fromRupees(100),
          reconstructedBalanceFromTxns: Money.zero,
          reconciliationReason: 'Valid reason',
          provenanceSource: '',
          status: ReconciliationStatus.equityAdjustmentRequired,
          createdAt: now,
        ),
        throwsArgumentError,
      );
    });
  });
}
