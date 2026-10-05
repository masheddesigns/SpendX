import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../../../domain/finance/finance.dart';
import '../../../models/credit_card.dart';
import '../../../models/credit_transaction.dart';
import '../../core/tables_v24.dart';

/// Adapter facilitating bidirectional translation and compatibility projection
/// between legacy [CreditCard] / [CreditTransaction] domain models and canonical v24 accounting entities.
///
/// CRITICAL ARCHITECTURAL INVARIANT:
/// 1. Legacy `credit_cards.used_amount` / `current_balance` is NEVER treated as financial truth.
/// 2. All credit card balances are derived dynamically from canonical double-entry postings
///    via `CanonicalAccountRepository.getDerivedBalance` (Liability: credits - debits).
/// 3. Card purchases produce: Dr Expense, Cr Card Liability.
/// 4. Card payments produce: Dr Card Liability, Cr Bank Asset (ZERO expense/income impact).
/// 5. Card refunds produce: Dr Card Liability, Cr Expense / Contra-Expense (ZERO income impact).
/// 6. Opening balances and reconciliation adjustments route through canonical
///    [CanonicalEventType.openingBalance] events balancing against [TablesV24.sysEquityOpening].
class CanonicalCreditAdapter {
  /// Converts a legacy [CreditCard] to an insert/update row for `TablesV24.accounts`.
  static Map<String, dynamic> toAccountsRow(CreditCard card) {
    return {
      'id': card.id,
      'account_type': 'liability',
      'subtype': 'credit_card',
      'name': card.name,
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'parent_account_id': null,
      'institution_name': card.bank,
      'account_number_last4': card.last4,
      'color_hex': card.color,
      'icon_name': card.cardType,
      'credit_limit_minor_units': (card.limitAmount * 100.0).round(),
      'billing_cycle_day': card.billingDay,
      'payment_due_day': card.dueDay,
      'created_at': card.createdAt.toIso8601String(),
      'updated_at': card.createdAt.toIso8601String(),
    };
  }

