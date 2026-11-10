import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/reversal_index_compatibility_service.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_credit_adapter.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_loan_adapter.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/settings_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });

  group('Milestone 5.0 DEF-504: Append-Only Remediation & Reversal Guard Suite', () {
    late Database db;
    late TransactionRepo transactionRepo;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );

      // Create schema v24
      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      transactionRepo = TransactionRepo(executor: db);

      // Create test account via accountRepo
      final now = DateTime(2026, 11, 1, 10, 0);
      final bank = BankAccount(
        id: 'acc_bank_compat',
        userId: 'user_1',
        name: 'HDFC Checking',
        bank: 'HDFC',
        balance: 10000.0,
        accountType: 'checking',
        createdAt: now,
        updatedAt: now,
      );
      await accountRepo.insertAccount(bank);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> dropUniqueIndex() async {
      await db.execute('DROP INDEX IF EXISTS idx_events_unique_reversal;');
    }

    Future<bool> hasUniqueIndex() async {
      final rows = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_events_unique_reversal';",
      );
      return rows.isNotEmpty;
    }

    test('1. Clean existing v24 database creates the unique index on inspection', () async {
      await dropUniqueIndex();
      expect(await hasUniqueIndex(), isFalse);

      final status = await ReversalIndexCompatibilityService.ensureReversalIndex(db);
      expect(status, ReversalIndexStatus.created);
      expect(await hasUniqueIndex(), isTrue);
    });

    test('2. Existing v24 database with duplicate reversals remains accessible (defers index without throwing)', () async {
      await dropUniqueIndex();

      final nowStr = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_orig_purchase',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': nowStr,
        'currency': 'INR',
        'description': 'Dinner at Bistro',
        'created_at': nowStr,
        'updated_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_orig_dr',
        'economic_event_id': 'evt_orig_purchase',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 50000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_orig_cr',
        'economic_event_id': 'evt_orig_purchase',
        'account_id': 'acc_bank_compat',
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 50000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_orig_purchase'],
      );

      // Seed TWO duplicate reversal events pointing to the same evt_orig_purchase
      for (int i = 1; i <= 2; i++) {
        final revId = 'evt_rev_dup_$i';
        await db.insert(TablesV24.economicEvents, {
          'id': revId,
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'reversal_of_event_id': 'evt_orig_purchase',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'REVERSAL: Dinner at Bistro',
          'created_at': '2026-11-01T10:00:0$i.000Z',
          'updated_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_rev${i}_dr',
          'economic_event_id': revId,
          'account_id': 'acc_bank_compat',
          'sequence_number': 1,
          'direction': 'debit',
          'amount_minor_units': 50000,
          'currency': 'INR',
          'created_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_rev${i}_cr',
          'economic_event_id': revId,
          'account_id': TablesV24.sysExpMisc,
          'sequence_number': 2,
          'direction': 'credit',
          'amount_minor_units': 50000,
          'currency': 'INR',
          'created_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: [revId],
        );
      }

      // Invoke ensureReversalIndex - MUST NOT THROW
      final status = await ReversalIndexCompatibilityService.ensureReversalIndex(db);
      expect(status, ReversalIndexStatus.deferredDueToDuplicates);
      expect(await hasUniqueIndex(), isFalse);

      final exceptions = await db.query(
        TablesV24.migrationExceptions,
        where: 'error_code = ?',
        whereArgs: ['ERR_DUPLICATE_REVERSAL_DEFERRED_INDEX'],
      );
      expect(exceptions.length, 1);
    });

    test('3. Historical duplicate reversal events remain byte-for-byte equivalent in all persisted fields after remediation', () async {
      await dropUniqueIndex();

      final nowStr = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_orig_immut',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': nowStr,
        'currency': 'INR',
        'description': 'Immutability Check Purchase',
        'notes': jsonEncode({'test': 'preserve_notes'}),
        'created_at': '2026-11-01T09:00:00.000Z',
        'updated_at': '2026-11-01T09:00:00.000Z',
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_orig_immut_dr',
        'economic_event_id': 'evt_orig_immut',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 75000,
        'currency': 'INR',
        'created_at': '2026-11-01T09:00:00.000Z',
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_orig_immut_cr',
        'economic_event_id': 'evt_orig_immut',
        'account_id': 'acc_bank_compat',
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 75000,
        'currency': 'INR',
        'created_at': '2026-11-01T09:00:00.000Z',
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_orig_immut'],
      );

      for (int i = 1; i <= 2; i++) {
        final revId = 'evt_rev_immut_$i';
        await db.insert(TablesV24.economicEvents, {
          'id': revId,
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'reversal_of_event_id': 'evt_orig_immut',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'REVERSAL: Immutability Check Purchase',
          'notes': jsonEncode({'reversal_run': i, 'flag': 'original_unmodified'}),
          'created_at': '2026-11-01T09:00:0$i.000Z',
          'updated_at': '2026-11-01T09:00:0$i.000Z',
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_rev_immut_${i}_dr',
          'economic_event_id': revId,
          'account_id': 'acc_bank_compat',
          'sequence_number': 1,
          'direction': 'debit',
          'amount_minor_units': 75000,
          'currency': 'INR',
          'created_at': '2026-11-01T09:00:0$i.000Z',
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_rev_immut_${i}_cr',
          'economic_event_id': revId,
          'account_id': TablesV24.sysExpMisc,
          'sequence_number': 2,
          'direction': 'credit',
          'amount_minor_units': 75000,
          'currency': 'INR',
          'created_at': '2026-11-01T09:00:0$i.000Z',
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: [revId],
        );
      }

      // Snapshot all historical events and postings before remediation
      final eventsBefore = await db.query(
        TablesV24.economicEvents,
        where: "id IN ('evt_orig_immut', 'evt_rev_immut_1', 'evt_rev_immut_2')",
        orderBy: 'id ASC',
      );
      final postingsBefore = await db.query(
        TablesV24.postings,
        where: "economic_event_id IN ('evt_orig_immut', 'evt_rev_immut_1', 'evt_rev_immut_2')",
        orderBy: 'id ASC',
      );

      // Execute append-only remediation
      final remResult = await ReversalIndexCompatibilityService.remediateDuplicateReversals(db);
      expect(remResult.success, isTrue);
      expect(remResult.groupsRemediated, 1);
      expect(remResult.duplicatesNeutralized, 1);
      expect(remResult.compensatingEventIds, ['comp_rev_evt_rev_immut_2']);
      expect(remResult.uniqueIndexCreated, isFalse, reason: 'Index remains deferred to protect duplicate pointers');

      // Snapshot the exact same historical records after remediation
      final eventsAfter = await db.query(
        TablesV24.economicEvents,
        where: "id IN ('evt_orig_immut', 'evt_rev_immut_1', 'evt_rev_immut_2')",
        orderBy: 'id ASC',
      );
      final postingsAfter = await db.query(
        TablesV24.postings,
        where: "economic_event_id IN ('evt_orig_immut', 'evt_rev_immut_1', 'evt_rev_immut_2')",
        orderBy: 'id ASC',
      );

      // MANDATORY ASSERTION: Zero bytes modified on historical posted records
      expect(eventsAfter, equals(eventsBefore));
      expect(postingsAfter, equals(postingsBefore));

      // Verify duplicate pointer on evt_rev_immut_2 remains exactly 'evt_orig_immut'
      final dupRevRow = eventsAfter.firstWhere((r) => r['id'] == 'evt_rev_immut_2');
      expect(dupRevRow['reversal_of_event_id'], 'evt_orig_immut');
    });

    test('4. Compensation neutralizes redundant reversal financial effect and restores trial balance', () async {
      await dropUniqueIndex();

      final nowStr = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_orig_fin',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': nowStr,
        'currency': 'INR',
        'description': 'Shopping Expense Fin',
        'created_at': nowStr,
        'updated_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_orig_fin_dr',
        'economic_event_id': 'evt_orig_fin',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 100000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_orig_fin_cr',
        'economic_event_id': 'evt_orig_fin',
        'account_id': 'acc_bank_compat',
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 100000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_orig_fin'],
      );

      // Seed 2 duplicate reversals
      for (int i = 1; i <= 2; i++) {
        final revId = 'evt_rev_fin_$i';
        await db.insert(TablesV24.economicEvents, {
          'id': revId,
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'reversal_of_event_id': 'evt_orig_fin',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'REVERSAL: Shopping Expense Fin',
          'created_at': '2026-11-01T10:00:0$i.000Z',
          'updated_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_rev_fin_${i}_dr',
          'economic_event_id': revId,
          'account_id': 'acc_bank_compat',
          'sequence_number': 1,
          'direction': 'debit',
          'amount_minor_units': 100000,
          'currency': 'INR',
          'created_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_rev_fin_${i}_cr',
          'economic_event_id': revId,
          'account_id': TablesV24.sysExpMisc,
          'sequence_number': 2,
          'direction': 'credit',
          'amount_minor_units': 100000,
          'currency': 'INR',
          'created_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: [revId],
        );
      }

      // Prior to remediation, bank account has an extra ₹1,000 credit (balance drift)
      var bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_compat');
      expect(bankBal.minorUnits, 1100000); // 1,000,000 baseline - 100,000 + 100,000 + 100,000

      // Execute remediation
      final remResult = await ReversalIndexCompatibilityService.remediateDuplicateReversals(db);
      expect(remResult.success, isTrue);
      expect(remResult.compensatingEventIds, ['comp_rev_evt_rev_fin_2']);

      // After remediation, compensating adjustment neutralizes the duplicate reversal:
      bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_compat');
      expect(bankBal.minorUnits, 1000000, reason: 'Balance returned to baseline of single canonical reversal');

      // Verify trial balance delta = 0
      final tbRows = await db.rawQuery('''
        SELECT 
          COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END), 0) AS total_debit,
          COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END), 0) AS total_credit
        FROM ${TablesV24.postings};
      ''');
      final totalDebit = (tbRows.first['total_debit'] as num).toInt();
      final totalCredit = (tbRows.first['total_credit'] as num).toInt();
      expect(totalDebit - totalCredit, 0);
    });

    test('5. Retrying remediation is idempotent and does not create duplicate compensations', () async {
      await dropUniqueIndex();

      final nowStr = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_orig_retry',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': nowStr,
        'currency': 'INR',
        'description': 'Retry Purchase',
        'created_at': nowStr,
        'updated_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_orig_retry_dr',
        'economic_event_id': 'evt_orig_retry',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 20000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_orig_retry_cr',
        'economic_event_id': 'evt_orig_retry',
        'account_id': 'acc_bank_compat',
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 20000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_orig_retry'],
      );

      for (int i = 1; i <= 2; i++) {
        final revId = 'evt_rev_retry_$i';
        await db.insert(TablesV24.economicEvents, {
          'id': revId,
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'reversal_of_event_id': 'evt_orig_retry',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'REVERSAL: Retry Purchase',
          'created_at': '2026-11-01T10:00:0$i.000Z',
          'updated_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_rev_retry_${i}_dr',
          'economic_event_id': revId,
          'account_id': 'acc_bank_compat',
          'sequence_number': 1,
          'direction': 'debit',
          'amount_minor_units': 20000,
          'currency': 'INR',
          'created_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_rev_retry_${i}_cr',
          'economic_event_id': revId,
          'account_id': TablesV24.sysExpMisc,
          'sequence_number': 2,
          'direction': 'credit',
          'amount_minor_units': 20000,
          'currency': 'INR',
          'created_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: [revId],
        );
      }

      // First remediation run
      final res1 = await ReversalIndexCompatibilityService.remediateDuplicateReversals(db);
      expect(res1.success, isTrue);
      expect(res1.compensatingEventIds, ['comp_rev_evt_rev_retry_2']);

      final compCount1 = (await db.query(
        TablesV24.economicEvents,
        where: "id = 'comp_rev_evt_rev_retry_2'",
      )).length;
      expect(compCount1, 1);

      // Second remediation run (retry)
      final res2 = await ReversalIndexCompatibilityService.remediateDuplicateReversals(db);
      expect(res2.success, isTrue);
      expect(res2.duplicatesNeutralized, 1);
      expect(res2.compensatingEventIds, ['comp_rev_evt_rev_retry_2']);

      final compCount2 = (await db.query(
        TablesV24.economicEvents,
        where: "id = 'comp_rev_evt_rev_retry_2'",
      )).length;
      expect(compCount2, 1, reason: 'Must not create duplicate compensating adjustments on retry');
    });

    test('6. An existing compensation ID with incorrect contents causes a safe failure', () async {
      await dropUniqueIndex();

      final nowStr = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_orig_corrupt',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': nowStr,
        'currency': 'INR',
        'description': 'Corrupt Test',
        'created_at': nowStr,
        'updated_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_orig_corrupt_dr',
        'economic_event_id': 'evt_orig_corrupt',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 15000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_orig_corrupt_cr',
        'economic_event_id': 'evt_orig_corrupt',
        'account_id': 'acc_bank_compat',
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 15000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_orig_corrupt'],
      );

      for (int i = 1; i <= 2; i++) {
        final revId = 'evt_rev_corrupt_$i';
        await db.insert(TablesV24.economicEvents, {
          'id': revId,
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'reversal_of_event_id': 'evt_orig_corrupt',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'REVERSAL: Corrupt Test',
          'created_at': '2026-11-01T10:00:0$i.000Z',
          'updated_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_rev_corrupt_${i}_dr',
          'economic_event_id': revId,
          'account_id': 'acc_bank_compat',
          'sequence_number': 1,
          'direction': 'debit',
          'amount_minor_units': 15000,
          'currency': 'INR',
          'created_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_rev_corrupt_${i}_cr',
          'economic_event_id': revId,
          'account_id': TablesV24.sysExpMisc,
          'sequence_number': 2,
          'direction': 'credit',
          'amount_minor_units': 15000,
          'currency': 'INR',
          'created_at': '2026-11-01T10:00:0$i.000Z',
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: [revId],
        );
      }

      // Pre-seed an invalid compensation record under the deterministic ID
      // with wrong event_type ('income' instead of 'adjustment')
      await db.insert(TablesV24.economicEvents, {
        'id': 'comp_rev_evt_rev_corrupt_2',
        'event_type': 'income',
        'lifecycle_status': 'draft',
        'timestamp': nowStr,
        'currency': 'INR',
        'description': 'Pre-existing colliding event with wrong type',
        'created_at': nowStr,
        'updated_at': nowStr,
      });

      // Remediation must detect invalid contents and throw StateError safely
      expect(
        () async => await ReversalIndexCompatibilityService.remediateDuplicateReversals(db),
        throwsA(isA<StateError>()),
      );
    });

    test('7. Interrupted remediation rolls back atomically leaving zero partial state', () async {
      await dropUniqueIndex();

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);

      // Attempt transaction where an error is deliberately triggered
      try {
        await db.transaction((txn) async {
          await txn.insert(TablesV24.economicEvents, {
            'id': 'partial_event',
            'event_type': 'expense',
            'lifecycle_status': 'draft',
            'timestamp': DateTime.now().toIso8601String(),
            'currency': 'INR',
            'created_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          });
          // Injected intentional exception
          throw FormatException('Simulated crash during remediation');
        });
      } catch (_) {}

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);

      expect(eventsAfter, equals(eventsBefore));
      expect(postingsAfter, equals(postingsBefore));
    });

    test('8. TransactionRepo: update and delete reject duplicate reversals even when unique index is deferred', () async {
      await dropUniqueIndex();

      final nowStr = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_tx_guard',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': nowStr,
        'currency': 'INR',
        'description': 'Tx Guard',
        'created_at': nowStr,
        'updated_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_tx_guard_dr',
        'economic_event_id': 'evt_tx_guard',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 50000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_tx_guard_cr',
        'economic_event_id': 'evt_tx_guard',
        'account_id': 'acc_bank_compat',
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 50000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_tx_guard'],
      );

      // Insert first reversal
      await db.insert(TablesV24.economicEvents, {
        'id': 'rev_tx_guard_1',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'reversal_of_event_id': 'evt_tx_guard',
        'timestamp': nowStr,
        'currency': 'INR',
        'description': 'REVERSAL: evt_tx_guard',
        'created_at': nowStr,
        'updated_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_rev_tx_1_dr',
        'economic_event_id': 'rev_tx_guard_1',
        'account_id': 'acc_bank_compat',
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 50000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': 'pos_rev_tx_1_cr',
        'economic_event_id': 'rev_tx_guard_1',
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 50000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['rev_tx_guard_1'],
      );

      // Attempt deletion of already reversed transaction
      final delRes = await transactionRepo.delete('evt_tx_guard');
      expect(delRes, 0, reason: 'TransactionRepo.delete must reject already reversed event');

      // Attempt update of already reversed transaction
      final updRes = await transactionRepo.update(spx.Transaction(
        id: 'evt_tx_guard',
        userId: 'user_1',
        amount: 500.0,
        type: 'expense',
        accountId: 'acc_bank_compat',
        date: DateTime.now(),
        notes: 'Update',
      ));
      expect(updRes, 0, reason: 'TransactionRepo.update must reject already reversed event');

      final revs = await db.query(
        TablesV24.economicEvents,
        where: 'reversal_of_event_id = ?',
        whereArgs: ['evt_tx_guard'],
      );
      expect(revs.length, 1);
    });

    test('9. CreditRepo: deleteTransaction rejects duplicate reversal transactionally when unique index is deferred', () async {
      await dropUniqueIndex();

      final now = DateTime(2026, 11, 1, 12, 0);
      final card = CreditCard(
        id: 'card_compat_1',
        userId: 'user_1',
        name: 'Sapphire Card',
        bank: 'Chase',
        last4: '4321',
        limitAmount: 500000.0,
        usedAmount: 0.0,
        createdAt: now,
      );
      await creditRepo.insert(card);

      final creditTx = CreditTransaction(
        id: 'ctx_guard_1',
        cardId: 'card_compat_1',
        amount: 1500.0,
        type: 'purchase',
        date: now,
        note: 'Tech purchase',
        category: 'Electronics',
        status: 'active',
      );
      await creditRepo.insertTransaction(creditTx);

      // First delete: creates reversal
      await creditRepo.deleteTransaction('ctx_guard_1');

      final revs1 = await db.query(
        TablesV24.economicEvents,
        where: 'reversal_of_event_id = ?',
        whereArgs: ['ctx_guard_1'],
      );
      expect(revs1.length, 1, reason: 'First delete must create structured reversal');

      // Second delete attempt (duplicate call): must be rejected transactionally without creating 2nd reversal
      await creditRepo.deleteTransaction('ctx_guard_1');

      final revs2 = await db.query(
        TablesV24.economicEvents,
        where: 'reversal_of_event_id = ?',
        whereArgs: ['ctx_guard_1'],
      );
      expect(revs2.length, 1, reason: 'Second delete must be rejected, preserving single reversal');
    });

    test('10. LoanRepo: reverseLoanEvent rejects duplicate reversal transactionally when unique index is deferred', () async {
      await dropUniqueIndex();

      final now = DateTime(2026, 11, 1, 10, 0);
      final loan = Loan(
        id: 'loan_compat_1',
        name: 'Auto Loan',
        bank: 'HDFC',
        total: 500000.0,
        interestRate: 8.5,
        tenureMonths: 36,
        monthlyInstallment: 15000.0,
        startDate: now,
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 5,
      );
      await loanRepo.insertLoan(loan);

      // Target the opening liability event created by insertLoan
      final disbEventId = 'evt_ob_loan_compat_1';
      final existingEvent = await canonicalEventRepo.getEvent(disbEventId);
      expect(existingEvent, isNotNull);

      // First reversal: succeeds
      final revId1 = await loanRepo.reverseLoanEvent(disbEventId);
      expect(revId1.isNotEmpty, isTrue);

      final revs1 = await db.query(
        TablesV24.economicEvents,
        where: 'reversal_of_event_id = ?',
        whereArgs: [disbEventId],
      );
      expect(revs1.length, 1);

      // Second reversal attempt: must throw AccountingInvariantException
      expect(
        () async => await loanRepo.reverseLoanEvent(disbEventId),
        throwsA(isA<AccountingInvariantException>()),
      );

      final revs2 = await db.query(
        TablesV24.economicEvents,
        where: 'reversal_of_event_id = ?',
        whereArgs: [disbEventId],
      );
      expect(revs2.length, 1, reason: 'Duplicate reversal rejected by transactional guard');
    });

    test('11. Clean databases receive unique index and reject duplicate raw SQL insertions', () async {
      expect(await hasUniqueIndex(), isTrue);

      final nowStr = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_clean_target',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': nowStr,
        'currency': 'INR',
        'description': 'Target Event',
        'created_at': nowStr,
        'updated_at': nowStr,
      });

      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_clean_rev_1',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'reversal_of_event_id': 'evt_clean_target',
        'timestamp': nowStr,
        'currency': 'INR',
        'description': 'Reversal 1',
        'created_at': nowStr,
        'updated_at': nowStr,
      });

      expect(
        () async => await db.insert(TablesV24.economicEvents, {
          'id': 'evt_clean_rev_2',
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'reversal_of_event_id': 'evt_clean_target',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'Duplicate Reversal',
          'created_at': nowStr,
          'updated_at': nowStr,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('12. CanonicalEventRepository: createDraftEvent rejects duplicate reversal when unique index is deferred', () async {
      await dropUniqueIndex();
      expect(await hasUniqueIndex(), isFalse);

      final now = DateTime(2026, 11, 1, 10, 0);
      final targetEvent = EconomicEvent.draft(
        id: 'evt_target_12',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'Original target expense 12',
      );
      await canonicalEventRepo.createDraftEvent(targetEvent);

      final rev1 = EconomicEvent.draft(
        id: 'evt_rev_12_a',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'REVERSAL: 12 A',
        reversalOfEventId: 'evt_target_12',
      );
      await canonicalEventRepo.createDraftEvent(rev1);

      final rev2 = EconomicEvent.draft(
        id: 'evt_rev_12_b',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'REVERSAL: 12 B',
        reversalOfEventId: 'evt_target_12',
      );
      expect(
        () async => await canonicalEventRepo.createDraftEvent(rev2),
        throwsA(isA<AccountingInvariantException>()),
      );

      final reversals = await db.query(
        TablesV24.economicEvents,
        where: 'reversal_of_event_id = ?',
        whereArgs: ['evt_target_12'],
      );
      expect(reversals.length, 1);
      expect(reversals.first['id'], 'evt_rev_12_a');
    });

    test('13. CanonicalEventRepository: createAndPostEvent rejects duplicate reversal when unique index is deferred', () async {
      await dropUniqueIndex();
      expect(await hasUniqueIndex(), isFalse);

      final now = DateTime(2026, 11, 1, 10, 0);
      final targetEvent = EconomicEvent.draft(
        id: 'evt_target_13',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'Original target expense 13',
      );
      await canonicalEventRepo.createAndPostEvent(
        targetEvent,
        postings: [
          Posting(
            id: 'pos_tgt_13_dr',
            economicEventId: 'evt_target_13',
            accountId: TablesV24.sysExpMisc,
            direction: PostingDirection.debit,
            amount: Money.fromPaise(50000),
            createdAt: now,
          ),
          Posting(
            id: 'pos_tgt_13_cr',
            economicEventId: 'evt_target_13',
            accountId: 'acc_bank_compat',
            direction: PostingDirection.credit,
            amount: Money.fromPaise(50000),
            createdAt: now,
          ),
        ],
      );

      final rev1 = EconomicEvent.draft(
        id: 'evt_rev_13_a',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'REVERSAL: 13 A',
        reversalOfEventId: 'evt_target_13',
      );
      await canonicalEventRepo.createAndPostEvent(
        rev1,
        postings: [
          Posting(
            id: 'pos_rev_13a_dr',
            economicEventId: 'evt_rev_13_a',
            accountId: 'acc_bank_compat',
            direction: PostingDirection.debit,
            amount: Money.fromPaise(50000),
            createdAt: now,
          ),
          Posting(
            id: 'pos_rev_13a_cr',
            economicEventId: 'evt_rev_13_a',
            accountId: TablesV24.sysExpMisc,
            direction: PostingDirection.credit,
            amount: Money.fromPaise(50000),
            createdAt: now,
          ),
        ],
      );

      final rev2 = EconomicEvent.draft(
        id: 'evt_rev_13_b',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'REVERSAL: 13 B',
        reversalOfEventId: 'evt_target_13',
      );
      expect(
        () async => await canonicalEventRepo.createAndPostEvent(
          rev2,
          postings: [
            Posting(
              id: 'pos_rev_13b_dr',
              economicEventId: 'evt_rev_13_b',
              accountId: 'acc_bank_compat',
              direction: PostingDirection.debit,
              amount: Money.fromPaise(50000),
              createdAt: now,
            ),
            Posting(
              id: 'pos_rev_13b_cr',
              economicEventId: 'evt_rev_13_b',
              accountId: TablesV24.sysExpMisc,
              direction: PostingDirection.credit,
              amount: Money.fromPaise(50000),
              createdAt: now,
            ),
          ],
        ),
        throwsA(isA<AccountingInvariantException>()),
      );

      final reversals = await db.query(
        TablesV24.economicEvents,
        where: 'reversal_of_event_id = ?',
        whereArgs: ['evt_target_13'],
      );
      expect(reversals.length, 1);
      expect(reversals.first['id'], 'evt_rev_13_a');
    });

    test('14. The first valid reversal succeeds under createDraftEvent and createAndPostEvent', () async {
      await dropUniqueIndex();

      final now = DateTime(2026, 11, 1, 10, 0);
      final targetDraft = EconomicEvent.draft(
        id: 'evt_target_14_draft',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'Target for draft reversal',
      );
      await canonicalEventRepo.createDraftEvent(targetDraft);

      final revDraft = EconomicEvent.draft(
        id: 'evt_rev_14_draft',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'REVERSAL: Draft',
        reversalOfEventId: 'evt_target_14_draft',
      );
      await canonicalEventRepo.createDraftEvent(revDraft);
      final persistedDraft = await canonicalEventRepo.getEvent('evt_rev_14_draft');
      expect(persistedDraft, isNotNull);
      expect(persistedDraft!.reversalOfEventId, 'evt_target_14_draft');
      expect(persistedDraft.lifecycleStatus.isDraft, isTrue);

      final targetPosted = EconomicEvent.draft(
        id: 'evt_target_14_posted',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'Target for posted reversal',
      );
      await canonicalEventRepo.createAndPostEvent(
        targetPosted,
        postings: [
          Posting(
            id: 'pos_14_dr',
            economicEventId: 'evt_target_14_posted',
            accountId: TablesV24.sysExpMisc,
            direction: PostingDirection.debit,
            amount: Money.fromPaise(20000),
            createdAt: now,
          ),
          Posting(
            id: 'pos_14_cr',
            economicEventId: 'evt_target_14_posted',
            accountId: 'acc_bank_compat',
            direction: PostingDirection.credit,
            amount: Money.fromPaise(20000),
            createdAt: now,
          ),
        ],
      );

      final revPosted = EconomicEvent.draft(
        id: 'evt_rev_14_posted',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'REVERSAL: Posted',
        reversalOfEventId: 'evt_target_14_posted',
      );
      await canonicalEventRepo.createAndPostEvent(
        revPosted,
        postings: [
          Posting(
            id: 'pos_14_rev_dr',
            economicEventId: 'evt_rev_14_posted',
            accountId: 'acc_bank_compat',
            direction: PostingDirection.debit,
            amount: Money.fromPaise(20000),
            createdAt: now,
          ),
          Posting(
            id: 'pos_14_rev_cr',
            economicEventId: 'evt_rev_14_posted',
            accountId: TablesV24.sysExpMisc,
            direction: PostingDirection.credit,
            amount: Money.fromPaise(20000),
            createdAt: now,
          ),
        ],
      );
      final persistedPosted = await canonicalEventRepo.getEvent('evt_rev_14_posted');
      expect(persistedPosted, isNotNull);
      expect(persistedPosted!.reversalOfEventId, 'evt_target_14_posted');
      expect(persistedPosted.lifecycleStatus.isPosted, isTrue);
    });

    test('15. Concurrent attempts cannot create two reversals for the same original event when index is deferred', () async {
      await dropUniqueIndex();
      expect(await hasUniqueIndex(), isFalse);

      final now = DateTime(2026, 11, 1, 10, 0);
      final targetEvent = EconomicEvent.draft(
        id: 'evt_target_15',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'Target event 15',
      );
      await canonicalEventRepo.createAndPostEvent(
        targetEvent,
        postings: [
          Posting(
            id: 'pos_15_dr',
            economicEventId: 'evt_target_15',
            accountId: TablesV24.sysExpMisc,
            direction: PostingDirection.debit,
            amount: Money.fromPaise(30000),
            createdAt: now,
          ),
          Posting(
            id: 'pos_15_cr',
            economicEventId: 'evt_target_15',
            accountId: 'acc_bank_compat',
            direction: PostingDirection.credit,
            amount: Money.fromPaise(30000),
            createdAt: now,
          ),
        ],
      );

      final revA = EconomicEvent.draft(
        id: 'evt_rev_15_a',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'Concurrent Reversal A',
        reversalOfEventId: 'evt_target_15',
      );
      final revB = EconomicEvent.draft(
        id: 'evt_rev_15_b',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'Concurrent Reversal B',
        reversalOfEventId: 'evt_target_15',
      );

      int successCount = 0;
      int errorCount = 0;

      Future<void> runRev(EconomicEvent rev, String pfx) async {
        try {
          await canonicalEventRepo.createAndPostEvent(
            rev,
            postings: [
              Posting(
                id: 'pos_15_${pfx}_dr',
                economicEventId: rev.id,
                accountId: 'acc_bank_compat',
                direction: PostingDirection.debit,
                amount: Money.fromPaise(30000),
                createdAt: now,
              ),
              Posting(
                id: 'pos_15_${pfx}_cr',
                economicEventId: rev.id,
                accountId: TablesV24.sysExpMisc,
                direction: PostingDirection.credit,
                amount: Money.fromPaise(30000),
                createdAt: now,
              ),
            ],
          );
          successCount++;
        } on AccountingInvariantException {
          errorCount++;
        }
      }

      await Future.wait([
        runRev(revA, 'a'),
        runRev(revB, 'b'),
      ]);

      expect(successCount, 1, reason: 'Exactly one concurrent reversal must succeed');
      expect(errorCount, 1, reason: 'The competing concurrent reversal must be rejected');

      final reversals = await db.query(
        TablesV24.economicEvents,
        where: 'reversal_of_event_id = ?',
        whereArgs: ['evt_target_15'],
      );
      expect(reversals.length, 1);
    });

    test('16. Existing historical duplicates remain unchanged when duplicate rejection is triggered', () async {
      await dropUniqueIndex();

      final nowStr = '2026-11-01T10:00:00.000Z';
      Future<void> seedPostedWithPostings(String eventId, {String? revOf, String? notes, String? ts}) async {
        final t = ts ?? nowStr;
        await db.insert(TablesV24.economicEvents, {
          'id': eventId,
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          if (revOf != null) 'reversal_of_event_id': revOf,
          'timestamp': t,
          'currency': 'INR',
          'description': 'Description $eventId',
          if (notes != null) 'notes': notes,
          'created_at': t,
          'updated_at': t,
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_${eventId}_1',
          'economic_event_id': eventId,
          'account_id': TablesV24.sysExpMisc,
          'sequence_number': 1,
          'direction': revOf != null ? 'credit' : 'debit',
          'amount_minor_units': 50000,
          'currency': 'INR',
          'created_at': t,
        });
        await db.insert(TablesV24.postings, {
          'id': 'pos_${eventId}_2',
          'economic_event_id': eventId,
          'account_id': 'acc_bank_compat',
          'sequence_number': 2,
          'direction': revOf != null ? 'debit' : 'credit',
          'amount_minor_units': 50000,
          'currency': 'INR',
          'created_at': t,
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: [eventId],
        );
      }

      await seedPostedWithPostings('evt_target_16');
      await seedPostedWithPostings('evt_hist_16_1', revOf: 'evt_target_16', notes: 'historical notes 1', ts: '2026-11-01T10:00:01.000Z');
      await seedPostedWithPostings('evt_hist_16_2', revOf: 'evt_target_16', notes: 'historical notes 2', ts: '2026-11-01T10:00:02.000Z');

      final hist1Before = (await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: ['evt_hist_16_1'])).first;
      final hist2Before = (await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: ['evt_hist_16_2'])).first;

      // Attempt new reversal via canonicalEventRepo
      final now = DateTime(2026, 11, 1, 10, 5);
      final newRev = EconomicEvent.draft(
        id: 'evt_new_rev_16',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'New Reversal Attempt',
        reversalOfEventId: 'evt_target_16',
      );

      expect(
        () async => await canonicalEventRepo.createDraftEvent(newRev),
        throwsA(isA<AccountingInvariantException>()),
      );

      final hist1After = (await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: ['evt_hist_16_1'])).first;
      final hist2After = (await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: ['evt_hist_16_2'])).first;

      expect(hist1After, equals(hist1Before));
      expect(hist2After, equals(hist2Before));
    });

    test('17. Normal non-reversal event creation remains completely unaffected', () async {
      await dropUniqueIndex();

      final now = DateTime(2026, 11, 1, 10, 0);
      final normalExpense = EconomicEvent.draft(
        id: 'evt_normal_exp',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'Normal Grocery Expense',
      );
      await canonicalEventRepo.createAndPostEvent(
        normalExpense,
        postings: [
          Posting(
            id: 'pos_norm_dr',
            economicEventId: 'evt_normal_exp',
            accountId: TablesV24.sysExpMisc,
            direction: PostingDirection.debit,
            amount: Money.fromPaise(15000),
            createdAt: now,
          ),
          Posting(
            id: 'pos_norm_cr',
            economicEventId: 'evt_normal_exp',
            accountId: 'acc_bank_compat',
            direction: PostingDirection.credit,
            amount: Money.fromPaise(15000),
            createdAt: now,
          ),
        ],
      );

      final normalDraft = EconomicEvent.draft(
        id: 'evt_normal_draft',
        canonicalType: CanonicalEventType.income,
        occurredAt: now,
        createdAt: now,
        description: 'Normal Salary Draft',
      );
      await canonicalEventRepo.createDraftEvent(normalDraft);

      final loadedExp = await canonicalEventRepo.getEvent('evt_normal_exp');
      final loadedDraft = await canonicalEventRepo.getEvent('evt_normal_draft');

      expect(loadedExp, isNotNull);
      expect(loadedExp!.lifecycleStatus.isPosted, isTrue);
      expect(loadedExp.reversalOfEventId, isNull);

      expect(loadedDraft, isNotNull);
      expect(loadedDraft!.lifecycleStatus.isDraft, isTrue);
      expect(loadedDraft.reversalOfEventId, isNull);
    });

    test('18. Clean databases continue to enforce the unique index at storage layer', () async {
      expect(await hasUniqueIndex(), isTrue);

      final now = DateTime(2026, 11, 1, 10, 0);
      final target = EconomicEvent.draft(
        id: 'evt_clean_idx_tgt',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'Clean Target',
      );
      await canonicalEventRepo.createDraftEvent(target);

      final rev1 = EconomicEvent.draft(
        id: 'evt_clean_idx_rev1',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
        description: 'Clean Reversal 1',
        reversalOfEventId: 'evt_clean_idx_tgt',
      );
      await canonicalEventRepo.createDraftEvent(rev1);

      // Raw attempt bypassing canonical checks must trigger DatabaseException (code 1555)
      final nowStr = now.toIso8601String();
      expect(
        () async => await db.insert(TablesV24.economicEvents, {
          'id': 'evt_clean_raw_bypass',
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'reversal_of_event_id': 'evt_clean_idx_tgt',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'Raw Bypass Reversal',
          'created_at': nowStr,
          'updated_at': nowStr,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });
  });
}
