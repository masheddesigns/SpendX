/// Production-grade merchant normalization engine.
///
/// Converts raw merchant strings from SMS into clean, canonical names.
/// "AMAZON PAY INDIA PVT LTD" → "Amazon"
/// "LE TRAVENUES TE" → "Le Travenues (MakeMyTrip)"
/// "ZOMATO ORDER 12345" → "Zomato"
class MerchantNormalizer {
  MerchantNormalizer._();

  /// Noise words to strip from merchant names.
  static final _noiseWords = RegExp(
    r'\b(?:pvt|ltd|private|limited|india|llp|inc|corp|'
    r'international|solutions|services|technologies|tech|'
    r'enterprises|consulting|holdings|group|co\.?|'
    r'online|digital|pay(?:ments?)?|platform|app|'
    r'upi|neft|imps|rtgs|via|ref|txn|transaction|'
    r'order\s*#?\d+|inv\s*#?\d+|bill\s*#?\d+|'
    r'[0-9]{6,})\b',
    caseSensitive: false,
  );

  /// Known merchant aliases → canonical name.
  static const _aliasMap = {
    // Food & Delivery
    'zomato': 'Zomato',
    'swiggy': 'Swiggy',
    'dominos': "Domino's",
    'mcdonalds': "McDonald's",
    'mcdonald': "McDonald's",
    'kfc': 'KFC',
    'subway': 'Subway',
    'burger king': 'Burger King',
    'pizza hut': 'Pizza Hut',
    'starbucks': 'Starbucks',
    'dunkin': "Dunkin'",
    'blinkit': 'Blinkit',
    'zepto': 'Zepto',
    'instamart': 'Swiggy Instamart',
    'bigbasket': 'BigBasket',
    'jiomart': 'JioMart',
    'dmart': 'DMart',

    // Transport
    'uber': 'Uber',
    'ola': 'Ola',
    'rapido': 'Rapido',
    'irctc': 'IRCTC',
    'le travenues': 'MakeMyTrip',
    'makemytrip': 'MakeMyTrip',
    'cleartrip': 'Cleartrip',
    'goibibo': 'Goibibo',
    'yatra': 'Yatra',
    'ixigo': 'ixigo',
    'redbus': 'redBus',
    'nhai': 'NHAI Toll',
    'fastag': 'FASTag',

    // Shopping
    'amazon': 'Amazon',
    'amzn': 'Amazon',
    'flipkart': 'Flipkart',
    'myntra': 'Myntra',
    'ajio': 'AJIO',
    'meesho': 'Meesho',
    'nykaa': 'Nykaa',
    'tata cliq': 'Tata CLiQ',
    'snapdeal': 'Snapdeal',
    'croma': 'Croma',
    'reliance digital': 'Reliance Digital',
    'vijay sales': 'Vijay Sales',

    // Subscriptions
    'netflix': 'Netflix',
    'spotify': 'Spotify',
    'hotstar': 'Disney+ Hotstar',
    'disney': 'Disney+ Hotstar',
    'youtube': 'YouTube Premium',
    'google play': 'Google Play',
    'apple': 'Apple',
    'icloud': 'iCloud',
    'zee5': 'ZEE5',
    'sonyliv': 'SonyLIV',
    'jiocinema': 'JioCinema',
    'amazon prime': 'Amazon Prime',

    // Bills & Utilities
    'bescom': 'BESCOM',
    'mseb': 'MSEB',
    'tneb': 'TNEB',
    'kseb': 'KSEB',
    'tata power': 'Tata Power',
    'adani gas': 'Adani Gas',
    'mahanagar gas': 'Mahanagar Gas',
    'indane': 'Indane Gas',
    'hpcl': 'HPCL',
    'bpcl': 'BPCL',
    'iocl': 'IOCL',

    // Payments & Wallets
    'phonepe': 'PhonePe',
    'paytm': 'Paytm',
    'google pay': 'Google Pay',
    'gpay': 'Google Pay',
    'cred': 'CRED',
    'bhim': 'BHIM',

    // Grocery
    'spencer': "Spencer's",
    'nature basket': 'Nature Basket',
    'star bazaar': 'Star Bazaar',
    'reliance fresh': 'Reliance Fresh',
    'more retail': 'More',
  };

  /// Normalize a raw merchant string into a clean canonical name.
  static String normalize(String raw) {
    if (raw.isEmpty) return raw;

    var cleaned = raw.trim();

    // Step 1: Try alias match (fastest path)
    final lower = cleaned.toLowerCase();
    for (final entry in _aliasMap.entries) {
      if (lower.contains(entry.key)) {
        return entry.value;
      }
    }

    // Step 2: Remove noise words
    cleaned = cleaned.replaceAll(_noiseWords, ' ');

    // Step 3: Clean up artifacts
    cleaned = cleaned
        .replaceAll(RegExp(r'[*_\-]+'), ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();

    // Step 4: Title case
    if (cleaned.isEmpty) return raw.trim();
    return _titleCase(cleaned);
  }

  static String _titleCase(String text) {
    return text.split(' ').where((w) => w.isNotEmpty).map((w) {
      if (w.length <= 2) return w.toUpperCase(); // "TE" stays "TE"
      return '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}';
    }).join(' ');
  }
}
