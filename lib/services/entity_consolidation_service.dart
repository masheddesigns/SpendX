import 'package:sqflite/sqflite.dart';
import '../data/core/app_database.dart';
import '../data/core/tables.dart';
import '../data/repositories/account_repo.dart';
import '../data/repositories/credit_repo.dart';
import '../models/bank_account.dart';
import '../models/credit_card.dart';
import '../core/logging/app_logger.dart';

/// Intelligent Anti-Collision & Financial Entity Consolidation Service.
///
/// Automatically discovers and resolves:
/// 1. Duplicate credit cards sharing the same bank and last4 digits (e.g., two HDFC 6366 cards).
/// 2. Ghost cards created from aggregator SMS without last4 digits (e.g., TNBPAY Card 0000).
/// 3. Bogus bank accounts mistakenly created for credit cards (e.g., HDFC Account 6366 with -₹31,000).
/// 4. Duplicate bank accounts sharing the same bank and last4 digits (e.g., two SBI 9331 accounts).
class EntityConsolidationService {
  static final EntityConsolidationService instance = EntityConsolidationService._();
  EntityConsolidationService._();

  Future<Database> get _db async => await AppDatabase.instance.database;

  /// Runs the full self-healing entity consolidation pass.
  /// Returns the number of consolidated / merged entities.
  Future<int> consolidate() async {
    int mergedCount = 0;
    final db = await _db;

    AppLogger.i('[EntityConsolidation] Starting financial entity consolidation...');

    // Temporarily drop postings update immutability trigger during maintenance pass
    await db.execute('DROP TRIGGER IF EXISTS trg_postings_prevent_update_on_posted;');

    try {
      // 1. Purge & Merge Ghost Cards (TNBPAY 0000, etc.)
      try {
        mergedCount += await _mergeGhostCards(db);
      } catch (e, stack) {
        AppLogger.e('[EntityConsolidation] Error in _mergeGhostCards: $e', e, stack);
      }

      // 2. Deduplicate Credit Cards with same (bank, last4)
      try {
        mergedCount += await _deduplicateCreditCards(db);
      } catch (e, stack) {
        AppLogger.e('[EntityConsolidation] Error in _deduplicateCreditCards: $e', e, stack);
      }

      // 3. Remove Bogus Bank Accounts that collide with Credit Cards
      try {
        mergedCount += await _removeCollidingBankAccounts(db);
      } catch (e, stack) {
        AppLogger.e('[EntityConsolidation] Error in _removeCollidingBankAccounts: $e', e, stack);
      }

      // 4. Deduplicate Bank Accounts with same (bank, last4)
      try {
        mergedCount += await _deduplicateBankAccounts(db);
      } catch (e, stack) {
        AppLogger.e('[EntityConsolidation] Error in _deduplicateBankAccounts: $e', e, stack);
      }

      AppLogger.i('[EntityConsolidation] Completed consolidation. Resolved $mergedCount entities.');
    } finally {
      // Always restore postings update immutability trigger
      await db.execute(TablesV24.trgPostingsPreventUpdateOnPosted);
    }

    return mergedCount;
  }

