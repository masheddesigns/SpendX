import 'package:sqflite/sqflite.dart' hide Transaction;

/// Phase 1B/1D — Guarded financial ledger reconciliation.
///
/// DATA-MIGRATION component ONLY, not a normal runtime mutation path. Its job:
/// make the canonical `ledger_transactions` journal plus an explicit
/// `opening_balance` entry reconcile exactly to the legacy stored balances,
/// WITHOUT touching UI, providers, or stored columns.
///
/// Locked constraints:
///   * `ledger_transactions` = canonical money journal.
///   * `bank_accounts.balance` = legacy stored balance used ONLY as the expected
///     value for parity (never modified).
///   * Opening balances use a dedicated `opening_balance` entry.
///   * Runs inside one SQL transaction; any hard failure makes the verdict
///     `FAIL` and the whole run rolls back — nothing is persisted.
///   * Idempotent: re-running creates zero duplicate movements.
///
/// Phase 1D adds [reconcile] — the production model: it re-reads and
/// re-validates inside the SAME transaction, requires an explicit `authorized`
/// signal, and uses a strict verdict model:
///   * `PASS` — executable.
///   * `EXECUTABLE_WITH_EXCEPTIONS` — executable ONLY because every warning is a
///     predefined, allow-listed category (lending repayment / salary-EMI
///     residual absorbed into opening balance).
///   * `FAIL` — never executable. Orphans, duplicates, unknown transaction or
///     reference types, mismatched existing ledger rows, and parity mismatches
///     are NEVER auto-allow-listed.
class LedgerBackfillService {
  // 1 cent tolerance — guards against float noise only, never a real diff.
  static const double tolerance = 0.01;

  static const Set<String> _positiveAccountTypes = {
    'income',
    'lending_received',
    'loan_disbursement',
    'refund',
    'opening_balance',
  };

  static const Set<String> _negativeAccountTypes = {
    'expense',
    'credit_payment',
    'emi_installment',
    'loan_payment',
    'transfer',
    'lending_given',
    'fuel_expense',
    'processing_fee',
    'interest_charge',
  };

  /// Strict migration mode (retained for clean devices / regression tests).
  /// Always applies and throws [BackfillFailedException] (rolling back) on any
  /// hard failure.
  static Future<BackfillReport> run(DatabaseExecutor db) async {
    final report = BackfillReport();
    if (db is Database) {
      try {
        await db.transaction((txn) async {
          await _reconcileSteps(txn, report, apply: true);
          if (!report.passed) throw _HardFail(report.hardFailures);
        });
      } on _HardFail {
        report.passed = false;
        report.errorMessage = report.hardFailures.join('\n');
        throw BackfillFailedException(report);
      }
      return report;
    }
    await _reconcileSteps(db, report, apply: true);
    if (!report.passed) {
      report.errorMessage = report.hardFailures.join('\n');
      throw BackfillFailedException(report);
    }
    return report;
  }

  /// Guarded reconcile mode — the Phase 1D production model.
  ///
  /// Always re-reads, re-validates, and APPLIES inside the SAME transaction.
  /// The only difference between a preflight and an execution is whether the
  /// transaction is committed: if [authorized] is false, or the analysis
  /// verdict is not executable, the transaction is rolled back (no mutation)
  /// and the report is returned. This guarantees parity is verified against
  /// the actually-applied state (no dry-run-then-execute TOCTOU window) and
  /// that a preflight never leaves data behind.
  static Future<BackfillReport> reconcile(
    DatabaseExecutor db, {
    required bool authorized,
  }) async {
    final report = BackfillReport();
    if (db is Database) {
      try {
        await db.transaction((txn) async {
          await _reconcileSteps(txn, report, apply: true);
          if (!authorized || !report.isExecutable) {
            // Preflight or non-executable: roll back, return analysis only.
            throw _ReconcileNoApply(report);
          }
        });
      } on _ReconcileNoApply catch (e) {
        return e.report;
      }
      return report;
    }
    // Already inside a transaction (e.g. harness): apply inline; signal
    // no-apply so the caller rolls back when not authorized / not executable.
    await _reconcileSteps(db, report, apply: true);
    if (!authorized || !report.isExecutable) {
      throw _ReconcileNoApply(report);
    }
    return report;
  }

