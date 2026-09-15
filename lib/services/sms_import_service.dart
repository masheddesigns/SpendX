import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/review_item.dart';
import 'transaction_text_parser.dart';

/// What kind of account a detected balance statement refers to.
enum BalanceKind { bank, creditCard, loan }

/// A bank/credit/loan balance figure detected in an SMS.
class BalanceHit {
  final BalanceKind kind;
  final double amount;
  final String? last4;
  final String? bankKeyword;
  final String sender;
  final String body;

  const BalanceHit({
    required this.kind,
    required this.amount,
    this.last4,
    this.bankKeyword,
    required this.sender,
    required this.body,
  });
}

/// A transaction parsed from an SMS message, with the raw message kept.
class SmsImportResult {
  final ParsedTransaction parsed;
  final String sender;
  final String body;

  const SmsImportResult({
    required this.parsed,
    required this.sender,
    required this.body,
  });
}

/// A bank account detected from SMS (best-known balance).
class DetectedAccount {
  final String bank;
  final String? last4;
  final double balance;
  final String sender;
  const DetectedAccount({
    required this.bank,
    this.last4,
    required this.balance,
    required this.sender,
  });
}

/// A credit card detected from SMS (best-known outstanding).
class DetectedCard {
  final String bank;
  final String? last4;
  final double outstanding;
  final String sender;
  const DetectedCard({
    required this.bank,
    this.last4,
    required this.outstanding,
    required this.sender,
  });
}

/// A loan detected from SMS (best-known outstanding balance).
class DetectedLoan {
  final String bank;
  final double outstanding;
  final String sender;
  const DetectedLoan({
    required this.bank,
    required this.outstanding,
    required this.sender,
  });
}

/// Everything a single SMS scan found.
class SmsScanBundle {
  final List<SmsImportResult> transactions;
  final List<BalanceHit> balances;
  final List<DetectedAccount> accounts;
  final List<DetectedCard> cards;
  final List<DetectedLoan> loans;

  const SmsScanBundle({
    required this.transactions,
    required this.balances,
    this.accounts = const [],
    this.cards = const [],
    this.loans = const [],
  });
}

/// Scan window options.
class SmsScanOptions {
  /// Days of SMS to look back. `null` = scan everything.
  final int? daysBack;
  const SmsScanOptions({this.daysBack});
}

/// Result of classifying a single SMS message (used by the live detector).
class SmsClassification {
  final ParsedTransaction? transaction;
  final BalanceHit? balance;
  const SmsClassification({this.transaction, this.balance});
}

/// Scans the device's SMS inbox for bank transaction messages and balance
/// statements, parsing them with the same rule engine as share imports.
class SmsImportService {
  SmsImportService._();
  static final SmsImportService instance = SmsImportService._();

  /// Requests the SMS read permission. Returns true when granted.
  Future<bool> requestPermission() async {
    final status = await Permission.sms.request();
    return status.isGranted;
  }

  /// Classifies a single incoming SMS message (transaction / balance).
  /// Used by the live SMS detector.
  SmsClassification classifyMessage(String body, String sender) {
    final balance = _detectBalance(body, sender);

    // Future/intent messages are not completed transactions.
    if (_nonTransactionRe.hasMatch(body.toLowerCase())) {
      return SmsClassification(balance: balance);
    }

    // Sender-based gatekeeping: if the sender doesn't look like a known bank
    // shortcode, only allow messages with very strong transaction signals
    // (explicit debit/credit keywords). This blocks promo SMS from random
    // senders that happen to contain transaction-like language.
    if (sender.isNotEmpty && !_isBankSender(sender)) {
      final lower = body.toLowerCase();
      final hasStrongSignal = RegExp(
        r'\b(?:debited|credited|has been debited|has been credited|'
        r'payment of .* (?:to|from)|transferred to|sent to|received from)\b',
        caseSensitive: false,
      ).hasMatch(lower);
      if (!hasStrongSignal) {
        return SmsClassification(balance: balance);
      }
    }

    final parsed = TransactionTextParser.parse(body, source: 'sms');
    if (parsed.amount <= 0 || parsed.confidence < 0.4) {
      return SmsClassification(balance: balance);
    }

    // Failed/declined/cancelled payments are not completed transactions.
    if (TransactionTextParser.isFailedPayment(body)) {
      return SmsClassification(balance: balance);
    }

    var merchant = parsed.merchant;
    if (merchant == null || merchant.isEmpty) {
      merchant = _merchantFromUpi(body);
    }

    final effective = ParsedTransaction(
      amount: parsed.amount,
      isCredit: parsed.isCredit,
      rawText: parsed.rawText,
      date: parsed.date,
      merchant: merchant,
      refId: parsed.refId,
      last4: parsed.last4,
      bankName: parsed.bankName,
      method: parsed.method,
      source: 'sms',
      confidence: parsed.confidence,
      merchantSource: parsed.merchantSource,
      hasDirectionSignal: parsed.hasDirectionSignal,
    );

    return SmsClassification(transaction: effective, balance: balance);
  }