  /// Finds ghost cards (e.g. TNBPAY Card 0000) and merges their liabilities into the real card.
  Future<int> _mergeGhostCards(Database db) async {
    int merged = 0;
    final creditRepo = CreditRepo();
    final allCards = await creditRepo.getAll();

    final ghostCards = allCards.where((c) {
      final nameLower = c.name.toLowerCase();
      final bankLower = c.bank.toLowerCase();
      return nameLower.contains('tnbpay') ||
          bankLower.contains('tnbpay') ||
          nameLower.contains('tneu') ||
          c.last4 == '0000' ||
          c.last4.isEmpty;
    }).toList();

    if (ghostCards.isEmpty) return 0;

    // Find the real HDFC card (or primary card) to absorb Tata Neu / TNBPAY ghost cards
    final hdfcCard = allCards.where((c) {
      final b = c.bank.toLowerCase();
      final n = c.name.toLowerCase();
      return (b.contains('hdfc') || n.contains('hdfc')) && c.last4 != '0000' && c.last4.isNotEmpty;
    }).firstOrNull;

    for (final ghost in ghostCards) {
      final targetCard = (ghost.name.toLowerCase().contains('tnbpay') || ghost.bank.toLowerCase().contains('tnbpay'))
          ? hdfcCard
          : null;

      if (targetCard != null) {
        AppLogger.i('[EntityConsolidation] Merging ghost card ${ghost.name} (${ghost.id}) into ${targetCard.name} (${targetCard.id})');

        // Migrate statement balance if target has 0
        if (targetCard.lastStatementBalance <= 0 && ghost.lastStatementBalance > 0) {
          final updatedTarget = targetCard.copyWith(
            lastStatementBalance: ghost.lastStatementBalance,
            dueDay: ghost.dueDay,
          );
          await creditRepo.update(updatedTarget);
        }

        // Re-link transactions & reminders to target card
        await _relinkCardReferences(db, oldCardId: ghost.id, newCardId: targetCard.id);
      }

      // Safely delete ghost card
      await creditRepo.delete(ghost.id);
      await db.update(TablesV24.accounts, {'is_active': 0}, where: 'id = ?', whereArgs: [ghost.id]);
      await db.delete(Tables.creditCards, where: 'id = ?', whereArgs: [ghost.id]);
      merged++;
    }

    return merged;
  }

  /// Deduplicates credit cards sharing the same bank and last4 digits.
  Future<int> _deduplicateCreditCards(Database db) async {
    int merged = 0;
    final creditRepo = CreditRepo();
    final allCards = await creditRepo.getAll();

    // Group cards by normalized key
    final groups = <String, List<CreditCard>>{};
    for (final c in allCards) {
      final normBank = _normalizeBank(_extractBank(c.bank, c.name));
      final last4 = _extractLast4(c.last4, c.name);
      if (last4.isEmpty || last4 == '0000') continue;
      final key = '${normBank}_$last4';
      groups.putIfAbsent(key, () => []).add(c);
    }

    for (final entry in groups.entries) {
      final cardsInGroup = entry.value;
      if (cardsInGroup.length <= 1) continue;

      // Select canonical card: prefer the one with highest credit limit, or positive balance
      cardsInGroup.sort((a, b) {
        if (a.limitAmount != b.limitAmount) {
          return b.limitAmount.compareTo(a.limitAmount);
        }
        if (a.lastStatementBalance != b.lastStatementBalance) {
          return b.lastStatementBalance.compareTo(a.lastStatementBalance);
        }
        return a.id.compareTo(b.id);
      });

      final canonical = cardsInGroup.first;
      final duplicates = cardsInGroup.sublist(1);

      for (final dup in duplicates) {
        AppLogger.i('[EntityConsolidation] Merging duplicate card ${dup.name} (${dup.id}) into canonical ${canonical.name} (${canonical.id})');

        // If duplicate has limit and canonical doesn't, update canonical
        if (canonical.limitAmount <= 0 && dup.limitAmount > 0) {
          await creditRepo.update(canonical.copyWith(limitAmount: dup.limitAmount));
        }

        // If duplicate has statement balance and canonical doesn't, migrate
        if (canonical.lastStatementBalance <= 0 && dup.lastStatementBalance > 0) {
          await creditRepo.update(canonical.copyWith(
            lastStatementBalance: dup.lastStatementBalance,
            dueDay: dup.dueDay,
          ));
        }

        // Re-link references
        await _relinkCardReferences(db, oldCardId: dup.id, newCardId: canonical.id);

        // Safely delete duplicate card
        await creditRepo.delete(dup.id);
        await db.update(TablesV24.accounts, {'is_active': 0}, where: 'id = ?', whereArgs: [dup.id]);
        await db.delete(Tables.creditCards, where: 'id = ?', whereArgs: [dup.id]);
        merged++;
      }
    }

    return merged;
  }

