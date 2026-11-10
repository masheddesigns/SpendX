import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_credit_adapter.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_loan_adapter.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/services/settings_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });

  group('Milestone 5.0 Phase 2: Reproduction Gate (DEF-505 to DEF-508)', () {
    late Database db;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late AccountRepo accountRepo;
    late CanonicalEventRepository canonicalEventRepo;

    setUp(() async {
      DatabaseAccessGate.instance.resetForTesting();

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

      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);

      // Seed common bank account
      final now = DateTime(2026, 11, 1, 10, 0);
      final bank = BankAccount(
        id: 'acc_bank_test',
        userId: 'user_1',
        name: 'HDFC Bank',
        bank: 'HDFC',
        balance: 50000.0,
        accountType: 'checking',
        createdAt: now,
        updatedAt: now,
      );
      await accountRepo.insertAccount(bank);
    });

    tearDown(() async {
      await db.close();
      DatabaseAccessGate.instance.resetForTesting();
    });

    // =========================================================================
    // DEF-505: Credit Card Reversal Ghosting
    // =========================================================================
    group('DEF-505: Credit Card Reversal Ghosting Reproduction', () {
      test('1. Purchase appears in card transaction history', () async {
        final card = CreditCard(
          id: 'card_505_1',
          name: 'Amazon ICICI',
          bank: 'ICICI',
          limitAmount: 100000.0,
          usedAmount: 0.0,
          dueDay: 15,
          billingDay: 1,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        final purchase = CreditTransaction(
          id: 'tx_p505_1',
          cardId: 'card_505_1',
          amount: 1500.0,
          date: DateTime(2026, 11, 2, 14, 0),
          category: 'Shopping',
          note: 'Wireless Mouse',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        );
        await creditRepo.insertTransaction(purchase);

        final history = await creditRepo.getTransactions('card_505_1');
        expect(history.length, 1);
        expect(history.first.id, 'tx_p505_1');
        expect(history.first.type, 'purchase');
        expect(history.first.amount, 1500.0);
        expect(history.first.status, 'active');
      });

      test('2. Reproduction: Deleted purchase is ghosted as 1 Purchase + 1 Payment in history', () async {
        final card = CreditCard(
          id: 'card_505_2',
          name: 'Amazon ICICI',
          bank: 'ICICI',
          limitAmount: 100000.0,
          usedAmount: 0.0,
          dueDay: 15,
          billingDay: 1,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        final purchase = CreditTransaction(
          id: 'tx_p505_2',
          cardId: 'card_505_2',
          amount: 2000.0,
          date: DateTime(2026, 11, 2, 14, 0),
          category: 'Shopping',
          note: 'Keyboard',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        );
        await creditRepo.insertTransaction(purchase);

        // Verify balance before deletion
        final balBefore = await creditRepo.getDerivedBalance('card_505_2');
        expect(balBefore.toRupees, 2000.0);

        // Delete/reverse the purchase
        await creditRepo.deleteTransaction('tx_p505_2');

        // Verify ledger balance is correctly neutralized (₹0)
        final balAfter = await creditRepo.getDerivedBalance('card_505_2');
        expect(balAfter.toRupees, 0.0, reason: 'Ledger double-entry balance is correctly 0');

        // NOW INSPECT PROJECTED TRANSACTION HISTORY:
        // Expected Accounting Invariant:
        // Reversal should either suppress the deleted purchase, or project original as 'reversed'
        // and NOT project the reversal posting as a legitimate 'payment'.
        final history = await creditRepo.getTransactions('card_505_2');

        // DEFECT OBSERVED:
        // 1. Both original purchase AND reversal event are returned (length == 2).
        expect(history.length, 2, reason: 'DEF-505 Defect: getTransactions returns both events');

        final originalEntry = history.firstWhere((t) => t.id == 'tx_p505_2');
        final reversalEntry = history.firstWhere((t) => t.id != 'tx_p505_2');

        // 2. Original purchase remains visible with status 'active' (not 'reversed')
        expect(originalEntry.status, 'active', reason: 'DEF-505 Defect: Original remains active');
        expect(originalEntry.type, 'purchase');

        // 3. Reversal event is ALSO projected as a 'purchase' with status 'active'!
        // Because eventType is 'credit_purchase', getTransactions matches the first branch
        // (eventType == 'credit_purchase') without checking reversal_of_event_id or direction!
        expect(reversalEntry.type, 'purchase',
            reason: 'DEF-505 Defect: Reversal projected as duplicate active purchase in transaction history');
        expect(reversalEntry.status, 'active');
        expect(reversalEntry.amount, 2000.0);
        expect(reversalEntry.note, contains('REVERSAL:'));
      });
    });

    // =========================================================================
    // DEF-506: Statement Reconciliation
    // =========================================================================
    group('DEF-506: Statement Reconciliation Reproduction', () {
      test('A. Historical statement balance reconciles against real-time ledger and wipes out subsequent purchases', () async {
        final card = CreditCard(
          id: 'card_506_a',
          name: 'HDFC Regalia',
          bank: 'HDFC',
          limitAmount: 200000.0,
          usedAmount: 0.0,
          dueDay: 20,
          billingDay: 31,
          createdAt: DateTime(2026, 10, 1),
        );
        await creditRepo.insert(card);

        // 1. Historical transactions up to Oct 31 (Statement period) = ₹10,000
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_oct_1',
          cardId: 'card_506_a',
          amount: 10000.0,
          date: DateTime(2026, 10, 25),
          category: 'Travel',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        expect((await creditRepo.getDerivedBalance('card_506_a')).toRupees, 10000.0);

        // 2. Subsequent purchase after statement date (Nov 02) = ₹3,000
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_nov_1',
          cardId: 'card_506_a',
          amount: 3000.0,
          date: DateTime(2026, 11, 2),
          category: 'Dining',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Real-time liability is now ₹13,000
        expect((await creditRepo.getDerivedBalance('card_506_a')).toRupees, 13000.0);

        // 3. Statement arrives via SMS / import reporting Oct 31 statement balance = ₹10,000
        // reconcileOutstanding is called with target = 10000.0
        await creditRepo.reconcileOutstanding(
          'card_506_a',
          10000.0,
          reason: 'October Statement Balance',
        );

        // DEFECT OBSERVED:
        // Current implementation compares targetUsedAmount (10000) directly against real-time liability (13000).
        // It posts an equity adjustment of -₹3,000, wiping out the November purchase from the card balance!
        final balanceAfter = await creditRepo.getDerivedBalance('card_506_a');
        expect(balanceAfter.toRupees, 10000.0,
            reason: 'DEF-506 Defect: Liability reduced to 10000, wiping out subsequent Nov purchase');

        // Check equity opening account: it received an artificial ₹3,000 credit adjustment!
        final equityRows = await db.rawQuery(
          'SELECT SUM(amount_minor_units) as total FROM ${TablesV24.postings} WHERE account_id = ?',
          [TablesV24.sysEquityOpening],
        );
        expect(equityRows.first['total'], isNotNull);
      });

      test('B. Race condition: concurrent transaction during reconcileOutstanding causes balance drift', () async {
        final card = CreditCard(
          id: 'card_506_b',
          name: 'HDFC Regalia',
          bank: 'HDFC',
          limitAmount: 200000.0,
          usedAmount: 0.0,
          dueDay: 20,
          billingDay: 1,
          createdAt: DateTime(2026, 10, 1),
        );
        await creditRepo.insert(card);

        // Initial balance = ₹5,000
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_init',
          cardId: 'card_506_b',
          amount: 5000.0,
          date: DateTime(2026, 11, 1),
          category: 'General',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Simulate concurrent read and write:
        // Reader A reads currentLiability = 5000, target is 8000 -> calculates delta = +3000
        final currentLiability = await creditRepo.getDerivedBalance('card_506_b');
        expect(currentLiability.toRupees, 5000.0);
        final targetLiability = Money.fromRupees(8000.0);
        final delta = targetLiability.minorUnits - currentLiability.minorUnits; // +3000

        // Interleaved Transaction: User makes ₹2,000 purchase before Reader A commits
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_interleaved',
          cardId: 'card_506_b',
          amount: 2000.0,
          date: DateTime(2026, 11, 2),
          category: 'General',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));
        expect((await creditRepo.getDerivedBalance('card_506_b')).toRupees, 7000.0);

        // Reader A now posts the stale delta (+3000)
        final rec = CanonicalCreditAdapter.createReconciliationRecords(
          cardId: 'card_506_b',
          cardName: 'HDFC Regalia',
          currentLiability: currentLiability,
          targetLiability: targetLiability,
        );
        await canonicalEventRepo.createAndPostEvent(
          rec!.event,
          postings: rec.postings,
          evidence: [rec.evidence],
        );

        // DEFECT OBSERVED:
        // Final balance is now ₹7,000 + ₹3,000 = ₹10,000 instead of target ₹8,000!
        final finalBal = await creditRepo.getDerivedBalance('card_506_b');
        expect(finalBal.toRupees, 10000.0,
            reason: 'DEF-506 Defect: Stale delta produced balance drift (10000 vs target 8000)');
      });
    });

    // =========================================================================
    // DEF-507: External Reference Deduplication
    // =========================================================================
    group('DEF-507: External Reference Deduplication Reproduction', () {
      test('1. CanonicalLoanAdapter omits external_reference column in Evidence', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final loan = Loan(
          id: 'loan_507_1',
          name: 'Personal Loan',
          bank: 'SBI',
          total: 100000.0,
          interestRate: 10.0,
          tenureMonths: 12,
          monthlyInstallment: 9000.0,
          startDate: now,
          paidAmount: 0.0,
          loanStatus: 'active',
          dueDay: 5,
        );
        await loanRepo.insertLoan(loan);

        // Record disbursement with external reference 'DISB_REF_001'
        await loanRepo.recordDisbursement(
          loanId: 'loan_507_1',
          assetAccountId: 'acc_bank_test',
          amount: 100000.0,
          timestamp: now,
          externalRef: 'DISB_REF_001',
        );

        // Inspect evidence row in SQLite:
        final rows = await db.query(TablesV24.evidence);
        expect(rows.isNotEmpty, isTrue);

        final disbEvidence = rows.firstWhere(
          (r) => (r['raw_payload_encrypted'] as String? ?? '').contains('DISB_REF_001'),
        );

        // DEFECT OBSERVED:
        // The indexed column `external_reference` is NULL because CanonicalLoanAdapter never sets it!
        expect(disbEvidence['external_reference'], isNull,
            reason: 'DEF-507 Defect: indexed column external_reference is unpopulated');
      });

      test('2. Reproduction: Encrypted evidence causes duplicate externalRef check to fail silently', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final loan = Loan(
          id: 'loan_507_2',
          name: 'Car Loan',
          bank: 'HDFC',
          total: 500000.0,
          interestRate: 8.5,
          tenureMonths: 36,
          monthlyInstallment: 16000.0,
          startDate: now,
          paidAmount: 0.0,
          loanStatus: 'active',
          dueDay: 10,
        );
        await loanRepo.insertLoan(loan);

        // First disbursement succeeds with externalRef 'TXN_ENC_123'
        await loanRepo.recordDisbursement(
          loanId: 'loan_507_2',
          assetAccountId: 'acc_bank_test',
          amount: 50000.0,
          timestamp: now,
          externalRef: 'TXN_ENC_123',
        );

        // Simulate realistic production encryption: the payload is encrypted ciphertext
        // Update the evidence row to simulate that rawPayload was encrypted
        await db.update(
          TablesV24.evidence,
          {'raw_payload_encrypted': 'AES256:GCM:c29tZV9lbmNyeXB0ZWRfY2lwaGVydGV4dA=='},
          where: 'raw_payload_encrypted LIKE ?',
          whereArgs: ['%TXN_ENC_123%'],
        );

        // DEFECT REPRODUCTION:
        // Attempt to submit the DUPLICATE disbursement with externalRef 'TXN_ENC_123' again!
        // Expected Invariant: Must throw AccountingInvariantException('Duplicate loan transaction...').
        // Actual Behavior: Because _checkDuplicateExternalRef runs SQL LIKE on raw_payload_encrypted,
        // it fails to match ciphertext, count returns 0, and the duplicate is ACCEPTED!
        bool duplicateAccepted = false;
        try {
          await loanRepo.recordDisbursement(
            loanId: 'loan_507_2',
            assetAccountId: 'acc_bank_test',
            amount: 50000.0,
            timestamp: now.add(const Duration(hours: 1)),
            externalRef: 'TXN_ENC_123',
          );
          duplicateAccepted = true;
        } on AccountingInvariantException {
          duplicateAccepted = false;
        }

        expect(duplicateAccepted, isTrue,
            reason: 'DEF-507 Defect: Duplicate disbursement accepted due to encrypted payload search failure');

        // Confirm derived loan liability doubled the disbursement (+50,000 twice on top of 500,000 opening)
        final balance = await loanRepo.getDerivedBalance('loan_507_2');
        expect(balance.toRupees, 600000.0,
            reason: 'DEF-507 Defect: Duplicate disbursement accepted into ledger (500k opening + 50k x 2)');
      });
    });

    // =========================================================================
    // DEF-508: Credit Card Refund Ceiling & Validation
    // =========================================================================
    group('DEF-508: Credit Card Refund Ceiling Reproduction', () {
      test('1. Reproduction: Excessive refund exceeding purchase amount is accepted without ceiling validation', () async {
        final card = CreditCard(
          id: 'card_508_1',
          name: 'SBI Cashback',
          bank: 'SBI',
          limitAmount: 50000.0,
          usedAmount: 0.0,
          dueDay: 15,
          billingDay: 1,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        // Original purchase: ₹1,000
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_card_orig_508',
          cardId: 'card_508_1',
          amount: 1000.0,
          date: DateTime(2026, 11, 2),
          category: 'Shopping',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        expect((await creditRepo.getDerivedBalance('card_508_1')).toRupees, 1000.0);

        // DEFECT REPRODUCTION:
        // Post refund of ₹5,000 (exceeds ₹1,000 purchase by ₹4,000)!
        // Expected Invariant: Must reject excessive refund exceeding original purchase (or total card liability).
        // Actual Behavior: Accepted blindly without ceiling validation!
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_card_excess_refund',
          cardId: 'card_508_1',
          amount: 5000.0,
          date: DateTime(2026, 11, 3),
          category: 'Shopping',
          type: 'refund',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Derived balance has become NEGATIVE liability (-₹4,000)
        final derivedBal = await creditRepo.getDerivedBalance('card_508_1');
        expect(derivedBal.minorUnits, -400000,
            reason: 'DEF-508 Defect: Excessive refund allowed liability to invert to negative ₹4,000');
      });

      test('2. Reproduction: Refund against deleted/reversed purchase is accepted', () async {
        final card = CreditCard(
          id: 'card_508_2',
          name: 'SBI Cashback',
          bank: 'SBI',
          limitAmount: 50000.0,
          usedAmount: 0.0,
          dueDay: 15,
          billingDay: 1,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        // Purchase ₹800
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_card_to_delete',
          cardId: 'card_508_2',
          amount: 800.0,
          date: DateTime(2026, 11, 2),
          category: 'Dining',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Delete the purchase (it is reversed)
        await creditRepo.deleteTransaction('tx_card_to_delete');
        expect((await creditRepo.getDerivedBalance('card_508_2')).toRupees, 0.0);

        // DEFECT REPRODUCTION:
        // Post refund against card referencing deleted purchase
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_refund_on_deleted',
          cardId: 'card_508_2',
          amount: 800.0,
          date: DateTime(2026, 11, 4),
          category: 'Dining',
          type: 'refund',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Actual Behavior: Accepted, driving liability to -₹800
        final finalBal = await creditRepo.getDerivedBalance('card_508_2');
        expect(finalBal.minorUnits, -80000,
            reason: 'DEF-508 Defect: Refund accepted against deleted purchase');
      });

      test('3. Verification: CreditTransaction model lacks relatedEntityId or purchase association', () {
        final tx = CreditTransaction(
          id: 'tx_check',
          cardId: 'card_1',
          amount: 100.0,
          date: DateTime.now(),
          category: 'Misc',
          type: 'refund',
          status: 'active',
        );

        final map = tx.toMap();
        expect(map.containsKey('relatedEntityId'), isFalse,
            reason: 'DEF-508: CreditTransaction lacks structured link to original purchase event');
        expect(map.containsKey('reversal_of_event_id'), isFalse);
      });
    });
  });
}
