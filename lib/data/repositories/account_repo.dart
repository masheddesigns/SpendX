import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, DatabaseExecutor;

import '../../domain/finance/money.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../core/app_database.dart';
import '../core/tables.dart';
import 'canonical/canonical_account_adapter.dart';
import 'canonical/canonical_account_repository.dart';
import 'canonical/canonical_event_repository.dart';
import 'canonical/canonical_opening_balance_repository.dart';

/// Account Repository for SpendX.
///
/// Refactored in Milestone C3B-2 to establish the Canonical Account Boundary:
/// - Authoritative accounts and metadata reside in `TablesV24.accounts`.
/// - Financial balances are derived exclusively from immutable canonical double-entry postings
///   via [CanonicalAccountRepository.getDerivedBalance].
/// - The legacy `bank_accounts.balance` column is NEVER written to and NEVER read as financial truth.
/// - Opening balances and statement balance reconciliations route strictly through canonical
///   [CanonicalEventType.openingBalance] events balancing against [TablesV24.sysEquityOpening].
/// - Historical accounts with postings are soft-archived (`is_active = 0`) to preserve accounting integrity.
class AccountRepo {
  final DatabaseExecutor? _customExecutor;
  final db = AppDatabase.instance;

  AccountRepo({DatabaseExecutor? executor}) : _customExecutor = executor;

  Future<DatabaseExecutor> _getExecutor() async {
    if (_customExecutor != null) return _customExecutor;
    return await db.database;
  }

  CanonicalAccountRepository get _canonicalAccountRepo =>
      CanonicalAccountRepository(executor: _customExecutor);

  Future<void> create(BankAccount account) async {
    await insertAccount(account);
  }

  Future<List<BankAccount>> getAll() async {
    return getAccounts();
  }

  /// Lists all active asset/bank accounts projected with their canonical derived balances.
  Future<List<BankAccount>> getAccounts() async {
    final database = await _getExecutor();
    final rows = await database.query(
      TablesV24.accounts,
      where: 'account_type = ? AND is_system = 0 AND is_active = 1',
      whereArgs: ['asset'],
      orderBy: 'name ASC',
    );

    final List<BankAccount> result = [];
    for (final row in rows) {
      final id = row['id'] as String;
      final derivedBalance = await _canonicalAccountRepo.getDerivedBalance(id);
      result.add(CanonicalAccountAdapter.toBankAccount(row, derivedBalance));
    }
    return result;
  }

