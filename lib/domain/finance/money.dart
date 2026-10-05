import 'exceptions.dart';

/// Immutable representation of monetary value in signed 64-bit integer minor units.
///
/// In Phase 1, all transactions default to INR, where 1 INR = 100 paise.
/// Canonical domain models NEVER store floating-point doubles for financial computation.
///
/// ### Economic Safety Cap vs. SQLite Physical Limit
/// - **SQLite Physical Limit**: Signed 64-bit integer ($-2^{63}$ to $2^{63}-1 \approx \pm 9.22 \times 10^{18}$ paise).
/// - **SpendX Economic Safety Cap**: $\pm 10^{14}$ paise ($\pm ₹1,000,000,000,000$, $\pm ₹1$ lakh crore).
/// - **Rationale**: Real-world personal finance never approaches $₹1$ lakh crore.
///   Restricting individual [Money] instances to $10^{14}$ paise guarantees that:
///   1. Aggregating up to 90,000 transactions or computing multi-year forecast sums
///      can mathematically NEVER overflow the physical 64-bit integer boundary of SQLite or Dart.
///   2. Any legacy database value exceeding $10^{14}$ paise is caught immediately as corrupted data.
class Money implements Comparable<Money> {
  /// The monetary amount in minor units (e.g., paise in INR).
  final int minorUnits;

  /// ISO 4217 currency code. Phase 1 default is 'INR'.
  final String currency;

  /// Economic safety limit: ±₹1 lakh crore (10^14 paise).
  static const int maxSafePaise = 100000000000000; // 10^14 paise
  static const int minSafePaise = -100000000000000;

  /// Standard zero money constant in INR.
  static const Money zero = Money._(0, 'INR');

  /// Internal canonical constructor with range validation.
  const Money._(this.minorUnits, this.currency);

  /// Creates a [Money] instance from integer minor units (e.g., paise).
  ///
  /// Throws [MoneyOverflowException] if [minorUnits] exceeds the economic safety cap.
  factory Money.fromMinorUnits(int minorUnits, {String currency = 'INR'}) {
    if (minorUnits > maxSafePaise || minorUnits < minSafePaise) {
      throw MoneyOverflowException(
        'Monetary value exceeds economic safety cap (±1 lakh crore).',
        minorUnits,
      );
    }
    return Money._(minorUnits, currency);
  }

  /// Convenience constructor creating a non-negative [Money] instance.
  /// Throws [ArgumentError] if [minorUnits] is negative.
  factory Money.nonNegative(int minorUnits, {String currency = 'INR'}) {
    if (minorUnits < 0) {
      throw ArgumentError.value(
        minorUnits,
        'minorUnits',
        'Monetary value must be non-negative.',
      );
    }
    return Money.fromMinorUnits(minorUnits, currency: currency);
  }

  /// Deterministically converts a legacy rupee amount (num/double) to integer paise.
  ///
  /// ### Canonical Rounding Policy: Round Half Away From Zero
  /// Uses Dart's `(rupees * 100.0).round()`, which rounds halfway cases away from zero:
  /// - `100.5` rounds to `101`
  /// - `-100.5` rounds to `-101`
  /// This matches the exact behavior of SQLite's native `ROUND(amount * 100.0)`.
  ///
  /// IMPORTANT CONTRACT:
  /// This function provides deterministic conversion of the stored legacy numeric value
  /// according to the Round Half Away From Zero policy. It does NOT claim to recover
  /// decimal intent that was already lost in the legacy REAL representation.
  factory Money.fromRupees(num rupees, {String currency = 'INR'}) {
    if (rupees.isNaN || rupees.isInfinite) {
      throw ArgumentError.value(rupees, 'rupees', 'Invalid numeric value.');
    }
    final paise = (rupees * 100.0).round();
    return Money.fromMinorUnits(paise, currency: currency);
  }

  /// Alias for [fromMinorUnits] representing INR paise.
  factory Money.fromPaise(int paise, {String currency = 'INR'}) =>
      Money.fromMinorUnits(paise, currency: currency);

  /// Zero constant for a given currency.
  factory Money.zeroCurrency([String currency = 'INR']) =>
      currency == 'INR' ? zero : Money._(0, currency);

