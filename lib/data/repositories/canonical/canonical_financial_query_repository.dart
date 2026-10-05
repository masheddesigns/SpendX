import 'package:sqflite/sqflite.dart';
import '../../../domain/finance/finance.dart';
import '../../core/app_database.dart';
import '../../core/tables_v24.dart';

/// Canonical Financial Query Repository for SpendX 2.0.
///
/// Computes aggregate accounting truth (Net Worth, Cash Flow, Income, Expenses,
/// Liquid Assets, and Safe-to-Spend) derived strictly from canonical postings.
///
/// CRITICAL ARCHITECTURAL INVARIANTS:
/// 1. ZERO DRAFT LEAKAGE: All financial calculations join `economic_events`
///    and filter `WHERE e.lifecycle_status = 'posted'`.
/// 2. DERIVED TRUTH: Net worth and cash flow are never read from snapshot caches.
/// 3. MATHEMATICAL SIGN CONVENTION:
///    - Asset: sum(debit) - sum(credit)
///    - Liability: sum(credit) - sum(debit)
///    - Income: sum(credit) - sum(debit)
///    - Expense: sum(debit) - sum(credit)
///    - Net Worth: Assets - Liabilities
///    - Cash Flow: Income - Expenses
class CanonicalFinancialQueryRepository {
  final DatabaseExecutor? _customExecutor;

  CanonicalFinancialQueryRepository({DatabaseExecutor? executor})
      : _customExecutor = executor;

  Future<DatabaseExecutor> _getExecutor(Transaction? txn) async {
    if (txn != null) return txn;
    if (_customExecutor != null) return _customExecutor;
    return await AppDatabase.instance.database;
  }

