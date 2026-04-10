import 'package:uuid/uuid.dart';
import '../features/sms/models/parsed_sms.dart';

/// An SMS transaction waiting for user review before insertion.
class ReviewItem {
  final String id;
  final String rawSms;
  final ParsedSms parsed;
  final double confidence;
  final String status; // 'pending', 'approved', 'rejected'
  final DateTime createdAt;

  ReviewItem({
    String? id,
    required this.rawSms,
    required this.parsed,
    required this.confidence,
    this.status = 'pending',
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'raw_sms': rawSms,
    'parsed_json': parsed.toJson(),
    'confidence': confidence,
    'status': status,
    'created_at': createdAt.toIso8601String(),
  };

  factory ReviewItem.fromMap(Map<String, dynamic> map) => ReviewItem(
    id: map['id'] as String,
    rawSms: map['raw_sms'] as String,
    parsed: ParsedSms.fromJson(map['parsed_json'] as String),
    confidence: (map['confidence'] as num).toDouble(),
    status: map['status'] as String? ?? 'pending',
    createdAt: DateTime.parse(map['created_at'] as String),
  );

  ReviewItem copyWith({String? status}) => ReviewItem(
    id: id,
    rawSms: rawSms,
    parsed: parsed,
    confidence: confidence,
    status: status ?? this.status,
    createdAt: createdAt,
  );
}
