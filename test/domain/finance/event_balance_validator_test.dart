import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  group('EventBalanceValidator Domain Invariant Tests', () {
    const validator = EventBalanceValidator();
    final now = DateTime(2026, 10, 3, 12, 0);

    test('Valid 2-leg balanced event passes validation', () {
      final postings = [
        Posting.debit(
          id: 'p1',
          economicEventId: 'evt_1',
          accountId: 'exp_food',
          amount: Money.fromRupees(500),
          createdAt: now,
        ),
        Posting.credit(
          id: 'p2',
          economicEventId: 'evt_1',
          accountId: 'ast_bank',
          amount: Money.fromRupees(500),
          createdAt: now,
        ),
      ];

      expect(() => validator.validateOrThrow('evt_1', postings), returnsNormally);
      expect(validator.isBalanced('evt_1', postings), isTrue);
      expect(validator.sumDebits(postings), Money.fromRupees(500));
      expect(validator.sumCredits(postings), Money.fromRupees(500));
    });

    test('Valid 3-leg balanced loan repayment passes validation', () {
      final postings = [
        Posting.debit(
          id: 'p1',
          economicEventId: 'evt_loan',
          accountId: 'liab_loan',
          amount: Money.fromRupees(8000), // Principal
          createdAt: now,
        ),
        Posting.debit(
          id: 'p2',
          economicEventId: 'evt_loan',
          accountId: 'exp_interest',
          amount: Money.fromRupees(2000), // Interest
          createdAt: now,
        ),
        Posting.credit(
          id: 'p3',
          economicEventId: 'evt_loan',
          accountId: 'ast_bank',
          amount: Money.fromRupees(10000), // Total cash outflow
          createdAt: now,
        ),
      ];

      expect(() => validator.validateOrThrow('evt_loan', postings), returnsNormally);
      expect(validator.isBalanced('evt_loan', postings), isTrue);
      expect(validator.sumDebits(postings), Money.fromRupees(10000));
      expect(validator.sumCredits(postings), Money.fromRupees(10000));
    });

    test('Unbalanced event (Debits != Credits) throws AccountingInvariantException', () {
      final postings = [
        Posting.debit(
          id: 'p1',
          economicEventId: 'evt_unbal',
          accountId: 'exp_food',
          amount: Money.fromRupees(500),
          createdAt: now,
        ),
        Posting.credit(
          id: 'p2',
          economicEventId: 'evt_unbal',
          accountId: 'ast_bank',
          amount: Money.fromRupees(499), // 1 rupee / 100 paise imbalance
          createdAt: now,
        ),
      ];

      expect(
        () => validator.validateOrThrow('evt_unbal', postings),
        throwsA(isA<AccountingInvariantException>()),
      );
      expect(validator.isBalanced('evt_unbal', postings), isFalse);
    });

    test('Single-posting event throws AccountingInvariantException', () {
      final postings = [
        Posting.debit(
          id: 'p1',
          economicEventId: 'evt_single',
          accountId: 'exp_food',
          amount: Money.fromRupees(500),
          createdAt: now,
        ),
      ];

      expect(
        () => validator.validateOrThrow('evt_single', postings),
        throwsA(isA<AccountingInvariantException>()),
      );
    });

    test('Zero-value posting is rejected at construction time', () {
      expect(
        () => Posting.debit(
          id: 'p_zero',
          economicEventId: 'evt_1',
          accountId: 'exp_food',
          amount: Money.zero,
          createdAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Negative posting is rejected at construction time', () {
      expect(
        () => Posting.debit(
          id: 'p_neg',
          economicEventId: 'evt_1',
          accountId: 'exp_food',
          amount: Money.fromPaise(-100),
          createdAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Mismatched economicEventId in postings throws AccountingInvariantException', () {
      final postings = [
        Posting.debit(
          id: 'p1',
          economicEventId: 'evt_1',
          accountId: 'exp_food',
          amount: Money.fromRupees(500),
          createdAt: now,
        ),
        Posting.credit(
          id: 'p2',
          economicEventId: 'evt_DIFFERENT',
          accountId: 'ast_bank',
          amount: Money.fromRupees(500),
          createdAt: now,
        ),
      ];

      expect(
        () => validator.validateOrThrow('evt_1', postings),
        throwsA(isA<AccountingInvariantException>()),
      );
    });

    test('Event with only debits throws AccountingInvariantException', () {
      final postings = [
        Posting.debit(
          id: 'p1',
          economicEventId: 'evt_1',
          accountId: 'exp_food',
          amount: Money.fromRupees(500),
          createdAt: now,
        ),
        Posting.debit(
          id: 'p2',
          economicEventId: 'evt_1',
          accountId: 'exp_travel',
          amount: Money.fromRupees(500),
          createdAt: now,
        ),
      ];

      expect(
        () => validator.validateOrThrow('evt_1', postings),
        throwsA(isA<AccountingInvariantException>()),
      );
    });
  });
}
