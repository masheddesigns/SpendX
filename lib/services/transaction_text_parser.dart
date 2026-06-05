import '../models/review_item.dart';
import 'merchant_memory.dart';
import 'merchant_normalizer.dart';

/// Rule-based parser for shared text and OCR output.
///
/// Replaces the SMS parser. Source-agnostic — works on:
///   - Plain text shared from any payment app (UPI receipt, etc.)
///   - OCR-extracted text from screenshots
///   - Manually pasted text
///
/// Pattern-based, not app-specific. Does not try to identify which app
/// the text came from — only extracts universal payment patterns.
class TransactionTextParser {
  TransactionTextParser._();

  // Precompiled hot-path regexes (compiled once per process, not per parse).
  static final RegExp _newlineRe = RegExp(r'\r?\n');
  static final RegExp _whitespaceRe = RegExp(r'\s+');
  static final RegExp _digitSpaceRe = RegExp(r'(\d)\s+(\d)');
  static final RegExp _trailingPuncRe = RegExp(r'[\.,]+\s*$');
  static final RegExp _vpaRe = RegExp(r'@\w{2,}');
  static final RegExp _cardSpaceDigitRe = RegExp(r'card\s+\d');

  /// Bump when ANY parser logic, regex, dictionary, or weight changes so
  /// stale cached entries from older builds can never be served.
  /// Mixed into the cache key — a version bump effectively wipes the cache
  /// without needing an explicit clear.
  static const _parserVersion = 4;

  /// Cache TTL — entries older than this are evicted on read. Prevents
  /// long-lived runs from accumulating drift; 5 minutes is well past any
  /// preview/rebuild window in normal use.
  static const _cacheTtl = Duration(minutes: 5);

  /// Lightweight in-process cache for repeated identical shares.
  /// Bounded at 50 entries with FIFO eviction + per-entry TTL.
  static final Map<int, _CacheEntry> _parseCache = {};
  static const _maxParseCacheSize = 50;

  /// Parse [text] with merchant memory lookup. Use this from production
  /// entry points (router, share intent) so user corrections compound
  /// over time. Tests can use the sync [parse] directly.
  static Future<ParsedTransaction> parseWithLearning(
    String text, {
    String? source,
  }) async {
    final learned = await MerchantMemory.instance.check(text);
    return parse(text, source: source, learnedMerchant: learned);
  }