  /// Retrieves an account by ID projected with its canonical derived balance.
  Future<BankAccount?> getById(String? id) async {
    if (id == null || id.isEmpty) return null;

    final database = await _getExecutor();
    final rows = await database.query(
      TablesV24.accounts,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    final row = rows.first;
    final derivedBalance = await _canonicalAccountRepo.getDerivedBalance(id);
    return CanonicalAccountAdapter.toBankAccount(row, derivedBalance);
  }

  /// Inserts a new canonical account row. If [account.balance] != 0, posts an opening
  /// balance double-entry event balancing against `sys_equity_opening` with provenance.
  Future<String> insertAccount(BankAccount account) async {
    final database = await _getExecutor();
    await CanonicalAccountAdapter.ensureSystemAccountsExist(database);

    final row = CanonicalAccountAdapter.toAccountsRow(account);
    await database.insert(
      TablesV24.accounts,
      row,
      conflictAlgorithm: ConflictAlgorithm.fail,
    );

    // Initial opening balance event (if non-zero)
    if (account.balance != 0) {
      final ob = CanonicalAccountAdapter.createOpeningBalanceRecords(account);
      if (ob != null) {
        final eventRepo = CanonicalEventRepository(executor: database);
        await eventRepo.createAndPostEvent(
          ob.event,
          postings: ob.postings,
          evidence: [ob.evidence],
        );
        final recRepo = CanonicalOpeningBalanceRepository(executor: database);
        await recRepo.saveReconciliation(ob.reconciliation);
      }
    }

    return account.id;
  }

  /// Updates account display metadata (name, bank, type, icon, color, last4).
  /// ZERO impact on accounting truth.
  Future<int> updateAccount(BankAccount account) async {
    final database = await _getExecutor();
    return await database.update(
      TablesV24.accounts,
      {
        'name': account.name,
        'subtype': account.accountType,
        'institution_name': account.bank,
        'account_number_last4': account.last4,
        'color_hex': account.color,
        'icon_name': account.icon,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [account.id],
    );
  }

  /// Reconciles an account balance against a reported target balance (e.g. from SMS statement).
  /// Posts a double-entry reconciliation event balancing against `sys_equity_opening`
  /// with explicit provenance in `opening_balance_reconciliations`.
  /// ZERO writes to `bank_accounts.balance`.
  Future<void> updateBalance(String id, double balance) async {
    final database = await _getExecutor();
    await CanonicalAccountAdapter.ensureSystemAccountsExist(database);

    final rows = await database.query(
      TablesV24.accounts,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;

    final accountName = rows.first['name'] as String;
    final currentBalance = await _canonicalAccountRepo.getDerivedBalance(id);
    final targetBalance = Money.fromRupees(balance);

    final rec = CanonicalAccountAdapter.createReconciliationRecords(
      accountId: id,
      accountName: accountName,
      currentBalance: currentBalance,
      targetBalance: targetBalance,
      reason: 'Balance update/reconciliation',
      provenance: 'sms_balance_update',
    );

    if (rec != null) {
      final eventRepo = CanonicalEventRepository(executor: database);
      await eventRepo.createAndPostEvent(
        rec.event,
        postings: rec.postings,
        evidence: [rec.evidence],
      );
      final recRepo = CanonicalOpeningBalanceRepository(executor: database);
      await recRepo.saveReconciliation(rec.reconciliation);
    }
  }

  /// Atomically adjust balance by a delta amount via canonical double-entry reconciliation.
  Future<void> adjustBalance(String id, double delta) async {
    if (delta == 0) return;
    final currentBalance = await _canonicalAccountRepo.getDerivedBalance(id);
    final targetRupees = currentBalance.toRupees + delta;
    await updateBalance(id, targetRupees);
  }

  /// Batch-adjust balances for multiple accounts via canonical double-entry reconciliation.
  Future<void> adjustBalances(Map<String, double> deltas) async {
    if (deltas.isEmpty) return;
    for (final entry in deltas.entries) {
      await adjustBalance(entry.key, entry.value);
    }
  }

  /// Batch-adjust within an existing [DatabaseExecutor].
  Future<void> adjustBalancesWithTxn(
    DatabaseExecutor txn,
    Map<String, double> deltas,
  ) async {
    if (deltas.isEmpty) return;
    final repo = AccountRepo(executor: txn);
    for (final entry in deltas.entries) {
      await repo.adjustBalance(entry.key, entry.value);
    }
  }

  /// Deletes or soft-archives an account:
  /// - If the account has historical postings: soft-archives (`is_active = 0`) to preserve
  ///   accounting immutability and foreign key constraints.
  /// - If the account has no postings: physically deletes from `accounts`.
  Future<int> deleteAccount(String id) async {
    final database = await _getExecutor();

    final postingsCountRes = await database.rawQuery(
      'SELECT COUNT(*) as count FROM ${TablesV24.postings} WHERE account_id = ?',
      [id],
    );
    final count = (postingsCountRes.first['count'] as num?)?.toInt() ?? 0;

    if (count > 0) {
      // Historical postings exist: soft archive
      await database.update(
        TablesV24.accounts,
        {
          'is_active': 0,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } else {
      // No postings: physically delete
      await database.delete(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [id],
      );
    }

    // Also remove from transitional bank_accounts table if present
    await database.delete(
      Tables.bankAccounts,
      where: 'id = ?',
      whereArgs: [id],
    );

    return 1;
  }

  // --- Transitional Credit Card methods retained for backward compatibility ---

  Future<List<CreditCard>> getCards() async {
    final database = await _getExecutor();
    final res = await database.query(Tables.creditCards);
    return res.map((e) => CreditCard.fromMap(e)).toList();
  }

  Future<String> insertCard(CreditCard card) async {
    final database = await _getExecutor();
    await database.insert(Tables.creditCards, card.toMap());
    return card.id;
  }

  Future<int> updateCard(CreditCard card) async {
    final database = await _getExecutor();
    return await database.update(
      Tables.creditCards,
      card.toMap(),
      where: 'id = ?',
      whereArgs: [card.id],
    );
  }

  Future<int> deleteCard(String id) async {
    final database = await _getExecutor();
    return await database.delete(
      Tables.creditCards,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Convert a bank account to a credit card.
  Future<String> convertAccountToCard(BankAccount account) async {
    final card = CreditCard(
      name: account.name,
      bank: account.bank,
      limitAmount: 0,
      usedAmount: account.balance.abs(),
    );
    final database = await _getExecutor();
    await database.insert(Tables.creditCards, card.toMap());
    await deleteAccount(account.id);
    return card.id;
  }

  /// Convert a credit card to a bank account.
  Future<String> convertCardToAccount(CreditCard card) async {
    final account = BankAccount(
      name: card.name,
      bank: card.bank,
      balance: 0,
      accountType: 'savings',
    );
    final database = await _getExecutor();
    await database.delete(
      Tables.creditCards,
      where: 'id = ?',
      whereArgs: [card.id],
    );
    await insertAccount(account);
    return account.id;
  }
}