  Future<List<SmsMessage>> _queryInbox() async {
    return SmsQuery().querySms(
      count: 200,
      kinds: const [SmsQueryKind.inbox],
    );
  }

  /// Scans recent SMS and returns detected transactions + balance statements.
  Future<SmsScanBundle> scan({SmsScanOptions options = const SmsScanOptions()}) async {
    if (!await requestPermission()) {
      return const SmsScanBundle(transactions: [], balances: []);
    }

    final messages = await _queryInbox();

    final cutoff = options.daysBack == null
        ? null
        : DateTime.now().subtract(Duration(days: options.daysBack!));

    final seenTx = <String>{};
    final seenBal = <String>{};
    final transactions = <SmsImportResult>[];
    final balances = <BalanceHit>[];
    final accountMap =
        <String, ({DateTime? date, String bank, String? last4, double balance, String sender})>{};
    final cardMap =
        <String, ({DateTime? date, String bank, String? last4, double outstanding, String sender})>{};
    final loanMap =
        <String, ({DateTime? date, String bank, double outstanding, String sender})>{};

    for (final sms in messages) {
      final body = sms.body ?? '';
      if (body.isEmpty) continue;

      final smsDate = sms.date;
      if (smsDate != null && cutoff != null && smsDate.isBefore(cutoff)) {
        continue;
      }

      final lower = body.toLowerCase();

      // 1. Balance statements (bank / credit card / loan) — detect BEFORE
      //    the non-transaction filter because credit card statements contain
      //    "statement"/"bill.*due" which would otherwise skip the balance.
      final senderAddr = sms.address ?? '';
      final balanceHit = _detectBalance(body, senderAddr);
      if (balanceHit != null) {
        final balKey =
            '${balanceHit.kind.name}|${balanceHit.amount}|${balanceHit.last4}';
        if (seenBal.add(balKey)) balances.add(balanceHit);

        // Track the latest known balance/outstanding per entity.
        if (balanceHit.kind == BalanceKind.bank) {
          final key = balanceHit.last4 ?? balanceHit.bankKeyword ?? '';
          if (key.isNotEmpty) {
            final existing = accountMap[key];
            if (existing == null ||
                smsDate == null ||
                existing.date == null ||
                smsDate.isAfter(existing.date!)) {
              accountMap[key] = (
                date: smsDate,
                bank: _bankDisplayName(balanceHit.bankKeyword),
                last4: balanceHit.last4,
                balance: balanceHit.amount,
                sender: balanceHit.sender,
              );
            }
          }
        } else if (balanceHit.kind == BalanceKind.creditCard) {
          final key = balanceHit.last4 ?? balanceHit.bankKeyword ?? '';
          if (key.isNotEmpty) {
            final existing = cardMap[key];
            if (existing == null ||
                smsDate == null ||
                existing.date == null ||
                smsDate.isAfter(existing.date!)) {
              cardMap[key] = (
                date: smsDate,
                bank: _bankDisplayName(balanceHit.bankKeyword),
                last4: balanceHit.last4,
                outstanding: balanceHit.amount,
                sender: balanceHit.sender,
              );
            }
          }
        } else if (balanceHit.kind == BalanceKind.loan) {
          final key = balanceHit.bankKeyword ?? '';
          if (key.isNotEmpty) {
            final existing = loanMap[key];
            if (existing == null ||
                smsDate == null ||
                existing.date == null ||
                smsDate.isAfter(existing.date!)) {
              loanMap[key] = (
                date: smsDate,
                bank: _bankDisplayName(balanceHit.bankKeyword),
                outstanding: balanceHit.amount,
                sender: balanceHit.sender,
              );
            }
          }
        }
      }

      // 2. Transaction messages — skip non-transaction / intent SMS.
      if (_nonTransactionRe.hasMatch(lower)) continue;

      // Sender-based gatekeeping: non-bank senders must have strong signals.
      if (senderAddr.isNotEmpty && !_isBankSender(senderAddr)) {
        final hasStrongSignal = RegExp(
          r'\b(?:debited|credited|has been debited|has been credited|'
          r'payment of .* (?:to|from)|transferred to|sent to|received from)\b',
          caseSensitive: false,
        ).hasMatch(lower);
        if (!hasStrongSignal) continue;
      }

      final parsed = TransactionTextParser.parse(body, source: 'sms');
      if (parsed.amount <= 0 || parsed.confidence < 0.4) continue;

      // Failed/declined/cancelled payments are not completed transactions.
      if (TransactionTextParser.isFailedPayment(body)) continue;

      // 3. Merchant fallback from the UPI reference when the parser missed it.
      var merchant = parsed.merchant;
      if (merchant == null || merchant.isEmpty) {
        merchant = _merchantFromUpi(body);
      }

      final effective = ParsedTransaction(
        amount: parsed.amount,
        isCredit: parsed.isCredit,
        rawText: parsed.rawText,
        date: smsDate ?? parsed.date,
        merchant: merchant,
        refId: parsed.refId,
        last4: parsed.last4,
        bankName: parsed.bankName,
        method: parsed.method,
        source: 'sms',
        confidence: parsed.confidence,
        merchantSource: parsed.merchantSource,
        hasDirectionSignal: parsed.hasDirectionSignal,
      );

      final txKey =
          '${effective.merchant}|${effective.amount}|'
          '${effective.date.year}-${effective.date.month}-${effective.date.day}';
      if (!seenTx.add(txKey)) continue;

      transactions.add(
        SmsImportResult(
          parsed: effective,
          sender: sms.address ?? '',
          body: body,
        ),
      );
    }

    // Filter balances to keep only the latest per account/card.
    // accountMap/cardMap already track the most recent by date — use them
    // to discard older balance hits so catchUpHistorical applies the right one.
    final latestByAccount = <String, double>{};
    for (final entry in accountMap.entries) {
      latestByAccount['bank|${entry.value.last4 ?? ''}'] = entry.value.balance;
    }
    for (final entry in cardMap.entries) {
      latestByAccount['card|${entry.value.last4 ?? ''}'] = entry.value.outstanding;
    }
    final dedupedBalances = balances.where((hit) {
      final key = hit.kind == BalanceKind.bank
          ? 'bank|${hit.last4 ?? ''}'
          : hit.kind == BalanceKind.creditCard
              ? 'card|${hit.last4 ?? ''}'
              : null;
      if (key == null) return true; // keep loan/unknown balances
      final latestAmount = latestByAccount[key];
      if (latestAmount == null) return true;
      return (hit.amount - latestAmount).abs() < 0.01;
    }).toList();

    final accounts = accountMap.values
        .map(
          (a) => DetectedAccount(
            bank: a.bank,
            last4: a.last4,
            balance: a.balance,
            sender: a.sender,
          ),
        )
        .toList();
    final cards = cardMap.values
        .map(
          (c) => DetectedCard(
            bank: c.bank,
            last4: c.last4,
            outstanding: c.outstanding,
            sender: c.sender,
          ),
        )
        .toList();
    final loans = loanMap.values
        .map(
          (l) => DetectedLoan(
            bank: l.bank,
            outstanding: l.outstanding,
            sender: l.sender,
          ),
        )
        .toList();

    return SmsScanBundle(
      transactions: transactions,
      balances: dedupedBalances,
      accounts: accounts,
      cards: cards,
      loans: loans,
    );
  }

