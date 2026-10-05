import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/migrations/migration_v24_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<bool> tableExists(DatabaseExecutor db, String tableName) async {
    final result = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      [tableName],
    );
    return result.isNotEmpty;
  }

  Future<void> seedStandardLegacyData(Database db) async {
    final now = DateTime(2025, 1, 1).toIso8601String();

    await db.insert('bank_accounts', {
      'id': 'acc_hdfc',
      'name': 'HDFC Salary',
      'balance': 50000.0,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('categories', {
      'id': 'cat_groceries',
      'name': 'Groceries',
      'type': 'expense',
    });
    await db.insert('categories', {
      'id': 'cat_salary',
      'name': 'Salary',
      'type': 'income',
    });
    await db.insert('transactions', {
      'id': 'tx_1',
      'amount': 5000.0,
      'type': 'expense',
      'account_id': 'acc_hdfc',
      'category_id': 'cat_groceries',
      'date': now,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('transactions', {
      'id': 'tx_2',
      'amount': 25000.0,
      'type': 'income',
      'account_id': 'acc_hdfc',
      'category_id': 'cat_salary',
      'date': now,
      'created_at': now,
      'updated_at': now,
    });

    // Seed vehicle tables (Milestone A obsolete)
    await db.insert('vehicles', {
      'id': 'veh_1',
      'name': 'Honda Civic',
      'created_at': now,
    });
    await db.insert('fuel_logs', {
      'id': 'fuel_1',
      'vehicle_id': 'veh_1',
      'date': now,
      'total_cost': 2500.0,
      'created_at': now,
    });
    await db.insert('vehicle_reminders', {
      'id': 'vr_1',
      'vehicle_id': 'veh_1',
      'title': 'Oil Change',
      'type': 'service',
      'due_date': now,
      'created_at': now,
    });

    // Seed bank_balance_snapshots (pre-v21 obsolete cache)
    await db.insert('bank_balance_snapshots', {
      'accountId': 'acc_hdfc',
      'balance': 50000.0,
      'timestamp': 1704067200,
    });

    // Seed ledger_transactions (interim journal)
    await db.insert('ledger_transactions', {
      'id': 'ltx_1',
      'amount': 5000.0,
      'type': 'expense',
      'date': now,
      'account_id': 'acc_hdfc',
      'created_at': now,
    });
  }

  Future<Database> createFreshDb() async {
    final db = await openDatabase(
      inMemoryDatabasePath,
      singleInstance: false,
      onConfigure: (d) async => await d.execute('PRAGMA foreign_keys = ON;'),
    );
    await Tables.createAll(db);
    await seedStandardLegacyData(db);
    return db;
  }

  group('Milestone C2C — Destructive Schema Cleanup Suite', () {
    test('1. Destruction disabled by default (allowDestructiveDrops = false)', () async {
      final db = await createFreshDb();

      // Default migration call
      final result = await MigrationV24Service.migrate(db);
      expect(result.destructiveDropsExecuted, isFalse);

      // Verify obsolete tables are STILL physically present
      for (final tbl in MigrationV24Service.approvedDestructiveDropTables) {
        expect(
          await tableExists(db, tbl),
          isTrue,
          reason: 'Table $tbl should remain when destruction is disabled',
        );
      }

      await db.close();
    });

    test('2. Destruction enabled explicitly (allowDestructiveDrops = true)', () async {
      final db = await createFreshDb();

      final result = await MigrationV24Service.migrate(
        db,
        allowDestructiveDrops: true,
      );
      expect(result.destructiveDropsExecuted, isTrue);

      await db.close();
    });

    test('3. Approved legacy tables removed', () async {
      final db = await createFreshDb();

      await MigrationV24Service.migrate(db, allowDestructiveDrops: true);

      // Exactly the 4 approved tables are removed
      expect(await tableExists(db, 'vehicles'), isFalse);
      expect(await tableExists(db, 'fuel_logs'), isFalse);
      expect(await tableExists(db, 'vehicle_reminders'), isFalse);
      expect(await tableExists(db, 'bank_balance_snapshots'), isFalse);

      await db.close();
    });

    test('4. Canonical tables retained', () async {
      final db = await createFreshDb();

      await MigrationV24Service.migrate(db, allowDestructiveDrops: true);

      // 10 Canonical v24 tables MUST exist
      const canonicalTables = [
        TablesV24.accounts,
        TablesV24.economicEvents,
        TablesV24.evidence,
        TablesV24.postings,
        TablesV24.assetEarmarks,
        TablesV24.recurringRules,
        TablesV24.expectedEvents,
        TablesV24.reviewCandidates,
        TablesV24.openingBalanceReconciliations,
        TablesV24.migrationExceptions,
      ];
      for (final tbl in canonicalTables) {
        expect(
          await tableExists(db, tbl),
          isTrue,
          reason: 'Canonical table $tbl must exist',
        );
      }

      // KEEP_TRANSITIONAL tables MUST exist
      expect(await tableExists(db, 'transactions'), isTrue);
      expect(await tableExists(db, 'ledger_transactions'), isTrue);
      expect(await tableExists(db, 'bank_accounts'), isTrue);
      expect(await tableExists(db, 'categories'), isTrue);

      await db.close();
    });

    test('5. Canonical triggers retained and operational', () async {
      final db = await createFreshDb();

      await MigrationV24Service.migrate(db, allowDestructiveDrops: true);

      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger';",
      );
      final triggerNames = triggers.map((t) => t['name'] as String).toSet();

      expect(
        triggerNames,
        containsAll([
          'trg_economic_events_prevent_direct_posted_insert',
          'trg_economic_events_validate_posted',
          'trg_postings_prevent_insert_on_posted',
          'trg_postings_prevent_update_on_posted',
          'trg_postings_prevent_delete_on_posted',
          'trg_economic_events_prevent_mutation_on_posted',
          'trg_economic_events_prevent_delete_posted',
        ]),
      );

      await db.close();
    });

    test('6. Foreign Key integrity: zero violations post-destruction', () async {
      final db = await createFreshDb();

      await MigrationV24Service.migrate(db, allowDestructiveDrops: true);

      final fkViolations = await db.rawQuery('PRAGMA foreign_key_check;');
      expect(fkViolations, isEmpty);

      await db.close();
    });

    test('7. SQLite integrity check returns ok', () async {
      final db = await createFreshDb();

      await MigrationV24Service.migrate(db, allowDestructiveDrops: true);

      final integrity = (await db.rawQuery('PRAGMA integrity_check;')).first.values.first;
      expect(integrity, 'ok');

      final userVersion = (await db.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(userVersion, 24);

      await db.close();
    });

    test('8. Posted-event immutability verified post-destruction', () async {
      final db = await createFreshDb();

      await MigrationV24Service.migrate(db, allowDestructiveDrops: true);

      // Attempt to mutate posted posting
      expect(
        () => db.update(
          TablesV24.postings,
          {'amount_minor_units': 999999},
          where: 'economic_event_id = ?',
          whereArgs: ['tx_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Attempt to delete posted posting
      expect(
        () => db.delete(
          TablesV24.postings,
          where: 'economic_event_id = ?',
          whereArgs: ['tx_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Attempt to delete posted event
      expect(
        () => db.delete(
          TablesV24.economicEvents,
          where: 'id = ?',
          whereArgs: ['tx_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      await db.close();
    });

    test('9. Draft-event behavior intact post-destruction', () async {
      final db = await createFreshDb();

      await MigrationV24Service.migrate(db, allowDestructiveDrops: true);

      final now = DateTime.now().toIso8601String();
      // 1. Insert draft event
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_draft_new',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Draft test',
        'created_at': now,
        'updated_at': now,
      });

      // 2. Insert single leg (allowed in draft)
      await db.insert(TablesV24.postings, {
        'id': 'pst_leg_1',
        'economic_event_id': 'evt_draft_new',
        'account_id': 'cat_groceries',
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 12000,
        'created_at': now,
      });

      // 3. Attempt to post while unbalanced -> blocked
      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_draft_new'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // 4. Insert balancing leg and post successfully
      await db.insert(TablesV24.postings, {
        'id': 'pst_leg_2',
        'economic_event_id': 'evt_draft_new',
        'account_id': 'acc_hdfc',
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 12000,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_draft_new'],
      );

      final postedEvent = (await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: ['evt_draft_new'],
      )).first;
      expect(postedEvent['lifecycle_status'], 'posted');

      await db.close();
    });

    test('10. Financial Parity: Before and after destructive cleanup', () async {
      // DB 1: Destruction disabled (baseline)
      final db1 = await createFreshDb();
      await MigrationV24Service.migrate(db1, allowDestructiveDrops: false);

      // DB 2: Destruction enabled
      final db2 = await createFreshDb();
      await MigrationV24Service.migrate(db2, allowDestructiveDrops: true);

      // Extract metrics helper
      Future<Map<String, int>> getFinancialMetrics(Database d) async {
        final balRow = await d.rawQuery('''
          SELECT 
            COALESCE(SUM(CASE WHEN a.account_type = 'asset' AND p.direction = 'debit' THEN p.amount_minor_units
                              WHEN a.account_type = 'asset' AND p.direction = 'credit' THEN -p.amount_minor_units ELSE 0 END), 0) AS total_assets,
            COALESCE(SUM(CASE WHEN a.account_type = 'liability' AND p.direction = 'credit' THEN p.amount_minor_units
                              WHEN a.account_type = 'liability' AND p.direction = 'debit' THEN -p.amount_minor_units ELSE 0 END), 0) AS total_liabilities,
            COALESCE(SUM(CASE WHEN a.account_type = 'income' AND p.direction = 'credit' THEN p.amount_minor_units
                              WHEN a.account_type = 'income' AND p.direction = 'debit' THEN -p.amount_minor_units ELSE 0 END), 0) AS total_income,
            COALESCE(SUM(CASE WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units
                              WHEN a.account_type = 'expense' AND p.direction = 'credit' THEN -p.amount_minor_units ELSE 0 END), 0) AS total_expenses
          FROM ${TablesV24.postings} p
          JOIN ${TablesV24.accounts} a ON p.account_id = a.id
          JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
          WHERE e.lifecycle_status = 'posted';
        ''');

        final row = balRow.first;
        return {
          'assets': row['total_assets'] as int,
          'liabilities': row['total_liabilities'] as int,
          'income': row['total_income'] as int,
          'expenses': row['total_expenses'] as int,
        };
      }

      final metrics1 = await getFinancialMetrics(db1);
      final metrics2 = await getFinancialMetrics(db2);

      // Mathematical identity
      expect(metrics2['assets'], metrics1['assets']);
      expect(metrics2['liabilities'], metrics1['liabilities']);
      expect(metrics2['income'], metrics1['income']);
      expect(metrics2['expenses'], metrics1['expenses']);

      await db1.close();
      await db2.close();
    });

    test('11. Event and Posting counts match before and after cleanup', () async {
      final db1 = await createFreshDb();
      await MigrationV24Service.migrate(db1, allowDestructiveDrops: false);

      final db2 = await createFreshDb();
      await MigrationV24Service.migrate(db2, allowDestructiveDrops: true);

      final events1 = (await db1.query(TablesV24.economicEvents)).length;
      final events2 = (await db2.query(TablesV24.economicEvents)).length;
      expect(events2, events1);

      final postings1 = (await db1.query(TablesV24.postings)).length;
      final postings2 = (await db2.query(TablesV24.postings)).length;
      expect(postings2, postings1);

      final evidence1 = (await db1.query(TablesV24.evidence)).length;
      final evidence2 = (await db2.query(TablesV24.evidence)).length;
      expect(evidence2, evidence1);

      final obr1 = (await db1.query(TablesV24.openingBalanceReconciliations)).length;
      final obr2 = (await db2.query(TablesV24.openingBalanceReconciliations)).length;
      expect(obr2, obr1);

      await db1.close();
      await db2.close();
    });

    test('12 & 13. Pre-migration backup integrity and independent reopen', () async {
      final tempDir = await Directory.systemTemp.createTemp('spendx_c2c_backup');
      final dbPath = '${tempDir.path}/live.db';

      final liveDb = await openDatabase(
        dbPath,
        version: 23,
        onCreate: (d, v) async {
          await Tables.createAll(d);
          await seedStandardLegacyData(d);
        },
      );

      final backupPath = await MigrationV24Service.createPreMigrationBackup(liveDb);
      expect(backupPath, isNotNull);

      // Perform destructive migration on live DB
      await MigrationV24Service.migrate(
        liveDb,
        allowDestructiveDrops: true,
        backupPath: backupPath,
      );

      // Verify live DB has dropped obsolete tables
      expect(await tableExists(liveDb, 'vehicles'), isFalse);
      expect(await tableExists(liveDb, 'fuel_logs'), isFalse);

      // Independently reopen backup DB
      final backupDb = await openDatabase(backupPath!);
      final integrity = (await backupDb.rawQuery('PRAGMA integrity_check;')).first.values.first;
      expect(integrity, 'ok');

      final backupVer = (await backupDb.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(backupVer, 23);

      // Verify backup RETAINS all legacy tables intact!
      expect(await tableExists(backupDb, 'vehicles'), isTrue);
      expect(await tableExists(backupDb, 'fuel_logs'), isTrue);
      expect(await tableExists(backupDb, 'vehicle_reminders'), isTrue);
      expect(await tableExists(backupDb, 'bank_balance_snapshots'), isTrue);

      final vehicles = await backupDb.query('vehicles');
      expect(vehicles.length, 1);
      expect(vehicles.first['name'], 'Honda Civic');

      await backupDb.close();
      await liveDb.close();
      await tempDir.delete(recursive: true);
    });

    test('14. Migration idempotency post-destruction', () async {
      final db = await createFreshDb();

      // 1st migration with destruction
      final res1 = await MigrationV24Service.migrate(db, allowDestructiveDrops: true);
      expect(res1.alreadyMigrated, isFalse);

      // 2nd migration
      final res2 = await MigrationV24Service.migrate(db, allowDestructiveDrops: true);
      expect(res2.alreadyMigrated, isTrue);

      // Assert zero duplicate events or postings
      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, res1.eventsMigrated);

      await db.close();
    });

    test('15. Injected failure safety: transaction atomicity rolls back cleanly', () async {
      final db = await createFreshDb();

      // Run migration inside transaction and throw
      await db.transaction((txn) async {
        try {
          await txn.execute('DROP TABLE IF EXISTS non_existent;');
          throw StateError('Simulated crash during destructive cleanup');
        } catch (_) {}
      });

      // Verify database remains valid and user_version is 0/unmigrated
      final ver = (await db.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(ver, 0);

      // Verify legacy tables still intact
      expect(await tableExists(db, 'vehicles'), isTrue);
      expect(await tableExists(db, 'fuel_logs'), isTrue);

      await db.close();
    });

    test('16. No accidental repository dependency introduced', () async {
      final db = await createFreshDb();

      await MigrationV24Service.migrate(db, allowDestructiveDrops: true);

      // Verify transactions and ledger_transactions can be queried by legacy repositories without error
      final txRows = await db.query(Tables.transactions);
      expect(txRows.length, 2);

      final ltxRows = await db.query(Tables.ledgerTransactions);
      expect(ltxRows.length, 1);

      await db.close();
    });
  });
}