  static Future<void> _reconcileSteps(
    DatabaseExecutor db,
    BackfillReport report, {
    required bool apply,
  }) async {
    await _stepAccounts(db, report, apply);
    await _stepLending(db, report, apply);
    await _stepCredit(db, report, apply);
    await _stepLoans(db, report, apply);
    await _stepOrphanAndDuplicates(db, report);
    await _stepAccountParity(db, report);
    await _stepSalaryEmiResidual(db, report);
    if (apply) {
      // Defense-in-depth: re-verify parity after applying, inside the same
      // transaction, so a data change between analysis and apply cannot slip
      // through. Any mismatch rolls the whole run back.
      await _recheckParity(db, report);
    }
    report.passed = report.hardFailures.isEmpty;
    final openingTouched =
        report.openingBalancesCreated + report.openingBalancesExpected;
    report.historicalCompleteness = (openingTouched == 0 &&
            report.exceptions.isEmpty &&
            report.reviewItems.isEmpty)
        ? 'COMPLETE'
        : 'PARTIAL';
  }

  // ---------------------------------------------------------------------------
  // STEP 1 + 3: opening balances + backfill of `transactions`
  // ---------------------------------------------------------------------------
  static Future<void> _stepAccounts(
    DatabaseExecutor db,
    BackfillReport report,
    bool apply,
  ) async {
    final accounts = await db.query('bank_accounts');
    final transactions = await db.query(
      'transactions',
      where: 'COALESCE(is_deleted, 0) = 0',
    );

    final existingMovement = <String, double>{};
    for (final a in accounts) {
      report.accountsExamined++;
      final accId = a['id'] as String;
      final sum = (await db.rawQuery(
        _accountMovementSql(excludeOpening: true),
        [accId],
      )).first['balance'];
      existingMovement[accId] = (sum as num?)?.toDouble() ?? 0.0;
    }

    final insertedNet = <String, double>{};
    for (final tx in transactions) {
      final type = (tx['type'] as String?) ?? '';
      if (type != 'income' && type != 'expense' && type != 'transfer') {
        // Unknown transaction type. Never allow-listed; blocks execution.
        final acc = tx['account_id'] as String?;
        final rel = tx['related_entity_id'] as String?;
        final withRef =
            (acc != null && acc.isNotEmpty) || (rel != null && rel.isNotEmpty);
        report.hardFailures.add(
          'Unknown transaction type "$type"${withRef ? ' with account '
              'reference' : ''} (id=${tx['id']}). Cannot safely reconstruct.',
        );
        continue;
      }

      final legs = _expectedLegs(tx);
      final existing = await db.query(
        'ledger_transactions',
        where: 'reference_id = ?',
        whereArgs: [tx['id']],
      );

      if (existing.isEmpty) {
        if (apply) {
          for (final leg in legs) {
            await db.insert('ledger_transactions', _legMap(leg, tx));
            report.ledgerEntriesCreated++;
            final acc = leg['account_id'] as String?;
            if (acc != null) {
              insertedNet[acc] = (insertedNet[acc] ?? 0) +
                  _signedOf(
                    leg['type'] as String,
                    (leg['amount'] as num).toDouble(),
                  );
            }
          }
        } else {
          report.ledgerEntriesExpected += legs.length;
        }
      } else {
        if (_legsMatch(existing, legs)) {
          report.existingLedgerSkipped++;
        } else {
          // Already journaled but amount/type differs -> WARN/REVIEW, never
          // auto-fixed, never allow-listed (blocks execution).
          report.reviewItems.add(
            'Ledger row for transaction ${tx['id']} exists but does not '
            'match the canonical derivation. Human review required.',
          );
          report.hardFailures.add(
            'Ledger integrity mismatch for transaction ${tx['id']}: existing '
            'journal does not match canonical derivation.',
          );
        }
      }
    }