  static final RegExp _bankBalanceRe = RegExp(
    r'\b(?:available\s*balance|avail\.?\s*bal(?:ance)?|current\s*balance|'
    r'account\s*balance|your\s*balance|closing\s*balance|'
    r'updated\s*balance|new\s*bal(?:ance)?|balance|bal\.?)\b'
    r'[^\d₹]*?(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)',
    caseSensitive: false,
  );

  static final RegExp _creditDueRe = RegExp(
    r'(?:outstanding\s*(?:balance|amount|dues)?|total\s*(?:due|outstanding)|'
    r'amount\s*due|bill\s*amount|payment\s*due|minimum\s*due|dues|'
    r'total\s+of|minimum\s+of)'
    r'[^\d₹]*?(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)',
    caseSensitive: false,
  );

  static final RegExp _loanBalanceRe = RegExp(
    r'(?:loan\s*(?:account|balance|principal|outstanding)|'
    r'principal\s*(?:outstanding|balance)|emi\s*loan)'
    r'[^\d₹]*?(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)',
    caseSensitive: false,
  );

  static final RegExp _last4Re = RegExp(
    r'(?:x+(\d{4,})|(?:a\/c|ac|acc|card|ending)[\s:*\-]*(\d{4,}))',
    caseSensitive: false,
  );