  /// Returns the amount in minor units (paise).
  int get paise => minorUnits;

  /// Derived convenience getter returning value in whole currency units (rupees).
  /// For display/export purposes only; never used for financial computation.
  double get toRupees => minorUnits / 100.0;
  double get asRupees => toRupees;

  bool get isZero => minorUnits == 0;
  bool get isPositive => minorUnits > 0;
  bool get isNegative => minorUnits < 0;

  /// Returns the absolute value of this [Money].
  Money abs() => Money._(minorUnits.abs(), currency);

  /// Adds two [Money] instances of the same currency.
  Money operator +(Money other) {
    _assertSameCurrency(other);
    final result = minorUnits + other.minorUnits;
    if (result > maxSafePaise || result < minSafePaise) {
      throw MoneyOverflowException('Addition resulted in monetary overflow.', result);
    }
    return Money._(result, currency);
  }

  /// Subtracts another [Money] instance of the same currency.
  Money operator -(Money other) {
    _assertSameCurrency(other);
    final result = minorUnits - other.minorUnits;
    if (result > maxSafePaise || result < minSafePaise) {
      throw MoneyOverflowException('Subtraction resulted in monetary overflow.', result);
    }
    return Money._(result, currency);
  }

  /// Negates this [Money] instance.
  Money operator -() => Money._(-minorUnits, currency);

  /// Multiplies this monetary amount by an integer scalar factor.
  Money operator *(int factor) {
    final result = minorUnits * factor;
    if (result > maxSafePaise || result < minSafePaise) {
      throw MoneyOverflowException('Multiplication resulted in monetary overflow.', result);
    }
    return Money._(result, currency);
  }

  /// Performs integer division in minor units by an integer divisor.
  Money operator ~/(int divisor) {
    if (divisor == 0) {
      throw ArgumentError('Cannot divide Money by zero divisor.');
    }
    final result = minorUnits ~/ divisor;
    return Money._(result, currency);
  }

  /// Returns the minor-unit remainder after integer division by an integer divisor.
  Money operator %(int divisor) {
    if (divisor == 0) {
      throw ArgumentError('Cannot divide Money by zero divisor.');
    }
    final result = minorUnits % divisor;
    return Money._(result, currency);
  }

  @override
  int compareTo(Money other) {
    _assertSameCurrency(other);
    return minorUnits.compareTo(other.minorUnits);
  }

  bool operator <(Money other) => compareTo(other) < 0;
  bool operator <=(Money other) => compareTo(other) <= 0;
  bool operator >(Money other) => compareTo(other) > 0;
  bool operator >=(Money other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Money &&
          runtimeType == other.runtimeType &&
          minorUnits == other.minorUnits &&
          currency == other.currency;

  @override
  int get hashCode => Object.hash(minorUnits, currency);

  void _assertSameCurrency(Money other) {
    if (currency != other.currency) {
      throw ArgumentError(
        'Cannot perform arithmetic across mismatched currencies: $currency vs ${other.currency}',
      );
    }
  }

  /// Formats this [Money] into a standard representation (e.g. `₹1,234.50`).
  String format({bool includeSymbol = true}) {
    final isNeg = minorUnits < 0;
    final absPaise = minorUnits.abs();
    final whole = absPaise ~/ 100;
    final frac = absPaise % 100;

    final fracStr = frac.toString().padLeft(2, '0');
    final wholeStr = _formatIndianGrouping(whole);

    final sign = isNeg ? '-' : '';
    final symbol = includeSymbol ? (currency == 'INR' ? '₹' : '$currency ') : '';

    return '$sign$symbol$wholeStr.$fracStr';
  }

  static String _formatIndianGrouping(int number) {
    final str = number.toString();
    if (str.length <= 3) return str;

    final lastThree = str.substring(str.length - 3);
    final rest = str.substring(0, str.length - 3);

    final buffer = StringBuffer();
    for (int i = 0; i < rest.length; i++) {
      if (i > 0 && (rest.length - i) % 2 == 0) {
        buffer.write(',');
      }
      buffer.write(rest[i]);
    }
    buffer.write(',');
    buffer.write(lastThree);
    return buffer.toString();
  }

  @override
  String toString() => format();
}
