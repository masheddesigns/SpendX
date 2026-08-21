// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' hide Transaction;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/tables.dart';

/// Phase 1C.1 — v21 schema-only boundary tests.
///
/// These prove the upgrade path performs SCHEMA migration only and never
/// backfills financial data. They use the public [AppDatabase.migrateSchemaOnly]
/// (the exact code [onUpgrade] invokes) and the explicit
/// [AppDatabase.runLedgerBackfill] entry point. They do NOT use the real
/// device DB (which already contains two legitimate historical ledger rows).
void main() {
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await openDatabase(inMemoryDatabasePath);
    await Tables.createAll(db);
  });

  tearDown(() async => db.close());

  /// Recreate ledger_transactions at the v19 shape (no category_id column),
  /// mirroring a real pre-v20 database, so migrations run from v19.
  Future<void> _downgradeLedgerToV19() async {
    await db.execute('ALTER TABLE ledger_transactions RENAME TO _lt_old');
    await db.execute('''
      CREATE TABLE ledger_transactions (
        id TEXT PRIMARY KEY, user_id TEXT, amount REAL NOT NULL,
        type TEXT NOT NULL, date TEXT NOT NULL, note TEXT,
        account_id TEXT, credit_card_id TEXT, loan_id TEXT,
        reference_id TEXT, created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      INSERT INTO ledger_transactions
        (id, user_id, amount, type, date, note, account_id,
         credit_card_id, loan_id, reference_id, created_at)
      SELECT id, user_id, amount, type, date, note, account_id,
             credit_card_id, loan_id, reference_id, created_at
      FROM _lt_old
    ''');
    await db.execute('DROP TABLE _lt_old');
  }

  Future<void> _seedTxn(String id, String type, double amount,
      {String? accountId}) async {
    await db.insert('transactions', {
      'id': id,
      'amount': amount,
      'type': type,
      'account_id': accountId,
      'date': DateTime(2025, 5, 1).toIso8601String(),
      'created_at': DateTime(2025, 5, 1).toIso8601String(),
      'updated_at': DateTime(2025, 5, 1).toIso8601String(),
    });
  }

  test('A. v19 → v21 upgrade is schema-only (no ledger backfill rows)',
      () async {
    await _downgradeLedgerToV19();
    await _seedTxn('t1', 'income', 500.0, accountId: 'A');
    await _seedTxn('t2', 'expense', 200.0, accountId: 'A');
    await db.execute('PRAGMA user_version = 19');

    await AppDatabase.instance.migrateSchemaOnly(db, 19);

    // Schema reached v21.
    final cols = await db.rawQuery('PRAGMA table_info(ledger_transactions)');
    expect(cols.any((c) => c['name'] == 'category_id'), isTrue,
        reason: 'v20 migration (category_id) must have run.');
    final logExists = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='ledger_backfill_log'",
    )).isNotEmpty;
    expect(logExists, isTrue, reason: 'v21 schema (log table) must exist.');

    // No financial backfill happened.
    expect((await db.query('ledger_transactions')).length, 0,
        reason: 'Upgrade must NOT create ledger backfill rows.');
    expect((await db.query('transactions')).length, 2,
        reason: 'Source transactions preserved.');
  });

  test('B. opening an already-v21 database does NOT backfill', () async {
    await _seedTxn('t1', 'income', 500.0, accountId: 'A');
    await _seedTxn('t2', 'expense', 200.0, accountId: 'A');
    await db.execute('PRAGMA user_version = 21');

    await AppDatabase.instance.migrateSchemaOnly(db, 21);

    expect((await db.query('ledger_transactions')).length, 0,
        reason: 'Even with transactions present, no backfill on v21 open.');
  });

  test('D. existing legacy ledger rows are preserved (not rewritten)',
      () async {
    await _downgradeLedgerToV19();
    await _seedTxn('t1', 'expense', 100.0, accountId: 'A');
    // A pre-existing ledger row that already represents t1.
    await db.insert('ledger_transactions', {
      'id': 'legacy-1',
      'type': 'expense',
      'amount': 100.0,
      'date': DateTime(2025, 1, 1).toIso8601String(),
      'account_id': 'A',
      'reference_id': 't1',
      'created_at': DateTime(2025, 1, 1).toIso8601String(),
    });
    await db.execute('PRAGMA user_version = 19');

    await AppDatabase.instance.migrateSchemaOnly(db, 19);

    final rows = await db.query('ledger_transactions');
    expect(rows.length, 1,
        reason: 'Schema-only upgrade must not add or remove ledger rows.');
    expect(rows.first['reference_id'], 't1');
    expect(rows.first['category_id'], isNull,
        reason: 'Pre-existing row kept; not re-backfilled.');
  });

  test('C. explicit runLedgerBackfill() remains callable and backfills '
      'independently of the upgrade path', () async {
    final dbPath = p.join(await getDatabasesPath(), 'spendx.db');
    final pre = File(dbPath);
    if (await pre.exists()) await pre.delete();
    try {
      final live = await AppDatabase.instance.database;
      await Tables.createAll(live);
      await live.insert('bank_accounts', {
        'id': 'A',
        'name': 'Savings',
        'balance': 1000.0,
        'is_asset': 1,
        'created_at': DateTime(2024, 1, 1).toIso8601String(),
        'updated_at': DateTime(2024, 1, 1).toIso8601String(),
      });
      await live.insert('transactions', {
        'id': 't1',
        'amount': 500.0,
        'type': 'income',
        'account_id': 'A',
        'date': DateTime(2025, 5, 1).toIso8601String(),
        'created_at': DateTime(2025, 5, 1).toIso8601String(),
        'updated_at': DateTime(2025, 5, 1).toIso8601String(),
      });

      await AppDatabase.instance.setBackfillEnabled(true);
      final report = await AppDatabase.instance.runLedgerBackfill(
        authorized: true,
        force: true,
      );

      expect(report.passed, isTrue);
      expect((await live.query('ledger_transactions')).length,
          greaterThanOrEqualTo(2),
          reason: 'Explicit backfill creates opening + income rows.');
    } finally {
      final f = File(dbPath);
      if (await f.exists()) await f.delete();
    }
  });
}