  /// Messages that describe a future/intent action (not a completed
  /// transaction) or are clearly non-transactional — filtered out.
  static final RegExp _nonTransactionRe = RegExp(
    r'upcoming|will be debited|will be credited|has been enabled|'
    r'loan facility|pre-approved|preapproved|eligible|expir(?:y|es|ing)|'
    r'\breminder\b|verification code|\botp\b|one time password|'
    r'emandate registered|auto.?pay|scheduled debit|plan offer|spend limit|'
    r'\bmandate\b|mandate.*(?:creat|revok|cancel|activ)|'
    r'successfully revok|revok(?:ed|ing)|'
    r'\bbonus\b|claim now|free bonus|\bneu ?coins?\b|reward|points? credited|'
    r'bill.*(?:generat|due|issued)|statement|is due for payment|'
    r'\bregistered\b|registration|enrolled|'
    r'credit limit|increas(?:e|ing) (?:the )?limit|limit.*(?:increas|rais)|'
    r'fund bal|securities bal|'
    r'\bapy\b|\bpran\b|pension|trade confirm|broker|booking info|'
    r'offer for you|pre-approved loan|'
    r'download (?:the )?app|apply now|limited time|use code|'
    r'get cashback|instant loan|personal loan|emi option|no cost|'
    r'0% ?interest|bajaj|loan approv|credit score|check your|'
    r'free credit|get loan|'
    r'terms and conditions|t&c|click here|know more|'
    r'customer care|toll free|helpline|'
    r'has been initiated|is booked|is available|is scheduled|'
    r'unsuccessful|failed|cancelled|canceled|'
    r'terms.*(?:chang|revis)|fee.*revis|foreclosure|'
    r'data usage|data quota|daily data|'
    r'report spam|TRAI DND',
    caseSensitive: false,
  );

  /// Known bank SMS sender patterns. Indian bank SMS typically come from
  /// shortcodes like "AD-FEDBNK-T", "VA-ICICIT-S", "JM-HDFCBK-P", etc.
  /// The format is `<3rdParty>-<BankCode>-<Type>` where Type is usually
  /// T (transactional), S (service), P (promotional).
  static final RegExp _bankSenderRe = RegExp(
    r'^[A-Z]{2,4}-[A-Z]{2,8}-[A-Z]$',
  );

  /// Returns true if the sender looks like a bank SMS shortcode.
  static bool _isBankSender(String sender) {
    if (sender.isEmpty) return false;
    return _bankSenderRe.hasMatch(sender);
  }

  /// UPI reference merchant: `UPI/DR/123456789012/MERCHANT`.
  static final RegExp _upiRefRe = RegExp(
    r'UPI/(?:DR|CR|P2A|P2P)/\d+/([A-Za-z0-9 .&/()-]+)',
    caseSensitive: false,
  );

