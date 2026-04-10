import 'package:uuid/uuid.dart';
import '../data/repositories/ledger_repo.dart';
import '../data/repositories/maintenance_repo.dart';
import '../models/category.dart' as app;
import '../models/credit_card.dart';
import '../models/credit_transaction.dart';
import '../models/bank_account.dart';
import '../models/loan.dart';
import '../models/ledger_transaction.dart';
import '../models/lending.dart';
import 'database_helper.dart';
import 'financial_intelligence_service.dart';
import '../domain/credit/credit_card_service.dart';
import '../domain/loans/loan_service.dart';
import 'dart:math';

class DevToolsService {
  DevToolsService._();
  static final DevToolsService instance = DevToolsService._();

  final _rand = Random();
  final _uuid = const Uuid();
  final _db = DatabaseHelper.instance;
  final _ledgerRepo = LedgerRepo();
  final _creditService = CreditCardService();
  final _loanService = LoanService();
  final _intel = FinancialIntelligenceService.instance;
  final _maintenanceRepo = MaintenanceRepo();

  Future<void> clearAll() => clearAllData();

  Future<void> seedDummyData({
    int days = 30,
    String scenario = 'mixed',
  }) => generateDummyData(days: days, scenario: scenario);

  Future<void> clearAllData() async {
    await _db.clearAllData();
    _db.notifyDataChange();
  }

  Future<void> clearExpenses() async {
    await _maintenanceRepo.clearExpenses();
    _db.notifyDataChange();
  }

  Future<void> clearCredit() async {
    await _maintenanceRepo.clearCreditData();
    _db.notifyDataChange();
  }

  Future<void> clearLoans() async {
    await _maintenanceRepo.clearLoans();
    _db.notifyDataChange();
  }

