import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/services/inbox_audit_service.dart';

void main() {
  group('InboxAuditResult Model Tests', () {
    test('serialization roundtrip preserves all fields', () {
      final now = DateTime.now();
      final missed = MissedInboxItem(
        id: 'test-1',
        sender: 'HDFCBK',
        body: 'Rs 1500 debited from HDFC Bank A/C XX6366 on 12-Nov-2026',
        amount: 1500.0,
        isCredit: false,
        merchant: 'Swiggy',
        bankName: 'HDFC Bank',
        last4: '6366',
        date: now,
        reviewCandidateId: 'candidate-uuid-1',
      );

      final result = InboxAuditResult(
        permissionGranted: true,
        totalScanned: 25,
        capturedCount: 24,
        missedCount: 1,
        coveragePercentage: 96.0,
        missedItems: [missed],
        scannedAt: now,
      );

      final map = result.toMap();
      final restored = InboxAuditResult.fromMap(map);

      expect(restored.permissionGranted, isTrue);
      expect(restored.totalScanned, 25);
      expect(restored.capturedCount, 24);
      expect(restored.missedCount, 1);
      expect(restored.coveragePercentage, 96.0);
      expect(restored.missedItems.length, 1);
      expect(restored.missedItems.first.amount, 1500.0);
      expect(restored.missedItems.first.merchant, 'Swiggy');
      expect(restored.missedItems.first.bankName, 'HDFC Bank');
      expect(restored.isClean, isFalse);
    });

    test('isClean is true when 0 missed items and permission is granted', () {
      final cleanResult = InboxAuditResult(
        permissionGranted: true,
        totalScanned: 10,
        capturedCount: 10,
        missedCount: 0,
        coveragePercentage: 100.0,
        missedItems: const [],
        scannedAt: DateTime.now(),
      );

      expect(cleanResult.isClean, isTrue);
    });
  });
}
