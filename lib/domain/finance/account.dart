import 'account_type.dart';

/// Immutable canonical account identity in SpendX 2.0.
///
/// CRITICAL ARCHITECTURAL INVARIANT:
/// An [Account] entity NEVER contains a mutable balance field.
/// Account balance is strictly a derived fact calculated by summing
/// immutable ledger postings in the canonical postings table.
class Account {
  /// Unique identifier of the account (UUID or deterministic synthetic ID).
  final String id;

  /// User-facing display name of the account (e.g., 'HDFC Savings', 'Groceries').
  final String name;

  /// Fundamental double-entry accounting category.
  final AccountType type;

  /// Optional hierarchical parent account ID (for sub-accounts or nested categories).
  final String? parentAccountId;

  /// Account sub-classification or domain category
  /// (e.g., 'bank', 'cash', 'credit_card', 'loan', 'salary', 'groceries').
  final String? category;

  /// Primary currency for this account. Defaults to 'INR'.
  final String currency;

  /// Whether the account is currently active or archived/hidden.
  final bool isActive;

  /// When this account record was created.
  final DateTime createdAt;

  /// When this account record was last modified.
  final DateTime updatedAt;

  const Account({
    required this.id,
    required this.name,
    required this.type,
    this.parentAccountId,
    this.category,
    this.currency = 'INR',
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Creates a copy of this account with updated fields.
  Account copyWith({
    String? name,
    AccountType? type,
    String? parentAccountId,
    String? category,
    String? currency,
    bool? isActive,
    DateTime? updatedAt,
  }) {
    return Account(
      id: id,
      name: name ?? this.name,
      type: type ?? this.type,
      parentAccountId: parentAccountId ?? this.parentAccountId,
      category: category ?? this.category,
      currency: currency ?? this.currency,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Account &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          type == other.type &&
          parentAccountId == other.parentAccountId &&
          category == other.category &&
          currency == other.currency &&
          isActive == other.isActive;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        type,
        parentAccountId,
        category,
        currency,
        isActive,
      );

  @override
  String toString() =>
      'Account(id: $id, name: $name, type: ${type.name}, category: $category, active: $isActive)';
}
