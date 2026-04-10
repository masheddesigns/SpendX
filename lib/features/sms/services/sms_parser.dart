import '../models/parsed_sms.dart';
import '../../../core/utils/upi_parser.dart';
import '../../../core/utils/merchant_extractor.dart';
import '../../../core/utils/merchant_normalizer.dart';

/// Production-grade SMS parsing engine for Indian banking messages.
///
/// Architecture: 3-pass pipeline
///   Pass 1: CLASSIFY — debit / credit / bill / upcoming / ignore
///   Pass 2: EXTRACT  — amount, date, merchant, account, reference
///   Pass 3: ENRICH   — bank detection, UPI details, confidence scoring
///
/// Supports 60+ banks/fintechs with extensible pattern registry.
class SmsParser {
  // =====================================================================
  // PASS 1: MESSAGE CLASSIFICATION
  // =====================================================================

  /// Messages that should NEVER become transactions.
  static final _ignorePatterns = [
    // OTP / verification
    RegExp(r'\bOTP\b.*\b(?:is|:)\s*\d{4,}', caseSensitive: false),
    RegExp(r'\bOTP\b.*\bvalid\s+(?:for|till)', caseSensitive: false),
    RegExp(r'(?:verification|verify)\s+code', caseSensitive: false),
    RegExp(r'\bPIN\b.*\bgenerat', caseSensitive: false),
    RegExp(r'\bMPIN\b', caseSensitive: false),
    // Pure promotional
    RegExp(r'(?:apply\s+now|upgrade\s+(?:your|now)|pre[\s.-]?approved\s+loan|'
        r'limit\s+increased|congratulations|win\s+(?:up\s+to|a\s+)|exciting\s+offer|'
        r'cashback\s+up\s+to|get\s+(?:up\s+to|instant)|special\s+offer)',
        caseSensitive: false),
    // Balance inquiry only (no transaction)
    RegExp(r'^(?:your\s+)?(?:a/c|account)\s+.*\bbal(?:ance)?\s+(?:is|:)',
        caseSensitive: false),
    // Service alerts (no amount context)
    RegExp(r'(?:password\s+changed|profile\s+updated|login\s+(?:from|detected)|'
        r'card\s+(?:activated|blocked|dispatched)|linked\s+successfully)',
        caseSensitive: false),
  ];

  /// Messages that are informational but NOT actual transactions.
  static final _billPatterns = [
    RegExp(r'(?:bill\s+(?:generated|ready|available|of\s+Rs)|statement\s+(?:is\s+)?(?:ready|generated|available))',
        caseSensitive: false),
    RegExp(r'(?:minimum\s+(?:amount\s+)?due|total\s+(?:amount\s+)?due\s+(?:is|:)|payment\s+due\s+(?:date|by))',
        caseSensitive: false),
  ];

  /// Messages about FUTURE transactions (not yet debited).
  static final _upcomingPatterns = [
    RegExp(r'(?:upcoming\s+(?:debit|payment|emi|charge)|will\s+be\s+(?:debited|charged)\s+on)',
        caseSensitive: false),
    RegExp(r'(?:e[\s.-]?mandate\s+(?:is\s+)?(?:set|registered)|auto[\s.-]?pay\s+(?:set|scheduled))',
        caseSensitive: false),
    RegExp(r'(?:scheduled\s+(?:for|on)|(?:payment|debit)\s+scheduled)',
        caseSensitive: false),
    RegExp(r'reminder\s*:?\s*(?:your|pay)', caseSensitive: false),
  ];

  // =====================================================================
  // PASS 2: FIELD EXTRACTION
  // =====================================================================

