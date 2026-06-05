import 'dart:convert';

import 'package:uuid/uuid.dart';

/// A parsed transaction candidate waiting for user review before insertion.
///
/// Source-agnostic: works for OCR (screenshots), shared text (payment apps),
/// CSV imports, or any future ingestion path. The original raw input lives
/// in [rawSource] for context; structured fields live in [parsed].
class ReviewItem {
  final String id;
  final String rawSource;
  final ParsedTransaction parsed;
  final double confidence;
  final String status; // 'pending', 'approved', 'rejected'
  final DateTime createdAt;

  ReviewItem({
    String? id,
    required this.rawSource,
    required this.parsed,
    required this.confidence,
    this.status = 'pending',
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        // Keep DB column name as `raw_sms` for backward compatibility —
        // the column stores raw source text regardless of origin.
        'raw_sms': rawSource,
        'parsed_json': parsed.toJson(),
        'confidence': confidence,
        'status': status,
        'created_at': createdAt.toIso8601String(),
      };

  factory ReviewItem.fromMap(Map<String, dynamic> map) => ReviewItem(
        id: map['id'] as String,
        rawSource: map['raw_sms'] as String,
        parsed: ParsedTransaction.fromJson(map['parsed_json'] as String),
        confidence: (map['confidence'] as num).toDouble(),
        status: map['status'] as String? ?? 'pending',
        createdAt: DateTime.parse(map['created_at'] as String),
      );

  ReviewItem copyWith({String? status}) => ReviewItem(
        id: id,
        rawSource: rawSource,
        parsed: parsed,
        confidence: confidence,
        status: status ?? this.status,
        createdAt: createdAt,
      );
}

/// Generic parsed transaction — source-agnostic.
///
/// Replaces the SMS-specific `ParsedSms` model. Holds only fields that are
/// universal across ingestion paths (OCR, shared text, manual paste, etc.).
class ParsedTransaction {
  final double amount;
  final bool isCredit;
  final String rawText;
  final DateTime date;
  final String? merchant;
  final String? refId;
  final String? last4;
  final String? bankName;
  final String? method; // 'upi' | 'card' | 'bank' | 'cash' | null
  final String? source; // 'share' | 'ocr' | 'paste' | 'csv' etc.
  final double confidence;

  /// How the merchant was extracted (UI uses this for trust signals):
  ///   - 'keyword'  → strong signal ("paid to X", "received from X")
  ///   - 'fallback' → weaker pattern match
  ///   - null       → not extracted
  final String? merchantSource;

  /// True if a debit/credit keyword was found in the text. UI uses this
  /// to mark the type field as confident vs guessed.
  final bool hasDirectionSignal;

  const ParsedTransaction({
    required this.amount,
    required this.isCredit,
    required this.rawText,
    required this.date,
    this.merchant,
    this.refId,
    this.last4,
    this.bankName,
    this.method,
    this.source,
    this.confidence = 0.0,
    this.merchantSource,
    this.hasDirectionSignal = false,
  });

  String get transactionType => isCredit ? 'income' : 'expense';
  bool get isHighConfidence => confidence >= 0.70;

  Map<String, dynamic> toMap() => {
        'amount': amount,
        'isCredit': isCredit,
        'rawText': rawText,
        'date': date.toIso8601String(),
        'merchant': merchant,
        'refId': refId,
        'last4': last4,
        'bankName': bankName,
        'method': method,
        'source': source,
        'confidence': confidence,
        'merchantSource': merchantSource,
        'hasDirectionSignal': hasDirectionSignal,
      };

  factory ParsedTransaction.fromMap(Map<String, dynamic> map) =>
      ParsedTransaction(
        amount: (map['amount'] as num).toDouble(),
        isCredit: map['isCredit'] as bool,
        rawText: map['rawText'] as String? ?? map['body'] as String? ?? '',
        date: DateTime.parse(map['date'] as String),
        merchant: map['merchant'] as String?,
        refId: map['refId'] as String?,
        last4: map['last4'] as String?,
        bankName: map['bankName'] as String?,
        method: map['method'] as String?,
        source: map['source'] as String?,
        confidence: (map['confidence'] as num?)?.toDouble() ?? 0.0,
        merchantSource: map['merchantSource'] as String?,
        hasDirectionSignal: map['hasDirectionSignal'] as bool? ?? false,
      );

  String toJson() => jsonEncode(toMap());
  factory ParsedTransaction.fromJson(String json) =>
      ParsedTransaction.fromMap(jsonDecode(json) as Map<String, dynamic>);
}
