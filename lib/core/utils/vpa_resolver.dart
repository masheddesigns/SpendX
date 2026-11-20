import '../../services/merchant_normalizer.dart';

/// Structured outcome of VPA extraction and resolution.
class VpaResolution {
  final String rawVpa;
  final String username;
  final String handle;
  final String? merchantName;
  final String? paymentProcessor;
  String? get aggregator => paymentProcessor;
  final bool isAggregator;
  final bool isNumericOrPhone;
  final bool isAmbiguous;

  const VpaResolution({
    required this.rawVpa,
    required this.username,
    required this.handle,
    this.merchantName,
    this.paymentProcessor,
    this.isAggregator = false,
    this.isNumericOrPhone = false,
    this.isAmbiguous = false,
  });

  @override
  String toString() =>
      'VpaResolution(rawVpa: $rawVpa, merchant: $merchantName, processor: $paymentProcessor, isAggregator: $isAggregator, isNumeric: $isNumericOrPhone, isAmbiguous: $isAmbiguous)';
}

/// Conservative VPA extraction and entity resolution engine.
class VpaResolver {
  VpaResolver._();

  // Known payment gateway / aggregator identifiers
  static const _aggregators = <String, String>{
    'payu': 'PayU',
    'razorpay': 'Razorpay',
    'billdesk': 'BillDesk',
    'ccavenue': 'CCAvenue',
    'juspay': 'Juspay',
    'cashfree': 'Cashfree',
    'atom': 'Atom',
    'pinelabs': 'Pine Labs',
    'worldline': 'Worldline',
    'airpay': 'Airpay',
    'zaakpay': 'Zaakpay',
    'instamojo': 'Instamojo',
    'citrus': 'Citrus',
    'mobikwik': 'Mobikwik',
  };

  // Operational noise suffixes commonly attached to merchant VPAs
  static const _operationalTokens = <String>{
    'order', 'orders', 'delivery', 'txn', 'pay', 'payment', 'payments',
    'care', 'support', 'app', 'store', 'pos', 'bill', 'recharge', 'direct',
    'auto', 'collect', 'desk', 'corp', 'online', 'nodal', 'gateway', 'merchant',
  };

  // Generic personal or web domains that are NOT UPI handles
  static const _nonUpiHandles = <String>{
    'gmail', 'yahoo', 'outlook', 'hotmail', 'icloud', 'proton', 'zoho',
    'com', 'org', 'net', 'in', 'co', 'io', 'gov', 'edu',
  };

  // Regex to extract VPA candidate
  static final RegExp _vpaCandidateRe = RegExp(
    r'\b([a-zA-Z0-9][a-zA-Z0-9.\-_]{1,50}@[a-zA-Z0-9]{2,30})\b',
  );

  // Regex specifically for UPI protocol reference strings
  static final RegExp _upiRefVpaRe = RegExp(
    r'UPI/(?:DR|CR|P2A|P2P|P2M)/\d+/([a-zA-Z0-9.\-_]+(?:@[a-zA-Z0-9]+)?)',
    caseSensitive: false,
  );

  /// Extract and resolve the primary VPA from message text.
  /// Returns null if no valid UPI VPA is found.
  static VpaResolution? resolve(String text) {
    final vpaString = extractRawVpa(text);
    if (vpaString == null) return null;
    return parse(vpaString);
  }

  /// Extracts the raw VPA string from text (if present).
  static String? extractRawVpa(String text) {
    // 1. Try structured UPI reference first (e.g. UPI/DR/12345/swiggy@icici)
    final upiRefMatch = _upiRefVpaRe.firstMatch(text);
    if (upiRefMatch != null) {
      final candidate = upiRefMatch.group(1)!.trim();
      if (candidate.contains('@')) {
        final parts = candidate.split('@');
        if (parts.length == 2 && !_nonUpiHandles.contains(parts[1].toLowerCase())) {
          return candidate;
        }
      }
    }

    // 2. Scan for email-like VPA candidates
    for (final match in _vpaCandidateRe.allMatches(text)) {
      final candidate = match.group(1)!.trim();
      final parts = candidate.split('@');
      if (parts.length != 2) continue;
      final handle = parts[1].toLowerCase();
      if (_nonUpiHandles.contains(handle)) continue;
      // Filter out domain names like test@example.com
      if (handle.contains('.')) continue;

      return candidate;
    }
    return null;
  }

