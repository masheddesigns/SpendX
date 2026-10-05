import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_opening_balance_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Canonical Auxiliary Repositories Tests', () {
    late Database db;
    late CanonicalAccountRepository accountRepo;
    late CanonicalReviewRepository reviewRepo;
    late CanonicalEarmarkRepository earmarkRepo;
    late CanonicalOpeningBalanceRepository obrRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await TablesV24.createAllV24(db);
      await TablesV24.installTriggers(db);
      await TablesV24.seedSystemAccounts(db);

      accountRepo = CanonicalAccountRepository(executor: db);
      reviewRepo = CanonicalReviewRepository(executor: db);
      earmarkRepo = CanonicalEarmarkRepository(executor: db);
      obrRepo = CanonicalOpeningBalanceRepository(executor: db);

      // Seed bank account
      final now = DateTime.now();
      await accountRepo.createAccount(Account(
        id: 'acc_bank_aux',
        name: 'HDFC Aux',
        type: AccountType.asset,
        createdAt: now,
        updatedAt: now,
      ));
    });

    tearDown(() async {
      await db.close();
    });

    test('CanonicalReviewRepository: candidate lifecycle without ledger impact', () async {
      final now = DateTime.now();
      final candidate = ReviewCandidate(
        id: 'cand_1',
        sourceType: 'sms',
        rawPayload: 'Paid INR 450.00 at Starbucks via UPI',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromMinorUnits(45000), // ₹450.00
        suggestedAccountId: 'acc_bank_aux',
        confidenceScore: 0.95,
        status: ReviewCandidateStatus.pending,
        createdAt: now,
      );

      await reviewRepo.createCandidate(candidate);

      final retrieved = await reviewRepo.getCandidate('cand_1');
      expect(retrieved, isNotNull);
      expect(retrieved!.status, ReviewCandidateStatus.pending);
      expect(retrieved.confidenceScore, 0.95);

      // Verify listing with filter
      final pendingList = await reviewRepo.listCandidates(status: ReviewCandidateStatus.pending);
      expect(pendingList.length, 1);

      // Approve candidate
      await reviewRepo.approveCandidate('cand_1');
      final approved = await reviewRepo.getCandidate('cand_1');
      expect(approved!.status, ReviewCandidateStatus.approved);

      // Reject candidate
      await reviewRepo.rejectCandidate('cand_1');
      final rejected = await reviewRepo.getCandidate('cand_1');
      expect(rejected!.status, ReviewCandidateStatus.rejected);

      // Crucial: review candidates must produce ZERO postings
      final postingsCount = (await db.rawQuery(
        'SELECT COUNT(*) AS c FROM ${TablesV24.postings};',
      )).first['c'] as int;
      expect(postingsCount, 0);
    });

    test('CanonicalEarmarkRepository: earmark reservations and cleanup', () async {
      final now = DateTime.now();
      final earmark1 = AssetEarmark(
        id: 'em_car',
        goalId: 'goal_car',
        assetAccountId: 'acc_bank_aux',
        earmarkedAmount: Money.fromMinorUnits(5000000), // ₹50,000.00
        createdAt: now,
        updatedAt: now,
      );
      final earmark2 = AssetEarmark(
        id: 'em_trip',
        goalId: 'goal_trip',
        assetAccountId: 'acc_bank_aux',
        earmarkedAmount: Money.fromMinorUnits(3000000), // ₹30,000.00
        createdAt: now,
        updatedAt: now,
      );

      await earmarkRepo.setEarmark(earmark1);
      await earmarkRepo.setEarmark(earmark2);

      // Verify total earmarked for account
      final totalEarmarked = await earmarkRepo.getTotalEarmarkedForAccount('acc_bank_aux');
      expect(totalEarmarked.minorUnits, 8000000); // ₹80,000.00

      // Query by goal
      final carEarmarks = await earmarkRepo.getEarmarksForGoal('goal_car');
      expect(carEarmarks.length, 1);
      expect(carEarmarks.first.earmarkedAmount.minorUnits, 5000000);

      // Delete by ID
      await earmarkRepo.deleteEarmark('em_trip');
      expect((await earmarkRepo.getTotalEarmarkedForAccount('acc_bank_aux')).minorUnits, 5000000);

      // Delete by goal
      await earmarkRepo.deleteEarmarksForGoal('goal_car');
      expect((await earmarkRepo.getTotalEarmarkedForAccount('acc_bank_aux')).minorUnits, 0);
    });

    test('CanonicalOpeningBalanceRepository: provenance and reconciliation delta preservation', () async {
      final now = DateTime.now();
      final obr = OpeningBalanceReconciliation(
        id: 'obr_1',
        accountId: 'acc_bank_aux',
        legacyReportedBalance: Money.fromMinorUnits(1500000), // ₹15,000.00
        reconstructedBalanceFromTxns: Money.fromMinorUnits(500000), // ₹5,000.00
        reconciliationReason: 'Legacy unbacked initial balance on account creation',
        provenanceSource: 'migration_v24_reconciliation',
        status: ReconciliationStatus.equityAdjustmentRequired,
        createdAt: now,
      );

      expect(obr.adjustmentDelta.minorUnits, 1000000); // ₹10,000.00 delta

      await obrRepo.saveReconciliation(obr);

      final retrieved = await obrRepo.getReconciliation('obr_1');
      expect(retrieved, isNotNull);
      expect(retrieved!.adjustmentDelta.minorUnits, 1000000);
      expect(retrieved.status, ReconciliationStatus.equityAdjustmentRequired);
      expect(retrieved.reconciliationReason, contains('Legacy unbacked initial balance'));

      final byAccount = await obrRepo.getReconciliationForAccount('acc_bank_aux');
      expect(byAccount, isNotNull);
      expect(byAccount!.id, 'obr_1');
    });
  });
}