  /// Projects a canonical `accounts` row and its derived [Money] liability balance
  /// into a legacy [CreditCard] model expected by UI and callers.
  static CreditCard toCreditCard(
    Map<String, dynamic> row,
    Money derivedLiabilityBalance, {
    Map<String, dynamic>? transitionalCardRow,
  }) {
    final limitMinor = row['credit_limit_minor_units'] as int?;
    final limitAmount = limitMinor != null ? limitMinor / 100.0 : 0.0;
    final billingDay = (row['billing_cycle_day'] as int?) ?? 1;
    final dueDay = (row['payment_due_day'] as int?) ?? 20;

    return CreditCard(
      id: row['id'] as String,
      userId: 'offline_user',
      name: row['name'] as String,
      bank: (row['institution_name'] as String?) ?? '',
      last4: (row['account_number_last4'] as String?) ?? '0000',
      limitAmount: limitAmount,
      billingDay: billingDay,
      dueDay: dueDay,
      cardType: (row['icon_name'] as String?) ?? 'visa',
      color: (row['color_hex'] as String?) ?? '#6366F1',
      usedAmount: derivedLiabilityBalance.toRupees, // STRICTLY DERIVED FROM CANONICAL POSTINGS
      lastStatementBalance:
          ((transitionalCardRow?['last_statement_balance'] as num?)?.toDouble() ?? 0.0),
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  /// Ensures core system accounts exist in `TablesV24.accounts`.
  static Future<void> ensureSystemAccountsExist(DatabaseExecutor db) async {
    final now = DateTime.now().toIso8601String();
    final systemAccounts = <Map<String, dynamic>>[
      {
        'id': TablesV24.sysEquityOpening,
        'account_type': 'equity',
        'subtype': 'opening_balance',
        'name': 'Equity:OpeningBalance',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': TablesV24.sysExpRefunds,
        'account_type': 'expense',
        'subtype': 'contra_expense',
        'name': 'Expense:General:Refunds',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': TablesV24.sysExpMisc,
        'account_type': 'expense',
        'subtype': 'general',
        'name': 'Expense:General:Miscellaneous',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
    ];

    for (final sa in systemAccounts) {
      final existing = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [sa['id']],
        limit: 1,
      );
      if (existing.isEmpty) {
        await db.insert(
          TablesV24.accounts,
          sa,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
  }

  /// Ensures referenced accounts exist in `accounts` table prior to posting creation.
  static Future<void> ensureAccountsExist(
    DatabaseExecutor db, {
    required String cardId,
    String? expenseAccountId,
    String? assetAccountId,
  }) async {
    await ensureSystemAccountsExist(db);
    final now = DateTime.now().toIso8601String();

    // Check card liability account
    final cardRows = await db.query(
      TablesV24.accounts,
      where: 'id = ?',
      whereArgs: [cardId],
      limit: 1,
    );
    if (cardRows.isEmpty) {
      await db.insert(
        TablesV24.accounts,
        {
          'id': cardId,
          'account_type': 'liability',
          'subtype': 'credit_card',
          'name': 'Credit Card $cardId',
          'currency': 'INR',
          'is_active': 1,
          'is_system': 0,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    // Check expense account
    if (expenseAccountId != null && expenseAccountId.isNotEmpty) {
      final expRows = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [expenseAccountId],
        limit: 1,
      );
      if (expRows.isEmpty) {
        await db.insert(
          TablesV24.accounts,
          {
            'id': expenseAccountId,
            'account_type': 'expense',
            'subtype': 'category',
            'name': 'Expense $expenseAccountId',
            'currency': 'INR',
            'is_active': 1,
            'is_system': 0,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }

    // Check asset account
    if (assetAccountId != null && assetAccountId.isNotEmpty) {
      final assetRows = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [assetAccountId],
        limit: 1,
      );
      if (assetRows.isEmpty) {
        await db.insert(
          TablesV24.accounts,
          {
            'id': assetAccountId,
            'account_type': 'asset',
            'subtype': 'liquid_cash',
            'name': 'Asset $assetAccountId',
            'currency': 'INR',
            'is_active': 1,
            'is_system': 0,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
  }

  /// Generates canonical opening balance records when a credit card is created
  /// with a non-zero initial outstanding amount.
  /// Returns `null` if initial outstanding is zero (0 financial postings).
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
    OpeningBalanceReconciliation reconciliation,
  })? createOpeningBalanceRecords(
    CreditCard card, {
    String reason = 'Credit card initial outstanding',
    String provenance = 'manual_card_creation',
  }) {
    final absPaise = (card.usedAmount.abs() * 100.0).round();
    if (absPaise == 0) return null;

    final amount = Money.fromMinorUnits(absPaise);
    final eventId = 'evt_ob_${card.id}';
    final now = card.createdAt;

    // Credit Card Liability increases with Credit; offset by Debit Equity:OpeningBalance
    final List<Posting> postings = [
      Posting(
        id: 'pst_${eventId}_1',
        economicEventId: eventId,
        accountId: card.id,
        direction: PostingDirection.credit,
        amount: amount,
        createdAt: now,
      ),
      Posting(
        id: 'pst_${eventId}_2',
        economicEventId: eventId,
        accountId: TablesV24.sysEquityOpening,
        direction: PostingDirection.debit,
        amount: amount,
        createdAt: now,
      ),
    ];

    final rawPayload = jsonEncode({
      'card_id': card.id,
      'outstanding': card.usedAmount,
    });
    final hash = sha256.convert(utf8.encode(rawPayload)).toString();

    final event = EconomicEvent(
      id: eventId,
      canonicalType: CanonicalEventType.openingBalance,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: now,
      description: 'Initial balance for ${card.name}',
      metadata: {'card_id': card.id, 'provenance': provenance},
      postings: postings,
      createdAt: now,
    );

    final evidence = Evidence(
      id: 'evi_ob_${card.id}',
      economicEventId: eventId,
      sourceType: 'manual',
      sourceTimestamp: now,
      extractedAmount: amount,
      bodyFingerprint: hash,
      rawPayloadEncrypted: rawPayload,
      createdAt: now,
    );

    final reconciliation = OpeningBalanceReconciliation(
      id: 'rec_ob_${card.id}',
      accountId: card.id,
      legacyReportedBalance: Money.fromRupees(card.usedAmount),
      reconstructedBalanceFromTxns: Money.zero,
      reconciliationReason: reason,
      provenanceSource: provenance,
      status: ReconciliationStatus.equityAdjustmentRequired,
      generatedEventId: eventId,
      createdAt: now,
    );

    return (
      event: event,
      postings: postings,
      evidence: evidence,
      reconciliation: reconciliation,
    );
  }

  /// Generates canonical balance reconciliation records when a reported outstanding amount
  /// diverges from the derived ledger liability balance.
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
    OpeningBalanceReconciliation reconciliation,
  })? createReconciliationRecords({
    required String cardId,
    required String cardName,
    required Money currentLiability,
    required Money targetLiability,
    String reason = 'Statement balance reconciliation',
    String provenance = 'sms_card_balance_update',
    DateTime? timestamp,
  }) {
    final deltaPaise = targetLiability.minorUnits - currentLiability.minorUnits;
    if (deltaPaise == 0) return null;

    final absPaise = deltaPaise.abs();
    final amount = Money.fromMinorUnits(absPaise);
    final now = timestamp ?? DateTime.now();
    final eventId = 'evt_rec_${cardId}_${now.millisecondsSinceEpoch}';

    final List<Posting> postings;
    if (deltaPaise > 0) {
      // Liability increased: Credit Card Liability, Debit sys_equity_opening
      postings = [
        Posting(
          id: 'pst_${eventId}_1',
          economicEventId: eventId,
          accountId: cardId,
          direction: PostingDirection.credit,
          amount: amount,
          createdAt: now,
        ),
        Posting(
          id: 'pst_${eventId}_2',
          economicEventId: eventId,
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.debit,
          amount: amount,
          createdAt: now,
        ),
      ];
    } else {
      // Liability decreased: Debit Card Liability, Credit sys_equity_opening
      postings = [
        Posting(
          id: 'pst_${eventId}_1',
          economicEventId: eventId,
          accountId: cardId,
          direction: PostingDirection.debit,
          amount: amount,
          createdAt: now,
        ),
        Posting(
          id: 'pst_${eventId}_2',
          economicEventId: eventId,
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.credit,
          amount: amount,
          createdAt: now,
        ),
      ];
    }

    final rawPayload = jsonEncode({
      'card_id': cardId,
      'current_minor': currentLiability.minorUnits,
      'target_minor': targetLiability.minorUnits,
    });
    final hash = sha256.convert(utf8.encode(rawPayload)).toString();

    final event = EconomicEvent(
      id: eventId,
      canonicalType: CanonicalEventType.openingBalance,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: now,
      description: 'Outstanding adjustment for $cardName',
      metadata: {'card_id': cardId, 'provenance': provenance},
      postings: postings,
      createdAt: now,
    );

    final evidence = Evidence(
      id: 'evi_$eventId',
      economicEventId: eventId,
      sourceType: provenance.startsWith('sms') ? 'sms' : 'manual',
      sourceTimestamp: now,
      extractedAmount: amount,
      bodyFingerprint: hash,
      rawPayloadEncrypted: rawPayload,
      createdAt: now,
    );

    final reconciliation = OpeningBalanceReconciliation(
      id: 'rec_$eventId',
      accountId: cardId,
      legacyReportedBalance: targetLiability,
      reconstructedBalanceFromTxns: currentLiability,
      reconciliationReason: reason,
      provenanceSource: provenance,
      status: ReconciliationStatus.equityAdjustmentRequired,
      generatedEventId: eventId,
      createdAt: now,
    );

    return (
      event: event,
      postings: postings,
      evidence: evidence,
      reconciliation: reconciliation,
    );
  }

  /// Translates a [CreditTransaction] into a canonical [EconomicEvent], balanced [Posting] legs,
  /// and [Evidence].
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
  }) toEconomicEventAndPostings(
    CreditTransaction tx, {
    String? defaultAssetAccountId,
  }) {
    final eventId = tx.id;
    final now = tx.date;
    final amount = Money.fromRupees(tx.amount.abs());
    final rawPayload = jsonEncode(tx.toMap());
    final hash = sha256.convert(utf8.encode(rawPayload)).toString();

    final CanonicalEventType eventType;
    final List<Posting> postings;

    switch (tx.type.toLowerCase()) {
      case 'payment':
        eventType = CanonicalEventType.cardPayment;
        final assetAcc = (tx.categoryId != null && tx.categoryId!.isNotEmpty)
            ? tx.categoryId!
            : (defaultAssetAccountId ?? 'acc_bank_default');
        postings = [
          // Debit Card Liability (reduces liability)
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: tx.cardId,
            direction: PostingDirection.debit,
            amount: amount,
            createdAt: now,
          ),
          // Credit Bank Asset (reduces bank asset)
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: assetAcc,
            direction: PostingDirection.credit,
            amount: amount,
            createdAt: now,
          ),
        ];
        break;

      case 'refund':
        eventType = CanonicalEventType.refund;
        final expAcc = tx.categoryId != null && tx.categoryId!.isNotEmpty
            ? tx.categoryId!
            : TablesV24.sysExpRefunds;
        postings = [
          // Debit Card Liability (reduces card liability)
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: tx.cardId,
            direction: PostingDirection.debit,
            amount: amount,
            createdAt: now,
          ),
          // Credit Contra-Expense (reduces expense, zero income)
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: expAcc,
            direction: PostingDirection.credit,
            amount: amount,
            createdAt: now,
          ),
        ];
        break;

      case 'interest_charge':
      case 'processing_fee':
        eventType = CanonicalEventType.expense;
        final expAcc = tx.categoryId != null && tx.categoryId!.isNotEmpty
            ? tx.categoryId!
            : TablesV24.sysExpMisc;
        postings = [
          // Debit Expense
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: expAcc,
            direction: PostingDirection.debit,
            amount: amount,
            createdAt: now,
          ),
          // Credit Card Liability
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: tx.cardId,
            direction: PostingDirection.credit,
            amount: amount,
            createdAt: now,
          ),
        ];
        break;

      case 'purchase':
      case 'emi_installment':
      default:
        eventType = CanonicalEventType.cardPurchase;
        final expAcc = tx.categoryId != null && tx.categoryId!.isNotEmpty
            ? tx.categoryId!
            : TablesV24.sysExpMisc;
        postings = [
          // Debit Expense
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: expAcc,
            direction: PostingDirection.debit,
            amount: amount,
            createdAt: now,
          ),
          // Credit Card Liability
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: tx.cardId,
            direction: PostingDirection.credit,
            amount: amount,
            createdAt: now,
          ),
        ];
        break;
    }