  /// Parse [text] into a [ParsedTransaction]. Always returns a result —
  /// confidence reflects how reliable the parse is. Caller decides what
  /// to do based on confidence + isFailed.
  ///
  /// [learnedMerchant] — optional precomputed merchant from MerchantMemory.
  /// When supplied, takes top priority and returns with `merchantSource =
  /// 'learned'` (highest-confidence band).
  static ParsedTransaction parse(
    String text, {
    String? source,
    String? learnedMerchant,
  }) {
    // Lightweight cache: identical share within the same session reuses
    // the last result. Most user flows produce duplicate parse calls
    // (preview rebuilds, validation snapshots). Also cheap to recompute
    // if the cache misses.
    //
    // Key folds in `_parserVersion` so a code bump auto-invalidates all
    // stored entries — no explicit clear ever needed.
    final cacheKey = Object.hash(_parserVersion, text, source, learnedMerchant);
    final cached = _parseCache[cacheKey];
    if (cached != null) {
      // TTL check — drop stale entries even if key still matches.
      if (DateTime.now().difference(cached.cachedAt) <= _cacheTtl) {
        return cached.data;
      }
      _parseCache.remove(cacheKey);
    }

    final normalized = _normalize(text);
    final lower = normalized.toLowerCase();

    // Single-scan tokenizer — split once at the top of the parse and reuse
    // for every downstream consumer that needs word-level lookups
    // (direction, method, stopword filtering). Avoids multiple
    // String.split / Set construction per parse.
    final tokens = lower.split(_whitespaceRe);
    final tokenSet = tokens.toSet();

    // Direction detection: compute hasCredit / hasDebit ONCE here and
    // pass the booleans down. Previously _isCredit + _hasDirectionSignal
    // each ran both regexes — this halves the regex scans on the hot path.
    //
    // hasDebit also captures the bare-recipient UPI pattern ("To
    // Vidhul Sathyan") via the case-preserved [normalized] text — the
    // verb-keyword regex alone misses these because the receipt has
    // no "paid"/"sent"/"transferred" prefix.
    final hasCredit = _creditKeywords.hasMatch(lower);
    final hasDebit = _debitKeywords.hasMatch(lower) ||
        _outgoingToRecipientRe.hasMatch(normalized);

    // OCR-specific number repair before amount extraction:
    //   "1 5 0"   → "150"   (digit-spacing)
    //   "1,5O0"   → "1,500" (letter O misread as zero, only between digits)
    final repaired = _repairOcrNumerics(normalized);
    // Two-pass amount extraction:
    //   1. Currency-prefixed (₹/Rs/INR + digits) — high confidence
    //   2. Naked-number fallback for app screenshots that omit the symbol
    double amount = _extractAmount(repaired) ?? 0.0;
    bool amountFromFallback = false;
    if (amount == 0) {
      final fallback = _extractAmountFallback(repaired);
      if (fallback != null && fallback > 0) {
        amount = fallback;
        amountFromFallback = true;
      }
    }
    final isCredit = _resolveCredit(hasCredit: hasCredit, hasDebit: hasDebit);
    // Resolution priority (top wins):
    //   1. Learned (user-confirmed memory)
    //   2. body_strong (dictionary alias match)
    //   3. keyword regex
    //   4. fallback regex
    String? merchant;
    String? merchantSource;
    if (learnedMerchant != null && learnedMerchant.trim().isNotEmpty) {
      merchant = learnedMerchant.trim();
      merchantSource = 'learned';
    } else {
      final result = _extractMerchantWithSource(normalized);
      merchant = result.$1;
      merchantSource = result.$2;
    }
    final method = _extractMethod(lower, tokenSet);
    final refId = _extractRefId(normalized);
    final last4 = _extractLast4(normalized);
    final bankName = _extractBankName(lower);
    final hasDirection = hasCredit || hasDebit;

    // Confidence scoring. Weighted by signal strength:
    //   amount currency-prefixed → 0.4  (strong)
    //   amount naked-number      → 0.2  (heuristic)
    //   merchant learned         → 0.30 (user-confirmed memory)
    //   merchant body_strong     → 0.20 (dictionary match)
    //   merchant keyword         → 0.12 (explicit "paid to X")
    //   merchant fallback        → 0.05 (weak "to X" / "at X")
    //   direction signal         → 0.2
    //   reference id             → 0.1
    //   method detected          → 0.1
    double confidence = 0;
    if (amount > 0) confidence += amountFromFallback ? 0.2 : 0.4;
    if (merchant != null && merchant.isNotEmpty) {
      confidence += switch (merchantSource) {
        'learned' => 0.30,
        'body_strong' => 0.20,
        'keyword' => 0.12,
        'fallback' => 0.05,
        _ => 0.05,
      };
    }
    if (hasDirection) confidence += 0.2;
    if (refId != null) confidence += 0.1;
    if (method != null) confidence += 0.1;
    // Bound to [0, 1] then round to 2 decimals so the same input always
    // produces the same display value (e.g. "73%" not "72.99999%").
    confidence = confidence.clamp(0.0, 1.0);
    confidence = (confidence * 100).round() / 100;

    final result = ParsedTransaction(
      amount: amount,
      isCredit: isCredit,
      rawText: text,
      date: DateTime.now(),
      merchant: merchant,
      refId: refId,
      last4: last4,
      bankName: bankName,
      method: method,
      source: source ?? 'share',
      confidence: confidence,
      merchantSource: merchantSource,
      hasDirectionSignal: hasDirection,
    );

    // FIFO cache: drop oldest when full
    if (_parseCache.length >= _maxParseCacheSize) {
      _parseCache.remove(_parseCache.keys.first);
    }
    _parseCache[cacheKey] = _CacheEntry(data: result, cachedAt: DateTime.now());
    return result;
  }

  /// Returns true if the text indicates a failed/declined/cancelled payment.
  /// This is checked separately from confidence so the UX can warn the user.
  static bool isFailedPayment(String text) =>
      _isFailedPayment(_normalize(text).toLowerCase());

  // ── Normalization ─────────────────────────────────────────────────

