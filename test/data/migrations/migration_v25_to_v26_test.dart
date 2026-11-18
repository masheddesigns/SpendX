import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tables_v25.dart';
import 'package:spend_x/data/core/tables_v26.dart';
import 'package:spend_x/data/migrations/migration_v26_service.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    MigrationV26Service.setTestFailurePoint(null);
    tempDir = await Directory.systemTemp.createTemp('spendx_migration_v26_test_');
  });

  tearDown(() async {
    MigrationV26Service.setTestFailurePoint(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  // Helper to create a base v25 test database
  Future<Database> createV25TestDb(String dbPath) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 25,
        onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON;'),
        onCreate: (db, version) async {
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
          await TablesV25.createAllV25(db);
          await TablesV25.installTriggers(db);
        },
      ),
    );

    // Seed dummy economic event
    await db.insert(TablesV24.economicEvents, {
      'id': 'evt_test_base',
      'event_type': 'expense',
      'lifecycle_status': 'draft',
      'timestamp': now,
      'currency': 'INR',
      'description': 'Base test event',
      'created_at': now,
      'updated_at': now,
    });

    return db;
  }

  group('Group 1: Reciprocal Marker Integrity & Conflict Validation', () {
    test('1. Valid reciprocal pair: migrates successfully into evidence_reconciliations and clears markers', () async {
      final dbPath = p.join(tempDir.path, 'valid_reciprocal.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Seed valid reciprocal pair
      await db.insert(TablesV24.evidence, {
        'id': 'ev_bcast_1',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:101',
        'extracted_amount_minor_units': 50000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:101',
        'body_sha256': 'sha_101_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_inbox_1',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:101',
        'extracted_amount_minor_units': 50000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:101',
        'body_sha256': 'sha_101_i',
        'created_at': now,
      });

      // Run migration inside transaction
      await db.transaction((txn) async {
        await MigrationV26Service.run(txn);
      });

      // Verify relationship is durably inserted
      final recs = await db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 1);
      expect(recs.first['broadcast_source_record_id'], 'SRC:BCAST:101');
      expect(recs.first['inbox_source_record_id'], 'SRC:INBOX:101');
      expect(recs.first['reconciliation_method'], 'MIGRATED_FROM_EXTERNAL_REFERENCE_V25');

      // Verify markers were safely cleared to NULL
      final bcastEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_bcast_1']);
      expect(bcastEv.first['external_reference'], isNull);

      final inboxEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_inbox_1']);
      expect(inboxEv.first['external_reference'], isNull);

      await db.close();
    });

    test('2. TO marker without FROM marker: fails transactionally, preserves markers, retry succeeds after fix', () async {
      final dbPath = p.join(tempDir.path, 'to_without_from.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Broadcast has RECONCILED_TO, but inbox evidence exists with external_reference NULL
      await db.insert(TablesV24.evidence, {
        'id': 'ev_bcast_orphan_to',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:102',
        'extracted_amount_minor_units': 50000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:102',
        'body_sha256': 'sha_102_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_inbox_no_marker',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:102',
        'extracted_amount_minor_units': 50000,
        'extracted_timestamp': now,
        'external_reference': null, // Missing reciprocal FROM marker!
        'body_sha256': 'sha_102_i',
        'created_at': now,
      });

      expect(
        () async {
          await db.transaction((txn) async {
            await MigrationV26Service.run(txn);
          });
        },
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Reciprocal marker mismatch'),
            contains('expected "RECONCILED_FROM:SRC:BCAST:102"'),
          ),
        )),
      );

      // Verify transaction rollback: table does not exist, markers intact
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='${TablesV26.evidenceReconciliations}';",
      );
      expect(tables.isEmpty, isTrue);

      final bcastEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_bcast_orphan_to']);
      expect(bcastEv.first['external_reference'], 'RECONCILED_TO:SRC:INBOX:102');

      // Retry: Fix the counterpart and re-run migration
      await db.update(
        TablesV24.evidence,
        {'external_reference': 'RECONCILED_FROM:SRC:BCAST:102'},
        where: 'id = ?',
        whereArgs: ['ev_inbox_no_marker'],
      );

      await db.transaction((txn) async {
        await MigrationV26Service.run(txn);
      });

      final recs = await db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 1);
      final bcastEvAfter = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_bcast_orphan_to']);
      expect(bcastEvAfter.first['external_reference'], isNull);

      await db.close();
    });

    test('3. FROM marker without TO marker: fails transactionally, preserves markers, retry succeeds after fix', () async {
      final dbPath = p.join(tempDir.path, 'from_without_to.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Broadcast exists with NULL external_reference, but inbox has RECONCILED_FROM
      await db.insert(TablesV24.evidence, {
        'id': 'ev_bcast_no_marker',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:103',
        'extracted_amount_minor_units': 30000,
        'extracted_timestamp': now,
        'external_reference': null, // Missing reciprocal TO marker!
        'body_sha256': 'sha_103_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_inbox_orphan_from',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:103',
        'extracted_amount_minor_units': 30000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:103',
        'body_sha256': 'sha_103_i',
        'created_at': now,
      });

      expect(
        () async {
          await db.transaction((txn) async {
            await MigrationV26Service.run(txn);
          });
        },
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Reciprocal marker mismatch'),
            contains('expected "RECONCILED_TO:SRC:INBOX:103"'),
          ),
        )),
      );

      // Verify rollback: no table, marker preserved
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='${TablesV26.evidenceReconciliations}';",
      );
      expect(tables.isEmpty, isTrue);

      final inboxEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_inbox_orphan_from']);
      expect(inboxEv.first['external_reference'], 'RECONCILED_FROM:SRC:BCAST:103');

      // Retry: Fix the broadcast evidence and re-run
      await db.update(
        TablesV24.evidence,
        {'external_reference': 'RECONCILED_TO:SRC:INBOX:103'},
        where: 'id = ?',
        whereArgs: ['ev_bcast_no_marker'],
      );

      await db.transaction((txn) async {
        await MigrationV26Service.run(txn);
      });

      final recs = await db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 1);
      final inboxEvAfter = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_inbox_orphan_from']);
      expect(inboxEvAfter.first['external_reference'], isNull);

      await db.close();
    });

    test('4. Reciprocal markers pointing to different identities: fails transactionally, preserves data', () async {
      final dbPath = p.join(tempDir.path, 'asymmetric_identities.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Broadcast B1 points to I1, but I1 points to B2!
      await db.insert(TablesV24.evidence, {
        'id': 'ev_bcast_mismatch',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:104_A',
        'extracted_amount_minor_units': 40000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:104',
        'body_sha256': 'sha_104_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_inbox_mismatch',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:104',
        'extracted_amount_minor_units': 40000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:104_DIFFERENT', // Contradiction!
        'body_sha256': 'sha_104_i',
        'created_at': now,
      });

      expect(
        () async {
          await db.transaction((txn) async {
            await MigrationV26Service.run(txn);
          });
        },
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Reciprocal marker mismatch'),
        )),
      );

      // Verify rollback: markers unchanged
      final bcastEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_bcast_mismatch']);
      expect(bcastEv.first['external_reference'], 'RECONCILED_TO:SRC:INBOX:104');
      final inboxEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_inbox_mismatch']);
      expect(inboxEv.first['external_reference'], 'RECONCILED_FROM:SRC:BCAST:104_DIFFERENT');

      await db.close();
    });

    test('5. Missing referenced evidence: fails transactionally and preserves data', () async {
      final dbPath = p.join(tempDir.path, 'missing_counterpart.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Broadcast points to an inbox identity that does not exist anywhere in evidence
      await db.insert(TablesV24.evidence, {
        'id': 'ev_dangling_bcast',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:105',
        'extracted_amount_minor_units': 25000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:NON_EXISTENT_ID',
        'body_sha256': 'sha_105',
        'created_at': now,
      });

      expect(
        () async {
          await db.transaction((txn) async {
            await MigrationV26Service.run(txn);
          });
        },
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Missing referenced inbox evidence "SRC:INBOX:NON_EXISTENT_ID"'),
        )),
      );

      // Verify rollback: marker unchanged
      final ev = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_dangling_bcast']);
      expect(ev.first['external_reference'], 'RECONCILED_TO:SRC:INBOX:NON_EXISTENT_ID');

      await db.close();
    });

    test('6. Contradictory marker relationship with existing reconciliation: fails transactionally', () async {
      final dbPath = p.join(tempDir.path, 'contradictory_relationship.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Pre-create TablesV26 with relationship: BCAST:301 -> INBOX:301
      await TablesV26.createAllV26(db);
      await db.insert(TablesV26.evidenceReconciliations, {
        'id': 'rec_existing_bcast',
        'broadcast_source_record_id': 'SRC:BCAST:301',
        'inbox_source_record_id': 'SRC:INBOX:301',
        'reconciliation_method': 'PRE_EXISTING',
        'created_at': now,
      });

      // Reciprocal pair between BCAST:301 and INBOX:999 (contradicts BCAST:301 -> INBOX:301!)
      await db.insert(TablesV24.evidence, {
        'id': 'ev_conflict_bcast',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:301',
        'extracted_amount_minor_units': 30000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:999',
        'body_sha256': 'sha_conflict_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_conflict_inbox',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:999',
        'extracted_amount_minor_units': 30000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:301',
        'body_sha256': 'sha_conflict_i',
        'created_at': now,
      });

      // Must throw descriptive StateError inside transaction
      expect(
        () async {
          await db.transaction((txn) async {
            await MigrationV26Service.run(txn);
          });
        },
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Migration v26 conflict: Broadcast identity "SRC:BCAST:301"'),
            contains('already belongs to different inbox identity "SRC:INBOX:301"'),
          ),
        )),
      );

      // Verify markers were NOT cleared
      final bEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_conflict_bcast']);
      expect(bEv.first['external_reference'], 'RECONCILED_TO:SRC:INBOX:999');
      final iEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_conflict_inbox']);
      expect(iEv.first['external_reference'], 'RECONCILED_FROM:SRC:BCAST:301');

      await db.close();
    });

    test('7. Dual conflict: both identities conflict with distinct existing relationships: fails safely', () async {
      final dbPath = p.join(tempDir.path, 'dual_conflict.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Pre-create TablesV26 with 2 existing relationships:
      // Pair 1: BCAST:501 -> INBOX:501
      // Pair 2: BCAST:502 -> INBOX:502
      await TablesV26.createAllV26(db);
      await db.insert(TablesV26.evidenceReconciliations, {
        'id': 'rec_pair_1',
        'broadcast_source_record_id': 'SRC:BCAST:501',
        'inbox_source_record_id': 'SRC:INBOX:501',
        'reconciliation_method': 'PRE_EXISTING',
        'created_at': now,
      });
      await db.insert(TablesV26.evidenceReconciliations, {
        'id': 'rec_pair_2',
        'broadcast_source_record_id': 'SRC:BCAST:502',
        'inbox_source_record_id': 'SRC:INBOX:502',
        'reconciliation_method': 'PRE_EXISTING',
        'created_at': now,
      });

      // Reciprocal pair between BCAST:501 and INBOX:502 (both conflict with different existing records!)
      await db.insert(TablesV24.evidence, {
        'id': 'ev_dual_bcast',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:501',
        'extracted_amount_minor_units': 50000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:502',
        'body_sha256': 'sha_dual_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_dual_inbox',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:502',
        'extracted_amount_minor_units': 50000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:501',
        'body_sha256': 'sha_dual_i',
        'created_at': now,
      });

      expect(
        () async {
          await db.transaction((txn) async {
            await MigrationV26Service.run(txn);
          });
        },
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Dual identity conflict in evidence "ev_dual_bcast"'),
        )),
      );

      // Verify all data preserved and markers untouched
      final bEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_dual_bcast']);
      expect(bEv.first['external_reference'], 'RECONCILED_TO:SRC:INBOX:502');
      final iEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_dual_inbox']);
      expect(iEv.first['external_reference'], 'RECONCILED_FROM:SRC:BCAST:501');

      final recs = await db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 2);

      await db.close();
    });

    test('8. Existing exact reconciliation plus matching legacy markers: remains idempotent and clears markers', () async {
      final dbPath = p.join(tempDir.path, 'exact_exists.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Pre-create TablesV26 and pre-insert the exact relationship
      await TablesV26.createAllV26(db);
      await db.insert(TablesV26.evidenceReconciliations, {
        'id': 'rec_pre_existing',
        'broadcast_source_record_id': 'SRC:BCAST:201',
        'inbox_source_record_id': 'SRC:INBOX:201',
        'reconciliation_method': 'PRE_EXISTING',
        'created_at': now,
      });

      // Evidence still holds markers pointing to that exact relationship
      await db.insert(TablesV24.evidence, {
        'id': 'ev_bcast_2',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:201',
        'extracted_amount_minor_units': 20000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:201',
        'body_sha256': 'sha_201_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_inbox_2',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:201',
        'extracted_amount_minor_units': 20000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:201',
        'body_sha256': 'sha_201_i',
        'created_at': now,
      });

      // Run migration
      await db.transaction((txn) async {
        await MigrationV26Service.run(txn);
      });

      // Verifications: still exactly 1 reconciliation record (no duplicates)
      final recs = await db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 1);
      expect(recs.first['id'], 'rec_pre_existing');

      // Both markers safely cleared
      final bcastEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_bcast_2']);
      expect(bcastEv.first['external_reference'], isNull);

      final inboxEv = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_inbox_2']);
      expect(inboxEv.first['external_reference'], isNull);

      await db.close();
    });

    test('9. Malformed or incomplete legacy markers: fails transaction without discarding', () async {
      final dbPath = p.join(tempDir.path, 'malformed_markers.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // 9a: empty inbox in RECONCILED_TO:
      await db.insert(TablesV24.evidence, {
        'id': 'ev_malformed_9a',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:601',
        'extracted_amount_minor_units': 1000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:   ',
        'body_sha256': 'sha_9a',
        'created_at': now,
      });

      expect(
        () async {
          await db.transaction((txn) async {
            await MigrationV26Service.run(txn);
          });
        },
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Malformed or incomplete RECONCILED_TO marker'),
        )),
      );

      await db.delete(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_malformed_9a']);

      // 9b: empty broadcast in RECONCILED_FROM:
      await db.insert(TablesV24.evidence, {
        'id': 'ev_malformed_9b',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:602',
        'extracted_amount_minor_units': 1000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:',
        'body_sha256': 'sha_9b',
        'created_at': now,
      });

      expect(
        () async {
          await db.transaction((txn) async {
            await MigrationV26Service.run(txn);
          });
        },
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Malformed or incomplete RECONCILED_FROM marker'),
        )),
      );

      await db.delete(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_malformed_9b']);

      // 9c: missing source_record_id
      await db.insert(TablesV24.evidence, {
        'id': 'ev_malformed_9c',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': '',
        'extracted_amount_minor_units': 1000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:603',
        'body_sha256': 'sha_9c',
        'created_at': now,
      });

      expect(
        () async {
          await db.transaction((txn) async {
            await MigrationV26Service.run(txn);
          });
        },
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('missing or empty source_record_id'),
        )),
      );

      await db.delete(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_malformed_9c']);

      // 9d: unrecognized RECONCILED_ prefix
      await db.insert(TablesV24.evidence, {
        'id': 'ev_malformed_9d',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:604',
        'extracted_amount_minor_units': 1000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_UNKNOWN_TAG:FOO',
        'body_sha256': 'sha_9d',
        'created_at': now,
      });

      expect(
        () async {
          await db.transaction((txn) async {
            await MigrationV26Service.run(txn);
          });
        },
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Unrecognized or malformed reconciliation marker'),
        )),
      );

      // Verify marker was not silently cleared
      final ev = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_malformed_9d']);
      expect(ev.first['external_reference'], 'RECONCILED_UNKNOWN_TAG:FOO');

      await db.close();
    });
  });

  group('Group 2: Complete Migration Chain through Application DB Upgrade Mechanism', () {
    test('Chain 1: v24 -> v25 -> v26 via AppDatabase.migrateSchemaOnly in onUpgrade', () async {
      final dbPath = p.join(tempDir.path, 'chain1_v24_v26.db');
      final now = DateTime.now().toUtc().toIso8601String();

      // Create v24 DB
      final v24Db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 24,
          onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON;'),
          onCreate: (db, version) async {
            await TablesV24.createAllV24(db);
            await TablesV24.seedSystemAccounts(db);
            await TablesV24.installTriggers(db);
          },
        ),
      );

      // Seed v24 economic event & evidence with genuine reference
      await v24Db.insert(TablesV24.economicEvents, {
        'id': 'evt_v24',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'v24 payment',
        'created_at': now,
        'updated_at': now,
      });

      await v24Db.insert(TablesV24.evidence, {
        'id': 'ev_v24_genuine',
        'economic_event_id': 'evt_v24',
        'source_type': 'sms',
        'extracted_amount_minor_units': 150000,
        'extracted_timestamp': now,
        'external_reference': 'UPI:RRN:242424242424',
        'body_sha256': 'sha_v24',
        'created_at': now,
      });

      await v24Db.close();

      // Upgrade directly to 26 using AppDatabase.instance.migrateSchemaOnly in onUpgrade
      final upgradedDb = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 26,
          onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON;'),
          onUpgrade: (db, oldVersion, newVersion) async {
            await AppDatabase.instance.migrateSchemaOnly(db, oldVersion);
          },
        ),
      );

      // 1. Verify user_version is 26
      final verRows = await upgradedDb.rawQuery('PRAGMA user_version;');
      final ver = (verRows.first.values.first as num).toInt();
      expect(ver, 26);

      // 2. Verify v25 tables exist (refund_allocations, migration_historical_baselines)
      final tables = (await upgradedDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table';",
      )).map((r) => r['name'] as String).toSet();

      expect(tables.contains(TablesV25.refundAllocations), isTrue);
      expect(tables.contains(TablesV25.migrationHistoricalBaselines), isTrue);

      // 3. Verify v26 table exists (evidence_reconciliations)
      expect(tables.contains(TablesV26.evidenceReconciliations), isTrue);

      // 4. Verify evidence preserved with genuine reference and added source_record_id column
      final evRows = await upgradedDb.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_v24_genuine']);
      expect(evRows.length, 1);
      expect(evRows.first['external_reference'], 'UPI:RRN:242424242424');

      await upgradedDb.close();
    });

    test('Chain 2: v25 -> v26 with reciprocal legacy reconciliation markers and genuine UTR/RRN references', () async {
      final dbPath = p.join(tempDir.path, 'chain2_v25_v26.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Seed genuine UTR
      await db.insert(TablesV24.evidence, {
        'id': 'ev_gen_utr',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:UTR1',
        'extracted_amount_minor_units': 50000,
        'extracted_timestamp': now,
        'external_reference': 'UPI:RRN:999888777666',
        'body_sha256': 'sha_utr',
        'created_at': now,
      });

      // Seed valid reciprocal pair
      await db.insert(TablesV24.evidence, {
        'id': 'ev_b_pair',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:PAIR1',
        'extracted_amount_minor_units': 75000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:PAIR1',
        'body_sha256': 'sha_b_pair',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_i_pair',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:PAIR1',
        'extracted_amount_minor_units': 75000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:PAIR1',
        'body_sha256': 'sha_i_pair',
        'created_at': now,
      });

      await db.close();

      // Open at version 26 using AppDatabase.instance.migrateSchemaOnly
      final v26Db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 26,
          onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON;'),
          onUpgrade: (db, oldVersion, newVersion) async {
            await AppDatabase.instance.migrateSchemaOnly(db, oldVersion);
          },
        ),
      );

      final ver = (await v26Db.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(ver, 26);

      // Verify reconciliation inserted
      final recs = await v26Db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 1);
      expect(recs.first['broadcast_source_record_id'], 'SRC:BCAST:PAIR1');
      expect(recs.first['inbox_source_record_id'], 'SRC:INBOX:PAIR1');

      // Verify markers cleared
      final bEv = await v26Db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_b_pair']);
      expect(bEv.first['external_reference'], isNull);

      final iEv = await v26Db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_i_pair']);
      expect(iEv.first['external_reference'], isNull);

      // Verify genuine UTR intact
      final utrEv = await v26Db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_gen_utr']);
      expect(utrEv.first['external_reference'], 'UPI:RRN:999888777666');

      await v26Db.close();
    });

    test('Chain 3: Fresh database creation directly at v26 via AppDatabase.onCreateForTesting', () async {
      final dbPath = p.join(tempDir.path, 'chain3_fresh_v26.db');

      final freshDb = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 26,
          onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON;'),
          onCreate: (db, version) async {
            await AppDatabase.instance.onCreateForTesting(db, version);
          },
        ),
      );

      final ver = (await freshDb.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(ver, 26);

      // Check all canonical tables present
      final tables = (await freshDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table';",
      )).map((r) => r['name'] as String).toSet();

      expect(tables.contains(TablesV24.accounts), isTrue);
      expect(tables.contains(TablesV24.economicEvents), isTrue);
      expect(tables.contains(TablesV24.evidence), isTrue);
      expect(tables.contains(TablesV25.refundAllocations), isTrue);
      expect(tables.contains(TablesV26.evidenceReconciliations), isTrue);

      await freshDb.close();
    });

    test('Chain 4: SQLCipher-backed upgrade path using isolated test key and database', () async {
      final dbPath = p.join(tempDir.path, 'chain4_sqlcipher_upgrade.db');
      final now = DateTime.now().toUtc().toIso8601String();

      // Provision isolated test key and SQLCipher blob
      final mockStorage = InMemorySecureStorageAdapter();
      final keyManager = SpendXDatabaseKeyManager(storageAdapter: mockStorage);
      final testKey = await keyManager.getOrCreateKey(encryptedDbPath: dbPath);
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(testKey);

      // 1. Create encrypted v25 database with SQLCipher password
      final encV25Db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
        version: 25,
        bypassPrimaryGuard: true,
        onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON;'),
        onCreate: (db, version) async {
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
          await TablesV25.createAllV25(db);
          await TablesV25.installTriggers(db);
        },
      );

      // Verify SQLCipher is actively running
      final cipherVer = await encV25Db.rawQuery('PRAGMA cipher_version;');
      expect(cipherVer.isNotEmpty, isTrue);

      // Seed genuine UTR and valid reciprocal pair
      await encV25Db.insert(TablesV24.economicEvents, {
        'id': 'evt_enc',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Encrypted payment',
        'created_at': now,
        'updated_at': now,
      });

      await encV25Db.insert(TablesV24.evidence, {
        'id': 'ev_enc_utr',
        'economic_event_id': 'evt_enc',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:ENC1',
        'extracted_amount_minor_units': 12000,
        'extracted_timestamp': now,
        'external_reference': 'UPI:RRN:ENC123456789',
        'body_sha256': 'sha_enc_utr',
        'created_at': now,
      });

      await encV25Db.insert(TablesV24.evidence, {
        'id': 'ev_enc_bcast',
        'economic_event_id': 'evt_enc',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:ENC_REC',
        'extracted_amount_minor_units': 15000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:ENC_REC',
        'body_sha256': 'sha_enc_b',
        'created_at': now,
      });

      await encV25Db.insert(TablesV24.evidence, {
        'id': 'ev_enc_inbox',
        'economic_event_id': 'evt_enc',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:ENC_REC',
        'extracted_amount_minor_units': 15000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:ENC_REC',
        'body_sha256': 'sha_enc_i',
        'created_at': now,
      });

      await encV25Db.close();

      // 2. Re-open encrypted database targeting version 26 using AppDatabase.migrateSchemaOnly
      final encV26Db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
        version: 26,
        bypassPrimaryGuard: true,
        onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON;'),
        onUpgrade: (db, oldVersion, newVersion) async {
          await AppDatabase.instance.migrateSchemaOnly(db, oldVersion);
        },
      );

      final ver = (await encV26Db.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(ver, 26);

      // Verify relationship created
      final recs = await encV26Db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 1);
      expect(recs.first['broadcast_source_record_id'], 'SRC:BCAST:ENC_REC');
      expect(recs.first['inbox_source_record_id'], 'SRC:INBOX:ENC_REC');

      // Verify markers cleared
      final bEv = await encV26Db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_enc_bcast']);
      expect(bEv.first['external_reference'], isNull);

      // Verify genuine reference preserved
      final utrEv = await encV26Db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_enc_utr']);
      expect(utrEv.first['external_reference'], 'UPI:RRN:ENC123456789');

      await encV26Db.close();
    });
  });

  group('Group 3: Transactional Failure Injection and Retry', () {
    test('Checkpoint 1: Injected failure after table creation rolls back completely and retry succeeds', () async {
      final dbPath = p.join(tempDir.path, 'fail_after_table_creation.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Seed reciprocal pair
      await db.insert(TablesV24.evidence, {
        'id': 'ev_fail_1_b',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:F1',
        'extracted_amount_minor_units': 1000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:F1',
        'body_sha256': 'sha_f1_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_fail_1_i',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:F1',
        'extracted_amount_minor_units': 1000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:F1',
        'body_sha256': 'sha_f1_i',
        'created_at': now,
      });

      // Inject failure after table creation
      MigrationV26Service.setTestFailurePoint(MigrationV26FailurePoint.afterTableCreation);

      var failed = false;
      try {
        await db.transaction((txn) async {
          await MigrationV26Service.run(txn);
        });
      } catch (_) {
        failed = true;
      }
      expect(failed, isTrue);

      // Verify rollback: evidence_reconciliations must NOT exist
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='${TablesV26.evidenceReconciliations}';",
      );
      expect(tables.isEmpty, isTrue);

      // Verify markers were NOT cleared
      final evB = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_1_b']);
      expect(evB.first['external_reference'], 'RECONCILED_TO:SRC:INBOX:F1');
      final evI = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_1_i']);
      expect(evI.first['external_reference'], 'RECONCILED_FROM:SRC:BCAST:F1');

      // Clear failure and retry
      MigrationV26Service.setTestFailurePoint(null);
      await db.transaction((txn) async {
        await MigrationV26Service.run(txn);
      });

      // Retry succeeded
      final recs = await db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 1);
      final evBAfter = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_1_b']);
      expect(evBAfter.first['external_reference'], isNull);
      final evIAfter = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_1_i']);
      expect(evIAfter.first['external_reference'], isNull);

      await db.close();
    });

    test('Checkpoint 2: Injected failure during legacy relationship insertion rolls back and retry succeeds', () async {
      final dbPath = p.join(tempDir.path, 'fail_during_insertion.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      await db.insert(TablesV24.evidence, {
        'id': 'ev_fail_2_b',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:F2',
        'extracted_amount_minor_units': 2000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:F2',
        'body_sha256': 'sha_f2_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_fail_2_i',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:F2',
        'extracted_amount_minor_units': 2000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:F2',
        'body_sha256': 'sha_f2_i',
        'created_at': now,
      });

      // Inject failure during legacy insertion
      MigrationV26Service.setTestFailurePoint(MigrationV26FailurePoint.duringLegacyInsertion);

      var failed = false;
      try {
        await db.transaction((txn) async {
          await MigrationV26Service.run(txn);
        });
      } catch (_) {
        failed = true;
      }
      expect(failed, isTrue);

      // Verify rollback: table does not exist
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='${TablesV26.evidenceReconciliations}';",
      );
      expect(tables.isEmpty, isTrue);

      // Markers intact
      final evB = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_2_b']);
      expect(evB.first['external_reference'], 'RECONCILED_TO:SRC:INBOX:F2');

      // Retry
      MigrationV26Service.setTestFailurePoint(null);
      await db.transaction((txn) async {
        await MigrationV26Service.run(txn);
      });

      final recs = await db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 1);
      final evBAfter = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_2_b']);
      expect(evBAfter.first['external_reference'], isNull);

      await db.close();
    });

    test('Checkpoint 3: Injected failure after partial relationship insertion rolls back completely and retry succeeds', () async {
      final dbPath = p.join(tempDir.path, 'fail_after_partial.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Seed 2 distinct reciprocal pairs
      await db.insert(TablesV24.evidence, {
        'id': 'ev_fail_p1_b',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:P1',
        'extracted_amount_minor_units': 3000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:P1',
        'body_sha256': 'sha_p1_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_fail_p1_i',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:P1',
        'extracted_amount_minor_units': 3000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:P1',
        'body_sha256': 'sha_p1_i',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_fail_p2_b',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:P2',
        'extracted_amount_minor_units': 4000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:P2',
        'body_sha256': 'sha_p2_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_fail_p2_i',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:P2',
        'extracted_amount_minor_units': 4000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:P2',
        'body_sha256': 'sha_p2_i',
        'created_at': now,
      });

      // Inject failure after partial insertion
      MigrationV26Service.setTestFailurePoint(MigrationV26FailurePoint.afterPartialInsertion);

      var failed = false;
      try {
        await db.transaction((txn) async {
          await MigrationV26Service.run(txn);
        });
      } catch (_) {
        failed = true;
      }
      expect(failed, isTrue);

      // Verify rollback: table does not exist, zero partial insertions preserved
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='${TablesV26.evidenceReconciliations}';",
      );
      expect(tables.isEmpty, isTrue);

      // All markers intact
      final ev1B = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_p1_b']);
      expect(ev1B.first['external_reference'], 'RECONCILED_TO:SRC:INBOX:P1');
      final ev2B = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_p2_b']);
      expect(ev2B.first['external_reference'], 'RECONCILED_TO:SRC:INBOX:P2');

      // Retry
      MigrationV26Service.setTestFailurePoint(null);
      await db.transaction((txn) async {
        await MigrationV26Service.run(txn);
      });

      final recs = await db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 2);

      final ev1BAfter = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_p1_b']);
      expect(ev1BAfter.first['external_reference'], isNull);
      final ev2BAfter = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_p2_b']);
      expect(ev2BAfter.first['external_reference'], isNull);

      await db.close();
    });

    test('Checkpoint 4: Injected failure during marker cleanup rolls back completely and retry succeeds', () async {
      final dbPath = p.join(tempDir.path, 'fail_during_cleanup.db');
      final db = await createV25TestDb(dbPath);
      final now = DateTime.now().toUtc().toIso8601String();

      await db.insert(TablesV24.evidence, {
        'id': 'ev_fail_4_b',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:BCAST:F4',
        'extracted_amount_minor_units': 5000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_TO:SRC:INBOX:F4',
        'body_sha256': 'sha_f4_b',
        'created_at': now,
      });

      await db.insert(TablesV24.evidence, {
        'id': 'ev_fail_4_i',
        'economic_event_id': 'evt_test_base',
        'source_type': 'sms',
        'source_record_id': 'SRC:INBOX:F4',
        'extracted_amount_minor_units': 5000,
        'extracted_timestamp': now,
        'external_reference': 'RECONCILED_FROM:SRC:BCAST:F4',
        'body_sha256': 'sha_f4_i',
        'created_at': now,
      });

      // Inject failure during marker cleanup
      MigrationV26Service.setTestFailurePoint(MigrationV26FailurePoint.duringMarkerCleanup);

      var failed = false;
      try {
        await db.transaction((txn) async {
          await MigrationV26Service.run(txn);
        });
      } catch (_) {
        failed = true;
      }
      expect(failed, isTrue);

      // Verify rollback: table does not exist
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='${TablesV26.evidenceReconciliations}';",
      );
      expect(tables.isEmpty, isTrue);

      // Markers intact
      final evB = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_4_b']);
      expect(evB.first['external_reference'], 'RECONCILED_TO:SRC:INBOX:F4');

      // Retry
      MigrationV26Service.setTestFailurePoint(null);
      await db.transaction((txn) async {
        await MigrationV26Service.run(txn);
      });

      final recs = await db.query(TablesV26.evidenceReconciliations);
      expect(recs.length, 1);
      final evBAfter = await db.query(TablesV24.evidence, where: 'id = ?', whereArgs: ['ev_fail_4_b']);
      expect(evBAfter.first['external_reference'], isNull);

      await db.close();
    });
  });

  group('Group 4: Failure Injection Security & Production Guard', () {
    test('MigrationV26Service.setTestFailurePoint is strictly test-only and guarded against production activation', () {
      // In test environment, setting failure point is permitted:
      MigrationV26Service.setTestFailurePoint(MigrationV26FailurePoint.afterTableCreation);
      expect(MigrationV26Service.testFailurePoint, MigrationV26FailurePoint.afterTableCreation);

      // Reset
      MigrationV26Service.setTestFailurePoint(null);
      expect(MigrationV26Service.testFailurePoint, isNull);
    });
  });

  group('Group 5: Downgrade Rejection', () {
    test('Downgrade rejection: opening a v26 database with application targeting v25 is fatally rejected', () async {
      final dbPath = p.join(tempDir.path, 'downgrade_v26_test.db');

      // 1. Create a v26 database
      final v26Db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 26,
          onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON;'),
          onCreate: (db, version) async {
            await TablesV24.createAllV24(db);
            await TablesV25.createAllV25(db);
            await TablesV26.createAllV26(db);
          },
        ),
      );
      await v26Db.close();

      // 2. Attempt opening with version 25 (downgrade)
      await expectLater(
        databaseFactory.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 25,
            onDowngrade: (db, oldVersion, newVersion) async {
              throw StateError(
                'FATAL: Database schema version ($oldVersion) is newer than application '
                'version ($newVersion). Downgrade is prohibited to prevent data loss. '
                'Please update the application.',
              );
            },
          ),
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('FATAL: Database schema version (26) is newer than application version (25)'),
        )),
      );

      // 3. Confirm file was not deleted
      final file = File(dbPath);
      expect(await file.exists(), isTrue);
    });
  });
}
