import '../../../models/bank_account.dart';
import '../../../models/credit_card.dart';
import '../../../core/utils/upi_parser.dart';
import '../models/parsed_sms.dart';
import '../providers/sms_providers.dart' show detectBank, resolveAccount, resolveCreditCard;

/// Result of account auto-mapping.
class AccountMapResult {
  /// Resolved bank account (null for credit card transactions).
  final BankAccount? account;

  /// Resolved credit card (null for bank transactions).
  final CreditCard? card;

  /// How the match was made.
  final AccountMatchMethod method;

  /// Confidence of the match (0.0–1.0).
  final double confidence;

  const AccountMapResult({
    this.account,
    this.card,
    required this.method,
    required this.confidence,
  });
}

enum AccountMatchMethod {
  exactLast4,      // Matched on last 4 digits
  senderBank,      // Matched sender ID → bank
  vpaBankHint,     // Matched VPA handle → bank
  bankNameFuzzy,   // Matched bank name in SMS body
  fallbackSingle,  // Only one account exists, used as default
  noMatch,         // No match found
}

/// Maps a parsed SMS to the correct account/card using multiple signals.
///
/// Priority order:
///   1. Exact last-4 match (highest confidence)
///   2. Sender ID → bank mapping
///   3. VPA handle → bank mapping
///   4. Bank name fuzzy match in body
///   5. Fallback to single account
class AccountMapper {
  // ── Sender ID → Bank mapping ─────────────────────────────────────────
  // Common Indian bank sender short codes
  static const _senderToBankMap = <String, String>{
    'HDFCBK': 'HDFC',
    'HDFCBN': 'HDFC',
    'ICICIB': 'ICICI',
    'ICICBK': 'ICICI',
    'SBIBNK': 'SBI',
    'SBIPSG': 'SBI',
    'SBIINB': 'SBI',
    'AXISBK': 'AXIS',
    'AXISBN': 'AXIS',
    'KOTAKB': 'KOTAK',
    'IDFCBK': 'IDFC',
    'YESBKL': 'YES',
    'BOBIRD': 'BOB',
    'BOBSMS': 'BOB',
    'PNBSMS': 'PNB',
    'CANBNK': 'CANARA',
    'RBLBNK': 'RBL',
    'FEDERL': 'FEDERAL',
    'FEDSMS': 'FEDERAL',
    'INDBNK': 'INDUSIND',
    'HSBCIN': 'HSBC',
    'AUSFBN': 'AU',
    'DBSBNK': 'DBS',
    'UNIONB': 'UNION',
    'IDBIBK': 'IDBI',
    'PAYTMB': 'PAYTM',
    'JUSPAY': 'JUSPAY',
    'PHONPE': 'PHONEPE',
  };

  /// Resolve the best matching account/card for a parsed SMS.
  static AccountMapResult resolve({
    required ParsedSms sms,
    required List<BankAccount> accounts,
    required List<CreditCard> cards,
    required bool isCreditCardTransaction,
  }) {
    if (isCreditCardTransaction) {
      return _resolveCard(sms: sms, cards: cards);
    }
    return _resolveAccount(sms: sms, accounts: accounts);
  }

  static AccountMapResult _resolveAccount({
    required ParsedSms sms,
    required List<BankAccount> accounts,
  }) {
    if (accounts.isEmpty) {
      return const AccountMapResult(method: AccountMatchMethod.noMatch, confidence: 0);
    }

    // 1. Exact last-4 match
    if (sms.last4 != null && sms.last4!.length == 4) {
      for (final account in accounts) {
        final haystack = '${account.bank} ${account.name}'.toLowerCase();
        if (haystack.contains(sms.last4!)) {
          return AccountMapResult(
            account: account,
            method: AccountMatchMethod.exactLast4,
            confidence: 1.0,
          );
        }
      }
    }

    // 2. Sender ID → bank
    final senderBank = _bankFromSender(sms.sender);
    if (senderBank != null) {
      final match = resolveAccount(senderBank, accounts, last4: sms.last4);
      if (match != null) {
        return AccountMapResult(
          account: match,
          method: AccountMatchMethod.senderBank,
          confidence: 0.85,
        );
      }
    }

    // 3. VPA handle → bank
    if (sms.vpa != null) {
      final vpaBank = UpiParser.bankFromVpa(sms.vpa);
      if (vpaBank != null) {
        final match = resolveAccount(vpaBank, accounts, last4: sms.last4);
        if (match != null) {
          return AccountMapResult(
            account: match,
            method: AccountMatchMethod.vpaBankHint,
            confidence: 0.75,
          );
        }
      }
    }

    // 4. Bank name from body (using existing detectBank)
    final bodyBank = detectBank(sms.sender, sms.body);
    if (bodyBank != 'default') {
      final match = resolveAccount(bodyBank, accounts, last4: sms.last4);
      if (match != null) {
        return AccountMapResult(
          account: match,
          method: AccountMatchMethod.bankNameFuzzy,
          confidence: 0.7,
        );
      }
    }

    // 5. Fallback: single account
    if (accounts.length == 1) {
      return AccountMapResult(
        account: accounts.first,
        method: AccountMatchMethod.fallbackSingle,
        confidence: 0.4,
      );
    }

    return const AccountMapResult(method: AccountMatchMethod.noMatch, confidence: 0);
  }

  static AccountMapResult _resolveCard({
    required ParsedSms sms,
    required List<CreditCard> cards,
  }) {
    if (cards.isEmpty) {
      return const AccountMapResult(method: AccountMatchMethod.noMatch, confidence: 0);
    }

    // 1. Exact last-4 match
    if (sms.last4 != null && sms.last4!.length == 4) {
      for (final card in cards) {
        if (card.last4 == sms.last4) {
          return AccountMapResult(
            card: card,
            method: AccountMatchMethod.exactLast4,
            confidence: 1.0,
          );
        }
      }
    }

    // 2. Sender/body bank match
    final senderBank = _bankFromSender(sms.sender);
    final bodyBank = detectBank(sms.sender, sms.body);
    final bank = senderBank ?? (bodyBank != 'default' ? bodyBank : null);

    if (bank != null) {
      final match = resolveCreditCard(bank, cards, last4: sms.last4);
      if (match != null) {
        return AccountMapResult(
          card: match,
          method: senderBank != null
              ? AccountMatchMethod.senderBank
              : AccountMatchMethod.bankNameFuzzy,
          confidence: senderBank != null ? 0.85 : 0.7,
        );
      }
    }

    // 3. Single card fallback
    if (cards.length == 1) {
      return AccountMapResult(
        card: cards.first,
        method: AccountMatchMethod.fallbackSingle,
        confidence: 0.4,
      );
    }

    return const AccountMapResult(method: AccountMatchMethod.noMatch, confidence: 0);
  }

  /// Extract bank key from sender short code.
  static String? _bankFromSender(String sender) {
    final upper = sender.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    // Try exact match first
    if (_senderToBankMap.containsKey(upper)) {
      return _senderToBankMap[upper];
    }
    // Try suffix match (sender might have prefix like "AD-HDFCBK")
    for (final entry in _senderToBankMap.entries) {
      if (upper.endsWith(entry.key) || upper.contains(entry.key)) {
        return entry.value;
      }
    }
    return null;
  }
}