  /// Calculates total net asset value across all asset accounts.
  Future<Money> getTotalAssets({Transaction? txn, String currency = 'INR'}) async {
    final db = await _getExecutor(txn);
    final result = await db.rawQuery('''
      SELECT COALESCE(
        SUM(
          CASE
            WHEN p.direction = 'debit' THEN p.amount_minor_units
            ELSE -p.amount_minor_units
          END
        ), 0
      ) AS total_assets
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE a.account_type = 'asset'
        AND a.is_active = 1
        AND e.lifecycle_status = 'posted';
    ''');

    final amount = (result.first['total_assets'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Calculates total liabilities across all liability accounts.
  Future<Money> getTotalLiabilities({Transaction? txn, String currency = 'INR'}) async {
    final db = await _getExecutor(txn);
    final result = await db.rawQuery('''
      SELECT COALESCE(
        SUM(
          CASE
            WHEN p.direction = 'credit' THEN p.amount_minor_units
            ELSE -p.amount_minor_units
          END
        ), 0
      ) AS total_liabilities
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE a.account_type = 'liability'
        AND a.is_active = 1
        AND e.lifecycle_status = 'posted';
    ''');

    final amount = (result.first['total_liabilities'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Calculates Net Worth = Total Assets - Total Liabilities.
  Future<Money> getNetWorth({Transaction? txn, String currency = 'INR'}) async {
    final assets = await getTotalAssets(txn: txn, currency: currency);
    final liabilities = await getTotalLiabilities(txn: txn, currency: currency);
    return assets - liabilities;
  }

  /// Calculates total earned income within an optional date range.
  Future<Money> getTotalIncome({
    DateTime? startDate,
    DateTime? endDate,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final whereClauses = <String>[
      "a.account_type = 'income'",
      "e.lifecycle_status = 'posted'",
    ];
    final whereArgs = <dynamic>[];

    if (startDate != null) {
      whereClauses.add('e.timestamp >= ?');
      whereArgs.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      whereClauses.add('e.timestamp <= ?');
      whereArgs.add(endDate.toIso8601String());
    }

    final where = whereClauses.join(' AND ');
    final result = await db.rawQuery('''
      SELECT COALESCE(
        SUM(
          CASE
            WHEN p.direction = 'credit' THEN p.amount_minor_units
            ELSE -p.amount_minor_units
          END
        ), 0
      ) AS total_income
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE $where;
    ''', whereArgs.isEmpty ? null : whereArgs);

    final amount = (result.first['total_income'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Calculates total incurred expenses within an optional date range.
  Future<Money> getTotalExpenses({
    DateTime? startDate,
    DateTime? endDate,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final whereClauses = <String>[
      "a.account_type = 'expense'",
      "e.lifecycle_status = 'posted'",
    ];
    final whereArgs = <dynamic>[];

    if (startDate != null) {
      whereClauses.add('e.timestamp >= ?');
      whereArgs.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      whereClauses.add('e.timestamp <= ?');
      whereArgs.add(endDate.toIso8601String());
    }

    final where = whereClauses.join(' AND ');
    final result = await db.rawQuery('''
      SELECT COALESCE(
        SUM(
          CASE
            WHEN p.direction = 'debit' THEN p.amount_minor_units
            ELSE -p.amount_minor_units
          END
        ), 0
      ) AS total_expenses
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE $where;
    ''', whereArgs.isEmpty ? null : whereArgs);

    final amount = (result.first['total_expenses'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Calculates physical net Cash Flow = Net change in liquid cash accounts
  /// (sum of debits minus credits on bank, cash, wallet, savings accounts).
  ///
  /// CRITICAL DISTINCTIONS:
  /// - Credit card purchase generates ₹0 cash flow (does not move liquid cash).
  /// - Credit card payment generates negative cash flow (moves cash out of bank).
  /// - Loan repayment generates negative cash flow for entire payment (principal + interest).
  /// - Inter-account liquid transfer generates ₹0 net cash flow.
  Future<Money> getCashFlow({
    DateTime? startDate,
    DateTime? endDate,
    bool includeOpeningBalances = false,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final whereClauses = <String>[
      "a.account_type = 'asset'",
      "(a.subtype IN ('bank', 'cash', 'savings', 'wallet', 'liquid_cash', 'asset') OR a.subtype IS NULL)",
      "e.lifecycle_status = 'posted'",
    ];
    if (!includeOpeningBalances) {
      whereClauses.add("e.event_type != 'opening_balance'");
    }
    final whereArgs = <dynamic>[];

    if (startDate != null) {
      whereClauses.add('e.timestamp >= ?');
      whereArgs.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      whereClauses.add('e.timestamp <= ?');
      whereArgs.add(endDate.toIso8601String());
    }

    final where = whereClauses.join(' AND ');
    final result = await db.rawQuery('''
      SELECT COALESCE(
        SUM(
          CASE
            WHEN p.direction = 'debit' THEN p.amount_minor_units
            ELSE -p.amount_minor_units
          END
        ), 0
      ) AS cash_flow
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE $where;
    ''', whereArgs.isEmpty ? null : whereArgs);

    final amount = (result.first['cash_flow'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Calculates Net Operating Income = Total Income - Total Expenses.
  Future<Money> getNetOperatingIncome({
    DateTime? startDate,
    DateTime? endDate,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final income = await getTotalIncome(
      startDate: startDate,
      endDate: endDate,
      txn: txn,
      currency: currency,
    );
    final expenses = await getTotalExpenses(
      startDate: startDate,
      endDate: endDate,
      txn: txn,
      currency: currency,
    );
    return income - expenses;
  }

  /// Calculates Base Equity (from equity accounts, e.g. opening balances, capital).
  Future<Money> getBaseEquity({
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final result = await db.rawQuery('''
      SELECT COALESCE(
        SUM(
          CASE
            WHEN p.direction = 'credit' THEN p.amount_minor_units
            ELSE -p.amount_minor_units
          END
        ), 0
      ) AS base_equity
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE a.account_type = 'equity'
        AND a.is_active = 1
        AND e.lifecycle_status = 'posted';
    ''');

    final amount = (result.first['base_equity'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Calculates Total Equity = Base Equity + Retained Earnings (Income - Expenses).
  ///
  /// Satisfies the Fundamental Accounting Equation:
  /// Assets = Liabilities + Total Equity
  Future<Money> getTotalEquity({
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final baseEquity = await getBaseEquity(txn: txn, currency: currency);
    final retainedEarnings = await getNetOperatingIncome(txn: txn, currency: currency);
    return baseEquity + retainedEarnings;
  }

  /// Calculates liquid asset total across active liquid accounts
  /// (bank, cash, wallet, savings).
  Future<Money> getLiquidAssets({
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final result = await db.rawQuery('''
      SELECT COALESCE(
        SUM(
          CASE
            WHEN p.direction = 'debit' THEN p.amount_minor_units
            ELSE -p.amount_minor_units
          END
        ), 0
      ) AS liquid_assets
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE a.account_type = 'asset'
        AND a.is_active = 1
        AND (a.subtype IN ('bank', 'cash', 'savings', 'wallet', 'liquid_cash', 'asset') OR a.subtype IS NULL)
        AND e.lifecycle_status = 'posted';
    ''');

    final amount = (result.first['liquid_assets'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Computes the complete Safe-to-Spend breakdown.
  Future<SafeToSpendCalculation> getSafeToSpend({
    Money? knownCommitments14d,
    Money? highConfidencePendingDebits,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);

    final liquidAssets = await getLiquidAssets(txn: txn, currency: currency);

    // Sum active earmarks
    final earmarkResult = await db.rawQuery('''
      SELECT COALESCE(SUM(amount_minor_units), 0) AS total_earmarks
      FROM ${TablesV24.assetEarmarks};
    ''');
    final earmarkAmount = (earmarkResult.first['total_earmarks'] as num?)?.toInt() ?? 0;
    final activeEarmarks = Money.fromMinorUnits(earmarkAmount, currency: currency);

    final commitments = knownCommitments14d ?? Money.zeroCurrency(currency);
    final pendingDebits = highConfidencePendingDebits ?? Money.zeroCurrency(currency);

    return SafeToSpendCalculation.compute(
      liquidAssets: liquidAssets,
      activeEarmarks: activeEarmarks,
      knownCommitments14d: commitments,
      highConfidencePendingDebits: pendingDebits,
    );
  }

  /// Calculates total expense spending for a specific category within an optional date range.
  Future<Money> getCategorySpending(
    String categoryId, {
    DateTime? startDate,
    DateTime? endDate,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final whereClauses = <String>[
      "a.account_type = 'expense'",
      "e.lifecycle_status = 'posted'",
      "(a.id = ? OR a.id = 'exp_' || ?)",
    ];
    final whereArgs = <dynamic>[categoryId, categoryId];

    if (startDate != null) {
      whereClauses.add('e.timestamp >= ?');
      whereArgs.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      whereClauses.add('e.timestamp <= ?');
      whereArgs.add(endDate.toIso8601String());
    }

    final where = whereClauses.join(' AND ');
    final result = await db.rawQuery('''
      SELECT COALESCE(
        SUM(
          CASE
            WHEN p.direction = 'debit' THEN p.amount_minor_units
            WHEN p.direction = 'credit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0
      ) AS total_category_expense
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE $where;
    ''', whereArgs);

    final amount = (result.first['total_category_expense'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Calculates total expense spending grouped by category within an optional date range.
  Future<Map<String, Money>> getAllCategorySpending({
    DateTime? startDate,
    DateTime? endDate,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final whereClauses = <String>[
      "a.account_type = 'expense'",
      "e.lifecycle_status = 'posted'",
    ];
    final whereArgs = <dynamic>[];

    if (startDate != null) {
      whereClauses.add('e.timestamp >= ?');
      whereArgs.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      whereClauses.add('e.timestamp <= ?');
      whereArgs.add(endDate.toIso8601String());
    }

    final where = whereClauses.join(' AND ');
    final result = await db.rawQuery('''
      SELECT 
        a.id AS category_id,
        COALESCE(
          SUM(
            CASE
              WHEN p.direction = 'debit' THEN p.amount_minor_units
              WHEN p.direction = 'credit' THEN -p.amount_minor_units
              ELSE 0
            END
          ), 0
        ) AS total_category_expense
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE $where
      GROUP BY a.id;
    ''', whereArgs.isEmpty ? null : whereArgs);

    final map = <String, Money>{};
    for (final row in result) {
      final catId = row['category_id'] as String;
      final amount = (row['total_category_expense'] as num?)?.toInt() ?? 0;
      map[catId] = Money.fromMinorUnits(amount, currency: currency);
    }
    return map;
  }

  /// Computes historical daily variable spending statistics over a lookback window.
  ///
  /// Filters strictly to posted expense events.
  /// Automatically excludes non-expense postings (transfers, card payments, loan principal).
  /// Excludes one-off capital spikes (> ₹1,00,000 / configurable threshold) from daily velocity.
  Future<DailySpendStats> getDailySpendStats({
    int lookbackDays = 30,
    Money? capitalOneOffThreshold,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final now = DateTime.now();
    final startDate = now.subtract(Duration(days: lookbackDays));

    final result = await db.rawQuery('''
      SELECT 
        strftime('%Y-%m-%d', e.timestamp) AS spend_date,
        SUM(
          CASE
            WHEN p.direction = 'debit' THEN p.amount_minor_units
            ELSE -p.amount_minor_units
          END
        ) AS daily_spend
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE a.account_type = 'expense'
        AND e.lifecycle_status = 'posted'
        AND e.timestamp >= ?
        AND e.timestamp <= ?
      GROUP BY strftime('%Y-%m-%d', e.timestamp);
    ''', [startDate.toIso8601String(), now.toIso8601String()]);

    final capLimit = capitalOneOffThreshold?.minorUnits ?? 10000000; // Default ₹1,00,000 = 10^7 paise
    final dailySpends = <int>[];
    int totalVariablePaise = 0;

    for (final row in result) {
      final spend = (row['daily_spend'] as num?)?.toInt() ?? 0;
      if (spend > 0) {
        // Exclude extreme capital one-off anomalies from daily velocity
        if (spend <= capLimit) {
          dailySpends.add(spend);
          totalVariablePaise += spend;
        }
      }
    }

    final daysWithSpend = dailySpends.length;
    final sampledDays = lookbackDays <= 0 ? 1 : lookbackDays;
    final avgPaise = (totalVariablePaise / sampledDays).round();

    // Fill remaining days in lookback window with 0 to compute true lookback median
    final allDays = List<int>.from(dailySpends);
    while (allDays.length < sampledDays) {
      allDays.add(0);
    }
    allDays.sort();
    final medianPaise = allDays.isEmpty ? 0 : allDays[allDays.length ~/ 2];

    return DailySpendStats(
      medianDailySpend: Money.fromMinorUnits(medianPaise, currency: currency),
      averageDailySpend: Money.fromMinorUnits(avgPaise, currency: currency),
      totalVariableSpend: Money.fromMinorUnits(totalVariablePaise, currency: currency),
      daysSampled: sampledDays,
      daysWithSpend: daysWithSpend,
    );
  }

  /// Total scheduled commitments (expenses/bills/EMIs) due between [fromDate] and [toDate].
  Future<Money> getUpcomingExpectedCommitments({
    DateTime? fromDate,
    DateTime? toDate,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final whereClauses = <String>[
      "e.status IN ('pending', 'overdue')",
      "(a.account_type = 'expense' OR r.category_account_id LIKE 'sys_exp_%' OR r.category_account_id LIKE 'exp_%')",
    ];
    final whereArgs = <dynamic>[];

    if (fromDate != null) {
      whereClauses.add('e.due_date >= ?');
      whereArgs.add(fromDate.toIso8601String());
    }
    if (toDate != null) {
      whereClauses.add('e.due_date <= ?');
      whereArgs.add(toDate.toIso8601String());
    }

    final where = whereClauses.join(' AND ');
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(e.amount_minor_units), 0) AS total_commitments
      FROM ${TablesV24.expectedEvents} e
      LEFT JOIN ${TablesV24.recurringRules} r ON e.rule_id = r.id
      LEFT JOIN ${TablesV24.accounts} a ON r.category_account_id = a.id
      WHERE $where;
    ''', whereArgs.isEmpty ? null : whereArgs);

    final amount = (result.first['total_commitments'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Total scheduled inflows (salary/income) due between [fromDate] and [toDate].
  Future<Money> getUpcomingExpectedInflows({
    DateTime? fromDate,
    DateTime? toDate,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final whereClauses = <String>[
      "e.status IN ('pending', 'overdue')",
      "(a.account_type = 'income' OR r.category_account_id LIKE 'sys_inc_%' OR r.category_account_id LIKE 'inc_%')",
    ];
    final whereArgs = <dynamic>[];

    if (fromDate != null) {
      whereClauses.add('e.due_date >= ?');
      whereArgs.add(fromDate.toIso8601String());
    }
    if (toDate != null) {
      whereClauses.add('e.due_date <= ?');
      whereArgs.add(toDate.toIso8601String());
    }

    final where = whereClauses.join(' AND ');
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(e.amount_minor_units), 0) AS total_inflows
      FROM ${TablesV24.expectedEvents} e
      LEFT JOIN ${TablesV24.recurringRules} r ON e.rule_id = r.id
      LEFT JOIN ${TablesV24.accounts} a ON r.category_account_id = a.id
      WHERE $where;
    ''', whereArgs.isEmpty ? null : whereArgs);

    final amount = (result.first['total_inflows'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }
}

/// Daily spending velocity statistics derived from canonical postings.
class DailySpendStats {
  final Money medianDailySpend;
  final Money averageDailySpend;
  final Money totalVariableSpend;
  final int daysSampled;
  final int daysWithSpend;

  const DailySpendStats({
    required this.medianDailySpend,
    required this.averageDailySpend,
    required this.totalVariableSpend,
    required this.daysSampled,
    required this.daysWithSpend,
  });
}

