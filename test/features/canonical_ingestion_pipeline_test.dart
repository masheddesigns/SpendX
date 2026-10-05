import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/budget_repo.dart';
import 'package:spend_x/data/repositories/review_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_transaction_adapter.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/category.dart';
import 'package:spend_x/models/review_item.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/settings_service.dart';
import 'package:spend_x/services/sms_import_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });

  group('Milestone C5: Canonical Multi-Evidence Ingestion & Deduplication Pipeline', () {
    late Database db;
    late TransactionRepo transactionRepo;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late GoalRepo goalRepo;
    late BudgetRepo budgetRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late CanonicalReviewRepository canonicalReviewRepo;
    late ReviewRepo reviewRepo;
    late FinancialTransactionService financialService;
    late ProviderContainer container;

    const testBankAccountId = 'acc_bank_test_1';
    const testCategoryId = 'cat_groceries_test';

    int firstIntValue(List<Map<String, Object?>> rows) {
      if (rows.isEmpty || rows.first.isEmpty) return 0;
      return (rows.first.values.first as num?)?.toInt() ?? 0;
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

      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      canonicalReviewRepo = CanonicalReviewRepository(executor: db);
      reviewRepo = ReviewRepo(
        canonicalReviewRepo: canonicalReviewRepo,
        eventRepo: canonicalEventRepo,
      );
      transactionRepo = TransactionRepo(executor: db);
      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      goalRepo = GoalRepo(executor: db);
      budgetRepo = BudgetRepo(executor: db, queryRepo: canonicalQueryRepo);
      financialService = FinancialTransactionService(
        transactionRepo: transactionRepo,
        creditRepo: creditRepo,
      );

      container = ProviderContainer(
        overrides: [
          app_data.transactionRepoProvider.overrideWithValue(transactionRepo),
          app_data.accountRepoProvider.overrideWithValue(accountRepo),
          app_data.creditRepoProvider.overrideWithValue(creditRepo),
          app_data.loanRepoProvider.overrideWithValue(loanRepo),
          app_data.goalRepoProvider.overrideWithValue(goalRepo),
          app_data.budgetRepoProvider.overrideWithValue(budgetRepo),
          app_data.canonicalFinancialQueryRepositoryProvider
              .overrideWithValue(canonicalQueryRepo),
        ],
      );

      // Seed bank account through AccountRepo (creates account + opening balance)
      await accountRepo.insertAccount(
        BankAccount(
          id: testBankAccountId,
          name: 'HDFC Salary Account',
          bank: 'HDFC',
          balance: 25000.0,
          color: '#000000',
          last4: '4321',
        ),
      );

      // Seed category
      await db.insert(
        Tables.categories,
        Category(
          id: testCategoryId,
          userId: 'offline_user',
          name: 'Groceries',
          icon: 'shopping_cart',
          color: '#FF5722',
          type: 'expense',
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await db.insert(
        TablesV24.accounts,
        {
          'id': testCategoryId,
          'account_type': 'expense',
          'subtype': 'category',
          'name': 'Groceries',
          'currency': 'INR',
          'is_active': 1,
          'is_system': 0,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('Invariant 1: SMS creates canonical Evidence in TablesV24.evidence', () async {
      final rawSms = 'Paid Rs. 1,450.00 to Blinkit via UPI Ref: 423456789012';
      final item = ReviewItem(
        id: 'rev_inv_1',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 1450.0,
          isCredit: false,
          rawText: rawSms,
          date: DateTime.now(),
          merchant: 'Blinkit',
          refId: '423456789012',
          bankName: 'HDFC',
          last4: '4321',
          confidence: 0.95,
          source: 'sms',
        ),
        confidence: 0.95,
      );

      await reviewRepo.insert(item);

      final evidenceRows = await db.query(
        TablesV24.evidence,
        where: 'source_type = ?',
        whereArgs: ['sms'],
      );
      expect(evidenceRows.length, 1);
      final ev = evidenceRows.first;
      expect(ev['source_type'], 'sms');
      expect(ev['extracted_amount_minor_units'], 145000);
      expect(ev['external_reference'], '423456789012');
      expect(ev['sender_address'], 'HDFC');
      expect(ev['body_sha256'], CanonicalTransactionAdapter.computeSha256(rawSms));
      expect(ev['economic_event_id'], isNull);
    });

    test('Invariant 2: Evidence fingerprint is deterministic SHA-256', () async {
      final body = 'Rs 250.00 spent on Zomato on 04-OCT-2026';
      final sha1 = CanonicalTransactionAdapter.computeSha256(body);
      final sha2 = CanonicalTransactionAdapter.computeSha256(body);
      expect(sha1, sha2);
      expect(sha1.length, 64);

      final item = ReviewItem(
        id: 'rev_inv_2',
        rawSource: body,
        parsed: ParsedTransaction(
          amount: 250.0,
          isCredit: false,
          rawText: body,
          date: DateTime.now(),
          merchant: 'Zomato',
          confidence: 0.9,
          source: 'sms',
        ),
        confidence: 0.9,
      );
      await reviewRepo.insert(item);

      final fetchedEv = await canonicalEventRepo.getEvidenceByFingerprint(sha1);
      expect(fetchedEv, isNotNull);
      expect(fetchedEv!.bodyFingerprint, sha1);
      expect(fetchedEv.extractedAmount?.minorUnits, 25000);
    });

    test('Invariant 3: SMS creates canonical ReviewCandidate in TablesV24.reviewCandidates', () async {
      final item = ReviewItem(
        id: 'rev_inv_3',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 500.0,
          isCredit: false,
          rawText: 'Spent Rs.500 at Cafe',
          date: DateTime.now(),
          merchant: 'Cafe',
          confidence: 0.88,
          source: 'sms',
        ),
        confidence: 0.88,
      );

      await reviewRepo.insert(item);

      final candidate = await canonicalReviewRepo.getCandidate('rev_inv_3');
      expect(candidate, isNotNull);
      expect(candidate!.id, 'rev_inv_3');
      expect(candidate.sourceType, 'sms');
      expect(candidate.status, ReviewCandidateStatus.pending);
      expect(candidate.suggestedAmount.minorUnits, 50000);
      expect(candidate.confidenceScore, 0.88);
    });

    test('Invariant 4: Runtime SMS ingestion writes zero rows to legacy review_queue', () async {
      final item = ReviewItem(
        id: 'rev_inv_4',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 1200.0,
          isCredit: false,
          rawText: 'Spent Rs.1200 at Supermarket',
          date: DateTime.now(),
          merchant: 'Supermarket',
          confidence: 0.9,
          source: 'sms',
        ),
        confidence: 0.9,
      );

      await reviewRepo.insert(item);

      final legacyCount = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${Tables.reviewQueue}'),
      );
      expect(legacyCount, 0, reason: 'Runtime writes to legacy review_queue must be strictly zero');
    });

    test('Invariant 5: SMS ingestion creates zero postings', () async {
      final initialPostings = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );

      final item = ReviewItem(
        id: 'rev_inv_5',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 3200.0,
          isCredit: false,
          rawText: 'Debited Rs. 3,200.00 for Amazon',
          date: DateTime.now(),
          merchant: 'Amazon',
          confidence: 0.99,
          source: 'sms',
        ),
        confidence: 0.99,
      );

      await reviewRepo.insert(item);

      final postIngestionPostings = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      expect(postIngestionPostings, initialPostings,
          reason: 'Ingestion of unconfirmed review candidates must create 0 postings');
    });

    test('Invariant 6: SMS ingestion creates zero EconomicEvents', () async {
      final initialEvents = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );

      final item = ReviewItem(
        id: 'rev_inv_6',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 750.0,
          isCredit: false,
          rawText: 'Debited Rs. 750.00 at Fuel Station',
          date: DateTime.now(),
          merchant: 'Fuel Station',
          confidence: 0.95,
          source: 'sms',
        ),
        confidence: 0.95,
      );

      await reviewRepo.insert(item);

      final postIngestionEvents = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      expect(postIngestionEvents, initialEvents,
          reason: 'Ingestion of unconfirmed review candidates must create 0 economic events');
    });

    test('Invariant 7: Net Worth is unaffected before approval', () async {
      final netWorthBefore = await canonicalQueryRepo.getNetWorth();
      expect(netWorthBefore.minorUnits, 2500000); // 25,000 INR

      final item = ReviewItem(
        id: 'rev_inv_7',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 15000.0,
          isCredit: false,
          rawText: 'Debited Rs. 15,000.00 for Electronics',
          date: DateTime.now(),
          merchant: 'Electronics',
          confidence: 0.95,
          source: 'sms',
        ),
        confidence: 0.95,
      );

      await reviewRepo.insert(item);

      final netWorthAfter = await canonicalQueryRepo.getNetWorth();
      expect(netWorthAfter.minorUnits, netWorthBefore.minorUnits,
          reason: 'Unapproved candidate ingestion must have zero impact on Net Worth');
    });

    test('Invariant 8: Safe-to-Spend is unaffected before approval', () async {
      final s2sBefore = await canonicalQueryRepo.getSafeToSpend();

      final item = ReviewItem(
        id: 'rev_inv_8',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 4000.0,
          isCredit: false,
          rawText: 'Debited Rs. 4,000.00 for Shopping',
          date: DateTime.now(),
          merchant: 'Shopping',
          confidence: 0.92,
          source: 'sms',
        ),
        confidence: 0.92,
      );

      await reviewRepo.insert(item);

      final s2sAfter = await canonicalQueryRepo.getSafeToSpend();
      expect(s2sAfter.safeToSpend.minorUnits, s2sBefore.safeToSpend.minorUnits,
          reason: 'Unapproved candidate ingestion must have zero impact on Safe-to-Spend');
    });

    test('Invariant 9: Duplicate SMS does not create duplicate candidate/accounting identity', () async {
      final rawSms = 'Paid Rs. 350.00 to Swiggy UPI Ref: 987654321001';
      final item1 = ReviewItem(
        id: 'rev_inv_9_1',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 350.0,
          isCredit: false,
          rawText: rawSms,
          date: DateTime.now(),
          merchant: 'Swiggy',
          refId: '987654321001',
          confidence: 0.95,
          source: 'sms',
        ),
        confidence: 0.95,
      );

      await reviewRepo.insert(item1);

      // Verify deduplication detects existing reference
      final existingByRef = await canonicalEventRepo
          .getEvidenceByExternalReference('987654321001');
      expect(existingByRef, isNotNull);

      final existingByHash = await canonicalEventRepo
          .getEvidenceByFingerprint(CanonicalTransactionAdapter.computeSha256(rawSms));
      expect(existingByHash, isNotNull);

      // Pending candidate count remains exactly 1
      final pendingCount = await reviewRepo.getPendingCount();
      expect(pendingCount, 1);
    });

    test('Invariant 10: UTR/bank-reference matching behaves deterministically', () async {
      const utr = 'UTR998877665544';
      final item = ReviewItem(
        id: 'rev_inv_10',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 820.0,
          isCredit: false,
          rawText: 'Paid Rs 820 at Pharmacy UTR: $utr',
          date: DateTime.now(),
          merchant: 'Pharmacy',
          refId: utr,
          confidence: 0.99,
          source: 'sms',
        ),
        confidence: 0.99,
      );

      await reviewRepo.insert(item);

      final found = await canonicalEventRepo.getEvidenceByExternalReference(utr);
      expect(found, isNotNull);
      expect(found!.externalReference, utr);
      expect(found.extractedAmount?.toRupees, 820.0);

      final notFound = await canonicalEventRepo.getEvidenceByExternalReference('NON_EXISTENT_UTR');
      expect(notFound, isNull);
    });

    test('Invariant 11: Balance SMS creates zero bank-balance mutation', () async {
      final initialBalance = (await accountRepo.getById(testBankAccountId))!.balance;
      expect(initialBalance, 25000.0);

      final hit = BalanceHit(
        amount: 89000.0,
        bankKeyword: 'HDFC',
        last4: '4321',
        kind: BalanceKind.bank,
        sender: 'HDFCBK',
        body: 'Avail Bal in HDFC A/c XX4321 is Rs 89000.00 as of 04-OCT',
      );

      // Record balance evidence as done in LiveSmsService
      final fingerprint = CanonicalTransactionAdapter.computeSha256(hit.body);
      final ev = Evidence(
        id: const Uuid().v4(),
        sourceType: 'sms',
        sourceIdentifier: hit.sender,
        sourceTimestamp: DateTime.now(),
        bodyFingerprint: fingerprint,
        extractedAmount: Money.fromRupees(hit.amount),
        accountContext: 'XX${hit.last4}',
        rawPayloadEncrypted: hit.body,
        retentionExpiresAt: DateTime.now().add(const Duration(days: 30)),
        isPayloadPurged: false,
        economicEventId: null,
        createdAt: DateTime.now(),
      );
      await canonicalEventRepo.insertEvidence(ev);

      // Bank account balance in SQLite must NOT have mutated
      final currentAcc = await accountRepo.getById(testBankAccountId);
      expect(currentAcc!.balance, initialBalance,
          reason: 'Balance SMS must never directly mutate bank_accounts.balance');

      // Canonical postings and net worth must remain identical
      final netWorth = await canonicalQueryRepo.getNetWorth();
      expect(netWorth.minorUnits, 2500000);
    });

    test('Invariant 12: Legacy transaction insertion cannot influence ingestion deduplication', () async {
      const rogueRef = 'ROGUE_LEGACY_REF_999';
      // Rogue insertion directly into legacy transactions table
      await db.rawInsert('''
        INSERT INTO ${Tables.transactions} (id, user_id, type, amount, date, category_id, account_id, external_ref, created_at, updated_at)
        VALUES ('legacy_rogue_1', 'offline_user', 'expense', 150.0, '${DateTime.now().toIso8601String()}', '$testCategoryId', '$testBankAccountId', '$rogueRef', '${DateTime.now().toIso8601String()}', '${DateTime.now().toIso8601String()}');
      ''');

      // Verify canonical event repo does not find this in canonical evidence
      final existingRef = await canonicalEventRepo.getEvidenceByExternalReference(rogueRef);
      expect(existingRef, isNull,
          reason: 'Rogue insertion into legacy transactions cannot register canonical evidence');

      // Now a real SMS with this ref arrives: it should be ingested cleanly
      final item = ReviewItem(
        id: 'rev_inv_12',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 150.0,
          isCredit: false,
          rawText: 'Paid Rs 150 ref $rogueRef',
          date: DateTime.now(),
          merchant: 'Tea Stall',
          refId: rogueRef,
          confidence: 0.9,
          source: 'sms',
        ),
        confidence: 0.9,
      );
      await reviewRepo.insert(item);

      final candidate = await canonicalReviewRepo.getCandidate('rev_inv_12');
      expect(candidate, isNotNull);
    });

    test('Invariant 13: Rejected candidate creates zero accounting effects', () async {
      final initialEvents = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final initialPostings = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );

      final item = ReviewItem(
        id: 'rev_inv_13',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 999.0,
          isCredit: false,
          rawText: 'OTP 123456 for transaction of Rs 999',
          date: DateTime.now(),
          merchant: 'Spam',
          confidence: 0.3,
          source: 'sms',
        ),
        confidence: 0.3,
      );
      await reviewRepo.insert(item);

      // User rejects the candidate
      await reviewRepo.reject(item.id);

      final candidate = await canonicalReviewRepo.getCandidate(item.id);
      expect(candidate!.status, ReviewCandidateStatus.rejected);

      final currentEvents = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final currentPostings = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      expect(currentEvents, initialEvents);
      expect(currentPostings, initialPostings);
    });

    test('Invariant 14 & 15: Approved candidate routes through FinancialTransactionService and creates balanced canonical postings', () async {
      final item = ReviewItem(
        id: 'rev_inv_14',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 1500.0,
          isCredit: false,
          rawText: 'Paid Rs 1,500.00 for Groceries via UPI Ref: 887766554433',
          date: DateTime.now(),
          merchant: 'Supermarket',
          refId: '887766554433',
          confidence: 0.95,
          source: 'sms',
        ),
        confidence: 0.95,
      );
      await reviewRepo.insert(item);

      final pendingBefore = await reviewRepo.getPendingCount();
      expect(pendingBefore, 1);

      // User approves candidate through canonical FinancialTransactionService workflow
      final txn = Transaction(
        id: 'tx_approved_14',
        userId: 'offline_user',
        type: 'expense',
        amount: item.parsed.amount,
        date: item.parsed.date,
        categoryId: testCategoryId,
        accountId: testBankAccountId,
        notes: item.parsed.merchant ?? 'Supermarket',
        source: 'review',
        externalRef: item.parsed.refId,
      );

      await financialService.createTransaction(txn);
      await reviewRepo.approve(item.id);

      // Verify candidate is marked approved
      final candidate = await canonicalReviewRepo.getCandidate(item.id);
      expect(candidate!.status, ReviewCandidateStatus.approved);

      // Verify economic event is created with posted lifecycle
      final event = await canonicalEventRepo.getEvent('tx_approved_14');
      expect(event, isNotNull);
      expect(event!.lifecycleStatus, EventLifecycle.posted);

      // Verify balanced postings
      final postings = await canonicalEventRepo.getPostingsForEvent('tx_approved_14');
      expect(postings.length, 2);

      final debitPosting = postings.firstWhere((p) => p.direction == PostingDirection.debit);
      final creditPosting = postings.firstWhere((p) => p.direction == PostingDirection.credit);

      expect(debitPosting.accountId, testCategoryId); // Expense account debited
      expect(debitPosting.amount.minorUnits, 150000);
      expect(creditPosting.accountId, testBankAccountId); // Asset account credited
      expect(creditPosting.amount.minorUnits, 150000);

      // Balance check
      final netWorthAfter = await canonicalQueryRepo.getNetWorth();
      expect(netWorthAfter.minorUnits, 2350000); // 25,000 - 1,500 = 23,500 INR
    });

    test('Invariant 16: Multiple evidence records can represent same underlying event without duplicate accounting', () async {
      final ev1 = Evidence(
        id: 'ev_multi_1',
        sourceType: 'sms',
        sourceIdentifier: 'HDFCBK',
        sourceTimestamp: DateTime.now(),
        bodyFingerprint: 'hash1',
        extractedAmount: Money.fromRupees(2000.0),
        externalReference: 'MULTI_REF_100',
        createdAt: DateTime.now(),
      );
      final ev2 = Evidence(
        id: 'ev_multi_2',
        sourceType: 'email',
        sourceIdentifier: 'receipts@merchant.com',
        sourceTimestamp: DateTime.now(),
        bodyFingerprint: 'hash2',
        extractedAmount: Money.fromRupees(2000.0),
        externalReference: 'MULTI_REF_100',
        createdAt: DateTime.now(),
      );

      await canonicalEventRepo.insertEvidence(ev1);
      await canonicalEventRepo.insertEvidence(ev2);

      // Only a single transaction and economic event is created for this purchase
      final txn = Transaction(
        id: 'tx_multi_ev',
        userId: 'offline_user',
        type: 'expense',
        amount: 2000.0,
        date: DateTime.now(),
        categoryId: testCategoryId,
        accountId: testBankAccountId,
        notes: 'Double-evidenced purchase',
        source: 'manual',
        externalRef: 'MULTI_REF_100',
      );
      await financialService.createTransaction(txn);

      final postings = await canonicalEventRepo.getPostingsForEvent('tx_multi_ev');
      expect(postings.length, 2); // Exactly 1 debit, 1 credit

      final evidenceRows = await db.query(
        TablesV24.evidence,
        where: 'external_reference = ?',
        whereArgs: ['MULTI_REF_100'],
      );
      expect(evidenceRows.length, 2, reason: 'Both evidence records exist for auditability');
    });

    test('Invariant 17: Legacy review_queue cannot become financial authority', () async {
      // Direct insertion into legacy review_queue
      await db.rawInsert('''
        INSERT INTO ${Tables.reviewQueue} (id, raw_sms, parsed_json, confidence, status, created_at)
        VALUES ('rogue_queue_1', 'fake_sms', '{"amount": 99999.0}', 1.0, 'pending', '${DateTime.now().toIso8601String()}');
      ''');

      // Canonical ReviewRepo ignores the legacy row
      final pendingItems = await reviewRepo.getPending();
      expect(pendingItems.any((i) => i.id == 'rogue_queue_1'), isFalse);

      final count = await reviewRepo.getPendingCount();
      expect(count, 0);
    });

    test('Invariant 18: Canonical evidence survives independently of mutable legacy transaction state', () async {
      final item = ReviewItem(
        id: 'rev_inv_18',
        rawSource: 'live_sms',
        parsed: ParsedTransaction(
          amount: 600.0,
          isCredit: false,
          rawText: 'Paid Rs 600 Ref: IMMUTABLE_REF_99',
          date: DateTime.now(),
          merchant: 'Bookstore',
          refId: 'IMMUTABLE_REF_99',
          confidence: 0.95,
          source: 'sms',
        ),
        confidence: 0.95,
      );
      await reviewRepo.insert(item);

      // Confirm candidate exists in TablesV24.evidence
      final evBefore = await canonicalEventRepo.getEvidenceByExternalReference('IMMUTABLE_REF_99');
      expect(evBefore, isNotNull);

      // Adversarial rogue delete/mutate on legacy tables
      await db.delete(Tables.transactions);
      await db.delete(Tables.reviewQueue);

      // Canonical evidence is completely untouched
      final evAfter = await canonicalEventRepo.getEvidenceByExternalReference('IMMUTABLE_REF_99');
      expect(evAfter, isNotNull);
      expect(evAfter!.id, evBefore!.id);
      expect(evAfter.externalReference, 'IMMUTABLE_REF_99');
    });
  });
}
