import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_opening_balance_repository.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C3B-2: AccountRepo Canonical Migration Suite', () {
    late Database db;
    late AccountRepo accountRepo;
    late TransactionRepo transactionRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalOpeningBalanceRepository canonicalOpeningBalanceRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      // Create full schema including v24 canonical tables & triggers
      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      accountRepo = AccountRepo(executor: db);
      transactionRepo = TransactionRepo(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalOpeningBalanceRepo = CanonicalOpeningBalanceRepository(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    test('1. Basic Account: Create account with 0 balance -> balance = 0, postings = 0, 0 legacy writes', () async {
      final acc = BankAccount(
        id: 'acc_zero',
        name: 'Zero Balance Savings',
        bank: 'State Bank of India',
        accountType: 'savings',
        balance: 0.0,
      );

      final returnedId = await accountRepo.insertAccount(acc);
      expect(returnedId, 'acc_zero');

      // 1. Account row exists in canonical accounts table
      final canonicalAcc = await canonicalAccountRepo.getAccount('acc_zero');
      expect(canonicalAcc, isNotNull);
      expect(canonicalAcc!.name, 'Zero Balance Savings');
      expect(canonicalAcc.type, AccountType.asset);
      expect(canonicalAcc.isActive, isTrue);

      // 2. Financial postings count is exactly 0
      final postings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['acc_zero'],
      );
      expect(postings, isEmpty, reason: 'Zero-balance account creation must produce 0 financial postings');

      // 3. Derived balance is exactly 0
      final fetched = await accountRepo.getById('acc_zero');
      expect(fetched, isNotNull);
      expect(fetched!.balance, 0.0);

      final derivedMoney = await canonicalAccountRepo.getDerivedBalance('acc_zero');
      expect(derivedMoney.minorUnits, 0);

      // 4. Legacy bank_accounts table has ZERO writes to balance
      final legacyRows = await db.query(
        Tables.bankAccounts,
        where: 'id = ?',
        whereArgs: ['acc_zero'],
      );
      expect(legacyRows, isEmpty, reason: 'Zero dual-writes: legacy bank_accounts table is not written');
    });

    test('2. Opening Balance: Account creation with non-zero balance produces balanced event + sys_equity_opening', () async {
      final acc = BankAccount(
        id: 'acc_hdfc',
        name: 'HDFC Salary Account',
        bank: 'HDFC Bank',
        accountType: 'savings',
        balance: 50000.0, // ₹50,000.00 initial balance
      );

      await accountRepo.create(acc);

      // 1. Derived balance is strictly ₹50,000.00
      final fetched = await accountRepo.getById('acc_hdfc');
      expect(fetched, isNotNull);
      expect(fetched!.balance, 50000.0);

      final derivedMoney = await canonicalAccountRepo.getDerivedBalance('acc_hdfc');
      expect(derivedMoney.minorUnits, 5000000); // 50,000 * 100 paise

      // 2. Balanced canonical opening_balance event exists
      final eventRows = await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: ['evt_ob_acc_hdfc'],
      );
      expect(eventRows.length, 1);
      expect(eventRows.first['event_type'], 'opening_balance');
      expect(eventRows.first['lifecycle_status'], 'posted');

      // 3. Postings: Dr Asset acc_hdfc ₹50k, Cr Equity sys_equity_opening ₹50k
      final postingRows = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['evt_ob_acc_hdfc'],
        orderBy: 'sequence_number ASC',
      );
      expect(postingRows.length, 2);
      expect(postingRows[0]['account_id'], 'acc_hdfc');
      expect(postingRows[0]['direction'], 'debit');
      expect(postingRows[0]['amount_minor_units'], 5000000);

      expect(postingRows[1]['account_id'], TablesV24.sysEquityOpening);
      expect(postingRows[1]['direction'], 'credit');
      expect(postingRows[1]['amount_minor_units'], 5000000);

      // 4. Equity opening balance reflects exactly ₹50,000.00
      final equityBalance = await canonicalAccountRepo.getDerivedBalance(TablesV24.sysEquityOpening);
      expect(equityBalance.minorUnits, 5000000);

      // 5. OpeningBalanceReconciliation record exists with provenance
      final rec = await canonicalOpeningBalanceRepo.getReconciliation('rec_ob_acc_hdfc');
      expect(rec, isNotNull);
      expect(rec!.accountId, 'acc_hdfc');
      expect(rec.adjustmentDelta.minorUnits, 5000000);
      expect(rec.provenanceSource, 'manual_account_creation');
      expect(rec.status, ReconciliationStatus.equityAdjustmentRequired);

      // 6. Zero income or expense postings created
      final expenseRows = await db.rawQuery('''
        SELECT COUNT(*) as count FROM ${TablesV24.postings} p
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        WHERE p.economic_event_id = 'evt_ob_acc_hdfc' AND a.account_type IN ('income', 'expense');
      ''');
      expect((expenseRows.first['count'] as num).toInt(), 0);
    });

    test('3. Income: Canonical income event increases asset account derived balance', () async {
      final acc = BankAccount(
        id: 'acc_icici',
        name: 'ICICI Savings',
        bank: 'ICICI Bank',
        balance: 10000.0, // Starting: ₹10,000
      );
      await accountRepo.create(acc);

      // Post income of ₹15,000 via migrated TransactionRepo
      final incomeTx = Transaction(
        id: 'tx_income_1',
        userId: 'user_1',
        type: 'income',
        amount: 15000.0,
        accountId: 'acc_icici',
        categoryId: 'cat_salary',
        date: DateTime.now(),
      );
      await transactionRepo.insert(incomeTx);

      // Derived balance reflects starting (10k) + income (15k) = ₹25,000.00
      final updated = await accountRepo.getById('acc_icici');
      expect(updated!.balance, 25000.0);

      final derivedMoney = await canonicalAccountRepo.getDerivedBalance('acc_icici');
      expect(derivedMoney.minorUnits, 2500000);
    });

    test('4. Expense: Canonical expense event decreases asset account derived balance', () async {
      final acc = BankAccount(
        id: 'acc_axis',
        name: 'Axis Bank',
        bank: 'Axis Bank',
        balance: 40000.0, // Starting: ₹40,000
      );
      await accountRepo.create(acc);

      // Post expense of ₹12,000 via migrated TransactionRepo
      final expTx = Transaction(
        id: 'tx_exp_1',
        userId: 'user_1',
        type: 'expense',
        amount: 12000.0,
        accountId: 'acc_axis',
        categoryId: 'cat_groceries',
        date: DateTime.now(),
      );
      await transactionRepo.insert(expTx);

      // Derived balance reflects starting (40k) - expense (12k) = ₹28,000.00
      final updated = await accountRepo.getById('acc_axis');
      expect(updated!.balance, 28000.0);

      final derivedMoney = await canonicalAccountRepo.getDerivedBalance('acc_axis');
      expect(derivedMoney.minorUnits, 2800000);
    });

    test('5. Transfer: Transfer between two asset accounts preserves total assets', () async {
      final accA = BankAccount(
        id: 'acc_a',
        name: 'Account A',
        bank: 'Bank A',
        balance: 30000.0,
      );
      final accB = BankAccount(
        id: 'acc_b',
        name: 'Account B',
        bank: 'Bank B',
        balance: 10000.0,
      );
      await accountRepo.create(accA);
      await accountRepo.create(accB);

      // Transfer ₹7,000 from acc_a to acc_b
      final transferTx = Transaction(
        id: 'tx_transfer_1',
        userId: 'user_1',
        type: 'transfer',
        amount: 7000.0,
        accountId: 'acc_a',
        relatedEntityId: 'acc_b',
        date: DateTime.now(),
      );
      await transactionRepo.insert(transferTx);

      final fetchedA = await accountRepo.getById('acc_a');
      final fetchedB = await accountRepo.getById('acc_b');

      expect(fetchedA!.balance, 23000.0); // 30k - 7k
      expect(fetchedB!.balance, 17000.0); // 10k + 7k

      // Total assets unchanged: 23k + 17k = 40k
      final allAccounts = await accountRepo.getAll();
      final totalAssets = allAccounts
          .where((a) => a.id == 'acc_a' || a.id == 'acc_b')
          .fold<double>(0.0, (sum, a) => sum + a.balance);
      expect(totalAssets, 40000.0);
    });

    test('6. Draft vs Posted: Draft contributes 0; posting changes balance exactly once', () async {
      final acc = BankAccount(
        id: 'acc_draft_test',
        name: 'Draft Test Account',
        bank: 'Test Bank',
        balance: 5000.0,
      );
      await accountRepo.create(acc);

      // Create a draft event with postings for ₹50,000
      final draftEventId = 'evt_draft_1';
      final draftPostings = [
        Posting(
          id: 'pst_dr_1',
          economicEventId: draftEventId,
          accountId: 'acc_draft_test',
          direction: PostingDirection.debit,
          amount: Money.fromRupees(50000),
          createdAt: DateTime.now(),
        ),
        Posting(
          id: 'pst_dr_2',
          economicEventId: draftEventId,
          accountId: 'cat_salary',
          direction: PostingDirection.credit,
          amount: Money.fromRupees(50000),
          createdAt: DateTime.now(),
        ),
      ];

      // Insert salary category account
      await canonicalAccountRepo.createAccount(
        Account(
          id: 'cat_salary',
          name: 'Salary',
          type: AccountType.income,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      await canonicalEventRepo.createDraftEvent(
        EconomicEvent(
          id: draftEventId,
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.draft,
          occurredAt: DateTime.now(),
          description: 'Pending Salary',
          postings: draftPostings,
          createdAt: DateTime.now(),
        ),
        postings: draftPostings,
      );

      // 1. While in DRAFT, derived balance MUST remain strictly ₹5,000.00
      final balanceDuringDraft = await accountRepo.getById('acc_draft_test');
      expect(balanceDuringDraft!.balance, 5000.0, reason: 'Draft events must contribute 0 to derived balance');

      // 2. Transition draft to POSTED
      await canonicalEventRepo.postEvent(draftEventId);

      // 3. After POSTING, balance changes exactly once: ₹5,000 + ₹50,000 = ₹55,000.00
      final balanceAfterPosted = await accountRepo.getById('acc_draft_test');
      expect(balanceAfterPosted!.balance, 55000.0);
    });

    test('7. Immutability: SQLite triggers prevent direct UPDATE or DELETE on posted postings', () async {
      final acc = BankAccount(
        id: 'acc_immut',
        name: 'Immutable Account',
        bank: 'Bank',
        balance: 1000.0,
      );
      await accountRepo.create(acc);

      // Verify direct modification of posted posting is rejected by SQLite trigger
      expect(
        () async => await db.rawUpdate(
          "UPDATE ${TablesV24.postings} SET amount_minor_units = 999999 WHERE account_id = 'acc_immut';",
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Verify direct deletion of posted posting is rejected by SQLite trigger
      expect(
        () async => await db.rawDelete(
          "DELETE FROM ${TablesV24.postings} WHERE account_id = 'acc_immut';",
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('8. Historical Account: Deleting account with postings soft-archives it; queryable by id', () async {
      final acc = BankAccount(
        id: 'acc_hist',
        name: 'Historical Account',
        bank: 'Historical Bank',
        balance: 15000.0,
      );
      await accountRepo.create(acc);

      // Delete the account
      final deleteResult = await accountRepo.deleteAccount('acc_hist');
      expect(deleteResult, 1);

      // 1. Account is NOT physically deleted from accounts table because it has postings
      final canonicalRow = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: ['acc_hist'],
      );
      expect(canonicalRow.length, 1);
      expect(canonicalRow.first['is_active'], 0, reason: 'Accounts with financial history must be soft-archived');

      // 2. Historical postings for acc_hist remain completely intact
      final postings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['acc_hist'],
      );
      expect(postings.length, 1, reason: 'acc_hist leg of opening balance remains intact');

      // 3. AccountRepo.getAll() excludes the archived account
      final allAccounts = await accountRepo.getAll();
      expect(allAccounts.any((a) => a.id == 'acc_hist'), isFalse);

      // 4. AccountRepo.getById still resolves the historical account with its ledger balance intact
      final historical = await accountRepo.getById('acc_hist');
      expect(historical, isNotNull);
      expect(historical!.balance, 15000.0);

      // 5. Account with ZERO postings is physically deleted
      final cleanAcc = BankAccount(
        id: 'acc_clean',
        name: 'Clean Account',
        bank: 'Clean Bank',
        balance: 0.0,
      );
      await accountRepo.insertAccount(cleanAcc);
      await accountRepo.deleteAccount('acc_clean');

      final cleanRow = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: ['acc_clean'],
      );
      expect(cleanRow, isEmpty, reason: 'Accounts with 0 postings can be physically deleted');
    });

    test('9. Legacy Firewall & Anti-Tamper: Direct writes to bank_accounts.balance do NOT alter truth', () async {
      final acc = BankAccount(
        id: 'acc_tamper',
        name: 'Tamper-Proof Account',
        bank: 'Fortress Bank',
        balance: 20000.0,
      );
      await accountRepo.create(acc);

      // Manually insert / mutate a row in transitional bank_accounts table with fake balance
      await db.insert(
        Tables.bankAccounts,
        {
          'id': 'acc_tamper',
          'name': 'Tampered Account',
          'bank': 'Fortress Bank',
          'balance': 9999999.0, // FAKE BALANCE
          'account_type': 'savings',
          'is_asset': 1,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
      );

      // AccountRepo must ignore the legacy table's fake balance and report canonical ₹20,000.00
      final fetched = await accountRepo.getById('acc_tamper');
      expect(fetched!.balance, 20000.0);

      final allAccounts = await accountRepo.getAll();
      final inList = allAccounts.firstWhere((a) => a.id == 'acc_tamper');
      expect(inList.balance, 20000.0);
    });

    test('10. updateBalance & adjustBalance: Route through canonical reconciliation with provenance', () async {
      final acc = BankAccount(
        id: 'acc_sms_rec',
        name: 'SMS Reconciled Account',
        bank: 'Kotak Bank',
        balance: 10000.0, // Initial ₹10,000.00
      );
      await accountRepo.create(acc);

      // SMS reports updated balance of ₹14,500.00 (delta: +₹4,500.00)
      await accountRepo.updateBalance('acc_sms_rec', 14500.0);

      // 1. Derived balance is updated to ₹14,500.00
      final updated = await accountRepo.getById('acc_sms_rec');
      expect(updated!.balance, 14500.0);

      // 2. Double-entry reconciliation event exists
      final reconciliationRecords = await canonicalOpeningBalanceRepo.listReconciliations();
      final latestRec = reconciliationRecords.firstWhere(
        (r) => r.accountId == 'acc_sms_rec' && r.provenanceSource == 'sms_balance_update',
      );
      expect(latestRec.adjustmentDelta.minorUnits, 450000); // +₹4,500.00
      expect(latestRec.legacyReportedBalance.minorUnits, 1450000);
      expect(latestRec.reconstructedBalanceFromTxns.minorUnits, 1000000);

      // 3. Equity opening balance reflects the delta (+₹4,500)
      final equityBalance = await canonicalAccountRepo.getDerivedBalance(TablesV24.sysEquityOpening);
      // Started with 10k opening + 4.5k adjustment = ₹14,500.00
      expect(equityBalance.minorUnits, 1450000);

      // 4. Test adjustBalance: subtract ₹2,500.00 -> balance becomes ₹12,000.00
      await accountRepo.adjustBalance('acc_sms_rec', -2500.0);
      final adjusted = await accountRepo.getById('acc_sms_rec');
      expect(adjusted!.balance, 12000.0);

      // 5. Zero writes to legacy bank_accounts table
      final legacyRows = await db.query(
        Tables.bankAccounts,
        where: 'id = ?',
        whereArgs: ['acc_sms_rec'],
      );
      expect(legacyRows, isEmpty);
    });
  });
}
