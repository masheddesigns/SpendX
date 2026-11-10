import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/credit_card.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone 5.0 Phase 4 — Group C: DEF-517 Safe-to-Spend Partial Payments', () {
    late Database db;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CreditRepo creditRepo;

    Future<void> recordBalancedTransaction({
      required String eventId,
      required String debitAccountId,
      required String creditAccountId,
      required int amountMinorUnits,
      required DateTime timestampUtc,
      required String eventType,
      String? description,
    }) async {
      final now = timestampUtc.toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': eventId,
        'event_type': eventType,
        'lifecycle_status': 'draft',
        'timestamp': now,
        'description': description ?? 'Test event $eventId',
        'created_at': now,
        'updated_at': now,
      });

      await db.insert(TablesV24.postings, {
        'id': 'pst_${eventId}_deb',
        'economic_event_id': eventId,
        'account_id': debitAccountId,
        'direction': 'debit',
        'amount_minor_units': amountMinorUnits,
        'created_at': now,
      });

      await db.insert(TablesV24.postings, {
        'id': 'pst_${eventId}_crd',
        'economic_event_id': eventId,
        'account_id': creditAccountId,
        'direction': 'credit',
        'amount_minor_units': amountMinorUnits,
        'created_at': now,
      });

      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [eventId],
      );
    }

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

      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      creditRepo = CreditRepo(executor: db);

      // Create primary bank account with ₹50,000 initial liquid balance
      final now = DateTime.now();
      await canonicalAccountRepo.createAccount(
        Account(
          id: 'acc_bank_primary',
          name: 'Primary Checking',
          type: AccountType.asset,
          category: 'bank',
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Seed bank asset: ₹50,000 (5,000,000 minor units)
      await recordBalancedTransaction(
        eventId: 'evt_bank_init',
        debitAccountId: 'acc_bank_primary',
        creditAccountId: TablesV24.sysEquityOpening,
        amountMinorUnits: 5000000,
        timestampUtc: now.toUtc().subtract(const Duration(days: 10)),
        eventType: 'opening_balance',
        description: 'Opening balance checking',
      );
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // C.1: Unpaid ₹5,000 statement -> commitment ₹5,000
    // -------------------------------------------------------------------------
    test('C.1: Unpaid ₹5,000 statement produces ₹5,000 commitment and preserves Safe-to-Spend', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 5) % 28 + 1;

      final card = CreditCard(
        id: 'card_c1',
        name: 'HDFC Regalia',
        bank: 'HDFC',
        last4: '1111',
        limitAmount: 100000,
        dueDay: dueDay,
        lastStatementBalance: 5000.0,
      );
      await creditRepo.insert(card);

      final dueDate = now.add(const Duration(days: 5));
      await db.insert(Tables.reminders, {
        'id': 'rem_c1',
        'title': 'HDFC Credit Card Bill',
        'amount': 5000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c1',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      final calc = await canonicalQueryRepo.getSafeToSpend();

      expect(calc.liquidAssets.toRupees, equals(50000.0));
      expect(calc.knownCommitments14d.toRupees, equals(5000.0));
      expect(calc.safeToSpend.toRupees, equals(45000.0));
      expect(calc.commitmentItems.length, equals(1));
      expect(calc.commitmentItems.first.amount.toRupees, equals(5000.0));
      expect(calc.commitmentItems.first.type, equals('credit_card'));
    });

    // -------------------------------------------------------------------------
    // C.2: Partial payment ₹2,000 -> commitment ₹3,000 (DEF-517 Core Parity)
    // -------------------------------------------------------------------------
    test('C.2: Partial payment ₹2,000 reduces commitment to ₹3,000 without double deduction', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 5) % 28 + 1;

      final card = CreditCard(
        id: 'card_c2',
        name: 'ICICI Sapphiro',
        bank: 'ICICI',
        last4: '2222',
        limitAmount: 100000,
        dueDay: dueDay,
        lastStatementBalance: 5000.0,
      );
      await creditRepo.insert(card);

      final dueDate = now.add(const Duration(days: 5));
      await db.insert(Tables.reminders, {
        'id': 'rem_c2',
        'title': 'ICICI Credit Card Bill',
        'amount': 5000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c2',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      // Partial payment: ₹2,000 from Primary Checking to ICICI Card
      await recordBalancedTransaction(
        eventId: 'evt_pay_c2',
        debitAccountId: 'card_c2',
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 200000, // ₹2,000
        timestampUtc: now.toUtc().subtract(const Duration(days: 1)),
        eventType: 'liability_settlement',
        description: 'Partial payment ICICI card',
      );

      final calc = await canonicalQueryRepo.getSafeToSpend();

      // Liquid assets reduced by ₹2,000 payment: ₹50,000 -> ₹48,000
      expect(calc.liquidAssets.toRupees, equals(48000.0));
      // Remaining commitment reduced by ₹2,000: ₹5,000 -> ₹3,000
      expect(calc.knownCommitments14d.toRupees, equals(3000.0));
      // Safe-to-Spend remains ₹45,000 (48,000 - 3,000 = 45,000) — NO DOUBLE DEDUCTION!
      expect(calc.safeToSpend.toRupees, equals(45000.0));
      expect(calc.commitmentItems.length, equals(1));
      expect(calc.commitmentItems.first.amount.toRupees, equals(3000.0));
    });

    // -------------------------------------------------------------------------
    // C.3: Full payment ₹5,000 -> commitment ₹0
    // -------------------------------------------------------------------------
    test('C.3: Full payment ₹5,000 reduces commitment to ₹0', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 5) % 28 + 1;

      final card = CreditCard(
        id: 'card_c3',
        name: 'Axis Magnus',
        bank: 'Axis',
        last4: '3333',
        limitAmount: 150000,
        dueDay: dueDay,
        lastStatementBalance: 5000.0,
      );
      await creditRepo.insert(card);

      final dueDate = now.add(const Duration(days: 5));
      await db.insert(Tables.reminders, {
        'id': 'rem_c3',
        'title': 'Axis Credit Card Bill',
        'amount': 5000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c3',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      // Full payment: ₹5,000 from Primary Checking to Axis Card
      await recordBalancedTransaction(
        eventId: 'evt_pay_c3',
        debitAccountId: 'card_c3',
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 500000, // ₹5,000
        timestampUtc: now.toUtc().subtract(const Duration(days: 1)),
        eventType: 'liability_settlement',
        description: 'Full payment Axis card',
      );

      final calc = await canonicalQueryRepo.getSafeToSpend();

      // Liquid assets reduced by ₹5,000: ₹50,000 -> ₹45,000
      expect(calc.liquidAssets.toRupees, equals(45000.0));
      // Commitment fully cleared: ₹0
      expect(calc.knownCommitments14d.toRupees, equals(0.0));
      // Safe-to-Spend is ₹45,000
      expect(calc.safeToSpend.toRupees, equals(45000.0));
      expect(calc.commitmentItems, isEmpty);
    });

    // -------------------------------------------------------------------------
    // C.4: Overpayment -> commitment ₹0, never negative
    // -------------------------------------------------------------------------
    test('C.4: Overpayment of ₹6,000 on ₹5,000 statement clamps commitment to ₹0, never negative', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 5) % 28 + 1;

      final card = CreditCard(
        id: 'card_c4',
        name: 'SBI Elite',
        bank: 'SBI',
        last4: '4444',
        limitAmount: 100000,
        dueDay: dueDay,
        lastStatementBalance: 5000.0,
      );
      await creditRepo.insert(card);

      final dueDate = now.add(const Duration(days: 5));
      await db.insert(Tables.reminders, {
        'id': 'rem_c4',
        'title': 'SBI Credit Card Bill',
        'amount': 5000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c4',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      // Overpayment: ₹6,000 from Primary Checking to SBI Card
      await recordBalancedTransaction(
        eventId: 'evt_pay_c4',
        debitAccountId: 'card_c4',
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 600000, // ₹6,000
        timestampUtc: now.toUtc().subtract(const Duration(days: 1)),
        eventType: 'liability_settlement',
        description: 'Overpayment SBI card',
      );

      final calc = await canonicalQueryRepo.getSafeToSpend();

      // Liquid assets reduced by ₹6,000: ₹50,000 -> ₹44,000
      expect(calc.liquidAssets.toRupees, equals(44000.0));
      // Commitment clamped at ₹0, never negative
      expect(calc.knownCommitments14d.toRupees, equals(0.0));
      expect(calc.safeToSpend.toRupees, equals(44000.0));
      expect(calc.commitmentItems, isEmpty);
    });

    // -------------------------------------------------------------------------
    // C.5: Payment belonging to another card -> no reduction
    // -------------------------------------------------------------------------
    test('C.5: Payment belonging to Card B does not reduce Card A commitment', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 5) % 28 + 1;

      final cardA = CreditCard(
        id: 'card_c5_a',
        name: 'HDFC Millennia',
        bank: 'HDFC',
        last4: '5551',
        limitAmount: 100000,
        dueDay: dueDay,
        lastStatementBalance: 5000.0,
      );
      final cardB = CreditCard(
        id: 'card_c5_b',
        name: 'HDFC Swiggy',
        bank: 'HDFC',
        last4: '5552',
        limitAmount: 50000,
        dueDay: dueDay,
        lastStatementBalance: 3000.0,
      );
      await creditRepo.insert(cardA);
      await creditRepo.insert(cardB);

      final dueDate = now.add(const Duration(days: 5));
      await db.insert(Tables.reminders, {
        'id': 'rem_c5_a',
        'title': 'HDFC Millennia Bill',
        'amount': 5000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c5_a',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      await db.insert(Tables.reminders, {
        'id': 'rem_c5_b',
        'title': 'HDFC Swiggy Bill',
        'amount': 3000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c5_b',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      // Settle Card B completely with ₹3,000 payment
      await recordBalancedTransaction(
        eventId: 'evt_pay_c5_b',
        debitAccountId: 'card_c5_b',
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 300000, // ₹3,000
        timestampUtc: now.toUtc().subtract(const Duration(days: 1)),
        eventType: 'liability_settlement',
        description: 'Payment HDFC Swiggy',
      );

      final calc = await canonicalQueryRepo.getSafeToSpend();

      // Liquid assets: ₹50,000 - ₹3,000 = ₹47,000
      expect(calc.liquidAssets.toRupees, equals(47000.0));
      // Card A is unpaid (₹5,000), Card B is fully paid (₹0). Total commitment = ₹5,000
      expect(calc.knownCommitments14d.toRupees, equals(5000.0));
      expect(calc.safeToSpend.toRupees, equals(42000.0));
      expect(calc.commitmentItems.length, equals(1));
      expect(calc.commitmentItems.first.title, contains('Millennia'));
      expect(calc.commitmentItems.first.amount.toRupees, equals(5000.0));
    });

    // -------------------------------------------------------------------------
    // C.6: Payment belonging to another statement/cycle -> no reduction
    // -------------------------------------------------------------------------
    test('C.6: Payment from previous billing cycle does not reduce current statement commitment', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 5) % 28 + 1;

      final card = CreditCard(
        id: 'card_c6',
        name: 'Amex SmartEarn',
        bank: 'Amex',
        last4: '6666',
        limitAmount: 100000,
        dueDay: dueDay,
        lastStatementBalance: 5000.0,
      );
      await creditRepo.insert(card);

      final dueDate = now.add(const Duration(days: 5));
      await db.insert(Tables.reminders, {
        'id': 'rem_c6',
        'title': 'Amex Credit Card Bill',
        'amount': 5000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c6',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      // Payment made 40 days ago (previous cycle)
      await recordBalancedTransaction(
        eventId: 'evt_pay_c6_old',
        debitAccountId: 'card_c6',
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 500000,
        timestampUtc: now.toUtc().subtract(const Duration(days: 40)),
        eventType: 'liability_settlement',
        description: 'Previous month Amex payment',
      );

      final calc = await canonicalQueryRepo.getSafeToSpend();

      // Current statement remains fully outstanding: ₹5,000
      expect(calc.knownCommitments14d.toRupees, equals(5000.0));
      expect(calc.commitmentItems.length, equals(1));
      expect(calc.commitmentItems.first.amount.toRupees, equals(5000.0));
    });

    // -------------------------------------------------------------------------
    // C.7: New purchases after statement close -> not removed from original commitment
    // -------------------------------------------------------------------------
    test('C.7: New purchases after statement close do not alter statement commitment', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 5) % 28 + 1;

      final card = CreditCard(
        id: 'card_c7',
        name: 'OneCard',
        bank: 'Federal Bank',
        last4: '7777',
        limitAmount: 100000,
        dueDay: dueDay,
        lastStatementBalance: 5000.0,
      );
      await creditRepo.insert(card);

      final dueDate = now.add(const Duration(days: 5));
      await db.insert(Tables.reminders, {
        'id': 'rem_c7',
        'title': 'OneCard Bill',
        'amount': 5000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c7',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      // Partial payment: ₹2,000
      await recordBalancedTransaction(
        eventId: 'evt_pay_c7',
        debitAccountId: 'card_c7',
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 200000,
        timestampUtc: now.toUtc().subtract(const Duration(days: 2)),
        eventType: 'liability_settlement',
        description: 'Partial payment OneCard',
      );

      // New post-statement purchase: ₹10,000 (Dr Expense, Cr Card Liability)
      await recordBalancedTransaction(
        eventId: 'evt_pur_c7',
        debitAccountId: TablesV24.sysExpMisc,
        creditAccountId: 'card_c7',
        amountMinorUnits: 1000000, // ₹10,000
        timestampUtc: now.toUtc().subtract(const Duration(hours: 5)),
        eventType: 'credit_purchase',
        description: 'New laptop purchase after statement close',
      );

      final calc = await canonicalQueryRepo.getSafeToSpend();

      // Liquid assets: ₹50,000 - ₹2,000 = ₹48,000
      expect(calc.liquidAssets.toRupees, equals(48000.0));
      // Commitment is strictly the remaining statement obligation: ₹5,000 - ₹2,000 = ₹3,000
      // The ₹10,000 purchase does not inflate or reduce this statement obligation
      expect(calc.knownCommitments14d.toRupees, equals(3000.0));
      expect(calc.safeToSpend.toRupees, equals(45000.0));
      expect(calc.commitmentItems.first.amount.toRupees, equals(3000.0));
    });

    // -------------------------------------------------------------------------
    // C.8: Refund or credit adjustment -> correct statement obligation
    // -------------------------------------------------------------------------
    test('C.8: Merchant refund credited to card correctly reduces statement obligation', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 5) % 28 + 1;

      final card = CreditCard(
        id: 'card_c8',
        name: 'Kotak White',
        bank: 'Kotak',
        last4: '8888',
        limitAmount: 100000,
        dueDay: dueDay,
        lastStatementBalance: 5000.0,
      );
      await creditRepo.insert(card);

      final dueDate = now.add(const Duration(days: 5));
      await db.insert(Tables.reminders, {
        'id': 'rem_c8',
        'title': 'Kotak White Bill',
        'amount': 5000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c8',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      // Merchant refund credited to card: ₹1,500 (Dr Card Liability, Cr Contra-Expense)
      await recordBalancedTransaction(
        eventId: 'evt_ref_c8',
        debitAccountId: 'card_c8',
        creditAccountId: TablesV24.sysExpRefunds,
        amountMinorUnits: 150000, // ₹1,500
        timestampUtc: now.toUtc().subtract(const Duration(days: 2)),
        eventType: 'refund',
        description: 'Merchant return refund Kotak',
      );

      final calc = await canonicalQueryRepo.getSafeToSpend();

      // Bank account liquid assets are NOT reduced by a card refund: ₹50,000
      expect(calc.liquidAssets.toRupees, equals(50000.0));
      // Remaining statement commitment: ₹5,000 - ₹1,500 = ₹3,500
      expect(calc.knownCommitments14d.toRupees, equals(3500.0));
      // Safe-to-Spend increases by ₹1,500: ₹50,000 - ₹3,500 = ₹46,500
      expect(calc.safeToSpend.toRupees, equals(46500.0));
      expect(calc.commitmentItems.first.amount.toRupees, equals(3500.0));
    });

    // -------------------------------------------------------------------------
    // C.9: Reminder-backed and direct paths -> exactly one commitment
    // -------------------------------------------------------------------------
    test('C.9: Reminder-backed and direct paths deduplicate to exactly one commitment', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 5) % 28 + 1;

      final card = CreditCard(
        id: 'card_c9',
        name: 'IndusInd Legend',
        bank: 'IndusInd',
        last4: '9999',
        limitAmount: 100000,
        dueDay: dueDay,
        lastStatementBalance: 5000.0,
      );
      await creditRepo.insert(card);

      final dueDate = now.add(const Duration(days: 5));
      await db.insert(Tables.reminders, {
        'id': 'rem_c9',
        'title': 'IndusInd Credit Card Bill',
        'amount': 5000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c9',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      // Partial payment: ₹2,000
      await recordBalancedTransaction(
        eventId: 'evt_pay_c9',
        debitAccountId: 'card_c9',
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 200000, // ₹2,000
        timestampUtc: now.toUtc().subtract(const Duration(days: 1)),
        eventType: 'liability_settlement',
        description: 'Payment IndusInd',
      );

      final calc = await canonicalQueryRepo.getSafeToSpend();

      // Exactly ONE commitment item is created, NOT two (deduplication verified)
      expect(calc.commitmentItems.length, equals(1));
      expect(calc.commitmentItems.first.amount.toRupees, equals(3000.0));
      expect(calc.knownCommitments14d.toRupees, equals(3000.0));
      expect(calc.safeToSpend.toRupees, equals(45000.0));
    });

    // -------------------------------------------------------------------------
    // C.10: Repeated calculation -> idempotency and no accumulated deductions
    // -------------------------------------------------------------------------
    test('C.10: Repeated calculation is strictly idempotent with no accumulated deductions', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 5) % 28 + 1;

      final card = CreditCard(
        id: 'card_c10',
        name: 'RBL World',
        bank: 'RBL',
        last4: '1010',
        limitAmount: 100000,
        dueDay: dueDay,
        lastStatementBalance: 5000.0,
      );
      await creditRepo.insert(card);

      final dueDate = now.add(const Duration(days: 5));
      await db.insert(Tables.reminders, {
        'id': 'rem_c10',
        'title': 'RBL Credit Card Bill',
        'amount': 5000.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'linked_entity_id': 'card_c10',
        'type': 'credit',
        'is_active': 1,
        'is_completed': 0,
      });

      // Partial payment: ₹2,000
      await recordBalancedTransaction(
        eventId: 'evt_pay_c10',
        debitAccountId: 'card_c10',
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 200000,
        timestampUtc: now.toUtc().subtract(const Duration(days: 1)),
        eventType: 'liability_settlement',
        description: 'Payment RBL',
      );

      final run1 = await canonicalQueryRepo.getSafeToSpend();
      final run2 = await canonicalQueryRepo.getSafeToSpend();
      final run3 = await canonicalQueryRepo.getSafeToSpend();

      expect(run1.liquidAssets.toRupees, equals(run2.liquidAssets.toRupees));
      expect(run2.liquidAssets.toRupees, equals(run3.liquidAssets.toRupees));

      expect(run1.knownCommitments14d.toRupees, equals(3000.0));
      expect(run2.knownCommitments14d.toRupees, equals(3000.0));
      expect(run3.knownCommitments14d.toRupees, equals(3000.0));

      expect(run1.safeToSpend.toRupees, equals(45000.0));
      expect(run2.safeToSpend.toRupees, equals(45000.0));
      expect(run3.safeToSpend.toRupees, equals(45000.0));
    });

    // -------------------------------------------------------------------------
    // C.11: General bill reminders — unrelated payments do not reduce reminder
    // -------------------------------------------------------------------------
    test('C.11: General bill reminders are not reduced by unrelated payments or fuzzy matching', () async {
      final now = DateTime.now();
      final dueDate = now.add(const Duration(days: 3));

      await db.insert(Tables.reminders, {
        'id': 'rem_c11_util',
        'title': 'BESCOM Electricity Bill',
        'amount': 4500.0,
        'date': dueDate.toIso8601String(),
        'created_at': now.toIso8601String(),
        'type': 'bill',
        'is_active': 1,
        'is_completed': 0,
      });

      // An unrelated grocery expense of ₹1,500
      await recordBalancedTransaction(
        eventId: 'evt_c11_groc',
        debitAccountId: TablesV24.sysExpMisc,
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 150000, // ₹1,500
        timestampUtc: now.toUtc().subtract(const Duration(hours: 2)),
        eventType: 'expense',
        description: 'Grocery shopping',
      );

      final calc = await canonicalQueryRepo.getSafeToSpend();

      // Liquid assets: ₹50,000 - ₹1,500 = ₹48,500
      expect(calc.liquidAssets.toRupees, equals(48500.0));
      // General bill reminder remains intact at ₹4,500
      expect(calc.knownCommitments14d.toRupees, equals(4500.0));
      expect(calc.safeToSpend.toRupees, equals(44000.0));
      expect(calc.commitmentItems.first.title, contains('BESCOM'));
      expect(calc.commitmentItems.first.amount.toRupees, equals(4500.0));
    });

    // -------------------------------------------------------------------------
    // C.12: Direct credit card without reminder — partial payment calculation
    // -------------------------------------------------------------------------
    test('C.12: Direct credit card obligation without reminder calculates partial payment correctly', () async {
      final now = DateTime.now();
      final dueDay = (now.day + 4) % 28 + 1;

      final card = CreditCard(
        id: 'card_c12_direct',
        name: 'Standard Chartered Ultimate',
        bank: 'Standard Chartered',
        last4: '1212',
        limitAmount: 200000,
        dueDay: dueDay,
        lastStatementBalance: 7000.0,
      );
      await creditRepo.insert(card);

      // Partial payment: ₹3,000 directly made to the card without any reminder present
      await recordBalancedTransaction(
        eventId: 'evt_pay_c12',
        debitAccountId: 'card_c12_direct',
        creditAccountId: 'acc_bank_primary',
        amountMinorUnits: 300000, // ₹3,000
        timestampUtc: now.toUtc().subtract(const Duration(days: 1)),
        eventType: 'liability_settlement',
        description: 'Payment Standard Chartered',
      );

      final calc = await canonicalQueryRepo.getSafeToSpend();

      // Liquid assets: ₹50,000 - ₹3,000 = ₹47,000
      expect(calc.liquidAssets.toRupees, equals(47000.0));
      // Direct commitment: ₹7,000 - ₹3,000 = ₹4,000
      expect(calc.knownCommitments14d.toRupees, equals(4000.0));
      // Safe-to-Spend: ₹47,000 - ₹4,000 = ₹43,000
      expect(calc.safeToSpend.toRupees, equals(43000.0));
      expect(calc.commitmentItems.length, equals(1));
      expect(calc.commitmentItems.first.title, equals('Standard Chartered Ultimate'));
      expect(calc.commitmentItems.first.amount.toRupees, equals(4000.0));
      expect(calc.commitmentItems.first.type, equals('credit_card'));
    });
  });
}