  /// Decorative/promotional phrases OCR commonly captures from receipts.
  /// Used to identify and DROP noisy lines wholesale — not greedy replace —
  /// so that single-line OCR ("Paid ₹500 available balance ₹2000") doesn't
  /// lose useful context.
  static final _noiseFragments = <String>[
    'available balance',
    'avbl bal',
    'thank you',
    'powered by',
    'download the app',
    'download our app',
    'visit our website',
    'visit website',
    'this is a system generated',
    'do not reply',
    'for queries',
    'reach us at',
    'customer care',
  ];

  static bool _isNoisyLine(String line) {
    final l = line.toLowerCase();
    for (final f in _noiseFragments) {
      if (l.contains(f)) return true;
    }
    return false;
  }

  static String _normalize(String text) {
    final cleanedRaw = text
        .replaceAll('\u00A0', ' ') // non-breaking space
        .replaceAll('\u200B', ''); // zero-width space

    // Line-based filter: drop entire lines that look promotional/decorative.
    // Keeps single-line content intact so we never accidentally truncate
    // useful data after a noise phrase.
    final lines = cleanedRaw.split(_newlineRe);
    final kept = lines.where((line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) return false;
      // For multi-line input we drop noisy lines entirely.
      if (lines.length > 1 && _isNoisyLine(trimmed)) return false;
      return true;
    });

