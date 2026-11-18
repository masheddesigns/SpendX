import '../models/bank_account.dart';
import '../models/credit_card.dart';
import 'sms_import_service.dart';

/// Deterministic, evidence-based resolution of an SMS balance statement to an
/// existing account or credit card.
///
/// The previous implementation fell back to "the only account/card" and to a
/// bank-name keyword (`hdfc`) that routed *bank* balances into *credit cards*.
/// Both behaviours can silently move money between unrelated instruments, so
/// this resolver never guesses:
///
/// * a match requires strong identity evidence (account-number last4 and/or
///   issuer) and the correct instrument class: bank/wallet statements may only
///   resolve to asset accounts, card statements only to credit cards. Bank and
///   wallet accounts share the asset class because a payments-bank account can
///   legitimately be stored under either type;
/// * more than one candidate is reported as [ambiguous] instead of picking the
///   first row;
/// * a single candidate is only accepted when the evidence actually identifies
///   it (issuer match or last4 match), never merely because it is the only row
///   in the table.
class BalanceAttribution {
  /// Resolved instrument id, or null when no safe match exists.
  final String? instrumentId;

  /// True when [instrumentId] refers to a credit card.
  final bool isCreditCard;

  /// True when identity evidence is insufficient or contradicts the candidates.
  final bool ambiguous;

  /// True when the evidence is strong enough to create a new instrument.
  final bool canCreate;

  /// Human-readable explanation, stored with the Review Queue candidate.
  final String reason;

  /// Candidate ids considered during resolution (diagnostics only).
  final List<String> candidateIds;

  const BalanceAttribution({
    this.instrumentId,
    this.isCreditCard = false,
    this.ambiguous = false,
    this.canCreate = false,
    this.reason = '',
    this.candidateIds = const [],
  });

  bool get matched => instrumentId != null;

  factory BalanceAttribution._match(
    String id, {
    required bool isCreditCard,
    required String reason,
  }) =>
      BalanceAttribution(
        instrumentId: id,
        isCreditCard: isCreditCard,
        reason: reason,
      );

  factory BalanceAttribution._ambiguous(
    String reason,
    List<String> ids,
  ) =>
      BalanceAttribution(
        ambiguous: true,
        reason: reason,
        candidateIds: List.unmodifiable(ids),
      );

  factory BalanceAttribution._unmatched(
    String reason, {
    bool canCreate = false,
  }) =>
      BalanceAttribution(reason: reason, canCreate: canCreate);

  /// Resolves [kind]/[last4]/[bankKeyword] against the supplied instruments.
  ///
  /// The caller is responsible for passing the complete account and card lists;
  /// system accounts are ignored here.
  static BalanceAttribution resolve({
    required BalanceKind kind,
    required String? last4,
    required String? bankKeyword,
    required List<BankAccount> accounts,
    required List<CreditCard> cards,
  }) {
    final effectiveLast4 = _normaliseLast4(last4);
    final issuer = bankKeyword?.trim().toLowerCase() ?? '';
    final hasIssuer = issuer.isNotEmpty;

    if (kind == BalanceKind.creditCard) {
      return _resolveCard(
        last4: effectiveLast4,
        issuer: issuer,
        hasIssuer: hasIssuer,
        cards: cards,
      );
    }
    return _resolveAccount(
      kind: kind,
      last4: effectiveLast4,
      issuer: issuer,
      hasIssuer: hasIssuer,
      accounts: accounts,
    );
  }

  static BalanceAttribution _resolveCard({
    required String? last4,
    required String issuer,
    required bool hasIssuer,
    required List<CreditCard> cards,
  }) {
    List<CreditCard> candidates;

    if (last4 != null) {
      candidates = cards.where((c) => c.last4 == last4).toList();
      if (hasIssuer && candidates.isNotEmpty) {
        final byIssuer =
            candidates.where((c) => _issuerMatches(issuer, c.bank, c.name)).toList();
        if (byIssuer.isNotEmpty) {
          candidates = byIssuer;
        } else {
          return BalanceAttribution._ambiguous(
            'Card last4 $last4 belongs to a different issuer than "$issuer"',
            candidates.map((c) => c.id).toList(),
          );
        }
      }
    } else if (hasIssuer) {
      candidates =
          cards.where((c) => _issuerMatches(issuer, c.bank, c.name)).toList();
    } else {
      return BalanceAttribution._unmatched(
        'No card instrument (last4) or issuer evidence',
      );
    }

    if (candidates.length == 1) {
      final card = candidates.first;
      return BalanceAttribution._match(
        card.id,
        isCreditCard: true,
        reason: last4 != null
            ? 'Matched card by last4 $last4'
            : 'Matched sole card for issuer "$issuer"',
      );
    }
    if (candidates.length > 1) {
      return BalanceAttribution._ambiguous(
        'Multiple credit cards match the balance statement',
        candidates.map((c) => c.id).toList(),
      );
    }
    return BalanceAttribution._unmatched(
      'No credit card matches the balance statement',
      canCreate: last4 != null && hasIssuer,
    );
  }

