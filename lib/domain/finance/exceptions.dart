/// Accounting and financial domain exceptions for SpendX 2.0.
library;

/// Exception thrown when an accounting invariant is violated
/// (e.g., unbalanced debits/credits, illegal posting mutation, etc.).
class AccountingInvariantException implements Exception {
  final String message;
  final String? eventId;
  final Map<String, dynamic>? details;

  const AccountingInvariantException(
    this.message, {
    this.eventId,
    this.details,
  });

  @override
  String toString() {
    final buffer = StringBuffer('AccountingInvariantException: $message');
    if (eventId != null) {
      buffer.write(' (Event ID: $eventId)');
    }
    if (details != null && details!.isNotEmpty) {
      buffer.write(' Details: $details');
    }
    return buffer.toString();
  }
}

/// Exception thrown when a monetary arithmetic operation exceeds the
/// safe 64-bit integer boundary or violates non-negative constraints.
class MoneyOverflowException implements Exception {
  final String message;
  final int? attemptedMinorUnits;

  const MoneyOverflowException(this.message, [this.attemptedMinorUnits]);

  @override
  String toString() {
    if (attemptedMinorUnits != null) {
      return 'MoneyOverflowException: $message (Value: $attemptedMinorUnits)';
    }
    return 'MoneyOverflowException: $message';
  }
}
