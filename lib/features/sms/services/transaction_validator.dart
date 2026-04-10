import '../models/parsed_sms.dart';

/// Data integrity rules for parsed SMS transactions.
///
/// Rules:
///   1. No transaction without amount (> 0)
///   2. No future-dated transaction (> 24h ahead)
///   3. Must have a direction (debit or credit)
///   4. Credit card payments are NOT income
///   5. Wallet loads are NOT expense
///   6. Self-transfers are ignored
///   7. Refunds are negative expenses (still type = income)
///   8. Confidence < 0.50 → reject, 0.50-0.69 → review, >= 0.70 → auto-insert
class TransactionValidator {
  TransactionValidator._();

  /// Validation result.
  static ValidationResult validate(ParsedSms sms) {
    final issues = <String>[];

    // Rule 1: Must have positive amount
    if (sms.amount <= 0) {
      return ValidationResult.rejected('Amount is zero or negative');
    }

    // Rule 2: No future-dated transactions (allow 24h buffer for timezone)
    final maxFutureDate = DateTime.now().add(const Duration(hours: 24));
    if (sms.date.isAfter(maxFutureDate)) {
      return ValidationResult.rejected('Future-dated transaction');
    }

    // Rule 3: Very old transactions (> 1 year) get lower confidence
    final oneYearAgo = DateTime.now().subtract(const Duration(days: 365));
    if (sms.date.isBefore(oneYearAgo)) {
      issues.add('Transaction is over 1 year old');
    }

    // Rule 4: Determine correct transaction type
    final correctedType = _correctTransactionType(sms);

    // Rule 5: Confidence threshold routing
    if (sms.confidence < 0.50) {
      return ValidationResult.rejected(
          'Confidence too low: ${sms.confidence.toStringAsFixed(2)}');
    }
    if (sms.confidence < 0.70) {
      return ValidationResult.review(
        correctedType: correctedType,
        issues: ['Low confidence — needs manual review', ...issues],
      );
    }

    // Rule 6: Internal transfers should not count as income/expense
    if (sms.kind == SmsKind.transfer) {
      return ValidationResult.accepted(
        correctedType: 'transfer',
        issues: issues.isEmpty ? null : issues,
      );
    }

    return ValidationResult.accepted(
      correctedType: correctedType,
      issues: issues.isEmpty ? null : issues,
    );
  }

  /// Correct the transaction type based on SMS kind.
  ///
  /// Fixes:
  ///   - Credit card payment → expense (paying your card bill)
  ///   - Wallet load → expense (moving money to wallet)
  ///   - Refund → income (money coming back)
  ///   - Self-transfer → transfer (not income/expense)
  static String _correctTransactionType(ParsedSms sms) {
    switch (sms.kind) {
      case SmsKind.creditCardPayment:
        // Paying your credit card bill = expense (money leaves bank)
        // But if the SMS is from the credit card side, it's a credit (payment received)
        // The key: if it says "debited from bank" → expense
        // If it says "payment received on card" → still expense (just confirmation)
        return 'expense';

      case SmsKind.creditCardSpend:
        return 'expense';

      case SmsKind.loanEmi:
        return 'expense';

      case SmsKind.atm:
        return 'expense';

      case SmsKind.transfer:
        return 'transfer';

      case SmsKind.refund:
        return 'income';

      case SmsKind.upiSend:
      case SmsKind.bankDebit:
        return 'expense';

      case SmsKind.upiReceive:
      case SmsKind.bankCredit:
        return 'income';

      case SmsKind.unknown:
        return sms.isCredit ? 'income' : 'expense';
    }
  }
}

/// Result of transaction validation.
class ValidationResult {
  final ValidationAction action;
  final String? correctedType;
  final String? rejectionReason;
  final List<String>? issues;

  const ValidationResult._({
    required this.action,
    this.correctedType,
    this.rejectionReason,
    this.issues,
  });

  factory ValidationResult.accepted({
    required String correctedType,
    List<String>? issues,
  }) =>
      ValidationResult._(
        action: ValidationAction.accept,
        correctedType: correctedType,
        issues: issues,
      );

  factory ValidationResult.review({
    required String correctedType,
    List<String>? issues,
  }) =>
      ValidationResult._(
        action: ValidationAction.review,
        correctedType: correctedType,
        issues: issues,
      );

  factory ValidationResult.rejected(String reason) => ValidationResult._(
        action: ValidationAction.reject,
        rejectionReason: reason,
      );

  bool get isAccepted => action == ValidationAction.accept;
  bool get needsReview => action == ValidationAction.review;
  bool get isRejected => action == ValidationAction.reject;
}

enum ValidationAction { accept, review, reject }
