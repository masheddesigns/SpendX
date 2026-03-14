class TransactionModel {
  final String id;
  final double amount;
  final String category;

  TransactionModel({
    required this.id,
    required this.amount,
    required this.category,
  });

  factory TransactionModel.fromJson(Map<String, dynamic> json) {
    return TransactionModel(
      id: json['id'],
      amount: json['amount'],
      category: json['category'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'amount': amount,
      'category': category,
    };
  }
}