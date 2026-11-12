import 'package:sqflite/sqflite.dart';
import '../../../domain/finance/finance.dart';
import '../../../models/credit_card.dart';
import '../../../models/reminder_model.dart';
import '../../core/app_database.dart';
import '../../core/tables.dart';
import '../credit_repo.dart';
import '../reminder_repo.dart';

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

  /// Calculates total net asset value across all active non-system asset accounts.
  /// Gross assets include all accounts with non-negative balance.
  /// Overdrawn accounts (negative balance) are treated as overdraft liabilities.
  Future<Money> getTotalAssets({Transaction? txn, String currency = 'INR'}) async {
    final db = await _getExecutor(txn);
    final result = await db.rawQuery('''
      SELECT COALESCE(
        SUM(
          CASE WHEN account_balance > 0 THEN account_balance ELSE 0 END
        ), 0
      ) AS total_assets
      FROM (
        SELECT p.account_id,
          SUM(
            CASE
              WHEN p.direction = 'debit' THEN p.amount_minor_units
              ELSE -p.amount_minor_units
            END
          ) AS account_balance
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
        WHERE a.account_type = 'asset'
          AND a.is_system = 0
          AND a.is_active = 1
          AND e.lifecycle_status = 'posted'
        GROUP BY p.account_id
      );
    ''');

    final amount = (result.first['total_assets'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Calculates total liabilities across all active non-system liability accounts
  /// plus any bank account overdrafts (asset accounts with negative balance).
  Future<Money> getTotalLiabilities({Transaction? txn, String currency = 'INR'}) async {
    final db = await _getExecutor(txn);
    final result = await db.rawQuery('''
      SELECT (
        (
          SELECT COALESCE(
            SUM(
              CASE WHEN account_liability > 0 THEN account_liability ELSE 0 END
            ), 0
          )
          FROM (
            SELECT p.account_id,
              SUM(
                CASE
                  WHEN p.direction = 'credit' THEN p.amount_minor_units
                  ELSE -p.amount_minor_units
                END
              ) AS account_liability
            FROM ${TablesV24.postings} p
            JOIN ${TablesV24.accounts} a ON p.account_id = a.id
            JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
            WHERE a.account_type = 'liability'
              AND a.is_system = 0
              AND a.is_active = 1
              AND e.lifecycle_status = 'posted'
            GROUP BY p.account_id
          )
        )
        +
        (
          SELECT COALESCE(
            SUM(
              CASE WHEN account_balance < 0 THEN -account_balance ELSE 0 END
            ), 0
          )
          FROM (
            SELECT p.account_id,
              SUM(
                CASE
                  WHEN p.direction = 'debit' THEN p.amount_minor_units
                  ELSE -p.amount_minor_units
                END
              ) AS account_balance
            FROM ${TablesV24.postings} p
            JOIN ${TablesV24.accounts} a ON p.account_id = a.id
            JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
            WHERE a.account_type = 'asset'
              AND a.is_system = 0
              AND a.is_active = 1
              AND e.lifecycle_status = 'posted'
            GROUP BY p.account_id
          )
        )
      ) AS total_liabilities;
    ''',);

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
    bool? isExclusiveEndDate,
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
      whereArgs.add(startDate.toUtc().toIso8601String());
    }
    if (endDate != null) {
      final isMidnight = endDate.hour == 0 &&
          endDate.minute == 0 &&
          endDate.second == 0 &&
          endDate.millisecond == 0 &&
          endDate.microsecond == 0;
      final op = (isExclusiveEndDate ?? isMidnight) ? '<' : '<=';
      whereClauses.add('e.timestamp $op ?');
      whereArgs.add(endDate.toUtc().toIso8601String());
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
    bool? isExclusiveEndDate,
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
      whereArgs.add(startDate.toUtc().toIso8601String());
    }
    if (endDate != null) {
      final isMidnight = endDate.hour == 0 &&
          endDate.minute == 0 &&
          endDate.second == 0 &&
          endDate.millisecond == 0 &&
          endDate.microsecond == 0;
      final op = (isExclusiveEndDate ?? isMidnight) ? '<' : '<=';
      whereClauses.add('e.timestamp $op ?');
      whereArgs.add(endDate.toUtc().toIso8601String());
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
    bool? isExclusiveEndDate,
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
      whereArgs.add(startDate.toUtc().toIso8601String());
    }
    if (endDate != null) {
      final isMidnight = endDate.hour == 0 &&
          endDate.minute == 0 &&
          endDate.second == 0 &&
          endDate.millisecond == 0 &&
          endDate.microsecond == 0;
      final op = (isExclusiveEndDate ?? isMidnight) ? '<' : '<=';
      whereClauses.add('e.timestamp $op ?');
      whereArgs.add(endDate.toUtc().toIso8601String());
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
    bool? isExclusiveEndDate,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final income = await getTotalIncome(
      startDate: startDate,
      endDate: endDate,
      isExclusiveEndDate: isExclusiveEndDate,
      txn: txn,
      currency: currency,
    );
    final expenses = await getTotalExpenses(
      startDate: startDate,
      endDate: endDate,
      isExclusiveEndDate: isExclusiveEndDate,
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
        AND a.is_system = 0
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

    final computed = await _computeKnownCommitments14d(db, currency: currency);
    final commitments = knownCommitments14d ?? computed.total;
    final commitmentItems = computed.items;
    final pendingDebits = highConfidencePendingDebits ?? Money.zeroCurrency(currency);

    return SafeToSpendCalculation.compute(
      liquidAssets: liquidAssets,
      activeEarmarks: activeEarmarks,
      knownCommitments14d: commitments,
      highConfidencePendingDebits: pendingDebits,
      commitmentItems: commitmentItems,
    );
  }

  /// Calculates total obligations (bills, subscriptions, credit card dues, EMI installments)
  /// due within the next 14 calendar days from the local database.
  Future<({Money total, List<CommitmentItem> items})> _computeKnownCommitments14d(
    DatabaseExecutor db, {
    String currency = 'INR',
  }) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startOverdue = now.subtract(const Duration(days: 14)).toIso8601String();
    final endWindow = now.add(const Duration(days: 14));
    final endIso = endWindow.toIso8601String();
    double total14d = 0.0;
    final items = <CommitmentItem>[];
    final seenCommitments = <String>{};

    // Reconcile pending reminders against existing recorded payments/expenses
    try {
      await ReminderRepo(database: db).reconcileWithExistingTransactions(executor: db);
    } catch (_) {}

    // Pre-load all credit cards with canonical derived liabilities
    List<CreditCard> cards = [];
    try {
      cards = await CreditRepo(executor: db).getAll();
    } catch (_) {}

    // 1. Reminders due within 14 days or recent overdue (excluding salary income)
    try {
      final reminderRows = await db.rawQuery('''
        SELECT id, title, amount, date, linked_entity_id, type, is_active, is_completed, record_status, snoozed_until
        FROM ${Tables.reminders}
        WHERE is_active = 1
          AND is_completed = 0
          AND (record_status IS NULL OR record_status != 'done')
          AND type != 'salary'
          AND date <= ?
          AND date >= ?
        ORDER BY date DESC;
      ''', [endIso, startOverdue]);

      for (final r in reminderRows) {
        final snoozed = r['snoozed_until'] as String?;
        if (snoozed != null) {
          final sDate = DateTime.tryParse(snoozed);
          if (sDate != null && sDate.isAfter(endWindow)) {
            continue; // Snoozed past the 14-day commitment horizon
          }
        }

        final amount = (r['amount'] as num?)?.toDouble() ?? 0.0;
        if (amount > 0) {
          final title = (r['title'] as String?)?.trim() ?? 'Reminder';
          final cardId = r['linked_entity_id'] as String?;
          final rType = r['type'] as String? ?? 'bill';
          final rawDate = r['date'] as String?;
          final dueDate = rawDate != null ? DateTime.tryParse(rawDate) ?? now : now;

          final isCreditReminder = rType == 'credit' ||
              title.toLowerCase().contains('credit card') ||
              (cardId != null && cardId.isNotEmpty);

          // If this reminder is for a credit card, check if it was already paid
          CreditCard? matchedCard;
          double totalPaid = 0.0;
          if (isCreditReminder) {
            if (cardId != null && cardId.isNotEmpty) {
              matchedCard = cards.where((c) => c.id == cardId).firstOrNull;
            }
            if (matchedCard == null) {
              final tLower = title.toLowerCase();
              matchedCard = cards.where((c) {
                final bLower = c.bank.toLowerCase();
                final nLower = c.name.toLowerCase();
                return (bLower.isNotEmpty && tLower.contains(bLower)) ||
                    (nLower.isNotEmpty && tLower.contains(nLower));
              }).firstOrNull;
            }

            if (matchedCard != null) {
              // QUALIFICATION (DEF-517): The 26-day window around due date is an attribution heuristic,
              // not a guaranteed deterministic statement association. Where no explicit statement foreign
              // key exists, payments or merchant refunds occurring within this span are attributed to this
              // cycle obligation. Cross-cycle attribution is theoretically possible if dates overlap.
              final dueUtc = dueDate.toUtc();
              final minPayDateUtc = dueUtc.subtract(const Duration(days: 26)).toIso8601String();
              final maxPayDateUtc = dueUtc.add(const Duration(days: 26)).toIso8601String();
              final minPayDateLocal = dueDate.subtract(const Duration(days: 26)).toIso8601String();
              final maxPayDateLocal = dueDate.add(const Duration(days: 26)).toIso8601String();

              try {
                final v24Pay = await db.rawQuery('''
                  SELECT COALESCE(SUM(
                    CASE WHEN p.direction = 'debit' THEN p.amount_minor_units
                         ELSE -p.amount_minor_units END
                  ), 0) AS total_minor
                  FROM ${TablesV24.postings} p
                  JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
                  WHERE e.lifecycle_status = 'posted'
                    AND p.account_id = ?
                    AND e.reversal_of_event_id IS NULL
                    AND NOT (substr(e.description, 1, 10) = 'REVERSAL: ')
                    AND e.timestamp >= ? AND e.timestamp <= ?;
                ''', [
                  matchedCard.id,
                  minPayDateUtc,
                  maxPayDateUtc,
                ]);
                totalPaid = ((v24Pay.first['total_minor'] as num?)?.toDouble() ?? 0.0) / 100.0;
              } catch (_) {}

              if (totalPaid <= 0.0) {
                try {
                  final payResult = await db.rawQuery('''
                    SELECT COALESCE(SUM(amount), 0) AS total_paid
                    FROM ${Tables.transactions}
                    WHERE is_deleted = 0
                      AND (related_entity_id = ? OR notes LIKE ? OR notes LIKE ?)
                      AND (type = 'credit_payment' OR source = 'credit_card_payment' OR notes LIKE '%credit%' OR notes LIKE '%card%')
                      AND date >= ? AND date <= ?;
                  ''', [
                    matchedCard.id,
                    '%${matchedCard.bank}%',
                    '%${matchedCard.name}%',
                    minPayDateLocal,
                    maxPayDateLocal,
                  ]);
                  totalPaid = (payResult.first['total_paid'] as num?)?.toDouble() ?? 0.0;
                } catch (_) {}
              }

              final remaining = (amount - totalPaid).clamp(0.0, amount);
              if (remaining <= 0.01) {
                // Credit card bill already paid in full!
                final oldId = r['id'] as String?;
                if (oldId != null && oldId.isNotEmpty) {
                  await db.rawUpdate(
                    'UPDATE ${Tables.reminders} SET is_completed = 1, record_status = ? WHERE id = ?',
                    [ReminderRecordStatus.done.name, oldId],
                  );
                }
                seenCommitments.add('card:${matchedCard.id}');
                if (cardId != null && cardId.isNotEmpty) {
                  seenCommitments.add('card:$cardId');
                }
                continue; // Skip paid credit card bill!
              }
            }
          }

          // Normalized deduplication key for recurring obligations/merchants
          final cleanTitle = title
              .toLowerCase()
              .replaceAll(
                RegExp(
                  r'\b(subscription|bill|due|premium|autopay|mandate|stocks|health|renewal)\b',
                ),
                '',
              )
              .replaceAll(RegExp(r'[^a-z0-9]'), '')
              .trim();
          final normKey = cleanTitle.isNotEmpty
              ? cleanTitle
              : title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

          if (seenCommitments.contains('norm:$normKey') ||
              (cardId != null &&
                  cardId.isNotEmpty &&
                  seenCommitments.contains('card:$cardId')) ||
              (matchedCard != null &&
                  seenCommitments.contains('card:${matchedCard.id}'))) {
            final oldId = r['id'] as String?;
            if (oldId != null && oldId.isNotEmpty) {
              await db.rawUpdate(
                'UPDATE ${Tables.reminders} SET is_completed = 1, record_status = ? WHERE id = ?',
                [ReminderRecordStatus.done.name, oldId],
              );
            }
            continue;
          }

          seenCommitments.add('norm:$normKey');
          if (cardId != null && cardId.isNotEmpty) {
            seenCommitments.add('card:$cardId');
          }
          if (matchedCard != null) {
            seenCommitments.add('card:${matchedCard.id}');
          }
          seenCommitments.add('title:${title.toLowerCase()}');

          final effectiveAmount = (isCreditReminder && matchedCard != null)
              ? (amount - totalPaid).clamp(0.0, amount)
              : amount;

          final isDuplicate = items.any((it) =>
              (it.title.toLowerCase().trim() == title.toLowerCase().trim() ||
                  ReminderRepo.areMerchantsEquivalent(it.title, title)) &&
              (it.amount.toRupees - effectiveAmount).abs() <= 1.0 &&
              it.dueDate.year == dueDate.year &&
              it.dueDate.month == dueDate.month &&
              it.dueDate.day == dueDate.day);
          if (isDuplicate) {
            continue;
          }

          total14d += effectiveAmount;

          final isPastDue = dueDate.isBefore(today);
          items.add(
            CommitmentItem(
              title: title,
              amount: Money.fromRupees(effectiveAmount, currency: currency),
              dueDate: dueDate,
              type: rType == 'credit' ? 'credit_card' : 'bill',
              id: r['id'] as String?,
              isOverdue: isPastDue,
            ),
          );
        }
      }
    } catch (_) {}

    // 2. Credit cards due within next 14 days (if not already counted via reminder)
    try {
      for (final card in cards) {
        if (seenCommitments.contains('card:${card.id}')) continue;
        final cardName = card.name.toLowerCase().trim();
        final bankName = card.bank.toLowerCase().trim();
        final alreadySeenTitle = seenCommitments.any((k) {
          final stripped = k.replaceFirst('title:', '');
          return stripped.isNotEmpty &&
              ((cardName.isNotEmpty && stripped.contains(cardName)) ||
                  (bankName.isNotEmpty && stripped.contains(bankName)));
        });
        if (alreadySeenTitle) continue;

        final alreadyInItems = items.any((it) =>
            (it.amount.toRupees - card.lastStatementBalance).abs() <= 1.0 &&
            (it.title.toLowerCase().contains(cardName) ||
                (bankName.isNotEmpty && it.title.toLowerCase().contains(bankName)) ||
                ReminderRepo.areMerchantsEquivalent(it.title, cardName)));
        if (alreadyInItems) continue;

        final nextDue = card.nextDueDate;

        if (nextDue.isBefore(endWindow) || nextDue.isAtSameMomentAs(endWindow)) {
          // Check if statement balance has already been paid
          final lastStmt = card.lastStatementBalance;
          if (lastStmt > 0) {
            // QUALIFICATION (DEF-517): Heuristic 26-day payment/refund attribution window around nextDue.
            // When no deterministic statement reference exists, debit postings on card in this range are allocated here.
            final dueUtc = nextDue.toUtc();
            final minPayDateUtc = dueUtc.subtract(const Duration(days: 26)).toIso8601String();
            final maxPayDateUtc = dueUtc.add(const Duration(days: 26)).toIso8601String();
            final minPayDateLocal = nextDue.subtract(const Duration(days: 26)).toIso8601String();
            final maxPayDateLocal = nextDue.add(const Duration(days: 26)).toIso8601String();

            double totalPaid = 0.0;
            try {
              final v24Pay = await db.rawQuery('''
                SELECT COALESCE(SUM(
                  CASE WHEN p.direction = 'debit' THEN p.amount_minor_units
                       ELSE -p.amount_minor_units END
                ), 0) AS total_minor
                FROM ${TablesV24.postings} p
                JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
                WHERE e.lifecycle_status = 'posted'
                  AND p.account_id = ?
                  AND e.reversal_of_event_id IS NULL
                  AND NOT (substr(e.description, 1, 10) = 'REVERSAL: ')
                  AND e.timestamp >= ? AND e.timestamp <= ?;
              ''', [
                card.id,
                minPayDateUtc,
                maxPayDateUtc,
              ]);
              totalPaid = ((v24Pay.first['total_minor'] as num?)?.toDouble() ?? 0.0) / 100.0;
            } catch (_) {}

            if (totalPaid <= 0.0) {
              try {
                final payResult = await db.rawQuery('''
                  SELECT COALESCE(SUM(amount), 0) AS total_paid
                  FROM ${Tables.transactions}
                  WHERE is_deleted = 0
                    AND (related_entity_id = ? OR notes LIKE ? OR notes LIKE ?)
                    AND (type = 'credit_payment' OR source = 'credit_card_payment' OR notes LIKE '%credit%' OR notes LIKE '%card%')
                    AND date >= ? AND date <= ?;
                ''', [
                  card.id,
                  '%${card.bank}%',
                  '%${card.name}%',
                  minPayDateLocal,
                  maxPayDateLocal,
                ]);
                totalPaid = (payResult.first['total_paid'] as num?)?.toDouble() ?? 0.0;
              } catch (_) {}
            }

            final remaining = (lastStmt - totalPaid).clamp(0.0, lastStmt);
            seenCommitments.add('card:${card.id}');
            if (remaining > 0.01) {
              total14d += remaining;
              items.add(
                CommitmentItem(
                  title: card.name,
                  amount: Money.fromRupees(remaining, currency: currency),
                  dueDate: nextDue,
                  type: 'credit_card',
                  id: card.id,
                  isOverdue: nextDue.isBefore(today),
                ),
              );
            }
            continue;
          }

          final dueAmount = card.outstanding;
          if (dueAmount > 0.01) {
            total14d += dueAmount;
            seenCommitments.add('card:${card.id}');
            items.add(
              CommitmentItem(
                title: card.name,
                amount: Money.fromRupees(dueAmount, currency: currency),
                dueDate: nextDue,
                type: 'credit_card',
                id: card.id,
                isOverdue: nextDue.isBefore(today),
              ),
            );
          }
        }
      }
    } catch (_) {}

    // 3. Recurring templates due within next 14 days (if not already counted via reminder)
    try {
      final recurringRows = await db.rawQuery('''
        SELECT name, amount, type, frequency, last_generated, next_generation, is_active
        FROM ${Tables.recurring_templates}
        WHERE is_active = 1 AND type = 'expense';
      ''');

      for (final t in recurringRows) {
        final rawName = (t['name'] as String? ?? '').toLowerCase().trim();
        final cleanName = rawName
            .replaceAll(
              RegExp(
                r'\b(subscription|bill|due|premium|autopay|mandate|stocks|health|renewal)\b',
              ),
              '',
            )
            .replaceAll(RegExp(r'[^a-z0-9]'), '')
            .trim();
        final normName = cleanName.isNotEmpty
            ? cleanName
            : rawName.replaceAll(RegExp(r'[^a-z0-9]'), '');

        if (seenCommitments.contains('norm:$normName') ||
            seenCommitments.contains('title:$rawName')) {
          continue;
        }

        final alreadySeen = seenCommitments.any((k) {
          final stripped = k
              .replaceFirst('title:', '')
              .replaceFirst('norm:', '');
          return stripped.isNotEmpty &&
              (stripped.contains(normName) || normName.contains(stripped));
        });
        if (alreadySeen) continue;

        final amount = (t['amount'] as num?)?.toDouble() ?? 0.0;
        final freq = t['frequency'] as String? ?? 'monthly';
        final startIso = t['next_generation'] as String?;
        final lastIso = t['last_generated'] as String?;

        final startDate = startIso != null ? DateTime.tryParse(startIso) ?? now : now;
        final lastDate = lastIso != null ? DateTime.tryParse(lastIso) : null;

        if (_isTemplateDueIn14Days(startDate, lastDate, freq, now, endWindow)) {
          total14d += amount;
          items.add(
            CommitmentItem(
              title: t['name'] as String? ?? 'Recurring Expense',
              amount: Money.fromRupees(amount, currency: currency),
              dueDate: startDate,
              type: 'recurring',
              isOverdue: startDate.isBefore(today),
            ),
          );
        }
      }
    } catch (_) {}

    // Sort items by due date ascending
    items.sort((a, b) => a.dueDate.compareTo(b.dueDate));

    return (total: Money.fromRupees(total14d, currency: currency), items: items);
  }

  bool _isTemplateDueIn14Days(
    DateTime startDate,
    DateTime? lastDate,
    String frequency,
    DateTime now,
    DateTime endWindow,
  ) {
    DateTime nextDate = startDate;
    if (lastDate != null) {
      nextDate = _calculateNextRecurring(lastDate, frequency);
    }

    while (nextDate.isBefore(now)) {
      final next = _calculateNextRecurring(nextDate, frequency);
      if (next.isAtSameMomentAs(nextDate)) break;
      nextDate = next;
    }

    return nextDate.isBefore(endWindow) || nextDate.isAtSameMomentAs(endWindow);
  }

  DateTime _calculateNextRecurring(DateTime from, String frequency) {
    switch (frequency) {
      case 'daily':
        return from.add(const Duration(days: 1));
      case 'weekly':
        return from.add(const Duration(days: 7));
      case 'monthly':
        final nextMonth = from.month == 12 ? 1 : from.month + 1;
        final nextYear = from.month == 12 ? from.year + 1 : from.year;
        final maxDays = DateTime(nextYear, nextMonth + 1, 0).day;
        final nextDay = from.day > maxDays ? maxDays : from.day;
        return DateTime(nextYear, nextMonth, nextDay, from.hour, from.minute);
      case 'yearly':
        final maxDays = DateTime(from.year + 1, from.month + 1, 0).day;
        final nextDay = from.day > maxDays ? maxDays : from.day;
        return DateTime(from.year + 1, from.month, nextDay, from.hour, from.minute);
      default:
        return from.add(const Duration(days: 30));
    }
  }

  /// Calculates total expense spending for a specific category within an optional date range.
  Future<Money> getCategorySpending(
    String categoryId, {
    DateTime? startDate,
    DateTime? endDate,
    bool? isExclusiveEndDate,
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
      whereArgs.add(startDate.toUtc().toIso8601String());
    }
    if (endDate != null) {
      final isMidnight = endDate.hour == 0 &&
          endDate.minute == 0 &&
          endDate.second == 0 &&
          endDate.millisecond == 0 &&
          endDate.microsecond == 0;
      final op = (isExclusiveEndDate ?? isMidnight) ? '<' : '<=';
      whereClauses.add('e.timestamp $op ?');
      whereArgs.add(endDate.toUtc().toIso8601String());
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
    bool? isExclusiveEndDate,
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
      whereArgs.add(startDate.toUtc().toIso8601String());
    }
    if (endDate != null) {
      final isMidnight = endDate.hour == 0 &&
          endDate.minute == 0 &&
          endDate.second == 0 &&
          endDate.millisecond == 0 &&
          endDate.microsecond == 0;
      final op = (isExclusiveEndDate ?? isMidnight) ? '<' : '<=';
      whereClauses.add('e.timestamp $op ?');
      whereArgs.add(endDate.toUtc().toIso8601String());
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
        AND e.timestamp < ?
      GROUP BY strftime('%Y-%m-%d', e.timestamp);
    ''', [startDate.toUtc().toIso8601String(), now.toUtc().toIso8601String()]);

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
      whereArgs.add(fromDate.toUtc().toIso8601String());
    }
    if (toDate != null) {
      whereClauses.add('e.due_date < ?');
      whereArgs.add(toDate.toUtc().toIso8601String());
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
      whereArgs.add(fromDate.toUtc().toIso8601String());
    }
    if (toDate != null) {
      whereClauses.add('e.due_date < ?');
      whereArgs.add(toDate.toUtc().toIso8601String());
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

