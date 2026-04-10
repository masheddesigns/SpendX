class CardStatement {
  final String id;
  final String cardId;
  final DateTime startDate;
  final DateTime endDate;
  final double statementAmount;
  final double minimumDue;
  final DateTime generatedDate;

  CardStatement({
    required this.id,
    required this.cardId,
    required this.startDate,
    required this.endDate,
    required this.statementAmount,
    required this.minimumDue,
    required this.generatedDate,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'cardId': cardId,
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
      'statementAmount': statementAmount,
      'minimumDue': minimumDue,
      'generatedDate': generatedDate.toIso8601String(),
    };
  }

  factory CardStatement.fromMap(Map<String, dynamic> map) {
    return CardStatement(
      id: map['id'],
      cardId: map['cardId'],
      startDate: DateTime.parse(map['startDate']),
      endDate: DateTime.parse(map['endDate']),
      statementAmount: (map['statementAmount'] as num).toDouble(),
      minimumDue: (map['minimumDue'] as num).toDouble(),
      generatedDate: DateTime.parse(map['generatedDate']),
    );
  }
}
