class TextFormatter {
  static final Map<String, String> _cache = {};

  static String toTitleCase(String input) {
    return input
        .trim()
        .split(' ')
        .map(
          (word) => word.isEmpty
              ? word
              : word[0].toUpperCase() + word.substring(1).toLowerCase(),
        )
        .join(' ');
  }

  static const Map<String, String> smartWords = {
    'upi': 'UPI',
    'emi': 'EMI',
    'gst': 'GST',
    'idfc': 'IDFC',
    'hdfc': 'HDFC',
    'icici': 'ICICI',
    'sbi': 'SBI',
    'axis': 'Axis', // Example of Title Case preservation
  };

  static const lowerCaseWords = ['of', 'and', 'to', 'for', 'in'];

  /// Converts a string to Smart Title Case (e.g., "emi payment to idfc bank" -> "EMI Payment To IDFC Bank")
  static String toSmartTitleCase(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return input;

    // Check cache
    if (_cache.containsKey(trimmed)) return _cache[trimmed]!;

    // Normalize multiple spaces to single space
    final normalized = trimmed.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final words = normalized.split(' ');

    final formatted = words
        .asMap()
        .entries
        .map((entry) {
          final index = entry.key;
          final word = entry.value;

          if (word.isEmpty) return '';

          // Handle smart words (acronyms or specific casing)
          if (smartWords.containsKey(word)) {
            return smartWords[word]!;
          }

          // Handle lowercase exceptions (Only if not first word)
          if (index > 0 && lowerCaseWords.contains(word)) {
            return word;
          }

          // Standard capitalization
          return word[0].toUpperCase() + word.substring(1);
        })
        .join(' ');

    // Store in cache
    _cache[trimmed] = formatted;
    return formatted;
  }

  /// Normalizes a name for storage
  static String normalizeName(String input) {
    return toSmartTitleCase(toTitleCase(input));
  }
}
