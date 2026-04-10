import 'dart:convert';

/// The kind of SMS transaction detected.
enum SmsKind {
  bankDebit,       // Regular bank account debit
  bankCredit,      // Regular bank account credit
  creditCardSpend, // Credit card purchase
  creditCardPayment, // Credit card bill payment
  upiSend,         // UPI money sent
  upiReceive,      // UPI money received
  loanEmi,         // Loan EMI deduction
  transfer,        // Self/inter-account transfer
  atm,             // ATM withdrawal
  refund,          // Refund/reversal
  unknown,
}

class ParsedSms {
  final double amount;
  final bool isCredit;
  final String sender;
  final String body;
  final DateTime date;
  final String? merchant;
  final String? vpa;
  final String? refId;
  final String? last4;
  final SmsKind kind;

  /// Post-transaction balance if present in SMS.
  final double? balance;

  /// Detected bank name (e.g., "HDFC", "SBI", "ICICI").
  final String? bankName;

  /// Confidence score 0.0-1.0 indicating parse quality.
  /// >= 0.70 -> auto-insert, < 0.70 -> review queue.
  final double confidence;

  const ParsedSms({
    required this.amount,
    required this.isCredit,
    required this.sender,
    required this.body,
    required this.date,
    this.merchant,
    this.vpa,
    this.refId,
    this.last4,
    this.kind = SmsKind.unknown,
    this.balance,
    this.bankName,
    this.confidence = 0.0,
  });

  ParsedSms copyWith({
    double? amount,
    bool? isCredit,
    String? sender,
    String? body,
    DateTime? date,
    String? merchant,
    String? vpa,
    String? refId,
    String? last4,
    SmsKind? kind,
    double? balance,
    String? bankName,
    double? confidence,
  }) {
    return ParsedSms(
      amount: amount ?? this.amount,
      isCredit: isCredit ?? this.isCredit,
      sender: sender ?? this.sender,
      body: body ?? this.body,
      date: date ?? this.date,
      merchant: merchant ?? this.merchant,
      vpa: vpa ?? this.vpa,
      refId: refId ?? this.refId,
      last4: last4 ?? this.last4,
      kind: kind ?? this.kind,
      balance: balance ?? this.balance,
      bankName: bankName ?? this.bankName,
      confidence: confidence ?? this.confidence,
    );
  }

  /// Whether this SMS was parsed with high enough confidence for auto-insert.
  bool get isHighConfidence => confidence >= 0.70;

  /// Whether this is a debit (expense-like) transaction.
  bool get isDebit => !isCredit;

  /// Transaction type string for the Transaction model.
  String get transactionType => isCredit ? 'income' : 'expense';

  /// Serialize to JSON for review queue storage.
  Map<String, dynamic> toMap() => {
    'amount': amount,
    'isCredit': isCredit,
    'sender': sender,
    'body': body,
    'date': date.toIso8601String(),
    'merchant': merchant,
    'vpa': vpa,
    'refId': refId,
    'last4': last4,
    'kind': kind.name,
    'balance': balance,
    'bankName': bankName,
    'confidence': confidence,
  };

  factory ParsedSms.fromMap(Map<String, dynamic> map) => ParsedSms(
    amount: (map['amount'] as num).toDouble(),
    isCredit: map['isCredit'] as bool,
    sender: map['sender'] as String,
    body: map['body'] as String,
    date: DateTime.parse(map['date'] as String),
    merchant: map['merchant'] as String?,
    vpa: map['vpa'] as String?,
    refId: map['refId'] as String?,
    last4: map['last4'] as String?,
    kind: SmsKind.values.firstWhere(
      (e) => e.name == (map['kind'] as String?),
      orElse: () => SmsKind.unknown,
    ),
    balance: (map['balance'] as num?)?.toDouble(),
    bankName: map['bankName'] as String?,
    confidence: (map['confidence'] as num?)?.toDouble() ?? 0.0,
  );

  String toJson() => jsonEncode(toMap());
  factory ParsedSms.fromJson(String json) =>
      ParsedSms.fromMap(jsonDecode(json) as Map<String, dynamic>);
}
