import 'package:flutter/services.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/logging/app_logger.dart';
import '../models/reminder_model.dart';
import '../models/review_item.dart';
import 'transaction_text_parser.dart';

const _channel = MethodChannel('spendx/sms_live');

/// What kind of account a detected balance statement refers to.
enum BalanceKind { bank, creditCard, loan, wallet }

/// A bank/credit/loan balance figure detected in an SMS.
class BalanceHit {
  final BalanceKind kind;
  final double amount;
  final String? last4;
  final String? bankKeyword;
  final String sender;
  final String body;
  final bool isAvailableLimit;
  final DateTime? dueDate;
  final double? minDue;
  final double? creditLimit;
  final bool isStatementBill;

  const BalanceHit({
    required this.kind,
    required this.amount,
    this.last4,
    this.bankKeyword,
    required this.sender,
    required this.body,
    this.isAvailableLimit = false,
    this.dueDate,
    this.minDue,
    this.creditLimit,
    this.isStatementBill = false,
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

/// A credit card detected from SMS (best-known outstanding / available limit).
class DetectedCard {
  final String bank;
  final String? last4;
  final String? keyword;
  final double outstanding;
  final double? creditLimit;
  final double? availableLimit;
  final bool isAvailableLimit;
  final bool isStatementBill;
  final DateTime? dueDate;
  final double? minDue;
  final String sender;

  const DetectedCard({
    required this.bank,
    this.last4,
    this.keyword,
    required this.outstanding,
    this.creditLimit,
    this.availableLimit,
    this.isAvailableLimit = false,
    this.isStatementBill = false,
    this.dueDate,
    this.minDue,
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

/// An upcoming financial obligation detected in an SMS (e-mandate, autopay, utility bill due, insurance renewal).
class UpcomingObligationHit {
  final String title;
  final double amount;
  final DateTime dueDate;
  final String? merchant;
  final String? last4;
  final String? bankKeyword;
  final ReminderType reminderType;
  final bool isMandate;
  final String sender;
  final String body;
  final DateTime? smsDate;

  const UpcomingObligationHit({
    required this.title,
    required this.amount,
    required this.dueDate,
    this.merchant,
    this.last4,
    this.bankKeyword,
    required this.reminderType,
    this.isMandate = false,
    required this.sender,
    required this.body,
    this.smsDate,
  });
}

/// Everything a single SMS scan found.
class SmsScanBundle {
  final List<SmsImportResult> transactions;
  final List<BalanceHit> balances;
  final List<DetectedAccount> accounts;
  final List<DetectedCard> cards;
  final List<DetectedLoan> loans;
  final List<UpcomingObligationHit> upcomingObligations;

  const SmsScanBundle({
    required this.transactions,
    required this.balances,
    this.accounts = const [],
    this.cards = const [],
    this.loans = const [],
    this.upcomingObligations = const [],
  });
}

/// Scan window options.
class SmsScanOptions {
  /// Days of SMS to look back. `null` = scan everything.
  final int? daysBack;
  const SmsScanOptions({this.daysBack});
}

/// High-level financial event type classified from an incoming SMS.
enum SmsEventType {
  /// General expense (bank debit, cash spend, etc.)
  expense,

  /// General income (salary, deposit, incoming UPI, etc.)
  income,

  /// Bill payment / payment received towards a credit card (liability settlement)
  creditCardPayment,

  /// Purchase made using a credit card (liability increase)
  creditCardPurchase,

  /// Refund credited back to a card or bank
  refund,

  /// Transfer between accounts or wallet top-up
  transfer,

  /// Failed, declined, or cancelled transaction attempt
  failed,

  /// Bill payment reminder, recurring subscription mandate, or upcoming scheduled debit
  billReminder,

  /// Non-transactional notification, statement summary, or balance update only
  infoOnly,
}

/// Result of classifying a single SMS message (used by the live detector).
class SmsClassification {
  final ParsedTransaction? transaction;
  final BalanceHit? balance;
  final UpcomingObligationHit? upcomingObligation;
  final SmsEventType eventType;

  const SmsClassification({
    this.transaction,
    this.balance,
    this.upcomingObligation,
    this.eventType = SmsEventType.infoOnly,
  });
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
    // 0. Hard reject OTPs and verification codes — NEVER return a transaction or balance!
    if (_isOtpOrAuth(body)) {
      return const SmsClassification();
    }

    final lower = body.toLowerCase();
    final isRefund = _isRefundText(lower);

    // 1. Check for failed/declined/cancelled payments first so they are properly classified as failed
    // (except when the message is a confirmed reversal/refund credit).
    if (!isRefund && TransactionTextParser.isFailedPayment(body)) {
      final balance = _detectBalance(body, sender);
      return SmsClassification(balance: balance, eventType: SmsEventType.failed);
    }

    // 1.5. Detect upcoming financial obligations (e-mandates, subscriptions, scheduled debits, bill dues)
    final upcoming = detectUpcomingObligation(body, sender);
    if (upcoming != null) {
      final balance = _detectBalance(body, sender);
      return SmsClassification(
        balance: balance,
        upcomingObligation: upcoming,
        eventType: SmsEventType.billReminder,
      );
    }

    // 2. Hard reject non-transaction / promotional / telecom / weather / service messages.
    // Exception: Do not reject credit card payment confirmations, refunds, bills, or spends.
    final isCcPaymentCandidate = _isCreditCardPaymentText(lower, sender);
    final isCcBillCandidate = _isCreditCardBillText(lower);
    final isCcSpend = _isCardSpendCandidate(lower);
    if (!isCcPaymentCandidate &&
        !isRefund &&
        !isCcBillCandidate &&
        !isCcSpend &&
        _nonTransactionRe.hasMatch(lower)) {
      return const SmsClassification();
    }

    // 2. Personal numbers: SMS from numeric mobile numbers are personal texts,
    // not bank broadcast alerts.
    final cleanSender = sender.trim().replaceAll('+', '').replaceAll('-', '');
    if (cleanSender.isNotEmpty && RegExp(r'^\d+$').hasMatch(cleanSender)) {
      return const SmsClassification();
    }

    // 3. Sender-based gatekeeping:
    // If the sender does not match a verified bank/wallet code, only allow
    // messages that contain both strong transaction language AND account identifiers.
    final isBank = _isBankSender(sender);
    if (!isBank) {
      final hasStrongSignal = RegExp(
        r'\b(?:debited\s*(?:from|by|with)|credited\s*(?:to|with)|has been debited|has been credited|'
        r'sent from|transferred to|received in|payment of .* (?:to|from))\b',
        caseSensitive: false,
      ).hasMatch(lower);
      final hasAccountSignal = RegExp(
        r'\b(?:a/c|acct|account|card ending|ending with \d{4}|x{2,}\d{2,4}|upi/dr|upi/cr)\b',
        caseSensitive: false,
      ).hasMatch(lower);
      if (!hasStrongSignal || !hasAccountSignal) {
        return const SmsClassification();
      }
    }

    final balance = _detectBalance(body, sender);

    final parsed = TransactionTextParser.parse(body, source: 'sms');
    if (parsed.amount <= 0 || parsed.confidence < 0.4) {
      return SmsClassification(balance: balance);
    }

    // Must have direction signal or explicit financial verb (or be an identified CC payment / refund)
    if (!parsed.hasDirectionSignal &&
        !isCcPaymentCandidate &&
        !isRefund &&
        !RegExp(r'\b(?:debited|credited|paid|spent|sent|transferred|withdrawn|refunded)\b',
                caseSensitive: false)
            .hasMatch(lower)) {
      return SmsClassification(balance: balance);
    }

    // Failed/declined/cancelled payments are not completed transactions
    // (unless it is a confirmed reversal/refund credit).
    if (!isRefund && TransactionTextParser.isFailedPayment(body)) {
      return SmsClassification(balance: balance, eventType: SmsEventType.failed);
    }

    var merchant = parsed.merchant;
    if (merchant == null || merchant.isEmpty) {
      merchant = _merchantFromUpi(body);
    }

    // Determine high-level financial event type
    final isCcPayment = _isCreditCardPaymentText(lower, sender);

    final isDebitCard = lower.contains('debit card') ||
        lower.contains('debit crd') ||
        lower.contains('debit-card');

    final isWallet = lower.contains('wallet') ||
        lower.contains('amazon pay balance') ||
        lower.contains('paytm balance');

    final hasExplicitCreditCard = lower.contains('credit card') ||
        lower.contains('credit crd') ||
        lower.contains('rupay credit') ||
        lower.contains('edge csb credit') ||
        lower.contains('edge credit') ||
        lower.contains('onecard') ||
        lower.contains('bobcard') ||
        lower.contains('bobcrd');

    final hasExplicitAccount = lower.contains('a/c') ||
        lower.contains('acct') ||
        lower.contains('bank a/c') ||
        lower.contains('savings a/c') ||
        lower.contains('current a/c') ||
        lower.contains('account xx') ||
        lower.contains('account no');

    // A transaction is a credit card spend ONLY IF:
    // 1. It is not an explicit debit card (ATM, POS swipe, etc.)
    // 2. It is not an explicit bank account or wallet (unless an explicit credit card is mentioned)
    final bool isCardSpend;
    if (isDebitCard || ((hasExplicitAccount || isWallet) && !hasExplicitCreditCard)) {
      isCardSpend = false;
    } else {
      isCardSpend = parsed.method == 'card' ||
          lower.contains('spent using') ||
          lower.contains('spent at') ||
          lower.contains('paid from your edge') ||
          lower.contains('credit card') ||
          lower.contains('card ending') ||
          lower.contains('card xx') ||
          lower.contains('card no') ||
          lower.contains('on your card') ||
          lower.contains('on card') ||
          sender.toLowerCase().contains('crd') ||
          sender.toLowerCase().contains('jtedge');
    }

    final SmsEventType eventType;
    final bool effectiveIsCredit;

    if (isCcPayment) {
      eventType = SmsEventType.creditCardPayment;
      effectiveIsCredit = false; // Zero income / liability reduction
    } else if (isRefund) {
      eventType = SmsEventType.refund;
      effectiveIsCredit = true; // Refund credit
    } else if (isCardSpend && !parsed.isCredit) {
      eventType = SmsEventType.creditCardPurchase;
      effectiveIsCredit = false;
    } else if (parsed.isCredit) {
      eventType = SmsEventType.income;
      effectiveIsCredit = true;
    } else {
      eventType = SmsEventType.expense;
      effectiveIsCredit = false;
    }

    final effectiveBankName = parsed.bankName ??
        (_bankKeyword(sender, lower) != null
            ? _bankDisplayName(_bankKeyword(sender, lower))
            : null);

    final effective = ParsedTransaction(
      amount: parsed.amount,
      isCredit: effectiveIsCredit,
      rawText: parsed.rawText,
      date: parsed.date,
      merchant: merchant,
      refId: parsed.refId,
      last4: parsed.last4 ?? _last4(body),
      bankName: effectiveBankName,
      method: (isCcPayment || isCardSpend || _isCreditCardRefundText(lower))
          ? 'card'
          : parsed.method,
      source: 'sms',
      confidence: parsed.confidence,
      merchantSource: parsed.merchantSource,
      hasDirectionSignal: parsed.hasDirectionSignal,
    );

    return SmsClassification(
      transaction: effective,
      balance: balance,
      eventType: eventType,
    );
  }

  Future<List<SmsMessage>> _queryInbox() async {
    // Use native query with date sorting — the flutter_sms_inbox library caps
    // at 1000 and doesn't sort, so OneCard/HDFC bills from months ago are missed.
    try {
      final List<dynamic> raw = await _channel.invokeMethod('queryInboxSince', {
        'sinceEpochMs': 0,
        'limit': 20000,
      });
      AppLogger.d('[SmsScan] Native queryInboxSince returned ${raw.length} raw messages');
      final result = raw.map((m) {
        final map = Map<String, dynamic>.from(m as Map);
        return SmsMessage.fromJson(map);
      }).toList();
      AppLogger.d('[SmsScan] Parsed ${result.length} SmsMessages');
      return result;
    } catch (e) {
      AppLogger.w('[SmsScan] Native queryInboxSince failed: $e — falling back to library');
      // Fallback to library if native query fails
      return SmsQuery().querySms(
        count: 1000,
        kinds: const [SmsQueryKind.inbox],
      );
    }
  }

  /// Scans recent SMS and returns detected transactions + balance statements.
  Future<SmsScanBundle> scan({SmsScanOptions options = const SmsScanOptions()}) async {
    if (!await requestPermission()) {
      return const SmsScanBundle(transactions: [], balances: []);
    }

    final messages = await _queryInbox();
    AppLogger.d('[SmsScan] _queryInbox returned ${messages.length} messages');

    final cutoff = options.daysBack == null
        ? null
        : DateTime.now().subtract(Duration(days: options.daysBack!));

    final seenTx = <String>{};
    final seenBal = <String>{};
    final seenUpcoming = <String>{};
    final transactions = <SmsImportResult>[];
    final balances = <BalanceHit>[];
    final upcomingObligations = <UpcomingObligationHit>[];
    final accountMap =
        <String, ({DateTime? date, String bank, String? last4, double balance, String sender})>{};
    final cardMap =
        <String, ({
          DateTime? date,
          String bank,
          String? last4,
          String? keyword,
          double outstanding,
          double? creditLimit,
          double? availableLimit,
          bool isAvailableLimit,
          bool isStatementBill,
          DateTime? dueDate,
          double? minDue,
          String sender,
        })>{};
    final loanMap =
        <String, ({DateTime? date, String bank, double outstanding, String sender})>{};

    for (final sms in messages) {
      final body = sms.body ?? '';
      if (body.isEmpty) continue;

      // 0. Hard reject OTPs and auth messages immediately
      if (_isOtpOrAuth(body)) continue;

      final smsDate = sms.date;
      if (smsDate != null && cutoff != null && smsDate.isBefore(cutoff)) {
        continue;
      }

      final senderAddr = sms.address ?? '';

      // Skip personal phone numbers
      final cleanSender = senderAddr.trim().replaceAll('+', '').replaceAll('-', '');
      if (cleanSender.isNotEmpty && RegExp(r'^\d+$').hasMatch(cleanSender)) {
        continue;
      }

      final lower = body.toLowerCase();

      // 1. Balance statements (bank / credit card / loan) — detect BEFORE
      //    the non-transaction filter because credit card statements contain
      //    "statement"/"bill.*due" which would otherwise skip the balance.
      final balanceHit = _detectBalance(body, senderAddr);
      if (balanceHit != null) {
        AppLogger.d(
          '[SmsScan] balance hit detected (type: ${balanceHit.kind.name})',
        );
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
                keyword: balanceHit.bankKeyword,
                outstanding: balanceHit.amount,
                creditLimit: balanceHit.creditLimit,
                availableLimit: balanceHit.isAvailableLimit ? balanceHit.amount : null,
                isAvailableLimit: balanceHit.isAvailableLimit,
                isStatementBill: balanceHit.isStatementBill,
                dueDate: balanceHit.dueDate,
                minDue: balanceHit.minDue,
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

      final isCcPaymentCandidate = _isCreditCardPaymentText(lower, senderAddr);
      final isRefundCandidate = _isRefundText(lower);
      final isCcBillCandidate = _isCreditCardBillText(lower);
      final isCardSpend = _isCardSpendCandidate(lower);

      // 1.5 Upcoming financial obligations (mandates, subscriptions, bill dues)
      final upcomingHit = detectUpcomingObligation(body, senderAddr, smsDate: smsDate);
      if (upcomingHit != null) {
        final upKey = '${upcomingHit.merchant ?? upcomingHit.title}|${upcomingHit.dueDate.year}-${upcomingHit.dueDate.month}-${upcomingHit.dueDate.day}|${upcomingHit.amount}';
        if (seenUpcoming.add(upKey)) {
          upcomingObligations.add(upcomingHit);
        }
      }

      // 2. Transaction messages — skip non-transaction / intent SMS.
      if (!isCcPaymentCandidate &&
          !isRefundCandidate &&
          !isCcBillCandidate &&
          !isCardSpend &&
          _nonTransactionRe.hasMatch(lower)) {
        continue;
      }

      // Sender-based gatekeeping: non-bank senders must have strong signals.
      if (!_isBankSender(senderAddr)) {
        final hasStrongSignal = RegExp(
          r'\b(?:debited\s*(?:from|by|with)|credited\s*(?:to|with)|has been debited|has been credited|'
          r'sent from|transferred to|received in|payment of .* (?:to|from))\b',
          caseSensitive: false,
        ).hasMatch(lower);
        final hasAccountSignal = RegExp(
          r'\b(?:a/c|acct|account|card ending|ending with \d{4}|x{2,}\d{2,4}|upi/dr|upi/cr)\b',
          caseSensitive: false,
        ).hasMatch(lower);
        if (!hasStrongSignal || !hasAccountSignal) continue;
      }

      final parsed = TransactionTextParser.parse(body, source: 'sms');
      if (parsed.amount <= 0 || parsed.confidence < 0.4) continue;

      // Must have direction signal or explicit financial verb
      if (!parsed.hasDirectionSignal &&
          !RegExp(r'\b(?:debited|credited|paid|spent|sent|transferred|withdrawn|refunded)\b',
                  caseSensitive: false)
              .hasMatch(lower)) {
        continue;
      }

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
      latestByAccount['bank|${entry.key}'] = entry.value.balance;
    }
    for (final entry in cardMap.entries) {
      latestByAccount['card|${entry.key}'] = entry.value.outstanding;
    }
    final dedupedBalances = balances.where((hit) {
      final key = hit.kind == BalanceKind.bank
          ? 'bank|${hit.last4 ?? hit.bankKeyword ?? ''}'
          : hit.kind == BalanceKind.creditCard
              ? 'card|${hit.last4 ?? hit.bankKeyword ?? ''}'
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
            keyword: c.keyword,
            outstanding: c.outstanding,
            creditLimit: c.creditLimit,
            availableLimit: c.availableLimit,
            isAvailableLimit: c.isAvailableLimit,
            isStatementBill: c.isStatementBill,
            dueDate: c.dueDate,
            minDue: c.minDue,
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
      upcomingObligations: upcomingObligations,
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
    r'(?:revised\s+total\s+due|outstanding\s*(?:balance|amount|dues)?|total\s*(?:due|outstanding)|'
    r'amount\s*due|bill\s*amount|payment\s*due|minimum\s*due|dues|'
    r'total\s+of|minimum\s+of|'
    r'bill\s+(?:of|for))'
    r'[^\d₹]*?(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)',
    caseSensitive: false,
  );

  static final RegExp _loanBalanceRe = RegExp(
    r'(?:loan\s*(?:account|balance|principal|outstanding)|'
    r'principal\s*(?:outstanding|balance)|emi\s*loan)'
    r'[^\d₹]*?(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)',
    caseSensitive: false,
  );

  // Credit card available limit detection: "Avl Limit: INR 82,933.13", "YOUR AVAILABLE LIMIT IS RS. 77755.88"
  static final RegExp _ccAvailableLimitRe = RegExp(
    r'(?:available\s*limit|avl\s*limit|avail(?:able)?\s*crd\s*lmt)[^\d₹]*?(?:inr|rs\.?)?\s*([\d,]+(?:\.\d+)?)',
    caseSensitive: false,
  );

  /// Credit card bill payment detection:
  /// - "Payment of Rs 10,000.00 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System"
  /// - "DEAR HDFCBANK CARDMEMBER, PAYMENT OF Rs. 2000.00 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 6366"
  /// - "Your payment of Rs 13.02 for your Edge CSB Bank RuPay Credit Card was successful"
  /// - "Payment towards your card was successful"
  static final RegExp _ccPaymentRe = RegExp(
    r'(?:'
    r'payment\s+(?:of\s+.*?)?(?:has\s+been\s+)?received\s+(?:on|towards)\s+.*?(?:credit\s*card|card\s*ending)|'
    r'payment\s+(?:of\s+.*?)?(?:towards|for)\s+.*?(?:credit\s*card|card\s*ending).*?(?:was\s+successful|received|processed|completed)|'
    r'payment\s+received\s+towards\s+your\s+credit\s+card|'
    r'received\s+on\s+your\s+(?:[A-Za-z0-9]+\s+)?credit\s+card|'
    r'payment\s+towards\s+credit\s+card\s+is\s+successful|'
    r'bill\s+payment\s+of\s+.*?(?:received|successful|credited\s+to\s+.*?(?:card|cc))'
    r')',
    caseSensitive: false,
  );

  /// Credit card refund detection:
  /// - "AMAZON PAY IN E COMMERC refund of Rs 189.00 credited to ICICI Bank Credit Card XX5007"
  /// - "refund of Rs X credited to ... Card"
  /// - "credited to your ... Card ... for reversal of transaction"
  static final RegExp _ccRefundRe = RegExp(
    r'(?:'
    r'refund\s+of\s+.*?(?:credited\s+to|received\s+on)\s+.*?(?:credit\s*card|card)|'
    r'credited\s+to\s+.*?(?:credit\s*card|card\s*ending).*?(?:refund|reversal)|'
    r'reversal\s+of\s+.*?(?:credited\s+to|card\s*ending)'
    r')',
    caseSensitive: false,
  );

  /// Returns true if text indicates a credit card bill payment confirmation.
  static bool _isCreditCardPaymentText(String lower, [String sender = '']) {
    if (_ccPaymentRe.hasMatch(lower)) return true;
    final hasCardSignal = lower.contains('credit card') ||
        lower.contains('card ending') ||
        lower.contains('cardmember') ||
        lower.contains('card xx') ||
        sender.toLowerCase().contains('crd') ||
        sender.toLowerCase().contains('jtedge');
    final hasPaymentSignal = lower.contains('payment') &&
        (lower.contains('received') || lower.contains('successful') || lower.contains('processed'));
    return hasCardSignal && hasPaymentSignal;
  }

  /// Returns true if text indicates a credit card refund or reversal.
  static bool _isCreditCardRefundText(String lower) {
    if (_ccRefundRe.hasMatch(lower)) return true;
    final hasCard = lower.contains('credit card') || lower.contains('card ending') || lower.contains('card xx');
    final hasRefund = lower.contains('refund') || lower.contains('reversal');
    final hasCredit = lower.contains('credited') || lower.contains('received');
    return hasCard && hasRefund && hasCredit;
  }

  /// Returns true if text indicates a genuine refund or reversal.
  /// Recognizes credit card refunds, wallet refunds, and bank account reversals.
  /// Rejects debits, ordinary income credits, and cashback.
  static bool _isRefundText(String lower) {
    if (_ccRefundRe.hasMatch(lower)) return true;

    final hasRefundTerm = lower.contains('refund') ||
        lower.contains('reversal') ||
        lower.contains('reversed');
    if (!hasRefundTerm) return false;

    // Must be a credit/receiving/processing signal
    final hasCreditSignal = lower.contains('credit') ||
        lower.contains('received') ||
        lower.contains('processed') ||
        lower.contains('reversed to') ||
        lower.contains('refunded to');

    // Reject if it's explicitly a debit / expense
    final hasDebitSignal = lower.contains('debited') ||
        lower.contains('paid to') ||
        lower.contains('spent on');

    return hasCreditSignal && !hasDebitSignal;
  }

  /// Returns true if text indicates a credit card bill statement or due date announcement.
  static bool _isCreditCardBillText(String lower) {
    final hasCardSignal = lower.contains('credit card') ||
        lower.contains('card ending') ||
        lower.contains('card xx') ||
        lower.contains('cardmember') ||
        lower.contains('crd') ||
        lower.contains('rupay');
    final hasBillSignal = _creditDueRe.hasMatch(lower) ||
        _ccAvailableLimitRe.hasMatch(lower) ||
        lower.contains('total due') ||
        lower.contains('amount due') ||
        lower.contains('minimum due') ||
        lower.contains('bill of rs') ||
        lower.contains('bill for rs') ||
        lower.contains('bill generated') ||
        lower.contains('statement has been generated') ||
        lower.contains('payable by');
    return hasCardSignal && hasBillSignal;
  }

  /// Returns true if text indicates an actual credit card spend transaction.
  static bool _isCardSpendCandidate(String lower) {
    if (lower.contains('debit card') || lower.contains('debit crd') || lower.contains('debit-card')) {
      return false;
    }
    final hasCardSignal = lower.contains('credit card') ||
        lower.contains('card ending') ||
        lower.contains('card xx') ||
        lower.contains('cardmember') ||
        lower.contains('jtedge') ||
        lower.contains('crd') ||
        lower.contains('rupay');
    final hasSpendVerb = RegExp(
      r'\b(?:spent|paid|charged|debited|used\s+for|transaction\s+of)\b',
      caseSensitive: false,
    ).hasMatch(lower);
    return hasCardSignal && hasSpendVerb;
  }

  // Digital wallet balance — Amazon Pay, Paytm Wallet, IRCTC RWallet, etc.
  static final RegExp _walletBalanceRe = RegExp(
    r'(?:updated\s*balance(?:\s*is)?|available\s*balance|'
    r'wallet\s*balance|current\s*balance)'
    r'[^\d₹]*?(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)',
    caseSensitive: false,
  );

  static final RegExp _last4Re = RegExp(
    r'(?:x+(\d{4,})|(?:a\/c|ac|acc|card|ending(?:\s+with)?)[\s:*\-]*(\d{4,}))',
    caseSensitive: false,
  );

  static final RegExp _otpAuthRe = RegExp(
    r'\b(?:otp|one[- ]time password|verification code|security code|secret code|login code|passcode|auth code|pin reset|reset.*pin|cvv)\b|'
    r'\b(?:is your otp|is the otp|use otp|enter otp|otp is|valid for \d+|never share|do not share|otps are secret)\b|'
    r'#\d{4,8}\b',
    caseSensitive: false,
  );

  static bool _isOtpOrAuth(String body) => _otpAuthRe.hasMatch(body);

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
    r'(?:increase|raise|raising|enhancing|enhancement)\s+(?:your\s+)?credit\s+limit|increas(?:e|ing) (?:the )?limit|limit.*(?:increas|rais)|'
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
    r'data usage|data quota|daily data|pack validity|recharge\s+(?:now|with|your|to|offer|pack|plan|due)\b|plan expir|'
    r'out for delivery|delivered|order placed|order confirmed|shipped|tracking id|courier|'
    r'feedback|survey|rate us|rate your|review us|'
    r'traded value|contract note|demat|depository|cdsl|nsdl|national stock exchange|bse ltd|'
    r'imd|ksdma|ndma|weather|forecast|thunderstorm|'
    r'റീചാർജ്|കാലഹരണപ്പെട്ടു|പ്ലാൻ|ജിയോ|ഡാറ്റ|ഫീഡ്‌ബാക്ക്|ഇടിമിന്നൽ|മഴ|കാറ്റ്|'
    r'report spam|TRAI DND',
    caseSensitive: false,
  );

  /// Known bank SMS sender patterns. Indian bank SMS typically come from
  /// shortcodes like "AD-FEDBNK-T", "VA-ICICIT-S", "JM-HDFCBK-P", etc.
  /// The format is `<3rdParty>-<BankCode>-<Type>` where Type is usually
  /// T (transactional), S (service), P (promotional).
  /// Some senders omit the trailing type letter (e.g. "JK-HDFCBK").
  static final RegExp _bankSenderRe = RegExp(
    r'^[A-Z]{2,4}-[A-Z0-9]{2,8}(?:-[A-Z])?$',
    caseSensitive: false,
  );

  static const _nonBankSenderPatterns = [
    'FLPKRT', 'SWIGGY', 'ZOMATO', 'DOMINO', 'JIOCAR', 'JIOVOC', 'JIOFIB',
    'AIRTEL', 'VODAFO', 'VI', 'BSNL', 'NETFLX', 'NDMAEW', 'NSETRA', 'MYNTRA',
    'BLINKT', 'ZEPTO', 'TATASKY', 'DTH', 'UBERIN', 'OLACAB', 'POLICY', 'SHADI',
  ];

  static const _financialSenderKeywords = [
    'HDFC', 'SBI', 'ICICI', 'AXIS', 'KOTAK', 'FEDBNK', 'JTEDGE', 'ONECRD',
    'BOBCRD', 'BOBONE', 'JIOPBS', 'PAYTM', 'QCAMZN', 'AMZPAY', 'JUSPAY',
    'CANBNK', 'PNBSMS', 'IDFC', 'INDUS', 'YESBK', 'YESBNK', 'UNIONB',
    'INDIANB', 'CENTBK', 'UCOBNK', 'IOB', 'KVB', 'CUB', 'SIBLTD',
    'KBL', 'TMB', 'BNDHAN', 'RBL', 'SCISMS', 'CITIBK', 'HSBC', 'STANBK',
    'AUBANK', 'AUCCB', 'EQUITAS', 'UJJIVAN', 'PAYU', 'RAZORP', 'EPFO',
    'BANK', 'BNK',
  ];

  /// Returns true if the sender looks like a bank SMS shortcode.
  static bool _isBankSender(String sender) {
    if (sender.isEmpty) return false;
    final upper = sender.toUpperCase().trim();
    if (!_bankSenderRe.hasMatch(upper)) return false;

    for (final pattern in _nonBankSenderPatterns) {
      if (upper.contains(pattern)) return false;
    }

    for (final kw in _financialSenderKeywords) {
      if (upper.contains(kw)) return true;
    }

    for (final key in bankNames.keys) {
      if (upper.contains(key.toUpperCase())) return true;
    }

    return false;
  }

  /// Returns true if the sender looks like a digital wallet SMS shortcode.
  static bool _isWalletSender(String sender) {
    if (sender.isEmpty) return false;
    final lower = sender.toLowerCase();
    return lower.contains('qcamzn') ||
        lower.contains('juspay') ||
        lower.contains('ipaytm') ||
        lower.contains('irsmsa');
  }

  /// UPI reference merchant: `UPI/DR/123456789012/MERCHANT`, `UPI/628001122334/UBER`, or `via UPI to MERCHANT`.
  static final RegExp _upiRefRe = RegExp(
    r'(?:UPI/(?:DR|CR|P2A|P2P|P2M)/\d+/|UPI/\d+/|(?:via\s+upi\s+to|upi\s+to)\s+)([A-Za-z0-9 .&/()@_-]+)',
    caseSensitive: false,
  );

  static final RegExp _dueDateRe = RegExp(
    r'(?:due\s*(?:date|on|by|for\s+(?:payment|renewal)\s+on)?|pay\s*(?:by|before)|payable\s*(?:by|on)|scheduled\s+on|before\s*due\s*date|of\s+inr[\d.]+\s+on)[^\w\d]*'
    r'([0-9]{4}[-\/.][0-9]{1,2}[-\/.][0-9]{1,2}|[0-9]{1,2}[-\/.][0-9]{1,2}[-\/.][0-9]{2,4}|[0-9]{1,2}[-\/\s](?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*[-\/\s]?[0-9]{0,4})',
    caseSensitive: false,
  );

  static DateTime? _extractDueDate(String body) {
    final m = _dueDateRe.firstMatch(body);
    if (m == null) return null;
    final rawDate = m.group(1)?.trim();
    if (rawDate == null || rawDate.isEmpty) return null;

    final now = DateTime.now();

    // 0. YYYY-MM-DD or YYYY/MM/DD
    final isoMatch = RegExp(r'^(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})$').firstMatch(rawDate);
    if (isoMatch != null) {
      final year = int.tryParse(isoMatch.group(1)!) ?? now.year;
      final month = int.tryParse(isoMatch.group(2)!) ?? 1;
      final day = int.tryParse(isoMatch.group(3)!) ?? 1;
      return DateTime(year, month, day);
    }

    // 1. DD/MM/YYYY or DD-MM-YYYY or DD.MM.YYYY
    final numMatch = RegExp(r'^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{2,4})$').firstMatch(rawDate);
    if (numMatch != null) {
      final day = int.tryParse(numMatch.group(1)!) ?? 1;
      final month = int.tryParse(numMatch.group(2)!) ?? 1;
      var year = int.tryParse(numMatch.group(3)!) ?? now.year;
      if (year < 100) year += 2000;
      return DateTime(year, month, day);
    }

    // 2. DD-MMM or DD-MMM-YYYY (e.g. 18-NOV-26 or 15-Nov)
    final textMatch = RegExp(r'^(\d{1,2})[-\/\s]([A-Za-z]{3,})[-\/\s]?(\d{2,4})?$').firstMatch(rawDate);
    if (textMatch != null) {
      final day = int.tryParse(textMatch.group(1)!) ?? 1;
      final monthStr = textMatch.group(2)!.toLowerCase().substring(0, 3);
      final months = {
        'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
        'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
      };
      final month = months[monthStr] ?? now.month;
      final yearGroup = textMatch.group(3);
      int year = now.year;
      if (yearGroup != null && yearGroup.isNotEmpty) {
        year = int.tryParse(yearGroup) ?? now.year;
        if (year < 100) year += 2000;
      } else {
        if (month < now.month) year += 1;
      }
      return DateTime(year, month, day);
    }

    return null;
  }

  static DateTime? _parseDateString(String rawDate, [DateTime? fallback]) {
    final now = fallback ?? DateTime.now();
    final isoMatch = RegExp(r'^(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})$').firstMatch(rawDate);
    if (isoMatch != null) {
      final year = int.tryParse(isoMatch.group(1)!) ?? now.year;
      final month = int.tryParse(isoMatch.group(2)!) ?? 1;
      final day = int.tryParse(isoMatch.group(3)!) ?? 1;
      return DateTime(year, month, day);
    }
    final numMatch = RegExp(r'^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{2,4})$').firstMatch(rawDate);
    if (numMatch != null) {
      final day = int.tryParse(numMatch.group(1)!) ?? 1;
      final month = int.tryParse(numMatch.group(2)!) ?? 1;
      var year = int.tryParse(numMatch.group(3)!) ?? now.year;
      if (year < 100) year += 2000;
      return DateTime(year, month, day);
    }
    return null;
  }

  static String _normalizeMerchantName(String raw) {
    final clean = raw.trim();
    final upper = clean.toUpperCase();
    if (upper == 'NETFLIX') return 'Netflix';
    if (upper == 'SPOTIFY') return 'Spotify';
    if (upper == 'YOUTUBE') return 'YouTube';
    if (upper.contains('GROWW')) return 'Groww Stocks SIP';
    if (upper.contains('ANOMALY')) return 'Anomaly';
    if (upper == 'AMAZON' || upper.startsWith('AMAZON ')) return 'Amazon';
    if (upper.contains('JIOHOME') || upper.contains('JIOFIB')) return 'JioHome';
    if (upper.contains('NIVA BUPA')) return 'Niva Bupa Health Insurance';
    if (clean.length > 2 && clean == clean.toUpperCase()) {
      return clean[0] + clean.substring(1).toLowerCase();
    }
    return clean;
  }

  static final RegExp _minDueRe = RegExp(
    r'(?:minimum\s*(?:amount\s*)?due|min\s*due)[^\d₹]*?(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)',
    caseSensitive: false,
  );

  static double? _extractMinDue(String body) {
    final m = _minDueRe.firstMatch(body);
    if (m == null) return null;
    return _parseAmount(m.group(1)!);
  }

  static final RegExp _totalLimitRe = RegExp(
    r'(?:total\s*(?:credit\s*)?limit|card\s*limit|credit\s*limit(?!\s*(?:to\s*rs|increase)))[^\d₹]*?(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)',
    caseSensitive: false,
  );

  static double? _extractTotalCreditLimit(String body) {
    final m = _totalLimitRe.firstMatch(body);
    if (m == null) return null;
    final val = _parseAmount(m.group(1)!);
    return val > 0 ? val : null;
  }

  /// Detects a balance statement in an SMS. Returns `null` when the message
  /// is (primarily) a transaction alert instead.
  BalanceHit? _detectBalance(String body, String sender) {
    final lower = body.toLowerCase();
    final bankKeyword = _bankKeyword(sender, lower);
    final isKnownBank = bankKeyword != null && bankNames.containsKey(bankKeyword);

    final hasExplicitCardMention = lower.contains('credit card') ||
        lower.contains('card ending') ||
        lower.contains('card xx') ||
        lower.contains('cardmember') ||
        _ccAvailableLimitRe.hasMatch(lower) ||
        _ccPaymentRe.hasMatch(lower) ||
        lower.contains('rupay credit') ||
        sender.toLowerCase().contains('crd') ||
        sender.toLowerCase().contains('jtedge');

    final ccIssuers = {
      'icicib', 'icicit', 'icici',
      'hdfc', 'hdfcbk', 'hdfcbn',
      'axisbk', 'axsbk', 'axns',
      'sbicrd', 'sbiinb', 'cbssbi', 'sbi',
      'bobcard', 'bobcrd', 'bob', 'onecrd', 'jtedge', 'auccb', 'aubnk', 'aubank',
      'kotak', 'kotakb', 'idfcfb', 'idfc', 'indus', 'rbl', 'yesbk', 'yesbank',
      'fedbnk', 'csb', 'canbnk', 'pnb', 'scisms', 'stanbk', 'citibk', 'hsbc',
    };
    final skipCreditCard = !hasExplicitCardMention && isKnownBank && !ccIssuers.contains(bankKeyword);

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

    // Credit card outstanding or available limit — check BEFORE bank balance
    if (!skipCreditCard) {
      if (_creditDueRe.hasMatch(lower)) {
        final m = _creditDueRe.firstMatch(body);
        if (m != null) {
          final amount = _parseAmount(m.group(1)!);
          if (amount >= 0) {
            final isStatementBill = lower.contains('bill') ||
                lower.contains('statement') ||
                lower.contains('due date') ||
                lower.contains('total due') ||
                lower.contains('amount due') ||
                lower.contains('payable by');
            return BalanceHit(
              kind: BalanceKind.creditCard,
              amount: amount,
              last4: _last4(body),
              bankKeyword: bankKeyword,
              sender: sender,
              body: body,
              dueDate: _extractDueDate(body),
              minDue: _extractMinDue(body),
              creditLimit: _extractTotalCreditLimit(body),
              isStatementBill: isStatementBill,
            );
          }
        }
      }

      // Check for available limit notification: "Avl Limit: INR 82,933.13" / "YOUR AVAILABLE LIMIT IS RS. 77755.88"
      if (_ccAvailableLimitRe.hasMatch(lower)) {
        final m = _ccAvailableLimitRe.firstMatch(body);
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
              isAvailableLimit: true,
              dueDate: _extractDueDate(body),
              minDue: _extractMinDue(body),
              creditLimit: _extractTotalCreditLimit(body),
            );
          }
        }
      }
    }

    // Digital wallet balance — check BEFORE bank balance because wallet SMS
    // also contain "balance" which would falsely match the bank pattern.
    if (_isWalletSender(sender) || _walletBalanceRe.hasMatch(lower)) {
      final m = _walletBalanceRe.firstMatch(body);
      if (m != null) {
        final amount = _parseAmount(m.group(1)!);
        if (amount > 0) {
          return BalanceHit(
            kind: BalanceKind.wallet,
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
      if (amount > 0 &&
          (bankKeyword != null || _last4(body) != null || _isBankSender(sender))) {
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

  /// Detects an upcoming financial obligation (e-mandate, autopay, utility bill due, insurance renewal).
  UpcomingObligationHit? detectUpcomingObligation(
    String body,
    String sender, {
    DateTime? smsDate,
  }) {
    // 0. Hard reject OTPs or cancellations/revocations
    if (_isOtpOrAuth(body)) return null;
    final lower = body.toLowerCase();
    if (lower.contains('revoked') ||
        lower.contains('successfully revok') ||
        lower.contains('cancelled') ||
        lower.contains('canceled') ||
        lower.contains('unsuccessful') ||
        lower.contains('failed')) {
      return null;
    }

    // 1. OneCard / Card E-Mandate Upcoming Debit:
    // e.g. "Hi Sivek, you have an upcoming debit for the emandate registered on NETFLIX of INR199.0 on 30/10/2026."
    final emandateMatch = RegExp(
      r'upcoming\s+debit\s+for\s+(?:the\s+)?e?mandate\s+registered\s+on\s+([A-Za-z0-9 .&_-]+?)\s+of\s+(?:inr|rs\.?)\s*([\d,]+(?:\.\d+)?)\s+on\s+([0-9]{1,2}[-\/.][0-9]{1,2}[-\/.][0-9]{2,4})',
      caseSensitive: false,
    ).firstMatch(body);
    if (emandateMatch != null) {
      final merchant = emandateMatch.group(1)!.trim();
      final amount = _parseAmount(emandateMatch.group(2)!);
      final rawDate = emandateMatch.group(3)!;
      final dueDate = _parseDateString(rawDate) ?? smsDate ?? DateTime.now();
      final normalizedMerchant = _normalizeMerchantName(merchant);
      return UpcomingObligationHit(
        title: '$normalizedMerchant Subscription',
        amount: amount,
        dueDate: dueDate,
        merchant: normalizedMerchant,
        last4: _last4(body),
        bankKeyword: _bankKeyword(sender, lower),
        reminderType: ReminderType.service,
        isMandate: true,
        sender: sender,
        body: body,
        smsDate: smsDate,
      );
    }

    // 2. UPI AutoPay / SIP Scheduled Debit:
    // e.g. "Dear UPI User, UPI AutoPay for GROWW INVEST TECH PRIVATE LIMITED STOCKS SIP debit of Rs.1100.00 is scheduled on .11/10/26"
    final autopayMatch = RegExp(
      r'upi\s*autopay\s+for\s+([A-Za-z0-9 .&_-]+?)(?:\s+debit)?\s+of\s+(?:rs\.?|inr)\s*([\d,]+(?:\.\d+)?)\s+is\s+scheduled\s+on\s*\.?([0-9]{1,2}[-\/.][0-9]{1,2}[-\/.][0-9]{2,4})',
      caseSensitive: false,
    ).firstMatch(body);
    if (autopayMatch != null) {
      final merchant = autopayMatch.group(1)!.trim();
      final amount = _parseAmount(autopayMatch.group(2)!);
      final rawDate = autopayMatch.group(3)!;
      final dueDate = _parseDateString(rawDate) ?? smsDate ?? DateTime.now();
      final normalizedMerchant = _normalizeMerchantName(merchant);
      final title = normalizedMerchant.toLowerCase().contains('sip')
          ? normalizedMerchant
          : '$normalizedMerchant AutoPay';
      return UpcomingObligationHit(
        title: title,
        amount: amount,
        dueDate: dueDate,
        merchant: normalizedMerchant,
        last4: _last4(body),
        bankKeyword: _bankKeyword(sender, lower),
        reminderType: ReminderType.service,
        isMandate: true,
        sender: sender,
        body: body,
        smsDate: smsDate,
      );
    }

    // 3. Card Standing Instruction:
    // e.g. "Payment of INR 799.00 towards Merchant Amazon to be debited from ICICI Bank Credit Card 5007, as per Standing Instruction Xu1DUr0BJS, is due by 24/06/2026."
    final siMatch = RegExp(
      r'payment\s+of\s+(?:inr|rs\.?)\s*([\d,]+(?:\.\d+)?)\s+towards\s+(?:merchant\s+)?(.+?)\s+to\s+be\s+debited.*?(?:due\s+by|on)\s+([0-9]{1,2}[-\/.][0-9]{1,2}[-\/.][0-9]{2,4})',
      caseSensitive: false,
    ).firstMatch(body);
    if (siMatch != null) {
      final amount = _parseAmount(siMatch.group(1)!);
      final merchant = siMatch.group(2)!.trim();
      final rawDate = siMatch.group(3)!;
      final dueDate = _parseDateString(rawDate) ?? smsDate ?? DateTime.now();
      final normalizedMerchant = _normalizeMerchantName(merchant);
      return UpcomingObligationHit(
        title: '$normalizedMerchant Subscription',
        amount: amount,
        dueDate: dueDate,
        merchant: normalizedMerchant,
        last4: _last4(body),
        bankKeyword: _bankKeyword(sender, lower),
        reminderType: ReminderType.service,
        isMandate: true,
        sender: sender,
        body: body,
        smsDate: smsDate,
      );
    }

    // 4. Utility / Broadband Bill Due:
    // e.g. "Bill dated 21-Oct-26 for your JioHome connection with JioFixedVoice Number ... is due for payment today. Total amount payable is Rs. 706.82."
    // e.g. "Your bill dated 21-10-2026 for JioHome connection... is due for payment on 27-10-2026 . Total amount payable: Rs. 706.82"
    final isUtilitySignal = lower.contains('jiohome') ||
        lower.contains('jiofiber') ||
        lower.contains('jiofixedvoice') ||
        lower.contains('broadband') ||
        lower.contains('electricity') ||
        lower.contains('water bill') ||
        sender.toLowerCase().contains('jiofib') ||
        sender.toLowerCase().contains('jioinf') ||
        sender.toLowerCase().contains('airtel');
    final isBillDueSignal = lower.contains('due for payment') ||
        lower.contains('payment due date') ||
        lower.contains('due today') ||
        lower.contains('bill is due');

    if (isUtilitySignal && isBillDueSignal) {
      final payableMatch = RegExp(
        r'(?:total\s*(?:amount\s*)?payable|amount\s*payable|total\s*due|bill\s*amount)[^\d₹]*?(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)',
        caseSensitive: false,
      ).firstMatch(body);
      if (payableMatch != null) {
        final amount = _parseAmount(payableMatch.group(1)!);
        if (amount > 0) {
          DateTime? dueDate;
          if (lower.contains('due for payment today') || lower.contains('due today')) {
            dueDate = smsDate ?? DateTime.now();
          } else {
            dueDate = _extractDueDate(body) ?? smsDate ?? DateTime.now();
          }
          final serviceName = lower.contains('jio')
              ? 'JioHome'
              : (lower.contains('airtel') ? 'Airtel Broadband' : 'Utility');
          return UpcomingObligationHit(
            title: '$serviceName Bill',
            amount: amount,
            dueDate: dueDate,
            merchant: serviceName,
            reminderType: ReminderType.service,
            isMandate: false,
            sender: sender,
            body: body,
            smsDate: smsDate,
          );
        }
      }
    }

    // 5. Insurance Renewal Notice:
    // e.g. "Dear Customer, your Niva Bupa Health Insurance Policy No. 34419958202501 is due for renewal on 07/11/2026."
    // e.g. "Hi Sivek, Your Niva Bupa policy renewal is due. ... Renew today with a premium of Rs.7,497 at ..."
    if (lower.contains('due for renewal') || lower.contains('policy renewal is due')) {
      final dueDate = _extractDueDate(body) ?? smsDate ?? DateTime.now();
      final premMatch = RegExp(
        r'premium\s+of\s+(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)',
        caseSensitive: false,
      ).firstMatch(body);
      final amount = premMatch != null ? _parseAmount(premMatch.group(1)!) : 0.0;
      final insurer = lower.contains('niva bupa')
          ? 'Niva Bupa Health Insurance'
          : (lower.contains('star health') ? 'Star Health Insurance' : 'Insurance Policy');
      return UpcomingObligationHit(
        title: '$insurer Renewal',
        amount: amount,
        dueDate: dueDate,
        merchant: insurer,
        reminderType: ReminderType.insurance,
        isMandate: false,
        sender: sender,
        body: body,
        smsDate: smsDate,
      );
    }

    // 6. Standalone Credit Card Bill Due (e.g. Tata Neu):
    // e.g. "Your HDFC Credit Card bill of Rs.25000.00 is due on 2026-10-21. Pay by 2026-10-21 to avoid late charges"
    final ccBillMatch = RegExp(
      r'([A-Za-z0-9]+)\s+credit\s+card\s+bill\s+of\s+(?:rs\.?|inr)?\s*([\d,]+(?:\.\d+)?)\s+is\s+due\s+on\s+([0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}[-\/.][0-9]{1,2}[-\/.][0-9]{2,4})',
      caseSensitive: false,
    ).firstMatch(body);
    if (ccBillMatch != null) {
      final bank = ccBillMatch.group(1)!.trim();
      final amount = _parseAmount(ccBillMatch.group(2)!);
      final rawDate = ccBillMatch.group(3)!;
      final dueDate = _parseDateString(rawDate) ?? smsDate ?? DateTime.now();
      return UpcomingObligationHit(
        title: '$bank Credit Card Bill',
        amount: amount,
        dueDate: dueDate,
        merchant: '$bank Credit Card',
        bankKeyword: bank.toLowerCase(),
        reminderType: ReminderType.credit,
        isMandate: false,
        sender: sender,
        body: body,
        smsDate: smsDate,
      );
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
    for (final bank in ['hdfc', 'axis', 'icici', 'sbi', 'kotak', 'yes bank', 'bobcard', 'onecard', 'au bank', 'idfc', 'indusind', 'canara', 'bob']) {
      if (lower.contains(bank)) return bank.replaceAll(' ', '');
    }
    return null;
  }

  static const bankNames = <String, String>{
    'cbssbi': 'State Bank of India',
    'sbiinb': 'State Bank of India',
    'sbi': 'State Bank of India',
    'sbicrd': 'SBI Cards',
    'fedbnk': 'Federal Bank',
    'axsbk': 'Axis Bank',
    'axisbk': 'Axis Bank',
    'axns': 'Axis Bank',
    'icicib': 'ICICI Bank',
    'icicit': 'ICICI Bank',
    'icici': 'ICICI Bank',
    'hdfcbk': 'HDFC Bank',
    'hdfcbn': 'HDFC Bank',
    'hdfc': 'HDFC Bank',
    'kotakb': 'Kotak Mahindra Bank',
    'kotak': 'Kotak Mahindra Bank',
    'jiopbs': 'Jio Payments Bank',
    'jiofbr': 'Jio Payments Bank',
    'onecrd': 'OneCard (BOBCARD)',
    'onecard': 'OneCard (BOBCARD)',
    'bobcrd': 'BOBCARD',
    'csb': 'CSB Bank',
    'jtedge': 'Jupiter (CSB Bank)',
    'yesbk': 'YES Bank',
    'yesbank': 'YES Bank',
    'pnb': 'Punjab National Bank',
    'idbib': 'IDBI Bank',
    'idfcfb': 'IDFC First Bank',
    'indus': 'IndusInd Bank',
    'aubnk': 'AU Small Finance Bank',
    'aubank': 'AU Small Finance Bank',
    'canbnk': 'Canara Bank',
    'bob': 'Bank of Baroda',
    'union': 'Union Bank of India',
    'indbnk': 'Indian Bank',
    'cbin': 'Central Bank of India',
    'psb': 'Punjab & Sind Bank',
    'uco': 'UCO Bank',
    'iob': 'Indian Overseas Bank',
    'kvb': 'Karur Vysya Bank',
    'cub': 'City Union Bank',
    'sib': 'South Indian Bank',
    'kbl': 'Karnataka Bank',
    'tmb': 'Tamilnad Mercantile Bank',
    'bandhan': 'Bandhan Bank',
    // Digital wallets
    'qcamzn': 'Amazon Pay',
    'juspay': 'Amazon Pay',
    'ipaytm': 'Paytm Wallet',
    'irsmsa': 'IRCTC Wallet',
    // Other accounts
    'prajin': 'Pension Savings (PMSY)',
  };

  String bankDisplayName(String? code) {
    if (code == null) return 'Bank';
    return bankNames[code] ?? code.toUpperCase();
  }

  String _bankDisplayName(String? code) => bankDisplayName(code);

  String? _last4(String body) {
    final m = _last4Re.firstMatch(body);
    if (m == null) return null;
    final digits = m.group(1) ?? m.group(2);
    if (digits == null) return null;
    return digits.length > 4 ? digits.substring(digits.length - 4) : digits;
  }

  static double _parseAmount(String raw) {
    return double.tryParse(raw.replaceAll(',', '')) ?? 0;
  }
}