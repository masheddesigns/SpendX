import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;

/// A canonical merchant entry with multiple aliases.
///
/// Aliases are matched against text normalized via
/// [MerchantNormalizer.normalizeForMatch] (lowercased, non-alphanumeric
/// stripped, whitespace collapsed) so OCR noise like "amazon  pay" and
/// "amazon-pay" both match the alias `amazon pay`.
class MerchantPattern {
  final String canonical;
  final List<String> aliases;
  final double weight;
  const MerchantPattern({
    required this.canonical,
    required this.aliases,
    this.weight = 1.0,
  });
}

/// Shared merchant identity layer.
///
/// One source of truth for "what is this merchant" — used by:
///   * [TransactionTextParser] to resolve OCR/share text → merchant
///   * [RecurringDetector] to group transactions by stable identity
///   * [MerchantAggregator] to bucket history without fragmentation
///
/// Why centralized: if these layers each rolled their own normalization,
/// "Amazon Pay" / "AMAZON PAY INDIA" / "amazonpay" would split across
/// services and recurring detection would silently degrade as the same
/// merchant appears under multiple keys. One canonical lookup keeps
/// every layer aligned.
class MerchantNormalizer {
  MerchantNormalizer._();

  /// Body-strong dictionary entries.
  ///
  /// Each pattern has multiple aliases so OCR variations ("amazon  pay",
  /// "amazonpay", "amazon pay india") all collapse to the same canonical
  /// name. Aliases are matched against text normalized via
  /// [normalizeForMatch] to be resilient against OCR noise.
  ///
  /// Order matters within the list — longer/more-specific entries come
  /// first so "amazon pay" matches before "amazon".
  static final List<MerchantPattern> dictionary = [
    // Payment apps
    MerchantPattern(canonical: 'Amazon Pay', aliases: ['amazon pay', 'amazonpay']),
    MerchantPattern(canonical: 'Google Pay', aliases: ['google pay', 'gpay']),
    MerchantPattern(canonical: 'PhonePe', aliases: ['phonepe', 'phone pe']),
    MerchantPattern(canonical: 'Paytm', aliases: ['paytm']),
    MerchantPattern(canonical: 'CRED', aliases: ['cred']),

    // Food delivery
    MerchantPattern(canonical: 'Swiggy', aliases: ['swiggy']),
    MerchantPattern(canonical: 'Zomato', aliases: ['zomato']),
    MerchantPattern(canonical: 'Blinkit', aliases: ['blinkit']),
    MerchantPattern(canonical: 'Zepto', aliases: ['zepto']),
    MerchantPattern(canonical: 'Instamart', aliases: ['instamart']),
    MerchantPattern(canonical: 'BigBasket', aliases: ['bigbasket', 'big basket']),
    MerchantPattern(canonical: 'Dunzo', aliases: ['dunzo']),

    // E-commerce
    MerchantPattern(canonical: 'Flipkart', aliases: ['flipkart']),
    MerchantPattern(canonical: 'Amazon', aliases: ['amazon']),
    MerchantPattern(canonical: 'Myntra', aliases: ['myntra']),
    MerchantPattern(canonical: 'Meesho', aliases: ['meesho']),
    MerchantPattern(canonical: 'Ajio', aliases: ['ajio']),
    MerchantPattern(canonical: 'Nykaa', aliases: ['nykaa']),

    // Travel
    MerchantPattern(canonical: 'Uber', aliases: ['uber']),
    MerchantPattern(canonical: 'Ola', aliases: ['ola']),
    MerchantPattern(canonical: 'Rapido', aliases: ['rapido']),
    MerchantPattern(canonical: 'IRCTC', aliases: ['irctc']),
    MerchantPattern(canonical: 'BookMyShow', aliases: ['bookmyshow', 'book my show']),
    MerchantPattern(canonical: 'MakeMyTrip', aliases: ['makemytrip', 'make my trip']),
    MerchantPattern(canonical: 'Goibibo', aliases: ['goibibo']),

    // Subscriptions
    MerchantPattern(canonical: 'Netflix', aliases: ['netflix']),
    MerchantPattern(canonical: 'Spotify', aliases: ['spotify']),
    MerchantPattern(canonical: 'Hotstar', aliases: ['hotstar']),
    MerchantPattern(canonical: 'YouTube', aliases: ['youtube']),

    // QSR
    MerchantPattern(canonical: 'Starbucks', aliases: ['starbucks']),
    MerchantPattern(canonical: 'Dominos', aliases: ['dominos', 'domino s']),
    MerchantPattern(canonical: 'McDonalds', aliases: ['mcdonalds', 'mcdonald s']),
    MerchantPattern(canonical: 'KFC', aliases: ['kfc']),
  ];

