// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' hide Transaction;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/migrations/ledger_backfill_service.dart';

void main() {
  late String dbPath;

  Future<Database> _openLive() async {
    final a = AppDatabase.instance;
    await a.close();
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
    final live = await a.database;
    await Tables.createAll(live);
    return live;
  }

  Future<void> _seedClean(Database db) async {
    await db.insert('bank_accounts', {
      'id': 'A',
      'name': 'Savings',
      'balance': 2000.0,
      'is_asset': 1,
      'created_at': DateTime(2024, 1, 1).toIso8601String(),
      'updated_at': DateTime(2024, 1, 1).toIso8601String(),
    });
    await db.insert('transactions', {
      'id': 't1',
      'amount': 600.0,
      'type': 'income',
      'account_id': 'A',
      'date': DateTime(2025, 5, 1).toIso8601String(),
      'created_at': DateTime(2025, 5, 1).toIso8601String(),
      'updated_at': DateTime(2025, 5, 1).toIso8601String(),
    });
  }

  Future<void> _seedOrphan(Database db) async {
    await _seedClean(db);
    await db.insert('ledger_transactions', {
      'id': 'orphan1',
      'type': 'expense',
      'amount': 10.0,
      'date': DateTime.now().toIso8601String(),
      'account_id': 'MISSING',
      'reference_id': 'noref',
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<String>> _statuses(Database db) async =>
      (await db.query('ledger_backfill_log'))
          .map((r) => r['status'] as String)
          .toList();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dbPath = p.join(await getDatabasesPath(), 'spendx_phase1e_test.db');
    AppDatabase.setTestDatabasePath(dbPath);
  });

  tearDownAll(() async {
    AppDatabase.auditLogWriter = null;
    AppDatabase.setTestDatabasePath(null);
    try {
      await AppDatabase.instance.close();
    } finally {
      final f = File(dbPath);
      if (await f.exists()) await f.delete();
    }
  });

  group('Phase 1E — outcome / audit logging', () {
    test('EXECUTION_SUCCESS logged on committed run; ledger mutated', () async {
      final live = await _openLive();
      await _seedClean(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      final report = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );

      expect(report.applied, isTrue);
      expect((await live.query('ledger_transactions')).length,
          greaterThanOrEqualTo(2));
      final logs = await _statuses(live);
      expect(logs, contains('EXECUTION_SUCCESS'));
    });

    test('EXECUTION_ROLLBACK on orphan; ledger unchanged; no success marker',
        () async {
      final live = await _openLive();
      await _seedOrphan(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      final report = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );

      expect(report.applied, isFalse);
      expect(report.blockReason, 'fail');
      // No ledger mutation: only the pre-existing orphan row remains.
      expect((await live.query('ledger_transactions')).length, 1);
      final logs = await _statuses(live);
      expect(logs, contains('EXECUTION_ROLLBACK'));
      expect(logs, isNot(contains('EXECUTION_SUCCESS')));
    });

    test('PREFLIGHT_PASS logged (no mutation)', () async {
      final live = await _openLive();
      await _seedClean(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      final report = await AppDatabase.instance.runLedgerBackfill(
        authorized: false,
        force: true,
      );

      expect(report.blockReason, 'preflight');
      expect((await live.query('ledger_transactions')).isEmpty, isTrue);
      final logs = await _statuses(live);
      expect(logs, contains('PREFLIGHT_PASS'));
    });

    test('PREFLIGHT_FAIL logged (no mutation)', () async {
      final live = await _openLive();
      await _seedOrphan(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      final report = await AppDatabase.instance.runLedgerBackfill(
        authorized: false,
        force: true,
      );

      expect(report.blockReason, 'preflight');
      expect((await live.query('ledger_transactions')).length, 1);
      final logs = await _statuses(live);
      expect(logs, contains('PREFLIGHT_FAIL'));
    });

    test('BLOCKED_BY_FLAG logged when feature flag off', () async {
      final live = await _openLive();
      await _seedClean(live);
      await AppDatabase.instance.setBackfillEnabled(false);
      await AppDatabase.instance.setKillSwitch(false);

      final report = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );

      expect(report.blockReason, 'flag');
      expect((await live.query('ledger_transactions')).isEmpty, isTrue);
      final logs = await _statuses(live);
      expect(logs, contains('BLOCKED_BY_FLAG'));
    });

    test('BLOCKED_BY_KILL_SWITCH logged when kill switch active', () async {
      final live = await _openLive();
      await _seedClean(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(true);

      final report = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );

      expect(report.blockReason, 'kill');
      expect((await live.query('ledger_transactions')).isEmpty, isTrue);
      final logs = await _statuses(live);
      expect(logs, contains('BLOCKED_BY_KILL_SWITCH'));
    });
  });

  group('Phase 1E — idempotency mapping', () {
    test('EXECUTION_SUCCESS blocks future runs (without force)', () async {
      final live = await _openLive();
      await _seedClean(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      await AppDatabase.instance.runLedgerBackfill(authorized: true);
      final before = (await live.query('ledger_transactions')).length;

      final again =
          await AppDatabase.instance.runLedgerBackfill(authorized: true);
      expect(again.exceptions.join('\n'), contains('Prior successful'));
      expect((await live.query('ledger_transactions')).length, before);
      expect(await _statuses(live), ['EXECUTION_SUCCESS']);
    });

    test('PREFLIGHT_PASS does NOT block future execution', () async {
      final live = await _openLive();
      await _seedClean(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      await AppDatabase.instance.runLedgerBackfill(authorized: false);
      final exec =
          await AppDatabase.instance.runLedgerBackfill(authorized: true);
      expect(exec.applied, isTrue);
      expect((await live.query('ledger_transactions')).length,
          greaterThanOrEqualTo(2));
    });

    test('EXECUTION_ROLLBACK does NOT block future execution', () async {
      final live = await _openLive();
      await _seedOrphan(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      await AppDatabase.instance.runLedgerBackfill(authorized: true);
      // Second attempt is not skipped (re-attempts and fails again).
      final retry =
          await AppDatabase.instance.runLedgerBackfill(authorized: true);
      expect(retry.blockReason, 'fail'); // attempted, not idempotency-skipped
    });

    test('BLOCKED_BY_FLAG does NOT block future execution', () async {
      final live = await _openLive();
      await _seedClean(live);
      await AppDatabase.instance.setBackfillEnabled(false);
      await AppDatabase.instance.setKillSwitch(false);

      await AppDatabase.instance.runLedgerBackfill(authorized: true);
      await AppDatabase.instance.setBackfillEnabled(true);
      final exec = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );
      expect(exec.applied, isTrue);
    });
  });

  group('Phase 1E — audit-log failure is non-destructive', () {
    test('commit survives audit-log write failure; applied stays true',
        () async {
      final live = await _openLive();
      await _seedClean(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      AppDatabase.auditLogWriter =
          (_, __, ___) => throw Exception('boom');

      final report = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );

      // No exception escaped; financial outcome intact.
      expect(report.applied, isTrue);
      expect((await live.query('ledger_transactions')).length,
          greaterThanOrEqualTo(2));
      // Audit log write failed -> no success row persisted.
      expect(await _statuses(live), isEmpty);
      AppDatabase.auditLogWriter = null;
    });
  });

  group('Phase 1E — TOCTOU: in-transaction flag/kill re-check', () {
    test('preflight executable, then flag flipped -> execute rejected',
        () async {
      final live = await _openLive();
      await _seedClean(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      final pre =
          await AppDatabase.instance.runLedgerBackfill(authorized: false);
      expect(pre.verdict, contains('PASS'));
      expect((await live.query('ledger_transactions')).isEmpty, isTrue);

      // Flip the feature flag OFF before execution.
      await AppDatabase.instance.setBackfillEnabled(false);
      final exec = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );

      expect(exec.blockReason, 'flag');
      expect((await live.query('ledger_transactions')).isEmpty, isTrue);
      expect(await _statuses(live), contains('BLOCKED_BY_FLAG'));
    });

    test('preflight executable, then kill switch flipped -> execute rejected',
        () async {
      final live = await _openLive();
      await _seedClean(live);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      await AppDatabase.instance.runLedgerBackfill(authorized: false);
      await AppDatabase.instance.setKillSwitch(true);
      final exec = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );

      expect(exec.blockReason, 'kill');
      expect((await live.query('ledger_transactions')).isEmpty, isTrue);
      expect(await _statuses(live), contains('BLOCKED_BY_KILL_SWITCH'));
    });

    test('in-transaction gate rejects when flag off (enforceFlagKill)', () async {
      final db = await _openLive();
      await _seedClean(db);

      final report = await LedgerBackfillService.reconcile(
        db,
        authorized: true,
        enforceFlagKill: true,
      );
      expect(report.blockReason, 'flag');
      expect(report.applied, isFalse);
      expect((await db.query('ledger_transactions')).isEmpty, isTrue);
    });

    test('in-transaction gate allows when flag on (enforceFlagKill)', () async {
      final db = await _openLive();
      await _seedClean(db);
      await db.insert('ledger_backfill_flags',
          {'key': 'enabled', 'value': 'true'});

      final report = await LedgerBackfillService.reconcile(
        db,
        authorized: true,
        enforceFlagKill: true,
      );
      expect(report.applied, isTrue);
      expect((await db.query('ledger_transactions')).length,
          greaterThanOrEqualTo(2));
    });
  });

  group('Phase 1E — LOAN_CREDIT_INTEREST_RESIDUAL exception', () {
    Future<void> _seedLoanWithInterest(Database db, double interest) async {
      await _seedClean(db);
      await db.insert('loans', {
        'id': 'L1',
        'name': 'Test Loan',
        'total': 1000.0,
        'start_date': DateTime(2024, 1, 1).toIso8601String(),
      });
      await db.insert('loan_installments', {
        'id': 'LI1',
        'loanId': 'L1',
        'status': 'paid',
        'amount': 150.0,
        'principalComponent': 100.0,
        'interestComponent': interest,
        'dueDate': DateTime(2025, 1, 1).toIso8601String(),
        'paidDate': DateTime(2025, 1, 1).toIso8601String(),
      });
    }

    test('interest residual is named exception; balanced but not journalized',
        () async {
      final live = await _openLive();
      await _seedLoanWithInterest(live, 50.0);
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      final report = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );

      expect(report.verdict, 'EXECUTABLE_WITH_EXCEPTIONS');
      expect(report.openingAbsorbedInterest, 50.0);
      expect(report.passed, isTrue); // balanced
      expect(report.historicallyJournalized, isFalse);
      expect(report.exceptions.join('\n'),
          contains('LOAN_CREDIT_INTEREST_RESIDUAL'));
      expect((await live.query('ledger_transactions')).isNotEmpty, isTrue);
    });

    test('unquantifiable (NULL) interest FAILs, never becomes zero', () async {
      final live = await _openLive();
      await _seedLoanWithInterest(live, 50.0);
      await live.insert('loan_installments', {
        'id': 'LI2',
        'loanId': 'L1',
        'status': 'paid',
        'amount': 150.0,
        'principalComponent': 100.0,
        'interestComponent': null,
        'dueDate': DateTime(2025, 2, 1).toIso8601String(),
        'paidDate': DateTime(2025, 2, 1).toIso8601String(),
      });
      await AppDatabase.instance.setBackfillEnabled(true);
      await AppDatabase.instance.setKillSwitch(false);

      final report = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );

      expect(report.verdict, contains('FAIL'));
      expect(report.applied, isFalse);
      expect((await live.query('ledger_transactions')).isEmpty, isTrue);
    });
  });
}
