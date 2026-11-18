import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tables_v25.dart';
import 'package:spend_x/data/repositories/refund_allocations_repo.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
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
    tempDir = await Directory.systemTemp.createTemp('spendx_t6_downgrade_test_');
    dbPath = p.join(tempDir.path, 'verification_test.db');

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
      'name': 'HDFC Card',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert(TablesV24.accounts, {
      'id': 'acc_expense_1',
      'account_type': 'expense',
      'subtype': 'general',
      'name': 'Shopping',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    if (db.isOpen) {
      await db.close();
    }
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Trigger 6 Focused Verification Suite', () {
    test('Case 1: Posting a refund without an allocation is rejected with REFUND_POST_VIOLATION', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // Create draft refund event with valid balanced postings
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_ref_no_alloc',
        'event_type': 'refund',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Refund without allocation',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_no_alloc_dr',
        'economic_event_id': 'evt_ref_no_alloc',
        'account_id': 'acc_bank_1',
        'direction': 'debit',
        'amount_minor_units': 25000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_no_alloc_cr',
        'economic_event_id': 'evt_ref_no_alloc',
        'account_id': TablesV24.sysExpRefunds,
        'direction': 'credit',
        'amount_minor_units': 25000,
        'sequence_number': 2,
        'created_at': now,
      });

      // Attempt to post without any row in refund_allocations
      await expectLater(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_ref_no_alloc'],
        ),
        throwsA(predicate((e) =>
            e.toString().contains('REFUND_POST_VIOLATION: posted refund event must have exactly one row in refund_allocations'))),
      );
    });

    test('Case 2: Multiple allocations for a single refund are rejected by schema UNIQUE constraint', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // Parent purchase
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_exp_multi',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Store purchase',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_m_dr',
        'economic_event_id': 'evt_exp_multi',
        'account_id': 'acc_expense_1',
        'direction': 'debit',
        'amount_minor_units': 50000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_m_cr',
        'economic_event_id': 'evt_exp_multi',
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
        whereArgs: ['evt_exp_multi'],
      );

      // Draft refund
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_ref_multi',
        'event_type': 'refund',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Multi-alloc refund',
        'created_at': now,
        'updated_at': now,
      });

      // Insert first allocation (succeeds)
      await db.transaction((txn) async {
        await repo.insertAllocation(
          txn: txn,
          allocation: RefundAllocation(
            id: 'alloc_first',
            refundEventId: 'evt_ref_multi',
            originalEventId: 'evt_exp_multi',
            allocatedAmountMinorUnits: 20000,
            createdAt: DateTime.now().toUtc(),
          ),
        );
      });

      // Attempt to insert second allocation for the SAME refund event
      // (idx_refund_alloc_refund enforces UNIQUE(refund_event_id))
      await expectLater(
        () => db.transaction((txn) async {
          await repo.insertAllocation(
            txn: txn,
            allocation: RefundAllocation(
              id: 'alloc_second',
              refundEventId: 'evt_ref_multi',
              originalEventId: 'evt_exp_multi',
              allocatedAmountMinorUnits: 10000,
              createdAt: DateTime.now().toUtc(),
            ),
          );
        }),
        throwsA(predicate((e) =>
            e.toString().contains('UNIQUE constraint failed: refund_allocations.refund_event_id'))),
      );
    });

    test('Case 2B: Trigger 6 defense-in-depth explicitly rejects refund posting with >1 allocations if index bypassed', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // Parent purchase of ₹500
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_exp_defense',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Defense in depth parent',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_def_dr',
        'economic_event_id': 'evt_exp_defense',
        'account_id': 'acc_expense_1',
        'direction': 'debit',
        'amount_minor_units': 50000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_def_cr',
        'economic_event_id': 'evt_exp_defense',
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
        whereArgs: ['evt_exp_defense'],
      );

      // Draft refund
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_ref_defense',
        'event_type': 'refund',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Defense in depth refund',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_ref_def_dr',
        'economic_event_id': 'evt_ref_defense',
        'account_id': 'acc_bank_1',
        'direction': 'debit',
        'amount_minor_units': 20000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_ref_def_cr',
        'economic_event_id': 'evt_ref_defense',
        'account_id': TablesV24.sysExpRefunds,
        'direction': 'credit',
        'amount_minor_units': 20000,
        'sequence_number': 2,
        'created_at': now,
      });

      // Under controlled test conditions: temporarily drop the UNIQUE indexes to simulate
      // a corrupted or bypassed index state, allowing multiple rows for the same refund_event_id.
      await db.execute('DROP INDEX IF EXISTS idx_refund_alloc_refund;');
      await db.execute('DROP INDEX IF EXISTS idx_refund_alloc_pair;');
      try {
        // Insert two allocation rows for the same draft refund event
        await db.insert(TablesV25.refundAllocations, {
          'id': 'alloc_def_1',
          'refund_event_id': 'evt_ref_defense',
          'original_event_id': 'evt_exp_defense',
          'allocated_amount_minor_units': 10000,
          'created_at': now,
        });
        await db.insert(TablesV25.refundAllocations, {
          'id': 'alloc_def_2',
          'refund_event_id': 'evt_ref_defense',
          'original_event_id': 'evt_exp_defense',
          'allocated_amount_minor_units': 10000,
          'created_at': now,
        });

        // Verify that 2 allocation rows exist for this refund
        final countRows = await db.rawQuery(
          'SELECT COUNT(*) as cnt FROM refund_allocations WHERE refund_event_id = ?',
          ['evt_ref_defense'],
        );
        expect((countRows.first['cnt'] as num).toInt(), 2);

        // Attempting to post the refund MUST be rejected by Trigger 6 (COUNT != 1)
        await expectLater(
          () => db.update(
            TablesV24.economicEvents,
            {'lifecycle_status': 'posted'},
            where: 'id = ?',
            whereArgs: ['evt_ref_defense'],
          ),
          throwsA(predicate((e) =>
              e.toString().contains('REFUND_POST_VIOLATION: posted refund event must have exactly one row in refund_allocations'))),
        );
      } finally {
        // Clean up test rows and restore the UNIQUE indexes and triggers
        await db.execute('DROP TRIGGER IF EXISTS trg_refund_allocations_prevent_delete;');
        await db.delete(TablesV25.refundAllocations, where: 'refund_event_id = ?', whereArgs: ['evt_ref_defense']);
        await db.execute(TablesV25.trgRefundAllocationsPreventDelete);
        await db.execute(TablesV25.createRefundAllocationsRefundIndex);
        await db.execute(TablesV25.createRefundAllocationsPairIndex);
      }
    });

    test('Case 3: Posting without exactly one asset/liability debit is rejected with REFUND_AMBIGUOUS_STRUCTURE', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // Parent purchase
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_exp_struct',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Parent purchase',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_s_dr',
        'economic_event_id': 'evt_exp_struct',
        'account_id': 'acc_expense_1',
        'direction': 'debit',
        'amount_minor_units': 30000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_s_cr',
        'economic_event_id': 'evt_exp_struct',
        'account_id': 'acc_bank_1',
        'direction': 'credit',
        'amount_minor_units': 30000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_exp_struct'],
      );

      // Sub-case A: Zero asset/liability debit postings (e.g. both are contra-expense / equity)
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_ref_zero_dr',
        'event_type': 'refund',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Zero asset debits',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_zdr_1',
        'economic_event_id': 'evt_ref_zero_dr',
        'account_id': 'acc_expense_1', // expense account, NOT asset/liability
        'direction': 'debit',
        'amount_minor_units': 15000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_zcr_1',
        'economic_event_id': 'evt_ref_zero_dr',
        'account_id': TablesV24.sysExpRefunds,
        'direction': 'credit',
        'amount_minor_units': 15000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.transaction((txn) async {
        await repo.insertAllocation(
          txn: txn,
          allocation: RefundAllocation(
            id: 'alloc_zdr',
            refundEventId: 'evt_ref_zero_dr',
            originalEventId: 'evt_exp_struct',
            allocatedAmountMinorUnits: 15000,
            createdAt: DateTime.now().toUtc(),
          ),
        );
      });
      // Attempting to post fails due to zero asset/liability debit
      await expectLater(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_ref_zero_dr'],
        ),
        throwsA(predicate((e) =>
            e.toString().contains('REFUND_AMBIGUOUS_STRUCTURE: refund event must have exactly one asset/liability debit posting'))),
      );

      // Sub-case B: Two asset debit postings (ambiguous split refund)
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_ref_two_dr',
        'event_type': 'refund',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Two asset debits',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_2dr_1',
        'economic_event_id': 'evt_ref_two_dr',
        'account_id': 'acc_bank_1', // asset debit 1
        'direction': 'debit',
        'amount_minor_units': 5000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_2dr_2',
        'economic_event_id': 'evt_ref_two_dr',
        'account_id': 'acc_bank_1', // asset debit 2
        'direction': 'debit',
        'amount_minor_units': 5000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_2cr_1',
        'economic_event_id': 'evt_ref_two_dr',
        'account_id': TablesV24.sysExpRefunds,
        'direction': 'credit',
        'amount_minor_units': 10000,
        'sequence_number': 3,
        'created_at': now,
      });
      await db.transaction((txn) async {
        await repo.insertAllocation(
          txn: txn,
          allocation: RefundAllocation(
            id: 'alloc_2dr',
            refundEventId: 'evt_ref_two_dr',
            originalEventId: 'evt_exp_struct',
            allocatedAmountMinorUnits: 10000,
            createdAt: DateTime.now().toUtc(),
          ),
        );
      });
      // Attempting to post fails due to 2 asset debits
      await expectLater(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_ref_two_dr'],
        ),
        throwsA(predicate((e) =>
            e.toString().contains('REFUND_AMBIGUOUS_STRUCTURE: refund event must have exactly one asset/liability debit posting'))),
      );
    });

    test('Case 4: Posting with an amount mismatch is rejected with REFUND_POST_AMOUNT_MISMATCH', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // Parent purchase of ₹400
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_exp_mismatch',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Parent purchase',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_mm_dr',
        'economic_event_id': 'evt_exp_mismatch',
        'account_id': 'acc_expense_1',
        'direction': 'debit',
        'amount_minor_units': 40000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_exp_mm_cr',
        'economic_event_id': 'evt_exp_mismatch',
        'account_id': 'acc_bank_1',
        'direction': 'credit',
        'amount_minor_units': 40000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_exp_mismatch'],
      );

      // Refund event with debit posting of ₹150 (15000 minor units)
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_ref_mismatch',
        'event_type': 'refund',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Mismatch refund',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_ref_mm_dr',
        'economic_event_id': 'evt_ref_mismatch',
        'account_id': 'acc_bank_1',
        'direction': 'debit',
        'amount_minor_units': 15000, // ₹150
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_ref_mm_cr',
        'economic_event_id': 'evt_ref_mismatch',
        'account_id': TablesV24.sysExpRefunds,
        'direction': 'credit',
        'amount_minor_units': 15000,
        'sequence_number': 2,
        'created_at': now,
      });

      // Allocation has ₹200 (20000 minor units) — mismatch!
      await db.transaction((txn) async {
        await repo.insertAllocation(
          txn: txn,
          allocation: RefundAllocation(
            id: 'alloc_mismatch',
            refundEventId: 'evt_ref_mismatch',
            originalEventId: 'evt_exp_mismatch',
            allocatedAmountMinorUnits: 20000, // ₹200 != ₹150
            createdAt: DateTime.now().toUtc(),
          ),
        );
      });

      // Attempt to post fails with amount mismatch
      await expectLater(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_ref_mismatch'],
        ),
        throwsA(predicate((e) =>
            e.toString().contains('REFUND_POST_AMOUNT_MISMATCH: allocated_amount_minor_units must equal refund debit posting amount'))),
      );
    });

    test('Case 5 & 6: Exceeding cumulative refund cap and restoring a refund that violates the cap', () async {
      final now = DateTime.now().toUtc().toIso8601String();

      // Parent purchase of ₹100 (10000 minor units)
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_exp_restore',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Parent purchase for restore test',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_res_p_dr',
        'economic_event_id': 'evt_exp_restore',
        'account_id': 'acc_expense_1',
        'direction': 'debit',
        'amount_minor_units': 10000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_res_p_cr',
        'economic_event_id': 'evt_exp_restore',
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
        whereArgs: ['evt_exp_restore'],
      );

      // Refund A: ₹60 (6000 minor units) - posted
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_ref_a',
        'event_type': 'refund',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Refund A',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_ra_dr',
        'economic_event_id': 'evt_ref_a',
        'account_id': 'acc_bank_1',
        'direction': 'debit',
        'amount_minor_units': 6000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_ra_cr',
        'economic_event_id': 'evt_ref_a',
        'account_id': TablesV24.sysExpRefunds,
        'direction': 'credit',
        'amount_minor_units': 6000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.transaction((txn) async {
        await repo.insertAllocation(
          txn: txn,
          allocation: RefundAllocation(
            id: 'alloc_a',
            refundEventId: 'evt_ref_a',
            originalEventId: 'evt_exp_restore',
            allocatedAmountMinorUnits: 6000,
            createdAt: DateTime.now().toUtc(),
          ),
        );
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_ref_a'],
      );

      // Now reverse Refund A so its status is 'reversed'
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'reversed'},
        where: 'id = ?',
        whereArgs: ['evt_ref_a'],
      );

      // Refund B: ₹70 (7000 minor units) - inserted and posted while A is reversed (0 + 70 <= 100)
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_ref_b',
        'event_type': 'refund',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Refund B',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_rb_dr',
        'economic_event_id': 'evt_ref_b',
        'account_id': 'acc_bank_1',
        'direction': 'debit',
        'amount_minor_units': 7000,
        'sequence_number': 1,
        'created_at': now,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pst_rb_cr',
        'economic_event_id': 'evt_ref_b',
        'account_id': TablesV24.sysExpRefunds,
        'direction': 'credit',
        'amount_minor_units': 7000,
        'sequence_number': 2,
        'created_at': now,
      });
      await db.transaction((txn) async {
        await repo.insertAllocation(
          txn: txn,
          allocation: RefundAllocation(
            id: 'alloc_b',
            refundEventId: 'evt_ref_b',
            originalEventId: 'evt_exp_restore',
            allocatedAmountMinorUnits: 7000,
            createdAt: DateTime.now().toUtc(),
          ),
        );
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_ref_b'],
      );

      // Case 6: Attempting to RESTORE Refund A back to 'posted' (60 + 70 = 130 > 100)
      // Trigger 6 detects that activating Refund A violates cumulative cap!
      await expectLater(
        () => db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['evt_ref_a'],
        ),
        throwsA(predicate((e) =>
            e.toString().contains('REFUND_RESTORATION_EXCEEDS_CAP: activating refund violates original purchase cumulative cap'))),
      );

      // Verify Refund A remained in reversed state
      final refARows = await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: ['evt_ref_a'],
      );
      expect(refARows.first['lifecycle_status'], 'reversed');
    });
  });

  group('Independent Downgrade Rejection Verification (Plaintext & SQLCipher)', () {
    test('Plaintext open path: rejects downgrade v25 -> v24 with fatal StateError and does not delete DB', () async {
      final plaintextPath = p.join(tempDir.path, 'downgrade_plaintext.db');

      // 1. Create v25 database
      final initDb = await databaseFactory.openDatabase(
        plaintextPath,
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
      await initDb.insert(TablesV24.evidence, {
        'id': 'ev_pt_preserve',
        'source_type': 'sms',
        'extracted_amount_minor_units': 123400,
        'extracted_timestamp': now,
        'body_sha256': 'sha_pt_preserve',
        'source_record_id': 'SRC:TELEPHONY_SMS:1234',
        'created_at': now,
      });
      await initDb.close();

      // 2. Open with version 24 using the production rejection handler
      await expectLater(
        () => databaseFactory.openDatabase(
          plaintextPath,
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

      // 3. Confirm file was NOT deleted
      final file = File(plaintextPath);
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(0));

      // 4. Re-open at v25 and confirm data intact
      final reopenedDb = await databaseFactory.openDatabase(
        plaintextPath,
        options: OpenDatabaseOptions(version: 25),
      );
      final rows = await reopenedDb.query(
        TablesV24.evidence,
        where: 'id = ?',
        whereArgs: ['ev_pt_preserve'],
      );
      expect(rows.length, 1);
      expect(rows.first['source_record_id'], 'SRC:TELEPHONY_SMS:1234');
      await reopenedDb.close();
    });

    test('SQLCipher encrypted open path: rejects downgrade v25 -> v24 with fatal StateError and does not delete DB', () async {
      final cipherPath = p.join(tempDir.path, 'downgrade_cipher.db');
      final rawKey = await SpendXDatabaseKeyManager.instance.getOrCreateKey(
        encryptedDbPath: cipherPath,
      );
      final password = SpendXDatabaseKeyManager.keyToSqlCipherBlob(rawKey);

      // 1. Create encrypted v25 database
      final cipherDb = await databaseFactory.openDatabase(
        cipherPath,
        options: OpenDatabaseOptions(
          version: 25,
          onConfigure: (db) async {
            await db.execute("PRAGMA key = '${password.replaceAll("'", "''")}';");
            await db.execute('PRAGMA cipher_page_size = 4096;');
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
      await cipherDb.insert(TablesV24.evidence, {
        'id': 'ev_cipher_preserve',
        'source_type': 'sms',
        'extracted_amount_minor_units': 567800,
        'extracted_timestamp': now,
        'body_sha256': 'sha_cipher_preserve',
        'source_record_id': 'SRC:TELEPHONY_SMS:5678',
        'created_at': now,
      });
      await cipherDb.close();

      // 2. Open with version 24 using SQLCipher key and rejection handler
      await expectLater(
        () => databaseFactory.openDatabase(
          cipherPath,
          options: OpenDatabaseOptions(
            version: 24,
            onConfigure: (db) async {
              await db.execute("PRAGMA key = '${password.replaceAll("'", "''")}';");
              await db.execute('PRAGMA cipher_page_size = 4096;');
              await db.execute('PRAGMA foreign_keys = ON;');
            },
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

      // 3. Confirm encrypted file was NOT deleted
      final file = File(cipherPath);
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(0));

      // 4. Re-open at v25 with cipher key and confirm data intact
      final reopenedDb = await databaseFactory.openDatabase(
        cipherPath,
        options: OpenDatabaseOptions(
          version: 25,
          onConfigure: (db) async {
            await db.execute("PRAGMA key = '${password.replaceAll("'", "''")}';");
            await db.execute('PRAGMA cipher_page_size = 4096;');
          },
        ),
      );
      final rows = await reopenedDb.query(
        TablesV24.evidence,
        where: 'id = ?',
        whereArgs: ['ev_cipher_preserve'],
      );
      expect(rows.length, 1);
      expect(rows.first['source_record_id'], 'SRC:TELEPHONY_SMS:5678');
      await reopenedDb.close();
    });
  });
}