  /// Removes bogus bank accounts that were mistakenly created for credit cards (e.g. HDFC 6366).
  Future<int> _removeCollidingBankAccounts(Database db) async {
    int removed = 0;
    final creditRepo = CreditRepo();
    final accountRepo = AccountRepo();

    final allCards = await creditRepo.getAll();
    final allAccounts = await accountRepo.getAll();

    for (final acc in allAccounts) {
      if (acc.accountType == 'wallet' || acc.id.startsWith('system_')) continue;
      final accLast4 = _extractLast4(acc.last4, acc.name);
      if (accLast4.isEmpty || accLast4 == '0000') continue;

      final accBankNorm = _normalizeBank(_extractBank(acc.bank, acc.name));

      // Check if a credit card with the same last4 and compatible bank exists
      final matchingCard = allCards.where((c) {
        final cardLast4 = _extractLast4(c.last4, c.name);
        if (cardLast4 != accLast4) return false;
        final cardBankNorm = _normalizeBank(_extractBank(c.bank, c.name));
        return cardBankNorm == accBankNorm ||
            cardBankNorm.contains(accBankNorm) ||
            accBankNorm.contains(cardBankNorm);
      }).firstOrNull;

      if (matchingCard != null) {
        AppLogger.i('[EntityConsolidation] Removing bogus bank account ${acc.name} (${acc.id}) colliding with card ${matchingCard.name}');

        // If the bank account had a negative balance, that was credit card spend!
        if (acc.balance < 0 && matchingCard.usedAmount <= 0) {
          await creditRepo.updateBalance(matchingCard.id, acc.balance.abs());
        }

        // Re-link any transactions under this bogus bank account to the credit card
        await db.rawUpdate('''
          UPDATE ${Tables.transactions}
          SET account_id = ?, type = 'credit_card_purchase'
          WHERE account_id = ?;
        ''', [matchingCard.id, acc.id]);

        await db.rawUpdate('''
          UPDATE ${TablesV24.postings}
          SET account_id = ?
          WHERE account_id = ?;
        ''', [matchingCard.id, acc.id]);

        // Delete the bogus bank account safely
        await accountRepo.deleteAccount(acc.id);
        await db.update(TablesV24.accounts, {'is_active': 0}, where: 'id = ?', whereArgs: [acc.id]);
        await db.delete(Tables.bankAccounts, where: 'id = ?', whereArgs: [acc.id]);
        removed++;
      }
    }

    return removed;
  }

  /// Deduplicates bank accounts sharing the same bank and last4 digits (e.g., two SBI 9331).
  Future<int> _deduplicateBankAccounts(Database db) async {
    int merged = 0;
    final accountRepo = AccountRepo();
    final allAccounts = await accountRepo.getAll();

    final groups = <String, List<BankAccount>>{};
    for (final a in allAccounts) {
      if (a.accountType == 'wallet' || a.id.startsWith('system_')) continue;
      final last4 = _extractLast4(a.last4, a.name);
      if (last4.isEmpty) continue;

      final normBank = _normalizeBank(_extractBank(a.bank, a.name));
      final key = '${normBank}_$last4';
      groups.putIfAbsent(key, () => []).add(a);
    }

    for (final entry in groups.entries) {
      final accountsInGroup = entry.value;
      if (accountsInGroup.length <= 1) continue;

      // Select canonical: prefer positive balance over negative, then highest balance
      accountsInGroup.sort((a, b) {
        if (a.balance >= 0 && b.balance < 0) return -1;
        if (b.balance >= 0 && a.balance < 0) return 1;
        return b.balance.compareTo(a.balance);
      });

      final canonical = accountsInGroup.first;
      final duplicates = accountsInGroup.sublist(1);

      for (final dup in duplicates) {
        AppLogger.i('[EntityConsolidation] Merging duplicate bank account ${dup.name} (${dup.id}) into ${canonical.name} (${canonical.id})');

        // Re-link transactions to canonical account
        await db.rawUpdate('''
          UPDATE ${Tables.transactions}
          SET account_id = ?
          WHERE account_id = ?;
        ''', [canonical.id, dup.id]);

        await db.rawUpdate('''
          UPDATE ${TablesV24.postings}
          SET account_id = ?
          WHERE account_id = ?;
        ''', [canonical.id, dup.id]);

        // Delete duplicate bank account safely
        await accountRepo.deleteAccount(dup.id);
        await db.update(TablesV24.accounts, {'is_active': 0}, where: 'id = ?', whereArgs: [dup.id]);
        await db.delete(Tables.bankAccounts, where: 'id = ?', whereArgs: [dup.id]);
        merged++;
      }
    }

    return merged;
  }