    final event = EconomicEvent(
      id: eventId,
      canonicalType: eventType,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: now,
      description: tx.note ?? '${tx.type} on card ${tx.cardId}',
      metadata: {
        'card_id': tx.cardId,
        'category_id': tx.categoryId,
        'type': tx.type,
        'source': 'credit_repo',
      },
      postings: postings,
      createdAt: now,
    );

    final evidence = Evidence(
      id: 'evi_$eventId',
      economicEventId: eventId,
      sourceType: 'manual',
      sourceTimestamp: now,
      extractedAmount: amount,
      bodyFingerprint: hash,
      rawPayloadEncrypted: rawPayload,
      createdAt: now,
    );

    return (
      event: event,
      postings: postings,
      evidence: evidence,
    );
  }

  /// Creates a balanced reversal event targeting [originalEvent].
  static ({
    EconomicEvent event,
    List<Posting> postings,
  }) createReversal(
    EconomicEvent originalEvent,
    List<Posting> originalPostings,
  ) {
    final reversalId = 'rev_${originalEvent.id}_${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now();

    final reversalPostings = originalPostings.map((p) {
      return Posting(
        id: 'pst_${reversalId}_${p.id}',
        economicEventId: reversalId,
        accountId: p.accountId,
        direction: p.direction.opposite,
        amount: p.amount,
        createdAt: now,
      );
    }).toList();

    final reversalEvent = EconomicEvent(
      id: reversalId,
      canonicalType: originalEvent.canonicalType,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: now,
      description: 'REVERSAL: ${originalEvent.id}',
      metadata: {
        'reversal_of': originalEvent.id,
      },
      postings: reversalPostings,
      createdAt: now,
    );

    return (
      event: reversalEvent,
      postings: reversalPostings,
    );
  }
}