  static final RegExp _stripRe = RegExp(r'[^a-z0-9 ]');
  static final RegExp _wsRe = RegExp(r'\s+');

  /// Confidence floor for [lookupCanonical] / [canonicalKey] to accept
  /// a dictionary match. Anything weaker than substring containment
  /// (e.g. mere token overlap) drops below 0.8 and falls through to the
  /// raw normalized key — preventing aggressive collapse of
  /// superficially-similar but distinct merchants ("Indian Oil" vs
  /// "Indian Bank" both share the token "indian" but should never
  /// merge into one canonical bucket).
  static const double _matchAcceptThreshold = 0.8;

  /// Tokens that show up in OCR receipt boilerplate and never carry
  /// merchant identity on their own. Used by [canonicalKey] to detect
  /// inputs that are dominated by receipt scaffolding rather than a
  /// real merchant name — those return empty so the intelligence layer
  /// drops them rather than bucketing under noise.
  ///
  /// NOT used by [lookupCanonical] / [matchScore] — the parser
  /// legitimately calls those against full OCR bodies that contain
  /// these tokens alongside the actual merchant ("paid amazon" must
  /// still resolve to Amazon).
  static const Set<String> _noiseTokens = {
    'order', 'orders', 'success', 'successful', 'successfully',
    'txn', 'transaction', 'transferred', 'id', 'reference', 'ref',
    'powered', 'date', 'time', 'utr', 'rrn', 'merchant',
  };

  /// Fraction of meaningful tokens that must be noise before the input
  /// is treated as scaffolding. Conservative (0.7) so a single stray
  /// noise word doesn't kill grouping for "paid amazon" or
  /// "transferred to John".
  static const double _noiseDominanceThreshold = 0.7;

  /// Normalize text for dictionary matching. Lowercases, strips
  /// non-alphanumeric characters, collapses whitespace. Makes matching
  /// resilient to OCR variations like "amazon  pay" or "amazon-pay".
  static String normalizeForMatch(String text) {
    return text.toLowerCase().replaceAll(_stripRe, ' ').replaceAll(_wsRe, ' ').trim();
  }

  /// Score how confidently [normalized] matches a dictionary [alias].
  ///   1.0 — exact equality (normalized == alias)
  ///   0.8 — alias appears as a contiguous whole-token sequence
  ///         in normalized (e.g. "amazon pay india" matches alias
  ///         "amazon pay" because [amazon, pay] is a token subarray;
  ///         "razorpay payment" does NOT match alias "pay" because
  ///         "pay" isn't a standalone token of normalized)
  ///   0.6 — token-level overlap only (≥3-char tokens shared in
  ///         either direction); diagnostic, not accepted by lookup
  ///   0.0 — nothing in common
  ///
  /// The graded scale lets [lookupCanonical] accept only confident
  /// matches (≥0.8) and reject weak token overlap that would
  /// otherwise merge unrelated merchants. Whole-token matching at
  /// the 0.8 tier prevents mid-word contamination ("smartpay" no
  /// longer hits aliases like "pay").
  static double matchScore(String normalized, String alias) {
    if (normalized.isEmpty || alias.isEmpty) return 0;
    if (normalized == alias) return 1.0;
    if (_containsAsTokens(normalized, alias)) return 0.8;
    // Token-level overlap fallback. Splits on whitespace and counts
    // whole-word matches in either direction. Diagnostic only — not
    // strong enough to accept on its own.
    final aTokens = normalized.split(_wsRe).where((t) => t.length >= 3).toSet();
    final bTokens = alias.split(_wsRe).where((t) => t.length >= 3).toSet();
    if (aTokens.isEmpty || bTokens.isEmpty) return 0;
    if (aTokens.intersection(bTokens).isNotEmpty) return 0.6;
    return 0;
  }

