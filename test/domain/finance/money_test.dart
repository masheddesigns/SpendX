import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  group('Money Domain Value Object Tests', () {
    test('Zero Money properties', () {
      const m0 = Money.zero;
      expect(m0.minorUnits, 0);
      expect(m0.paise, 0);
      expect(m0.toRupees, 0.0);
      expect(m0.isZero, isTrue);
      expect(m0.isPositive, isFalse);
      expect(m0.isNegative, isFalse);
      expect(m0.format(), '₹0.00');
    });

    test('1 paisa representation', () {
      final m1 = Money.fromPaise(1);
      expect(m1.minorUnits, 1);
      expect(m1.paise, 1);
      expect(m1.toRupees, 0.01);
      expect(m1.isPositive, isTrue);
      expect(m1.format(), '₹0.01');
    });

    test('₹1.00 representation', () {
      final m100 = Money.fromRupees(1.00);
      expect(m100.minorUnits, 100);
      expect(m100.paise, 100);
      expect(m100.toRupees, 1.00);
      expect(m100.format(), '₹1.00');
    });

    test('₹1.15 floating-point conversion precision (adversarial vector)', () {
      // 1.15 in IEEE 754 is 1.14999999999999991118...
      // Naive .toInt() produces 114 (bug). Money.fromRupees must produce exactly 115.
      final m115 = Money.fromRupees(1.15);
      expect(m115.minorUnits, 115);
      expect(m115.paise, 115);
      expect(m115.toRupees, 1.15);
      expect(m115.format(), '₹1.15');
    });

    test('₹10.05 conversion precision', () {
      final m1005 = Money.fromRupees(10.05);
      expect(m1005.minorUnits, 1005);
      expect(m1005.format(), '₹10.05');
    });

    test('Negative monetary values where permitted', () {
      final neg = Money.fromPaise(-5025);
      expect(neg.isNegative, isTrue);
      expect(neg.isPositive, isFalse);
      expect(neg.minorUnits, -5025);
      expect(neg.toRupees, -50.25);
      expect(neg.abs().minorUnits, 5025);
      expect(neg.format(), '-₹50.25');
    });

    test('Non-negative factory throws on negative values', () {
      expect(
        () => Money.nonNegative(-1),
        throwsArgumentError,
      );
      expect(
        Money.nonNegative(0).minorUnits,
        0,
      );
      expect(
        Money.nonNegative(500).minorUnits,
        500,
      );
    });

    test('Maximum supported amount (1 lakh crore = 10^14 paise)', () {
      final maxVal = Money.fromPaise(Money.maxSafePaise);
      expect(maxVal.minorUnits, 100000000000000);
      expect(maxVal.isPositive, isTrue);
    });

    test('Overflow boundary throws MoneyOverflowException', () {
      expect(
        () => Money.fromPaise(Money.maxSafePaise + 1),
        throwsA(isA<MoneyOverflowException>()),
      );
      expect(
        () => Money.fromPaise(Money.minSafePaise - 1),
        throwsA(isA<MoneyOverflowException>()),
      );
    });

    test('Arithmetic operations preserve exact minor units', () {
      final a = Money.fromRupees(150.75); // 15075
      final b = Money.fromRupees(49.25);  // 4925

      final sum = a + b;
      expect(sum.minorUnits, 20000);
      expect(sum.toRupees, 200.0);

      final diff = a - b;
      expect(diff.minorUnits, 10150);
      expect(diff.toRupees, 101.50);

      final mult = Money.fromPaise(250) * 4;
      expect(mult.minorUnits, 1000);
      expect(mult.toRupees, 10.0);
    });

    test('Arithmetic overflow is detected loudly', () {
      final huge = Money.fromPaise(Money.maxSafePaise - 50);
      expect(
        () => huge + Money.fromPaise(100),
        throwsA(isA<MoneyOverflowException>()),
      );
      expect(
        () => huge * 2,
        throwsA(isA<MoneyOverflowException>()),
      );
    });

    test('Comparison and value equality', () {
      final m1 = Money.fromRupees(50.0);
      final m2 = Money.fromPaise(5000);
      final m3 = Money.fromRupees(75.0);

      expect(m1 == m2, isTrue);
      expect(m1.hashCode == m2.hashCode, isTrue);
      expect(m1 < m3, isTrue);
      expect(m3 > m1, isTrue);
      expect(m1 <= m2, isTrue);
      expect(m1 >= m2, isTrue);
    });

    test('Round Half Away From Zero boundary tests around fractional paise', () {
      // Positive boundary vectors:
      // Note: In IEEE 754, 1.005 is stored as 1.004999999999999893..., so 1.005 * 100.0 is 100.49999999999999 (< 100.5) -> 100.
      // This proves that binary floating point cannot recover decimal intent lost in legacy REAL.
      // The conversion is strictly deterministic on the stored IEEE 754 representation.
      expect(Money.fromRupees(1.004).minorUnits, 100);
      expect(Money.fromRupees(1.005).minorUnits, 100); // 100.49999999999999 -> 100
      expect(Money.fromRupees(1.006).minorUnits, 101);

      expect(Money.fromRupees(1.014).minorUnits, 101);
      expect(Money.fromRupees(1.015).minorUnits, 101); // 101.49999999999999 -> 101
      expect(Money.fromRupees(1.016).minorUnits, 102);

      expect(Money.fromRupees(2.004).minorUnits, 200);
      expect(Money.fromRupees(2.005).minorUnits, 201); // 200.5 -> 201 (half away from 0)
      expect(Money.fromRupees(2.006).minorUnits, 201);

      expect(Money.fromRupees(10.004).minorUnits, 1000);
      expect(Money.fromRupees(10.005).minorUnits, 1001); // 1000.5000000000001 -> 1001
      expect(Money.fromRupees(10.006).minorUnits, 1001);

      // Negative boundary vectors (symmetric round half away from zero)
      expect(Money.fromRupees(-1.004).minorUnits, -100);
      expect(Money.fromRupees(-1.005).minorUnits, -100);
      expect(Money.fromRupees(-1.006).minorUnits, -101);

      expect(Money.fromRupees(-1.014).minorUnits, -101);
      expect(Money.fromRupees(-1.015).minorUnits, -101);
      expect(Money.fromRupees(-1.016).minorUnits, -102);

      expect(Money.fromRupees(-2.004).minorUnits, -200);
      expect(Money.fromRupees(-2.005).minorUnits, -201);
      expect(Money.fromRupees(-2.006).minorUnits, -201);

      expect(Money.fromRupees(-10.004).minorUnits, -1000);
      expect(Money.fromRupees(-10.005).minorUnits, -1001);
      expect(Money.fromRupees(-10.006).minorUnits, -1001);
    });

    test('Integer division and remainder operations', () {
      final total = Money.fromRupees(100.0); // 10000 paise
      final divided = total ~/ 3;           // 3333 paise
      final remainder = total % 3;          // 1 paisa

      expect(divided.minorUnits, 3333);
      expect(remainder.minorUnits, 1);
      expect(divided * 3 + remainder, total);

      expect(() => total ~/ 0, throwsArgumentError);
      expect(() => total % 0, throwsArgumentError);
    });

    test('Minimum supported Money and boundaries', () {
      final minVal = Money.fromPaise(Money.minSafePaise);
      expect(minVal.minorUnits, -100000000000000);
      expect(minVal.isNegative, isTrue);

      expect(
        () => Money.fromPaise(Money.minSafePaise - 1),
        throwsA(isA<MoneyOverflowException>()),
      );
    });

    test('Indian number formatting grouping', () {
      expect(Money.fromRupees(1000).format(), '₹1,000.00');
      expect(Money.fromRupees(100000).format(), '₹1,00,000.00');
      expect(Money.fromRupees(10000000).format(), '₹1,00,00,000.00');
    });
  });
}
