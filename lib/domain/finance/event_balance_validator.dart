import 'exceptions.dart';
import 'money.dart';
import 'posting.dart';

/// Pure domain-level validator that enforces fundamental double-entry balance invariants.
///
/// COMPLETELY INDEPENDENT OF SQLITE.
/// Evaluates in-memory posting collections before an event can transition to 'posted'.
class EventBalanceValidator {
  const EventBalanceValidator();

  /// Validates a list of postings for a given [economicEventId].
  ///
  /// Invariants enforced:
  /// 1. At least two postings must exist (minimum double-entry legs).
  /// 2. All postings must have strictly positive amounts (Money > 0).
  /// 3. All postings must reference the target [economicEventId].
  /// 4. At least one debit leg and at least one credit leg must exist.
  /// 5. Total debits must EXACTLY equal total credits down to the integer minor unit.
  ///
  /// Throws [AccountingInvariantException] if any invariant is violated.
  void validateOrThrow(String economicEventId, List<Posting> postings) {
    if (postings.length < 2) {
      throw AccountingInvariantException(
        'An EconomicEvent must contain at least 2 postings. Found ${postings.length}.',
        eventId: economicEventId,
        details: {'postingCount': postings.length},
      );
    }

    int debitsMinorUnits = 0;
    int creditsMinorUnits = 0;
    int debitCount = 0;
    int creditCount = 0;
    String? currency;

    for (final posting in postings) {
      if (posting.economicEventId != economicEventId) {
        throw AccountingInvariantException(
          'Posting references mismatched economicEventId: ${posting.economicEventId} != $economicEventId',
          eventId: economicEventId,
          details: {
            'postingId': posting.id,
            'expectedEventId': economicEventId,
            'actualEventId': posting.economicEventId,
          },
        );
      }

      if (!posting.amount.isPositive) {
        throw AccountingInvariantException(
          'Posting amount must be strictly positive minor units.',
          eventId: economicEventId,
          details: {
            'postingId': posting.id,
            'amount': posting.amount.minorUnits,
          },
        );
      }

      currency ??= posting.amount.currency;
      if (posting.amount.currency != currency) {
        throw AccountingInvariantException(
          'Multi-currency events not supported in Phase 1. Found ${posting.amount.currency} vs $currency.',
          eventId: economicEventId,
        );
      }

      if (posting.direction == PostingDirection.debit) {
        debitsMinorUnits += posting.amount.minorUnits;
        debitCount++;
      } else {
        creditsMinorUnits += posting.amount.minorUnits;
        creditCount++;
      }
    }

    if (debitCount == 0 || creditCount == 0) {
      throw AccountingInvariantException(
        'Event must contain at least one debit leg and one credit leg.',
        eventId: economicEventId,
        details: {'debitCount': debitCount, 'creditCount': creditCount},
      );
    }

    if (debitsMinorUnits != creditsMinorUnits) {
      final imbalance = debitsMinorUnits - creditsMinorUnits;
      throw AccountingInvariantException(
        'Accounting Invariant Violation: Debits do not equal Credits (Imbalance: $imbalance paise).',
        eventId: economicEventId,
        details: {
          'totalDebitsPaise': debitsMinorUnits,
          'totalCreditsPaise': creditsMinorUnits,
          'imbalancePaise': imbalance,
          'currency': currency,
        },
      );
    }
  }

  /// Non-throwing inspection helper returning whether postings are balanced.
  bool isBalanced(String economicEventId, List<Posting> postings) {
    try {
      validateOrThrow(economicEventId, postings);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Calculates the total debits of the given postings.
  Money sumDebits(List<Posting> postings, {String currency = 'INR'}) {
    int total = 0;
    for (final p in postings) {
      if (p.direction == PostingDirection.debit) {
        total += p.amount.minorUnits;
      }
    }
    return Money.fromMinorUnits(total, currency: currency);
  }

  /// Calculates the total credits of the given postings.
  Money sumCredits(List<Posting> postings, {String currency = 'INR'}) {
    int total = 0;
    for (final p in postings) {
      if (p.direction == PostingDirection.credit) {
        total += p.amount.minorUnits;
      }
    }
    return Money.fromMinorUnits(total, currency: currency);
  }
}
