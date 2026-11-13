import 'dart:convert';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, Database, DatabaseExecutor;

import '../../domain/finance/finance.dart';
import '../../models/credit_card.dart';
import '../../models/credit_transaction.dart';
import '../../models/credit_emi.dart';
import '../../models/emi_installment.dart';
import '../../models/card_statement.dart';
import '../core/app_database.dart';
import '../core/database_access_gate.dart';
import '../core/tables.dart';
import 'canonical/canonical_account_repository.dart';
import 'canonical/canonical_credit_adapter.dart';
import 'canonical/canonical_event_repository.dart';
import 'canonical/canonical_opening_balance_repository.dart';

/// Credit Card Repository for SpendX.
///
/// Refactored in Milestone C3B-3 to establish the Canonical Credit / Liability Boundary:
/// - Authoritative card accounts reside in `TablesV24.accounts` as `AccountType.liability`.
/// - Financial balances are derived exclusively from immutable canonical double-entry postings
///   via [CanonicalAccountRepository.getDerivedBalance] (Liability: credits - debits).
/// - The legacy `credit_cards.used_amount` column is NEVER read as authoritative financial truth.
/// - Purchases produce: Dr Expense, Cr Card Liability.
/// - Payments produce: Dr Card Liability, Cr Bank Asset (0 expense/income impact).
/// - Refunds produce: Dr Card Liability, Cr Expense / Contra-Expense (0 income impact).
/// - Opening balances and statement reconciliations route strictly through canonical
///   [CanonicalEventType.openingBalance] events balancing against [TablesV24.sysEquityOpening].
/// - Historical cards with postings are soft-archived (`is_active = 0`) to preserve accounting integrity.
class CreditRepo {
  final DatabaseExecutor? _customExecutor;

  CreditRepo({DatabaseExecutor? database, DatabaseExecutor? executor})
      : _customExecutor = executor ?? database;

  DatabaseExecutor? get executor => _customExecutor;

  Future<DatabaseExecutor> get _db async =>
      _customExecutor != null
          ? DatabaseAccessGate.instance.wrapExecutor(_customExecutor)
          : await AppDatabase.instance.database;

  CanonicalAccountRepository _getAccountRepo(DatabaseExecutor db) =>
      CanonicalAccountRepository(executor: db);

  CanonicalEventRepository _getEventRepo(DatabaseExecutor db) =>
      CanonicalEventRepository(executor: db);

  CanonicalOpeningBalanceRepository _getReconciliationRepo(DatabaseExecutor db) =>
      CanonicalOpeningBalanceRepository(executor: db);

