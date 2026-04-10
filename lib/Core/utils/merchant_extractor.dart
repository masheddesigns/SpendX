class MerchantExtractor {
  static final _stop = {
    'upi', 'txn', 'ref', 'no', 'bank', 'account', 'ac', 'a/c', 'rs', 'inr',
    'debited', 'credited', 'payment', 'from', 'to', 'via', 'has', 'been',
    'your', 'the', 'for', 'with', 'and', 'was', 'you', 'is', 'on', 'of',
    'at', 'by', 'in', 'not', 'card', 'towards', 'amount', 'avl', 'bal',
    'balance', 'available', 'rupees', 'transfer', 'transaction', 'neft',
    'imps', 'rtgs', 'utr', 'info', 'alert', 'dear', 'customer', 'sir',
    'date', 'time', 'aapke', 'apne', 'apna', 'se', 'ka', 'ki', 'ke',
    'hai', 'hua', 'gaya', 'kiya', 'mein', 'number', 'num', 'id', 'request',
    'successfully', 'successful', 'completed', 'processed', 'done',
  };

  // Ordered by specificity — most specific patterns first
  static final _patterns = [
    // "paid to MERCHANT via UPI" / "paid to MERCHANT on DATE"
    RegExp(r'paid\s+to\s+([a-z0-9][a-z0-9 .&\-]{1,40}?)(?:\s+(?:via|on|ref|upi|for|rs|inr)\b)',
        caseSensitive: false),
    // "purchase at MERCHANT" / "swiped at MERCHANT"
    RegExp(r'(?:purchase|swiped|used)\s+at\s+([a-z0-9][a-z0-9 .&\-]{1,40}?)(?:\s+(?:on|for|ref|rs|inr)\b)',
        caseSensitive: false),
    // "transferred to MERCHANT via/on"
    RegExp(r'transferred\s+to\s+([a-z0-9][a-z0-9 .&\-]{1,40}?)(?:\s+(?:on|via|ref|for)\b)',
        caseSensitive: false),
    // "spent on MERCHANT" / "spent at MERCHANT"
    RegExp(r'spent\s+(?:on|at)\s+([a-z0-9][a-z0-9 .&\-]{1,40}?)(?:\s+(?:on|via|ref|for|rs)\b)',
        caseSensitive: false),
    // "towards MERCHANT" (HDFC/ICICI format)
    RegExp(r'towards\s+([a-z0-9][a-z0-9 .&\-]{1,40}?)(?:\s+(?:on|via|ref|for|rs|inr|avl)\b|$)',
        caseSensitive: false),
    // "at MERCHANT on DATE"
    RegExp(r'\bat\s+([a-z0-9][a-z0-9 .&\-]{1,40}?)(?:\s+(?:on\s+\d|for|ref|via)\b)',
        caseSensitive: false),
    // "to MERCHANT on/via" (less specific — last resort for preposition patterns)
    RegExp(r'\bto\s+([a-z0-9][a-z0-9 .&\-]{1,40}?)(?:\s+(?:on\s+\d|via|ref|upi|a/c)\b)',
        caseSensitive: false),
  ];

  /// Extract merchant name from SMS body.
  /// Returns empty string if no merchant found.
  static String extract(String text) {
    final lower = text.toLowerCase();

    // Try pattern-based extraction first
    for (final pattern in _patterns) {
      final match = pattern.firstMatch(lower);
      if (match != null) {
        final candidate = _clean(match.group(1)!);
        if (candidate.isNotEmpty && candidate.length >= 2) {
          return _titleCase(candidate);
        }
      }
    }

    // Fallback: longest non-stop-word token (3+ chars)
    final tokens = lower.split(RegExp(r'[\s,.\-]+'))
      ..removeWhere(
        (token) => token.isEmpty || _stop.contains(token) || token.length < 3,
      );

    tokens.sort((a, b) => b.length.compareTo(a.length));
    if (tokens.isNotEmpty) {
      final fallback = _clean(tokens.first);
      if (fallback.length >= 3) return _titleCase(fallback);
    }
    return '';
  }

  static String _clean(String value) {
    var result = value
        .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Remove trailing stop words
    final words = result.split(' ');
    while (words.isNotEmpty && _stop.contains(words.last)) {
      words.removeLast();
    }
    while (words.isNotEmpty && _stop.contains(words.first)) {
      words.removeAt(0);
    }
    return words.join(' ').trim();
  }

  /// Convert "amazon pay" to "Amazon Pay".
  static String _titleCase(String text) {
    if (text.isEmpty) return text;
    return text.split(' ').map((w) {
      if (w.isEmpty) return w;
      return '${w[0].toUpperCase()}${w.substring(1)}';
    }).join(' ');
  }
}