  /// Detects a balance statement in an SMS. Returns `null` when the message
  /// is (primarily) a transaction alert instead.
  BalanceHit? _detectBalance(String body, String sender) {
    final lower = body.toLowerCase();
    final bankKeyword = _bankKeyword(sender, lower);

    // Loan balance — check BEFORE credit card because loan SMS often contain
    // "outstanding" which would falsely match the credit card pattern.
    if (_loanBalanceRe.hasMatch(lower)) {
      final m = _loanBalanceRe.firstMatch(body);
      if (m != null) {
        final amount = _parseAmount(m.group(1)!);
        if (amount > 0) {
          return BalanceHit(
            kind: BalanceKind.loan,
            amount: amount,
            last4: _last4(body),
            bankKeyword: bankKeyword,
            sender: sender,
            body: body,
          );
        }
      }
    }

    // Credit card outstanding — check BEFORE bank balance because credit card
    // SMS often contain the word "balance" which would falsely match bank.
    if (_creditDueRe.hasMatch(lower)) {
      final m = _creditDueRe.firstMatch(body);
      if (m != null) {
        final amount = _parseAmount(m.group(1)!);
        if (amount > 0) {
          return BalanceHit(
            kind: BalanceKind.creditCard,
            amount: amount,
            last4: _last4(body),
            bankKeyword: bankKeyword,
            sender: sender,
            body: body,
          );
        }
      }
    }

    // Bank balance — matches "available balance Rs X" statements as well as
    // the trailing "Bal Rs X" on transaction messages.
    final bankBalance = _bankBalanceRe.firstMatch(body);
    if (bankBalance != null) {
      final amount = _parseAmount(bankBalance.group(1)!);
      if (amount > 0) {
        return BalanceHit(
          kind: BalanceKind.bank,
          amount: amount,
          last4: _last4(body),
          bankKeyword: bankKeyword,
          sender: sender,
          body: body,
        );
      }
    }

    return null;
  }

  String? _merchantFromUpi(String body) {
    final m = _upiRefRe.firstMatch(body);
    if (m == null) return null;
    var raw = m.group(1)!.trim();
    raw = raw
        .replaceFirst(
          RegExp(r'\s+(not you|call|ref|on)\b.*$', caseSensitive: false),
          '',
        )
        .trim();
    return raw.isEmpty ? null : raw;
  }

  String? _bankKeyword(String sender, String lower) {
    // Sender format is usually `<3rdParty>-<BANKCODE>-<Type>`; the middle
    // segment is the bank code (e.g. "VA-FEDBNK-T" -> "fedbnk").
    final parts = sender.split('-');
    if (parts.length >= 3 && parts[1].isNotEmpty) {
      final code = parts[1].toLowerCase();
      if (RegExp(r'^[a-z0-9]+$').hasMatch(code)) return code;
    }
    final letters = RegExp(r'[a-z]+').allMatches(sender.toLowerCase()).map(
      (m) => m.group(0)!,
    );
    if (letters.isNotEmpty) return letters.first;
    // Fall back to a bank name like "hdfc", "axis", "sbi", "icici" in body.
    for (final bank in ['hdfc', 'axis', 'icici', 'sbi', 'kotak', 'yes bank']) {
      if (lower.contains(bank)) return bank.replaceAll(' ', '');
    }
    return null;
  }

  static const _bankNames = <String, String>{
    'cbssbi': 'State Bank of India',
    'sbiinb': 'State Bank of India',
    'sbi': 'State Bank of India',
    'fedbnk': 'Federal Bank',
    'axsbk': 'Axis Bank',
    'axisbk': 'Axis Bank',
    'axns': 'Axis Bank',
    'icicib': 'ICICI Bank',
    'icici': 'ICICI Bank',
    'hdfcbk': 'HDFC Bank',
    'hdfc': 'HDFC Bank',
    'kotakb': 'Kotak Mahindra Bank',
    'kotak': 'Kotak Mahindra Bank',
    'jiopbs': 'Jio Payments Bank',
    'onecrd': 'OneCard',
    'onecard': 'OneCard',
    'csb': 'CSB Bank',
    'jtedge': 'Jupiter',
    'yesbk': 'YES Bank',
    'yesbank': 'YES Bank',
    'pnb': 'Punjab National Bank',
    'idbib': 'IDBI Bank',
    'indus': 'IndusInd Bank',
  };

  String _bankDisplayName(String? code) {
    if (code == null) return 'Bank';
    return _bankNames[code] ?? code.toUpperCase();
  }

  String? _last4(String body) {
    final m = _last4Re.firstMatch(body);
    if (m == null) return null;
    final digits = m.group(1) ?? m.group(2);
    if (digits == null) return null;
    return digits.length > 4 ? digits.substring(digits.length - 4) : digits;
  }

  double _parseAmount(String raw) {
    return double.tryParse(raw.replaceAll(',', '')) ?? 0;
  }
}