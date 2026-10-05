import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../../../domain/finance/finance.dart';
import '../../../models/bank_account.dart';
import '../../core/tables_v24.dart';

/// Adapter facilitating bidirectional translation and compatibility projection
/// between legacy [BankAccount] domain models and canonical v24 accounting entities.
///
/// CRITICAL ARCHITECTURAL INVARIANT:
/// 1. Legacy `bank_accounts.balance` is NEVER treated as financial truth.
/// 2. All balances projected into [BankAccount.balance] are derived dynamically
///    from canonical double-entry postings (`TablesV24.postings`).
/// 3. Account creation with non-zero initial balance establishes opening equity
///    via canonical [CanonicalEventType.openingBalance] events balancing against [TablesV24.sysEquityOpening].
class CanonicalAccountAdapter {
  /// Converts a legacy [BankAccount] to a canonical domain [Account].
  static Account toCanonicalAccount(BankAccount account) {
    return Account(
      id: account.id,
      name: account.name,
      type: account.isAsset ? AccountType.asset : AccountType.liability,
      category: account.accountType,
      currency: 'INR',
      isActive: true,
      createdAt: account.createdAt,
      updatedAt: account.updatedAt,
    );
  }

  /// Converts a legacy [BankAccount] to an insert row for `TablesV24.accounts`.
  static Map<String, dynamic> toAccountsRow(BankAccount account) {
    return {
      'id': account.id,
      'account_type': account.isAsset ? 'asset' : 'liability',
      'subtype': account.accountType,
      'name': account.name,
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'parent_account_id': null,
      'institution_name': account.bank,
      'account_number_last4': account.last4,
      'color_hex': account.color,
      'icon_name': account.icon,
      'created_at': account.createdAt.toIso8601String(),
      'updated_at': account.updatedAt.toIso8601String(),
    };
  }

  /// Projects a canonical `accounts` row and its derived [Money] balance into
  /// a legacy [BankAccount] model expected by UI and callers.
  static BankAccount toBankAccount(
    Map<String, dynamic> row,
    Money derivedBalance,
  ) {
    final subtype = (row['subtype'] as String?) ?? 'savings';
    return BankAccount(
      id: row['id'] as String,
      userId: 'offline_user',
      name: row['name'] as String,
      bank: (row['institution_name'] as String?) ?? '',
      accountType: subtype,
      balance: derivedBalance.toRupees,
      color: (row['color_hex'] as String?) ?? BankAccount.colorForType(subtype),
      icon: (row['icon_name'] as String?) ?? BankAccount.iconForType(subtype),
      isAsset: (row['account_type'] as String) == 'asset',
      last4: row['account_number_last4'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  /// Verifies that system accounts (specifically [TablesV24.sysEquityOpening])
  /// exist in `accounts` table, provisioning them if missing.
  static Future<void> ensureSystemAccountsExist(DatabaseExecutor db) async {
    final existing = await db.query(
      TablesV24.accounts,
      where: 'id = ?',
      whereArgs: [TablesV24.sysEquityOpening],
      limit: 1,
    );
    if (existing.isEmpty) {
      final now = DateTime.now().toIso8601String();
      await db.insert(
        TablesV24.accounts,
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
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  /// Generates canonical opening balance records for account creation.
  /// Returns `null` if the initial balance is zero (0 posting impact).
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
    OpeningBalanceReconciliation reconciliation,
  })? createOpeningBalanceRecords(
    BankAccount account, {
    String reason = 'Account opening balance',
    String provenance = 'manual_account_creation',
  }) {
    final absPaise = (account.balance.abs() * 100.0).round();
    if (absPaise == 0) return null;

    final amount = Money.fromMinorUnits(absPaise);
    final eventId = 'evt_ob_${account.id}';
    final now = account.createdAt;

    final List<Posting> postings;
    if (account.balance > 0) {
      // Asset increases: Debit Asset, Credit sys_equity_opening
      postings = [
        Posting(
          id: 'pst_${eventId}_1',
          economicEventId: eventId,
          accountId: account.id,
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
    } else {
      // Asset decreases/negative: Credit Asset, Debit sys_equity_opening
      postings = [
        Posting(
          id: 'pst_${eventId}_1',
          economicEventId: eventId,
          accountId: account.id,
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
    }

    final rawPayload = jsonEncode({
      'account_id': account.id,
      'balance': account.balance,
    });
    final hash = sha256.convert(utf8.encode(rawPayload)).toString();

    final event = EconomicEvent(
      id: eventId,
      canonicalType: CanonicalEventType.openingBalance,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: now,
      description: 'Opening balance for ${account.name}',
      metadata: {'account_id': account.id, 'provenance': provenance},
      postings: postings,
      createdAt: now,
    );

    final evidence = Evidence(
      id: 'evi_ob_${account.id}',
      economicEventId: eventId,
      sourceType: 'manual',
      sourceTimestamp: now,
      extractedAmount: amount,
      bodyFingerprint: hash,
      rawPayloadEncrypted: rawPayload,
      createdAt: now,
    );

    final reconciliation = OpeningBalanceReconciliation(
      id: 'rec_ob_${account.id}',
      accountId: account.id,
      legacyReportedBalance: Money.fromRupees(account.balance),
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

  /// Generates canonical balance reconciliation records when a reported balance
  /// (e.g. from SMS or statement reconciliation) diverges from the derived ledger balance.
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
    OpeningBalanceReconciliation reconciliation,
  })? createReconciliationRecords({
    required String accountId,
    required String accountName,
    required Money currentBalance,
    required Money targetBalance,
    String reason = 'Statement balance reconciliation',
    String provenance = 'sms_balance_update',
    DateTime? timestamp,
  }) {
    final deltaPaise = targetBalance.minorUnits - currentBalance.minorUnits;
    if (deltaPaise == 0) return null;

    final absPaise = deltaPaise.abs();
    final amount = Money.fromMinorUnits(absPaise);
    final now = timestamp ?? DateTime.now();
    final eventId = 'evt_rec_${accountId}_${now.millisecondsSinceEpoch}';

    final List<Posting> postings;
    if (deltaPaise > 0) {
      // Balance increased: Debit account, Credit sys_equity_opening
      postings = [
        Posting(
          id: 'pst_${eventId}_1',
          economicEventId: eventId,
          accountId: accountId,
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
    } else {
      // Balance decreased: Credit account, Debit sys_equity_opening
      postings = [
        Posting(
          id: 'pst_${eventId}_1',
          economicEventId: eventId,
          accountId: accountId,
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
    }

    final rawPayload = jsonEncode({
      'account_id': accountId,
      'current_minor': currentBalance.minorUnits,
      'target_minor': targetBalance.minorUnits,
    });
    final hash = sha256.convert(utf8.encode(rawPayload)).toString();

    final event = EconomicEvent(
      id: eventId,
      canonicalType: CanonicalEventType.openingBalance,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: now,
      description: 'Reconciliation adjustment for $accountName',
      metadata: {'account_id': accountId, 'provenance': provenance},
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
      accountId: accountId,
      legacyReportedBalance: targetBalance,
      reconstructedBalanceFromTxns: currentBalance,
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
}