  /// Master Dummy Data Generator v4
  Future<void> generateDummyData({
    int days = 30,
    String scenario = 'mixed',
  }) async {
    await clearAllData();

    final isStress = scenario == 'stress';
    final totalDays = isStress ? 730 : days;

    // 1. Create Core Categories
    final categories = [
      app.Category(
        id: 'cat_food',
        userId: 'offline_user',
        name: 'Food',
        icon: 'fastfood',
        color: '#FF5252',
        type: 'expense',
      ),
      app.Category(
        id: 'cat_travel',
        userId: 'offline_user',
        name: 'Travel',
        icon: 'flight',
        color: '#448AFF',
        type: 'expense',
      ),
      app.Category(
        id: 'cat_shop',
        userId: 'offline_user',
        name: 'Shopping',
        icon: 'shopping_bag',
        color: '#E040FB',
        type: 'expense',
      ),
      app.Category(
        id: 'cat_bills',
        userId: 'offline_user',
        name: 'Bills',
        icon: 'receipt',
        color: '#FFAB40',
        type: 'expense',
      ),
      app.Category(
        id: 'cat_emi',
        userId: 'offline_user',
        name: 'EMI',
        icon: 'payment',
        color: '#7C4DFF',
        type: 'expense',
      ),
      app.Category(
        id: 'cat_salary',
        userId: 'offline_user',
        name: 'Salary',
        icon: 'work',
        color: '#00BCD4',
        type: 'income',
      ),
      app.Category(
        id: 'cat_rent',
        userId: 'offline_user',
        name: 'Rent',
        icon: 'home',
        color: '#FF5722',
        type: 'expense',
      ),
    ];

    for (var cat in categories) {
      await _db.insertCategory(cat);
    }

    // 2. Create Bank Accounts
    final axis = BankAccount(
      id: 'acc_axis',
      name: 'Axis Bank',
      bank: 'Axis',
      balance: 0,
      isAsset: true,
    );
    final hdfc = BankAccount(
      id: 'acc_hdfc',
      name: 'HDFC Bank',
      bank: 'HDFC',
      balance: 0,
      isAsset: true,
    );
    final sbi = BankAccount(
      id: 'acc_sbi',
      name: 'SBI Savings',
      bank: 'SBI',
      balance: 0,
      isAsset: true,
    );

    await _db.insertBankAccount(axis);
    await _db.insertBankAccount(hdfc);
    if (isStress) await _db.insertBankAccount(sbi);

    // Initial Balances
    final initialDate = DateTime.now().subtract(Duration(days: totalDays + 1));
    await _ledgerRepo.insert(
      LedgerTransaction(
        type: LedgerType.income,
        amount: isStress ? 500000 : 50000,
        date: initialDate,
        accountId: axis.id,
        note: 'Opening Balance',
      ),
    );
    await _ledgerRepo.insert(
      LedgerTransaction(
        type: LedgerType.income,
        amount: isStress ? 800000 : 80000,
        date: initialDate,
        accountId: hdfc.id,
        note: 'Opening Balance',
      ),
    );

    // 3. Create Credit Cards
    final cards = <String>[];
    cards.add(
      await _db.insertCreditCard(
        CreditCard(
          name: 'HDFC Regalia',
          bank: 'HDFC',
          last4: '4545',
          limitAmount: 100000,
          usedAmount: 0,
          billingDay: 15,
          dueDay: 5,
          cardType: 'visa',
          color: '#1A237E',
        ),
      ),
    );

    if (isStress) {
      cards.add(
        await _db.insertCreditCard(
          CreditCard(
            name: 'SBI Prime',
            bank: 'SBI',
            last4: '1212',
            limitAmount: 250000,
            usedAmount: 0,
            billingDay: 20,
            dueDay: 10,
            cardType: 'mastercard',
            color: '#004D40',
          ),
        ),
      );
      cards.add(
        await _db.insertCreditCard(
          CreditCard(
            name: 'ICICI Amazon',
            bank: 'ICICI',
            last4: '9999',
            limitAmount: 50000,
            usedAmount: 0,
            billingDay: 1,
            dueDay: 18,
            cardType: 'visa',
            color: '#E65100',
          ),
        ),
      );
    }

    // 4. Create Loans
    final loanIds = <String>['loan_auto_1'];
    if (isStress) loanIds.addAll(['loan_home_1', 'loan_personal_1']);

    for (var lId in loanIds) {
      final isHome = lId.contains('home');
      final lPrincipal = isHome
          ? 5000000.0
          : (lId.contains('auto') ? 800000.0 : 200000.0);
      final lRate = isHome ? 8.5 : 12.0;
      final lTenure = isHome ? 180 : (lId.contains('auto') ? 60 : 36);
      final loanStart = DateTime.now().subtract(Duration(days: totalDays + 30));
      final loanEMI = _loanService.calculateMonthlyInstallment(
        lPrincipal,
        lRate,
        lTenure,
      );

      final loan = Loan(
        id: lId,
        name: isHome
            ? 'Home Loan'
            : (lId.contains('auto') ? 'Car Loan' : 'Personal Loan'),
        bank: isHome ? 'LIC' : 'SBI',
        total: lPrincipal,
        interestRate: lRate,
        tenureMonths: lTenure,
        monthlyInstallment: loanEMI,
        startDate: loanStart,
        paidAmount: 0,
        loanStatus: 'active',
        dueDay: 5,
        type: LoanType.reducing,
      );

      await _db.insertLoan(loan);
      await _loanService.generateInstallments(
        lId,
        lPrincipal,
        lTenure,
        loanStart,
        lRate,
      );
    }

    // 5. Daily Simulation Loop
    final startTime = DateTime.now().subtract(Duration(days: totalDays));

    for (int i = 0; i <= totalDays; i++) {
      final currentDate = startTime.add(Duration(days: i));

      // Prevent UI freezing on main thread by yielding occasionally
      if (i % 20 == 0) await Future.delayed(const Duration(milliseconds: 1));

      // A. Take Snapshot
      await _intel.takeSnapshot(axis.id, timestamp: currentDate);
      await _intel.takeSnapshot(hdfc.id, timestamp: currentDate);

      // B. Income
      if (currentDate.day == 1) {
        // Salary
        await _ledgerRepo.insert(
          LedgerTransaction(
            type: LedgerType.income,
            amount: isStress ? 150000 : 75000,
            date: currentDate,
            accountId: hdfc.id,
            categoryId: 'cat_salary',
            note: 'Monthly Salary',
          ),
        );
      }

      // D. Expenses
      final prob = isStress ? 0.9 : 0.7;
      if (_rand.nextDouble() < prob) {
        final expenseCount = isStress
            ? (_rand.nextInt(8) + 3)
            : (_rand.nextInt(3) + 1);
        for (int e = 0; e < expenseCount; e++) {
          final isCredit = (isStress || scenario == 'credit_heavy')
              ? _rand.nextDouble() < 0.6
              : _rand.nextDouble() < 0.3;
          final amount = (_rand.nextInt(isStress ? 5000 : 2000) + 50)
              .toDouble();
          final cat = categories[_rand.nextInt(categories.length - 1)];

          if (isCredit) {
            final cId = cards[_rand.nextInt(cards.length)];
            await _creditService.addCreditTransaction(
              CreditTransaction(
                id: _uuid.v4(),
                cardId: cId,
                amount: amount,
                date: currentDate,
                category: cat.name,
                categoryId: cat.id,
                status: 'active',
                type: 'purchase',
                note: 'Purchase stress-$i-$e',
              ),
            );
          } else {
            final accId = _rand.nextBool() ? axis.id : hdfc.id;
            await _ledgerRepo.insert(
              LedgerTransaction(
                type: LedgerType.expense,
                amount: amount,
                date: currentDate,
                accountId: accId,
                categoryId: cat.id,
                note: 'Cash Stress-$i-$e',
              ),
            );
          }
        }
      }

      // E. Credit Card Payments (Simplified)
      if (currentDate.day == 25) {
        for (var cId in cards) {
          final bill = await _creditService.calculateOutstanding(cId);
          if (bill > 500) {
            await _creditService.processPayment(
              cardId: cId,
              paymentAmount: bill * 0.9,
              date: currentDate,
              accountId: hdfc.id,
              note: 'Partial CC Payment',
            );
          }
        }
      }

      // F. Loan Payments (Simplified)
      if (currentDate.day == 5) {
        for (var lId in loanIds) {
          final insts = await (await _db.database).query(
            DatabaseHelper.tableLoanInstallments,
            where: 'loanId = ? AND status = ?',
            whereArgs: [lId, 'pending'],
            limit: 1,
          );
          if (insts.isNotEmpty) {
            await _loanService.recordInstallmentPayment(
              insts.first['id'] as String,
              accountId: axis.id,
            );
          }
        }
      }
    }

    // 6. Create Lending Records
    final names = [
      'John',
      'Jane',
      'Mike',
      'Sarah',
      'Alex',
      'Chris',
      'Emma',
      'David',
      'Sophia',
      'James',
    ];
    final lendingCount = isStress ? 25 : 5;
    for (int i = 0; i < lendingCount; i++) {
      final name = names[_rand.nextInt(names.length)];
      final type = _rand.nextBool() ? 'lent' : 'borrowed';
      final amount = (_rand.nextInt(10000) + 1000).toDouble();
      final isSettled = _rand.nextDouble() < 0.4;
      await _db.insertLending(
        Lending(
          personName: '$name ${i + 1}',
          type: type,
          originalAmount: amount,
          paidAmount: isSettled ? amount : (amount * 0.2),
          date: startTime.add(Duration(days: _rand.nextInt(totalDays))),
          isSettled: isSettled,
          categoryId: 'cat_shop',
        ),
      );
    }

    _db.notifyDataChange();
  }