  // ── Amount (3 tiers: contextual → positional → general) ────────────
  static final _amountPatterns = [
    // Tier 1: Amount with clear action context
    // "Rs.500 debited" / "debited by Rs.500" / "Rs 9,535.00 spent"
    RegExp(
      r'(?:INR|Rs\.?|₹|Rupees?)\s?([0-9,]+(?:\.\d{1,2})?)\s*'
      r'(?:has\s+been\s+|was\s+|is\s+)?'
      r'(?:debited|credited|spent|paid|received|charged|deducted|withdrawn|deposited|sent)',
      caseSensitive: false,
    ),
    RegExp(
      r'(?:debited|credited|spent|paid|received|charged|deducted|withdrawn|deposited|sent)'
      r'[^0-9]{0,30}?(?:INR|Rs\.?|₹|Rupees?)\s?([0-9,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    ),
    // Tier 2: "of Rs.500" / "for Rs.500" / "with Rs.500"
    RegExp(
      r'(?:of|for|with|amount)\s+(?:INR|Rs\.?|₹|Rupees?)\s?([0-9,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    ),
    // Tier 3: "Txn of INR 625" / "Payment of Rs 4,500"
    RegExp(
      r'(?:Txn|Transaction|Payment|Transfer)\s+(?:of\s+)?(?:INR|Rs\.?|₹)\s?([0-9,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    ),
    // Tier 4: General fallback — any Rs/INR/₹ amount
    RegExp(
      r'(?:INR|Rs\.?|₹|Rupees?)\s?([0-9,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    ),
    // Tier 5: Global currencies — USD, EUR, GBP, AED, SGD
    RegExp(
      r'(?:USD|US\$|\$|EUR|€|GBP|£|AED|SGD|S\$|JPY|¥|CAD|C\$|AUD|A\$)'
      r'\s?([0-9,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    ),
    // European format: €45,00 (comma as decimal)
    RegExp(
      r'(?:EUR|€)\s?([0-9.]+,\d{2})',
      caseSensitive: false,
    ),
  ];

  // ── Date extraction (from SMS body) ────────────────────────────────
  static final _datePatterns = [
    // 21-Feb-26, 12-Mar-2026, 4 Jul 26
    RegExp(r'(\d{1,2})[\s/-]([A-Za-z]{3})[\s/-](\d{2,4})', caseSensitive: false),
    // 2026-02-21 (ISO — most reliable)
    RegExp(r'(\d{4})-(\d{2})-(\d{2})'),
    // DD/MM/YY or DD/MM/YYYY — only match with / separator (avoid time confusion)
    RegExp(r'\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b'),
  ];

  static const _monthMap = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  // ── Direction keywords ─────────────────────────────────────────────
  static final _debitSignals = RegExp(
    r'(?:debited|spent|paid|purchase|payment\s+(?:of|for)|sent|withdrawn|deducted|'
    r'swiped|charged|auto[\s.-]?debit|mandate|(?<!\w)emi(?!\w)|neft|rtgs|imps|'
    r'\bdr\b|dr\.?\s*gs|debit|txn\s+(?:of|at)|bill\s+pay|'
    r'pos\b|atm\b|transferred\s+(?:to|from)|outward|'
    r'debited\s+(?:to|from)\s+your|used\s+at|money\s+sent|amount\s+debited)',
    caseSensitive: false,
  );

  static final _creditSignals = RegExp(
    r'(?:credited|received|deposit|refund|reversal|cashback|salary|'
    r'interest\s+(?:credit|paid)|dividend|bonus|\bcr\b|'
    r'inward|money\s+received|amount\s+(?:received|credited)|settled|'
    r'credited\s+(?:to|with)|pay(?:ment)?\s+received|was\s+successful)',
    caseSensitive: false,
  );

  // ── Account / Card last-4 ──────────────────────────────────────────
  static final _last4Patterns = [
    RegExp(r'(?:a/c|acct|account)\s*(?:no\.?)?\s*[^\d]{0,8}(?:xx|x{2,}|\*{2,})?\s*(\d{4})',
        caseSensitive: false),
    RegExp(r'(?:credit\s+card|debit\s+card|card)\s+(?:ending|no\.?|xx)\s*[^\d]{0,6}(\d{4})',
        caseSensitive: false),
    RegExp(r'\bending\s+(?:with\s+)?(\d{4})\b', caseSensitive: false),
    RegExp(r'\bx(\d{4})\b', caseSensitive: false),
    RegExp(r'\bxx(\d{4})\b', caseSensitive: false),
    RegExp(r'\*{2,}(\d{4})\b'),
    RegExp(r'\.{2,}(\d{4})\b'),
  ];

  // ── Reference ID ───────────────────────────────────────────────────
  static final _refPatterns = [
    // UPI Ref no. / UPI Ref: / UPI Txn ID
    RegExp(r'UPI\s*(?:Ref|Txn)\s*(?:[Nn]o\.?|ID|#|:)?\s*\.?\s*([A-Za-z0-9]{6,})',
        caseSensitive: false),
    // UTR/IMPS/NEFT/RTGS specific
    RegExp(r'(?:UTR|IMPS|NEFT|RTGS)\s*(?:[Nn]o\.?|Ref\.?|:)?\s*([A-Za-z0-9]{10,})',
        caseSensitive: false),
    // Ref/Txn No: / Reference No.
    RegExp(r'(?:Ref(?:erence)?|Txn|Transaction)\s*(?:[Nn]o\.?|ID|#|:)\s*\.?\s*([A-Za-z0-9]{6,})',
        caseSensitive: false),
    // Standalone Ref followed by digits
    RegExp(r'\bRef\s*\.?\s*(\d{10,})', caseSensitive: false),
  ];

  // ── Balance ────────────────────────────────────────────────────────
  static final _balanceRegex = RegExp(
    r'(?:(?:Avl|Available|Avail\.?)\s*(?:Bal(?:ance)?|Amt|Lmt)?|'
    r'Bal(?:ance)?\s*(?:is|:)?|A/c\s+bal)'
    r'\s*(?:INR|Rs\.?|₹)?\s*([0-9,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );

  // ── VPA ────────────────────────────────────────────────────────────
  static final _vpaRegex = RegExp(
    r'([\w.\-]+@[a-zA-Z0-9]{2,})',
    caseSensitive: false,
  );
  static final _emailDomains = RegExp(r'@(?:gmail|yahoo|hotmail|outlook|rediff|mail|icloud)');

  // ── SMS Kind detection ─────────────────────────────────────────────
  static final _creditCardRegex = RegExp(
    r'(?:credit\s*card|card\s+ending|card\s+xx|visa|mastercard|rupay|'
    r'amex|diners|(?:your\s+(?:\w+\s+){0,4}card))',
    caseSensitive: false,
  );
  static final _emiRegex = RegExp(
    r'(?:(?<!\w)emi(?!\w)|installment|loan\s+(?:emi|repayment|payment)|'
    r'equated\s+monthly|loan\s+a/c|emi\s+(?:of|amount|due)|'
    r'monthly\s+(?:payment|installment))',
    caseSensitive: false,
  );
  static final _atmRegex = RegExp(
    r'(?:\batm\b|cash\s+withdrawal|self\s+withdrawal|atm\s+withdrawal)',
    caseSensitive: false,
  );
  static final _transferRegex = RegExp(
    r'(?:transfer(?:red)?\s+(?:to|from)\s+(?:your|self|own)|'
    r'(?:self|own)\s+(?:a/c|account)\s+transfer|'
    r'fund\s+transfer|inter[\s-]?bank)',
    caseSensitive: false,
  );

  // =====================================================================
  // PASS 3: BANK DETECTION (sender + body)
  // =====================================================================

  static const _senderBankMap = {
    // Major banks
    'HDFC': ['HDFCBK', 'HDFC', 'HDFCBANK', 'HDFCBN'],
    'SBI': ['SBIBNK', 'CBSSBI', 'SBI', 'SBIIN', 'SBIUPI', 'ATMSBI'],
    'ICICI': ['ICICIT', 'ICICI', 'ICICIB', 'ICICIS'],
    'Axis': ['AXISBK', 'AXIS', 'AXISB', 'AXISBN'],
    'Kotak': ['KOTAKB', 'KOTAK', 'KOTAKM'],
    'Yes Bank': ['YESBK', 'YESBNK', 'YESUPI'],
    'IndusInd': ['INDUSIND', 'INDBNK', 'INDUSB'],
    'BOB': ['BOBSMS', 'BOB', 'BOBIBN'],
    'PNB': ['PNBSMS', 'PNB', 'PUNBNK'],
    'Canara': ['CANBNK', 'CANARA', 'CANBK'],
    'Federal': ['FEDBNK', 'FEDERAL', 'FEDBK'],
    'RBL': ['RBLBNK', 'RBL', 'RBLBK'],
    'IDFC': ['IDFCFB', 'IDFC', 'IDFCBK'],
    'Union': ['UBOI', 'UNIONB', 'UBIBNK'],
    'IOB': ['IOBBNK', 'IOB'],
    'UCO': ['UCOBNK', 'UCO'],
    'Indian Bank': ['INDIANB', 'INDBK'],
    'Central Bank': ['CBIBNK', 'CBI'],
    'Bank of Maharashtra': ['MAHABN', 'BOM'],
    'South Indian Bank': ['SIBBNK', 'SIB'],
    'Karur Vysya': ['KVBBNK', 'KVB'],
    'City Union': ['CUBBNK', 'CUB'],
    'DCB': ['DCBBNK', 'DCB'],
    'Bandhan': ['BANDHN', 'BANDHAN'],
    'IDBI': ['IDIBNK', 'IDBI'],
    'DBS': ['DBSBNK', 'DBS'],
    'Standard Chartered': ['SCBBNK', 'SCBANK'],
    'Citibank': ['CITIBN', 'CITI'],
    'HSBC': ['HSBCBK', 'HSBC'],
    'CSB': ['CSBBNK', 'CSB', 'EDGECSB'],
    // Fintechs / Neo-banks
    'Jupiter': ['JTEDGE', 'JUPITER', 'JUPBNK'],
    'OneCard': ['OneCrd', 'ONECARD', 'ONECRD'],
    'Slice': ['SLICE', 'SLICEP'],
    'Fi': ['FIMONEY', 'EPIFI', 'FIBNK'],
    'Niyo': ['NIYO', 'NIYOBN'],
    'Paytm': ['PAYTM', 'PYTM', 'PAYTMB'],
    'PhonePe': ['PHONEPE', 'PHNEPE'],
    'GPay': ['GOOGLE', 'GPAY'],
    'CRED': ['CRED', 'CREDAP'],
    'Snapmint': ['SNPMNT', 'SNAPMINT'],
    'IPRUMF': ['IPRUMF'],
    'Navi': ['NAVIFI', 'NAVI'],
    'Groww': ['GROWW'],
    'Uni': ['UNICRD', 'UNI'],
    'Jio': ['JIOFIN', 'JIO', 'JIOBNK', 'JIOPAY'],
    'Bajaj': ['BAJFIN', 'BAJAJ', 'BAJFNS'],
    'Airtel': ['AIRTEL', 'AIRTLP'],
    'Amazon Pay': ['AMZNPY', 'AMAZON'],
    'Flipkart': ['FLPKRT', 'FLIPKA'],
    'ZestMoney': ['ZESTMN', 'ZEST'],
    'TVS Credit': ['TVSCRD', 'TVS'],
    'Tata Capital': ['TATACL', 'TATAFI'],
    'Muthoot': ['MUTHFT', 'MUTHOO'],
  };

  static final _bodyBankPatterns = [
    (RegExp(r'Edge\s*CSB\s*Bank', caseSensitive: false), 'CSB'),
    (RegExp(r'Jupiter\s*(?:App|Bank)?', caseSensitive: false), 'Jupiter'),
    (RegExp(r'ICICI\s*Bank', caseSensitive: false), 'ICICI'),
    (RegExp(r'HDFC\s*Bank', caseSensitive: false), 'HDFC'),
    (RegExp(r'State\s*Bank|SBI', caseSensitive: false), 'SBI'),
    (RegExp(r'Axis\s*Bank', caseSensitive: false), 'Axis'),
    (RegExp(r'Kotak\s*(?:Mahindra)?', caseSensitive: false), 'Kotak'),
    (RegExp(r'Federal\s*Bank', caseSensitive: false), 'Federal'),
    (RegExp(r'IndusInd\s*Bank', caseSensitive: false), 'IndusInd'),
    (RegExp(r'RBL\s*Bank', caseSensitive: false), 'RBL'),
    (RegExp(r'Jio\s*(?:Financial|Pay|Bank)?', caseSensitive: false), 'Jio'),
    (RegExp(r'Bajaj\s*(?:Finserv|Finance)?', caseSensitive: false), 'Bajaj'),
    (RegExp(r'OneCard', caseSensitive: false), 'OneCard'),
    (RegExp(r'Slice', caseSensitive: false), 'Slice'),
    (RegExp(r'Paytm', caseSensitive: false), 'Paytm'),
    (RegExp(r'PhonePe', caseSensitive: false), 'PhonePe'),
    (RegExp(r'Amazon\s*Pay', caseSensitive: false), 'Amazon Pay'),
  ];

  // =====================================================================
  // MAIN PARSE METHOD
  // =====================================================================

  /// Parse a raw SMS into a structured [ParsedSms].
  /// Returns null if the SMS should be ignored.
  static ParsedSms? parse({
    required String sender,
    required String body,
    required int timestampMillis,
  }) {
    // Normalize whitespace, non-breaking spaces, zero-width chars
    final text = body
        .replaceAll('\u00A0', ' ')
        .replaceAll('\u200B', '')
        .replaceAll('\u200C', '')
        .replaceAll('\u200D', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // ── PASS 1: CLASSIFY ──────────────────────────────────────────────
    for (final p in _ignorePatterns) {
      if (p.hasMatch(text)) return null;
    }

    // Check if this is a bill/statement (not a transaction)
    final isBill = _billPatterns.any((p) => p.hasMatch(text));
    // Check if this is an upcoming/scheduled transaction
    final isUpcoming = _upcomingPatterns.any((p) => p.hasMatch(text));

    // Bills and upcoming: skip — they're not actual debits/credits
    if (isBill || isUpcoming) return null;

    // ── PASS 2: EXTRACT ───────────────────────────────────────────────

    // Amount
    double? amount;
    for (final p in _amountPatterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        var raw = m.group(1)!;
        // Handle European format: 45,00 → 45.00
        if (raw.contains(',') && RegExp(r'^\d+,\d{2}$').hasMatch(raw)) {
          raw = raw.replaceAll(',', '.');
        } else {
          raw = raw.replaceAll(',', '');
        }
        amount = double.tryParse(raw);
        if (amount != null && amount > 0) break;
        amount = null;
      }
    }
    if (amount == null || amount <= 0) return null;

    // Direction
    final hasDebit = _debitSignals.hasMatch(text);
    final hasCredit = _creditSignals.hasMatch(text);
    if (!hasDebit && !hasCredit) return null;

    // Credit wins only if no debit signal
    final isCredit = hasCredit && !hasDebit;

    // Balance
    double? balance;
    final balM = _balanceRegex.firstMatch(text);
    if (balM != null) {
      balance = double.tryParse(balM.group(1)!.replaceAll(',', ''));
      if (balance == amount) balance = null; // don't duplicate
    }

    // Date: SMS timestamp is primary (always accurate).
    // Body-extracted date only used if timestamp is missing/zero.
    final DateTime smsDate;
    if (timestampMillis > 0) {
      smsDate = DateTime.fromMillisecondsSinceEpoch(timestampMillis);
    } else {
      smsDate = _extractDate(text) ?? DateTime.now();
    }

    // Account last-4
    String? last4;
    for (final p in _last4Patterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        last4 = m.group(1);
        break;
      }
    }

    // Reference ID
    String? refId;
    for (final p in _refPatterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        refId = m.group(1);
        break;
      }
    }

    // VPA
    String? vpa;
    final vpaM = _vpaRegex.firstMatch(text.toLowerCase());
    if (vpaM != null) {
      vpa = vpaM.group(1);
      if (vpa != null && _emailDomains.hasMatch(vpa)) vpa = null;
    }

    // UPI enrichment
    final upi = UpiParser.parse(text);
    if (upi != null) {
      refId ??= upi.refId;
      vpa ??= upi.vpa;
    }

    // Merchant (extract + normalize)
    String? merchant = upi?.merchant;
    if (merchant == null || merchant.isEmpty) {
      final extracted = MerchantExtractor.extract(text);
      merchant = extracted.isNotEmpty ? extracted : null;
    }
    // Normalize: "AMAZON PAY INDIA PVT LTD" → "Amazon"
    if (merchant != null && merchant.isNotEmpty) {
      merchant = MerchantNormalizer.normalize(merchant);
    }

    // ── PASS 3: ENRICH ────────────────────────────────────────────────

    // Bank from sender
    String? bankName;
    final senderUp = sender.toUpperCase();
    for (final entry in _senderBankMap.entries) {
      for (final alias in entry.value) {
        if (senderUp.contains(alias.toUpperCase())) {
          bankName = entry.key;
          break;
        }
      }
      if (bankName != null) break;
    }
    // Fallback: bank from body
    if (bankName == null) {
      for (final (pattern, bank) in _bodyBankPatterns) {
        if (pattern.hasMatch(text)) {
          bankName = bank;
          break;
        }
      }
    }

    // SMS Kind — advanced sub-type classification
    final finalIsCredit = upi?.isCredit ?? isCredit;
    final lower = text.toLowerCase();
    SmsKind kind = SmsKind.unknown;

    // Priority 1: Self/internal transfers (not real income/expense)
    if (_transferRegex.hasMatch(text)) {
      kind = SmsKind.transfer;
    }
    // Priority 2: ATM (cash withdrawal)
    else if (_atmRegex.hasMatch(text)) {
      kind = SmsKind.atm;
    }
    // Priority 3: Loan EMI
    else if (_emiRegex.hasMatch(text)) {
      kind = SmsKind.loanEmi;
    }
    // Priority 4: Refund/reversal
    else if (lower.contains('refund') || lower.contains('reversal') ||
        lower.contains('reversed')) {
      kind = SmsKind.refund;
    }
    // Priority 5: Credit card transactions
    else if (_creditCardRegex.hasMatch(text)) {
      // Distinguish: card bill payment vs card spend
      final isPaymentToCard = lower.contains('payment') &&
          (lower.contains('received') || lower.contains('successful') ||
           lower.contains('towards') || lower.contains('for your'));
      kind = isPaymentToCard
          ? SmsKind.creditCardPayment
          : finalIsCredit
              ? SmsKind.creditCardPayment
              : SmsKind.creditCardSpend;
    }
    // Priority 6: UPI
    else if (vpa != null || upi != null) {
      kind = finalIsCredit ? SmsKind.upiReceive : SmsKind.upiSend;
    }
    // Priority 7: Bank debit/credit
    else {
      kind = finalIsCredit ? SmsKind.bankCredit : SmsKind.bankDebit;
    }

    // Confidence scoring
    double confidence = 0;
    if (amount > 0) confidence += 0.25;
    if (hasDebit || hasCredit) confidence += 0.20;
    if (last4 != null) confidence += 0.15;
    if (refId != null && refId.isNotEmpty) confidence += 0.15;
    if (merchant != null && merchant.isNotEmpty) confidence += 0.10;
    if (bankName != null) confidence += 0.10;
    if (vpa != null) confidence += 0.05;
    confidence = confidence.clamp(0.0, 1.0);

    return ParsedSms(
      amount: amount,
      isCredit: finalIsCredit,
      sender: sender,
      body: body,
      date: smsDate,
      merchant: merchant,
      vpa: vpa,
      refId: refId,
      last4: last4,
      kind: kind,
      balance: balance,
      bankName: bankName,
      confidence: confidence,
    );
  }

  // =====================================================================
  // DATE EXTRACTION HELPER
  // =====================================================================

  static DateTime? _extractDate(String text) {
    // Pattern 1: 21-Feb-26, 12-Mar-2026 (most reliable — month name)
    final m1 = _datePatterns[0].firstMatch(text);
    if (m1 != null) {
      final day = int.tryParse(m1.group(1)!);
      final monthStr = m1.group(2)!.toLowerCase().substring(0, 3);
      final yearRaw = int.tryParse(m1.group(3)!);
      final month = _monthMap[monthStr];
      if (day != null && month != null && yearRaw != null) {
        final year = yearRaw < 100 ? 2000 + yearRaw : yearRaw;
        if (day >= 1 && day <= 31 && year >= 2020 && year <= 2030) {
          return DateTime(year, month, day);
        }
      }
    }

    // Pattern 2: 2026-02-21 (ISO — reliable)
    final m2 = _datePatterns[1].firstMatch(text);
    if (m2 != null) {
      final year = int.tryParse(m2.group(1)!);
      final month = int.tryParse(m2.group(2)!);
      final day = int.tryParse(m2.group(3)!);
      if (year != null && month != null && day != null &&
          year >= 2020 && year <= 2030 && month >= 1 && month <= 12) {
        return DateTime(year, month, day);
      }
    }

    // Pattern 3: DD/MM/YY or DD/MM/YYYY (Indian format — only / separator)
    final m3 = _datePatterns[2].firstMatch(text);
    if (m3 != null) {
      final p1 = int.tryParse(m3.group(1)!);
      final p2 = int.tryParse(m3.group(2)!);
      final p3 = int.tryParse(m3.group(3)!);
      if (p1 != null && p2 != null && p3 != null) {
        final year = p3 < 100 ? 2000 + p3 : p3;
        final day = p1;
        final month = p2;
        if (month >= 1 && month <= 12 && day >= 1 && day <= 31 &&
            year >= 2020 && year <= 2030) {
          return DateTime(year, month, day);
        }
      }
    }

    return null;
  }
}