  /// Parses and disambiguates a known VPA string into its components.
  static VpaResolution parse(String vpa) {
    final parts = vpa.split('@');
    if (parts.length != 2) {
      return VpaResolution(
        rawVpa: vpa,
        username: vpa,
        handle: '',
        isAmbiguous: true,
      );
    }

    final rawUsername = parts[0];
    final handle = parts[1].toLowerCase();
    final lowerUser = rawUsername.toLowerCase();

    // 1. Check if username is purely numeric (mobile number or account ID)
    final isPhoneOrNumeric = RegExp(r'^\+?\d{8,12}$').hasMatch(lowerUser);
    if (isPhoneOrNumeric) {
      // CONSERVATIVE: A numeric VPA does not establish a merchant, nor does it guarantee a person.
      return VpaResolution(
        rawVpa: vpa,
        username: rawUsername,
        handle: handle,
        merchantName: null,
        isNumericOrPhone: true,
        isAmbiguous: true,
      );
    }

    // 2. Check for payment processor / aggregator segment (e.g. uber.payu, netflix.billdesk, swiggy.razorpay)
    // Split user by delimiters: dot, hyphen, underscore
    final segments = lowerUser.split(RegExp(r'[.\-_]')).where((s) => s.isNotEmpty).toList();

    String? detectedProcessor;
    bool isAggregator = false;
    final merchantCandidateTokens = <String>[];

    for (final seg in segments) {
      if (_aggregators.containsKey(seg)) {
        detectedProcessor = _aggregators[seg];
        isAggregator = true;
      } else if (!_operationalTokens.contains(seg)) {
        merchantCandidateTokens.add(seg);
      }
    }

    // If the username only contained the aggregator itself (e.g. payu@icici or razorpay@yesbank)
    if (merchantCandidateTokens.isEmpty && isAggregator) {
      return VpaResolution(
        rawVpa: vpa,
        username: rawUsername,
        handle: handle,
        merchantName: null, // CONSERVATIVE: Do not name PayU as merchant
        paymentProcessor: detectedProcessor,
        isAggregator: true,
        isAmbiguous: true,
      );
    }

    // 3. Evaluate merchant candidate token
    final candidateName = merchantCandidateTokens.join(' ');
    if (candidateName.isNotEmpty) {
      // Check against MerchantNormalizer canonical dictionary
      final canonical = MerchantNormalizer.lookupCanonical(candidateName);
      if (canonical != null) {
        return VpaResolution(
          rawVpa: vpa,
          username: rawUsername,
          handle: handle,
          merchantName: canonical,
          paymentProcessor: detectedProcessor,
          isAggregator: isAggregator,
          isAmbiguous: false,
        );
      }

      // Check single token matches in dictionary
      for (final token in merchantCandidateTokens) {
        final tokenCanonical = MerchantNormalizer.lookupCanonical(token);
        if (tokenCanonical != null) {
          return VpaResolution(
            rawVpa: vpa,
            username: rawUsername,
            handle: handle,
            merchantName: tokenCanonical,
            paymentProcessor: detectedProcessor,
            isAggregator: isAggregator,
            isAmbiguous: false,
          );
        }
      }
    }

    // 4. Ambiguous / Personal VPA candidate (e.g. rahul.kumar@okaxis, priya99@sbi)
    // CONSERVATIVE RULE: Do not automatically convert every VPA or personal-looking name into a merchant or personal transfer.
    return VpaResolution(
      rawVpa: vpa,
      username: rawUsername,
      handle: handle,
      merchantName: null,
      paymentProcessor: detectedProcessor,
      isAggregator: isAggregator,
      isAmbiguous: true,
    );
  }
}
