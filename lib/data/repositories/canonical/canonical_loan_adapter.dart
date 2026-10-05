import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../../../domain/finance/finance.dart';
import '../../../models/loan.dart';
import '../../core/tables_v24.dart';

/// Adapter facilitating bidirectional translation and compatibility projection
/// between legacy [Loan] domain models and canonical v24 double-entry accounting entities.
///
/// CRITICAL ARCHITECTURAL INVARIANTS:
/// 1. Legacy `loans.total`, `loans.paid_amount`, and `loans.loan_status` are NEVER
///    treated as independent authoritative financial truth.
/// 2. All loan balances are derived dynamically from canonical double-entry postings
///    via `CanonicalAccountRepository.getDerivedBalance` (Liability: credits - debits).
/// 3. Loan disbursement produces:
///    Dr Bank Asset (receives funds), Cr Loan Liability (debt owed). Net worth unchanged.
/// 4. Principal repayment produces:
///    Dr Loan Liability (reduces debt), Cr Bank Asset (source of funds). Net worth unchanged.
/// 5. Interest payment produces:
///    Dr Interest Expense (`sys_exp_interest`), Cr Bank Asset. Principal liability unaffected.
/// 6. Combined EMI payment produces:
///    Dr Loan Liability (principal), Dr Interest Expense (interest), Cr Bank Asset (total EMI).
/// 7. Opening balances and reconciliation adjustments route strictly through canonical
///    [CanonicalEventType.openingBalance] or [CanonicalEventType.adjustment] events
///    balancing against [TablesV24.sysEquityOpening].
/// 8. Expected loan installments in operational schedule tables NEVER generate accounting postings.
class CanonicalLoanAdapter {
  /// Converts a legacy [Loan] to an insert/update row for `TablesV24.accounts`.
  static Map<String, dynamic> toAccountsRow(Loan loan) {
    final now = DateTime.now().toIso8601String();
    return {
      'id': loan.id,
      'account_type': 'liability',
      'subtype': 'loan',
      'name': loan.name,
      'currency': 'INR',
      'is_active': loan.loanStatus == 'closed' ? 0 : 1,
      'is_system': 0,
      'parent_account_id': null,
      'institution_name': loan.bank,
      'account_number_last4': null,
      'color_hex': null,
      'icon_name': loan.type.name,
      'credit_limit_minor_units': null,
      'billing_cycle_day': null,
      'payment_due_day': loan.dueDay,
      'principal_original_minor_units': (loan.total * 100.0).round(),
      'interest_rate_basis_points': (loan.interestRate * 100.0).round(),
      'tenure_months': loan.tenureMonths,
      'monthly_installment_minor_units': (loan.monthlyInstallment * 100.0).round(),
      'start_date': loan.startDate.toIso8601String(),
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Projects a canonical `accounts` row and its derived [Money] liability balance
  /// into a legacy [Loan] model expected by UI and callers.
  static Loan toLoan(
    Map<String, dynamic> row,
    Money derivedLiabilityBalance, {
    Map<String, dynamic>? transitionalLoanRow,
  }) {
    final principalMinor = row['principal_original_minor_units'] as int?;
    final total = principalMinor != null
        ? principalMinor / 100.0
        : (transitionalLoanRow?['total'] as num?)?.toDouble() ?? derivedLiabilityBalance.toRupees;

    final rateBps = row['interest_rate_basis_points'] as int?;
    final interestRate = rateBps != null
        ? rateBps / 100.0
        : (transitionalLoanRow?['interest_rate'] as num?)?.toDouble() ?? 0.0;

    final tenureMonths = (row['tenure_months'] as int?) ??
        (transitionalLoanRow?['tenure_months'] as int?) ??
        0;

    final emiMinor = row['monthly_installment_minor_units'] as int?;
    final monthlyInstallment = emiMinor != null
        ? emiMinor / 100.0
        : (transitionalLoanRow?['monthly_installment'] as num?)?.toDouble() ?? 0.0;

    final startDateStr = (row['start_date'] as String?) ??
        (transitionalLoanRow?['start_date'] as String?);
    final startDate = startDateStr != null ? DateTime.parse(startDateStr) : DateTime.now();

    final remaining = derivedLiabilityBalance.toRupees;
    // Derive paid amount: max(0, total - remaining)
    final double derivedPaidAmount;
    if (derivedLiabilityBalance.minorUnits <= 0) {
      derivedPaidAmount = total;
    } else {
      derivedPaidAmount = (total - remaining).clamp(0.0, total);
    }

    final int isActive = (row['is_active'] as int?) ?? 1;
    final String loanStatus;
    if (isActive == 0 || derivedLiabilityBalance.minorUnits <= 0) {
      loanStatus = 'closed';
    } else {
      loanStatus = (transitionalLoanRow?['loan_status'] as String?) ?? 'active';
    }

    final nextDueDateStr = transitionalLoanRow?['next_due_date'] as String?;
    final nextDueDate = nextDueDateStr != null ? DateTime.parse(nextDueDateStr) : null;

    final dueDay = (row['payment_due_day'] as int?) ??
        (transitionalLoanRow?['due_day'] as int?) ??
        1;

    final rawType = (transitionalLoanRow?['loan_type'] as String?) ??
        (row['icon_name'] as String?) ??
        'reducing';
    final type = LoanType.values.firstWhere(
      (e) => e.name == rawType,
      orElse: () => LoanType.reducing,
    );

    return Loan(
      id: row['id'] as String,
      name: row['name'] as String,
      bank: (row['institution_name'] as String?) ??
          (transitionalLoanRow?['bank'] as String?) ??
          '',
      total: total,
      interestRate: interestRate,
      tenureMonths: tenureMonths,
      monthlyInstallment: monthlyInstallment,
      startDate: startDate,
      paidAmount: derivedPaidAmount, // STRICTLY DERIVED FROM CANONICAL POSTINGS
      loanStatus: loanStatus,
      nextDueDate: nextDueDate,
      categoryId: transitionalLoanRow?['category_id'] as String?,
      dueDay: dueDay,
      type: type,
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
        'id': TablesV24.sysExpInterest,
        'account_type': 'expense',
        'subtype': 'financial_interest',
        'name': 'Expense:Financial:Interest',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
      {
        'id': TablesV24.sysSuspenseLoan,
        'account_type': 'liability',
        'subtype': 'suspense_loan',
        'name': 'Suspense:Loan',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      },
    ];

    for (final acc in systemAccounts) {
      await db.insert(
        TablesV24.accounts,
        acc,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  /// Generates canonical opening balance records when a loan is created
  /// with a non-zero initial principal/outstanding amount.
  /// Returns `null` if initial liability is zero (0 financial postings).
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
    OpeningBalanceReconciliation reconciliation,
  })? createOpeningBalanceRecords(
    Loan loan, {
    String reason = 'Initial loan opening balance',
    String provenance = 'manual_loan_creation',
  }) {
    final initialLiability = (loan.total - loan.paidAmount).clamp(0.0, loan.total);
    final absPaise = (initialLiability * 100.0).round();
    if (absPaise == 0) return null;

    final amount = Money.fromMinorUnits(absPaise);
    final eventId = 'evt_ob_${loan.id}';
    final now = loan.startDate;

    // Loan Liability increases with Credit; offset by Debit Equity:OpeningBalance
    final List<Posting> postings = [
      Posting(
        id: 'pst_${eventId}_1',
        economicEventId: eventId,
        accountId: loan.id,
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
      'loan_id': loan.id,
      'total': loan.total,
      'paid_amount': loan.paidAmount,
      'initial_liability': initialLiability,
    });
    final hash = sha256.convert(utf8.encode(rawPayload)).toString();

    final event = EconomicEvent(
      id: eventId,
      canonicalType: CanonicalEventType.openingBalance,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: now,
      description: 'Initial balance for ${loan.name}',
      metadata: {'loan_id': loan.id, 'provenance': provenance},
      postings: postings,
      createdAt: now,
    );

    final evidence = Evidence(
      id: 'evi_ob_${loan.id}',
      economicEventId: eventId,
      sourceType: 'manual',
      sourceTimestamp: now,
      extractedAmount: amount,
      bodyFingerprint: hash,
      rawPayloadEncrypted: rawPayload,
      createdAt: now,
    );

    final reconciliation = OpeningBalanceReconciliation(
      id: 'rec_ob_${loan.id}',
      accountId: loan.id,
      legacyReportedBalance: Money.fromRupees(initialLiability),
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

  /// Generates canonical records for loan disbursement:
  /// Dr Bank Asset (receives funds), Cr Loan Liability (debt owed).
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
  }) createDisbursementRecords({
    required String loanId,
    required String assetAccountId,
    required Money amount,
    required DateTime timestamp,
    String? description,
    String? externalRef,
    String? eventId,
  }) {
    final eId = eventId ?? 'evt_disb_${loanId}_${timestamp.millisecondsSinceEpoch}';
    final desc = description ?? 'Loan Disbursement for $loanId';

    final postings = [
      Posting(
        id: 'pst_${eId}_dr',
        economicEventId: eId,
        accountId: assetAccountId,
        direction: PostingDirection.debit,
        amount: amount,
        createdAt: timestamp,
      ),
      Posting(
        id: 'pst_${eId}_cr',
        economicEventId: eId,
        accountId: loanId,
        direction: PostingDirection.credit,
        amount: amount,
        createdAt: timestamp,
      ),
    ];

    final payload = jsonEncode({
      'loan_id': loanId,
      'asset_account_id': assetAccountId,
      'amount': amount.toRupees,
      'type': 'loan_disbursement',
      'external_ref': externalRef,
    });
    final hash = sha256.convert(utf8.encode(payload)).toString();

    final event = EconomicEvent(
      id: eId,
      canonicalType: CanonicalEventType.loanDisbursement,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: timestamp,
      description: desc,
      metadata: {
        'loan_id': loanId,
        'asset_account_id': assetAccountId,
        'external_ref': ?externalRef,
      },
      postings: postings,
      createdAt: timestamp,
    );

    final evidence = Evidence(
      id: 'evi_$eId',
      economicEventId: eId,
      sourceType: 'manual',
      sourceTimestamp: timestamp,
      extractedAmount: amount,
      bodyFingerprint: hash,
      rawPayloadEncrypted: payload,
      createdAt: timestamp,
    );

    return (
      event: event,
      postings: postings,
      evidence: evidence,
    );
  }

  /// Generates canonical records for principal repayment:
  /// Dr Loan Liability (reduces debt), Cr Bank Asset (source of payment).
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
  }) createRepaymentRecords({
    required String loanId,
    required String assetAccountId,
    required Money principalAmount,
    required DateTime timestamp,
    String? description,
    String? externalRef,
    String? eventId,
  }) {
    final eId = eventId ?? 'evt_repay_${loanId}_${timestamp.millisecondsSinceEpoch}';
    final desc = description ?? 'Loan Principal Repayment for $loanId';

    final postings = [
      Posting(
        id: 'pst_${eId}_dr',
        economicEventId: eId,
        accountId: loanId,
        direction: PostingDirection.debit,
        amount: principalAmount,
        createdAt: timestamp,
      ),
      Posting(
        id: 'pst_${eId}_cr',
        economicEventId: eId,
        accountId: assetAccountId,
        direction: PostingDirection.credit,
        amount: principalAmount,
        createdAt: timestamp,
      ),
    ];

    final payload = jsonEncode({
      'loan_id': loanId,
      'asset_account_id': assetAccountId,
      'principal_amount': principalAmount.toRupees,
      'type': 'loan_repayment',
      'external_ref': ?externalRef,
    });
    final hash = sha256.convert(utf8.encode(payload)).toString();

    final event = EconomicEvent(
      id: eId,
      canonicalType: CanonicalEventType.loanRepayment,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: timestamp,
      description: desc,
      metadata: {
        'loan_id': loanId,
        'asset_account_id': assetAccountId,
        'external_ref': ?externalRef,
      },
      postings: postings,
      createdAt: timestamp,
    );

    final evidence = Evidence(
      id: 'evi_$eId',
      economicEventId: eId,
      sourceType: 'manual',
      sourceTimestamp: timestamp,
      extractedAmount: principalAmount,
      bodyFingerprint: hash,
      rawPayloadEncrypted: payload,
      createdAt: timestamp,
    );

    return (
      event: event,
      postings: postings,
      evidence: evidence,
    );
  }

  /// Generates canonical records for loan interest payment:
  /// Dr Interest Expense (`sys_exp_interest`), Cr Bank Asset.
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
  }) createInterestPaymentRecords({
    required String loanId,
    required String assetAccountId,
    required Money interestAmount,
    required DateTime timestamp,
    String? description,
    String? externalRef,
    String? eventId,
  }) {
    final eId = eventId ?? 'evt_interest_${loanId}_${timestamp.millisecondsSinceEpoch}';
    final desc = description ?? 'Loan Interest Payment for $loanId';

    final postings = [
      Posting(
        id: 'pst_${eId}_dr',
        economicEventId: eId,
        accountId: TablesV24.sysExpInterest,
        direction: PostingDirection.debit,
        amount: interestAmount,
        createdAt: timestamp,
      ),
      Posting(
        id: 'pst_${eId}_cr',
        economicEventId: eId,
        accountId: assetAccountId,
        direction: PostingDirection.credit,
        amount: interestAmount,
        createdAt: timestamp,
      ),
    ];

    final payload = jsonEncode({
      'loan_id': loanId,
      'asset_account_id': assetAccountId,
      'interest_amount': interestAmount.toRupees,
      'type': 'loan_interest',
      'external_ref': ?externalRef,
    });
    final hash = sha256.convert(utf8.encode(payload)).toString();

    final event = EconomicEvent(
      id: eId,
      canonicalType: CanonicalEventType.loanRepayment,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: timestamp,
      description: desc,
      metadata: {
        'loan_id': loanId,
        'asset_account_id': assetAccountId,
        'interest_only': true,
        'external_ref': ?externalRef,
      },
      postings: postings,
      createdAt: timestamp,
    );

    final evidence = Evidence(
      id: 'evi_$eId',
      economicEventId: eId,
      sourceType: 'manual',
      sourceTimestamp: timestamp,
      extractedAmount: interestAmount,
      bodyFingerprint: hash,
      rawPayloadEncrypted: payload,
      createdAt: timestamp,
    );

    return (
      event: event,
      postings: postings,
      evidence: evidence,
    );
  }

  /// Generates canonical records for combined EMI payment (principal + interest):
  /// Dr Loan Liability (principal)
  /// Dr Interest Expense (interest)
  /// Cr Bank Asset (total EMI)
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
  }) createCombinedPaymentRecords({
    required String loanId,
    required String assetAccountId,
    required Money principalAmount,
    required Money interestAmount,
    required DateTime timestamp,
    String? description,
    String? externalRef,
    String? eventId,
  }) {
    final eId = eventId ?? 'evt_emi_${loanId}_${timestamp.millisecondsSinceEpoch}';
    final totalEmi = Money.fromMinorUnits(principalAmount.minorUnits + interestAmount.minorUnits);
    final desc = description ?? 'Loan EMI Repayment for $loanId';

    final postings = [
      Posting(
        id: 'pst_${eId}_p',
        economicEventId: eId,
        accountId: loanId,
        direction: PostingDirection.debit,
        amount: principalAmount,
        createdAt: timestamp,
      ),
      Posting(
        id: 'pst_${eId}_i',
        economicEventId: eId,
        accountId: TablesV24.sysExpInterest,
        direction: PostingDirection.debit,
        amount: interestAmount,
        createdAt: timestamp,
      ),
      Posting(
        id: 'pst_${eId}_bank',
        economicEventId: eId,
        accountId: assetAccountId,
        direction: PostingDirection.credit,
        amount: totalEmi,
        createdAt: timestamp,
      ),
    ];

    final payload = jsonEncode({
      'loan_id': loanId,
      'asset_account_id': assetAccountId,
      'principal_amount': principalAmount.toRupees,
      'interest_amount': interestAmount.toRupees,
      'total_emi': totalEmi.toRupees,
      'type': 'combined_emi',
      'external_ref': ?externalRef,
    });
    final hash = sha256.convert(utf8.encode(payload)).toString();

    final event = EconomicEvent(
      id: eId,
      canonicalType: CanonicalEventType.loanRepayment,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: timestamp,
      description: desc,
      metadata: {
        'loan_id': loanId,
        'asset_account_id': assetAccountId,
        'principal_amount': principalAmount.toRupees,
        'interest_amount': interestAmount.toRupees,
        'external_ref': ?externalRef,
      },
      postings: postings,
      createdAt: timestamp,
    );

    final evidence = Evidence(
      id: 'evi_$eId',
      economicEventId: eId,
      sourceType: 'manual',
      sourceTimestamp: timestamp,
      extractedAmount: totalEmi,
      bodyFingerprint: hash,
      rawPayloadEncrypted: payload,
      createdAt: timestamp,
    );

    return (
      event: event,
      postings: postings,
      evidence: evidence,
    );
  }

  /// Generates canonical balance reconciliation records when a reported loan balance
  /// diverges from the derived liability balance.
  /// Emits a balanced [CanonicalEventType.adjustment] event targeting [TablesV24.sysEquityOpening].
  static ({
    EconomicEvent event,
    List<Posting> postings,
    Evidence evidence,
    OpeningBalanceReconciliation reconciliation,
  })? createReconciliationRecords({
    required String loanId,
    required String loanName,
    required Money currentLiability,
    required Money targetLiability,
    String reason = 'Loan balance reconciliation',
    String provenance = 'loan_reconciliation_delta',
  }) {
    final deltaPaise = targetLiability.minorUnits - currentLiability.minorUnits;
    if (deltaPaise == 0) return null;

    final now = DateTime.now();
    final eventId = 'evt_adj_${loanId}_${now.millisecondsSinceEpoch}';
    final adjustmentAmount = Money.fromMinorUnits(deltaPaise.abs());

    // If target > current (liability increased): Cr Loan Liability, Dr Equity:OpeningBalance
    // If target < current (liability decreased): Dr Loan Liability, Cr Equity:OpeningBalance
    final List<Posting> postings = deltaPaise > 0
        ? [
            Posting(
              id: 'pst_${eventId}_1',
              economicEventId: eventId,
              accountId: loanId,
              direction: PostingDirection.credit,
              amount: adjustmentAmount,
              createdAt: now,
            ),
            Posting(
              id: 'pst_${eventId}_2',
              economicEventId: eventId,
              accountId: TablesV24.sysEquityOpening,
              direction: PostingDirection.debit,
              amount: adjustmentAmount,
              createdAt: now,
            ),
          ]
        : [
            Posting(
              id: 'pst_${eventId}_1',
              economicEventId: eventId,
              accountId: loanId,
              direction: PostingDirection.debit,
              amount: adjustmentAmount,
              createdAt: now,
            ),
            Posting(
              id: 'pst_${eventId}_2',
              economicEventId: eventId,
              accountId: TablesV24.sysEquityOpening,
              direction: PostingDirection.credit,
              amount: adjustmentAmount,
              createdAt: now,
            ),
          ];

    final rawPayload = jsonEncode({
      'loan_id': loanId,
      'current_liability_minor': currentLiability.minorUnits,
      'target_liability_minor': targetLiability.minorUnits,
      'delta_minor': deltaPaise,
      'reason': reason,
      'provenance': provenance,
    });
    final hash = sha256.convert(utf8.encode(rawPayload)).toString();

    final event = EconomicEvent(
      id: eventId,
      canonicalType: CanonicalEventType.adjustment,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: now,
      description: 'Reconciliation adjustment for $loanName',
      metadata: {'loan_id': loanId, 'provenance': provenance},
      postings: postings,
      createdAt: now,
    );

    final evidence = Evidence(
      id: 'evi_$eventId',
      economicEventId: eventId,
      sourceType: 'manual',
      sourceTimestamp: now,
      extractedAmount: adjustmentAmount,
      bodyFingerprint: hash,
      rawPayloadEncrypted: rawPayload,
      createdAt: now,
    );

    final reconciliation = OpeningBalanceReconciliation(
      id: 'rec_$eventId',
      accountId: loanId,
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

  /// Creates an append-only reversal event and opposite postings for an existing posted event.
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
