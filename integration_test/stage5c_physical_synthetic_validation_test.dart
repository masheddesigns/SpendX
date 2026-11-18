import 'package:flutter/foundation.dart';
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

  testWidgets('Stage 5C on-device synthetic ingestion & deduplication validation', (tester) async {
    expect(kReleaseMode, isFalse,
        reason: 'Stage 5C physical validation must never run in release mode.');

    // 1. Run fail-closed preflight assertions
    await Stage5BTestBootstrap.runPreflightAssertions();

    final packageInfo = await PackageInfo.fromPlatform();
    final database = await AppDatabase.instance.database;

    expect(packageInfo.packageName, Stage5BTestBootstrap.testApplicationId);
    expect(AppDatabase.testDatabasePath, Stage5BTestBootstrap.testDatabaseFilename);
    expect(
      SpendXDatabaseKeyManager.instance.keyStorageName,
      Stage5BTestBootstrap.testKeyStorageName,
    );

    // 2. Seed test accounts in isolated Stage 5B database
    final now = DateTime.now().toUtc();
    final nowStr = now.toIso8601String();

    await database.insert(
      TablesV24.accounts,
      {
        'id': 'acc_stage5c_sbi_1111',
        'account_type': 'asset',
        'subtype': 'savings',
        'name': 'SBI Test A/c 1111',
        'account_number_last4': '1111',
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
        'id': 'acc_stage5c_hdfc_4321',
        'account_type': 'asset',
        'subtype': 'checking',
        'name': 'HDFC Test A/c 4321',
        'account_number_last4': '4321',
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

    // 3. Test Synthetic Debit SMS Processing
    final debitCandidate = IncomingTransactionCandidate(
      sourceRecordId: 'SRC:TELEPHONY_SMS:STAGE5C_001',
      sourceChannel: SourceChannel.sms,
      sender: 'VM-HDFCBK',
      body: 'Rs 1,500.00 debited from HDFC A/c **4321 on 18-Nov-26 at Swiggy. Ref: 554433221100',
      amountMinorUnits: 150000,
      direction: PostingDirection.debit,
      timestamp: now,
      externalReference: '554433221100',
      accountNumberLast4: '4321',
      accountId: 'acc_stage5c_hdfc_4321',
    );
    final debitResult = await dedupService.processWithConflictResolution(
      candidate: debitCandidate,
      db: database,
    );
    expect(debitResult.status, DeduplicationStatus.newEventCreated);
    expect(debitResult.eventId, isNotNull);

    // 4. Test Stage 0 Idempotent Re-ingestion of same source ID
    final duplicateDebitResult = await dedupService.processWithConflictResolution(
      candidate: debitCandidate,
      db: database,
    );
    expect(duplicateDebitResult.status, DeduplicationStatus.duplicateSourceRecord);
    expect(duplicateDebitResult.eventId, debitResult.eventId);

    // 5. Test Cross-Channel Matching: Push arrives for same payment with matching UTR
    final pushCandidate = IncomingTransactionCandidate(
      sourceRecordId: 'SRC:ANDROID_NOTIF:com.google.android.apps.nbu.paisa.user:99::1731900000000',
      sourceChannel: SourceChannel.push,
      sender: 'Google Pay',
      body: 'Paid Rs 1,500.00 to Swiggy. UPI Ref: 554433221100',
      amountMinorUnits: 150000,
      direction: PostingDirection.debit,
      timestamp: now.add(const Duration(seconds: 5)),
      externalReference: '554433221100',
      accountNumberLast4: '4321',
      accountId: 'acc_stage5c_hdfc_4321',
    );
    final pushResult = await dedupService.processWithConflictResolution(
      candidate: pushCandidate,
      db: database,
    );
    expect(pushResult.status, DeduplicationStatus.strongMatchMerged);
    expect(pushResult.eventId, debitResult.eventId);

    // 6. Test Review Queue Routing for Unreferenced Cross-Channel Collision
    final unrefCandidate = IncomingTransactionCandidate(
      sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:88::1731900000000',
      sourceChannel: SourceChannel.push,
      sender: 'PhonePe',
      body: 'Paid Rs 500.00 from HDFC A/c **4321',
      amountMinorUnits: 50000,
      direction: PostingDirection.debit,
      timestamp: now,
      accountNumberLast4: '4321',
      accountId: 'acc_stage5c_hdfc_4321',
    );
    final unref1 = await dedupService.processWithConflictResolution(
      candidate: unrefCandidate,
      db: database,
    );
    expect(unref1.status, DeduplicationStatus.newEventCreated);

    final unrefSms = IncomingTransactionCandidate(
      sourceRecordId: 'SRC:TELEPHONY_SMS:STAGE5C_002',
      sourceChannel: SourceChannel.sms,
      sender: 'VM-HDFCBK',
      body: 'Rs 500.00 debited from HDFC A/c **4321',
      amountMinorUnits: 50000,
      direction: PostingDirection.debit,
      timestamp: now.add(const Duration(seconds: 15)),
      accountNumberLast4: '4321',
      accountId: 'acc_stage5c_hdfc_4321',
    );
    final unref2 = await dedupService.processWithConflictResolution(
      candidate: unrefSms,
      db: database,
    );
    expect(unref2.status, DeduplicationStatus.routedToReviewQueue);

    // 7. Verify Trial Balance Across Postings in On-Device Database
    final balanceCheck = await database.rawQuery('''
      SELECT 
        COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END), 0) as total_debits,
        COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END), 0) as total_credits
      FROM ${TablesV24.postings};
    ''');
    final totalDebits = (balanceCheck.first['total_debits'] as num).toInt();
    final totalCredits = (balanceCheck.first['total_credits'] as num).toInt();
    expect(totalDebits, equals(totalCredits));
    expect(totalDebits, greaterThan(0));

    final totalEvents = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents};'),
    );
    final totalEvidence = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM ${TablesV24.evidence};'),
    );
    final totalPostings = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings};'),
    );
    final totalReviewItems = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM ${TablesV24.reviewCandidates};'),
    );

    debugPrint(
      'STAGE5C_DEVICE_EVIDENCE_SUMMARY '
      'package=${packageInfo.packageName} '
      'db=${AppDatabase.testDatabasePath} '
      'total_events=$totalEvents '
      'total_evidence=$totalEvidence '
      'total_postings=$totalPostings '
      'total_review_items=$totalReviewItems '
      'debits=$totalDebits '
      'credits=$totalCredits',
    );

    // 8. Clean Teardown
    await Stage5BTestBootstrap.tearDown();
    expect(Stage5BTestBootstrap.state, Stage5BBootstrapState.tornDown);
    debugPrint('STAGE5C_DEVICE_TEARDOWN_RESULT state=${Stage5BTestBootstrap.state}');
  });
}