    for (final a in accounts) {
      final accId = a['id'] as String;
      final stored = (a['balance'] as num?)?.toDouble() ?? 0.0;
      final opening =
          stored - ((existingMovement[accId] ?? 0) + (insertedNet[accId] ?? 0));
      if (opening.abs() > tolerance) {
        final existingOb = await db.query(
          'ledger_transactions',
          where: 'reference_id = ?',
          whereArgs: ['migration-opening-balance-$accId'],
        );
        if (existingOb.isEmpty) {
          if (apply) {
            final now = DateTime.now().toIso8601String();
            await db.insert('ledger_transactions', {
              'id': 'migration-opening-$accId',
              'type': 'opening_balance',
              'amount': opening,
              'date': (a['created_at'] as String?) ?? now,
              'account_id': accId,
              'category_id': null,
              'reference_id': 'migration-opening-balance-$accId',
              'created_at': now,
            });
            report.openingBalancesCreated++;
          } else {
            report.openingBalancesExpected++;
          }
        }
      }
      report.accountsMigrated++;
    }
  }

  // ---------------------------------------------------------------------------
  // STEP 5: lending historical reconciliation
  // ---------------------------------------------------------------------------
  static Future<void> _stepLending(
    DatabaseExecutor db,
    BackfillReport report,
    bool apply,
  ) async {
    final lendings = await db.query('lendings');
    for (final l in lendings) {
      final id = l['id'] as String;
      final type = (l['type'] as String?) ?? 'lent';
      final original = (l['original_amount'] as num?)?.toDouble() ?? 0.0;
      final paid = (l['paid_amount'] as num?)?.toDouble() ?? 0.0;

      final exist = await db.query(
        'ledger_transactions',
        where: 'reference_id = ?',
        whereArgs: [id],
      );
      if (exist.isEmpty) {
        if (apply) {
          final legType = type == 'borrowed' ? 'lending_received' : 'lending_given';
          await db.insert('ledger_transactions', {
            'id': 'migration-lending-$id',
            'type': legType,
            'amount': original,
            'date': (l['date'] as String?) ?? DateTime.now().toIso8601String(),
            'reference_id': id,
            'created_at': DateTime.now().toIso8601String(),
          });
          report.ledgerEntriesCreated++;
        } else {
          report.ledgerEntriesExpected++;
        }
      } else {
        report.existingLedgerSkipped++;
      }
      report.lendingReconciled++;

      final derived = ((await db.rawQuery(
        '''SELECT COALESCE(SUM(CASE WHEN type = 'lending_given' THEN amount
            WHEN type = 'lending_received' THEN -amount ELSE 0 END), 0) as b
           FROM ledger_transactions WHERE reference_id = ?''',
        [id],
      )).first['b'] as num? ?? 0.0).toDouble();
      final expected = type == 'borrowed' ? -original : original;
      final diff = (derived - expected).abs();
      report.lendingParity.add(BackfillParity(id, expected, derived, diff));
      if (diff > tolerance) {
        report.hardFailures.add(
          'Lending parity mismatch for $id: derived=$derived expected=$expected',
        );
      }
      if (paid != 0) {
        // Allow-listed exception (deferred to Phase 2), NOT a hard failure.
        report.exceptions.add(
          'Lending $id has repayments (paid_amount=$paid) not reconstructable '
          'in ledger; deferred to Phase 2.',
        );
        report.lendingRepaymentExceptions++;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // STEP 6: credit-card historical reconciliation
  // ---------------------------------------------------------------------------
  static Future<void> _stepCredit(
    DatabaseExecutor db,
    BackfillReport report,
    bool apply,
  ) async {
    final cards = await db.query('credit_cards');
    final creditTxns = await db.query('credit_transactions');

    for (final ctx in creditTxns) {
      final cid = ctx['id'] as String;
      final cardId = ctx['cardId'] as String?;
      final ctype = (ctx['type'] as String?) ?? 'purchase';
      final amt = (ctx['amount'] as num?)?.toDouble() ?? 0.0;

      final exist = await db.query(
        'ledger_transactions',
        where: 'reference_id = ?',
        whereArgs: [cid],
      );
      if (exist.isEmpty) {
        if (apply) {
          final legType = ctype == 'payment'
              ? 'credit_payment'
              : ctype == 'refund'
                  ? 'refund'
                  : 'credit_purchase';
          await db.insert('ledger_transactions', {
            'id': 'migration-credit-$cid',
            'type': legType,
            'amount': amt,
            'credit_card_id': cardId,
            'category_id': ctx['categoryId'],
            'date':
                (ctx['date'] as String?) ?? DateTime.now().toIso8601String(),
            'reference_id': cid,
            'created_at': DateTime.now().toIso8601String(),
          });
          report.ledgerEntriesCreated++;
        } else {
          report.ledgerEntriesExpected++;
        }
      } else {
        report.existingLedgerSkipped++;
      }
      report.creditReconciled++;
    }

    for (final c in cards) {
      final cardId = c['id'] as String;
      final derived = await _creditOutstanding(db, cardId);
      var reconstructable = 0.0;
      for (final ctx in creditTxns) {
        if (ctx['cardId'] != cardId) continue;
        final ctype = (ctx['type'] as String?) ?? 'purchase';
        final amt = (ctx['amount'] as num?)?.toDouble() ?? 0.0;
        if (ctype == 'payment' || ctype == 'refund') {
          reconstructable -= amt;
        } else {
          reconstructable += amt;
        }
      }
      final diff = (derived - reconstructable).abs();
      report.creditParity.add(
        BackfillParity(cardId, reconstructable, derived, diff),
      );
      if (diff > tolerance) {
        report.hardFailures.add(
          'Credit parity mismatch for card $cardId: derived=$derived '
          'reconstructable=$reconstructable',
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // STEP 7: loan historical reconciliation (principal, not total EMI)
  // ---------------------------------------------------------------------------
  static Future<void> _stepLoans(
    DatabaseExecutor db,
    BackfillReport report,
    bool apply,
  ) async {
    final loans = await db.query('loans');
    final installments = await db.query('loan_installments');

    for (final loan in loans) {
      final loanId = loan['id'] as String;
      final total = (() {
        final t = (loan['total'] as num?)?.toDouble();
        if (t != null) return t;
        return (loan['principal_amount'] as num?)?.toDouble() ?? 0.0;
      })();

      final disb = await db.query(
        'ledger_transactions',
        where: 'reference_id = ? AND type = ?',
        whereArgs: [loanId, 'loan_disbursement'],
      );
      if (disb.isEmpty) {
        if (apply) {
          await db.insert('ledger_transactions', {
            'id': 'migration-loan-disb-$loanId',
            'type': 'loan_disbursement',
            'amount': total,
            'loan_id': loanId,
            'date': (loan['start_date'] as String?) ??
                DateTime.now().toIso8601String(),
            'reference_id': loanId,
            'created_at': DateTime.now().toIso8601String(),
          });
          report.ledgerEntriesCreated++;
        } else {
          report.ledgerEntriesExpected++;
        }
      } else {
        report.existingLedgerSkipped++;
      }

      final loanInst = installments.where((i) => i['loanId'] == loanId).toList();
      for (final inst in loanInst) {
        if ((inst['status'] as String?) == 'paid') {
          final exist = await db.query(
            'ledger_transactions',
            where: 'reference_id = ?',
            whereArgs: [inst['id']],
          );
          if (exist.isEmpty) {
            if (apply) {
              final principal =
                  (inst['principalComponent'] as num?)?.toDouble() ?? 0.0;
              await db.insert('ledger_transactions', {
                'id': 'migration-loan-pay-${inst['id']}',
                'type': 'loan_payment',
                'amount': principal,
                'loan_id': loanId,
                'date': (inst['paidDate'] as String?) ??
                    (inst['dueDate'] as String?) ??
                    DateTime.now().toIso8601String(),
                'reference_id': inst['id'],
                'created_at': DateTime.now().toIso8601String(),
              });
              report.ledgerEntriesCreated++;
            } else {
              report.ledgerEntriesExpected++;
            }
          } else {
            report.existingLedgerSkipped++;
          }
        }
      }
      report.loanReconciled++;

      final paidPrincipal = ((await db.rawQuery(
        '''SELECT COALESCE(SUM(principalComponent), 0) as p
           FROM loan_installments WHERE loanId = ? AND status = ?''',
        [loanId, 'paid'],
      )).first['p'] as num? ?? 0.0).toDouble();
      final expectedRemaining = total - paidPrincipal;

      final disbTotal = (await db.rawQuery(
        '''SELECT COALESCE(SUM(amount), 0) as s FROM ledger_transactions
           WHERE loan_id = ? AND type = 'loan_disbursement' ''',
        [loanId],
      )).first['s'];
      final payTotal = (await db.rawQuery(
        '''SELECT COALESCE(SUM(amount), 0) as s FROM ledger_transactions
           WHERE loan_id = ? AND type = 'loan_payment' ''',
        [loanId],
      )).first['s'];
      var ledgerRemaining =
          (disbTotal as num).toDouble() - (payTotal as num).toDouble();
      if (ledgerRemaining.isNaN) {
        ledgerRemaining = 0.0;
      }

      final diff = (expectedRemaining - ledgerRemaining).abs();
      report.loanParity.add(
        BackfillLoanParity(
          loanId,
          total,
          paidPrincipal,
          expectedRemaining,
          ledgerRemaining,
          diff,
        ),
      );
      if (diff > tolerance) {
        report.hardFailures.add(
          'Loan principal mismatch for $loanId: expectedRemaining='
          '$expectedRemaining ledgerRemaining=$ledgerRemaining',
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // STEP 11: orphan / duplicate / unknown-reference detection
  // ---------------------------------------------------------------------------
  static Future<void> _stepOrphanAndDuplicates(
    DatabaseExecutor db,
    BackfillReport report,
  ) async {
    final accounts = await db.query('bank_accounts');
    final cards = await db.query('credit_cards');
    final loans = await db.query('loans');
    final lendings = await db.query('lendings');
    final transactions = await db.query('transactions');
    final installments = await db.query('loan_installments');
    final creditTxns = await db.query('credit_transactions');

    final accountIds = accounts.map((a) => a['id']).toSet();
    final cardIds = cards.map((c) => c['id']).toSet();
    final loanIds = loans.map((l) => l['id']).toSet();
    final lendingIds = lendings.map((l) => l['id']).toSet();
    final txIds = transactions.map((t) => t['id']).toSet();
    final instIds = installments.map((i) => i['id']).toSet();
    final creditTxnIds = creditTxns.map((c) => c['id']).toSet();

    final allLedger = await db.query('ledger_transactions');
    for (final row in allLedger) {
      final acc = row['account_id'];
      final card = row['credit_card_id'];
      final loan = row['loan_id'];
      final ref = row['reference_id'];

      if (acc != null && !accountIds.contains(acc)) {
        report.orphanCount++;
        report.hardFailures.add('Orphan ledger row references missing account $acc');
      }
      if (card != null && !cardIds.contains(card)) {
        report.orphanCount++;
        report.hardFailures.add('Orphan ledger row references missing card $card');
      }
      if (loan != null && !loanIds.contains(loan)) {
        report.orphanCount++;
        report.hardFailures.add('Orphan ledger row references missing loan $loan');
      }
      if (ref is String &&
          !ref.startsWith('migration-') &&
          !txIds.contains(ref) &&
          !lendingIds.contains(ref) &&
          !loanIds.contains(ref) &&
          !instIds.contains(ref) &&
          !creditTxnIds.contains(ref)) {
        report.orphanCount++;
        report.hardFailures.add(
          'Orphan ledger row reference_id $ref matches no known entity '
          '(unknown reference domain)',
        );
      }
    }

    final byRefType = <String, int>{};
    for (final row in allLedger) {
      final ref = row['reference_id'];
      final type = row['type'];
      if (ref == null) continue;
      final key = '$ref|$type';
      byRefType[key] = (byRefType[key] ?? 0) + 1;
    }
    byRefType.forEach((key, count) {
      if (count > 1) {
        report.duplicateCount++;
        report.hardFailures.add('Duplicate ledger representation: $key x$count');
      }
    });
  }

  // ---------------------------------------------------------------------------
  // STEP 8: account parity (derived == legacy stored)
  // ---------------------------------------------------------------------------
  static Future<void> _stepAccountParity(
    DatabaseExecutor db,
    BackfillReport report,
  ) async {
    final accounts = await db.query('bank_accounts');
    for (final a in accounts) {
      final accId = a['id'] as String;
      final stored = (a['balance'] as num?)?.toDouble() ?? 0.0;
      final derived = (await db.rawQuery(
        _accountMovementSql(excludeOpening: false),
        [accId],
      )).first['balance'];
      final derivedVal = (derived as num?)?.toDouble() ?? 0.0;
      final diff = (derivedVal - stored).abs();
      report.accountParity.add(BackfillParity(accId, stored, derivedVal, diff));
      if (diff > tolerance) {
        report.hardFailures.add(
          'Account parity mismatch for $accId: derived=$derivedVal '
          'legacy=$stored',
        );
      }
    }
  }

  /// Phase 1D post-apply parity re-verification (TOCTOU defense).
  static Future<void> _recheckParity(
    DatabaseExecutor db,
    BackfillReport report,
  ) async {
    final accounts = await db.query('bank_accounts');
    for (final a in accounts) {
      final accId = a['id'] as String;
      final stored = (a['balance'] as num?)?.toDouble() ?? 0.0;
      final derived = (await db.rawQuery(
        _accountMovementSql(excludeOpening: false),
        [accId],
      )).first['balance'];
      final derivedVal = (derived as num?)?.toDouble() ?? 0.0;
      if ((derivedVal - stored).abs() > tolerance &&
          !report.hardFailures
              .any((f) => f.contains('Account parity mismatch for $accId'))) {
        report.hardFailures.add(
          'Account parity mismatch for $accId (post-apply): derived='
          '$derivedVal legacy=$stored',
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // STEP 9: salary / EMI residual — allow-listed exceptions (absorbed opening)
  // ---------------------------------------------------------------------------
  static Future<void> _stepSalaryEmiResidual(
    DatabaseExecutor db,
    BackfillReport report,
  ) async {
    final salary = await db.query('salary');
    final salaryAbsorbed = salary.fold(
      0.0,
      (double s, r) => s + ((r['amount_received'] as num?)?.toDouble() ?? 0.0),
    );
    if (salary.isNotEmpty) {
      report.openingAbsorbedSalary = salaryAbsorbed;
      report.exceptions.add(
        'Salary events (INR $salaryAbsorbed) are not individually journaled; '
        'absorbed into opening balance (historically NOT reconstructed).',
      );
      report.salaryResidualExceptions++;
    }
    final loanInt = (await db.rawQuery(
      'SELECT COALESCE(SUM(interestComponent),0) as s FROM loan_installments',
    )).first['s'];
    final emiInt = (await db.rawQuery(
      'SELECT COALESCE(SUM(interestAmount),0) as s FROM credit_emis',
    )).first['s'];
    final unsupported =
        (loanInt as num).toDouble() + (emiInt as num).toDouble();
    if (unsupported > tolerance) {
      report.openingAbsorbedUnsupported = unsupported;
      report.exceptions.add(
        'Loan/credit interest (INR $unsupported) is not individually '
        'journaled; absorbed into opening balance.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  static String _accountMovementSql({required bool excludeOpening}) {
    final positive = excludeOpening
        ? "('income', 'lending_received', 'loan_disbursement', 'refund')"
        : "('income', 'lending_received', 'loan_disbursement', 'refund', "
            "'opening_balance')";
    return '''
      SELECT SUM(CASE
        WHEN type IN $positive THEN amount
        WHEN type IN ('expense', 'credit_payment', 'emi_installment',
                      'loan_payment', 'transfer', 'lending_given',
                      'fuel_expense', 'processing_fee', 'interest_charge')
          THEN -amount
        ELSE 0 END) as balance
      FROM ledger_transactions
      WHERE account_id = ?
    ''';
  }

  static Future<double> _creditOutstanding(
    DatabaseExecutor db,
    String cardId,
  ) async {
    final rows = await db.rawQuery(
      '''
      SELECT SUM(CASE
        WHEN type IN ('credit_purchase', 'emi_installment',
                      'processing_fee', 'interest_charge') THEN amount
        WHEN type IN ('credit_payment', 'refund') THEN -amount
        ELSE 0 END) as outstanding
      FROM ledger_transactions
      WHERE credit_card_id = ?
      ''',
      [cardId],
    );
    return (rows.first['outstanding'] as num?)?.toDouble() ?? 0.0;
  }

  static List<Map<String, dynamic>> _expectedLegs(Map<String, dynamic> tx) {
    final type = (tx['type'] as String?) ?? '';
    final amount = (tx['amount'] as num).toDouble();
    final accountId = tx['account_id'] as String?;
    final rel = tx['related_entity_id'] as String?;
    final categoryId = tx['category_id'] as String?;

    if (type == 'transfer') {
      final legs = <Map<String, dynamic>>[];
      if (accountId != null && accountId.isNotEmpty) {
        legs.add({
          'type': 'transfer',
          'amount': amount,
          'account_id': accountId,
          'category_id': categoryId,
        });
      }
      if (rel != null && rel.isNotEmpty) {
        legs.add({
          'type': 'income',
          'amount': amount,
          'account_id': rel,
          'category_id': categoryId,
        });
      }
      return legs;
    } else if (type == 'income') {
      return [
        {
          'type': 'income',
          'amount': amount,
          'account_id': accountId,
          'category_id': categoryId,
        }
      ];
    } else if (type == 'expense') {
      return [
        {
          'type': 'expense',
          'amount': amount,
          'account_id': accountId,
          'category_id': categoryId,
        }
      ];
    }
    return [];
  }

  static double _signedOf(String type, double amount) {
    if (_positiveAccountTypes.contains(type)) return amount;
    if (_negativeAccountTypes.contains(type)) return -amount;
    return 0.0;
  }

  static Map<String, dynamic> _legMap(
    Map<String, dynamic> leg,
    Map<String, dynamic> tx,
  ) {
    return {
      'id': 'migration-tx-${tx['id']}-${leg['type']}',
      'type': leg['type'],
      'amount': leg['amount'],
      'date': (tx['date'] as String?) ?? DateTime.now().toIso8601String(),
      'account_id': leg['account_id'],
      'category_id': leg['category_id'],
      'reference_id': tx['id'],
      'created_at': DateTime.now().toIso8601String(),
    };
  }

  static bool _legsMatch(
    List<Map<String, dynamic>> existing,
    List<Map<String, dynamic>> legs,
  ) {
    for (final leg in legs) {
      final match = existing.any((r) {
        final rType = r['type'];
        final rAcc = r['account_id'];
        final rAmt = (r['amount'] as num?)?.toDouble() ?? 0.0;
        final lAmt = (leg['amount'] as num?)?.toDouble() ?? 0.0;
        return rType == leg['type'] &&
            rAcc == leg['account_id'] &&
            (rAmt - lAmt).abs() < tolerance;
      });
      if (!match) return false;
    }
    return true;
  }
}

class _HardFail implements Exception {
  final List<String> messages;
  _HardFail(this.messages);
}

class _ReconcileNoApply implements Exception {
  final BackfillReport report;
  _ReconcileNoApply(this.report);
}

class BackfillFailedException implements Exception {
  final BackfillReport report;
  BackfillFailedException(this.report);

  @override
  String toString() =>
      'BackfillFailedException: migration rolled back.\n${report.errorMessage}';
}

class BackfillParity {
  final String entityId;
  final double expected;
  final double derived;
  final double diff;
  BackfillParity(this.entityId, this.expected, this.derived, this.diff);
  bool get passed => diff <= LedgerBackfillService.tolerance;
}

class BackfillLoanParity {
  final String loanId;
  final double total;
  final double paidPrincipal;
  final double expectedRemaining;
  final double ledgerRemaining;
  final double diff;
  BackfillLoanParity(
    this.loanId,
    this.total,
    this.paidPrincipal,
    this.expectedRemaining,
    this.ledgerRemaining,
    this.diff,
  );
  bool get passed => diff <= LedgerBackfillService.tolerance;
}

class BackfillReport {
  int accountsExamined = 0;
  int accountsMigrated = 0;
  int openingBalancesCreated = 0;
  int openingBalancesExpected = 0;
  int transactionsExamined = 0;
  int ledgerEntriesCreated = 0;
  int ledgerEntriesExpected = 0;
  int existingLedgerSkipped = 0;
  int lendingReconciled = 0;
  int creditReconciled = 0;
  int loanReconciled = 0;
  int orphanCount = 0;
  int duplicateCount = 0;
  int lendingRepaymentExceptions = 0;
  int salaryResidualExceptions = 0;
  bool passed = false;
  String? errorMessage;

  String historicalCompleteness = 'UNKNOWN';
  double openingAbsorbedSalary = 0.0;
  double openingAbsorbedUnsupported = 0.0;

  final List<BackfillParity> accountParity = [];
  final List<BackfillParity> lendingParity = [];
  final List<BackfillParity> creditParity = [];
  final List<BackfillLoanParity> loanParity = [];
  final List<String> exceptions = [];
  final List<String> hardFailures = [];
  final List<String> reviewItems = [];

  bool get isExecutable => passed;

  String get verdict {
    if (!passed) return 'FAIL — ROLLED BACK';
    return exceptions.isEmpty ? 'PASS' : 'EXECUTABLE_WITH_EXCEPTIONS';
  }

  Map<String, dynamic> toSummary() => {
        'verdict': verdict,
        'passed': passed,
        'isExecutable': isExecutable,
        'historicalCompleteness': historicalCompleteness,
        'openingAbsorbedSalary': openingAbsorbedSalary,
        'openingAbsorbedUnsupported': openingAbsorbedUnsupported,
        'accountsExamined': accountsExamined,
        'accountsMigrated': accountsMigrated,
        'openingBalancesCreated': openingBalancesCreated,
        'openingBalancesExpected': openingBalancesExpected,
        'ledgerEntriesCreated': ledgerEntriesCreated,
        'ledgerEntriesExpected': ledgerEntriesExpected,
        'existingLedgerSkipped': existingLedgerSkipped,
        'lendingReconciled': lendingReconciled,
        'creditReconciled': creditReconciled,
        'loanReconciled': loanReconciled,
        'orphanCount': orphanCount,
        'duplicateCount': duplicateCount,
        'lendingRepaymentExceptions': lendingRepaymentExceptions,
        'salaryResidualExceptions': salaryResidualExceptions,
        'accountParityPassed': accountParity.where((p) => p.passed).length,
        'creditParityPassed': creditParity.where((p) => p.passed).length,
        'loanParityPassed': loanParity.where((p) => p.passed).length,
        'reviewItems': reviewItems,
        'exceptions': exceptions,
        'hardFailures': hardFailures,
        'errorMessage': errorMessage,
      };
}

