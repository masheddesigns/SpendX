import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tables_v25.dart';
import 'package:spend_x/data/migrations/migration_v25_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spendx_app_db_v25_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('Upgrade path: v24 database upgraded to v25 installs schema and captures baseline', () async {
    final dbPath = p.join(tempDir.path, 'upgrade_v24_to_v25.db');

    // 1. Create a pure v24 database
    final v24Db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 24,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onCreate: (db, version) async {
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
        },
      ),
    );

    // Seed v24 evidence
    final now = DateTime.now().toUtc().toIso8601String();
    await v24Db.insert(TablesV24.evidence, {
      'id': 'ev_v24_1',
      'source_type': 'sms',
      'extracted_amount_minor_units': 150000,
      'extracted_timestamp': now,
      'body_sha256': 'sha_v24_1',
      'created_at': now,
    });
    await v24Db.close();

    // 2. Open at version 25 invoking MigrationV25Service directly in onUpgrade
    final v25Db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 25,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 25) {
            await MigrationV25Service.run(db);
          }
        },
      ),
    );

    // 3. Verify user_version is 25
    final verResult = await v25Db.rawQuery('PRAGMA user_version;');
    final version = (verResult.first.values.first as num).toInt();
    expect(version, 25);

    // 4. Verify source_record_id column exists
    final cols = await v25Db.rawQuery('PRAGMA table_info(evidence);');
    expect(cols.any((c) => c['name'] == 'source_record_id'), isTrue);

    // 5. Verify refund_allocations table exists
    final tables = await v25Db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='${TablesV25.refundAllocations}';",
    );
    expect(tables.isNotEmpty, isTrue);

    // 6. Verify migration_historical_baselines contains the V25_BASELINE
    final baselines = await v25Db.query(TablesV25.migrationHistoricalBaselines);
    expect(baselines.length, 1);
    expect(baselines.first['id'], 'V25_BASELINE');
    expect(baselines.first['migration_version'], 25);

    // 7. Verify pre-existing v24 evidence record is intact
    final evidenceRows = await v25Db.query(
      TablesV24.evidence,
      where: 'id = ?',
      whereArgs: ['ev_v24_1'],
    );
    expect(evidenceRows.length, 1);
    expect(evidenceRows.first['extracted_amount_minor_units'], 150000);
    expect(evidenceRows.first['source_record_id'], isNull);

    // 8. Verify source_record_id can be updated and uniqueness is enforced
    await v25Db.update(
      TablesV24.evidence,
      {'source_record_id': 'SRC:TELEPHONY_SMS:1001'},
      where: 'id = ?',
      whereArgs: ['ev_v24_1'],
    );

    await v25Db.insert(TablesV24.evidence, {
      'id': 'ev_v25_2',
      'source_type': 'sms',
      'extracted_amount_minor_units': 200000,
      'extracted_timestamp': now,
      'body_sha256': 'sha_v25_2',
      'source_record_id': 'SRC:TELEPHONY_SMS:1002',
      'created_at': now,
    });

    // Uniqueness violation
    await expectLater(
      () => v25Db.insert(TablesV24.evidence, {
        'id': 'ev_v25_duplicate',
        'source_type': 'sms',
        'extracted_amount_minor_units': 300000,
        'extracted_timestamp': now,
        'body_sha256': 'sha_v25_dup',
        'source_record_id': 'SRC:TELEPHONY_SMS:1001', // Duplicate!
        'created_at': now,
      }),
      throwsA(anything),
    );

    await v25Db.close();
  });

  test('Fresh-install bootstrap: creates V25 schema with ZERO historical baseline rows', () async {
    final dbPath = p.join(tempDir.path, 'fresh_install_v25.db');

    // Bootstrap fresh install
    final freshDb = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 25,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onCreate: (db, version) async {
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
          await TablesV25.createAllV25(db);
          await TablesV25.installTriggers(db);
        },
      ),
    );

    // 1. Verify user_version is 25
    final verResult = await freshDb.rawQuery('PRAGMA user_version;');
    final version = (verResult.first.values.first as num).toInt();
    expect(version, 25);

    // 2. Verify V25 tables exist
    final tables = await freshDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('${TablesV25.refundAllocations}', '${TablesV25.migrationHistoricalBaselines}');",
    );
    expect(tables.length, 2);

    // 3. Verify V25 triggers exist (6 triggers)
    final triggers = await freshDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg_%';",
    );
    final triggerNames = triggers.map((t) => t['name'] as String).toSet();
    expect(triggerNames.contains('trg_refund_allocations_validate_insert'), isTrue);
    expect(triggerNames.contains('trg_refund_allocations_prevent_update'), isTrue);
    expect(triggerNames.contains('trg_refund_allocations_prevent_delete'), isTrue);
    expect(triggerNames.contains('trg_economic_events_prevent_direct_posted_refund'), isTrue);
    expect(triggerNames.contains('trg_economic_events_protect_refunded_parents'), isTrue);
    expect(triggerNames.contains('trg_economic_events_validate_refund_posted'), isTrue);

    // 4. Requirement 2: Verify migration_historical_baselines has ZERO rows
    final baselines = await freshDb.query(TablesV25.migrationHistoricalBaselines);
    expect(baselines, isEmpty);

    await freshDb.close();
  });

  test('Downgrade rejection: opening v25 database with v24 throws fatal StateError and preserves data', () async {
    final dbPath = p.join(tempDir.path, 'downgrade_test.db');

    // 1. Create v25 database with data
    final v25Db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 25,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onCreate: (db, version) async {
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
          await TablesV25.createAllV25(db);
          await TablesV25.installTriggers(db);
        },
      ),
    );
    final now = DateTime.now().toUtc().toIso8601String();
    await v25Db.insert(TablesV24.evidence, {
      'id': 'ev_preserve',
      'source_type': 'sms',
      'extracted_amount_minor_units': 999900,
      'extracted_timestamp': now,
      'body_sha256': 'sha_preserve',
      'source_record_id': 'SRC:TELEPHONY_SMS:9999',
      'created_at': now,
    });
    await v25Db.close();

    // 2. Attempt opening with version 24 using rejection callback
    await expectLater(
      () => databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 24,
          onDowngrade: (db, oldVersion, newVersion) async {
            throw StateError(
              'FATAL: Database schema version ($oldVersion) is newer than application '
              'version ($newVersion). Downgrade is prohibited to prevent data loss. '
              'Please update the application.',
            );
          },
        ),
      ),
      throwsA(predicate((e) =>
          e is StateError &&
          e.message.contains('FATAL: Database schema version (25) is newer than application version (24)'))),
    );

    // 3. Re-open at v25 and confirm data was not wiped or corrupted
    final reopenDb = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 25,
      ),
    );
    final rows = await reopenDb.query(
      TablesV24.evidence,
      where: 'id = ?',
      whereArgs: ['ev_preserve'],
    );
    expect(rows.length, 1);
    expect(rows.first['extracted_amount_minor_units'], 999900);
    expect(rows.first['source_record_id'], 'SRC:TELEPHONY_SMS:9999');

    await reopenDb.close();
  });
}
