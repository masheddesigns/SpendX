// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spend_x/data/core/tables_v24.dart';
import 'fixtures/migration_v25_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() {
    MigrationV25Service.testFailureInjector = null;
  });

  /// Creates a realistic, disposable v24 SQLite database file populated with
  /// canonical double-entry accounting data, postings, evidence, and v24 triggers.
  Future<String> createV24DatabaseFixture(Directory tempDir, String name) async {
    final dbPath = p.join(tempDir.path, name);
    final db = await openDatabase(
      dbPath,
      version: 24,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
      },
      onCreate: (db, version) async {
        await TablesV24.createAllV24(db);
        await TablesV24.seedSystemAccounts(db);
        await TablesV24.installTriggers(db);
      },
    );

    // 1. Seed custom user accounts
    await db.insert(TablesV24.accounts, {
      'id': 'acc_bank_sbi',
      'account_type': 'asset',
      'subtype': 'checking',
      'name': 'SBI Checking',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': '2026-01-01T00:00:00.000Z',
    });

    await db.insert(TablesV24.accounts, {
      'id': 'acc_card_hdfc',
      'account_type': 'liability',
      'subtype': 'credit_card',
      'name': 'HDFC Regalia',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': '2026-01-01T00:00:00.000Z',
    });

    await db.insert(TablesV24.accounts, {
      'id': 'acc_bank_savings',
      'account_type': 'asset',
      'subtype': 'savings',
      'name': 'SBI Savings',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': '2026-01-01T00:00:00.000Z',
    });

    // 2. Seed Historical Event 1: Expense (₹1,250 = 125,000 minor units)
    await db.insert(TablesV24.economicEvents, {
      'id': 'ev_exp_001',
      'event_type': 'expense',
      'lifecycle_status': 'draft',
      'timestamp': '2026-02-01T10:00:00.000Z',
      'currency': 'INR',
      'description': 'Supermarket Groceries',
      'category_id': TablesV24.sysExpMisc,
      'created_at': '2026-02-01T10:00:00.000Z',
      'updated_at': '2026-02-01T10:00:00.000Z',
    });
    await db.insert(TablesV24.postings, {
      'id': 'pst_exp_001_dr',
      'economic_event_id': 'ev_exp_001',
      'account_id': TablesV24.sysExpMisc,
      'direction': 'debit',
      'amount_minor_units': 125000,
      'currency': 'INR',
      'created_at': '2026-02-01T10:00:00.000Z',
    });
    await db.insert(TablesV24.postings, {
      'id': 'pst_exp_001_cr',
      'economic_event_id': 'ev_exp_001',
      'account_id': 'acc_bank_sbi',
      'direction': 'credit',
      'amount_minor_units': 125000,
      'currency': 'INR',
      'created_at': '2026-02-01T10:00:00.000Z',
    });
    await db.insert(TablesV24.evidence, {
      'id': 'evi_exp_001',
      'economic_event_id': 'ev_exp_001',
      'source_type': 'sms',
      'extracted_amount_minor_units': 125000,
      'extracted_timestamp': '2026-02-01T10:00:00.000Z',
      'sender_address': 'SBIINB',
      'external_reference': 'UPI:RRN:501100112233',
      'body_sha256': 'hash_exp_001',
      'raw_payload_encrypted': 'ENC:payload_exp_001',
      'created_at': '2026-02-01T10:00:00.000Z',
    });
    await db.update(
      TablesV24.economicEvents,
      {'lifecycle_status': 'posted'},
      where: 'id = ?',
      whereArgs: ['ev_exp_001'],
    );

    // 3. Seed Historical Event 2: Credit Card Purchase (₹3,400 = 340,000 minor units)
    await db.insert(TablesV24.economicEvents, {
      'id': 'ev_card_002',
      'event_type': 'credit_purchase',
      'lifecycle_status': 'draft',
      'timestamp': '2026-02-02T12:00:00.000Z',
      'currency': 'INR',
      'description': 'Electronics Store',
      'category_id': TablesV24.sysExpMisc,
      'created_at': '2026-02-02T12:00:00.000Z',
      'updated_at': '2026-02-02T12:00:00.000Z',
    });
    await db.insert(TablesV24.postings, {
      'id': 'pst_card_002_dr',
      'economic_event_id': 'ev_card_002',
      'account_id': TablesV24.sysExpMisc,
      'direction': 'debit',
      'amount_minor_units': 340000,
      'currency': 'INR',
      'created_at': '2026-02-02T12:00:00.000Z',
    });
    await db.insert(TablesV24.postings, {
      'id': 'pst_card_002_cr',
      'economic_event_id': 'ev_card_002',
      'account_id': 'acc_card_hdfc',
      'direction': 'credit',
      'amount_minor_units': 340000,
      'currency': 'INR',
      'created_at': '2026-02-02T12:00:00.000Z',
    });
    await db.insert(TablesV24.evidence, {
      'id': 'evi_card_002',
      'economic_event_id': 'ev_card_002',
      'source_type': 'sms',
      'extracted_amount_minor_units': 340000,
      'extracted_timestamp': '2026-02-02T12:00:00.000Z',
      'sender_address': 'HDFCBK',
      'external_reference': 'HDFC:CC:TX998877',
      'body_sha256': 'hash_card_002',
      'raw_payload_encrypted': 'ENC:payload_card_002',
      'created_at': '2026-02-02T12:00:00.000Z',
    });
    await db.update(
      TablesV24.economicEvents,
      {'lifecycle_status': 'posted'},
      where: 'id = ?',
      whereArgs: ['ev_card_002'],
    );

    // 4. Seed Historical Event 3: Transfer (₹5,000 = 500,000 minor units)
    await db.insert(TablesV24.economicEvents, {
      'id': 'ev_xfer_003',
      'event_type': 'transfer',
      'lifecycle_status': 'draft',
      'timestamp': '2026-02-03T15:00:00.000Z',
      'currency': 'INR',
      'description': 'Savings Transfer',
      'created_at': '2026-02-03T15:00:00.000Z',
      'updated_at': '2026-02-03T15:00:00.000Z',
    });
    await db.insert(TablesV24.postings, {
      'id': 'pst_xfer_003_dr',
      'economic_event_id': 'ev_xfer_003',
      'account_id': 'acc_bank_savings',
      'direction': 'debit',
      'amount_minor_units': 500000,
      'currency': 'INR',
      'created_at': '2026-02-03T15:00:00.000Z',
    });
    await db.insert(TablesV24.postings, {
      'id': 'pst_xfer_003_cr',
      'economic_event_id': 'ev_xfer_003',
      'account_id': 'acc_bank_sbi',
      'direction': 'credit',
      'amount_minor_units': 500000,
      'currency': 'INR',
      'created_at': '2026-02-03T15:00:00.000Z',
    });
    await db.update(
      TablesV24.economicEvents,
      {'lifecycle_status': 'posted'},
      where: 'id = ?',
      whereArgs: ['ev_xfer_003'],
    );

    // Verify baseline fixture state
    final verRows = await db.rawQuery('PRAGMA user_version;');
    expect(verRows.first.values.first, 24);

    await db.close();
    return dbPath;
  }

  /// Upgrades a database file using the real `openDatabase(..., version: 25, onUpgrade: ...)` path.
  Future<Database> upgradeToV25(
    String dbPath, {
    int watermarkDate = 1770000000000,
    int watermarkId = 450,
  }) async {
    return await openDatabase(
      dbPath,
      version: 25,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 25) {
          // Uses the exact single executor provided by onUpgrade, zero nested transactions
          await MigrationV25Service.run(
            db,
            watermarkSnapshotDate: watermarkDate,
            watermarkSnapshotId: watermarkId,
          );
        }
      },
      onDowngrade: (db, oldVersion, newVersion) async {
        throw StateError(
          'FATAL: Database schema version ($oldVersion) is newer than application version ($newVersion). '
          'Downgrade is prohibited to prevent data loss. Please update the application.',
        );
      },
    );
  }

  group('Stage 1 — Isolated V24 → V25 Migration & Rollback Testing', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('spendx_stage1_test_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('S1-01: Clean v24 → v25 upgrade succeeds with historical records intact', () async {
      final dbPath = await createV24DatabaseFixture(tempDir, 's1_01_clean.db');

      final db = await upgradeToV25(dbPath, watermarkDate: 1771122334455, watermarkId: 8899);

      try {
        // 1. Verify user_version is 25
        final verRows = await db.rawQuery('PRAGMA user_version;');
        expect(verRows.first.values.first, 25);

        // 2. Verify PRAGMA integrity_check passes
        final integrity = await db.rawQuery('PRAGMA integrity_check;');
        expect(integrity.first.values.first, 'ok');

        // 3. Verify all historical v24 data survived intact
        final events = await db.query(TablesV24.economicEvents, orderBy: 'id ASC');
        expect(events.length, 3);
        expect(events[0]['id'], 'ev_card_002');
        expect(events[1]['id'], 'ev_exp_001');
        expect(events[2]['id'], 'ev_xfer_003');

        final postings = await db.query(TablesV24.postings);
        expect(postings.length, 6); // 2 per event

        final evidenceRows = await db.query(TablesV24.evidence, orderBy: 'id ASC');
        expect(evidenceRows.length, 2);
        // Pre-migration rows must have source_record_id = NULL
        expect(evidenceRows[0]['source_record_id'], isNull);
        expect(evidenceRows[1]['source_record_id'], isNull);
        expect(evidenceRows[0]['raw_payload_encrypted'], 'ENC:payload_card_002');
        expect(evidenceRows[1]['raw_payload_encrypted'], 'ENC:payload_exp_001');

        // 4. Verify new schema objects exist
        final refundAllocTable = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='refund_allocations';",
        );
        expect(refundAllocTable.isNotEmpty, isTrue);

        final baselineTable = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='migration_historical_baselines';",
        );
        expect(baselineTable.isNotEmpty, isTrue);

        // 5. Verify watermark snapshot was captured accurately
        final baselineRows = await db.query('migration_historical_baselines');
        expect(baselineRows.length, 1);
        expect(baselineRows.first['id'], 'V25_BASELINE');
        expect(baselineRows.first['migration_version'], 25);
        expect(baselineRows.first['watermark_snapshot_date'], 1771122334455);
        expect(baselineRows.first['watermark_snapshot_id'], 8899);

        // 6. Verify Triggers 1 through 6 exist in sqlite_master
        final triggerRows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg_%';",
        );
        final triggerNames = triggerRows.map((r) => r['name'] as String).toSet();
        expect(triggerNames.contains('trg_refund_allocations_validate_insert'), isTrue);
        expect(triggerNames.contains('trg_refund_allocations_prevent_update'), isTrue);
        expect(triggerNames.contains('trg_refund_allocations_prevent_delete'), isTrue);
        expect(triggerNames.contains('trg_economic_events_prevent_direct_posted_refund'), isTrue);
        expect(triggerNames.contains('trg_economic_events_protect_refunded_parents'), isTrue);
        expect(triggerNames.contains('trg_economic_events_validate_refund_posted'), isTrue);
      } finally {
        await db.close();
      }
    });

    test('S1-02: Failure after source_record_id column addition rolls back completely to v24', () async {
      final dbPath = await createV24DatabaseFixture(tempDir, 's1_02_fail_col.db');

      // Inject failure after Step 1
      MigrationV25Service.testFailureInjector = (step) {
        if (step == MigrationV25Step.addColumn) {
          throw Exception('INJECTED_FAILURE_AFTER_ADD_COLUMN');
        }
      };

      // Upgrade must throw and fail
      expect(
        () => upgradeToV25(dbPath),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('INJECTED_FAILURE_AFTER_ADD_COLUMN'))),
      );

      // Re-open at v24 to verify transactional rollback
      final db = await openDatabase(dbPath, version: 24);
      try {
        final verRows = await db.rawQuery('PRAGMA user_version;');
        expect(verRows.first.values.first, 24);

        final integrity = await db.rawQuery('PRAGMA integrity_check;');
        expect(integrity.first.values.first, 'ok');

        // Column source_record_id must NOT exist
        final tableInfo = await db.rawQuery("PRAGMA table_info('evidence');");
        final colNames = tableInfo.map((r) => r['name'] as String).toSet();
        expect(colNames.contains('source_record_id'), isFalse);

        // Historical data completely intact
        final events = await db.query(TablesV24.economicEvents);
        expect(events.length, 3);
      } finally {
        await db.close();
      }
    });

    test('S1-03: Failure after refund_allocations creation rolls back completely to v24', () async {
      final dbPath = await createV24DatabaseFixture(tempDir, 's1_03_fail_alloc.db');

      // Inject failure after Step 2
      MigrationV25Service.testFailureInjector = (step) {
        if (step == MigrationV25Step.createRefundAllocations) {
          throw Exception('INJECTED_FAILURE_AFTER_CREATE_REFUND_ALLOCATIONS');
        }
      };

      expect(
        () => upgradeToV25(dbPath),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('INJECTED_FAILURE_AFTER_CREATE_REFUND_ALLOCATIONS'))),
      );

      final db = await openDatabase(dbPath, version: 24);
      try {
        final verRows = await db.rawQuery('PRAGMA user_version;');
        expect(verRows.first.values.first, 24);

        final integrity = await db.rawQuery('PRAGMA integrity_check;');
        expect(integrity.first.values.first, 'ok');

        // Table refund_allocations must NOT exist
        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='refund_allocations';",
        );
        expect(tables.isEmpty, isTrue);

        // Column source_record_id must also have rolled back
        final tableInfo = await db.rawQuery("PRAGMA table_info('evidence');");
        final colNames = tableInfo.map((r) => r['name'] as String).toSet();
        expect(colNames.contains('source_record_id'), isFalse);
      } finally {
        await db.close();
      }
    });

    test('S1-04: Failure after baseline table creation rolls back completely to v24', () async {
      final dbPath = await createV24DatabaseFixture(tempDir, 's1_04_fail_base.db');

      // Inject failure after Step 3
      MigrationV25Service.testFailureInjector = (step) {
        if (step == MigrationV25Step.createBaselineTable) {
          throw Exception('INJECTED_FAILURE_AFTER_CREATE_BASELINE_TABLE');
        }
      };

      expect(
        () => upgradeToV25(dbPath),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('INJECTED_FAILURE_AFTER_CREATE_BASELINE_TABLE'))),
      );

      final db = await openDatabase(dbPath, version: 24);
      try {
        final verRows = await db.rawQuery('PRAGMA user_version;');
        expect(verRows.first.values.first, 24);

        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('refund_allocations', 'migration_historical_baselines');",
        );
        expect(tables.isEmpty, isTrue);
      } finally {
        await db.close();
      }
    });

    test('S1-05: Failure after Trigger 3 installation rolls back completely to v24 with zero v25 triggers', () async {
      final dbPath = await createV24DatabaseFixture(tempDir, 's1_05_fail_trg.db');

      // Inject failure after Trigger 3 (midway through trigger installation)
      MigrationV25Service.testFailureInjector = (step) {
        if (step == MigrationV25Step.installTrigger3) {
          throw Exception('INJECTED_FAILURE_AFTER_TRIGGER_3');
        }
      };

      expect(
        () => upgradeToV25(dbPath),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('INJECTED_FAILURE_AFTER_TRIGGER_3'))),
      );

      final db = await openDatabase(dbPath, version: 24);
      try {
        final verRows = await db.rawQuery('PRAGMA user_version;');
        expect(verRows.first.values.first, 24);

        // Zero v25 triggers remain registered
        final v25Triggers = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='trigger' AND name IN ("
          "'trg_refund_allocations_validate_insert', "
          "'trg_refund_allocations_prevent_update', "
          "'trg_refund_allocations_prevent_delete', "
          "'trg_economic_events_prevent_direct_posted_refund', "
          "'trg_economic_events_protect_refunded_parents', "
          "'trg_economic_events_validate_refund_posted'"
          ");",
        );
        expect(v25Triggers.isEmpty, isTrue);

        // Baseline v24 triggers still exist and function
        final v24Triggers = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='trigger' AND name='trg_economic_events_validate_posted';",
        );
        expect(v24Triggers.isNotEmpty, isTrue);
      } finally {
        await db.close();
      }
    });

    test('S1-06: Failure during baseline snapshot insertion rolls back completely to v24', () async {
      final dbPath = await createV24DatabaseFixture(tempDir, 's1_06_fail_snap.db');

      // Inject failure at snapshot insertion
      MigrationV25Service.testFailureInjector = (step) {
        if (step == MigrationV25Step.insertSnapshot) {
          throw Exception('INJECTED_FAILURE_AT_INSERT_SNAPSHOT');
        }
      };

      expect(
        () => upgradeToV25(dbPath),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('INJECTED_FAILURE_AT_INSERT_SNAPSHOT'))),
      );

      final db = await openDatabase(dbPath, version: 24);
      try {
        final verRows = await db.rawQuery('PRAGMA user_version;');
        expect(verRows.first.values.first, 24);

        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='migration_historical_baselines';",
        );
        expect(tables.isEmpty, isTrue);
      } finally {
        await db.close();
      }
    });

    test('S1-07: Retry after a failed migration succeeds idempotently', () async {
      final dbPath = await createV24DatabaseFixture(tempDir, 's1_07_retry.db');

      // 1. First attempt fails at Step 3
      MigrationV25Service.testFailureInjector = (step) {
        if (step == MigrationV25Step.createBaselineTable) {
          throw Exception('INTERRUPTED_CRASH_SIMULATION');
        }
      };

      await expectLater(
        upgradeToV25(dbPath),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('INTERRUPTED_CRASH_SIMULATION'))),
      );

      // 2. Clear failure injector (simulates app restart & clean retry)
      MigrationV25Service.testFailureInjector = null;

      // 3. Retry upgrade
      final db = await upgradeToV25(dbPath, watermarkDate: 1779988776655, watermarkId: 1024);
      try {
        final verRows = await db.rawQuery('PRAGMA user_version;');
        expect(verRows.first.values.first, 25);

        final integrity = await db.rawQuery('PRAGMA integrity_check;');
        expect(integrity.first.values.first, 'ok');

        // Verify clean state
        final baselines = await db.query('migration_historical_baselines');
        expect(baselines.length, 1);
        expect(baselines.first['watermark_snapshot_id'], 1024);

        final events = await db.query(TablesV24.economicEvents);
        expect(events.length, 3);
      } finally {
        await db.close();
      }
    });

    test('S1-08: Opening v25 database using v24 application version rejects downgrade without data loss', () async {
      final dbPath = await createV24DatabaseFixture(tempDir, 's1_08_downgrade.db');

      // 1. Clean upgrade to v25
      final v25Db = await upgradeToV25(dbPath);
      await v25Db.close();

      // 2. Simulate opening with an older v24 application binary
      expect(
        () => openDatabase(
          dbPath,
          version: 24,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON;');
          },
          onUpgrade: (db, oldVersion, newVersion) async {},
          onDowngrade: (db, oldVersion, newVersion) async {
            throw StateError(
              'FATAL: Database schema version ($oldVersion) is newer than application version ($newVersion). '
              'Downgrade is prohibited to prevent data loss. Please update the application.',
            );
          },
        ),
        throwsA(isA<StateError>().having((e) => e.toString(), 'msg', contains('Downgrade is prohibited'))),
      );

      // 3. Re-open at v25 and verify that zero data was dropped, wiped, or corrupted
      final db = await openDatabase(dbPath, version: 25);
      try {
        final verRows = await db.rawQuery('PRAGMA user_version;');
        expect(verRows.first.values.first, 25);

        final integrity = await db.rawQuery('PRAGMA integrity_check;');
        expect(integrity.first.values.first, 'ok');

        final events = await db.query(TablesV24.economicEvents);
        expect(events.length, 3);

        final allocations = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='refund_allocations';",
        );
        expect(allocations.isNotEmpty, isTrue);
      } finally {
        await db.close();
      }
    });
  });
}
