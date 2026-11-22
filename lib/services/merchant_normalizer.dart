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
    MerchantPattern(canonical: 'Paytm', aliases: ['paytm', 'one97', 'one97 communications']),
    MerchantPattern(canonical: 'CRED', aliases: ['cred', 'dreamplug', 'dreamplug technologies', 'cred club', 'credclub']),
    MerchantPattern(canonical: 'Cheq', aliases: ['cheq', 'cheq app']),
    MerchantPattern(canonical: 'Jupiter', aliases: ['jupiter', 'jupiter edge', 'jtedge']),
    MerchantPattern(canonical: 'Scapia', aliases: ['scapia', 'scapia federal']),
    MerchantPattern(canonical: 'Kiwi', aliases: ['kiwi', 'kiwi axis']),
    MerchantPattern(canonical: 'Tata Neu', aliases: ['tata neu', 'tataneu']),
    MerchantPattern(canonical: 'Tata CLiQ', aliases: ['tata cliq', 'tatacliq', 'tata unistore', 'tataunistore', 'tata unistore ltd', 'mycliq']),
    MerchantPattern(canonical: 'Freecharge', aliases: ['freecharge']),
    MerchantPattern(canonical: 'Mobikwik', aliases: ['mobikwik']),
    MerchantPattern(canonical: 'PolicyBazaar', aliases: ['policybazaar', 'policy bazaar', 'polbaz', 'policybazaar insurance']),
    MerchantPattern(canonical: 'District Movies', aliases: ['district', 'districtmovies', 'district movies', 'districtmovies gurgoan', 'dstrkt']),
    MerchantPattern(canonical: 'VVM Food Chain', aliases: ['vvm food chain', 'vvm food chain llp']),
    MerchantPattern(canonical: 'City Fuel Station', aliases: ['city fuel st', 'city fuel station', 'city fuel']),
    MerchantPattern(canonical: 'Muddy Paws', aliases: ['muddy paws', 'muddypaws']),
    MerchantPattern(canonical: 'Air Arabia', aliases: ['air arabia', 'air arabia auh', 'airarabia']),
    MerchantPattern(canonical: 'OneCard', aliases: ['onecard', 'one card', 'bobone', 'bobcard onecard']),
    MerchantPattern(canonical: 'Bharat BillPay', aliases: ['bbps', 'bharat billpay', 'bharat bill pay']),
    MerchantPattern(canonical: 'BillDesk', aliases: ['billdesk', 'bill desk']),
    MerchantPattern(canonical: 'PayZapp', aliases: ['payzapp', 'pz hdfc']),
    MerchantPattern(canonical: 'Super.money', aliases: ['supermoney', 'super money', 'super.money', 'supercard']),
    MerchantPattern(canonical: 'Slice', aliases: ['slice', 'sliceit', 'slice pay']),
    MerchantPattern(canonical: 'Uni', aliases: ['uni card', 'unicard', 'uni pay']),
    MerchantPattern(canonical: 'Park+', aliases: ['park plus', 'parkplus', 'park fastag', 'myparkplus', 'parviom systems']),
    MerchantPattern(canonical: 'FASTag', aliases: ['fastag', 'netc fastag', 'nhai fastag', 'toll plaza']),

    // Food delivery & Quick-commerce
    MerchantPattern(canonical: 'Swiggy', aliases: ['swiggy', 'bundl technologies', 'bundl tech', 'swiggy instamart', 'swiggy xl']),
    MerchantPattern(canonical: 'Zomato', aliases: ['zomato', 'zomato media', 'eternal limited', 'zomato gold']),
    MerchantPattern(canonical: 'Blinkit', aliases: ['blinkit', 'blink commerce', 'grofers']),
    MerchantPattern(canonical: 'Zepto', aliases: ['zepto', 'kiranakart', 'kiranakart technologies']),
    MerchantPattern(canonical: 'Instamart', aliases: ['instamart']),
    MerchantPattern(canonical: 'BigBasket', aliases: ['bigbasket', 'big basket', 'supermarket grocery', 'supermarket grocery supplies', 'bb daily', 'bbdaily']),
    MerchantPattern(canonical: 'Dunzo', aliases: ['dunzo']),

    // E-commerce & Retail
    MerchantPattern(canonical: 'Flipkart', aliases: ['flipkart', 'flipkart internet', 'fkrt']),
    MerchantPattern(canonical: 'Amazon', aliases: ['amazon', 'amazon seller', 'amazon retail', 'amzn']),
    MerchantPattern(canonical: 'Myntra', aliases: ['myntra', 'myntra designs']),
    MerchantPattern(canonical: 'Meesho', aliases: ['meesho']),
    MerchantPattern(canonical: 'Ajio', aliases: ['ajio']),
    MerchantPattern(canonical: 'Nykaa', aliases: ['nykaa', 'fsn e commerce', 'fsn ecommerce', 'nykaa e retail']),
    MerchantPattern(canonical: 'Decathlon', aliases: ['decathlon', 'decathlon sports']),
    MerchantPattern(canonical: 'Zudio', aliases: ['zudio', 'trent limited']),
    MerchantPattern(canonical: 'Westside', aliases: ['westside']),
    MerchantPattern(canonical: 'Urban Company', aliases: ['urban company', 'urban clap', 'urbanclap', 'urbanclap technologies']),

    // Healthcare & Pharmacy
    MerchantPattern(canonical: 'PharmEasy', aliases: ['pharmeasy', 'api holdings']),
    MerchantPattern(canonical: 'Apollo Pharmacy', aliases: ['apollo pharmacy', 'apollo hospitals', 'apollo 247']),
    MerchantPattern(canonical: '1mg', aliases: ['1mg', 'tata 1mg', '1mg technologies']),
    MerchantPattern(canonical: 'Lenskart', aliases: ['lenskart', 'lenskart solutions']),

    // Telecom & Utilities
    MerchantPattern(canonical: 'Airtel', aliases: ['airtel', 'bharti airtel', 'airtel payments bank', 'airtel digital']),
    MerchantPattern(canonical: 'Jio', aliases: ['reliance jio', 'jio infocomm', 'jiomart', 'jio recharge']),
    MerchantPattern(canonical: 'Vi', aliases: ['vodafone idea', 'vi recharge', 'vi postpaid']),

    // Broking & Investments
    MerchantPattern(canonical: 'Zerodha', aliases: ['zerodha', 'zerodha broking']),
    MerchantPattern(canonical: 'Groww', aliases: ['groww', 'nextbillion technology']),
    MerchantPattern(canonical: 'Angel One', aliases: ['angel one', 'angel broking']),
    MerchantPattern(canonical: 'Upstox', aliases: ['upstox', 'rksv securities']),

    // Travel & Airlines
    MerchantPattern(canonical: 'Air Arabia', aliases: ['air arabia', 'air arabia auh', 'airarabia']),
    MerchantPattern(canonical: 'IndiGo', aliases: ['indigo', 'indigo airlines']),
    MerchantPattern(canonical: 'Air India', aliases: ['air india', 'airindia']),
    MerchantPattern(canonical: 'Emirates', aliases: ['emirates']),
    MerchantPattern(canonical: 'Uber', aliases: ['uber', 'uber india', 'uber b v', 'uber trip']),
    MerchantPattern(canonical: 'Ola', aliases: ['ola', 'ani technologies', 'ola cabs', 'ola electric']),
    MerchantPattern(canonical: 'Rapido', aliases: ['rapido']),
    MerchantPattern(canonical: 'IRCTC', aliases: ['irctc', 'indian railway', 'irctc app', 'irctc web']),
    MerchantPattern(canonical: 'BookMyShow', aliases: ['bookmyshow', 'book my show', 'bigtree entertainment']),
    MerchantPattern(canonical: 'PVR INOX', aliases: ['pvr', 'pvr inox', 'inox', 'pvr cinemas', 'inox leisure']),
    MerchantPattern(canonical: 'MakeMyTrip', aliases: ['makemytrip', 'make my trip']),
    MerchantPattern(canonical: 'Goibibo', aliases: ['goibibo']),

    // Subscriptions
    MerchantPattern(canonical: 'Netflix', aliases: ['netflix']),
    MerchantPattern(canonical: 'Spotify', aliases: ['spotify']),
    MerchantPattern(canonical: 'Hotstar', aliases: ['hotstar']),
    MerchantPattern(canonical: 'YouTube', aliases: ['youtube', 'youtube cybs si', 'youtube cybs', 'google youtube']),

    // Fuel & Petrol Pumps
    MerchantPattern(canonical: 'Indian Oil', aliases: ['indian oil', 'indianoil', 'iocl', 'indian oil corporation']),
    MerchantPattern(canonical: 'Bharat Petroleum', aliases: ['bharat petroleum', 'bpcl']),
    MerchantPattern(canonical: 'Hindustan Petroleum', aliases: ['hindustan petroleum', 'hpcl']),
    MerchantPattern(canonical: 'Shell', aliases: ['shell petrol', 'shell india']),
    MerchantPattern(canonical: 'Nayara Energy', aliases: ['nayara', 'nayara energy']),
    MerchantPattern(canonical: 'Jio-bp', aliases: ['jio-bp', 'jio bp']),

    // EV Charging Networks
    MerchantPattern(canonical: 'Statiq', aliases: ['statiq', 'sharify services']),
    MerchantPattern(canonical: 'Ather Grid', aliases: ['ather grid', 'ather energy']),
    MerchantPattern(canonical: 'Zeon Charging', aliases: ['zeon charging', 'zeon electric']),
    MerchantPattern(canonical: 'Bolt.earth', aliases: ['bolt earth', 'bolt.earth']),

    // Transit & Mobility
    MerchantPattern(canonical: 'Namma Yatri', aliases: ['namma yatri', 'nammayatri', 'moving tech innovations', 'moving tech']),
    MerchantPattern(canonical: 'BluSmart', aliases: ['blusmart', 'blusmart mobility']),
    MerchantPattern(canonical: 'InDrive', aliases: ['indrive', 'in driver', 'indriver']),
    MerchantPattern(canonical: 'Chalo', aliases: ['chalo', 'chalo card']),
    MerchantPattern(canonical: 'RedBus', aliases: ['redbus', 'red bus', 'ibibo group']),
    MerchantPattern(canonical: 'AbhiBus', aliases: ['abhibus', 'abhi bus']),
    MerchantPattern(canonical: 'Metro Rail', aliases: ['dmrc', 'bmrc', 'bmrcl', 'cmrl', 'mmrcl', 'delhi metro', 'bangalore metro', 'namma metro', 'mumbai metro', 'chennai metro', 'kochi metro']),

    // QSR & Dining
    MerchantPattern(canonical: 'Starbucks', aliases: ['starbucks']),
    MerchantPattern(canonical: 'Dominos', aliases: ['dominos', 'domino s']),
    MerchantPattern(canonical: 'McDonalds', aliases: ['mcdonalds', 'mcdonald s']),
    MerchantPattern(canonical: 'KFC', aliases: ['kfc']),
    MerchantPattern(canonical: 'Pizza Hut', aliases: ['pizza hut', 'yum brands', 'devyani international']),
    MerchantPattern(canonical: 'Burger King', aliases: ['burger king', 'restaurant brands asia']),
    MerchantPattern(canonical: 'Subway', aliases: ['subway']),
    MerchantPattern(canonical: 'EatSure', aliases: ['eatsure', 'rebel foods', 'faasos', 'behrouz biryani', 'behrouz', 'ovenstory', 'oven story', 'wendys']),
    MerchantPattern(canonical: 'Box8', aliases: ['box8', 'poncho hospitality', 'mojo pizza']),
    MerchantPattern(canonical: 'FreshMenu', aliases: ['freshmenu', 'fresh menu']),
    MerchantPattern(canonical: 'Chai Point', aliases: ['chai point', 'mountain trail foods']),
    MerchantPattern(canonical: 'Chaayos', aliases: ['chaayos', 'sunshine teahouse']),
    MerchantPattern(canonical: 'Third Wave Coffee', aliases: ['third wave coffee', 'third wave', 'heisetasse']),
    MerchantPattern(canonical: 'Blue Tokai', aliases: ['blue tokai', 'blue tokai coffee']),
    MerchantPattern(canonical: 'Haldiram', aliases: ['haldiram', 'haldirams']),
    MerchantPattern(canonical: 'Barbeque Nation', aliases: ['barbeque nation', 'bbq nation']),
    MerchantPattern(canonical: 'Bikanervala', aliases: ['bikanervala', 'bikano']),
    MerchantPattern(canonical: 'Adyar Ananda Bhavan', aliases: ['adyar ananda bhavan', 'a2b']),
    MerchantPattern(canonical: 'Saravana Bhavan', aliases: ['saravana bhavan']),
    MerchantPattern(canonical: 'Anjappar', aliases: ['anjappar']),
    MerchantPattern(canonical: 'Wow Momo', aliases: ['wow momo', 'wow china']),

    // Grocery, Dairy & Daily Essentials
    MerchantPattern(canonical: 'Country Delight', aliases: ['country delight', 'countrydelight', 'beejapuri']),
    MerchantPattern(canonical: 'Licious', aliases: ['licious', 'delightful gourmet']),
    MerchantPattern(canonical: 'FreshToHome', aliases: ['freshtohome', 'fresh to home']),
    MerchantPattern(canonical: 'DMart', aliases: ['dmart', 'd mart', 'avenue supermarts']),
    MerchantPattern(canonical: 'Reliance Smart', aliases: ['reliance smart', 'smart bazaar', 'reliance fresh']),
    MerchantPattern(canonical: 'More Retail', aliases: ['more retail', 'more supermarket', 'more megastore']),
    MerchantPattern(canonical: 'Spencer\'s', aliases: ['spencers', 'spencer s']),
    MerchantPattern(canonical: 'Nature\'s Basket', aliases: ['nature basket', 'natures basket']),
    MerchantPattern(canonical: 'Mother Dairy', aliases: ['mother dairy']),
    MerchantPattern(canonical: 'Amul', aliases: ['amul', 'gcmmf']),
    MerchantPattern(canonical: 'Otipy', aliases: ['otipy', 'crofarm']),

    // Fashion, Home & Electronics Retail
    MerchantPattern(canonical: 'Croma', aliases: ['croma', 'infiniti retail']),
    MerchantPattern(canonical: 'Reliance Digital', aliases: ['reliance digital', 'rel digital']),
    MerchantPattern(canonical: 'Vijay Sales', aliases: ['vijay sales']),
    MerchantPattern(canonical: 'Ikea', aliases: ['ikea', 'ikea india']),
    MerchantPattern(canonical: 'Pepperfry', aliases: ['pepperfry']),
    MerchantPattern(canonical: 'Urban Ladder', aliases: ['urban ladder']),
    MerchantPattern(canonical: 'Wakefit', aliases: ['wakefit', 'wakefit innovations']),
    MerchantPattern(canonical: 'SleepyCat', aliases: ['sleepycat', 'sleepy cat']),
    MerchantPattern(canonical: 'Pantaloons', aliases: ['pantaloons', 'aditya birla fashion', 'abfrl']),
    MerchantPattern(canonical: 'Shoppers Stop', aliases: ['shoppers stop']),
    MerchantPattern(canonical: 'Lifestyle', aliases: ['lifestyle', 'landmark group']),
    MerchantPattern(canonical: 'Max Fashion', aliases: ['max fashion']),
    MerchantPattern(canonical: 'H&M', aliases: ['h&m', 'h and m', 'hennes mauritz']),
    MerchantPattern(canonical: 'Zara', aliases: ['zara', 'inditex']),
    MerchantPattern(canonical: 'Uniqlo', aliases: ['uniqlo']),
    MerchantPattern(canonical: 'The Souled Store', aliases: ['the souled store', 'souled store']),
    MerchantPattern(canonical: 'Snitch', aliases: ['snitch']),
    MerchantPattern(canonical: 'Bewakoof', aliases: ['bewakoof']),
    MerchantPattern(canonical: 'Bata', aliases: ['bata', 'bata india']),

    // Streaming, Gaming & Entertainment
    MerchantPattern(canonical: 'SonyLIV', aliases: ['sonyliv', 'sony liv', 'culver max']),
    MerchantPattern(canonical: 'JioCinema', aliases: ['jiocinema', 'jio cinema', 'viacom18']),
    MerchantPattern(canonical: 'Zee5', aliases: ['zee5', 'zee entertainment']),
    MerchantPattern(canonical: 'Apple Services', aliases: ['apple services', 'itunes', 'apple.com/bill']),
    MerchantPattern(canonical: 'Google Play', aliases: ['google play', 'google *play']),
    MerchantPattern(canonical: 'PlayStation', aliases: ['playstation', 'playstation network', 'sony interactive']),
    MerchantPattern(canonical: 'Steam', aliases: ['steam games', 'steampowered']),

    // Broadband, DTH & Utilities
    MerchantPattern(canonical: 'Tata Play', aliases: ['tata play', 'tata sky']),
    MerchantPattern(canonical: 'Dish TV', aliases: ['dish tv', 'dishtv']),
    MerchantPattern(canonical: 'Sun Direct', aliases: ['sun direct']),
    MerchantPattern(canonical: 'ACT Fibernet', aliases: ['act fibernet', 'act broadband', 'atria convergence']),
    MerchantPattern(canonical: 'Hathway', aliases: ['hathway']),
    MerchantPattern(canonical: 'Asianet Broadband', aliases: ['asianet broadband', 'asianet cable']),
    MerchantPattern(canonical: 'Excitel', aliases: ['excitel']),
    MerchantPattern(canonical: 'Tata Power', aliases: ['tata power', 'tata power ez charge']),
    MerchantPattern(canonical: 'BESCOM', aliases: ['bescom']),
    MerchantPattern(canonical: 'MSEDCL', aliases: ['msedcl', 'mahadiscom', 'mseb']),
    MerchantPattern(canonical: 'TNEB', aliases: ['tneb', 'tangedco']),
    MerchantPattern(canonical: 'KSEB', aliases: ['kseb']),
    MerchantPattern(canonical: 'CESC', aliases: ['cesc']),
    MerchantPattern(canonical: 'Adani Electricity', aliases: ['adani electricity', 'adani power']),
    MerchantPattern(canonical: 'Torrent Power', aliases: ['torrent power']),
    MerchantPattern(canonical: 'Indane', aliases: ['indane', 'indane gas']),
    MerchantPattern(canonical: 'Bharat Gas', aliases: ['bharat gas']),
    MerchantPattern(canonical: 'HP Gas', aliases: ['hp gas']),
    MerchantPattern(canonical: 'IGL', aliases: ['indraprastha gas', 'igl']),
    MerchantPattern(canonical: 'MGL', aliases: ['mahanagar gas', 'mgl']),

    // ATM & Cash
    MerchantPattern(canonical: 'ATM Cash Withdrawal', aliases: [
      'atm cash withdrawal',
      'atm withdrawal',
      'cash withdrawal',
      'atm cash wdl',
      'cash wdl',
      'nfs atm',
      'state bank atm',
      'sbi atm',
      'hdfc atm',
      'icici atm',
      'axis atm',
      'kotak atm',
      'canara atm',
      'bob atm',
      'pnb atm',
    ]),
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