    return kept.join(' ').replaceAll(_whitespaceRe, ' ').trim();
  }

  // ── OCR numeric repair (scoped to currency contexts) ─────────────

  /// Repairs OCR slips ONLY inside currency tokens (after ₹/Rs/INR).
  /// Scoping prevents collateral damage like converting "OYO" → "0Y0"
  /// or "Hello" tokens elsewhere. Common slips fixed:
  ///   "₹ 1 5 0"     → "₹150"     (digit-spacing)
  ///   "₹ 1,5O0"     → "₹1,500"   (letter O for zero)
  ///   "Rs l50"      → "Rs 150"   (lowercase l for one)
  ///   "₹ IOO"       → "₹100"     (capital I for one)
  static final _currencyContext = RegExp(
    r'(₹|Rs\.?|INR)\s*([0-9OIl,.\s]+)',
    caseSensitive: false,
  );

  static String _repairOcrNumerics(String text) {
    return text.replaceAllMapped(_currencyContext, (m) {
      final prefix = m.group(1)!;
      var raw = m.group(2)!;
      // Repeatedly collapse digit-space-digit until stable
      while (_digitSpaceRe.hasMatch(raw)) {
        raw = raw.replaceAllMapped(_digitSpaceRe, (mm) => '${mm[1]}${mm[2]}');
      }
      // OCR letter→digit slips (only inside this currency token)
      raw = raw
          .replaceAll(RegExp(r'O', caseSensitive: false), '0')
          .replaceAll('I', '1')
          .replaceAll('l', '1');
      return '$prefix $raw';
    });
  }

  // ── Amount extraction ─────────────────────────────────────────────

  /// Tier 1: amount with action context (debited/paid/sent + Rs X)
  /// Tier 2: action keyword followed by amount
  /// Tier 3: any Rs/INR/₹ amount
  static final _amountPatterns = <RegExp>[
    // "₹500 debited", "Rs 500 paid" (allows multiple spaces between symbol+number)
    RegExp(
      r'(?:₹|Rs\.?|INR)\s*([0-9,]+(?:\.\d{1,2})?)\s*'
      r'(?:has\s+been\s+|was\s+|is\s+)?'
      r'(?:debited|credited|paid|received|sent|spent|charged|deducted|deposited)',
      caseSensitive: false,
    ),
    // "debited Rs 500", "paid Rs.500", "received ₹500"
    RegExp(
      r'(?:debited|credited|paid|received|sent|spent|charged|deducted|deposited)'
      r'[^0-9]{0,30}?(?:₹|Rs\.?|INR)\s*([0-9,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    ),
    // "of Rs 500", "for Rs.500"
    RegExp(
      r'(?:of|for|amount)\s+(?:₹|Rs\.?|INR)\s*([0-9,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    ),
    // Bare amount: ₹500, Rs.500
    RegExp(
      r'(?:₹|Rs\.?|INR)\s*([0-9,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    ),
  ];

  static double? _extractAmount(String text) {
    for (final p in _amountPatterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        final raw = m.group(1)!.replaceAll(',', '');
        final value = double.tryParse(raw);
        if (value != null && value > 0) return value;
      }
    }
    return null;
  }

  // ── Naked-number fallback extractor ───────────────────────────────
  //
  // Some payment apps (GPay, PhonePe, Amazon Pay) render the amount as
  // a standalone number with NO currency prefix in screenshots.
  // Example: "565.85\nCompleted\nTo Vidhul Sathyan\n+91 63838 16830".
  //
  // Strategy (two-tier, decimals trump integers):
  //   Tier 1 — decimal-formatted numbers ("565.85"). These are
  //            currency-shaped by definition; phone numbers and IDs
  //            don't carry decimals. If any decimal candidate exists,
  //            pick from this tier alone — never fall through to
  //            integers, because that re-opens the phone/ID hole.
  //   Tier 2 — naked integers, but with phone-adjacency rejection
  //            (skip candidates near "+91" / "+XX" prefixes) and the
  //            existing reference-sequence guard.
  // Within each tier: keyword proximity wins, then largest value.

  static final _nakedNumberPattern =
      RegExp(r'\b\d{2,6}(?:,\d{3})*(?:\.\d{1,2})?\b');

  static final _amountKeywords = RegExp(
    r'\b(?:paid|debited|credited|spent|sent|received|charged|deducted|'
    r'amount|total|deposited|withdrawn|transferred|ordered)\b',
    caseSensitive: false,
  );

  /// Country-code prefix used to detect phone-adjacent numbers. A
  /// candidate within 30 chars after this pattern is almost certainly
  /// a phone-number fragment, not a currency amount.
  static final _phonePrefixRe = RegExp(r'\+\d{1,3}');

  static double? _extractAmountFallback(String text) {
    final decimal = <(int, double)>[];
    final integer = <(int, double)>[];

    for (final m in _nakedNumberPattern.allMatches(text)) {
      final raw = m.group(0)!;
      final stripped = raw.replaceAll(',', '');
      if (stripped.length > 9) continue;
      final value = double.tryParse(stripped);
      if (value == null || value < 10 || value > 1000000) continue;
      // Phone-adjacent rejection: a "+91" anywhere in the 30 chars
      // before this number marks it as a phone fragment, not money.
      if (_isPhoneAdjacent(text, m.start)) continue;
      if (raw.contains('.')) {
        decimal.add((m.start, value));
      } else {
        integer.add((m.start, value));
      }
    }

    // Tier 1 — decimals win outright when present. A decimal-shaped
    // number in a payment receipt is the amount with very high
    // probability; falling through to integers from here would re-
    // open exactly the phone/ID hole this tier is designed to close.
    if (decimal.isNotEmpty) {
      return _pickAmountWithKeywordBias(text, decimal);
    }

    if (integer.isEmpty) return null;
    if (_isLikelyReferenceSequence(integer.map((c) => c.$2).toList())) {
      return null;
    }
    return _pickAmountWithKeywordBias(text, integer);
  }

  /// Bias toward candidates within 60 chars of a payment keyword, then
  /// fall back to the largest plausible candidate. Shared between the
  /// decimal and integer tiers so the bias rule stays consistent.
  static double? _pickAmountWithKeywordBias(
      String text, List<(int, double)> candidates) {
    if (candidates.isEmpty) return null;
    final lower = text.toLowerCase();
    final keywordHit = _amountKeywords.firstMatch(lower);
    if (keywordHit != null) {
      final kwPos = keywordHit.start;
      final near = candidates
          .where((c) => (c.$1 - kwPos).abs() <= 60)
          .toList()
        ..sort((a, b) => b.$2.compareTo(a.$2));
      if (near.isNotEmpty) return near.first.$2;
    }
    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    return candidates.first.$2;
  }

  /// True when a country-code prefix (`+91`, `+1`, `+44`, etc.)
  /// appears within 30 chars BEFORE [pos]. UPI receipts commonly
  /// render the recipient phone as "+91 63838 16830" — without this
  /// guard the `63838` cluster passes the naked-number filter and
  /// dominates the amount selection.
  static bool _isPhoneAdjacent(String text, int pos) {
    final start = pos > 30 ? pos - 30 : 0;
    return _phonePrefixRe.hasMatch(text.substring(start, pos));
  }

  /// True when every candidate is unusually large (>100k) AND there are
  /// at least two of them — the hallmark of a screenshot full of order /
  /// ref / txn IDs rather than an amount. Conservative on purpose: a
  /// single 200k value could be a real high-ticket purchase.
  static bool _isLikelyReferenceSequence(List<double> numbers) {
    if (numbers.length < 2) return false;
    return numbers.every((n) => n > 100000);
  }

  // ── Direction (credit / debit) ────────────────────────────────────

  static final _creditKeywords = RegExp(
    r'\b(credited|received|deposit(?:ed)?|refund(?:ed)?|cashback|salary|'
    r'bonus|collected|reimburs(?:ed|ement)?)\b',
    caseSensitive: false,
  );

  static final _debitKeywords = RegExp(
    r'\b(debited|paid|sent|spent|charged|deducted|withdrawn|withdrew|'
    r'purchase[ds]?|transferred?|swiped|outgoing)\b',
    caseSensitive: false,
  );

  /// Bare-recipient outgoing pattern. UPI receipts (GPay, PhonePe,
  /// Paytm) often render the destination as a separate line — "To
  /// Vidhul Sathyan" — without any preceding verb the [_debitKeywords]
  /// regex would catch. Runs against the CASE-PRESERVED normalized
  /// text (not the lowercased one) so the capitalized recipient name
  /// distinguishes legitimate `To Person/Company` from generic
  /// English uses like "to your account" or "according to". The
  /// 2-char minimum on the recipient name avoids one-letter false
  /// positives.
  static final _outgoingToRecipientRe = RegExp(r'\bTo\s+[A-Z][a-zA-Z]{1,}');

  /// Resolve credit/debit from precomputed signals. Debit wins on tie
  /// (most receipts are spends). Pure function — kept here so the tie-
  /// breaking rule lives next to the keyword definitions.
  static bool _resolveCredit({
    required bool hasCredit,
    required bool hasDebit,
  }) {
    if (hasDebit) return false;
    return hasCredit;
  }

  // ── Failure detection ─────────────────────────────────────────────

  static final _failurePatterns = RegExp(
    r'\b(?:failed|declined|cancelled|canceled|reversed|unsuccessful|'
    r'transaction\s+failed|payment\s+failed|insufficient\s+balance)\b',
    caseSensitive: false,
  );

  static bool _isFailedPayment(String lower) =>
      _failurePatterns.hasMatch(lower);

  // ── Merchant extraction ───────────────────────────────────────────
  //
  // Resolution priority (strict, top wins):
  //   1. Known-merchant body match     — strongest signal
  //   2. Keyword pattern (paid to / received from)
  //   3. Bare-preposition fallback     (to X / at X) — weakest
  //
  // Each candidate is then run through a noise filter to reject OCR
  // garbage (multi-line phrases, stopword-heavy strings).

  /// Phrases whose presence near a candidate marks it as OCR garbage.
  /// "Cc Ordered Successfully Order Id Flyngo S" etc.
  static final _merchantNoiseFragments = <String>[
    'order id',
    'order no',
    'ordered successfully',
    'successfully',
    'transaction id',
    'reference',
    'date',
    'time',
    'paid from',
    'paid to vpa',
    'powered by',
  ];

  /// Returns true if the candidate looks like OCR junk rather than a
  /// real merchant. Conservative — only rejects clearly-bad strings.
  static bool _isNoisyMerchant(String candidate) {
    final lower = candidate.toLowerCase();
    // Reject overly long captures (real merchant names are 1-4 words)
    final wordCount = candidate.trim().split(_whitespaceRe).length;
    if (wordCount > 5) return true;
    // Multiple noise fragments → garbage
    int hits = 0;
    for (final f in _merchantNoiseFragments) {
      if (lower.contains(f)) hits++;
      if (hits >= 2) return true;
    }
    // Stopword density — if >50% of tokens are stopwords, reject
    final tokens = lower.split(_whitespaceRe);
    if (tokens.length >= 3) {
      final stopHits =
          tokens.where((t) => _merchantStopWords.contains(t)).length;
      if (stopHits / tokens.length > 0.5) return true;
    }
    return false;
  }

  // The dictionary + normalization helpers live in [MerchantNormalizer]
  // so the recurring detector and merchant aggregator group transactions
  // under the same canonical identity. The parser delegates here rather
  // than duplicating the dictionary — single source of truth.

  /// Common patterns:
  ///   "paid to ZOMATO"
  ///   "to AMAZON via UPI"
  ///   "at Swiggy"
  ///   "from John Doe"
  // Note: apostrophe omitted from char class — raw strings in Dart cannot
  // contain backslash-escaped apostrophes. Merchants like "Domino's" still
  // match via the open-ended word boundary; only the apostrophe character
  // itself is excluded from the captured name.
  static final _merchantPatterns = <RegExp>[
    // "paid to MERCHANT", "sent to MERCHANT"
    RegExp(
      r'(?:paid|sent|transferred)\s+to\s+([A-Z][A-Za-z0-9 .&-]{1,40})',
    ),
    // "to MERCHANT" (with capital first letter)
    RegExp(r'\bto\s+([A-Z][A-Za-z0-9 .&-]{1,40})'),
    // "at MERCHANT"
    RegExp(r'\bat\s+([A-Z][A-Za-z0-9 .&-]{1,40})'),
    // "received from MERCHANT", "from MERCHANT"
    RegExp(r'\bfrom\s+([A-Z][A-Za-z0-9 .&-]{1,40})'),
  ];

  /// Words that should never be treated as a merchant.
  static final _merchantStopWords = {
    'upi', 'bank', 'account', 'a/c', 'card', 'ref', 'txn', 'transaction',
    'payment', 'your', 'the', 'a', 'an', 'on', 'for', 'via', 'using',
  };

  /// Returns (normalizedMerchant, source).
  /// `source` = 'body_strong' (dictionary match — most reliable)
  ///         | 'keyword'     (regex: "paid to X" / "received from X")
  ///         | 'fallback'    (weakest: "to X" / "at X")
  ///         | null          (no merchant)
  ///
  /// Resolution order is critical for OCR text — dictionary match wins
  /// because keyword regex picks up garbage from screenshot phrases like
  /// "Cc Ordered Successfully Order Id Flyngo S".
  static (String?, String?) _extractMerchantWithSource(String text) {
    final lower = text.toLowerCase();

    // 1. Dictionary match — strongest. Bypasses noisy regex entirely.
    final known = MerchantNormalizer.lookupCanonical(lower);
    if (known != null) {
      return (known, 'body_strong');
    }

    // 2. Keyword pattern — explicit "paid to X" / "received from X"
    // 3. Bare-preposition fallback — "to X" / "at X"
    for (var i = 0; i < _merchantPatterns.length; i++) {
      final m = _merchantPatterns[i].firstMatch(text);
      if (m == null) continue;
      var merchant = m.group(1)!.trim();
      merchant = merchant
          .replaceAll(
            RegExp(r'\s+(?:on|via|ref|upi|using|w\.?e\.?f|dated|bank).*$',
                caseSensitive: false),
            '',
          )
          .trim();
      if (merchant.isEmpty || merchant.length < 2) continue;
      final firstWord = merchant.split(' ').first.toLowerCase();
      if (_merchantStopWords.contains(firstWord)) continue;
      // Reject OCR garbage candidates outright — better to return null
      // than poison the merchant memory with phrases like
      // "Cc Ordered Successfully Order Id".
      if (_isNoisyMerchant(merchant)) continue;
      final src = (i == 0 || i == 3) ? 'keyword' : 'fallback';
      return (_normalizeMerchant(merchant), src);
    }
    return (null, null);
  }

  /// Normalize merchant name for stable merchant memory keys.
  ///
  /// Strips ONLY legal/corporate suffixes — never semantic identifiers.
  /// "ZOMATO PVT LTD" / "Zomato Pvt. Ltd." / "ZOMATO LIMITED" → "Zomato"
  ///
  /// Preserved (these change merchant identity, not noise):
  ///   - "Payments Bank" — Paytm Payments Bank ≠ Paytm
  ///   - "Online", "Digital", "Internet" — semantic identifiers
  ///   - "Bank", "Services" when not part of a legal suffix
  static final _legalSuffixes = RegExp(
    r'\b(?:pvt\.?|ltd\.?|limited|llp|inc\.?|corp\.?|corporation)\b',
    caseSensitive: false,
  );

  static String _normalizeMerchant(String raw) {
    var cleaned = raw
        .replaceAll(_legalSuffixes, '')
        .replaceAll(_trailingPuncRe, '') // trailing punctuation
        .replaceAll(_whitespaceRe, ' ') // collapse whitespace
        .trim();
    if (cleaned.isEmpty) return raw.trim();
    return cleaned
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w.length == 1
            ? w.toUpperCase()
            : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }

  // ── Method (UPI / Card / Bank) ────────────────────────────────────

  /// Method detection. Single-token signals (`upi`, `vpa`, `neft`, `imps`,
  /// `rtgs`, `cash`) are checked against the precomputed [tokenSet] for
  /// O(1) lookups; multi-token / phrase signals fall back to substring
  /// scan. This avoids 9+ separate `lower.contains()` substring searches
  /// per parse.
  static String? _extractMethod(String lower, Set<String> tokenSet) {
    if (tokenSet.contains('upi') ||
        tokenSet.contains('vpa') ||
        _vpaRe.hasMatch(lower)) {
      return 'upi';
    }
    if (lower.contains('credit card') ||
        lower.contains('debit card') ||
        lower.contains('card ending') ||
        lower.contains('card xx') ||
        _cardSpaceDigitRe.hasMatch(lower)) {
      return 'card';
    }
    if (tokenSet.contains('neft') ||
        tokenSet.contains('imps') ||
        tokenSet.contains('rtgs') ||
        lower.contains('bank transfer')) {
      return 'bank';
    }
    if (tokenSet.contains('cash')) return 'cash';
    return null;
  }

  // ── Reference ID ──────────────────────────────────────────────────

  static final _refPatterns = <RegExp>[
    RegExp(
      r'(?:UPI\s*(?:Ref|Txn)|UTR|Ref(?:erence)?|Txn|Transaction)\s*'
      r'(?:[Nn]o\.?|ID|#|:)?\s*\.?\s*([A-Za-z0-9]{6,})',
      caseSensitive: false,
    ),
  ];

  static String? _extractRefId(String text) {
    for (final p in _refPatterns) {
      final m = p.firstMatch(text);
      if (m != null) return m.group(1);
    }
    return null;
  }

  // ── Account last 4 ────────────────────────────────────────────────

  static final _last4Patterns = <RegExp>[
    RegExp(r'\bx{1,2}(\d{4})\b', caseSensitive: false),
    RegExp(r'\*{2,}(\d{4})\b'),
    RegExp(r'(?:a/c|account)\s*[^\d]{0,8}(\d{4})\b', caseSensitive: false),
  ];

  static String? _extractLast4(String text) {
    for (final p in _last4Patterns) {
      final m = p.firstMatch(text);
      if (m != null) return m.group(1);
    }
    return null;
  }

  // ── Bank name (light hint) ────────────────────────────────────────
  //
  // Pure banking entities ONLY. Payment apps (Amazon Pay, PhonePe, etc.)
  // are merchants in OCR'd payment screenshots — they're handled by the
  // _knownMerchants dictionary above, not as banks. This split prevents
  // the dual-classification bug where a merchant string ended up in both
  // `merchant` and `bankName`.

  static const _bankHints = <String, String>{
    'hdfc': 'HDFC',
    'icici': 'ICICI',
    'sbi': 'SBI',
    'state bank': 'SBI',
    'axis': 'Axis',
    'kotak': 'Kotak',
    'yes bank': 'Yes Bank',
    'indusind': 'IndusInd',
    'federal': 'Federal',
    'rbl': 'RBL',
    'idfc': 'IDFC',
    'jio payments bank': 'Jio',
  };

  static String? _extractBankName(String lower) {
    for (final entry in _bankHints.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return null;
  }
}

/// Cache entry for the parser — wraps a [ParsedTransaction] with the
/// timestamp it was computed at so [TransactionTextParser] can enforce
/// a TTL on reads. Internal-only.
class _CacheEntry {
  final ParsedTransaction data;
  final DateTime cachedAt;
  const _CacheEntry({required this.data, required this.cachedAt});
}

// MerchantPattern + dictionary now live in merchant_normalizer.dart so
// parser, recurring detector, and merchant aggregator share one
// canonical identity layer. Anyone needing MerchantPattern should
// import it from there.
