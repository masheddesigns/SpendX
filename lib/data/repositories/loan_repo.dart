import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, Database, DatabaseExecutor, Transaction;

import '../../domain/finance/finance.dart';
import '../../models/loan.dart';
import '../../models/loan_installment.dart';
import '../core/app_database.dart';
import '../core/tables.dart';
import 'canonical/canonical_account_repository.dart';
import 'canonical/canonical_event_repository.dart';
import 'canonical/canonical_loan_adapter.dart';
import 'canonical/canonical_opening_balance_repository.dart';

/// Loan Repository for SpendX.
///
/// Refactored in Milestone C3B-4 to establish the Canonical Loan / Liability Boundary:
/// - Authoritative loan accounts reside in `TablesV24.accounts` with `account_type = 'liability'` and `subtype = 'loan'`.
/// - Financial balances are derived exclusively from immutable canonical double-entry postings
///   via [CanonicalAccountRepository.getDerivedBalance] (Liability: credits - debits).
/// - The legacy `loans.total`, `loans.paid_amount`, and `loans.loan_status` columns are NEVER
///   treated as independent authoritative financial truth.
/// - Loan disbursement produces: Dr Bank Asset, Cr Loan Liability (Net worth unchanged, 0 expense/income).
/// - Principal repayment produces: Dr Loan Liability, Cr Bank Asset (Net worth unchanged, 0 expense).
/// - Interest payment produces: Dr Interest Expense (`sys_exp_interest`), Cr Bank Asset.
/// - Combined EMI produces: Dr Loan Liability (principal), Dr Interest Expense (interest), Cr Bank Asset (total EMI).
/// - Opening balances and reconciliations route strictly through canonical double-entry events
///   balancing against [TablesV24.sysEquityOpening].
/// - Historical loans with postings are soft-archived (`is_active = 0`) to preserve accounting integrity.
/// - Operational schedule tables (`loan_installments`) remain isolated metadata and generate zero postings.
class LoanRepo {
  final DatabaseExecutor? _customExecutor;

  LoanRepo({DatabaseExecutor? database, DatabaseExecutor? executor})
      : _customExecutor = executor ?? database;

  DatabaseExecutor? get executor => _customExecutor;

  Future<DatabaseExecutor> get _db async =>
      _customExecutor ?? await AppDatabase.instance.database;

  CanonicalAccountRepository _getAccountRepo(DatabaseExecutor db) =>
      CanonicalAccountRepository(executor: db);

  CanonicalEventRepository _getEventRepo(DatabaseExecutor db) =>
      CanonicalEventRepository(executor: db);

  CanonicalOpeningBalanceRepository _getReconciliationRepo(DatabaseExecutor db) =>
      CanonicalOpeningBalanceRepository(executor: db);

  Future<T> _runInTransaction<T>(
    DatabaseExecutor db,
    Future<T> Function(DatabaseExecutor txn) action,
  ) async {
    if (db is Transaction) {
      return await action(db);
    } else if (db is Database) {
      return await db.transaction((txn) async => await action(txn));
    } else {
      return await action(db);
    }
  }

  // ============================================================================
  // DERIVED READ METHODS (3 methods)
  // ============================================================================

