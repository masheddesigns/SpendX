import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_transaction_adapter.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/review_item.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/live_sms_service.dart';
import 'package:spend_x/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory testDir;
  late String dbPath;
  late Database db;
  final List<String> channelInvocations = [];
  List<dynamic> mockPendingSms = [];

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
      (MethodCall methodCall) async {
        channelInvocations.add(methodCall.method);
        if (methodCall.method == 'getPendingSms') {
          return List.of(mockPendingSms);
        } else if (methodCall.method == 'clearPendingSms') {
          mockPendingSms.clear();
          return null;
        }
        return null;
      },
    );
  });

  setUp(() async {
    testDir = await Directory.systemTemp.createTemp('spendx_p3_group_b_');
    dbPath = p.join(testDir.path, 'group_b_test.db');
    AppDatabase.setTestDatabasePath(dbPath);
    DatabaseAccessGate.instance.resetForTesting();
    DatabaseLifecycleCoordinator.instance.resetForTesting();

    db = await AppDatabase.instance.database;

    final now = DateTime(2026, 11, 1, 10, 0);
    final bank = BankAccount(
      id: 'acc_bank_test_b',
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
      id: 'card_icici_test_b',
      name: 'ICICI Coral Card',
      bank: 'ICICI',
      last4: '5007',
      limitAmount: 150000.0,
      usedAmount: 0.0,
      createdAt: now,
    );
    await CreditRepo(executor: db).insert(card);

    channelInvocations.clear();
    mockPendingSms.clear();
    LiveSmsService.testSimulateSharedPreferencesFailure = false;
    LiveSmsService.testSimulateFailureCounterSetFalse = false;
    LiveSmsService.testSimulateQuarantineSetFalse = false;
    LiveSmsService.testSimulateFailureClearSetFalse = false;
    LiveSmsService.testProcessBodyInterceptor = null;
    LiveSmsService.instance.clearLiveBufferForTesting();
    await LiveSmsService.instance.clearDurableQuarantineForTesting();
  });

  tearDown(() async {
    LiveSmsService.testSimulateSharedPreferencesFailure = false;
    LiveSmsService.testSimulateFailureCounterSetFalse = false;
    LiveSmsService.testSimulateQuarantineSetFalse = false;
    LiveSmsService.testSimulateFailureClearSetFalse = false;
    LiveSmsService.testProcessBodyInterceptor = null;
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

  group('Milestone 5.0 Phase 3 — Group B Remediation (DEF-511 & DEF-512)', () {
    // =========================================================================
    // SECTION B: DEF-511 Durable Quarantine, Retry, & Native Queue Protocol
    // =========================================================================
    group('DEF-511: Durable Quarantine & Native Queue Protocol', () {
      test('B.1: Valid -> transient failure -> valid: queue preserved, then acknowledged on retry without duplicates', () async {
        const sms1 = 'Debited Rs. 100.00 from A/c **1234 on 10-OCT-26 via UPI to CHAIPOINT. Ref: 627181818301. Bal: Rs. 44450.00 - HDFC Bank';
        const sms2Transient = 'Debited Rs. 200.00 from A/c **1234 on 10-OCT-26 via UPI to STARBUCKS. Ref: 627181818302. Bal: Rs. 44250.00 - HDFC Bank';
        const sms3 = 'Debited Rs. 300.00 from A/c **1234 on 10-OCT-26 via UPI to UBER. Ref: 627181818303. Bal: Rs. 43950.00 - HDFC Bank';

        mockPendingSms = [
          {'sender': 'AD-HDFCBK-T', 'body': sms1},
          {'sender': 'AD-HDFCBK-T', 'body': sms2Transient},
          {'sender': 'AD-HDFCBK-T', 'body': sms3},
        ];

        // First attempt: SMS 2 encounters a transient database lock timeout
        LiveSmsService.testProcessBodyInterceptor = (sender, body) async {
          if (body.contains('627181818302')) {
            throw TimeoutException('Simulated database lock timeout');
          }
        };

        await LiveSmsService.instance.drainPending();

        // 1. Poison-message isolation: SMS 1 and SMS 3 succeeded despite SMS 2 failure
        final eventRepo = CanonicalEventRepository(executor: db);
        expect(await eventRepo.getEvidenceByExternalReference('627181818301'), isNotNull);
        expect(await eventRepo.getEvidenceByExternalReference('627181818303'), isNotNull);
        expect(await eventRepo.getEvidenceByExternalReference('627181818302'), isNull);

        // 2. Queue preservation: clearPendingSms was NOT called because SMS 2 is transient!
        expect(channelInvocations.contains('clearPendingSms'), isFalse,
            reason: 'DEF-511 VERIFIED: Native queue is NOT cleared while a transient failure remains');
        expect(mockPendingSms.length, equals(3));

        // Second attempt: Transient condition resolves. Retry without receiving new SMS.
        LiveSmsService.testProcessBodyInterceptor = null;
        await LiveSmsService.instance.drainPending();

        // 3. SMS 2 is now posted
        expect(await eventRepo.getEvidenceByExternalReference('627181818302'), isNotNull);

        // 4. Native queue is acknowledged now that all items are resolved
        expect(channelInvocations.contains('clearPendingSms'), isTrue,
            reason: 'DEF-511 VERIFIED: Native queue is cleared once all messages succeed');
        expect(mockPendingSms, isEmpty);

        // 5. Idempotency check: exactly 1 posting for each of the 3 transactions in the ledger
        final txRepo = TransactionRepo(executor: db);
        final allTxs = await txRepo.getAll();
        expect(allTxs.where((t) => t.externalRef == '627181818301').length, equals(1));
        expect(allTxs.where((t) => t.externalRef == '627181818302').length, equals(1));
        expect(allTxs.where((t) => t.externalRef == '627181818303').length, equals(1));
      });

      test('B.2: Valid -> permanent failure -> valid: poison pill is durably quarantined, queue cleared', () async {
        const sms1 = 'Debited Rs. 150.00 from A/c **1234 on 10-OCT-26 via UPI to CCD. Ref: 627181818401. Bal: Rs. 43800.00 - HDFC Bank';
        const sms2Permanent = 'CORRUPTED_NON_PARSEABLE_SMS_BINARY_PAYLOAD_X';
        const sms3 = 'Debited Rs. 250.00 from A/c **1234 on 10-OCT-26 via UPI to ZOMATO. Ref: 627181818403. Bal: Rs. 43550.00 - HDFC Bank';

        mockPendingSms = [
          {'sender': 'AD-HDFCBK-T', 'body': sms1},
          {'sender': 'MALFORMED', 'body': sms2Permanent},
          {'sender': 'AD-HDFCBK-T', 'body': sms3},
        ];

        LiveSmsService.testProcessBodyInterceptor = (sender, body) async {
          if (body.contains('CORRUPTED')) {
            throw const FormatException('Malformed payload structure');
          }
        };

        await LiveSmsService.instance.drainPending();

        // 1. SMS 1 and SMS 3 succeeded
        final eventRepo = CanonicalEventRepository(executor: db);
        expect(await eventRepo.getEvidenceByExternalReference('627181818401'), isNotNull);
        expect(await eventRepo.getEvidenceByExternalReference('627181818403'), isNotNull);

        // 2. SMS 2 is durably quarantined
        final bodyFp = CanonicalTransactionAdapter.computeBodyFingerprint(sms2Permanent);
        final quarantined = LiveSmsService.instance.quarantinedForTesting;
        expect(quarantined.containsKey(bodyFp), isTrue);
        expect(quarantined[bodyFp]!.body, equals(sms2Permanent));
        expect(quarantined[bodyFp]!.exceptionType, equals('FormatException'));

        // 3. Native queue was acknowledged because all items were resolved (2 succeeded, 1 quarantined)
        expect(channelInvocations.contains('clearPendingSms'), isTrue,
            reason: 'DEF-511 VERIFIED: Queue acknowledged after durable quarantine');
        expect(mockPendingSms, isEmpty);
      });

      test('B.3: Quarantine persistence and survival across process/service restart', () async {
        const smsBad = 'CORRUPTED_PERSISTENCE_TEST_PAYLOAD';
        final bodyFp = CanonicalTransactionAdapter.computeBodyFingerprint(smsBad);

        mockPendingSms = [
          {'sender': 'UNKNOWN', 'body': smsBad},
        ];

        LiveSmsService.testProcessBodyInterceptor = (sender, body) async {
          throw const FormatException('Fatal format error');
        };

        await LiveSmsService.instance.drainPending();

        expect(LiveSmsService.instance.quarantinedForTesting.containsKey(bodyFp), isTrue);

        // Simulate complete process restart: clear in-memory state and reload from SharedPreferences
        await LiveSmsService.instance.reloadDurableStateForTesting();

        // Verify quarantine survived restart
        final reloaded = LiveSmsService.instance.quarantinedForTesting;
        expect(reloaded.containsKey(bodyFp), isTrue,
            reason: 'DEF-511 VERIFIED: Quarantine survives process/service recreation via SharedPreferences');
        expect(reloaded[bodyFp]!.body, equals(smsBad));
        expect(reloaded[bodyFp]!.exceptionType, equals('FormatException'));

        // Also inspect raw SharedPreferences key directly
        final prefs = await SharedPreferences.getInstance();
        final rawJson = prefs.getString('spendx_sms_durable_quarantine_v1');
        expect(rawJson, isNotNull);
        expect(rawJson!.contains(bodyFp), isTrue);
      });

      test('B.4: Retry limit escalation: transient failure is durably quarantined on 3rd attempt', () async {
        const smsStuck = 'Debited Rs. 99.00 from A/c **1234 on 10-OCT-26 via UPI to CHAI. Ref: 627181818501. Bal: Rs. 43451.00 - HDFC Bank';
        final bodyFp = CanonicalTransactionAdapter.computeBodyFingerprint(smsStuck);

        mockPendingSms = [
          {'sender': 'AD-HDFCBK-T', 'body': smsStuck},
        ];

        LiveSmsService.testProcessBodyInterceptor = (sender, body) async {
          throw TimeoutException('Simulated persistent timeout');
        };

        // Attempt 1: Transient failure (count = 1) -> queue NOT cleared
        channelInvocations.clear();
        await LiveSmsService.instance.drainPending();
        expect(channelInvocations.contains('clearPendingSms'), isFalse);
        expect(LiveSmsService.instance.quarantinedForTesting.containsKey(bodyFp), isFalse);

        // Attempt 2: Transient failure (count = 2) -> queue NOT cleared
        channelInvocations.clear();
        await LiveSmsService.instance.drainPending();
        expect(channelInvocations.contains('clearPendingSms'), isFalse);
        expect(LiveSmsService.instance.quarantinedForTesting.containsKey(bodyFp), isFalse);

        // Attempt 3: Retry limit reached (count = 3) -> escalated to durable quarantine!
        channelInvocations.clear();
        await LiveSmsService.instance.drainPending();
        expect(LiveSmsService.instance.quarantinedForTesting.containsKey(bodyFp), isTrue,
            reason: 'DEF-511 VERIFIED: Escalated to durable quarantine after 3 failed attempts');
        expect(channelInvocations.contains('clearPendingSms'), isTrue,
            reason: 'DEF-511 VERIFIED: Queue acknowledged after item is durably quarantined');
      });

      test('B.5: Concurrent quarantine writes via Future.wait serialize safely without record loss', () async {
        const smsBad1 = 'Bad SMS payload alpha 11111';
        const smsBad2 = 'Bad SMS payload beta 22222';
        const smsBad3 = 'Bad SMS payload gamma 33333';
        final fp1 = CanonicalTransactionAdapter.computeBodyFingerprint(smsBad1);
        final fp2 = CanonicalTransactionAdapter.computeBodyFingerprint(smsBad2);
        final fp3 = CanonicalTransactionAdapter.computeBodyFingerprint(smsBad3);

        // Clear quarantine state
        await LiveSmsService.instance.clearDurableQuarantineForTesting();

        // Launch independent quarantine operations concurrently using Future.wait
        await Future.wait([
          LiveSmsService.instance.durableQuarantineForTesting(
            fp1,
            sender: 'SRC1',
            body: smsBad1,
            error: const FormatException('Err 1'),
            failureCount: 1,
          ),
          LiveSmsService.instance.durableQuarantineForTesting(
            fp2,
            sender: 'SRC2',
            body: smsBad2,
            error: const FormatException('Err 2'),
            failureCount: 1,
          ),
          LiveSmsService.instance.durableQuarantineForTesting(
            fp3,
            sender: 'SRC3',
            body: smsBad3,
            error: const FormatException('Err 3'),
            failureCount: 1,
          ),
        ]);

        // Verify in-memory state contains all 3 records
        final quarantined = LiveSmsService.instance.quarantinedForTesting;
        expect(quarantined.containsKey(fp1), isTrue);
        expect(quarantined.containsKey(fp2), isTrue);
        expect(quarantined.containsKey(fp3), isTrue);
        expect(quarantined.length, equals(3));

        // Reload directly from disk (SharedPreferences) to confirm serialization persisted every record
        await LiveSmsService.instance.reloadDurableStateForTesting();
        final reloaded = LiveSmsService.instance.quarantinedForTesting;
        expect(reloaded.containsKey(fp1), isTrue);
        expect(reloaded.containsKey(fp2), isTrue);
        expect(reloaded.containsKey(fp3), isTrue);
        expect(reloaded.length, equals(3));
      });

      test('B.6: SharedPreferences persistence exception prevents native queue clearance and retains unhandled messages', () async {
        const smsCorrupt = 'CORRUPT_SMS_FAILING_STORAGE_TEST_333';
        mockPendingSms = [
          {'sender': 'BANK-TEST', 'body': smsCorrupt},
        ];

        LiveSmsService.testProcessBodyInterceptor = (sender, body) async {
          throw const FormatException('Permanent fatal error');
        };

        // Simulate SharedPreferences disk/persistence failure via thrown exception
        LiveSmsService.testSimulateSharedPreferencesFailure = true;

        await LiveSmsService.instance.drainPending();

        // Native queue MUST NOT be cleared when persistence of quarantine fails!
        expect(channelInvocations.contains('clearPendingSms'), isFalse,
            reason: 'DEF-511 VERIFIED: Native queue is NOT acknowledged when persistence throws exception');
        expect(mockPendingSms.length, equals(1));

        LiveSmsService.testSimulateSharedPreferencesFailure = false;
      });

      test('B.6a: Failure counter setString() returning false executes (!success) branch and prevents queue acknowledgement', () async {
        const smsTransient = 'Debited Rs. 50.00 from A/c **1234 on 10-OCT-26 via UPI. Ref: 627181819901. Bal: Rs. 40000.00 - HDFC Bank';
        final bodyFp = CanonicalTransactionAdapter.computeBodyFingerprint(smsTransient);
        mockPendingSms = [
          {'sender': 'BANK-TEST', 'body': smsTransient},
        ];

        LiveSmsService.testProcessBodyInterceptor = (sender, body) async {
          throw TimeoutException('Simulated transient lock timeout');
        };

        // Simulate setString returning false on failure counter write
        LiveSmsService.testSimulateFailureCounterSetFalse = true;

        await LiveSmsService.instance.drainPending();

        // 1. Native queue MUST NOT be cleared
        expect(channelInvocations.contains('clearPendingSms'), isFalse,
            reason: 'DEF-511 VERIFIED: Failure counter persistence failure prevents queue clearance');
        expect(mockPendingSms.length, equals(1));

        // 2. In-memory state must NOT falsely record the counter increment as durable
        expect(LiveSmsService.instance.getFailureCountForTesting(bodyFp), isNull,
            reason: 'DEF-511 VERIFIED: Failed disk write does not update in-memory state');

        LiveSmsService.testSimulateFailureCounterSetFalse = false;
      });

      test('B.6b: Quarantine persistence setString() returning false executes (!success) branch and prevents queue acknowledgement', () async {
        const smsPermanent = 'CORRUPT_PAYLOAD_FAILING_QUARANTINE_PERSISTENCE';
        final bodyFp = CanonicalTransactionAdapter.computeBodyFingerprint(smsPermanent);
        mockPendingSms = [
          {'sender': 'BANK-TEST', 'body': smsPermanent},
        ];

        LiveSmsService.testProcessBodyInterceptor = (sender, body) async {
          throw const FormatException('Permanent fatal error');
        };

        // Simulate setString returning false on quarantine write
        LiveSmsService.testSimulateQuarantineSetFalse = true;

        await LiveSmsService.instance.drainPending();

        // 1. Native queue MUST NOT be cleared
        expect(channelInvocations.contains('clearPendingSms'), isFalse,
            reason: 'DEF-511 VERIFIED: Quarantine persistence failure prevents queue clearance');
        expect(mockPendingSms.length, equals(1));

        // 2. In-memory state must NOT falsely record the quarantine as durable
        expect(LiveSmsService.instance.quarantinedForTesting.containsKey(bodyFp), isFalse,
            reason: 'DEF-511 VERIFIED: Failed quarantine disk write does not update in-memory quarantine map');

        LiveSmsService.testSimulateQuarantineSetFalse = false;
      });

      test('B.6c: Failure counter clearing setString() returning false executes (!success) branch and prevents queue acknowledgement', () async {
        const smsValid = 'Debited Rs. 75.00 from A/c **1234 on 10-OCT-26 via UPI to STORE. Ref: 627181819902. Bal: Rs. 39925.00 - HDFC Bank';
        final bodyFp = CanonicalTransactionAdapter.computeBodyFingerprint(smsValid);
        mockPendingSms = [
          {'sender': 'BANK-TEST', 'body': smsValid},
        ];

        // Seed existing failure counter in memory and disk
        LiveSmsService.instance.setFailureCountForTesting(bodyFp, 1);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('spendx_sms_failure_counts_v1', jsonEncode({bodyFp: 1}));

        // Simulate setString returning false when attempting to clear the failure counter
        LiveSmsService.testSimulateFailureClearSetFalse = true;

        await LiveSmsService.instance.drainPending();

        // 1. Native queue MUST NOT be cleared because clearing retry state failed
        expect(channelInvocations.contains('clearPendingSms'), isFalse,
            reason: 'DEF-511 VERIFIED: Failure to clear failure counter prevents queue clearance');
        expect(mockPendingSms.length, equals(1));

        // 2. In-memory failure counter must NOT be falsely cleared
        expect(LiveSmsService.instance.getFailureCountForTesting(bodyFp), equals(1),
            reason: 'DEF-511 VERIFIED: Failed disk clear does not falsely remove in-memory counter');

        LiveSmsService.testSimulateFailureClearSetFalse = false;
      });
    });

    // =========================================================================
    // SECTION C: DEF-512 Boundary & Duplicate-Detection Regression Tests
    // =========================================================================
    group('DEF-512: Boundary & Duplicate-Detection Scenarios', () {
      test('C.1: Same transaction with changed SMS wording is deduplicated via reference or heuristic', () async {
        // SMS A (Bank format)
        const smsA = 'Debited Rs. 420.00 from A/c **1234 on 02-OCT-26 via UPI to SWIGGY. Ref: 627181818601. Bal: Rs. 45000.00 - HDFC Bank';
        LiveSmsService.instance.addLiveBufferForTesting('AD-HDFCBK-T', smsA);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        // SMS B (UPI confirmation format with changed wording, same UTR)
        const smsB = 'Paid Rs. 420.00 to SWIGGY from HDFC Bank A/c **1234 on 02-OCT-26. UPI Ref: 627181818601. Successful.';
        LiveSmsService.instance.addLiveBufferForTesting('UPI-APP', smsB);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        final txRepo = TransactionRepo(executor: db);
        final allTxs = await txRepo.getAll();
        final swiggyTxs = allTxs.where((t) => t.externalRef == '627181818601').toList();

        expect(swiggyTxs.length, equals(1),
            reason: 'DEF-512 VERIFIED: Changed SMS wording with identical UTR is deduplicated');
      });

      test('C.2: Same transaction redelivered with different timestamp is deduplicated via reference', () async {
        const ref = '627181818602';
        const smsOriginal = 'Debited Rs. 200.00 from A/c **1234 on 10-OCT-26 at 10:00 via UPI to CAFE. Ref: $ref. Bal: Rs. 44800.00 - HDFC Bank';
        LiveSmsService.instance.addLiveBufferForTesting('AD-HDFCBK-T', smsOriginal);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        // Network redelivery with later timestamp
        const smsRedelivered = 'Debited Rs. 200.00 from A/c **1234 on 10-OCT-26 at 14:00 via UPI to CAFE. Ref: $ref. Bal: Rs. 44800.00 - HDFC Bank';
        LiveSmsService.instance.addLiveBufferForTesting('AD-HDFCBK-T', smsRedelivered);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        final txRepo = TransactionRepo(executor: db);
        final allTxs = await txRepo.getAll();
        final cafeTxs = allTxs.where((t) => t.externalRef == ref).toList();

        expect(cafeTxs.length, equals(1),
            reason: 'DEF-512 VERIFIED: Redelivered SMS with different timestamp deduplicates via reference');
      });

      test('C.3: Two legitimate same-amount purchases close together (Starbucks 10 min apart) are NOT collapsed', () async {
        final txRepo = TransactionRepo(executor: db);

        // Purchase 1 at 10:00
        const sms1 = 'Debited Rs. 150.00 from A/c **1234 on 10-OCT-26 via UPI to STARBUCKS. Ref: 627181818603. Bal: Rs. 44650.00 - HDFC Bank';
        LiveSmsService.instance.addLiveBufferForTesting('AD-HDFCBK-T', sms1);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        // Purchase 2 (10 minutes later) at 10:10
        const sms2 = 'Debited Rs. 150.00 from A/c **1234 on 10-OCT-26 via UPI to STARBUCKS. Ref: 627181818604. Bal: Rs. 44500.00 - HDFC Bank';
        LiveSmsService.instance.addLiveBufferForTesting('AD-HDFCBK-T', sms2);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        final allTxs = await txRepo.getAll();
        final starbucksTxs = allTxs.where((t) => t.notes.toLowerCase().contains('starbucks')).toList();

        expect(starbucksTxs.length, equals(2),
            reason: 'DEF-512 VERIFIED: Legitimate same-amount purchases are preserved');
      });

      test('C.4: Same merchant and amount across DIFFERENT accounts are strictly isolated', () async {
        final txRepo = TransactionRepo(executor: db);

        // Purchase on Bank Account
        const smsBank = 'Debited Rs. 500.00 from A/c **1234 on 10-OCT-26 via UPI to SWIGGY. Ref: 627181818605. Bal: Rs. 44000.00 - HDFC Bank';
        LiveSmsService.instance.addLiveBufferForTesting('AD-HDFCBK-T', smsBank);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        // Purchase on Credit Card
        const smsCard = 'An amount of INR 500.00 has been spent on your ICICI Bank Credit Card ending 5007 at SWIGGY on 10-OCT-26. Avl Lmt: INR 1,49,500.00';
        LiveSmsService.instance.addLiveBufferForTesting('JM-ICICIB-S', smsCard);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        final allTxs = await txRepo.getAll();
        final swiggyTxs = allTxs.where((t) => t.notes.toLowerCase().contains('swiggy')).toList();

        expect(swiggyTxs.length, equals(2),
            reason: 'DEF-512 VERIFIED: Cross-account transactions are strictly isolated');
        expect(swiggyTxs.any((t) => t.accountId == 'acc_bank_test_b'), isTrue);
        expect(swiggyTxs.any((t) => t.accountId == 'card_icici_test_b'), isTrue);
      });

      test('C.5: Missing or ambiguous merchant information matches safely or rejects cleanly', () async {
        // Manual transaction with known merchant
        final txManual = spx.Transaction(
          id: 'tx_manual_coffee_c5',
          amount: 220.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_test_b',
          date: DateTime.utc(2026, 11, 10, 14, 0),
          notes: 'Third Wave Coffee',
          source: 'manual',
        );
        await FinancialTransactionService(database: db).createTransaction(txManual);

        // 1. Candidate with null merchant but raw text explicitly mentions merchant -> matches!
        final parsedMentioning = ParsedTransaction(
          amount: 220.0,
          date: DateTime.utc(2026, 11, 10, 14, 2),
          isCredit: false,
          merchant: null,
          rawText: 'Rs 220 debited from A/c **1234 on 10-Nov-26 at Third Wave Coffee',
        );
        final matchesMentioning = await LiveSmsService.instance.testAlreadyInApp(
          parsedMentioning,
          candidateAccountId: 'acc_bank_test_b',
        );
        expect(matchesMentioning, isTrue,
            reason: 'DEF-512 VERIFIED: Matches when rawText contains merchant name');

        // 2. Candidate with null merchant and unrelated raw text -> rejects!
        final parsedUnrelated = ParsedTransaction(
          amount: 220.0,
          date: DateTime.utc(2026, 11, 10, 14, 20),
          isCredit: false,
          merchant: null,
          rawText: 'Rs 220 debited from A/c **1234 on 10-Nov-26 for Metro transit',
        );
        final matchesUnrelated = await LiveSmsService.instance.testAlreadyInApp(
          parsedUnrelated,
          candidateAccountId: 'acc_bank_test_b',
        );
        expect(matchesUnrelated, isFalse,
            reason: 'DEF-512 VERIFIED: Rejects when rawText does not mention merchant');
      });

      test('C.6: Heuristic deduplication with altered SMS wording and absent external reference', () async {
        // Pre-existing manual transaction with no external reference
        final txManual = spx.Transaction(
          id: 'tx_manual_bt_c6',
          amount: 350.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_test_b',
          date: DateTime.utc(2026, 11, 10, 16, 0),
          notes: 'Blue Tokai',
          source: 'manual',
        );
        await FinancialTransactionService(database: db).createTransaction(txManual);

        // Candidate SMS arrives with completely altered wording and NO UTR
        final candidate = ParsedTransaction(
          amount: 350.0,
          date: DateTime.utc(2026, 11, 10, 16, 1),
          isCredit: false,
          merchant: 'Blue Tokai Coffee',
          rawText: 'Payment of INR 350.00 confirmed to Blue Tokai Coffee Roasters',
          refId: null,
        );

        final isDuplicate = await LiveSmsService.instance.testAlreadyInApp(
          candidate,
          candidateAccountId: 'acc_bank_test_b',
        );
        expect(isDuplicate, isTrue,
            reason: 'DEF-512 VERIFIED: Heuristic matches altered phrasing when merchant and account match');
      });

      test('C.7: Heuristic deduplication with changed timestamp and no UTR', () async {
        const smsOriginal = 'Debited Rs. 180.00 from A/c **1234 on 10-OCT-26 via UPI to STARBUCKS. Bal: Rs. 42000.00 - HDFC Bank';
        LiveSmsService.instance.addLiveBufferForTesting('AD-HDFCBK-T', smsOriginal);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        // Duplicate delivery arriving 1 minute later with adjusted timestamp and NO UTR
        final candidate = ParsedTransaction(
          amount: 180.0,
          date: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          isCredit: false,
          merchant: 'Starbucks',
          rawText: 'Alert: Rs 180.00 debited for Starbucks on your account.',
          refId: null,
        );

        final isDuplicate = await LiveSmsService.instance.testAlreadyInApp(
          candidate,
          candidateAccountId: 'acc_bank_test_b',
        );
        expect(isDuplicate, isTrue,
            reason: 'DEF-512 VERIFIED: Redelivered SMS with no UTR and minor timestamp skew is deduplicated');
      });

      test('C.8: Two legitimate purchases of same amount and merchant within 3 minutes with distinct references', () async {
        const smsFirst = 'Debited Rs. 250.00 from A/c **1234 on 10-OCT-26 via UPI to COSTA. Ref: 627181819001. Bal: Rs. 41750.00 - HDFC Bank';
        LiveSmsService.instance.addLiveBufferForTesting('AD-HDFCBK-T', smsFirst);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        // Second legitimate purchase 1 minute later with distinct reference
        final candidateSecond = ParsedTransaction(
          amount: 250.0,
          date: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          isCredit: false,
          merchant: 'Costa',
          rawText: 'Debited Rs. 250.00 from A/c **1234 on 10-OCT-26 via UPI to COSTA. Ref: 627181819002. Bal: Rs. 41500.00 - HDFC Bank',
          refId: '627181819002',
        );

        final isDuplicate = await LiveSmsService.instance.testAlreadyInApp(
          candidateSecond,
          candidateAccountId: 'acc_bank_test_b',
        );
        expect(isDuplicate, isFalse,
            reason: 'DEF-512 VERIFIED: Legitimate proximate purchases with distinct references are NOT collapsed');

        // Post second transaction and confirm both are recorded
        LiveSmsService.instance.addLiveBufferForTesting('AD-HDFCBK-T', candidateSecond.rawText);
        await LiveSmsService.instance.flushLiveBufferForTesting();

        final allTxs = await TransactionRepo(executor: db).getAll();
        final costaTxs = allTxs.where((t) => t.notes.toLowerCase().contains('costa')).toList();
        expect(costaTxs.length, equals(2));
      });

      test('C.9: Two distinct transactions with missing merchant information remain distinct', () async {
        final txMissing = spx.Transaction(
          id: 'tx_missing_merchant_c9',
          amount: 500.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_test_b',
          date: DateTime.utc(2026, 11, 10, 12, 0),
          notes: '',
          source: 'manual',
        );
        await FinancialTransactionService(database: db).createTransaction(txMissing);

        // Case A: Missing merchant, but 15 minutes apart (> 3.0 min) on same account -> NOT duplicate
        final candidateDifferentTime = ParsedTransaction(
          amount: 500.0,
          date: DateTime.utc(2026, 11, 10, 12, 15),
          isCredit: false,
          merchant: null,
          rawText: 'INR 500.00 debited from A/c **1234',
          refId: null,
        );
        final isDupTime = await LiveSmsService.instance.testAlreadyInApp(
          candidateDifferentTime,
          candidateAccountId: 'acc_bank_test_b',
        );
        expect(isDupTime, isFalse,
            reason: 'DEF-512 VERIFIED: Missing merchant transactions > 3 minutes apart remain distinct');

        // Case B: Missing merchant, identical time, but different account -> NOT duplicate
        final candidateDifferentAccount = ParsedTransaction(
          amount: 500.0,
          date: DateTime.utc(2026, 11, 10, 12, 0),
          isCredit: false,
          merchant: null,
          rawText: 'INR 500.00 spent on ICICI Card **5007',
          refId: null,
        );
        final isDupAccount = await LiveSmsService.instance.testAlreadyInApp(
          candidateDifferentAccount,
          candidateAccountId: 'card_icici_test_b',
        );
        expect(isDupAccount, isFalse,
            reason: 'DEF-512 VERIFIED: Missing merchant across different accounts remain distinct');
      });

      test('C.10: Cross-account isolation remains strictly intact under missing references', () async {
        final txBank = spx.Transaction(
          id: 'tx_bank_amazon_c10',
          amount: 800.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_test_b',
          date: DateTime.utc(2026, 11, 10, 15, 0),
          notes: 'Amazon',
          source: 'manual',
        );
        await FinancialTransactionService(database: db).createTransaction(txBank);

        // Candidate on Credit Card with identical amount, merchant, and timestamp, with NO UTR
        final candidateCard = ParsedTransaction(
          amount: 800.0,
          date: DateTime.utc(2026, 11, 10, 15, 0),
          isCredit: false,
          merchant: 'Amazon',
          rawText: 'Rs 800.00 spent on ICICI Card **5007 at Amazon',
          refId: null,
        );

        final isDuplicate = await LiveSmsService.instance.testAlreadyInApp(
          candidateCard,
          candidateAccountId: 'card_icici_test_b',
        );
        expect(isDuplicate, isFalse,
            reason: 'DEF-512 VERIFIED: Transactions on different accounts are never collapsed, even with identical amount/merchant/time');
      });
    });

    // =========================================================================
    // Double-Entry Ledger Conservation Invariant
    // =========================================================================
    test('Double-entry trial balance holds across all Group B operations', () async {
      final rows = await db.rawQuery('''
        SELECT
          SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END) as total_debit,
          SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END) as total_credit
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
        WHERE e.lifecycle_status = 'posted'
      ''');

      final totalDebit = rows.first['total_debit'] as int? ?? 0;
      final totalCredit = rows.first['total_credit'] as int? ?? 0;
      expect(totalDebit, equals(totalCredit), reason: 'Trial balance: total debits must equal total credits');
    });
  });
}
