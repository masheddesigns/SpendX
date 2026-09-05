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

/// Everything a single SMS scan found.
class SmsScanBundle {
  final List<SmsImportResult> transactions;
  final List<BalanceHit> balances;
  final List<DetectedAccount> accounts;
  final List<DetectedCard> cards;

  const SmsScanBundle({
    required this.transactions,
    required this.balances,
    this.accounts = const [],
    this.cards = const [],
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
    if (_futureIntentRe.hasMatch(body.toLowerCase())) {
      return SmsClassification(balance: balance);
    }

    final parsed = TransactionTextParser.parse(body, source: 'sms');
    if (parsed.amount <= 0 || parsed.confidence < 0.4) {
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

    for (final sms in messages) {
      final body = sms.body ?? '';
      if (body.isEmpty) continue;

      final smsDate = sms.date;
      if (smsDate != null && cutoff != null && smsDate.isBefore(cutoff)) {
        continue;
      }

      final lower = body.toLowerCase();

      // Skip future/intent notifications (not completed transactions).
      if (_futureIntentRe.hasMatch(lower)) continue;

      // 1. Balance statements (bank / credit card / loan) — also picks up
      //    the trailing "Bal Rs X" from transaction messages.
      final balanceHit = _detectBalance(body, sms.address ?? '');
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
        }
      }

      // 2. Transaction messages.
      final parsed = TransactionTextParser.parse(body, source: 'sms');
      if (parsed.amount <= 0 || parsed.confidence < 0.4) continue;

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

    return SmsScanBundle(
      transactions: transactions,
      balances: balances,
      accounts: accounts,
      cards: cards,
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
    r'amount\s*due|bill\s*amount|payment\s*due|minimum\s*due|dues)'
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
  static final RegExp _futureIntentRe = RegExp(
    r'upcoming|will be debited|will be credited|has been enabled|'
    r'loan facility|pre-approved|preapproved|eligible|expir(?:y|es)|'
    r'\breminder\b|verification code|\botp\b|one time password|'
    r'emandate registered|auto.?pay|scheduled debit|plan offer|spend limit',
    caseSensitive: false,
  );

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

    // Credit card outstanding.
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

    // Loan balance.
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