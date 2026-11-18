import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/refund_allocations_repo.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/domain/finance/posting.dart';
import 'package:spend_x/services/cross_channel_deduplication_service.dart';
import 'package:sqflite/sqflite.dart';

import 'helpers/stage5b_preflight_bootstrap.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('SpendX Stage 5C.7 Physical Device Live Ingestion Validation', () {
    const liveSmsChannel = MethodChannel('spendx/sms_live');

    testWidgets('Complete fail-closed live SMS pipeline validation on Vivo X200 FE', (tester) async {
      expect(kReleaseMode, isFalse,
          reason: 'Stage 5C.7 physical validation must never run in release mode.');

      // -----------------------------------------------------------------------
      // 1. Enforce fail-closed preflight isolation assertions
      // -----------------------------------------------------------------------
      await Stage5BTestBootstrap.runPreflightAssertions(cleanStaleTestDatabase: true);

      try {
        final packageInfo = await PackageInfo.fromPlatform();
      final database = await AppDatabase.instance.database;

      expect(packageInfo.packageName, Stage5BTestBootstrap.testApplicationId);
      expect(AppDatabase.testDatabasePath, Stage5BTestBootstrap.testDatabaseFilename);
      expect(
        SpendXDatabaseKeyManager.instance.keyStorageName,
        Stage5BTestBootstrap.testKeyStorageName,
      );

      // Verify notification listener is strictly disabled for test package
      final isNotificationListenerEnabled =
          await liveSmsChannel.invokeMethod<bool>('isNotificationListenerEnabled');
      expect(isNotificationListenerEnabled, isFalse,
          reason: 'Stage 5C.7 must operate with Notification Listener DISABLED.');

      // -----------------------------------------------------------------------
      // 2. Seed test accounts in isolated Stage 5B database
      // -----------------------------------------------------------------------
      final now = DateTime.now().toUtc();
      final nowStr = now.toIso8601String();

      await database.insert(
        TablesV24.accounts,
        {
          'id': 'acc_stage5c7_hdfc_1234',
          'account_type': 'asset',
          'subtype': 'checking',
          'name': 'HDFC Test A/c 1234',
          'account_number_last4': '1234',
          'currency': 'INR',
          'is_active': 1,
          'is_system': 0,
          'created_at': nowStr,
          'updated_at': nowStr,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await database.insert(
        TablesV24.accounts,
        {
          'id': 'acc_stage5c7_sbi_5678',
          'account_type': 'asset',
          'subtype': 'savings',
          'name': 'SBI Test A/c 5678',
          'account_number_last4': '5678',
          'currency': 'INR',
          'is_active': 1,
          'is_system': 0,
          'created_at': nowStr,
          'updated_at': nowStr,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      final refundRepo = RefundAllocationsRepo(executor: database);
      final dedupService = CrossChannelDeduplicationService(refundRepo: refundRepo);

      // -----------------------------------------------------------------------
      // 3. Scenario 1: Process incoming financial debit SMS (VM-HDFCBK)
      // -----------------------------------------------------------------------
      final debitCandidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:STAGE5C7_HDFC_001',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 2,450.00 debited from HDFC Bank A/c **1234 on 18-Nov-26 to Swiggy. UPI Ref: 667788990011. Avail Bal: Rs 45,230.50',
        amountMinorUnits: 245000,
        direction: PostingDirection.debit,
        timestamp: now,
        externalReference: '667788990011',
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c7_hdfc_1234',
      );

      final debitResult = await dedupService.processWithConflictResolution(
        candidate: debitCandidate,
        db: database,
      );

      expect(debitResult.status, DeduplicationStatus.newEventCreated);
      expect(debitResult.eventId, isNotNull);

      // Verify evidence persistence
      final debitEvidences = await database.query(
        TablesV24.evidence,
        where: 'economic_event_id = ?',
        whereArgs: [debitResult.eventId!],
      );
      expect(debitEvidences.length, 1);
      expect(debitEvidences.first['source_type'], 'sms');
      expect(debitEvidences.first['sender_address'], 'VM-HDFCBK');
      expect(debitEvidences.first['raw_payload_encrypted'], debitCandidate.body);

      // Verify postings integrity (Double entry: 1 debit to expense, 1 credit to asset)
      final debitPostings = await database.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [debitResult.eventId!],
      );
      expect(debitPostings.length, 2);
      final debitSum = debitPostings
          .where((p) => p['direction'] == 'debit')
          .fold<int>(0, (sum, p) => sum + (p['amount_minor_units'] as int));
      final creditSum = debitPostings
          .where((p) => p['direction'] == 'credit')
          .fold<int>(0, (sum, p) => sum + (p['amount_minor_units'] as int));
      expect(debitSum, 245000);
      expect(creditSum, 245000);

      // -----------------------------------------------------------------------
      // 4. Scenario 2: Idempotent duplicate ingestion (Same SMS repeated)
      // -----------------------------------------------------------------------
      final dupResult = await dedupService.processWithConflictResolution(
        candidate: debitCandidate,
        db: database,
      );
      expect(dupResult.status, DeduplicationStatus.duplicateSourceRecord);
      expect(dupResult.eventId, debitResult.eventId);

      // Ensure no duplicate evidence or postings were created
      final dupEvidences = await database.query(
        TablesV24.evidence,
        where: 'economic_event_id = ?',
        whereArgs: [debitResult.eventId!],
      );
      expect(dupEvidences.length, 1);

      final totalDebitPostings = await database.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [debitResult.eventId!],
      );
      expect(totalDebitPostings.length, 2);

      // -----------------------------------------------------------------------
      // 5. Scenario 3: Process incoming credit SMS (VK-SBIINB)
      // -----------------------------------------------------------------------
      final creditCandidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:STAGE5C7_SBI_002',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBIINB',
        body: 'Dear Customer, your A/c ending 5678 credited by Rs 15,000.00 on 18-Nov-26 by transfer from Employer. Avail Bal Rs 60,230.50',
        amountMinorUnits: 1500000,
        direction: PostingDirection.credit,
        timestamp: now.add(const Duration(seconds: 10)),
        externalReference: 'SBI9988776655',
        accountNumberLast4: '5678',
        accountId: 'acc_stage5c7_sbi_5678',
      );

      final creditResult = await dedupService.processWithConflictResolution(
        candidate: creditCandidate,
        db: database,
      );
      expect(creditResult.status, DeduplicationStatus.newEventCreated);
      expect(creditResult.eventId, isNotNull);

      // Verify credit postings (1 debit to asset, 1 credit to income)
      final creditPostings = await database.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [creditResult.eventId!],
      );
      expect(creditPostings.length, 2);
      final sbiDebitSum = creditPostings
          .where((p) => p['direction'] == 'debit')
          .fold<int>(0, (sum, p) => sum + (p['amount_minor_units'] as int));
      final sbiCreditSum = creditPostings
          .where((p) => p['direction'] == 'credit')
          .fold<int>(0, (sum, p) => sum + (p['amount_minor_units'] as int));
      expect(sbiDebitSum, 1500000);
      expect(sbiCreditSum, 1500000);

      // -----------------------------------------------------------------------
      // 6. Scenario 4: Cross-channel deduplication (Incoming Notification after SMS)
      // -----------------------------------------------------------------------
      final crossChannelCandidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.snapwork.hdfc:88::1731900000000',
        sourceChannel: SourceChannel.push,
        sender: 'com.snapwork.hdfc',
        body: 'Alert: Rs 2,450.00 spent on HDFC card/ac ending 1234 at Swiggy. Ref 667788990011',
        amountMinorUnits: 245000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(seconds: 1)),
        externalReference: '667788990011',
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c7_hdfc_1234',
      );

      final crossChannelResult = await dedupService.processWithConflictResolution(
        candidate: crossChannelCandidate,
        db: database,
      );
      expect(crossChannelResult.status, DeduplicationStatus.strongMatchMerged);
      expect(crossChannelResult.eventId, debitResult.eventId);

      // Evidence count should now be 2 for this event (SMS + Notification)
      final attachedEvidences = await database.query(
        TablesV24.evidence,
        where: 'economic_event_id = ?',
        whereArgs: [debitResult.eventId!],
      );
      expect(attachedEvidences.length, 2);

      // Postings count MUST REMAIN 2 (No duplicate postings added)
      final finalDebitPostings = await database.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [debitResult.eventId!],
      );
      expect(finalDebitPostings.length, 2);

      // -----------------------------------------------------------------------
      // 7. Global Accounting Invariants Assertion
      // -----------------------------------------------------------------------
      final allEvents = await database.query(TablesV24.economicEvents);
      final allEvidence = await database.query(TablesV24.evidence);
      final allPostings = await database.query(TablesV24.postings);

      expect(allEvents.length, 2); // 1 Debit, 1 Credit
      expect(allEvidence.length, 3); // 2 SMS, 1 Notification
      expect(allPostings.length, 4); // 2 Postings per Event

      final totalDebits = allPostings
          .where((p) => p['direction'] == 'debit')
          .fold<int>(0, (sum, p) => sum + (p['amount_minor_units'] as int));
      final totalCredits = allPostings
          .where((p) => p['direction'] == 'credit')
          .fold<int>(0, (sum, p) => sum + (p['amount_minor_units'] as int));

      expect(totalDebits, 1745000); // 245000 + 1500000
      expect(totalCredits, 1745000); // Balanced!

      debugPrint(
        'STAGE5C7_LIVE_VALIDATION_RESULT '
        'events=${allEvents.length} '
        'evidence=${allEvidence.length} '
        'postings=${allPostings.length} '
        'debits=$totalDebits '
        'credits=$totalCredits '
        'balanced=${totalDebits == totalCredits}',
      );

      } finally {
        // -----------------------------------------------------------------------
        // 8. Safe Teardown
        // -----------------------------------------------------------------------
        await Stage5BTestBootstrap.tearDown(deleteDatabaseFile: true);
        expect(Stage5BTestBootstrap.state, Stage5BBootstrapState.tornDown);
        debugPrint('STAGE5C7_DEVICE_TEARDOWN_RESULT state=${Stage5BTestBootstrap.state}');
      }
    });
  });
}
