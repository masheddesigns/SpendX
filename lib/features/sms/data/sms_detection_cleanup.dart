import '../../../data/core/app_database.dart';
import '../../../data/core/tables.dart';
import '../../../models/bank_account.dart';
import '../../../models/credit_card.dart';

class SmsDetectionCleanupResult {
  final int renamedAccounts;
  final int renamedCards;
  final int removedDuplicateAccounts;
  final int removedDuplicateCards;

  const SmsDetectionCleanupResult({
    required this.renamedAccounts,
    required this.renamedCards,
    required this.removedDuplicateAccounts,
    required this.removedDuplicateCards,
  });
}

class SmsDetectionCleanup {
  static final _last4Regexes = [
    RegExp(r'(?:a/c|acct|account)[^\d]{0,12}(?:xx|x{2,}|[*]{2,})?(\d{4})', caseSensitive: false),
    RegExp(r'(?:card ending|card xx|card no|credit card)[^\d]{0,12}(?:xx|x{2,}|[*]{2,})?(\d{4})', caseSensitive: false),
    RegExp(r'\bending\s+(\d{4})\b', caseSensitive: false),
    RegExp(r'\bxx(\d{4})\b', caseSensitive: false),
  ];

  final _db = AppDatabase.instance;

  Future<SmsDetectionCleanupResult> run() async {
    final database = await _db.database;
    final accountsRaw = await database.query(Tables.bankAccounts);
    final cardsRaw = await database.query(Tables.creditCards);
    final transactions = await database.query(Tables.transactions);
    final creditTransactions = await database.query(Tables.creditTransactions);

    var renamedAccounts = 0;
    var renamedCards = 0;
    var removedDuplicateAccounts = 0;
    var removedDuplicateCards = 0;

    final accounts = accountsRaw.map(BankAccount.fromMap).toList();
    final cards = cardsRaw.map(CreditCard.fromMap).toList();

    for (final account in accounts) {
      if (!_isGenericAccount(account.name)) continue;
      final linkedNotes = transactions
          .where((row) => row['account_id'] == account.id)
          .map((row) => (row['notes'] as String?) ?? (row['note'] as String?) ?? '')
          .toList();
      final last4 = _findUniqueLast4(linkedNotes);
      if (last4 == null) continue;
      final updated = account.copyWith(name: '${account.bank} Account $last4');
      await database.update(
        Tables.bankAccounts,
        updated.toMap(),
        where: 'id = ?',
        whereArgs: [account.id],
      );
      renamedAccounts++;
    }

    for (final card in cards) {
      if (!_isGenericCard(card)) continue;
      final linkedNotes = creditTransactions
          .where((row) => row['cardId'] == card.id)
          .map((row) => (row['note'] as String?) ?? '')
          .toList();
      final last4 = _findUniqueLast4(linkedNotes);
      if (last4 == null) continue;
      final updated = card.copyWith(
        name: '${card.bank} Credit Card $last4',
        last4: last4,
      );
      await database.update(
        Tables.creditCards,
        updated.toMap(),
        where: 'id = ?',
        whereArgs: [card.id],
      );
      renamedCards++;
    }

    final refreshedAccounts = (await database.query(Tables.bankAccounts))
        .map(BankAccount.fromMap)
        .toList();
    final refreshedCards = (await database.query(Tables.creditCards))
        .map(CreditCard.fromMap)
        .toList();

    final accountGroups = <String, List<BankAccount>>{};
    for (final account in refreshedAccounts) {
      final key = '${account.bank}|${account.name.toLowerCase()}';
      accountGroups.putIfAbsent(key, () => []).add(account);
    }
    for (final group in accountGroups.values) {
      if (group.length < 2) continue;
      group.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final duplicate in group.skip(1)) {
        final hasLinkedTx = transactions.any((row) => row['account_id'] == duplicate.id);
        if (!hasLinkedTx && duplicate.balance == 0) {
          await database.delete(
            Tables.bankAccounts,
            where: 'id = ?',
            whereArgs: [duplicate.id],
          );
          removedDuplicateAccounts++;
        }
      }
    }

    final cardGroups = <String, List<CreditCard>>{};
    for (final card in refreshedCards) {
      final key = '${card.bank}|${card.last4}|${card.name.toLowerCase()}';
      cardGroups.putIfAbsent(key, () => []).add(card);
    }
    for (final group in cardGroups.values) {
      if (group.length < 2) continue;
      group.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final duplicate in group.skip(1)) {
        final hasLinkedTx = creditTransactions.any((row) => row['cardId'] == duplicate.id);
        if (!hasLinkedTx && duplicate.usedAmount == 0) {
          await database.delete(
            Tables.creditCards,
            where: 'id = ?',
            whereArgs: [duplicate.id],
          );
          removedDuplicateCards++;
        }
      }
    }

    return SmsDetectionCleanupResult(
      renamedAccounts: renamedAccounts,
      renamedCards: renamedCards,
      removedDuplicateAccounts: removedDuplicateAccounts,
      removedDuplicateCards: removedDuplicateCards,
    );
  }

  bool _isGenericAccount(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith(' account') && !RegExp(r'\b\d{4}\b').hasMatch(lower);
  }

  bool _isGenericCard(CreditCard card) {
    final lower = card.name.toLowerCase();
    return lower.endsWith(' credit card') &&
        (card.last4 == '0000' || !RegExp(r'^\d{4}$').hasMatch(card.last4));
  }

  String? _findUniqueLast4(List<String> notes) {
    final found = <String>{};
    for (final note in notes) {
      for (final regex in _last4Regexes) {
        final match = regex.firstMatch(note);
        if (match != null) {
          found.add(match.group(1)!);
        }
      }
    }
    if (found.length == 1) {
      return found.first;
    }
    return null;
  }
}
