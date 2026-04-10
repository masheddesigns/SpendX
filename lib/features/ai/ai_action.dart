import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/accounts/providers/account_providers.dart';
import '../../features/categories/providers/category_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../../models/bank_account.dart';
import '../../models/category.dart';
import '../../models/transaction.dart';
import '../../utils/app_format.dart';

// ── Action Model ─────────────────────────────────────────────────────────

enum AIActionType {
  addExpense,
  addIncome,
  unknown,
}

/// A parsed, validated action ready for user confirmation.
class AIAction {
  final AIActionType type;
  final double amount;
  final String? categoryName;
  final String? categoryId;
  final String? accountId;
  final String? accountName;
  final String? note;

  const AIAction({
    required this.type,
    required this.amount,
    this.categoryName,
    this.categoryId,
    this.accountId,
    this.accountName,
    this.note,
  });

  /// Human-readable confirmation message.
  String get confirmationText {
    final typeLabel = type == AIActionType.addIncome ? 'income' : 'expense';
    final catLabel = categoryName ?? 'Uncategorized';
    final accLabel = accountName != null ? ' from $accountName' : '';
    return 'Add ${AppFormat.currency(amount)} $typeLabel to $catLabel$accLabel?';
  }
}

// ── Action Parser (Rule-Based) ───────────────────────────────────────────

// Amount patterns: ₹500, Rs.500, Rs 500, 500, INR 500
final _amountRegex = RegExp(
  r'(?:₹|rs\.?|inr)?\s?(\d[\d,]*(?:\.\d{1,2})?)',
  caseSensitive: false,
);

// Expense triggers
final _expenseTriggers = RegExp(
  r'^(?:add|log|spent|spend|paid|bought|expense)',
  caseSensitive: false,
);

// Income triggers
final _incomeTriggers = RegExp(
  r'^(?:received|got|earned|salary|income|credited)',
  caseSensitive: false,
);

/// Try to parse a chat message into an AIAction.
/// Returns null if the message doesn't look like an action command.
AIAction? tryParseAction({
  required String input,
  required List<Category> categories,
  required List<BankAccount> accounts,
}) {
  final lower = input.toLowerCase().trim();

  // Must match an action trigger
  final isExpense = _expenseTriggers.hasMatch(lower);
  final isIncome = _incomeTriggers.hasMatch(lower);
  if (!isExpense && !isIncome) return null;

  // Must have an amount
  final amountMatch = _amountRegex.firstMatch(lower);
  if (amountMatch == null) return null;

  final raw = amountMatch.group(1)!.replaceAll(',', '');
  final amount = double.tryParse(raw);
  if (amount == null || amount <= 0) return null;

  final type = isIncome ? AIActionType.addIncome : AIActionType.addExpense;

  // Try to extract category from remaining text
  // Remove the amount and trigger words, what's left is likely the category
  var remaining = lower
      .replaceFirst(_expenseTriggers, '')
      .replaceFirst(_incomeTriggers, '')
      .replaceFirst(_amountRegex, '')
      .replaceAll(RegExp(r'[₹]'), '')
      .replaceAll(RegExp(r'\b(for|on|to|at|from|of|in|as)\b'), '')
      .trim();

  // Match against known categories
  String? categoryId;
  String? categoryName;
  final txType = type == AIActionType.addIncome ? 'income' : 'expense';

  if (remaining.isNotEmpty) {
    // Exact name match first
    for (final cat in categories) {
      if (cat.type == txType &&
          cat.name.toLowerCase() == remaining.toLowerCase()) {
        categoryId = cat.id;
        categoryName = cat.name;
        break;
      }
    }
    // Contains match
    if (categoryId == null) {
      for (final cat in categories) {
        if (cat.type == txType &&
            (cat.name.toLowerCase().contains(remaining) ||
             remaining.contains(cat.name.toLowerCase()))) {
          categoryId = cat.id;
          categoryName = cat.name;
          break;
        }
      }
    }
    // Use remaining text as note if no category matched
    if (categoryId == null && remaining.length >= 2) {
      categoryName = remaining[0].toUpperCase() + remaining.substring(1);
    }
  }

  // Default account: first asset account
  String? accountId;
  String? accountName;
  if (accounts.isNotEmpty) {
    final primary = accounts.firstWhere(
      (a) => a.isAsset,
      orElse: () => accounts.first,
    );
    accountId = primary.id;
    accountName = primary.name;
  }

  return AIAction(
    type: type,
    amount: amount,
    categoryId: categoryId,
    categoryName: categoryName,
    accountId: accountId,
    accountName: accountName,
    note: categoryName ?? (remaining.isNotEmpty ? remaining : null),
  );
}

// ── Action Executor ──────────────────────────────────────────────────────

/// Execute a confirmed AI action. Returns a success message.
/// ONLY call after user confirms. Never auto-execute.
/// Accepts either Ref or WidgetRef since both support .read().
Future<String> executeAction(AIAction action, dynamic ref) async {
  final txType = action.type == AIActionType.addIncome ? 'income' : 'expense';

  final transaction = Transaction(
    userId: 'offline_user',
    type: txType,
    amount: action.amount,
    date: DateTime.now(),
    notes: action.note ?? 'Added via AI',
    categoryId: action.categoryId,
    accountId: action.accountId,
    source: 'ai_action',
  );

  await ref.read(addTransactionProvider)(transaction);

  final catLabel = action.categoryName ?? 'Uncategorized';
  return 'Done! ${AppFormat.currency(action.amount)} $txType added to $catLabel.';
}

// ── Provider for Action Parsing ──────────────────────────────────────────

/// Tries to parse user input as an action. Returns the parsed AIAction
/// (for confirmation) or null (falls through to query handling).
final parseAIActionProvider = Provider((ref) {
  return (String input) {
    final categories = ref.read(categoriesProvider).valueOrNull ?? [];
    final accounts = ref.read(accountsProvider).valueOrNull ?? [];
    return tryParseAction(
      input: input,
      categories: categories,
      accounts: accounts,
    );
  };
});
