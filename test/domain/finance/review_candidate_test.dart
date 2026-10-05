import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  group('ReviewCandidate Ingestion Boundary Invariant Tests', () {
    final now = DateTime(2026, 10, 3, 15, 30);

    test('Pending candidate has zero economic event links and produces zero postings', () {
      final candidate = ReviewCandidate(
        id: 'cand_1',
        sourceType: 'sms',
        rawPayload: 'Spent Rs.450 at Starbucks on card XX1234',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(450),
        suggestedAccountId: 'liab_card_1234',
        suggestedCategoryId: 'exp_dining',
        confidenceScore: 0.95,
        status: ReviewCandidateStatus.pending,
        createdAt: now,
      );

      expect(candidate.status.isPending, isTrue);
      expect(candidate.convertedEconomicEventId, isNull);
    });

    test('Rejected candidate remains unlinked to accounting truth', () {
      final candidate = ReviewCandidate(
        id: 'cand_2',
        sourceType: 'sms',
        rawPayload: 'Your OTP is 492011',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(492011),
        confidenceScore: 0.15,
        status: ReviewCandidateStatus.pending,
        createdAt: now,
      );

      final rejected = candidate.reject();
      expect(rejected.status.isRejected, isTrue);
      expect(rejected.convertedEconomicEventId, isNull);
    });

    test('Duplicate candidate remains unlinked to accounting truth', () {
      final candidate = ReviewCandidate(
        id: 'cand_3',
        sourceType: 'sms',
        rawPayload: 'Debited Rs 100 for Metro',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(100),
        confidenceScore: 0.9,
        createdAt: now,
      );

      final duplicate = candidate.markDuplicate();
      expect(duplicate.status.isDuplicate, isTrue);
      expect(duplicate.convertedEconomicEventId, isNull);
    });

    test('Approved candidate transitions and references generated EconomicEvent', () {
      final candidate = ReviewCandidate(
        id: 'cand_4',
        sourceType: 'sms',
        rawPayload: 'Debited Rs 1200 at D-Mart',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(1200),
        confidenceScore: 0.98,
        createdAt: now,
      );

      final approved = candidate.approve('evt_dmart_1200');
      expect(approved.status.isApproved, isTrue);
      expect(approved.convertedEconomicEventId, 'evt_dmart_1200');
    });

    test('Invalid confidence scores are rejected', () {
      expect(
        () => ReviewCandidate(
          id: 'c_bad',
          sourceType: 'sms',
          suggestedEventType: CanonicalEventType.expense,
          suggestedAmount: Money.fromRupees(10),
          confidenceScore: 1.5,
          createdAt: now,
        ),
        throwsArgumentError,
      );

      expect(
        () => ReviewCandidate(
          id: 'c_bad',
          sourceType: 'sms',
          suggestedEventType: CanonicalEventType.expense,
          suggestedAmount: Money.fromRupees(10),
          confidenceScore: -0.1,
          createdAt: now,
        ),
        throwsArgumentError,
      );
    });
  });
}