  Future<void> stressTestExpenses({int count = 500}) async {
    final catIds = ['cat_food', 'cat_travel', 'cat_shop', 'cat_bills'];
    final accIds = ['acc_axis', 'acc_hdfc'];
    final now = DateTime.now();

    for (int i = 0; i < count; i++) {
      if (i % 50 == 0) await Future.delayed(const Duration(milliseconds: 1));
      await _ledgerRepo.insert(
        LedgerTransaction(
          type: LedgerType.expense,
          amount: (_rand.nextInt(1000) + 10).toDouble(),
          date: now.subtract(Duration(minutes: i * 30)),
          accountId: accIds[_rand.nextInt(accIds.length)],
          categoryId: catIds[_rand.nextInt(catIds.length)],
          note: 'Stress Expense $i',
        ),
      );
    }
    _db.notifyDataChange();
  }

  Future<void> stressTestCredit({int count = 200}) async {
    final cards = await _db.getAllCreditCards();
    if (cards.isEmpty) {
      await _db.insertCreditCard(
        CreditCard(
          name: 'Stress Card',
          bank: 'Test',
          last4: '8888',
          limitAmount: 500000,
          usedAmount: 0,
          billingDay: 15,
          dueDay: 5,
          cardType: 'visa',
          color: '#1A237E',
        ),
      );
    }
    final allCards = await _db.getAllCreditCards();
    final now = DateTime.now();

    for (int i = 0; i < count; i++) {
      if (i % 40 == 0) await Future.delayed(const Duration(milliseconds: 1));
      final cId = allCards[_rand.nextInt(allCards.length)].id;
      await _creditService.addCreditTransaction(
        CreditTransaction(
          id: _uuid.v4(),
          cardId: cId,
          amount: (_rand.nextInt(5000) + 100).toDouble(),
          date: now.subtract(Duration(hours: i * 2)),
          category: 'Shopping',
          categoryId: 'cat_shop',
          status: 'active',
          type: 'purchase',
          note: 'Stress Credit $i',
        ),
      );
    }
    _db.notifyDataChange();
  }

  Future<void> stressTestLoans({int count = 10}) async {
    final now = DateTime.now();
    for (int i = 0; i < count; i++) {
      final lId = 'stress_loan_$i';
      final start = now.subtract(Duration(days: i * 30));
      final loan = Loan(
        id: lId,
        name: 'Stress Loan $i',
        bank: 'StressBank',
        total: 100000,
        interestRate: 10,
        tenureMonths: 12,
        monthlyInstallment: 9000,
        startDate: start,
        paidAmount: 0,
        loanStatus: 'active',
        dueDay: 10,
        type: LoanType.reducing,
      );
      await _db.insertLoan(loan);
      await _loanService.generateInstallments(lId, 100000, 12, start, 10);
    }
    _db.notifyDataChange();
  }

  Future<void> stressTestLending({int count = 50}) async {
    final names = ['Tester', 'User', 'Bot', 'Stress'];
    final now = DateTime.now();
    for (int i = 0; i < count; i++) {
      await _db.insertLending(
        Lending(
          personName: '${names[_rand.nextInt(names.length)]} $i',
          type: _rand.nextBool() ? 'lent' : 'borrowed',
          originalAmount: (_rand.nextInt(5000) + 500).toDouble(),
          paidAmount: 0,
          date: now.subtract(Duration(days: i)),
          isSettled: false,
          categoryId: 'cat_shop',
        ),
      );
    }
    _db.notifyDataChange();
  }
}
