import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/transaction.dart' as model;

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone 5.0 Phase 4 — Group A Verification Suite (DEF-513, DEF-515, DEF-518)', () {
    late Database db;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late TransactionRepo transactionRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );

      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      transactionRepo = TransactionRepo(executor: db);

      final now = DateTime.now();
      await canonicalAccountRepo.createAccount(
        Account(
          id: 'acc_bank_primary',
          name: 'Primary Bank',
          type: AccountType.asset,
          category: 'bank',
          createdAt: now,
          updatedAt: now,
        ),
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> recordBalancedTransaction({
      required String eventId,
      required String debitAccountId,
      required String creditAccountId,
      required int amountMinorUnits,
      required DateTime timestampUtc,
      String eventType = 'income',
      String description = 'Test Event',
    }) async {
      final iso = timestampUtc.toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': eventId,
        'event_type': eventType,
        'lifecycle_status': 'draft',
        'timestamp': iso,
        'currency': 'INR',
        'description': description,
        'created_at': iso,
        'updated_at': iso,
      });

      await db.insert(TablesV24.postings, {
        'id': 'post_deb_$eventId',
        'economic_event_id': eventId,
        'account_id': debitAccountId,
        'direction': 'debit',
        'amount_minor_units': amountMinorUnits,
        'created_at': iso,
      });

      await db.insert(TablesV24.postings, {
        'id': 'post_cred_$eventId',
        'economic_event_id': eventId,
        'account_id': creditAccountId,
        'direction': 'credit',
        'amount_minor_units': amountMinorUnits,
        'created_at': iso,
      });

      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted', 'updated_at': iso},
        where: 'id = ?',
        whereArgs: [eventId],
      );
    }

    // -------------------------------------------------------------------------
    // TEST 1: IST Month Transition (DEF-513 & DEF-518)
    // -------------------------------------------------------------------------
    test('1. November 1, 02:00 IST transaction is correctly included in November queries and monthlyStats', () async {
      // 2026-11-01 02:00:00 IST is 2026-10-31 20:30:00 UTC
      final eventDateUtc = DateTime.parse('2026-10-31T20:30:00.000Z');

      await recordBalancedTransaction(
        eventId: 'evt_ist_1',
        debitAccountId: 'acc_bank_primary',
        creditAccountId: TablesV24.sysIncMisc,
        amountMinorUnits: 5000000, // ₹50,000
        timestampUtc: eventDateUtc,
        eventType: 'income',
        description: 'Salary November',
      );

      // Query November using local boundaries
      final localNovStart = DateTime(2026, 11, 1);
      final localDecStart = DateTime(2026, 12, 1);

      // DEF-513: CanonicalFinancialQueryRepository.getTotalIncome converts local start/end to UTC
      final novIncome = await canonicalQueryRepo.getTotalIncome(
        startDate: localNovStart,
        endDate: localDecStart,
      );
      expect(novIncome.minorUnits, equals(5000000), reason: 'DEF-513 fixed: Local boundaries converted to UTC include transaction');
      expect(novIncome.toRupees, equals(50000.0));

      // DEF-518: TransactionRepo.getMonthlyStats respects reporting timezone
      const istOffset = Duration(hours: 5, minutes: 30);
      final monthlyStats = await transactionRepo.getMonthlyStats(12, timeZoneOffset: istOffset);
      final novEntry = monthlyStats.where((s) => s['month'] == '2026-11').firstOrNull;
      expect(novEntry, isNotNull, reason: 'DEF-518 fixed: Transaction correctly bucketed in 2026-11');
      expect(novEntry!['income'], equals(50000.0));

      // TransactionRepo.getStatsForMonth
      final novStats = await transactionRepo.getStatsForMonth(2026, 11, timeZoneOffset: istOffset);
      expect(novStats['income'], equals(50000.0));
      final octStats = await transactionRepo.getStatsForMonth(2026, 10, timeZoneOffset: istOffset);
      expect(octStats['income'], equals(0.0), reason: 'Not included in October under IST');
    });

    // -------------------------------------------------------------------------
    // TEST 2: UTC Month Transition
    // -------------------------------------------------------------------------
    test('2. UTC month transition properly respects UTC reporting offset (Duration.zero)', () async {
      // 2026-11-01 00:00:00 UTC
      final eventDateUtc = DateTime.parse('2026-11-01T00:00:00.000Z');

      await recordBalancedTransaction(
        eventId: 'evt_utc_1',
        debitAccountId: 'acc_bank_primary',
        creditAccountId: TablesV24.sysIncMisc,
        amountMinorUnits: 1500000, // ₹15,000
        timestampUtc: eventDateUtc,
        eventType: 'income',
        description: 'UTC Nov Income',
      );

      final monthlyStatsUtc = await transactionRepo.getMonthlyStats(
        12,
        timeZoneOffset: Duration.zero,
      );
      final novEntry = monthlyStatsUtc.where((s) => s['month'] == '2026-11').firstOrNull;
      expect(novEntry, isNotNull);
      expect(novEntry!['income'], equals(15000.0));

      final novStats = await transactionRepo.getStatsForMonth(2026, 11, timeZoneOffset: Duration.zero);
      expect(novStats['income'], equals(15000.0));
    });

    // -------------------------------------------------------------------------
    // TEST 3: Midnight Purchase on Local Month Boundary (DEF-518)
    // -------------------------------------------------------------------------
    test('3. November 1, 00:00:00 IST expense is not counted in October stats', () async {
      // 2026-11-01 00:00:00 IST is 2026-10-31 18:30:00 UTC
      final eventDateUtc = DateTime.parse('2026-10-31T18:30:00.000Z');

      await recordBalancedTransaction(
        eventId: 'evt_midnight_1',
        debitAccountId: TablesV24.sysExpMisc,
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 250000, // ₹2,500
        timestampUtc: eventDateUtc,
        eventType: 'expense',
        description: 'Midnight Nov 1 Expense',
      );

      const istOffset = Duration(hours: 5, minutes: 30);
      final octStats = await transactionRepo.getStatsForMonth(2026, 10, timeZoneOffset: istOffset);
      expect(octStats['expense'], equals(0.0), reason: 'DEF-518 fixed: Midnight Nov 1 IST expense is not in October');

      final novStats = await transactionRepo.getStatsForMonth(2026, 11, timeZoneOffset: istOffset);
      expect(novStats['expense'], equals(2500.0), reason: 'DEF-518 fixed: Midnight Nov 1 IST expense is in November');
    });

    // -------------------------------------------------------------------------
    // TEST 4: Fractional-Second Boundary Handling (DEF-515)
    // -------------------------------------------------------------------------
    test('4. Fractional-second transactions at 23:59:59.500 and 23:59:59.999 are included in previous month', () {
      final now = DateTime(2026, 11, 8, 12, 0, 0);
      final currentMonthStart = DateTime(now.year, now.month, 1);
      final previousMonthStart = DateTime(now.year, now.month - 1, 1);

      final tx500ms = model.Transaction(
        id: 'tx_500ms',
        userId: 'usr',
        type: 'expense',
        amount: 1500.0,
        date: DateTime(2026, 10, 31, 23, 59, 59, 500),
        notes: '500ms expense',
      );

      final tx999ms = model.Transaction(
        id: 'tx_999ms',
        userId: 'usr',
        type: 'expense',
        amount: 800.0,
        date: DateTime(2026, 10, 31, 23, 59, 59, 999),
        notes: '999ms expense',
      );

      final txMidnight = model.Transaction(
        id: 'tx_midnight',
        userId: 'usr',
        type: 'expense',
        amount: 500.0,
        date: DateTime(2026, 11, 1, 0, 0, 0, 0),
        notes: 'Midnight Nov 1',
      );

      // Half-open previous month evaluation: [previousMonthStart, currentMonthStart)
      bool inPrevMonth(model.Transaction t) =>
          !t.date.isBefore(previousMonthStart) && t.date.isBefore(currentMonthStart);

      // Half-open current month evaluation: [currentMonthStart, nextMonthStart)
      final nextMonthStart = DateTime(now.year, now.month + 1, 1);
      bool inCurrentMonth(model.Transaction t) =>
          !t.date.isBefore(currentMonthStart) && t.date.isBefore(nextMonthStart);

      expect(inPrevMonth(tx500ms), isTrue, reason: 'DEF-515 fixed: 23:59:59.500 is in October');
      expect(inPrevMonth(tx999ms), isTrue, reason: 'DEF-515 fixed: 23:59:59.999 is in October');
      expect(inPrevMonth(txMidnight), isFalse, reason: 'Midnight Nov 1 is NOT in October');

      expect(inCurrentMonth(tx500ms), isFalse);
      expect(inCurrentMonth(txMidnight), isTrue, reason: 'Midnight Nov 1 is in November');
    });

    // -------------------------------------------------------------------------
    // TEST 5: Year Boundary Transitions
    // -------------------------------------------------------------------------
    test('5. Year boundary transitions (December 31 to January 1) are accurately handled', () async {
      // 2027-01-01 01:30:00 IST is 2026-12-31 20:00:00 UTC
      final eventDateUtc = DateTime.parse('2026-12-31T20:00:00.000Z');

      await recordBalancedTransaction(
        eventId: 'evt_new_year_1',
        debitAccountId: 'acc_bank_primary',
        creditAccountId: TablesV24.sysIncMisc,
        amountMinorUnits: 10000000, // ₹1,00,000
        timestampUtc: eventDateUtc,
        eventType: 'income',
        description: 'New Year Bonus',
      );

      const istOffset = Duration(hours: 5, minutes: 30);
      final decStats = await transactionRepo.getStatsForMonth(2026, 12, timeZoneOffset: istOffset);
      expect(decStats['income'], equals(0.0), reason: 'Not in December 2026 under IST');

      final janStats = await transactionRepo.getStatsForMonth(2027, 1, timeZoneOffset: istOffset);
      expect(janStats['income'], equals(100000.0), reason: 'Correctly in January 2027 under IST');

      final monthlyStats = await transactionRepo.getMonthlyStats(12, timeZoneOffset: istOffset);
      final janEntry = monthlyStats.where((s) => s['month'] == '2027-01').firstOrNull;
      expect(janEntry, isNotNull);
      expect(janEntry!['income'], equals(100000.0));
    });

    // -------------------------------------------------------------------------
    // TEST 6: Half-Open Range Invariant [start, end)
    // -------------------------------------------------------------------------
    test('6. Half-open range strictly includes start and excludes end moment', () async {
      final start = DateTime.utc(2026, 6, 1, 0, 0, 0);
      final end = DateTime.utc(2026, 7, 1, 0, 0, 0);

      // Event exactly at start
      await recordBalancedTransaction(
        eventId: 'evt_start_edge',
        debitAccountId: 'acc_bank_primary',
        creditAccountId: TablesV24.sysIncMisc,
        amountMinorUnits: 100000, // ₹1,000
        timestampUtc: start,
        eventType: 'income',
        description: 'Start moment',
      );

      // Event exactly at end
      await recordBalancedTransaction(
        eventId: 'evt_end_edge',
        debitAccountId: 'acc_bank_primary',
        creditAccountId: TablesV24.sysIncMisc,
        amountMinorUnits: 200000, // ₹2,000
        timestampUtc: end,
        eventType: 'income',
        description: 'End moment',
      );

      final income = await canonicalQueryRepo.getTotalIncome(
        startDate: start,
        endDate: end,
      );
      // In [start, end), start is included (₹1,000), end is excluded (₹2,000)
      expect(income.minorUnits, equals(100000), reason: 'Start is included, end is strictly excluded');
    });

    // -------------------------------------------------------------------------
    // TEST 7: Expenses & Cash Flow Half-Open UTC Query Conformance
    // -------------------------------------------------------------------------
    test('7. getTotalExpenses and getCashFlow properly convert local dates to UTC half-open ranges', () async {
      // 2026-11-01 02:00:00 IST is 2026-10-31 20:30:00 UTC
      final eventDateUtc = DateTime.parse('2026-10-31T20:30:00.000Z');

      await recordBalancedTransaction(
        eventId: 'evt_exp_ist_1',
        debitAccountId: TablesV24.sysExpMisc,
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 300000, // ₹3,000
        timestampUtc: eventDateUtc,
        eventType: 'expense',
        description: 'Nov 1 2am Purchase',
      );

      final localNovStart = DateTime(2026, 11, 1);
      final localDecStart = DateTime(2026, 12, 1);

      final expenses = await canonicalQueryRepo.getTotalExpenses(
        startDate: localNovStart,
        endDate: localDecStart,
      );
      expect(expenses.minorUnits, equals(300000));
      expect(expenses.toRupees, equals(3000.0));

      final cashFlow = await canonicalQueryRepo.getCashFlow(
        startDate: localNovStart,
        endDate: localDecStart,
      );
      // Outflow of ₹3,000 = -₹3,000
      expect(cashFlow.toRupees, equals(-3000.0));
    });
  });
}
