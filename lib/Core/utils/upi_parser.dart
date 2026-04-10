class UpiParseResult {
  final double amount;
  final bool isCredit;
  final String? vpa;
  final String? merchant;
  final String? refId;

  /// Bank inferred from VPA handle (e.g., @okhdfcbank → HDFC).
  final String? vpaBankHint;

  const UpiParseResult({
    required this.amount,
    required this.isCredit,
    this.vpa,
    this.merchant,
    this.refId,
    this.vpaBankHint,
  });
}

class UpiParser {
  static final _amount = RegExp(
    r'(?:Rs\.?|INR|₹)\s?([\d,]+\.?\d*)',
    caseSensitive: false,
  );
  static final _vpa = RegExp(
    r'([\w.\-]+@[a-zA-Z]{2,})',
    caseSensitive: false,
  );
  static final _ref = RegExp(
    r'(?:ref|txn|utr|upi)\s*(?:no\.?|id|#|:)?\s*[:\s#]?([A-Za-z0-9]{6,})',
    caseSensitive: false,
  );

  // ── Merchant patterns (ordered by specificity) ───────────────────────
  static final _merchantPatterns = [
    RegExp(r'(?:paid to|transferred to)\s+([a-z0-9 .&\-]+)', caseSensitive: false),
    RegExp(r'(?:received from|from)\s+([a-z0-9 .&\-]+?)(?:\s+(?:on|via|ref|upi))', caseSensitive: false),
    RegExp(r'to\s+([a-z0-9 .&\-]+?)(?:\s+(?:on|via|ref|upi|a/c))', caseSensitive: false),
  ];

  // ── VPA handle → bank mapping ────────────────────────────────────────
  // Covers major Indian UPI handles
  static const _vpaHandleToBankMap = <String, String>{
    // HDFC
    'okhdfcbank': 'HDFC',
    'hdfcbank': 'HDFC',
    // SBI
    'oksbi': 'SBI',
    'sbi': 'SBI',
    // ICICI
    'okicici': 'ICICI',
    'icici': 'ICICI',
    // Axis
    'okaxis': 'AXIS',
    'axisbank': 'AXIS',
    'axis': 'AXIS',
    // Kotak
    'kotak': 'KOTAK',
    'kmbl': 'KOTAK',
    // Yes Bank (PhonePe, GPay)
    'ybl': 'YES',
    'yesbankltd': 'YES',
    // Paytm (Axis via Paytm)
    'paytm': 'PAYTM',
    'ptyes': 'PAYTM',
    'pthdfc': 'PAYTM',
    'ptsbi': 'PAYTM',
    'ptaxis': 'PAYTM',
    // Google Pay
    'okbizaxis': 'AXIS',
    // IDFC
    'idfcbank': 'IDFC',
    'idfc': 'IDFC',
    // Bob
    'barodampay': 'BOB',
    'mahb': 'BOB',
    // Federal
    'federal': 'FEDERAL',
    'federalbank': 'FEDERAL',
    // IndusInd
    'indus': 'INDUSIND',
    // RBL
    'rbl': 'RBL',
    // PNB
    'pnb': 'PNB',
    // AU
    'aubank': 'AU',
    // Union
    'uboi': 'UNION',
    'unionbankofindia': 'UNION',
    // Canara
    'cnrb': 'CANARA',
    // DBS (digibank)
    'dbs': 'DBS',
    // IDBI
    'idbi': 'IDBI',
    // Jupiter / CSB
    'jupiteraxis': 'FEDERAL',
    // CRED
    'axl': 'AXIS',
    // Amazon Pay
    'apl': 'AXIS',
    // Slice
    'sliceaxis': 'AXIS',
  };

  /// Extract bank hint from a VPA handle.
  /// e.g., "user@okhdfcbank" → "HDFC"
  static String? bankFromVpa(String? vpa) {
    if (vpa == null || !vpa.contains('@')) return null;
    final handle = vpa.split('@').last.toLowerCase();
    return _vpaHandleToBankMap[handle];
  }

  static UpiParseResult? parse(String body) {
    final lower = body.toLowerCase();
    // Check for UPI/IMPS/NEFT/RTGS signals (not just "upi")
    if (!RegExp(r'(?:upi|imps|neft|rtgs|bhim)', caseSensitive: false)
        .hasMatch(lower)) {
      return null;
    }

    final amountMatch = _amount.firstMatch(body);
    if (amountMatch == null) return null;

    final amount = double.tryParse(amountMatch.group(1)!.replaceAll(',', ''));
    if (amount == null || amount <= 0) return null;

    final isCredit = lower.contains('credited') || lower.contains('received');

    final vpa = _vpa.firstMatch(lower)?.group(1);
    final vpaBankHint = bankFromVpa(vpa);

    // Merchant extraction (multi-pattern)
    String? merchant;
    for (final pattern in _merchantPatterns) {
      final match = pattern.firstMatch(lower);
      if (match != null) {
        merchant = _cleanMerchant(match.group(1)!);
        if (merchant.isNotEmpty) break;
      }
    }

    final ref = _ref.firstMatch(lower)?.group(1);

    return UpiParseResult(
      amount: amount,
      isCredit: isCredit,
      vpa: vpa,
      merchant: merchant,
      refId: ref,
      vpaBankHint: vpaBankHint,
    );
  }

  static String _cleanMerchant(String raw) {
    return raw
        .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
