import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/reminder_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/reminder_model.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Safe-to-Spend Recurring Obligation Remediation Comprehensive Suite', () {
    late Database db;
    late CanonicalFinancialQueryRepository queryRepo;
    late CanonicalAccountRepository accountRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = OFF;');
        },
      );

      // Create Tables
      await TablesV24.createAllV24(db);
      await TablesV24.installTriggers(db);
      await TablesV24.seedSystemAccounts(db);

      await db.execute(Tables.createReminders);
      await db.execute(Tables.createRecurringTemplates);
      await db.execute(Tables.createCreditCards);
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${Tables.transactions} (
          id TEXT PRIMARY KEY,
          user_id TEXT,
          category_id TEXT,
          account_id TEXT,
          amount REAL NOT NULL,
          type TEXT NOT NULL,
          date TEXT NOT NULL,
          notes TEXT,
          note TEXT,
          source TEXT,
          related_entity_id TEXT,
          external_ref TEXT,
          location TEXT,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''');

      queryRepo = CanonicalFinancialQueryRepository(executor: db);
      accountRepo = CanonicalAccountRepository(executor: db);

      final now = DateTime.now();
      await accountRepo.createAccount(Account(
        id: 'acc_cash_default',
        name: 'Cash',
        type: AccountType.asset,
        category: 'cash',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_expense_general',
        name: 'General Expense',
        type: AccountType.expense,
        category: 'expense',
        createdAt: now,
        updatedAt: now,
      ));
    });

    tearDown(() async {
      await db.close();
    });

    // Helper to insert a posted double-entry expense into TablesV24
    Future<void> insertV24Expense({
      required String id,
      required String description,
      required double amountRupees,
      required DateTime timestamp,
    }) async {
      final minorUnits = (amountRupees * 100).round();
      final iso = timestamp.toIso8601String();

      await db.insert(TablesV24.economicEvents, {
        'id': id,
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': iso,
        'currency': 'INR',
        'description': description,
        'merchant_normalized': description.toLowerCase(),
        'created_at': iso,
        'updated_at': iso,
      });

      await db.insert(TablesV24.postings, {
        'id': 'p_${id}_dr',
        'economic_event_id': id,
        'account_id': 'acc_expense_general',
        'direction': 'debit',
        'amount_minor_units': minorUnits,
        'created_at': iso,
      });

      await db.insert(TablesV24.postings, {
        'id': 'p_${id}_cr',
        'economic_event_id': id,
        'account_id': 'acc_cash_default',
        'direction': 'credit',
        'amount_minor_units': minorUnits,
        'created_at': iso,
      });

      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted', 'updated_at': iso},
        where: 'id = ?',
        whereArgs: [id],
      );

      // Mirror to legacy transactions table for complete compatibility
      await db.insert(Tables.transactions, {
        'id': id,
        'user_id': 'u1',
        'amount': amountRupees,
        'type': 'expense',
        'date': iso,
        'notes': description,
        'created_at': iso,
        'updated_at': iso,
        'is_deleted': 0,
      });
    }

    // =========================================================================
    // SECTION 1: Recurrence Correctness
    // =========================================================================

    test('1.1 January 31 -> February 28/29 -> March 31 anchor day preservation', () {
      final jan31 = DateTime(2026, 1, 31, 10, 0);

      // Jan 31 -> Feb 28 (clamped to 28 days in non-leap year 2026)
      final feb = CanonicalFinancialQueryRepository.calculateNextRecurringDate(
        jan31,
        'monthly',
        anchorDay: 31,
      );
      expect(feb.year, 2026);
      expect(feb.month, 2);
      expect(feb.day, 28);

      // Feb 28 -> Mar 31 (recovers anchor day 31, not stuck on 28!)
      final mar = CanonicalFinancialQueryRepository.calculateNextRecurringDate(
        feb,
        'monthly',
        anchorDay: 31,
      );
      expect(mar.year, 2026);
      expect(mar.month, 3);
      expect(mar.day, 31);

      // Mar 31 -> Apr 30 (clamped to 30 days)
      final apr = CanonicalFinancialQueryRepository.calculateNextRecurringDate(
        mar,
        'monthly',
        anchorDay: 31,
      );
      expect(apr.year, 2026);
      expect(apr.month, 4);
      expect(apr.day, 30);

      // Apr 30 -> May 31 (recovers anchor day 31)
      final may = CanonicalFinancialQueryRepository.calculateNextRecurringDate(
        apr,
        'monthly',
        anchorDay: 31,
      );
      expect(may.year, 2026);
      expect(may.month, 5);
      expect(may.day, 31);
    });

    test('1.2 Leap-year annual recurrence: Feb 29 restores on next leap year', () {
      final leap2024 = DateTime(2024, 2, 29, 9, 30);

      // 2024 -> 2025 (clamped to Feb 28)
      final year2025 = CanonicalFinancialQueryRepository.calculateNextRecurringDate(
        leap2024,
        'yearly',
        anchorDay: 29,
      );
      expect(year2025.year, 2025);
      expect(year2025.month, 2);
      expect(year2025.day, 28);

      // 2025 -> 2026
      final year2026 = CanonicalFinancialQueryRepository.calculateNextRecurringDate(
        year2025,
        'yearly',
        anchorDay: 29,
      );
      expect(year2026.year, 2026);
      expect(year2026.month, 2);
      expect(year2026.day, 28);

      // 2026 -> 2027
      final year2027 = CanonicalFinancialQueryRepository.calculateNextRecurringDate(
        year2026,
        'yearly',
        anchorDay: 29,
      );
      expect(year2027.year, 2027);
      expect(year2027.month, 2);
      expect(year2027.day, 28);

      // 2027 -> 2028 (leap year restores Feb 29!)
      final year2028 = CanonicalFinancialQueryRepository.calculateNextRecurringDate(
        year2027,
        'yearly',
        anchorDay: 29,
      );
      expect(year2028.year, 2028);
      expect(year2028.month, 2);
      expect(year2028.day, 29);
    });

    test('1.3 Multiple missed occurrences in weekly template are both reported as overdue', () async {
      final now = DateTime.now();
      // Weekly template started 12 days ago, never paid
      final start12dAgo = now.subtract(const Duration(days: 12));

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_weekly_groceries',
        'name': 'Weekly Groceries',
        'amount': 500.0,
        'type': 'expense',
        'frequency': 'weekly',
        'interval': 1,
        'day_of_month': start12dAgo.day,
        'next_generation': start12dAgo.toIso8601String(),
        'is_active': 1,
        'created_at': start12dAgo.toIso8601String(),
      });

      final calc = await queryRepo.getSafeToSpend();
      final items = calc.commitmentItems.where((c) => c.title == 'Weekly Groceries').toList();

      final overdueItems = items.where((c) => c.isOverdue).toList();
      final upcomingItems = items.where((c) => !c.isOverdue).toList();

      expect(overdueItems.length, 2, reason: 'Must capture both missed cycles (12d ago and 5d ago)');
      expect(upcomingItems.length, 2, reason: 'Must capture both upcoming cycles (in 2d and in 9d)');
      expect(calc.knownCommitments14d.toRupees, 2000.0);
    });

    test('1.4 Exact overdue and forward-window boundaries', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // Exact 14-day past boundary (included)
      final exactPastBoundary = today.subtract(const Duration(days: 14));
      // 15 days ago (excluded)
      final outsidePast = today.subtract(const Duration(days: 15));
      // Exact 14-day forward boundary (included)
      final exactFutureBoundary = today.add(const Duration(days: 14));
      // 15 days ahead (excluded)
      final outsideFuture = today.add(const Duration(days: 15));

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_exact_past',
        'name': 'Boundary Past 14d',
        'amount': 100.0,
        'type': 'expense',
        'frequency': 'yearly',
        'interval': 1,
        'next_generation': exactPastBoundary.toIso8601String(),
        'is_active': 1,
        'created_at': exactPastBoundary.toIso8601String(),
      });

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_outside_past',
        'name': 'Outside Past 15d',
        'amount': 200.0,
        'type': 'expense',
        'frequency': 'yearly',
        'interval': 1,
        'next_generation': outsidePast.toIso8601String(),
        'is_active': 1,
        'created_at': outsidePast.toIso8601String(),
      });

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_exact_future',
        'name': 'Boundary Future 14d',
        'amount': 300.0,
        'type': 'expense',
        'frequency': 'yearly',
        'interval': 1,
        'next_generation': exactFutureBoundary.toIso8601String(),
        'is_active': 1,
        'created_at': now.toIso8601String(),
      });

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_outside_future',
        'name': 'Outside Future 15d',
        'amount': 400.0,
        'type': 'expense',
        'frequency': 'yearly',
        'interval': 1,
        'next_generation': outsideFuture.toIso8601String(),
        'is_active': 1,
        'created_at': now.toIso8601String(),
      });

      final calc = await queryRepo.getSafeToSpend();
      final titles = calc.commitmentItems.map((c) => c.title).toSet();

      expect(titles.contains('Boundary Past 14d'), isTrue, reason: 'Exact 14-day past boundary must be included');
      expect(titles.contains('Outside Past 15d'), isFalse, reason: 'Beyond 14-day past boundary must be excluded');
      expect(titles.contains('Boundary Future 14d'), isTrue, reason: 'Exact 14-day forward boundary must be included');
      expect(titles.contains('Outside Future 15d'), isFalse, reason: 'Beyond 14-day forward boundary must be excluded');
    });

    test('1.5 Future last_generated_date does not act as faux-payment or corrupt schedule', () async {
      final now = DateTime.now();
      final dueIn5Days = now.add(const Duration(days: 5));
      final futureGen = now.add(const Duration(days: 10));

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_future_gen',
        'name': 'Software Tool',
        'amount': 899.0,
        'type': 'expense',
        'frequency': 'monthly',
        'interval': 1,
        'next_generation': dueIn5Days.toIso8601String(),
        'last_generated': futureGen.toIso8601String(),
        'is_active': 1,
        'created_at': now.toIso8601String(),
      });

      final calc = await queryRepo.getSafeToSpend();
      final item = calc.commitmentItems.where((c) => c.title == 'Software Tool').firstOrNull;

      expect(item, isNotNull, reason: 'Generation cursor cannot serve as proof of payment; unpaid obligation must remain');
      expect(item!.amount.toRupees, 899.0);
    });

    test('1.6 Timezone and date-boundary behavior (midnight vs late-night)', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // Yesterday at 23:59:00 -> overdue
      final yesterdayLate = today.subtract(const Duration(seconds: 60));
      // Today at 00:01:00 -> due today (not overdue)
      final todayEarly = today.add(const Duration(minutes: 1));
      // Today at 23:59:00 -> due today (not overdue)
      final todayLate = today.add(const Duration(hours: 23, minutes: 59));

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_yesterday_late',
        'name': 'Late Yesterday Bill',
        'amount': 111.0,
        'type': 'expense',
        'frequency': 'monthly',
        'next_generation': yesterdayLate.toIso8601String(),
        'is_active': 1,
        'created_at': yesterdayLate.toIso8601String(),
      });

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_today_early',
        'name': 'Early Today Bill',
        'amount': 222.0,
        'type': 'expense',
        'frequency': 'monthly',
        'next_generation': todayEarly.toIso8601String(),
        'is_active': 1,
        'created_at': todayEarly.toIso8601String(),
      });

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_today_late',
        'name': 'Late Today Bill',
        'amount': 333.0,
        'type': 'expense',
        'frequency': 'monthly',
        'next_generation': todayLate.toIso8601String(),
        'is_active': 1,
        'created_at': todayLate.toIso8601String(),
      });

      final calc = await queryRepo.getSafeToSpend();
      final yLate = calc.commitmentItems.firstWhere((c) => c.title == 'Late Yesterday Bill');
      final tEarly = calc.commitmentItems.firstWhere((c) => c.title == 'Early Today Bill');
      final tLate = calc.commitmentItems.firstWhere((c) => c.title == 'Late Today Bill');

      expect(yLate.isOverdue, isTrue, reason: 'Yesterday 23:59 must be classified as overdue');
      expect(tEarly.isOverdue, isFalse, reason: 'Today 00:01 is not overdue');
      expect(tLate.isOverdue, isFalse, reason: 'Today 23:59 is not overdue');
    });

    // =========================================================================
    // SECTION 2: Settlement Matching Safety
    // =========================================================================

    test('2.1 Two qualifying transactions for one occurrence consumes exactly one', () async {
      final now = DateTime.now();
      final due7dAgo = now.subtract(const Duration(days: 7));

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_gym_single',
        'name': 'Fitness Gym',
        'amount': 1200.0,
        'type': 'expense',
        'frequency': 'monthly',
        'next_generation': due7dAgo.toIso8601String(),
        'is_active': 1,
        'created_at': due7dAgo.toIso8601String(),
      });

      await insertV24Expense(
        id: 'tx_gym_exact',
        description: 'Fitness Gym AutoPay',
        amountRupees: 1200.0,
        timestamp: due7dAgo,
      );
      await insertV24Expense(
        id: 'tx_gym_extra',
        description: 'Fitness Gym Counter',
        amountRupees: 1200.0,
        timestamp: due7dAgo.add(const Duration(days: 1)),
      );

      final calc = await queryRepo.getSafeToSpend();
      final gymItems = calc.commitmentItems.where((c) => c.title == 'Fitness Gym').toList();

      expect(gymItems.isEmpty, isTrue, reason: 'Occurrence is settled');
      final events = await db.query(TablesV24.economicEvents, where: "description LIKE '%Fitness Gym%'");
      expect(events.length, 2, reason: 'Both ledger transactions must be preserved without mutation');
    });

    test('2.2 One transaction qualifying for two templates settles exactly one', () async {
      final now = DateTime.now();
      final due4dAgo = now.subtract(const Duration(days: 4));

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_adobe_personal',
        'name': 'Adobe Creative',
        'amount': 4200.0,
        'type': 'expense',
        'frequency': 'monthly',
        'next_generation': due4dAgo.toIso8601String(),
        'is_active': 1,
        'created_at': due4dAgo.toIso8601String(),
      });

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_adobe_work',
        'name': 'Adobe Cloud Service',
        'amount': 4200.0,
        'type': 'expense',
        'frequency': 'monthly',
        'next_generation': due4dAgo.toIso8601String(),
        'is_active': 1,
        'created_at': due4dAgo.toIso8601String(),
      });

      await insertV24Expense(
        id: 'tx_adobe_single_paid',
        description: 'Adobe Systems India',
        amountRupees: 4200.0,
        timestamp: due4dAgo,
      );

      final calc = await queryRepo.getSafeToSpend();
      final adobeItems = calc.commitmentItems.where((c) => c.title.contains('Adobe')).toList();

      expect(adobeItems.length, 1, reason: 'Deterministic 1-to-1 matching: one transaction cannot settle two templates');
      expect(adobeItems.first.amount.toRupees, 4200.0);
    });

    test('2.3 Two recurring templates with identical merchant and amount', () async {
      final now = DateTime.now();
      final due3dAgo = now.subtract(const Duration(days: 3));

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_netflix_sub1',
        'name': 'Netflix Account 1',
        'amount': 199.0,
        'type': 'expense',
        'frequency': 'monthly',
        'next_generation': due3dAgo.toIso8601String(),
        'is_active': 1,
        'created_at': due3dAgo.toIso8601String(),
      });

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_netflix_sub2',
        'name': 'Netflix Account 2',
        'amount': 199.0,
        'type': 'expense',
        'frequency': 'monthly',
        'next_generation': due3dAgo.toIso8601String(),
        'is_active': 1,
        'created_at': due3dAgo.toIso8601String(),
      });

      await insertV24Expense(
        id: 'tx_netflix_single',
        description: 'Netflix Payment',
        amountRupees: 199.0,
        timestamp: due3dAgo,
      );

      final calc = await queryRepo.getSafeToSpend();
      final netflixItems = calc.commitmentItems.where((c) => c.title.contains('Netflix')).toList();

      expect(netflixItems.length, 1, reason: 'Only one Netflix template is settled; second remains active unpaid');
    });

    test('2.4 Same merchant and amount but unrelated purchases are not matched', () async {
      final now = DateTime.now();
      final dueIn3Days = now.add(const Duration(days: 3));

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_swiggy_one',
        'name': 'Swiggy One Membership',
        'amount': 299.0,
        'type': 'expense',
        'frequency': 'monthly',
        'next_generation': dueIn3Days.toIso8601String(),
        'is_active': 1,
        'created_at': now.toIso8601String(),
      });

      await insertV24Expense(
        id: 'tx_unrelated_pizza',
        description: 'Pizza Hut Order',
        amountRupees: 299.0,
        timestamp: dueIn3Days,
      );

      final calc = await queryRepo.getSafeToSpend();
      final item = calc.commitmentItems.where((c) => c.title == 'Swiggy One Membership').firstOrNull;

      expect(item, isNotNull, reason: 'Unrelated merchant must never settle recurring template');
      expect(item!.amount.toRupees, 299.0);
    });

    test('2.5 Ambiguous candidates: deterministic ranking picks closest match', () async {
      final now = DateTime.now();
      final occDate = now.subtract(const Duration(days: 6));

      await db.insert(Tables.recurring_templates, {
        'id': 'rec_broadband_multi',
        'name': 'Airtel Broadband',
        'amount': 1199.0,
        'type': 'expense',
        'frequency': 'monthly',
        'next_generation': occDate.toIso8601String(),
        'is_active': 1,
        'created_at': occDate.toIso8601String(),
      });

      // Candidate 1: 5 days away from due date
      await insertV24Expense(
        id: 'tx_airtel_far',
        description: 'Airtel Payment',
        amountRupees: 1199.0,
        timestamp: occDate.subtract(const Duration(days: 5)),
      );

      // Candidate 2: exactly on due date (diffDays = 0)
      await insertV24Expense(
        id: 'tx_airtel_close',
        description: 'Airtel Payment',
        amountRupees: 1199.0,
        timestamp: occDate,
      );

      final calc = await queryRepo.getSafeToSpend();
      final item = calc.commitmentItems.where((c) => c.title == 'Airtel Broadband').firstOrNull;
      expect(item, isNull, reason: 'Settled by closest match deterministically');
    });

    // =========================================================================
    // SECTION 3: Mark Paid Semantics
    // =========================================================================

    test('3.1 Mark Paid is preserved for reminders and does not hijack recurring template cursor', () async {
      final now = DateTime.now();
      final dueDate = now.subtract(const Duration(days: 2));

      await db.insert(Tables.reminders, {
        'id': 'rem_elec_bill',
        'title': 'Electricity Due',
        'amount': 1450.0,
        'date': dueDate.toIso8601String(),
        'type': ReminderType.service.name,
        'is_active': 1,
        'is_completed': 0,
        'record_status': ReminderRecordStatus.pending.name,
        'created_at': dueDate.toIso8601String(),
      });

      var calc = await queryRepo.getSafeToSpend();
      expect(calc.commitmentItems.any((c) => c.id == 'rem_elec_bill' && c.isOverdue), isTrue);

      await ReminderRepo(database: db).markReminderPaid('rem_elec_bill');

      calc = await queryRepo.getSafeToSpend();
      expect(calc.commitmentItems.any((c) => c.id == 'rem_elec_bill'), isFalse, reason: 'Discrete reminder marked done is settled');
    });

    // =========================================================================
    // SECTION 4: Safe-to-Spend Calculations & Baseline
    // =========================================================================

    test('4.1 Safe-to-Spend cleanly separates liquid funds, upcoming, overdue, and shortfall', () {
      final now = DateTime.now();
      final items = [
        CommitmentItem(
          title: 'Unpaid Water Bill',
          amount: Money.fromRupees(500.0),
          dueDate: now.subtract(const Duration(days: 3)),
          type: 'bill',
          isOverdue: true,
        ),
        CommitmentItem(
          title: 'Upcoming Broadband',
          amount: Money.fromRupees(1000.0),
          dueDate: now.add(const Duration(days: 5)),
          type: 'recurring',
          isOverdue: false,
        ),
      ];

      final calc = SafeToSpendCalculation.compute(
        liquidAssets: Money.fromRupees(1200.0),
        activeEarmarks: Money.zero,
        knownCommitments14d: Money.fromRupees(1500.0),
        highConfidencePendingDebits: Money.zero,
        commitmentItems: items,
      );

      final overdueItems = calc.commitmentItems.where((c) => c.isOverdue).toList();
      final upcomingItems = calc.commitmentItems.where((c) => !c.isOverdue).toList();

      expect(overdueItems.length, 1);
      expect(upcomingItems.length, 1);
      expect(overdueItems.first.amount.toRupees, 500.0);
      expect(upcomingItems.first.amount.toRupees, 1000.0);

      expect(calc.liquidAssets.toRupees, 1200.0);
      expect(calc.discretionaryCash.toRupees, -300.0);
      expect(calc.safeToSpend.toRupees, 0.0);
      expect(calc.cashflowShortfall.toRupees, 300.0);
      expect(calc.hasShortfall, isTrue);
    });

    test('4.2 November 19 baseline: Netflix settled Oct 31, YouTube settled Nov 3, Spotify due Nov 26 -> remaining commitment ₹179', () async {
      final now = DateTime.now();

      // Seed initial liquid cash of ₹498 so that after paying Netflix (₹199) and YouTube (₹299),
      // the remaining liquid cash is exactly ₹0.00.
      final seedDate = now.subtract(const Duration(days: 30));
      await db.insert(TablesV24.economicEvents, {
        'id': 'evt_open_cash',
        'event_type': 'opening_balance',
        'lifecycle_status': 'draft',
        'timestamp': seedDate.toIso8601String(),
        'currency': 'INR',
        'description': 'Opening Cash',
        'created_at': seedDate.toIso8601String(),
        'updated_at': seedDate.toIso8601String(),
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_open_dr',
        'economic_event_id': 'evt_open_cash',
        'account_id': 'acc_cash_default',
        'direction': 'debit',
        'amount_minor_units': 49800,
        'created_at': seedDate.toIso8601String(),
      });
      await db.insert(TablesV24.postings, {
        'id': 'p_open_cr',
        'economic_event_id': 'evt_open_cash',
        'account_id': 'acc_expense_general',
        'direction': 'credit',
        'amount_minor_units': 49800,
        'created_at': seedDate.toIso8601String(),
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: ['evt_open_cash'],
      );

      // 1. Netflix ₹199 settled October 31 (past cycle settled, next cycle outside 14d horizon)
      final netflixPastDue = now.subtract(const Duration(days: 19)); // ~Oct 31
      await db.insert(Tables.recurring_templates, {
        'id': 'rec_netflix_base',
        'name': 'Netflix',
        'amount': 199.0,
        'type': 'expense',
        'frequency': 'monthly',
        'interval': 1,
        'day_of_month': now.add(const Duration(days: 20)).day, // Next occurrence is outside 14-day window
        'next_generation': netflixPastDue.toIso8601String(),
        'is_active': 1,
        'created_at': netflixPastDue.toIso8601String(),
      });
      await insertV24Expense(
        id: 'tx_netflix_oct31',
        description: 'Netflix Payment',
        amountRupees: 199.0,
        timestamp: netflixPastDue,
      );

      // 2. YouTube ₹299 settled November 3 (past cycle settled, next cycle outside 14d horizon)
      final ytPastDue = now.subtract(const Duration(days: 16)); // ~Nov 3
      await db.insert(Tables.recurring_templates, {
        'id': 'rec_yt_base',
        'name': 'YouTube',
        'amount': 299.0,
        'type': 'expense',
        'frequency': 'monthly',
        'interval': 1,
        'day_of_month': now.add(const Duration(days: 22)).day, // Next occurrence is outside 14-day window
        'next_generation': ytPastDue.toIso8601String(),
        'is_active': 1,
        'created_at': ytPastDue.toIso8601String(),
      });
      await insertV24Expense(
        id: 'tx_yt_nov3',
        description: 'YouTube Subscription',
        amountRupees: 299.0,
        timestamp: ytPastDue,
      );

      // 3. Spotify ₹179 due in 7 days (November 26) - active & unpaid
      final spotifyDue = now.add(const Duration(days: 7));
      await db.insert(Tables.reminders, {
        'id': 'rem_spotify_base',
        'title': 'Spotify Subscription',
        'amount': 179.0,
        'date': spotifyDue.toIso8601String(),
        'type': ReminderType.service.name,
        'is_active': 1,
        'is_completed': 0,
        'record_status': ReminderRecordStatus.pending.name,
        'created_at': now.toIso8601String(),
      });

      final calc = await queryRepo.getSafeToSpend();

      final overdueItems = calc.commitmentItems.where((c) => c.isOverdue).toList();
      final upcomingItems = calc.commitmentItems.where((c) => !c.isOverdue).toList();

      expect(overdueItems.isEmpty, isTrue, reason: 'Zero overdue items remain after settling Netflix and YouTube');
      expect(upcomingItems.length, 1, reason: 'Only Spotify remains as upcoming obligation');
      expect(upcomingItems.first.title, contains('Spotify'));
      expect(upcomingItems.first.amount.toRupees, 179.0);

      // Expected remaining commitment: strictly ₹179.00!
      expect(calc.knownCommitments14d.toRupees, 179.0);

      // Liquid assets = ₹0.00
      expect(calc.liquidAssets.toRupees, 0.0);

      // Domain shortfall with 0 liquid cash equals remaining commitment
      expect(calc.cashflowShortfall.toRupees, 179.0);
    });

    test('4.3 Spotify state transitions: active unpaid -> cancelled -> settled/paid', () async {
      final now = DateTime.now();
      final spotifyDue = now.add(const Duration(days: 7));

      // 1. Active & unpaid recurring template
      await db.insert(Tables.recurring_templates, {
        'id': 'rec_spotify_lifecycle',
        'name': 'Spotify Premium Family',
        'amount': 179.0,
        'type': 'expense',
        'frequency': 'monthly',
        'interval': 1,
        'next_generation': spotifyDue.toIso8601String(),
        'is_active': 1,
        'created_at': now.toIso8601String(),
      });

      // State A: Active & Unpaid
      var calc = await queryRepo.getSafeToSpend();
      var item = calc.commitmentItems.where((c) => c.title == 'Spotify Premium Family').firstOrNull;
      expect(item, isNotNull, reason: 'Active unpaid Spotify must appear in commitments');
      expect(item!.amount.toRupees, 179.0);
      expect(item.isOverdue, isFalse);

      // State B: Cancelled (is_active = 0)
      await db.update(
        Tables.recurring_templates,
        {'is_active': 0},
        where: 'id = ?',
        whereArgs: ['rec_spotify_lifecycle'],
      );
      calc = await queryRepo.getSafeToSpend();
      item = calc.commitmentItems.where((c) => c.title == 'Spotify Premium Family').firstOrNull;
      expect(item, isNull, reason: 'Cancelled Spotify template must be immediately excluded');

      // State C: Reactivated (is_active = 1) but Paid / Settled
      await db.update(
        Tables.recurring_templates,
        {'is_active': 1},
        where: 'id = ?',
        whereArgs: ['rec_spotify_lifecycle'],
      );
      await insertV24Expense(
        id: 'tx_spotify_paid_settled',
        description: 'Spotify Premium Family Subscription',
        amountRupees: 179.0,
        timestamp: spotifyDue,
      );
      calc = await queryRepo.getSafeToSpend();
      item = calc.commitmentItems.where((c) => c.title == 'Spotify Premium Family').firstOrNull;
      expect(item, isNull, reason: 'Settled Spotify template must be dynamically suppressed by ledger posting');
    });

    // =========================================================================
    // SECTION 5: Ledger Invariance
    // =========================================================================

    test('5.1 Zero modification to database/transactions/postings/accounts/events', () async {
      final now = DateTime.now();
      await insertV24Expense(
        id: 'tx_audit_baseline',
        description: 'Baseline Ledger Entry',
        amountRupees: 100.0,
        timestamp: now,
      );

      final eventsBefore = await db.query(TablesV24.economicEvents);
      final postingsBefore = await db.query(TablesV24.postings);
      final accountsBefore = await db.query(TablesV24.accounts);
      final txBefore = await db.query(Tables.transactions);

      // Execute Safe-to-Spend
      await queryRepo.getSafeToSpend();

      final eventsAfter = await db.query(TablesV24.economicEvents);
      final postingsAfter = await db.query(TablesV24.postings);
      final accountsAfter = await db.query(TablesV24.accounts);
      final txAfter = await db.query(Tables.transactions);

      expect(eventsAfter, equals(eventsBefore), reason: 'Zero mutations to economic_events allowed');
      expect(postingsAfter, equals(postingsBefore), reason: 'Zero mutations to postings allowed');
      expect(accountsAfter, equals(accountsBefore), reason: 'Zero mutations to accounts allowed');
      expect(txAfter, equals(txBefore), reason: 'Zero mutations to transactions allowed');
    });

    // =========================================================================
    // SECTION 6: Final Accounting Safety Gate for Recurring Settlement Matching
    // =========================================================================

    group('6. Final Accounting Safety Gate', () {
      setUp(() async {
        final now = DateTime.now();
        await accountRepo.createAccount(Account(
          id: 'acc_bank_secondary',
          name: 'HDFC Savings',
          type: AccountType.asset,
          category: 'bank',
          createdAt: now,
          updatedAt: now,
        ));
        await accountRepo.createAccount(Account(
          id: 'acc_card_secondary',
          name: 'ICICI Coral Card',
          type: AccountType.liability,
          category: 'credit_card',
          createdAt: now,
          updatedAt: now,
        ));
        await accountRepo.createAccount(Account(
          id: 'acc_loan_secondary',
          name: 'Personal Loan',
          type: AccountType.liability,
          category: 'loan',
          createdAt: now,
          updatedAt: now,
        ));
      });

      test('6.1 Rejection of account transfers', () async {
        final now = DateTime.now();
        await db.insert(Tables.recurring_templates, {
          'id': 'rec_netflix_xfer_test',
          'name': 'Netflix Subscription',
          'amount': 199.0,
          'type': 'expense',
          'frequency': 'monthly',
          'next_generation': now.toIso8601String(),
          'is_active': 1,
          'created_at': now.toIso8601String(),
        });

        // Insert transfer event: debit asset (bank), credit asset (cash)
        final xferId = 'ev_xfer_netflix';
        final iso = now.toIso8601String();
        await db.insert(TablesV24.economicEvents, {
          'id': xferId,
          'event_type': 'transfer',
          'lifecycle_status': 'draft',
          'timestamp': iso,
          'currency': 'INR',
          'description': 'Netflix Subscription Transfer',
          'merchant_normalized': 'netflix subscription transfer',
          'created_at': iso,
          'updated_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${xferId}_dr',
          'economic_event_id': xferId,
          'account_id': 'acc_bank_secondary',
          'direction': 'debit',
          'amount_minor_units': 19900,
          'created_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${xferId}_cr',
          'economic_event_id': xferId,
          'account_id': 'acc_cash_default',
          'direction': 'credit',
          'amount_minor_units': 19900,
          'created_at': iso,
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted', 'updated_at': iso},
          where: 'id = ?',
          whereArgs: [xferId],
        );
        await db.insert(Tables.transactions, {
          'id': xferId,
          'user_id': 'u1',
          'amount': 199.0,
          'type': 'transfer',
          'date': iso,
          'notes': 'Netflix Subscription Transfer',
          'created_at': iso,
          'updated_at': iso,
          'is_deleted': 0,
        });

        final settlement = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 199.0,
          templateName: 'Netflix Subscription',
          frequency: 'monthly',
        );

        expect(settlement.isSettled, isFalse, reason: 'Transfers must never settle recurring expenses');
        expect(settlement.matchedTxnId, isNull);

        final calc = await queryRepo.getSafeToSpend();
        final netflix = calc.commitmentItems.where((c) => c.title == 'Netflix Subscription').firstOrNull;
        expect(netflix, isNotNull, reason: 'Obligation must remain active and unpaid');
      });

      test('6.2 Rejection of credit-card bill payments', () async {
        final now = DateTime.now();
        await db.insert(Tables.recurring_templates, {
          'id': 'rec_netflix_cc_pay_test',
          'name': 'Netflix Plan',
          'amount': 199.0,
          'type': 'expense',
          'frequency': 'monthly',
          'next_generation': now.toIso8601String(),
          'is_active': 1,
          'created_at': now.toIso8601String(),
        });

        // Insert liability settlement: debit liability (card), credit asset (cash)
        final ccPayId = 'ev_cc_pay_netflix';
        final iso = now.toIso8601String();
        await db.insert(TablesV24.economicEvents, {
          'id': ccPayId,
          'event_type': 'liability_settlement',
          'lifecycle_status': 'draft',
          'timestamp': iso,
          'currency': 'INR',
          'description': 'Netflix Plan CC Bill Payment',
          'merchant_normalized': 'netflix plan cc bill payment',
          'created_at': iso,
          'updated_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${ccPayId}_dr',
          'economic_event_id': ccPayId,
          'account_id': 'acc_card_secondary',
          'direction': 'debit',
          'amount_minor_units': 19900,
          'created_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${ccPayId}_cr',
          'economic_event_id': ccPayId,
          'account_id': 'acc_cash_default',
          'direction': 'credit',
          'amount_minor_units': 19900,
          'created_at': iso,
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted', 'updated_at': iso},
          where: 'id = ?',
          whereArgs: [ccPayId],
        );
        await db.insert(Tables.transactions, {
          'id': ccPayId,
          'user_id': 'u1',
          'amount': 199.0,
          'type': 'credit_payment',
          'date': iso,
          'notes': 'Netflix Plan CC Bill Payment',
          'created_at': iso,
          'updated_at': iso,
          'is_deleted': 0,
        });

        final settlement = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 199.0,
          templateName: 'Netflix Plan',
          frequency: 'monthly',
        );

        expect(settlement.isSettled, isFalse, reason: 'Credit card bill payments must never settle recurring expenses');
        expect(settlement.matchedTxnId, isNull);
      });

      test('6.3 Rejection of refunds', () async {
        final now = DateTime.now();
        await db.insert(Tables.recurring_templates, {
          'id': 'rec_spotify_refund_test',
          'name': 'Spotify Premium',
          'amount': 179.0,
          'type': 'expense',
          'frequency': 'monthly',
          'next_generation': now.toIso8601String(),
          'is_active': 1,
          'created_at': now.toIso8601String(),
        });

        // Insert refund: debit asset (bank), credit expense
        final refundId = 'ev_refund_spotify';
        final iso = now.toIso8601String();
        await db.insert(TablesV24.economicEvents, {
          'id': refundId,
          'event_type': 'refund',
          'lifecycle_status': 'draft',
          'timestamp': iso,
          'currency': 'INR',
          'description': 'Spotify Premium Refund',
          'merchant_normalized': 'spotify premium refund',
          'created_at': iso,
          'updated_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${refundId}_dr',
          'economic_event_id': refundId,
          'account_id': 'acc_cash_default',
          'direction': 'debit',
          'amount_minor_units': 17900,
          'created_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${refundId}_cr',
          'economic_event_id': refundId,
          'account_id': 'acc_expense_general',
          'direction': 'credit',
          'amount_minor_units': 17900,
          'created_at': iso,
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted', 'updated_at': iso},
          where: 'id = ?',
          whereArgs: [refundId],
        );
        await db.insert(Tables.transactions, {
          'id': refundId,
          'user_id': 'u1',
          'amount': 179.0,
          'type': 'refund',
          'date': iso,
          'notes': 'Spotify Premium Refund',
          'created_at': iso,
          'updated_at': iso,
          'is_deleted': 0,
        });

        final settlement = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 179.0,
          templateName: 'Spotify Premium',
          frequency: 'monthly',
        );

        expect(settlement.isSettled, isFalse, reason: 'Refunds must never settle recurring expenses');
        expect(settlement.matchedTxnId, isNull);
      });

      test('6.4 Rejection of reversals (both reversal event and reversed original event)', () async {
        final now = DateTime.now();
        await db.insert(Tables.recurring_templates, {
          'id': 'rec_youtube_rev_test',
          'name': 'YouTube Family',
          'amount': 299.0,
          'type': 'expense',
          'frequency': 'monthly',
          'next_generation': now.toIso8601String(),
          'is_active': 1,
          'created_at': now.toIso8601String(),
        });

        // 1. Original event that was reversed
        final origId = 'ev_yt_orig_reversed';
        final revId = 'ev_yt_reversal_posted';
        final iso = now.toIso8601String();

        await db.insert(TablesV24.economicEvents, {
          'id': origId,
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'timestamp': iso,
          'currency': 'INR',
          'description': 'YouTube Family Membership',
          'merchant_normalized': 'youtube family membership',
          'created_at': iso,
          'updated_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${origId}_dr',
          'economic_event_id': origId,
          'account_id': 'acc_expense_general',
          'direction': 'debit',
          'amount_minor_units': 29900,
          'created_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${origId}_cr',
          'economic_event_id': origId,
          'account_id': 'acc_cash_default',
          'direction': 'credit',
          'amount_minor_units': 29900,
          'created_at': iso,
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted', 'updated_at': iso},
          where: 'id = ?',
          whereArgs: [origId],
        );

        // 2. Reversal event posted to reverse origId
        await db.insert(TablesV24.economicEvents, {
          'id': revId,
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'timestamp': iso,
          'currency': 'INR',
          'description': 'REVERSAL: YouTube Family Membership',
          'merchant_normalized': 'reversal youtube family membership',
          'reversal_of_event_id': origId,
          'created_at': iso,
          'updated_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${revId}_dr',
          'economic_event_id': revId,
          'account_id': 'acc_cash_default',
          'direction': 'debit',
          'amount_minor_units': 29900,
          'created_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${revId}_cr',
          'economic_event_id': revId,
          'account_id': 'acc_expense_general',
          'direction': 'credit',
          'amount_minor_units': 29900,
          'created_at': iso,
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted', 'updated_at': iso},
          where: 'id = ?',
          whereArgs: [revId],
        );

        final settlement = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 299.0,
          templateName: 'YouTube Family',
          frequency: 'monthly',
        );

        expect(settlement.isSettled, isFalse, reason: 'Reversals and reversed transactions must be rejected');
        expect(settlement.matchedTxnId, isNull);
      });

      test('6.5 Rejection of loan payments and loan-interest events unless explicitly valid', () async {
        final now = DateTime.now();

        // Template A: Regular gym expense
        await db.insert(Tables.recurring_templates, {
          'id': 'rec_gym_not_loan',
          'name': 'Gym Membership',
          'amount': 2500.0,
          'type': 'expense',
          'frequency': 'monthly',
          'next_generation': now.toIso8601String(),
          'is_active': 1,
          'created_at': now.toIso8601String(),
        });

        // Insert a loan payment event for ₹2500
        final loanPayId = 'ev_gym_loan_pay';
        final iso = now.toIso8601String();
        await db.insert(TablesV24.economicEvents, {
          'id': loanPayId,
          'event_type': 'loan_payment',
          'lifecycle_status': 'draft',
          'timestamp': iso,
          'currency': 'INR',
          'description': 'Gym Membership Loan Payment',
          'merchant_normalized': 'gym membership loan payment',
          'created_at': iso,
          'updated_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${loanPayId}_dr_prin',
          'economic_event_id': loanPayId,
          'account_id': 'acc_loan_secondary',
          'direction': 'debit',
          'amount_minor_units': 200000,
          'created_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${loanPayId}_dr_int',
          'economic_event_id': loanPayId,
          'account_id': TablesV24.sysExpInterest,
          'direction': 'debit',
          'amount_minor_units': 50000,
          'created_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${loanPayId}_cr',
          'economic_event_id': loanPayId,
          'account_id': 'acc_cash_default',
          'direction': 'credit',
          'amount_minor_units': 250000,
          'created_at': iso,
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted', 'updated_at': iso},
          where: 'id = ?',
          whereArgs: [loanPayId],
        );

        final gymSettlement = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 2500.0,
          templateName: 'Gym Membership',
          frequency: 'monthly',
        );

        expect(gymSettlement.isSettled, isFalse, reason: 'Standard expense cannot be settled by loan payment');

        // Template B: Explicit loan template
        await db.insert(Tables.recurring_templates, {
          'id': 'rec_explicit_loan',
          'name': 'Home Loan EMI',
          'amount': 25000.0,
          'type': 'expense',
          'frequency': 'monthly',
          'next_generation': now.toIso8601String(),
          'is_active': 1,
          'created_at': now.toIso8601String(),
        });

        final emiPayId = 'ev_home_loan_emi';
        await db.insert(TablesV24.economicEvents, {
          'id': emiPayId,
          'event_type': 'loan_payment',
          'lifecycle_status': 'draft',
          'timestamp': iso,
          'currency': 'INR',
          'description': 'Home Loan EMI Payment',
          'merchant_normalized': 'home loan emi payment',
          'created_at': iso,
          'updated_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${emiPayId}_dr_prin',
          'economic_event_id': emiPayId,
          'account_id': 'acc_loan_secondary',
          'direction': 'debit',
          'amount_minor_units': 2000000,
          'created_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${emiPayId}_dr_int',
          'economic_event_id': emiPayId,
          'account_id': TablesV24.sysExpInterest,
          'direction': 'debit',
          'amount_minor_units': 500000,
          'created_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${emiPayId}_cr',
          'economic_event_id': emiPayId,
          'account_id': 'acc_cash_default',
          'direction': 'credit',
          'amount_minor_units': 2500000,
          'created_at': iso,
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted', 'updated_at': iso},
          where: 'id = ?',
          whereArgs: [emiPayId],
        );

        final emiSettlement = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 25000.0,
          templateName: 'Home Loan EMI',
          frequency: 'monthly',
        );

        expect(emiSettlement.isSettled, isTrue, reason: 'Explicit loan template can be settled by loan payment');
        expect(emiSettlement.matchedTxnId, emiPayId);
      });

      test('6.6 Rejection of pending, draft, or unposted economic events', () async {
        final now = DateTime.now();
        await db.insert(Tables.recurring_templates, {
          'id': 'rec_draft_test',
          'name': 'Cloud Server',
          'amount': 800.0,
          'type': 'expense',
          'frequency': 'monthly',
          'next_generation': now.toIso8601String(),
          'is_active': 1,
          'created_at': now.toIso8601String(),
        });

        // Insert event with draft status
        final draftId = 'ev_draft_server';
        final iso = now.toIso8601String();
        await db.insert(TablesV24.economicEvents, {
          'id': draftId,
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'timestamp': iso,
          'currency': 'INR',
          'description': 'Cloud Server Hosting',
          'merchant_normalized': 'cloud server hosting',
          'created_at': iso,
          'updated_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${draftId}_dr',
          'economic_event_id': draftId,
          'account_id': 'acc_expense_general',
          'direction': 'debit',
          'amount_minor_units': 80000,
          'created_at': iso,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_${draftId}_cr',
          'economic_event_id': draftId,
          'account_id': 'acc_cash_default',
          'direction': 'credit',
          'amount_minor_units': 80000,
          'created_at': iso,
        });

        final settlement = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 800.0,
          templateName: 'Cloud Server',
          frequency: 'monthly',
        );

        expect(settlement.isSettled, isFalse, reason: 'Draft/unposted events must never settle recurring obligations');
      });

      test('6.7 Duplicate evidence records for the same underlying transaction', () async {
        final now = DateTime.now();
        await db.insert(Tables.recurring_templates, {
          'id': 'rec_multi_ev_test',
          'name': 'Broadband Fiber',
          'amount': 999.0,
          'type': 'expense',
          'frequency': 'monthly',
          'next_generation': now.toIso8601String(),
          'is_active': 1,
          'created_at': now.toIso8601String(),
        });

        final evId = 'ev_broadband_multi_evidence';
        await insertV24Expense(
          id: evId,
          description: 'Broadband Fiber Bill',
          amountRupees: 999.0,
          timestamp: now,
        );

        // Add 3 separate evidence records pointing to the same economic event
        final iso = now.toIso8601String();
        await db.insert(TablesV24.evidence, {
          'id': 'evi_sms_1',
          'economic_event_id': evId,
          'source_type': 'sms',
          'extracted_amount_minor_units': 99900,
          'extracted_timestamp': iso,
          'body_sha256': 'hash1',
          'created_at': iso,
        });
        await db.insert(TablesV24.evidence, {
          'id': 'evi_ocr_2',
          'economic_event_id': evId,
          'source_type': 'ocr',
          'extracted_amount_minor_units': 99900,
          'extracted_timestamp': iso,
          'body_sha256': 'hash2',
          'created_at': iso,
        });
        await db.insert(TablesV24.evidence, {
          'id': 'evi_manual_3',
          'economic_event_id': evId,
          'source_type': 'manual',
          'extracted_amount_minor_units': 99900,
          'extracted_timestamp': iso,
          'body_sha256': 'hash3',
          'created_at': iso,
        });

        final usedTxnIds = <String>{};
        final settlement = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 999.0,
          templateName: 'Broadband Fiber',
          frequency: 'monthly',
          usedTxnIds: usedTxnIds,
        );

        expect(settlement.isSettled, isTrue);
        expect(settlement.matchedTxnId, evId);
        expect(usedTxnIds.length, 1, reason: 'Exactly one transaction ID claimed despite multiple evidence records');
      });

      test('6.8 Amount tolerance exact boundary tests (±₹1.00 accept vs ±₹1.01 reject)', () async {
        final now = DateTime.now();

        // Case A: diff = -₹1.00 (₹198.00 vs ₹199.00) -> ACCEPTED
        await insertV24Expense(
          id: 'tx_boundary_minus_1',
          description: 'BoundaryAlpha Payment',
          amountRupees: 198.00,
          timestamp: now,
        );
        final matchMinus1 = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 199.00,
          templateName: 'BoundaryAlpha',
          frequency: 'monthly',
        );
        expect(matchMinus1.isSettled, isTrue, reason: 'Difference of -₹1.00 is exactly within ±₹1.00 boundary');

        // Case B: diff = +₹1.00 (₹200.00 vs ₹199.00) -> ACCEPTED
        await insertV24Expense(
          id: 'tx_boundary_plus_1',
          description: 'BoundaryBeta Payment',
          amountRupees: 200.00,
          timestamp: now,
        );
        final matchPlus1 = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 199.00,
          templateName: 'BoundaryBeta',
          frequency: 'monthly',
        );
        expect(matchPlus1.isSettled, isTrue, reason: 'Difference of +₹1.00 is exactly within ±₹1.00 boundary');

        // Case C: diff = -₹1.01 (₹197.99 vs ₹199.00) -> REJECTED
        await insertV24Expense(
          id: 'tx_boundary_minus_1_01',
          description: 'BoundaryGamma Payment',
          amountRupees: 197.99,
          timestamp: now,
        );
        final matchMinus101 = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 199.00,
          templateName: 'BoundaryGamma',
          frequency: 'monthly',
        );
        expect(matchMinus101.isSettled, isFalse, reason: 'Difference of -₹1.01 exceeds ±₹1.00 tolerance and must be rejected');

        // Case D: diff = +₹1.01 (₹200.01 vs ₹199.00) -> REJECTED
        await insertV24Expense(
          id: 'tx_boundary_plus_1_01',
          description: 'BoundaryDelta Payment',
          amountRupees: 200.01,
          timestamp: now,
        );
        final matchPlus101 = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 199.00,
          templateName: 'BoundaryDelta',
          frequency: 'monthly',
        );
        expect(matchPlus101.isSettled, isFalse, reason: 'Difference of +₹1.01 exceeds ±₹1.00 tolerance and must be rejected');
      });

      test('6.9 Ambiguity and diagnostic identification of matched transaction', () async {
        final now = DateTime.now();

        // Insert candidate A: 5 days away
        await insertV24Expense(
          id: 'tx_diag_candidate_far',
          description: 'Airtel Broadband',
          amountRupees: 1199.0,
          timestamp: now.subtract(const Duration(days: 5)),
        );

        // Insert candidate B: exactly on due date
        await insertV24Expense(
          id: 'tx_diag_candidate_exact',
          description: 'Airtel Broadband',
          amountRupees: 1199.0,
          timestamp: now,
        );

        final usedTxnIds = <String>{};
        final match = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 1199.0,
          templateName: 'Airtel Broadband',
          frequency: 'monthly',
          usedTxnIds: usedTxnIds,
        );

        expect(match.isSettled, isTrue);
        expect(match.matchedTxnId, 'tx_diag_candidate_exact', reason: 'Closest candidate deterministically selected');
        expect(usedTxnIds.contains('tx_diag_candidate_exact'), isTrue);

        // Unrelated purchase cannot settle and cannot cause genuine upcoming commitment to disappear
        final unrelated = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 1199.0,
          templateName: 'Water Utility Bill',
          frequency: 'monthly',
          usedTxnIds: usedTxnIds,
        );
        expect(unrelated.isSettled, isFalse);
        expect(unrelated.matchedTxnId, isNull);
      });

      test('6.10 Ambiguity resolution: two templates with identical amounts, one generic gateway transaction -> both remain visible', () async {
        final now = DateTime.now();

        // Template 1: Netflix ₹199
        await db.insert(Tables.recurring_templates, {
          'id': 'rec_netflix_ambig',
          'name': 'Netflix Standard',
          'amount': 199.0,
          'type': 'expense',
          'frequency': 'monthly',
          'next_generation': now.toIso8601String(),
          'is_active': 1,
          'created_at': now.toIso8601String(),
        });

        // Template 2: YouTube ₹199
        await db.insert(Tables.recurring_templates, {
          'id': 'rec_youtube_ambig',
          'name': 'YouTube Premium',
          'amount': 199.0,
          'type': 'expense',
          'frequency': 'monthly',
          'next_generation': now.toIso8601String(),
          'is_active': 1,
          'created_at': now.toIso8601String(),
        });

        // One generic gateway transaction: ₹199, generic description, no merchant tokens
        await insertV24Expense(
          id: 'tx_generic_gateway_199',
          description: 'Razorpay PG Payment',
          amountRupees: 199.0,
          timestamp: now,
        );

        final calc = await queryRepo.getSafeToSpend();
        final netflix = calc.commitmentItems.where((c) => c.title == 'Netflix Standard').firstOrNull;
        final youtube = calc.commitmentItems.where((c) => c.title == 'YouTube Premium').firstOrNull;

        expect(netflix, isNotNull, reason: 'Netflix must NOT be settled by a generic gateway transaction lacking merchant tokens');
        expect(youtube, isNotNull, reason: 'YouTube must NOT be settled by a generic gateway transaction lacking merchant tokens');
        expect(calc.knownCommitments14d.toRupees, 398.0, reason: 'Both ₹199 obligations (total ₹398) must remain active and visible');
      });

      test('6.11 Semantic check of corrected events (original superseded, replacement valid)', () async {
        final now = DateTime.now();

        // 1. Original event that was corrected/superseded by replEventId
        final origEventId = 'ev_corrected_orig';
        final replEventId = 'ev_corrected_repl';

        await insertV24Expense(
          id: origEventId,
          description: 'Hosting Subscription Old',
          amountRupees: 500.0,
          timestamp: now,
        );

        // Mark the original event as corrected by replEventId
        await db.update(
          TablesV24.economicEvents,
          {'corrected_by_event_id': replEventId},
          where: 'id = ?',
          whereArgs: [origEventId],
        );

        final origSettlement = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 500.0,
          templateName: 'Hosting Subscription Old',
          frequency: 'monthly',
        );

        expect(origSettlement.isSettled, isFalse, reason: 'Original event with corrected_by_event_id != null must be rejected');

        // 2. Replacement event that has corrected_by_event_id = null
        await insertV24Expense(
          id: replEventId,
          description: 'Hosting Subscription Active',
          amountRupees: 500.0,
          timestamp: now,
        );

        final replSettlement = await queryRepo.checkRecurringOccurrenceSettlement(
          db: db,
          occDate: now,
          amount: 500.0,
          templateName: 'Hosting Subscription Active',
          frequency: 'monthly',
        );

        expect(replSettlement.isSettled, isTrue, reason: 'Valid replacement event with corrected_by_event_id == null must be accepted');
        expect(replSettlement.matchedTxnId, replEventId);
      });
    });
  });
}