  /// Lists all active credit cards projected with their canonical derived liability balances.
  Future<List<CreditCard>> getAll() async {
    final database = await _db;
    final rows = await database.query(
      TablesV24.accounts,
      where: "account_type = 'liability' AND subtype = 'credit_card' AND is_active = 1",
      orderBy: 'name ASC',
    );

    final List<CreditCard> result = [];
    for (final row in rows) {
      final id = row['id'] as String;
      final derivedBalance = await _getAccountRepo(database).getDerivedBalance(id);

      // Fetch optional transitional row for lastStatementBalance if available
      final transitionalRows = await database.query(
        Tables.creditCards,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      final transitionalCardRow = transitionalRows.firstOrNull;

      result.add(CanonicalCreditAdapter.toCreditCard(
        row,
        derivedBalance,
        transitionalCardRow: transitionalCardRow,
      ));
    }
    return result;
  }

  /// Retrieves a credit card by ID projected with its canonical derived liability balance.
  Future<CreditCard?> getCard(String id) async {
    if (id.isEmpty) return null;

    final database = await _db;
    final rows = await database.query(
      TablesV24.accounts,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    final row = rows.first;
    final derivedBalance = await _getAccountRepo(database).getDerivedBalance(id);

    final transitionalRows = await database.query(
      Tables.creditCards,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final transitionalCardRow = transitionalRows.firstOrNull;

    return CanonicalCreditAdapter.toCreditCard(
      row,
      derivedBalance,
      transitionalCardRow: transitionalCardRow,
    );
  }

  /// Inserts a new canonical credit card liability account.
  /// If [card.usedAmount] != 0, posts an opening balance double-entry event
  /// balancing against `sys_equity_opening` with explicit provenance.
  Future<String> insert(CreditCard card) async {
    final database = await _db;
    await CanonicalCreditAdapter.ensureSystemAccountsExist(database);

    final row = CanonicalCreditAdapter.toAccountsRow(card);
    await database.insert(
      TablesV24.accounts,
      row,
      conflictAlgorithm: ConflictAlgorithm.fail,
    );

    // Initial opening balance event (if non-zero outstanding)
    if (card.usedAmount != 0) {
      final ob = CanonicalCreditAdapter.createOpeningBalanceRecords(card);
      if (ob != null) {
        final eventRepo = _getEventRepo(database);
        await eventRepo.createAndPostEvent(
          ob.event,
          postings: ob.postings,
          evidence: [ob.evidence],
        );
        final recRepo = _getReconciliationRepo(database);
        await recRepo.saveReconciliation(ob.reconciliation);
      }
    }

    // Keep transitional table populated with metadata for compatibility
    await database.insert(
      Tables.creditCards,
      card.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    return card.id;
  }

  Future<T> _runInTransaction<T>(
    DatabaseExecutor executor,
    Future<T> Function(DatabaseExecutor txn) action,
  ) async {
    if (executor is Database) {
      return await executor.transaction((t) => action(t));
    } else {
      return await action(executor);
    }
  }

  /// Updates credit card display metadata (name, bank, limit, billing cycle, color, icon).
  /// ZERO impact on accounting truth. Stale usedAmount in [card] is intentionally ignored
  /// to prevent spurious reconciliation events during ordinary metadata edits.
  Future<int> update(CreditCard card) async {
    final database = await _db;

    final count = await database.update(
      TablesV24.accounts,
      {
        'name': card.name,
        'institution_name': card.bank,
        'account_number_last4': card.last4,
        'credit_limit_minor_units': (card.limitAmount * 100.0).round(),
        'billing_cycle_day': card.billingDay,
        'payment_due_day': card.dueDay,
        'color_hex': card.color,
        'icon_name': card.cardType,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [card.id],
    );

    // Update transitional table metadata
    await database.update(
      Tables.creditCards,
      card.toMap(),
      where: 'id = ?',
      whereArgs: [card.id],
    );

    return count;
  }

  /// Explicitly reconciles a credit card's outstanding liability against a reported target balance
  /// (e.g. from SMS statement or explicit statement sync).
  /// Posts a double-entry reconciliation event balancing against `sys_equity_opening`
  /// with explicit provenance in `opening_balance_reconciliations`.
  /// ZERO writes to mutable legacy balance columns.
  /// When [statementClosingDate] is provided, reconciles point-in-time liability as of that date,
  /// completely preserving transactions posted after the statement closing date.
  Future<void> reconcileOutstanding(
    String cardId,
    double targetUsedAmount, {
    DateTime? statementClosingDate,
    String reason = 'Statement balance reconciliation',
    String provenance = 'sms_card_balance_update',
  }) async {
    final database = await _db;
    await _runInTransaction(database, (txn) async {
      await CanonicalCreditAdapter.ensureSystemAccountsExist(txn);

      final currentLiability = await _getAccountRepo(txn).getDerivedBalance(
        cardId,
        txn: txn,
        asOf: statementClosingDate,
      );
      final targetLiability = Money.fromRupees(targetUsedAmount);
      final deltaPaise = targetLiability.minorUnits - currentLiability.minorUnits;

      if (deltaPaise != 0) {
        final rows = await txn.query(
          TablesV24.accounts,
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [cardId],
          limit: 1,
        );
        final cardName = rows.isNotEmpty ? (rows.first['name'] as String) : 'Credit Card $cardId';

        final effectiveReason = statementClosingDate != null
            ? '$reason (as of ${statementClosingDate.toIso8601String()})'
            : reason;

        final rec = CanonicalCreditAdapter.createReconciliationRecords(
          cardId: cardId,
          cardName: cardName,
          currentLiability: currentLiability,
          targetLiability: targetLiability,
          reason: effectiveReason,
          provenance: provenance,
          timestamp: statementClosingDate,
        );
        if (rec != null) {
          final eventRepo = _getEventRepo(txn);
          await eventRepo.createAndPostEvent(
            rec.event,
            postings: rec.postings,
            evidence: [rec.evidence],
          );
          final recRepo = _getReconciliationRepo(txn);
          await recRepo.saveReconciliation(rec.reconciliation);
        }
      }
    });
  }

  /// Alias to [reconcileOutstanding] for API parity with AccountRepo.updateBalance.
  Future<void> updateBalance(String cardId, double balance, {DateTime? messageDate}) async {
    await reconcileOutstanding(cardId, balance, statementClosingDate: messageDate);
  }

  /// Deletes or soft-archives a credit card:
  /// - If the card has historical postings: soft-archives (`is_active = 0`) in `accounts`.
  /// - If the card has no postings: physically deletes from `accounts`.
  Future<int> delete(String id) async {
    final database = await _db;

    final postingsCountRes = await database.rawQuery(
      'SELECT COUNT(*) as count FROM ${TablesV24.postings} WHERE account_id = ?',
      [id],
    );
    final count = (postingsCountRes.first['count'] as num?)?.toInt() ?? 0;

    if (count > 0) {
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
      await database.delete(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [id],
      );
    }

    // Also remove from transitional credit_cards table
    await database.delete(
      Tables.creditCards,
      where: 'id = ?',
      whereArgs: [id],
    );

    return 1;
  }

  /// Batch-adjusts outstandings for multiple cards via canonical double-entry reconciliation.
  /// ZERO direct writes to legacy mutable balance columns.
  /// Wrapped in an atomic transaction boundary.
  Future<void> adjustOutstandings(Map<String, double> deltas) async {
    if (deltas.isEmpty) return;
    final database = await _db;
    await CanonicalCreditAdapter.ensureSystemAccountsExist(database);

    await _runInTransaction(database, (txn) async {
      for (final entry in deltas.entries) {
        if (entry.value == 0) continue;
        final currentLiability = await _getAccountRepo(txn).getDerivedBalance(entry.key);
        final deltaMinor = (entry.value * 100.0).round();
        final targetLiability = Money.fromMinorUnits(currentLiability.minorUnits + deltaMinor);

        final rec = CanonicalCreditAdapter.createReconciliationRecords(
          cardId: entry.key,
          cardName: 'Credit Card ${entry.key}',
          currentLiability: currentLiability,
          targetLiability: targetLiability,
          reason: 'Outstanding adjustment',
          provenance: 'card_reconciliation_delta',
        );
        if (rec != null) {
          final eventRepo = _getEventRepo(txn);
          await eventRepo.createAndPostEvent(
            rec.event,
            postings: rec.postings,
            evidence: [rec.evidence],
          );
          final recRepo = _getReconciliationRepo(txn);
          await recRepo.saveReconciliation(rec.reconciliation);
        }
      }
    });
  }

  /// Batch-adjust within an existing [DatabaseExecutor].
  Future<void> adjustOutstandingsWithTxn(
    DatabaseExecutor txn,
    Map<String, double> deltas,
  ) async {
    if (deltas.isEmpty) return;
    final repo = CreditRepo(executor: txn);
    await repo.adjustOutstandings(deltas);
  }

  /// Atomically posts a credit transaction as a canonical double-entry event:
  /// - Payment: Dr Card Liability, Cr Bank Asset (0 expense/income)
  /// - Refund: Dr Card Liability, Cr Contra-Expense (0 income)
  /// - Purchase / EMI: Dr Expense, Cr Card Liability
  Future<void> insertTransaction(CreditTransaction tx) async {
    final database = await _db;
    await _runInTransaction(database, (txn) async {
      final isPayment = tx.type.toLowerCase() == 'payment';
      final isRefund = tx.type.toLowerCase() == 'refund';
      final assetAcc = isPayment ? (tx.categoryId ?? 'acc_bank_default') : null;

      if (isRefund && tx.relatedEntityId != null && tx.relatedEntityId!.trim().isNotEmpty) {
        final purchaseId = tx.relatedEntityId!.trim();

        // 1. Original purchase must exist and be posted
        final origRows = await txn.query(
          TablesV24.economicEvents,
          where: "id = ? AND lifecycle_status = 'posted'",
          whereArgs: [purchaseId],
        );
        if (origRows.isEmpty) {
          throw AccountingInvariantException(
            'Refund rejected: Original purchase $purchaseId does not exist or is not posted.',
          );
        }
        final origEvent = origRows.first;

        // 2. Reject if original is already a reversal
        if (origEvent['reversal_of_event_id'] != null ||
            (origEvent['description'] as String? ?? '').startsWith('REVERSAL:')) {
          throw AccountingInvariantException(
            'Refund rejected: Cannot refund a reversal event ($purchaseId).',
          );
        }

        // 3. Reject if original has already been deleted or reversed
        final revRows = await txn.query(
          TablesV24.economicEvents,
          columns: ['id'],
          where: "reversal_of_event_id = ? AND lifecycle_status = 'posted'",
          whereArgs: [purchaseId],
        );
        if (revRows.isNotEmpty) {
          throw AccountingInvariantException(
            'Refund rejected: Original purchase $purchaseId has been reversed or deleted.',
          );
        }

        // 4. Get original purchase amount
        final origPostings = await txn.query(
          TablesV24.postings,
          where: 'economic_event_id = ? AND account_id = ?',
          whereArgs: [purchaseId, tx.cardId],
        );
        if (origPostings.isEmpty) {
          throw AccountingInvariantException(
            'Refund rejected: Original purchase $purchaseId has no postings for card ${tx.cardId}.',
          );
        }
        final origPaise = origPostings.first['amount_minor_units'] as int;

        // 5. Query cumulative unreversed prior refunds
        final priorRefundRows = await txn.rawQuery('''
          SELECT COALESCE(SUM(p.amount_minor_units), 0) AS prior_refund_paise
          FROM ${TablesV24.economicEvents} e
          JOIN ${TablesV24.postings} p ON p.economic_event_id = e.id AND p.account_id = ?
          WHERE e.event_type = 'refund'
            AND e.lifecycle_status = 'posted'
            AND e.id != ?
            AND (
              e.notes LIKE ?
              OR e.reversal_of_event_id = ?
            )
            AND NOT EXISTS (
              SELECT 1 FROM ${TablesV24.economicEvents} r
              WHERE r.reversal_of_event_id = e.id AND r.lifecycle_status = 'posted'
            )
        ''', [
          tx.cardId,
          tx.id,
          '%"related_entity_id":"$purchaseId"%',
          purchaseId,
        ]);
        final priorRefundPaise = (priorRefundRows.first['prior_refund_paise'] as num?)?.toInt() ?? 0;
        final remainingPaise = origPaise - priorRefundPaise;
        final thisRefundPaise = (tx.amount.abs() * 100.0).round();

        if (thisRefundPaise > remainingPaise) {
          throw AccountingInvariantException(
            'Refund rejected: Refund amount ₹${tx.amount.abs()} exceeds remaining refundable ceiling '
            '₹${remainingPaise / 100.0} for purchase $purchaseId.',
          );
        }
      }

      await CanonicalCreditAdapter.ensureAccountsExist(
        txn,
        cardId: tx.cardId,
        expenseAccountId: isPayment ? null : tx.categoryId,
        assetAccountId: assetAcc,
      );

      final data = CanonicalCreditAdapter.toEconomicEventAndPostings(
        tx,
        defaultAssetAccountId: assetAcc,
      );
      final eventRepo = _getEventRepo(txn);
      await eventRepo.createAndPostEvent(
        data.event,
        postings: data.postings,
        evidence: [data.evidence],
      );
    });
  }

  /// Returns the canonical derived liability balance for [cardId].
  Future<Money> getDerivedBalance(
    String cardId, {
    DatabaseExecutor? executor,
    DateTime? asOf,
  }) async {
    final database = executor ?? await _db;
    return _getAccountRepo(database).getDerivedBalance(cardId, txn: executor, asOf: asOf);
  }

  /// Bulk-insert credit transactions in a single batch.
  Future<void> insertTransactions(List<CreditTransaction> txns) async {
    if (txns.isEmpty) return;
    for (final tx in txns) {
      await insertTransaction(tx);
    }
  }

  /// Bulk-insert credit transactions within an existing [DatabaseExecutor].
  Future<void> insertTransactionsWithTxn(
    DatabaseExecutor txn,
    List<CreditTransaction> txns,
  ) async {
    if (txns.isEmpty) return;
    final repo = CreditRepo(executor: txn);
    for (final tx in txns) {
      await repo.insertTransaction(tx);
    }
  }

  /// Projects card transaction history from canonical double-entry postings.
  /// Strictly filters out reversed original transactions and reversal events.
  Future<List<CreditTransaction>> getTransactions(String cardId) async {
    final database = await _db;
    final query = '''
      SELECT 
        e.id AS event_id,
        e.timestamp AS event_time,
        e.description AS description,
        e.event_type AS event_type,
        e.notes AS notes,
        p.id AS posting_id,
        p.amount_minor_units AS amount_minor,
        p.direction AS direction
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE p.account_id = ? 
        AND e.lifecycle_status = 'posted'
        AND e.event_type != 'opening_balance'
        AND NOT (LOWER(e.description) LIKE '%adjustment%')
        AND NOT (LOWER(e.description) LIKE '%reconciliation%')
        AND NOT (LOWER(e.description) LIKE '%opening balance%')
        AND e.reversal_of_event_id IS NULL
        AND NOT (substr(e.description, 1, 10) = 'REVERSAL: ')
        AND NOT EXISTS (
          SELECT 1 FROM ${TablesV24.economicEvents} r
          WHERE r.reversal_of_event_id = e.id AND r.lifecycle_status = 'posted'
        )
        AND NOT EXISTS (
          SELECT 1 FROM ${TablesV24.economicEvents} r
          WHERE r.lifecycle_status = 'posted'
            AND substr(r.description, 1, 10) = 'REVERSAL: '
            AND (substr(r.description, 11) = e.id OR substr(r.description, 11, length(e.id) + 3) = e.id || ' - ')
        )
      ORDER BY e.timestamp DESC, p.sequence_number ASC
    ''';
    final rows = await database.rawQuery(query, [cardId]);
    return rows.map((r) {
      final eventType = r['event_type'] as String? ?? 'credit_purchase';
      final direction = r['direction'] as String? ?? 'credit';
      final amountMinor = r['amount_minor'] as int? ?? 0;
      final amount = amountMinor / 100.0;
      final date = DateTime.parse(r['event_time'] as String);
      final desc = (r['description'] as String?) ?? '';
      final rawNotes = r['notes'] as String?;

      String? relatedEntityId;
      if (rawNotes != null && rawNotes.trim().startsWith('{') && rawNotes.trim().endsWith('}')) {
        try {
          final parsed = jsonDecode(rawNotes) as Map<String, dynamic>;
          relatedEntityId = parsed['related_entity_id'] as String?;
        } catch (_) {}
      }

      final String type;
      if (eventType == 'credit_purchase') {
        type = 'purchase';
      } else if (eventType == 'liability_settlement' || (eventType == 'transfer' && direction == 'debit')) {
        type = 'payment';
      } else if (eventType == 'refund') {
        type = 'refund';
      } else if (eventType == 'opening_balance' || eventType == 'adjustment') {
        type = 'adjustment';
      } else if (direction == 'debit') {
        type = 'payment';
      } else {
        type = 'purchase';
      }

      return CreditTransaction(
        id: r['event_id'] as String,
        cardId: cardId,
        amount: amount,
        date: date,
        category: 'Credit Card',
        note: desc,
        type: type,
        status: 'active',
        relatedEntityId: relatedEntityId,
      );
    }).toList();
  }

  Future<CreditTransaction?> getTransactionById(String id) async {
    final database = await _db;
    final eventRepo = _getEventRepo(database);
    final event = await eventRepo.getEvent(id);
    if (event == null || event.lifecycleStatus != EventLifecycle.posted) {
      final legacyRows = await database.query(
        Tables.creditTransactions,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (legacyRows.isNotEmpty) {
        return CreditTransaction.fromMap(legacyRows.first);
      }
      return null;
    }
    final postings = await eventRepo.getPostingsForEvent(id);
    if (postings.isEmpty) return null;
    final cardId = (event.metadata['card_id'] as String?) ??
        postings.firstWhere(
          (p) => !p.accountId.startsWith('sys_exp_') && !p.accountId.startsWith('cat_'),
          orElse: () => postings.last,
        ).accountId;

    final isReversal = event.reversalOfEventId != null || event.description.startsWith('REVERSAL:');
    final hasReversal = (await database.rawQuery(
      '''SELECT 1 FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ? AND lifecycle_status = 'posted' LIMIT 1''',
      [event.id],
    )).isNotEmpty;

    final status = (isReversal || hasReversal) ? 'reversed' : 'active';
    final String type;
    if (event.canonicalType == CanonicalEventType.cardPayment) {
      type = 'payment';
    } else if (event.canonicalType == CanonicalEventType.refund) {
      type = 'refund';
    } else {
      type = 'purchase';
    }

    return CreditTransaction(
      id: event.id,
      cardId: cardId,
      amount: postings.first.amount.toRupees,
      date: event.occurredAt,
      category: (event.metadata['category_id'] as String?) ?? 'Credit Card',
      note: event.description,
      type: type,
      status: status,
      relatedEntityId: event.metadata['related_entity_id'] as String?,
    );
  }

  /// Operational status update (e.g. 'converted_to_emi', 'billed'). ZERO posting impact.
  Future<void> updateTransactionStatus(String id, String status) async {
    final database = await _db;
    await database.update(
      Tables.creditTransactions,
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Deletes a credit transaction.
  /// If a posted canonical event exists for [id], posts a balanced double-entry reversal
  /// preserving immutable ledger audit history with transactional duplicate protection.
  Future<void> deleteTransaction(String id) async {
    final database = await _db;
    await _runInTransaction(database, (txn) async {
      final eventRepo = _getEventRepo(txn);

      final event = await eventRepo.getEvent(id);
      if (event != null && event.lifecycleStatus == EventLifecycle.posted) {
        // 1. Reject if target is already a reversal
        if (event.reversalOfEventId != null ||
            event.description.startsWith('REVERSAL:')) {
          return;
        }

        // 2. Structured duplicate guard: check if a reversal already exists
        final existingReversal = await txn.rawQuery(
          '''
          SELECT id FROM ${TablesV24.economicEvents}
          WHERE reversal_of_event_id = ? AND lifecycle_status = 'posted'
             OR (
               substr(description, 1, 10) = 'REVERSAL: '
               AND (substr(description, 11) = ? OR substr(description, 11, length(?) + 3) = ? || ' - ')
             )
          LIMIT 1;
          ''',
          [id, id, id, id],
        );

        if (existingReversal.isNotEmpty) {
          // Idempotent rejection: already reversed
          await txn.delete(
            Tables.creditTransactions,
            where: 'id = ?',
            whereArgs: [id],
          );
          return;
        }

        final postings = await eventRepo.getPostingsForEvent(id);
        final reversal = CanonicalCreditAdapter.createReversal(event, postings);
        await eventRepo.createAndPostEvent(
          reversal.event,
          postings: reversal.postings,
        );
      }

      await txn.delete(
        Tables.creditTransactions,
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  // --- Operational EMI / Installment metadata methods (transitional tables) ---

  Future<List<CreditEMI>> getEmis(String cardId) async {
    final database = await _db;
    final res = await database.query(
      Tables.creditEmis,
      where: 'cardId = ?',
      whereArgs: [cardId],
      orderBy: 'startDate DESC',
    );
    return res.map((e) => CreditEMI.fromMap(e)).toList();
  }

  Future<CreditEMI?> getEMIById(String id) async {
    final database = await _db;
    final res = await database.query(
      Tables.creditEmis,
      where: 'id = ?',
      whereArgs: [id],
    );
    return res.isNotEmpty ? CreditEMI.fromMap(res.first) : null;
  }

  Future<void> insertEMI(CreditEMI emi) async {
    final database = await _db;
    await database.insert(Tables.creditEmis, emi.toMap());
  }

  Future<void> updateEMI(CreditEMI emi) async {
    final database = await _db;
    await database.update(
      Tables.creditEmis,
      emi.toMap(),
      where: 'id = ?',
      whereArgs: [emi.id],
    );
  }

  Future<void> deleteEMI(String id) async {
    final database = await _db;
    await database.delete(Tables.creditEmis, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<EMIInstallment>> getInstallments(String emiId) async {
    final database = await _db;
    final res = await database.query(
      Tables.emiInstallments,
      where: 'emiId = ?',
      whereArgs: [emiId],
      orderBy: 'dueDate ASC',
    );
    return res.map((e) => EMIInstallment.fromMap(e)).toList();
  }

  Future<void> insertInstallment(EMIInstallment inst) async {
    final database = await _db;
    await database.insert(Tables.emiInstallments, inst.toMap());
  }

  Future<int> updateInstallment(EMIInstallment installment) async {
    final database = await _db;
    return database.update(
      Tables.emiInstallments,
      installment.toMap(),
      where: 'id = ?',
      whereArgs: [installment.id],
    );
  }

  Future<int> deleteInstallment(String id) async {
    final database = await _db;
    return database.delete(
      Tables.emiInstallments,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteInstallments(String emiId) async {
    final database = await _db;
    await database.delete(
      Tables.emiInstallments,
      where: 'emiId = ?',
      whereArgs: [emiId],
    );
  }

  // --- Operational Statement metadata methods (transitional tables) ---

  Future<void> insertStatement(CardStatement statement) async {
    final database = await _db;
    await database.insert(Tables.cardStatements, statement.toMap());
  }

  Future<void> assignTransactionsToStatement({
    required String statementId,
    required List<String> transactionIds,
  }) async {
    if (transactionIds.isEmpty) return;

    final database = await _db;
    final batch = database.batch();
    for (final id in transactionIds) {
      batch.update(
        Tables.creditTransactions,
        {'statementId': statementId},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<CardStatement>> getStatements(String cardId) async {
    final database = await _db;
    final res = await database.query(
      Tables.cardStatements,
      where: 'cardId = ?',
      whereArgs: [cardId],
      orderBy: 'generatedDate DESC',
    );
    return res.map((e) => CardStatement.fromMap(e)).toList();
  }
}
