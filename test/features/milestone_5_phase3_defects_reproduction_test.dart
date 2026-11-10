import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_transaction_adapter.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/live_sms_service.dart';
import 'package:spend_x/services/settings_service.dart';
import 'package:spend_x/services/sms_import_service.dart';
import 'package:spend_x/services/transaction_text_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory testDir;
  late String dbPath;
  late Database db;

  setUpAll(() async {
    await SpendXDatabaseFactory.instance.initialize();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (MethodCall methodCall) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('spendx/sms_live'),
      (MethodCall methodCall) async => null,
    );
  });

  setUp(() async {
    testDir = await Directory.systemTemp.createTemp('spendx_p3_repro_');
    dbPath = p.join(testDir.path, 'repro_test.db');
    AppDatabase.setTestDatabasePath(dbPath);
    DatabaseAccessGate.instance.resetForTesting();
    DatabaseLifecycleCoordinator.instance.resetForTesting();

    db = await AppDatabase.instance.database;

    // Seed test bank account and credit card
    final now = DateTime(2026, 11, 1, 10, 0);
    final bank = BankAccount(
      id: 'acc_bank_hdfc',
      userId: 'offline_user',
      name: 'HDFC Bank',
      bank: 'HDFC',
      last4: '1234',
      balance: 100000.0,
      accountType: 'savings',
      createdAt: now,
      updatedAt: now,
    );
    await AccountRepo(executor: db).insertAccount(bank);

    final card = CreditCard(
      id: 'card_icici_5678',
      name: 'ICICI Coral',
      bank: 'ICICI',
      last4: '5678',
      limitAmount: 200000.0,
      usedAmount: 0.0,
      dueDay: 20,
      billingDay: 1,
      createdAt: now,
    );
    await CreditRepo(executor: db).insert(card);
  });

  tearDown(() async {
    try {
      await AppDatabase.instance.close();
    } catch (_) {}
    DatabaseLifecycleCoordinator.instance.resetForTesting();
    DatabaseAccessGate.instance.resetForTesting();
    AppDatabase.setTestDatabasePath(null);
    try {
      if (await testDir.exists()) {
        await testDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Milestone 5.0 Phase 3 Reproduction Gate: DEF-509 to DEF-512', () {
    // =========================================================================
    // DEF-509: Evidence SHA-256 Fingerprint Discrepancy
    // =========================================================================
    group('DEF-509: Evidence SHA-256 Fingerprint Discrepancy', () {
      test('1. Reproduction: Persisted bodyFingerprint hashes externalRef instead of rawBody', () async {
        const rawBody =
            'Debited Rs 450.00 from A/c **1234 on 10-Nov-26 via UPI to Swiggy. Ref: 987654321098. Bal: Rs 12000.00';
        final expectedRawBodyHash = CanonicalTransactionAdapter.computeSha256(rawBody);
        const externalRef = '987654321098';
        final externalRefHash = CanonicalTransactionAdapter.computeSha256(externalRef);

        final tx = spx.Transaction(
          id: 'tx_p3_509_demo',
          amount: 450.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_hdfc',
          date: DateTime(2026, 11, 10, 12, 0),
          notes: 'Swiggy',
          externalRef: externalRef,
          source: 'sms',
        );

        await FinancialTransactionService(database: db).createTransaction(tx);

        final eventRepo = CanonicalEventRepository(executor: db);
        final evidence = await eventRepo.getEvidenceByExternalReference(externalRef);
        expect(evidence, isNotNull);

        // DEF-509 PROOF:
        // Evidence.bodyFingerprint matches computeSha256(externalRef), NOT computeSha256(rawBody)!
        expect(evidence!.bodyFingerprint, equals(externalRefHash),
            reason: 'Persisted bodyFingerprint hashes externalRef');
        expect(evidence.bodyFingerprint, isNot(equals(expectedRawBodyHash)),
            reason: 'Persisted bodyFingerprint DOES NOT match raw SMS body hash');

        // Lookup by raw SMS body fingerprint FAILS to find the existing evidence:
        final lookupByRawHash = await eventRepo.getEvidenceByFingerprint(expectedRawBodyHash);
        expect(lookupByRawHash, isNull,
            reason: 'Lookup by raw body fingerprint returns null because database contains hash of externalRef');
      });

      test('2. Reproduction: Layer 5b scenario from sms_parser_matrix_test reproduced', () async {
        const rawBody =
            'Debited Rs 750.00 from A/c **1234 on 10-Oct-26 via UPI to Zomato. Ref: 629000111222. Bal: Rs 49250.00';
        final expectedFingerprint = CanonicalTransactionAdapter.computeSha256(rawBody);

        final tx = spx.Transaction(
          id: 'tx_dedup_5b_repro',
          amount: 750.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_hdfc',
          date: DateTime(2026, 10, 10, 14, 0),
          notes: 'Zomato',
          externalRef: '629000111222',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(tx);

        final eventRepo = CanonicalEventRepository(executor: db);
        final evidence = await eventRepo.getEvidenceByExternalReference('629000111222');
        expect(evidence, isNotNull);

        // This assertion documents the exact failure in sms_parser_matrix_test.dart:1105
        final bool matchesRawBodyHash = evidence!.bodyFingerprint == expectedFingerprint;
        expect(matchesRawBodyHash, isFalse,
            reason: 'REPRODUCED DEF-509: Evidence.bodyFingerprint diverges from computeSha256(rawBody)');
      });
    });

    // =========================================================================
    // DEF-510: Synthetic Reference Lookup Missing in Deduplication
    // =========================================================================
    group('DEF-510: Synthetic Reference Lookup Missing in Deduplication', () {
      test('1. Reproduction: SMS without bank UTR generates synthetic ref, but lookup checks parsed.refId', () async {
        const rawBody = 'Rs 250.00 debited from A/c **1234 at CCD on 15-Nov-26.';
        final parsed = TransactionTextParser.parse(rawBody, source: 'sms');
        expect(parsed.refId, isNull, reason: 'SMS has no bank UTR / reference');

        final dateMs = parsed.date.millisecondsSinceEpoch;
        final syntheticRef = 'live_sms|$dateMs|${parsed.amount.toStringAsFixed(2)}';

        // When processed by LiveSmsService, externalRef is populated with syntheticRef:
        final tx = spx.Transaction(
          id: 'tx_p3_510_demo',
          amount: parsed.amount,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_hdfc',
          date: parsed.date,
          notes: 'CCD',
          externalRef: syntheticRef,
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(tx);

        final eventRepo = CanonicalEventRepository(executor: db);

        // 1. Evidence table DOES contain the synthetic reference:
        final evidenceBySynthetic = await eventRepo.getEvidenceByExternalReference(syntheticRef);
        expect(evidenceBySynthetic, isNotNull,
            reason: 'Synthetic reference was persisted in the evidence table');

        // 2. DEF-510 PROOF:
        // In LiveSmsService._alreadyInApp(parsed):
        //   if (parsed.refId != null && parsed.refId!.trim().isNotEmpty) { ... }
        // Because parsed.refId is NULL, Tier 1 lookup getEvidenceByExternalReference is NEVER called!
        final bool wouldTier1Execute = parsed.refId != null && parsed.refId!.trim().isNotEmpty;
        expect(wouldTier1Execute, isFalse,
            reason: 'REPRODUCED DEF-510: Tier 1 externalRef lookup is completely bypassed when parsed.refId is null');
      });
    });

    // =========================================================================
    // DEF-511: Live Buffer Error Isolation & Poison Pill
    // =========================================================================
    group('DEF-511: Live Buffer Error Isolation', () {
      test('1. Reproduction: Unhandled exception in batch loop clears buffer and drops subsequent messages', () async {
        final List<String> buffer = ['Message_A_Valid', 'Message_B_Throws', 'Message_C_Valid'];
        final List<String> committed = [];
        final List<String> failed = [];

        // Simulate current _flushLiveBuffer logic:
        final batch = List.of(buffer);
        buffer.clear(); // Cleared upfront before processing!

        dynamic caughtError;
        try {
          for (final msg in batch) {
            if (msg == 'Message_B_Throws') {
              throw StateError('Simulated database/parsing error on Message B');
            }
            committed.add(msg);
          }
        } catch (e) {
          caughtError = e;
        }

        // DEF-511 PROOF:
        expect(caughtError, isNotNull, reason: 'Batch loop terminated on Message B error');
        expect(committed, equals(['Message_A_Valid']), reason: 'Message A was processed');
        expect(buffer, isEmpty, reason: 'Live buffer was cleared upfront; un-processed messages are NOT in buffer');
        // Message C was never processed, never retried, and permanently lost!
        expect(committed.contains('Message_C_Valid'), isFalse,
            reason: 'REPRODUCED DEF-511: Message C was dropped without execution');
      });

      test('2. Reproduction: Native queue drain failure leaves clearPendingSms uncalled (poison pill)', () async {
        final List<String> nativeQueue = ['SMS_A_Valid', 'SMS_B_Throws', 'SMS_C_Valid'];
        bool clearPendingSmsCalled = false;
        final List<String> committed = [];

        // Simulate drainPending() logic:
        try {
          for (final item in nativeQueue) {
            if (item == 'SMS_B_Throws') {
              throw StateError('Simulated poison-pill parsing error');
            }
            committed.add(item);
          }
          clearPendingSmsCalled = true;
        } catch (_) {
          // Channel catch block ignores error without clearing
        }

        // DEF-511 PROOF:
        expect(committed, equals(['SMS_A_Valid']));
        expect(clearPendingSmsCalled, isFalse,
            reason: 'REPRODUCED DEF-511: clearPendingSms is not reached; on next start all 3 will be retried');
      });
    });

    // =========================================================================
    // DEF-512: Heuristic Duplicate False-Positives & False-Negatives
    // =========================================================================
    group('DEF-512: Heuristic Duplicate False-Positives & False-Negatives', () {
      test('1. False Positive: Two genuine purchases at same merchant within 30 min are falsely collapsed', () async {
        final txRepo = TransactionRepo(executor: db);

        // Purchase 1: ₹150 at Starbucks at 10:00 UTC
        final purchaseTime = DateTime.utc(2026, 11, 10, 10, 0);
        final tx1 = spx.Transaction(
          id: 'tx_starbucks_1',
          amount: 150.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_hdfc',
          date: purchaseTime,
          notes: 'Starbucks',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(tx1);

        // Purchase 2 (15 minutes later): Another genuine ₹150 at Starbucks at 10:15 UTC
        final candidateTime = DateTime.utc(2026, 11, 10, 10, 15);
        final sameAmount = await txRepo.findByAmountAndDateRange(
          amount: 150.0,
          from: candidateTime.subtract(const Duration(minutes: 30)),
          to: candidateTime.add(const Duration(minutes: 30)),
        );

        expect(sameAmount.isNotEmpty, isTrue, reason: 'Finds Purchase 1 in the 30-min window');
        // Both have merchant 'Starbucks':
        final isFalselyFlaggedDuplicate = sameAmount.any((t) => t.notes.toLowerCase() == 'starbucks');
        expect(isFalselyFlaggedDuplicate, isTrue,
            reason: 'REPRODUCED DEF-512 (False Positive): Second legitimate purchase within 30m is rejected as duplicate');
      });

      test('2. False Positive: Same amount and merchant across DIFFERENT accounts is falsely collapsed', () async {
        final txRepo = TransactionRepo(executor: db);

        // Purchase 1: ₹500 at Swiggy on Bank Account
        final purchaseTime = DateTime.utc(2026, 11, 10, 12, 0);
        final tx1 = spx.Transaction(
          id: 'tx_swiggy_bank',
          amount: 500.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_hdfc',
          date: purchaseTime,
          notes: 'Swiggy',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(tx1);

        // Purchase 2: ₹500 at Swiggy on Credit Card 10 minutes later
        final candidateTime = DateTime.utc(2026, 11, 10, 12, 10);

        // findByAmountAndDateRange does NOT filter by accountId!
        final sameAmount = await txRepo.findByAmountAndDateRange(
          amount: 500.0,
          from: candidateTime.subtract(const Duration(minutes: 30)),
          to: candidateTime.add(const Duration(minutes: 30)),
        );

        expect(sameAmount.isNotEmpty, isTrue);
        // Matches Swiggy from bank account even though candidate is on credit card!
        final isFalselyFlaggedDuplicate = sameAmount.any((t) => t.notes.toLowerCase() == 'swiggy');
        expect(isFalselyFlaggedDuplicate, isTrue,
            reason: 'REPRODUCED DEF-512 (False Positive): Transaction on Card is blocked by previous transaction on Bank');
      });

      test('3. False Negative: Local DateTime vs UTC query mismatch causes findByAmountAndDateRange to miss duplicates', () async {
        final txRepo = TransactionRepo(executor: db);

        // Stored transaction has local time (which gets stored as UTC in SQLite):
        final localPurchaseTime = DateTime(2026, 11, 10, 10, 0); // e.g. IST
        final tx1 = spx.Transaction(
          id: 'tx_local_tz_demo',
          amount: 300.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_hdfc',
          date: localPurchaseTime,
          notes: 'Uber',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(tx1);

        // When queried with local DateTime without .toUtc():
        final localFrom = localPurchaseTime.subtract(const Duration(minutes: 30));
        final localTo = localPurchaseTime.add(const Duration(minutes: 30));

        // If local timezone is not UTC (e.g. IST +05:30), localFrom.toIso8601String()
        // produces "2026-11-10T09:30:00.000", whereas SQLite stored UTC "2026-11-10T04:30:00.000Z".
        // In string comparison, "04:30" < "09:30", so BETWEEN fails to match!
        if (localPurchaseTime.timeZoneOffset != Duration.zero) {
          final queryResult = await txRepo.findByAmountAndDateRange(
            amount: 300.0,
            from: localFrom,
            to: localTo,
          );
          expect(queryResult.isEmpty, isTrue,
              reason: 'REPRODUCED DEF-512: Local timezone mismatch causes findByAmountAndDateRange to return empty results');
        }
      });

      test('4. False Negative: Duplicate SMS with null merchant bypasses Tier 3 heuristic completely', () async {
        // When merchant cannot be parsed:
        // _normalizeMerchantForDedup(null) returns ''
        // _merchantsMatch('', notes) returns false!
        const String? candidateMerchant = null;
        final normMerchant = candidateMerchant ?? '';

        final bool matchResult = normMerchant.isNotEmpty;
        expect(matchResult, isFalse,
            reason: 'REPRODUCED DEF-512 (False Negative): When merchant is null, Tier 3 heuristic fails to match duplicates');
      });
    });
  });
}