  /// True when [alias]'s token sequence appears contiguously inside
  /// [normalized]'s tokens. Treats both as space-delimited word lists
  /// and slides the alias over normalized looking for a whole-token
  /// match.
  ///
  /// Why this matters: dictionary aliases come in two shapes —
  ///   * Multi-token   ("amazon pay")  → matches as a token subarray
  ///                                      inside "amazon pay india"
  ///   * Single-token  ("amazonpay")   → matches when one of
  ///                                      normalized's tokens equals
  ///                                      it, e.g. "paid via amazonpay"
  /// Both forms ship in the dictionary side by side so OCR variants
  /// of the same merchant ("Amazon Pay" vs "amazonpay") collapse to
  /// the same canonical without the alias accidentally hitting
  /// mid-word like "smartpay" / "razorpay".
  static bool _containsAsTokens(String normalized, String alias) {
    final aliasTokens =
        alias.split(_wsRe).where((t) => t.isNotEmpty).toList();
    final norm =
        normalized.split(_wsRe).where((t) => t.isNotEmpty).toList();
    if (aliasTokens.isEmpty || aliasTokens.length > norm.length) return false;
    for (var i = 0; i <= norm.length - aliasTokens.length; i++) {
      var ok = true;
      for (var j = 0; j < aliasTokens.length; j++) {
        if (norm[i + j] != aliasTokens[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }

  /// Look up [text] against the dictionary. Returns the canonical name
  /// (e.g. "Amazon Pay") if any alias matches with score
  /// ≥ [_matchAcceptThreshold], null otherwise.
  ///
  /// Used by the parser as the body_strong merchant signal and by the
  /// intelligence layer as the canonical identity for grouping.
  ///
  /// Walks aliases in declaration order so longer/more-specific
  /// entries (placed first in [dictionary]) win on ties.
  static String? lookupCanonical(String text) {
    if (text.isEmpty) return null;
    final normalized = normalizeForMatch(text);
    if (normalized.isEmpty) return null;
    for (final pattern in dictionary) {
      for (final alias in pattern.aliases) {
        if (matchScore(normalized, alias) >= _matchAcceptThreshold) {
          return pattern.canonical;
        }
      }
    }
    // Bounded fuzzy fallback for OCR-truncated/slipped aliases like
    // "flipkrt", "amzn pay", "starbukcs". Only fires when the strict
    // match failed AND the input is short (≤16 chars per token cluster
    // of length ≤12) — keeps cost trivial and collision risk low.
    final fuzzy = _fuzzyLookup(normalized);
    if (fuzzy != null) {
      debugPrint('[Normalizer][Fuzzy][Match] "$normalized" → $fuzzy');
      return fuzzy;
    }
    return null;
  }

  /// Try every alias against [normalized] using a tight near-match
  /// rule. Returns the canonical of the first hit, null otherwise.
  /// Bounded by:
  ///   * input length 4..16 chars — under 4 chars the collision risk
  ///     spikes ("hp" / "io" can match too many aliases by accident)
  ///     and there's nothing to recover anyway
  ///   * alias length ≤ 12 chars
  ///   * input token count ≤ 2 — multi-token inputs ("indian pay
  ///     service") rely on strict matching to prevent cross-merchant
  ///     bleed where a single fuzzy alias hit would otherwise hijack
  ///     identity for the whole phrase.
  static String? _fuzzyLookup(String normalized) {
    if (normalized.length < 4 || normalized.length > 16) return null;
    final tokens = normalized.split(_wsRe).where((t) => t.isNotEmpty).toList();
    if (tokens.length > 2) return null;
    for (final pattern in dictionary) {
      for (final alias in pattern.aliases) {
        if (alias.length > 12) continue;
        if (_isNearMatch(normalized, alias)) return pattern.canonical;
      }
    }
    return null;
  }

  /// Lightweight near-match for OCR slips. Two flavors combined:
  ///   1. End-truncation: shorter is a prefix of longer, length diff
  ///      ≤ 2. Catches "flipkar" / "flipka" → "flipkart".
  ///   2. Positional Hamming: same-position char comparison up to the
  ///      shorter length, allows ≤ 2 mismatches AND length diff ≤ 2.
  ///      Catches "flipkrt" / "amzn" / "swiggi" → swiggy.
  ///
  /// Intentionally NOT full Levenshtein — DP overhead outweighs gain
  /// for ≤12-char strings, and the positional check is strict enough
  /// to avoid collapsing unrelated short merchants.
  static bool _isNearMatch(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    final lenDiff = (a.length - b.length).abs();
    if (lenDiff > 2) return false;

    // Prefix check (handles trailing truncation cleanly).
    final shorter = a.length <= b.length ? a : b;
    final longer = a.length <= b.length ? b : a;
    if (longer.startsWith(shorter)) return true;

    // Positional comparison. Length difference counts toward the
    // mismatch budget so we don't accept tiny strings that happen to
    // align on every shared character but differ wildly in length.
    int mismatches = lenDiff;
    final n = math.min(a.length, b.length);
    for (var i = 0; i < n; i++) {
      if (a.codeUnitAt(i) != b.codeUnitAt(i)) {
        mismatches++;
        if (mismatches > 2) return false;
      }
    }
    return mismatches <= 2;
  }

  /// Stable grouping key for an arbitrary merchant string.
  ///
  /// Resolution:
  ///   1. Reject if dominated by OCR scaffolding tokens — returning
  ///      empty so the intelligence layer drops the row entirely
  ///      rather than bucketing under "order id 12345" or similar.
  ///   2. If digit-heavy (>40% digits) → skip dictionary canonical
  ///      mapping. "store123" / "store124" should remain distinct
  ///      keys rather than collapse via fuzzy alias hits, and an
  ///      ID-shaped merchant rarely has a real canonical anyway.
  ///   3. Dictionary alias hit → lowercased canonical
  ///      (e.g. "amazon pay")
  ///   4. Else → normalized input WITH a length suffix
  ///      (e.g. "local cafe|len:10")
  ///
  /// The length suffix in the fallback path adds entropy so two
  /// distinct unknown merchants whose normalized forms happen to be
  /// short prefixes of one another don't collapse into a single
  /// bucket. Dictionary canonicals don't get the suffix — they're
  /// already collision-proof by definition. Empty for blank input.
  static String canonicalKey(String input) {
    if (input.trim().isEmpty) return '';
    final normalized = normalizeForMatch(input);
    if (normalized.isEmpty) return '';
    if (_isNoiseDominated(normalized)) return '';
    if (_isDigitHeavy(normalized)) {
      return '$normalized|len:${normalized.length}';
    }
    final canonical = lookupCanonical(input);
    if (canonical != null) return canonical.toLowerCase();
    return '$normalized|len:${normalized.length}';
  }

  /// Maximum digit fraction tolerated before we treat the input as an
  /// identifier rather than a name. 0.4 is conservative — real
  /// merchants like "7-Eleven" or "24/7 Mart" still pass (the dash /
  /// slash + words drop digit ratio under 40%).
  static const double _digitDensityCeiling = 0.4;

  /// True when the input looks like an identifier (lots of digits)
  /// rather than a merchant name. Skips dictionary canonical lookup
  /// so "store123" and "store124" stay in distinct buckets even when
  /// they'd otherwise share an alias-fuzzy match.
  static bool _isDigitHeavy(String normalized) {
    if (normalized.isEmpty) return false;
    int digits = 0;
    int total = 0;
    for (var i = 0; i < normalized.length; i++) {
      final c = normalized.codeUnitAt(i);
      if (c == 0x20) continue; // skip spaces from total
      total++;
      if (c >= 0x30 && c <= 0x39) digits++;
    }
    if (total == 0) return false;
    return digits / total > _digitDensityCeiling;
  }

  /// True when most of the meaningful tokens in [normalized] are
  /// receipt scaffolding rather than identity-bearing words.
  /// Skipped on very short inputs (< 4 tokens) where one stray noise
  /// word would otherwise dominate by ratio.
  static bool _isNoiseDominated(String normalized) {
    final tokens =
        normalized.split(_wsRe).where((t) => t.length >= 3).toList();
    if (tokens.length < 4) return false;
    final noise = tokens.where(_noiseTokens.contains).length;
    return noise / tokens.length >= _noiseDominanceThreshold;
  }

  /// Best display name for [input]. Dictionary hit wins (proper casing
  /// from the canonical entry); otherwise the trimmed input is returned
  /// as-is so user-typed merchants keep their original casing.
  static String canonicalDisplay(String input) {
    final canonical = lookupCanonical(input);
    if (canonical != null) return canonical;
    return input.trim();
  }
}
