import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tables_v25.dart';
import 'package:spend_x/data/repositories/refund_allocations_repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late String dbPath;
  late Database db;
  late RefundAllocationsRepo repo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spendx_stage2_repo_test_');
    dbPath = p.join(tempDir.path, 'stage2_test.db');

    db = await databaseFactory.openDatabase(
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

    repo = RefundAllocationsRepo(executor: db);

    // Seed test accounts
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert(TablesV24.accounts, {
      'id': 'acc_bank_1',
      'account_type': 'asset',
      'subtype': 'savings',
      'name': 'HDFC Bank',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert(TablesV24.accounts, {
      'id': 'acc_card_1',
      'account_type': 'liability',
      'subtype': 'credit_card',
      'name': 'HDFC Regalia',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert(TablesV24.accounts, {
      'id': 'acc_expense_food',
      'account_type': 'expense',
      'subtype': 'food',
      'name': 'Dining Out',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('RefundAllocationsRepo — Mandatory Transaction Injection', () {
    test('writes commit atomically inside caller-provided transaction', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // 1. Create parent expense (₹1000)
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_expense_1',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Amazon electronics',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_1_dr',
        'economic_event_id': 'evt_expense_1',
        'account_id': 'acc_expense_food',
        'direction': 'debit',
        'amount_minor_units': 100000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_1_cr',
        'economic_event_id': 'evt_expense_1',
        'account_id': 'acc_bank_1',
        'direction': 'credit',
        'amount_minor_units': 100000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_expense_1'],
      );

      // 2. Perform atomic refund transaction using txn
      final refundAllocation = RefundAllocation(
        id: 'alloc_1',
        refundEventId: 'evt_refund_1',
        originalEventId: 'evt_expense_1',
        allocatedAmountMinorUnits: 40000,
        createdAt: DateTime.now().toUtc(),
      );

      await db.transaction((txn) async {
        // Draft refund event
        await txn.insert(TablesV24.economicEvents, {
          'id': 'evt_refund_1',
          'event_type': 'refund',
          'lifecycle_status': 'draft',
          'timestamp': now,
          'currency': 'INR',
          'description': 'Partial refund for electronics',
          'created_at': now,
          'updated_at': now,
        });
        // Balanced postings
        await txn.insert(TablesV24.postings, {
          'id': 'pst_ref_1_dr',
          'economic_event_id': 'evt_refund_1',
          'account_id': 'acc_bank_1',
          'direction': 'debit',
          'amount_minor_units': 40000,
          'sequence_number': 1,
          'created_at': now,
        });
        await txn.insert(TablesV24.postings, {
          'id': 'pst_ref_1_cr',
          'economic_event_id': 'evt_refund_1',
          'account_id': TablesV24.sysExpRefunds,
          'direction': 'credit',
          'amount_minor_units': 40000,
          'sequence_number': 2,
          'created_at': now,
        });

        // Insert allocation with mandatory txn parameter
        await repo.insertAllocation(txn: txn, allocation: refundAllocation);

        // Transition refund to posted
        await txn.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_refund_1'],
        );
      });

      // Query via repository
      final fetched = await repo.findByRefundEventId('evt_refund_1');
      expect(fetched, isNotNull);
      expect(fetched!.id, 'alloc_1');
      expect(fetched.refundEventId, 'evt_refund_1');
      expect(fetched.originalEventId, 'evt_expense_1');
      expect(fetched.allocatedAmountMinorUnits, 40000);

      final originalAllocations = await repo.findByOriginalEventId('evt_expense_1');
      expect(originalAllocations.length, 1);
      expect(originalAllocations.first.id, 'alloc_1');

      final cumulative = await repo.getCumulativeAllocatedAmount('evt_expense_1');
      expect(cumulative, 40000);

      final byId = await repo.findById('alloc_1');
      expect(byId, equals(refundAllocation));
    });

    test('aborted transaction rolls back allocation and associated refund', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // Parent purchase
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_expense_2',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Flight tickets',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_2_dr',
        'economic_event_id': 'evt_expense_2',
        'account_id': 'acc_expense_food',
        'direction': 'debit',
        'amount_minor_units': 500000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_2_cr',
        'economic_event_id': 'evt_expense_2',
        'account_id': 'acc_bank_1',
        'direction': 'credit',
        'amount_minor_units': 500000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_expense_2'],
      );

      final failingAllocation = RefundAllocation(
        id: 'alloc_fail',
        refundEventId: 'evt_refund_fail',
        originalEventId: 'evt_expense_2',
        allocatedAmountMinorUnits: 200000,
        createdAt: DateTime.now().toUtc(),
      );

      // Execute transaction that throws
      try {
        await db.transaction((txn) async {
          await txn.insert(TablesV24.economicEvents, {
            'id': 'evt_refund_fail',
            'event_type': 'refund',
            'lifecycle_status': 'draft',
            'timestamp': now,
            'currency': 'INR',
            'description': 'Aborted refund attempt',
            'created_at': now,
            'updated_at': now,
          });
          await repo.insertAllocation(txn: txn, allocation: failingAllocation);
          throw Exception('SIMULATED_TRANSACTION_FAILURE');
        });
      } catch (e) {
        expect(e.toString(), contains('SIMULATED_TRANSACTION_FAILURE'));
      }

      // Assert complete rollback
      final fetched = await repo.findById('alloc_fail');
      expect(fetched, isNull);

      final events = await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: ['evt_refund_fail'],
      );
      expect(events, isEmpty);
    });
  });

  group('RefundAllocationsRepo — SQLite Trigger Enforcements', () {
    test('Trigger 1: Rejects allocation exceeding original purchase amount', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // Parent purchase of ₹500 (50000 minor units)
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_exp_cap',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Books',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_cap_dr',
        'economic_event_id': 'evt_exp_cap',
        'account_id': 'acc_expense_food',
        'direction': 'debit',
        'amount_minor_units': 50000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_cap_cr',
        'economic_event_id': 'evt_exp_cap',
        'account_id': 'acc_bank_1',
        'direction': 'credit',
        'amount_minor_units': 50000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_exp_cap'],
      );

      // Draft refund
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_ref_cap',
        'event_type': 'refund',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Over-cap refund',
        'created_at': now,
        'updated_at': now,
      });

      // Try allocating ₹600 (60000 minor units)
      final overCap = RefundAllocation(
        id: 'alloc_over_cap',
        refundEventId: 'evt_ref_cap',
        originalEventId: 'evt_exp_cap',
        allocatedAmountMinorUnits: 60000,
        createdAt: DateTime.now().toUtc(),
      );

      await expectLater(
        () => db.transaction((txn) async {
          await repo.insertAllocation(txn: txn, allocation: overCap);
        }),
        throwsA(predicate((e) =>
            e.toString().contains('REFUND_ALLOCATION_EXCEEDS_ORIGINAL_AMOUNT'))),
      );
    });

    test('Triggers 2 & 3: Direct UPDATE or DELETE on refund_allocations is prohibited', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // Parent purchase
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_exp_immut',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Hardware',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_immut_dr',
        'economic_event_id': 'evt_exp_immut',
        'account_id': 'acc_expense_food',
        'direction': 'debit',
        'amount_minor_units': 10000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_immut_cr',
        'economic_event_id': 'evt_exp_immut',
        'account_id': 'acc_bank_1',
        'direction': 'credit',
        'amount_minor_units': 10000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_exp_immut'],
      );

      // Draft refund
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_ref_immut',
        'event_type': 'refund',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Immutability test refund',
        'created_at': now,
        'updated_at': now,
      });

      final alloc = RefundAllocation(
        id: 'alloc_immut',
        refundEventId: 'evt_ref_immut',
        originalEventId: 'evt_exp_immut',
        allocatedAmountMinorUnits: 5000,
        createdAt: DateTime.now().toUtc(),
      );

      await db.transaction((txn) async {
        await repo.insertAllocation(txn: txn, allocation: alloc);
      });

      // Trigger 2: UPDATE prohibited
      await expectLater(
        () => db.update(
          TablesV25.refundAllocations,
          {'allocated_amount_minor_units': 6000},
          where: 'id = ?',
          whereArgs: ['alloc_immut'],
        ),
        throwsA(predicate((e) =>
            e.toString().contains('IMMUTABILITY_VIOLATION: refund_allocations rows are strictly immutable.'))),
      );

      // Trigger 3: DELETE prohibited
      await expectLater(
        () => db.delete(
          TablesV25.refundAllocations,
          where: 'id = ?',
          whereArgs: ['alloc_immut'],
        ),
        throwsA(predicate((e) =>
            e.toString().contains('IMMUTABILITY_VIOLATION: direct deletion of refund_allocations is prohibited.'))),
      );
    });

    test('Trigger 4: Direct insertion of already-posted refund is prohibited', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      await expectLater(
        () => db.insert(TablesV24.economicEvents, {
          'id': 'evt_direct_posted_ref',
          'event_type': 'refund',
          'lifecycle_status': 'posted', // Prohibited! Must start as draft.
          'timestamp': now,
          'currency': 'INR',
          'description': 'Illegal direct posted refund',
          'created_at': now,
          'updated_at': now,
        }),
        throwsA(predicate((e) =>
            e.toString().contains('REFUND_INSERT_VIOLATION'))),
      );
    });

    test('Trigger 5: Protects refunded parent from deletion or reversal while refund is active', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // Parent purchase
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_parent_protect',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Protected parent item',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_prot_dr',
        'economic_event_id': 'evt_parent_protect',
        'account_id': 'acc_expense_food',
        'direction': 'debit',
        'amount_minor_units': 8000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_prot_cr',
        'economic_event_id': 'evt_parent_protect',
        'account_id': 'acc_bank_1',
        'direction': 'credit',
        'amount_minor_units': 8000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_parent_protect'],
      );

      // Refund
      await db.transaction((txn) async {
        await txn.insert(TablesV24.economicEvents, {
          'id': 'evt_ref_protect',
          'event_type': 'refund',
          'lifecycle_status': 'draft',
          'timestamp': now,
          'currency': 'INR',
          'description': 'Active refund',
          'created_at': now,
          'updated_at': now,
        });
        await txn.insert(TablesV24.postings, {
          'id': 'pst_ref_p_dr',
          'economic_event_id': 'evt_ref_protect',
          'account_id': 'acc_bank_1',
          'direction': 'debit',
          'amount_minor_units': 8000,
          'sequence_number': 1,
          'created_at': now,
        });
        await txn.insert(TablesV24.postings, {
          'id': 'pst_ref_p_cr',
          'economic_event_id': 'evt_ref_protect',
          'account_id': TablesV24.sysExpRefunds,
          'direction': 'credit',
          'amount_minor_units': 8000,
          'sequence_number': 2,
          'created_at': now,
        });
        await repo.insertAllocation(
          txn: txn,
          allocation: RefundAllocation(
            id: 'alloc_protect',
            refundEventId: 'evt_ref_protect',
            originalEventId: 'evt_parent_protect',
            allocatedAmountMinorUnits: 8000,
            createdAt: DateTime.now().toUtc(),
          ),
        );
        await txn.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_ref_protect'],
        );
      });

      // Try reversing parent while refund is posted -> rejected!
      await expectLater(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'reversed'},
          where: 'id = ?',
          whereArgs: ['evt_parent_protect'],
        ),
        throwsA(predicate((e) =>
            e.toString().contains('CANNOT_REVERSE_PARENT_WITH_ACTIVE_REFUNDS'))),
      );

      // Try mutating parent event_type -> rejected!
      await expectLater(
        () => db.update(
          TablesV24.economicEvents,
          {'event_type': 'income'},
          where: 'id = ?',
          whereArgs: ['evt_parent_protect'],
        ),
        throwsA(predicate((e) =>
            e.toString().contains('REFUND_PARENT_TYPE_VIOLATION'))),
      );
    });
  });
}