  /// Lists all active loans projected with their canonical derived liability balances.
  Future<List<Loan>> getLoans() async {
    final database = await _db;
    final rows = await database.query(
      TablesV24.accounts,
      where: "account_type = 'liability' AND subtype = 'loan' AND is_active = 1",
      orderBy: 'name ASC',
    );

    final List<Loan> result = [];
    for (final row in rows) {
      final id = row['id'] as String;
      final derivedBalance = await _getAccountRepo(database).getDerivedBalance(id);

      final transitionalRows = await database.query(
        Tables.loans,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      final transitionalLoanRow = transitionalRows.firstOrNull;

      result.add(CanonicalLoanAdapter.toLoan(
        row,
        derivedBalance,
        transitionalLoanRow: transitionalLoanRow,
      ));
    }
    return result;
  }

  /// Retrieves a loan by ID projected with its canonical derived liability balance.
  Future<Loan?> getLoanById(String id) async {
    if (id.isEmpty) return null;

    final database = await _db;
    final rows = await database.query(
      TablesV24.accounts,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) {
      // Check transitional table for legacy/unmigrated fallback
      final transitionalRows = await database.query(
        Tables.loans,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (transitionalRows.isEmpty) return null;

      // Auto-provision canonical account for consistency
      await _ensureCanonicalLoanExists(database, transitionalRows.first);
      return getLoanById(id);
    }

    final row = rows.first;
    final derivedBalance = await _getAccountRepo(database).getDerivedBalance(id);

    final transitionalRows = await database.query(
      Tables.loans,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final transitionalLoanRow = transitionalRows.firstOrNull;

    return CanonicalLoanAdapter.toLoan(
      row,
      derivedBalance,
      transitionalLoanRow: transitionalLoanRow,
    );
  }

  /// Returns the canonical derived liability balance for a loan.
  Future<Money> getDerivedBalance(String loanId) async {
    final database = await _db;
    return await _getAccountRepo(database).getDerivedBalance(loanId);
  }

  // ============================================================================
  // CANONICAL FINANCIAL WRITE & LIFECYCLE METHODS (9 methods)
  // ============================================================================

  /// Inserts a new canonical loan liability account into `accounts`.
  /// If the loan has an initial liability balance, posts a canonical opening balance
  /// event balancing against `sys_equity_opening` with explicit provenance.
  /// Idempotent: repeated calls do not duplicate opening balance postings.
  Future<String> insertLoan(Loan loan) async {
    final database = await _db;

    return await _runInTransaction(database, (txn) async {
      await CanonicalLoanAdapter.ensureSystemAccountsExist(txn);

      final row = CanonicalLoanAdapter.toAccountsRow(loan);
      final existingAcc = await txn.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [loan.id],
        limit: 1,
      );
      if (existingAcc.isNotEmpty) {
        await txn.update(
          TablesV24.accounts,
          row,
          where: 'id = ?',
          whereArgs: [loan.id],
        );
      } else {
        await txn.insert(
          TablesV24.accounts,
          row,
        );
      }

      // Check if opening event already exists for idempotency
      final obEventId = 'evt_ob_${loan.id}';
      final existingEvent = await _getEventRepo(txn).getEvent(obEventId);

      if (existingEvent == null) {
        final ob = CanonicalLoanAdapter.createOpeningBalanceRecords(loan);
        if (ob != null) {
          final eventRepo = _getEventRepo(txn);
          await eventRepo.createAndPostEvent(
            ob.event,
            postings: ob.postings,
            evidence: [ob.evidence],
          );
          final recRepo = _getReconciliationRepo(txn);
          await recRepo.saveReconciliation(ob.reconciliation);
        }
      }

      // Maintain operational compatibility projection in transitional table
      await txn.insert(
        Tables.loans,
        loan.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      return loan.id;
    });
  }

  /// Deletes or soft-archives a loan:
  /// - If the loan has historical postings: soft-archives (`is_active = 0`) in `accounts`.
  /// - If the loan has no postings: physically deletes from `accounts`.
  /// Always purges operational compatibility rows from transitional tables.
  Future<int> deleteLoan(String id) async {
    final database = await _db;

    return await _runInTransaction(database, (txn) async {
      final postingsCountRes = await txn.rawQuery(
        'SELECT COUNT(*) as count FROM ${TablesV24.postings} WHERE account_id = ?',
        [id],
      );
      final count = (postingsCountRes.first['count'] as num?)?.toInt() ?? 0;

      if (count > 0) {
        await txn.update(
          TablesV24.accounts,
          {
            'is_active': 0,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      } else {
        await txn.delete(
          TablesV24.accounts,
          where: 'id = ?',
          whereArgs: [id],
        );
      }

      await txn.delete(
        Tables.loans,
        where: 'id = ?',
        whereArgs: [id],
      );

      await txn.delete(
        Tables.loanInstallments,
        where: 'loanId = ?',
        whereArgs: [id],
      );

      return 1;
    });
  }

  /// Reconciles the loan's derived liability balance to [targetBalance] via an explicit
  /// balanced [CanonicalEventType.adjustment] event targeting `sys_equity_opening`.
  Future<void> reconcileBalance(
    String loanId,
    double targetBalance, {
    String reason = 'manual_reconciliation',
    String provenance = 'loan_reconciliation_delta',
  }) async {
    final database = await _db;

    await _runInTransaction(database, (txn) async {
      await CanonicalLoanAdapter.ensureSystemAccountsExist(txn);

      final currentLiability = await _getAccountRepo(txn).getDerivedBalance(loanId);
      final targetLiability = Money.fromRupees(targetBalance);
      final deltaPaise = targetLiability.minorUnits - currentLiability.minorUnits;

      if (deltaPaise != 0) {
        final rows = await txn.query(
          TablesV24.accounts,
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [loanId],
          limit: 1,
        );
        final loanName = rows.isNotEmpty ? (rows.first['name'] as String) : 'Loan $loanId';

        final rec = CanonicalLoanAdapter.createReconciliationRecords(
          loanId: loanId,
          loanName: loanName,
          currentLiability: currentLiability,
          targetLiability: targetLiability,
          reason: reason,
          provenance: provenance,
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

  /// Alias to [reconcileBalance] for API parity with AccountRepo.updateBalance and CreditRepo.updateBalance.
  Future<void> updateBalance(String loanId, double balance) async {
    await reconcileBalance(loanId, balance);
  }

  /// Records a canonical loan disbursement event:
  /// Dr Bank Asset (receives disbursement)
  /// Cr Loan Liability (debt owed)
  ///
  /// Economic effects: Asset increases, Liability increases, Net worth unchanged, Income=0, Expense=0.
  Future<String> recordDisbursement({
    required String loanId,
    required String assetAccountId,
    required double amount,
    required DateTime timestamp,
    String? description,
    String? externalRef,
    String? eventId,
  }) async {
    final database = await _db;

    return await _runInTransaction(database, (txn) async {
      if (eventId != null) {
        final existing = await _getEventRepo(txn).getEvent(eventId);
        if (existing != null) {
          throw AccountingInvariantException('Duplicate disbursement event: $eventId');
        }
      }
      if (externalRef != null) {
        await _checkDuplicateExternalRef(txn, externalRef);
      }

      await CanonicalLoanAdapter.ensureSystemAccountsExist(txn);

      final money = Money.fromRupees(amount);
      final records = CanonicalLoanAdapter.createDisbursementRecords(
        loanId: loanId,
        assetAccountId: assetAccountId,
        amount: money,
        timestamp: timestamp,
        description: description,
        externalRef: externalRef,
        eventId: eventId,
      );

      final eventRepo = _getEventRepo(txn);
      await eventRepo.createAndPostEvent(
        records.event,
        postings: records.postings,
        evidence: [records.evidence],
      );

      return records.event.id;
    });
  }

  /// Records a canonical principal repayment event:
  /// Dr Loan Liability (reduces debt)
  /// Cr Bank Asset (source of payment)
  ///
  /// Economic effects: Liability decreases, Asset decreases, Expense=0.
  Future<String> recordRepayment({
    required String loanId,
    required String assetAccountId,
    required double principalAmount,
    required DateTime timestamp,
    String? description,
    String? externalRef,
    String? eventId,
  }) async {
    final database = await _db;

    return await _runInTransaction(database, (txn) async {
      if (eventId != null) {
        final existing = await _getEventRepo(txn).getEvent(eventId);
        if (existing != null) {
          throw AccountingInvariantException('Duplicate repayment event: $eventId');
        }
      }
      if (externalRef != null) {
        await _checkDuplicateExternalRef(txn, externalRef);
      }

      await CanonicalLoanAdapter.ensureSystemAccountsExist(txn);

      final money = Money.fromRupees(principalAmount);
      final records = CanonicalLoanAdapter.createRepaymentRecords(
        loanId: loanId,
        assetAccountId: assetAccountId,
        principalAmount: money,
        timestamp: timestamp,
        description: description,
        externalRef: externalRef,
        eventId: eventId,
      );

      final eventRepo = _getEventRepo(txn);
      await eventRepo.createAndPostEvent(
        records.event,
        postings: records.postings,
        evidence: [records.evidence],
      );

      return records.event.id;
    });
  }

  /// Records a canonical interest payment event:
  /// Dr Interest Expense (`sys_exp_interest`)
  /// Cr Bank Asset (source of payment)
  ///
  /// Economic effects: Loan liability principal is unaffected, Expense increases, Net worth decreases.
  Future<String> recordInterestPayment({
    required String loanId,
    required String assetAccountId,
    required double interestAmount,
    required DateTime timestamp,
    String? description,
    String? externalRef,
    String? eventId,
  }) async {
    final database = await _db;

    return await _runInTransaction(database, (txn) async {
      if (eventId != null) {
        final existing = await _getEventRepo(txn).getEvent(eventId);
        if (existing != null) {
          throw AccountingInvariantException('Duplicate interest payment event: $eventId');
        }
      }
      if (externalRef != null) {
        await _checkDuplicateExternalRef(txn, externalRef);
      }

      await CanonicalLoanAdapter.ensureSystemAccountsExist(txn);

      final money = Money.fromRupees(interestAmount);
      final records = CanonicalLoanAdapter.createInterestPaymentRecords(
        loanId: loanId,
        assetAccountId: assetAccountId,
        interestAmount: money,
        timestamp: timestamp,
        description: description,
        externalRef: externalRef,
        eventId: eventId,
      );

      final eventRepo = _getEventRepo(txn);
      await eventRepo.createAndPostEvent(
        records.event,
        postings: records.postings,
        evidence: [records.evidence],
      );

      return records.event.id;
    });
  }

  /// Records a combined EMI repayment event:
  /// Dr Loan Liability (principal)
  /// Dr Interest Expense (interest)
  /// Cr Bank Asset (total EMI)
  ///
  /// Balanced: principal + interest = total EMI.
  Future<String> recordCombinedPayment({
    required String loanId,
    required String assetAccountId,
    required double principalAmount,
    required double interestAmount,
    required DateTime timestamp,
    String? description,
    String? externalRef,
    String? eventId,
  }) async {
    final database = await _db;

    return await _runInTransaction(database, (txn) async {
      if (eventId != null) {
        final existing = await _getEventRepo(txn).getEvent(eventId);
        if (existing != null) {
          throw AccountingInvariantException('Duplicate combined payment event: $eventId');
        }
      }
      if (externalRef != null) {
        await _checkDuplicateExternalRef(txn, externalRef);
      }

      await CanonicalLoanAdapter.ensureSystemAccountsExist(txn);

      final pMoney = Money.fromRupees(principalAmount);
      final iMoney = Money.fromRupees(interestAmount);
      final records = CanonicalLoanAdapter.createCombinedPaymentRecords(
        loanId: loanId,
        assetAccountId: assetAccountId,
        principalAmount: pMoney,
        interestAmount: iMoney,
        timestamp: timestamp,
        description: description,
        externalRef: externalRef,
        eventId: eventId,
      );

      final eventRepo = _getEventRepo(txn);
      await eventRepo.createAndPostEvent(
        records.event,
        postings: records.postings,
        evidence: [records.evidence],
      );

      return records.event.id;
    });
  }

  /// Deterministic append-only reversal of a posted loan event.
  /// Reverses all postings in double-entry ledger preserving complete immutable audit history.
  Future<String> reverseLoanEvent(String eventId) async {
    final database = await _db;

    return await _runInTransaction(database, (txn) async {
      final eventRepo = _getEventRepo(txn);
      final event = await eventRepo.getEvent(eventId);
      if (event == null) {
        throw AccountingInvariantException('Event not found for reversal: $eventId');
      }
      if (event.lifecycleStatus != EventLifecycle.posted) {
        throw AccountingInvariantException(
          'Cannot reverse event $eventId in status ${event.lifecycleStatus.name}',
        );
      }

      final postings = await eventRepo.getPostingsForEvent(eventId);
      final reversal = CanonicalLoanAdapter.createReversal(event, postings);

      await eventRepo.createAndPostEvent(
        reversal.event,
        postings: reversal.postings,
      );

      return reversal.event.id;
    });
  }

  // ============================================================================
  // CANONICAL METADATA METHOD (1 method)
  // ============================================================================

  /// Updates display and configuration metadata for a loan.
  /// CRITICAL ARCHITECTURAL INVARIANT:
  /// Mutating loan metadata NEVER secretly modifies financial balances.
  /// Balance fields (`paidAmount`, `total`) are strictly ignored here.
  Future<int> updateLoan(Loan loan) async {
    final database = await _db;

    return await _runInTransaction(database, (txn) async {
      final count = await txn.update(
        TablesV24.accounts,
        {
          'name': loan.name,
          'institution_name': loan.bank,
          'icon_name': loan.type.name,
          'payment_due_day': loan.dueDay,
          'interest_rate_basis_points': (loan.interestRate * 100.0).round(),
          'tenure_months': loan.tenureMonths,
          'monthly_installment_minor_units': (loan.monthlyInstallment * 100.0).round(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [loan.id],
      );

      // Also update transitional table for UI compatibility
      await txn.update(
        Tables.loans,
        loan.toMap(),
        where: 'id = ?',
        whereArgs: [loan.id],
      );

      return count;
    });
  }

  // ============================================================================
  // TRANSITIONAL COMPATIBILITY SCHEDULE METHODS (7 methods)
  // ============================================================================

  /// Reads installments for a loan from operational schedule table.
  /// Operational metadata only — produces ZERO postings.
  Future<List<LoanInstallment>> getInstallments(String loanId) async {
    final database = await _db;
    final res = await database.query(
      Tables.loanInstallments,
      where: 'loanId = ?',
      whereArgs: [loanId],
      orderBy: 'dueDate ASC',
    );
    return res.map((e) => LoanInstallment.fromMap(e)).toList();
  }

  /// Reads a specific installment by ID from operational schedule table.
  Future<LoanInstallment?> getInstallmentById(String id) async {
    final database = await _db;
    final res = await database.query(
      Tables.loanInstallments,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return res.isEmpty ? null : LoanInstallment.fromMap(res.first);
  }

  /// Inserts an operational installment schedule item.
  /// Expected installment generates ZERO canonical postings.
  Future<String> insertInstallment(LoanInstallment installment) async {
    final database = await _db;
    await database.insert(
      Tables.loanInstallments,
      installment.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return installment.id;
  }

  /// Updates an operational installment schedule item. ZERO posting impact.
  Future<int> updateInstallment(LoanInstallment installment) async {
    final database = await _db;
    return database.update(
      Tables.loanInstallments,
      installment.toMap(),
      where: 'id = ?',
      whereArgs: [installment.id],
    );
  }

  /// Updates operational installment status (e.g. 'pending' -> 'paid').
  /// Does not create financial postings; operational schedule tracking only.
  Future<int> updateInstallmentStatus(
    String installmentId,
    String status,
    DateTime? paidDate,
  ) async {
    final existing = await getInstallmentById(installmentId);
    if (existing == null) return 0;
    return updateInstallment(
      existing.copyWith(status: status, paidDate: paidDate),
    );
  }

  /// Retrieves the next pending installment for schedule tracking.
  Future<LoanInstallment?> getNextPendingInstallment(String loanId) async {
    final database = await _db;
    final res = await database.query(
      Tables.loanInstallments,
      where: 'loanId = ? AND status = ?',
      whereArgs: [loanId, 'pending'],
      orderBy: 'dueDate ASC',
      limit: 1,
    );
    return res.isEmpty ? null : LoanInstallment.fromMap(res.first);
  }

  /// Updates operational tracking fields (`loanStatus`, `nextDueDate`, `paidAmount`)
  /// in transitional `loans` table. ZERO mutation to canonical double-entry ledger.
  Future<int> updateLoanProgress(
    String loanId,
    double paidAmount,
    String loanStatus,
  ) async {
    final loan = await getLoanById(loanId);
    if (loan == null) return 0;

    final nextInstallment = await getNextPendingInstallment(loanId);
    final database = await _db;

    // Update operational metadata in transitional table
    return await database.update(
      Tables.loans,
      {
        'paid_amount': paidAmount,
        'loan_status': loanStatus,
        'next_due_date': nextInstallment?.dueDate.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [loanId],
    );
  }

  // ============================================================================
  // INTERNAL HELPERS
  // ============================================================================

  Future<void> _ensureCanonicalLoanExists(
    DatabaseExecutor db,
    Map<String, dynamic> legacyRow,
  ) async {
    final loan = Loan.fromMap(legacyRow);
    final accountRow = CanonicalLoanAdapter.toAccountsRow(loan);
    await db.insert(
      TablesV24.accounts,
      accountRow,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    final ob = CanonicalLoanAdapter.createOpeningBalanceRecords(loan);
    if (ob != null) {
      final eventRepo = _getEventRepo(db);
      final existingEvent = await eventRepo.getEvent(ob.event.id);
      if (existingEvent == null) {
        await eventRepo.createAndPostEvent(
          ob.event,
          postings: ob.postings,
          evidence: [ob.evidence],
        );
        final recRepo = _getReconciliationRepo(db);
        await recRepo.saveReconciliation(ob.reconciliation);
      }
    }
  }

  Future<void> _checkDuplicateExternalRef(
    DatabaseExecutor db,
    String externalRef,
  ) async {
    final res = await db.rawQuery('''
      SELECT COUNT(*) as count FROM ${TablesV24.evidence}
      WHERE raw_payload_encrypted LIKE ?
    ''', ['%"external_ref":"$externalRef"%']);
    final count = (res.first['count'] as num?)?.toInt() ?? 0;
    if (count > 0) {
      throw AccountingInvariantException(
        'Duplicate loan transaction detected with external reference: $externalRef',
      );
    }
  }
}
