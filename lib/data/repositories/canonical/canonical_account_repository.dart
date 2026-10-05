import 'package:sqflite/sqflite.dart';
import '../../../domain/finance/finance.dart';
import '../../core/app_database.dart';
import '../../core/tables_v24.dart';

/// Canonical Account Repository for SpendX 2.0.
///
/// Implements the persistence boundary for [Account] entities.
///
/// CRITICAL ARCHITECTURAL INVARIANT:
/// Account entities do not have mutable balance columns.
/// Account balances are derived exclusively by summing immutable postings
/// belonging to posted economic events.
class CanonicalAccountRepository {
  final DatabaseExecutor? _customExecutor;

  CanonicalAccountRepository({DatabaseExecutor? executor})
      : _customExecutor = executor;

  Future<DatabaseExecutor> _getExecutor(Transaction? txn) async {
    if (txn != null) return txn;
    if (_customExecutor != null) return _customExecutor;
    return await AppDatabase.instance.database;
  }

  /// Inserts a new canonical account into `accounts`.
  Future<void> createAccount(Account account, {Transaction? txn}) async {
    final db = await _getExecutor(txn);
    final isSys = account.id.startsWith('sys_') ? 1 : 0;
    await db.insert(
      TablesV24.accounts,
      {
        'id': account.id,
        'account_type': account.type.name,
        'subtype': account.category ?? account.type.name,
        'name': account.name,
        'currency': account.currency,
        'is_active': account.isActive ? 1 : 0,
        'is_system': isSys,
        'parent_account_id': account.parentAccountId,
        'created_at': account.createdAt.toIso8601String(),
        'updated_at': account.updatedAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.fail,
    );
  }

  /// Updates an existing canonical account in `accounts`.
  Future<void> updateAccount(Account account, {Transaction? txn}) async {
    final db = await _getExecutor(txn);
    final count = await db.update(
      TablesV24.accounts,
      {
        'account_type': account.type.name,
        'subtype': account.category ?? account.type.name,
        'name': account.name,
        'currency': account.currency,
        'is_active': account.isActive ? 1 : 0,
        'parent_account_id': account.parentAccountId,
        'updated_at': account.updatedAt.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [account.id],
    );

    if (count == 0) {
      throw AccountingInvariantException(
        'Account with ID ${account.id} not found for update.',
      );
    }
  }

  /// Sets `is_active = 0` for an account (soft archive).
  Future<void> archiveAccount(String accountId, {Transaction? txn}) async {
    final db = await _getExecutor(txn);
    final count = await db.update(
      TablesV24.accounts,
      {
        'is_active': 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [accountId],
    );

    if (count == 0) {
      throw AccountingInvariantException(
        'Account with ID $accountId not found for archiving.',
      );
    }
  }

  /// Retrieves an account by [id].
  Future<Account?> getAccount(String id, {Transaction? txn}) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.accounts,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return _mapRowToAccount(rows.first);
  }

  /// Lists accounts with optional filtering by type, activity status, and subtype.
  Future<List<Account>> listAccounts({
    AccountType? type,
    bool? isActive,
    String? subtype,
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (type != null) {
      whereClauses.add('account_type = ?');
      whereArgs.add(type.name);
    }
    if (isActive != null) {
      whereClauses.add('is_active = ?');
      whereArgs.add(isActive ? 1 : 0);
    }
    if (subtype != null) {
      whereClauses.add('subtype = ?');
      whereArgs.add(subtype);
    }

    final where = whereClauses.isEmpty ? null : whereClauses.join(' AND ');
    final rows = await db.query(
      TablesV24.accounts,
      where: where,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'name ASC',
    );

    return rows.map(_mapRowToAccount).toList();
  }

  /// Calculates the derived balance of an account from immutable postings.
  ///
  /// CRITICAL RULES:
  /// 1. ONLY postings belonging to posted economic events (`lifecycle_status = 'posted'`)
  ///    are included. Drafts, reversed, or deleted events are strictly excluded.
  /// 2. Assets & Expenses have normal DEBIT balance: SUM(debit) - SUM(credit).
  /// 3. Liabilities, Equity, & Income have normal CREDIT balance: SUM(credit) - SUM(debit).
  Future<Money> getDerivedBalance(String accountId, {Transaction? txn}) async {
    final db = await _getExecutor(txn);
    final acc = await getAccount(accountId, txn: txn);
    if (acc == null) {
      throw AccountingInvariantException('Account with ID $accountId does not exist.');
    }

    final isNormalDebit = acc.type == AccountType.asset || acc.type == AccountType.expense;

    final formula = isNormalDebit
        ? "CASE WHEN p.direction = 'debit' THEN p.amount_minor_units ELSE -p.amount_minor_units END"
        : "CASE WHEN p.direction = 'credit' THEN p.amount_minor_units ELSE -p.amount_minor_units END";

    final result = await db.rawQuery('''
      SELECT COALESCE(SUM($formula), 0) AS derived_balance
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE p.account_id = ? AND e.lifecycle_status = 'posted'
    ''', [accountId]);

    final rawBalance = (result.first['derived_balance'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(rawBalance, currency: acc.currency);
  }

  /// Calculates derived balances for a batch of account IDs.
  Future<Map<String, Money>> getDerivedBalances(
    List<String> accountIds, {
    Transaction? txn,
  }) async {
    final result = <String, Money>{};
    for (final id in accountIds) {
      result[id] = await getDerivedBalance(id, txn: txn);
    }
    return result;
  }

  /// Returns the absolute sum of debits and credits for an account.
  Future<({Money debits, Money credits})> getRawDebitCredit(
    String accountId, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final acc = await getAccount(accountId, txn: txn);
    if (acc == null) {
      throw AccountingInvariantException('Account with ID $accountId does not exist.');
    }

    final result = await db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN p.direction = 'debit' THEN p.amount_minor_units ELSE 0 END), 0) AS total_debits,
        COALESCE(SUM(CASE WHEN p.direction = 'credit' THEN p.amount_minor_units ELSE 0 END), 0) AS total_credits
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE p.account_id = ? AND e.lifecycle_status = 'posted'
    ''', [accountId]);

    final totalDebits = (result.first['total_debits'] as num?)?.toInt() ?? 0;
    final totalCredits = (result.first['total_credits'] as num?)?.toInt() ?? 0;

    return (
      debits: Money.fromMinorUnits(totalDebits, currency: acc.currency),
      credits: Money.fromMinorUnits(totalCredits, currency: acc.currency),
    );
  }

  Account _mapRowToAccount(Map<String, dynamic> row) {
    final typeStr = row['account_type'] as String;
    final accountType = AccountType.values.firstWhere(
      (e) => e.name == typeStr,
      orElse: () => throw AccountingInvariantException('Unknown account_type: $typeStr'),
    );

    return Account(
      id: row['id'] as String,
      name: row['name'] as String,
      type: accountType,
      parentAccountId: row['parent_account_id'] as String?,
      category: row['subtype'] as String?,
      currency: (row['currency'] as String?) ?? 'INR',
      isActive: (row['is_active'] as int) == 1,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}