  String _extractLast4(String? last4, String name) {
    if (last4 != null && last4.isNotEmpty && last4 != '0000') return last4;
    final match = RegExp(r'(\d{4})').firstMatch(name);
    if (match != null) return match.group(1)!;
    return last4 ?? '';
  }

  String _extractBank(String? bank, String name) {
    if (bank != null && bank.trim().isNotEmpty) return bank;
    final lower = name.toLowerCase();
    for (final b in ['hdfc', 'sbi', 'icici', 'axis', 'federal', 'bob', 'kotak', 'jio', 'csb', 'onecard']) {
      if (lower.contains(b)) return b;
    }
    return bank ?? '';
  }

  Future<void> _relinkCardReferences(
    Database db, {
    required String oldCardId,
    required String newCardId,
  }) async {
    // 1. Transactions
    await db.rawUpdate('''
      UPDATE ${Tables.transactions}
      SET related_entity_id = ?
      WHERE related_entity_id = ?;
    ''', [newCardId, oldCardId]);

    await db.rawUpdate('''
      UPDATE ${Tables.transactions}
      SET account_id = ?
      WHERE account_id = ?;
    ''', [newCardId, oldCardId]);

    // 2. Postings
    await db.rawUpdate('''
      UPDATE ${TablesV24.postings}
      SET account_id = ?
      WHERE account_id = ?;
    ''', [newCardId, oldCardId]);

    // 3. Reminders
    await db.rawUpdate('''
      UPDATE ${Tables.reminders}
      SET linked_entity_id = ?
      WHERE linked_entity_id = ?;
    ''', [newCardId, oldCardId]);

    await db.rawUpdate('''
      UPDATE ${Tables.reminders}
      SET source_id = ?
      WHERE source_id = ?;
    ''', [newCardId, oldCardId]);

    // Delete redundant reminder if one already exists for newCardId
    final existingReminders = await db.rawQuery('''
      SELECT id FROM ${Tables.reminders}
      WHERE linked_entity_id = ? AND is_completed = 0;
    ''', [newCardId]);

    if (existingReminders.length > 1) {
      final keepId = existingReminders.first['id'] as String;
      await db.delete(
        Tables.reminders,
        where: 'linked_entity_id = ? AND id != ? AND is_completed = 0',
        whereArgs: [newCardId, keepId],
      );
    }
  }

  String _normalizeBank(String raw) {
    final lower = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (lower.contains('hdfc') || lower.contains('tnbpay') || lower.contains('tneu')) return 'hdfc';
    if (lower.contains('sbi') || lower.contains('statebank')) return 'sbi';
    if (lower.contains('icici') || lower.contains('amzn') || lower.contains('amazon')) return 'icici';
    if (lower.contains('axis') || lower.contains('fkart') || lower.contains('flipkart')) return 'axis';
    if (lower.contains('federal') || lower.contains('fed')) return 'federal';
    if (lower.contains('bob') || lower.contains('baroda')) return 'bob';
    if (lower.contains('kotak')) return 'kotak';
    if (lower.contains('onecard')) return 'onecard';
    if (lower.contains('csb') || lower.contains('jupiter') || lower.contains('jtedge')) return 'csb';
    return lower;
  }
}