  static BalanceAttribution _resolveAccount({
    required BalanceKind kind,
    required String? last4,
    required String issuer,
    required bool hasIssuer,
    required List<BankAccount> accounts,
  }) {
    if (last4 == null && !hasIssuer) {
      return BalanceAttribution._unmatched(
        'No instrument (last4) or issuer evidence',
      );
    }

    final assetAccounts =
        accounts.where((a) => !a.id.startsWith('system_')).toList();
    final walletAccounts =
        assetAccounts.where((a) => a.accountType == 'wallet').toList();
    final otherAccounts =
        assetAccounts.where((a) => a.accountType != 'wallet').toList();

    // `bank` and `wallet` are both asset instruments. A payments-bank account
    // can legitimately be stored under either type, so the SMS hint only sets
    // the preference order; identity evidence still has to match. Credit cards
    // are never considered here (see `_resolveCard`).
    final preferred =
        kind == BalanceKind.wallet ? walletAccounts : otherAccounts;
    final secondary =
        kind == BalanceKind.wallet ? otherAccounts : walletAccounts;

    final preferredResult = _resolveAccountPool(
      preferred,
      last4: last4,
      issuer: issuer,
      hasIssuer: hasIssuer,
      isWallet: kind == BalanceKind.wallet,
    );
    if (preferredResult != null) return preferredResult;

    final secondaryResult = _resolveAccountPool(
      secondary,
      last4: last4,
      issuer: issuer,
      hasIssuer: hasIssuer,
      isWallet: kind != BalanceKind.wallet,
    );
    if (secondaryResult != null) return secondaryResult;

    return BalanceAttribution._unmatched(
      'No ${kind == BalanceKind.wallet ? 'wallet' : 'account'} matches the '
      'balance statement',
      canCreate: last4 != null && hasIssuer,
    );
  }

  /// Resolves a single asset-account pool.
  ///
  /// Returns null when the pool has no candidate, so the caller can try the
  /// other asset type. A last4 that exists in this pool but belongs to another
  /// issuer is reported as ambiguous instead of silently falling through.
  static BalanceAttribution? _resolveAccountPool(
    List<BankAccount> pool, {
    required String? last4,
    required String issuer,
    required bool hasIssuer,
    required bool isWallet,
  }) {
    List<BankAccount> candidates;

    if (last4 != null) {
      candidates = pool.where((a) => a.last4 == last4).toList();
      if (hasIssuer && candidates.isNotEmpty) {
        final byIssuer = candidates
            .where((a) => _issuerMatches(issuer, a.bank, a.name))
            .toList();
        if (byIssuer.isNotEmpty) {
          candidates = byIssuer;
        } else {
          return BalanceAttribution._ambiguous(
            'Account last4 $last4 belongs to a different issuer than "$issuer"',
            candidates.map((a) => a.id).toList(),
          );
        }
      }
    } else {
      candidates = pool
          .where((a) => _issuerMatches(issuer, a.bank, a.name))
          .toList();
    }

    if (candidates.length == 1) {
      final account = candidates.first;
      return BalanceAttribution._match(
        account.id,
        isCreditCard: false,
        reason: last4 != null
            ? 'Matched ${isWallet ? 'wallet' : 'account'} by last4 $last4'
            : 'Matched sole ${isWallet ? 'wallet' : 'account'} for issuer "$issuer"',
      );
    }
    if (candidates.length > 1) {
      return BalanceAttribution._ambiguous(
        'Multiple ${isWallet ? 'wallets' : 'accounts'} match the balance statement',
        candidates.map((a) => a.id).toList(),
      );
    }
    return null;
  }

  static String? _normaliseLast4(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == '0000') return null;
    return trimmed;
  }

  static bool _issuerMatches(
    String keyword,
    String bank,
    String name,
  ) {
    final haystack = '$bank $name'.toLowerCase();
    if (haystack.trim().isEmpty) return false;
    if (haystack.contains(keyword)) return true;
    for (final alias in _issuerAliases[keyword] ?? const <String>[]) {
      if (haystack.contains(alias)) return true;
    }
    // Bank sender ids are often compact (`jiopbs`, `hdfcbk`, `icicib`), so a
    // known issuer token embedded in the keyword may be the only evidence.
    for (final entry in _issuerAliases.entries) {
      if (entry.key.length < 3) continue;
      if (!keyword.contains(entry.key)) continue;
      if (haystack.contains(entry.key)) return true;
      for (final alias in entry.value) {
        if (haystack.contains(alias)) return true;
      }
    }
    return false;
  }

  static const Map<String, List<String>> _issuerAliases = {
    'fed': ['federal'],
    'federal': ['federal'],
    'sbi': ['state bank', 'sbi'],
    'jio': ['jio'],
    'bob': ['bank of baroda', 'baroda'],
    'onecard': ['onecard', 'one card'],
    'amex': ['american express', 'amex'],
    'hdfc': ['hdfc'],
    'icici': ['icici'],
    'axis': ['axis'],
    'kotak': ['kotak'],
    'idfc': ['idfc'],
    'indusind': ['indusind', 'indus ind'],
    'yes': ['yes bank'],
    'csb': ['csb'],
    'rbl': ['rbl'],
    'pnb': ['punjab national', 'pnb'],
    'canara': ['canara'],
    'union': ['union bank'],
    'au': ['au small finance', 'au bank'],
  };
}
