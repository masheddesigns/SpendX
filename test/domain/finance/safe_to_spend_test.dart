import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  group('SafeToSpendCalculation Domain Invariant Tests', () {
    test('Positive discretionary cash scenario', () {
      final calc = SafeToSpendCalculation.compute(
        liquidAssets: Money.fromRupees(100000),             // 1,00,000
        activeEarmarks: Money.fromRupees(20000),             // - 20,000
        knownCommitments14d: Money.fromRupees(15000),        // - 15,000
        highConfidencePendingDebits: Money.fromRupees(5000), // -  5,000
      );

      // 100,000 - 20,000 - 15,000 - 5,000 = 60,000
      expect(calc.discretionaryCash, Money.fromRupees(60000));
      expect(calc.safeToSpend, Money.fromRupees(60000));
      expect(calc.cashflowShortfall, Money.zero);
      expect(calc.hasShortfall, isFalse);
      expect(calc.totalReservations, Money.fromRupees(40000));
    });

    test('Zero discretionary cash scenario', () {
      final calc = SafeToSpendCalculation.compute(
        liquidAssets: Money.fromRupees(50000),
        activeEarmarks: Money.fromRupees(30000),
        knownCommitments14d: Money.fromRupees(20000),
        highConfidencePendingDebits: Money.zero,
      );

      expect(calc.discretionaryCash, Money.zero);
      expect(calc.safeToSpend, Money.zero);
      expect(calc.cashflowShortfall, Money.zero);
      expect(calc.hasShortfall, isFalse);
    });

    test('Negative discretionary cash scenario (Shortfall Deficit)', () {
      // User has ₹30,000 cash, but ₹20,000 earmarks + ₹25,000 commitments = ₹45,000 reserved
      final calc = SafeToSpendCalculation.compute(
        liquidAssets: Money.fromRupees(30000),
        activeEarmarks: Money.fromRupees(20000),
        knownCommitments14d: Money.fromRupees(25000),
        highConfidencePendingDebits: Money.zero,
      );

      // Discretionary: 30,000 - 45,000 = -15,000
      expect(calc.discretionaryCash, Money.fromRupees(-15000));
      // Safe to spend MUST be floored at zero:
      expect(calc.safeToSpend, Money.zero);
      // Shortfall MUST preserve the full magnitude:
      expect(calc.cashflowShortfall, Money.fromRupees(15000));
      expect(calc.hasShortfall, isTrue);

      // Invariant: discretionaryCash, safeToSpend, cashflowShortfall NEVER collapsed!
      expect(calc.discretionaryCash != calc.safeToSpend, isTrue);
      expect(calc.cashflowShortfall == -calc.discretionaryCash, isTrue);
    });

    test('14-day commitments scenario with real SMS obligations', () {
      // Obligations: Netflix ₹199, Spotify ₹179, JioHome ₹706.82, HDFC CC bill ₹25,000 = ₹26,084.82
      final obligations = 199.0 + 179.0 + 706.82 + 25000.0;
      final calc = SafeToSpendCalculation.compute(
        liquidAssets: Money.fromRupees(50000),
        activeEarmarks: Money.fromRupees(10000),
        knownCommitments14d: Money.fromRupees(obligations),
        highConfidencePendingDebits: Money.zero,
      );

      // Liquid: 50,000 - 10,000 - 26,084.82 = 13,915.18
      expect(calc.discretionaryCash, Money.fromRupees(13915.18));
      expect(calc.safeToSpend, Money.fromRupees(13915.18));
      expect(calc.hasShortfall, isFalse);
      expect(calc.knownCommitments14d.toRupees, 26084.82);
    });

    test('commitmentItems preserves details of upcoming obligations', () {
      final now = DateTime.now();
      final items = [
        CommitmentItem(
          title: 'Netflix Subscription',
          amount: Money.fromRupees(199.0),
          dueDate: now.add(const Duration(days: 3)),
          type: 'bill',
        ),
        CommitmentItem(
          title: 'SBI Credit Card',
          amount: Money.fromRupees(35718.82),
          dueDate: now.add(const Duration(days: 5)),
          type: 'credit_card',
        ),
      ];

      final calc = SafeToSpendCalculation.compute(
        liquidAssets: Money.fromRupees(50000),
        activeEarmarks: Money.zero,
        knownCommitments14d: Money.fromRupees(199.0 + 35718.82),
        highConfidencePendingDebits: Money.zero,
        commitmentItems: items,
      );

      expect(calc.commitmentItems.length, 2);
      expect(calc.commitmentItems[0].title, 'Netflix Subscription');
      expect(calc.commitmentItems[0].amount.toRupees, 199.0);
      expect(calc.commitmentItems[1].title, 'SBI Credit Card');
      expect(calc.commitmentItems[1].type, 'credit_card');
    });
  });
}
