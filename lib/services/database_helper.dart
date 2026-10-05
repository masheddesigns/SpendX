import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../data/core/app_database.dart';
import '../data/core/tables.dart';
import 'canonical_backup_validator.dart';
import '../models/bank_account.dart';
import '../models/category.dart' as app_models;
import '../models/credit_card.dart';
import '../models/credit_transaction.dart';
import '../models/emi_plan.dart';
import '../models/lending.dart';
import '../models/loan.dart';
import '../models/recurring_template.dart';
import '../models/budget.dart';
import '../models/reminder_model.dart';
import '../models/transaction.dart' as spx;
import '../data/repositories/account_repo.dart';
import '../data/repositories/budget_repo.dart';
import '../data/repositories/category_repo.dart';
import '../data/repositories/credit_repo.dart';
import '../data/repositories/lending_repo.dart';
import '../data/repositories/loan_repo.dart';
import '../data/repositories/maintenance_repo.dart';
import '../data/repositories/transaction_repo.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  DatabaseHelper._init();

  static const tableLedgerTransactions = Tables.ledgerTransactions;
  static const tableCategories = Tables.categories;
  static const tableCreditCards = Tables.creditCards;
  static const tableCreditTransactions = Tables.creditTransactions;
  static const tableCreditEmis = Tables.creditEmis;
  static const tableEmiPlans = 'emi_plans';
  static const tableLoans = Tables.loans;
  static const tableLoanInstallments = 'loan_installments';
  static const tableBankBalanceSnapshots = 'bank_balance_snapshots';

  final Set<VoidCallback> _listeners = <VoidCallback>{};

  Future<Database> get database async => AppDatabase.instance.database;
  final MaintenanceRepo _maintenanceRepo = MaintenanceRepo();

  @Deprecated(
    'Use DataChangeBus instead. DatabaseHelper is a low-level adapter only.',
  )
  void addDataChangeListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  @Deprecated(
    'Use DataChangeBus instead. DatabaseHelper is a low-level adapter only.',
  )
  void removeDataChangeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  @Deprecated(
    'Use DataChangeBus instead. DatabaseHelper is a low-level adapter only.',
  )
  void notifyDataChange() {
    for (final listener in List<VoidCallback>.from(_listeners)) {
      listener();
    }
  }

  @Deprecated(
    'Use MaintenanceRepo via providers/notifiers. DatabaseHelper is a low-level adapter only.',
  )
  Future<void> clearAllData() async {
    await _maintenanceRepo.clearAllData();
    notifyDataChange();
  }

  @Deprecated(
    'Use MaintenanceRepo via providers/notifiers. DatabaseHelper is a low-level adapter only.',
  )
  Future<void> clearExpenses() async {
    await _maintenanceRepo.clearExpenses();
    notifyDataChange();
  }

  @Deprecated(
    'Use MaintenanceRepo via providers/notifiers. DatabaseHelper is a low-level adapter only.',
  )
  Future<void> clearIncome() async {
    await _maintenanceRepo.clearIncome();
    notifyDataChange();
  }

  @Deprecated(
    'Use MaintenanceRepo via providers/notifiers. DatabaseHelper is a low-level adapter only.',
  )
  Future<void> clearLending() async {
    await _maintenanceRepo.clearLending();
    notifyDataChange();
  }

  @Deprecated(
    'Use MaintenanceRepo via providers/notifiers. DatabaseHelper is a low-level adapter only.',
  )
  Future<void> clearCreditData() async {
    await _maintenanceRepo.clearCreditData();
    notifyDataChange();
  }

  @Deprecated(
    'Use MaintenanceRepo via providers/notifiers. DatabaseHelper is a low-level adapter only.',
  )
  Future<void> clearLoans() async {
    await _maintenanceRepo.clearLoans();
    notifyDataChange();
  }

  /// Get all active recurring templates for the engine.
  Future<List<RecurringTemplate>> getAllRecurringTemplates() async {
    final db = await database;
    final maps = await db.query(Tables.recurring_templates,
        orderBy: 'created_at DESC');
    return maps.map(RecurringTemplate.fromMap).toList();
  }

  /// Update a recurring template (for engine: last_generated_date, is_active).
  Future<void> updateRecurringTemplate(RecurringTemplate template) async {
    final db = await database;
    await db.update(
      Tables.recurring_templates,
      template.toMap(),
      where: 'id = ?',
      whereArgs: [template.id],
    );
  }

  /// Batch insert transactions — deprecated in C9, dead code.
  @Deprecated('Dead code retired in Milestone C9')
  Future<void> batchInsertTransactions(List<spx.Transaction> txns) async {
    // Dead code retired in Milestone C9: zero writes to legacy tables.
  }

  @Deprecated('Use RecurringRepo. DatabaseHelper is a low-level adapter only.')
  Future<void> insertRecurringTemplate(RecurringTemplate template) async {
    final db = await database;
    await db.insert(Tables.recurring_templates, {
      'id': template.id,
      'name': template.name,
      'amount': template.amount,
      'type': template.type,
      'category_id': template.categoryId,
      'frequency': template.frequency,
      'interval': 1,
      'last_generated': template.lastGeneratedDate?.toIso8601String(),
      'next_generation': template.startDate.toIso8601String(),
      'is_active': template.isActive ? 1 : 0,
      'created_at': template.createdAt.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @Deprecated('Use CategoryRepo. DatabaseHelper is a low-level adapter only.')
  Future<List<app_models.Category>> getAllCategories() async {
    final db = await database;
    final maps = await db.query(Tables.categories, orderBy: 'name ASC');
    return maps.map(app_models.Category.fromMap).toList();
  }

  @Deprecated('Use ReminderRepo. DatabaseHelper is a low-level adapter only.')
  Future<List<Reminder>> getAllGlobalReminders() async {
    final db = await database;
    final maps = await db.query(Tables.reminders, orderBy: 'due_date ASC');
    return maps.map(Reminder.fromMap).toList();
  }

  @Deprecated('Use CreditRepo. DatabaseHelper is a low-level adapter only.')
  Future<CreditTransaction?> getCreditTransactionById(String id) async {
    final db = await database;
    final results = await db.query(
      Tables.creditTransactions,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return CreditTransaction.fromMap(results.first);
  }

  @Deprecated('Use CreditRepo. DatabaseHelper is a low-level adapter only.')
  Future<List<CreditCard>> getAllCreditCards() async {
    return CreditRepo().getAll();
  }

  @Deprecated('Use AccountRepo. DatabaseHelper is a low-level adapter only.')
  Future<List<BankAccount>> getAllBankAccounts() {
    return AccountRepo().getAccounts();
  }

  @Deprecated('Use CategoryRepo. DatabaseHelper is a low-level adapter only.')
  Future<String> insertCategory(app_models.Category category) {
    return CategoryRepo().insert(category);
  }

  @Deprecated('Use AccountRepo. DatabaseHelper is a low-level adapter only.')
  Future<String> insertBankAccount(BankAccount account) {
    return AccountRepo().insertAccount(account);
  }

  @Deprecated('Use CreditRepo. DatabaseHelper is a low-level adapter only.')
  Future<String> insertCreditCard(CreditCard card) {
    return CreditRepo().insert(card);
  }

  @Deprecated('Use LoanRepo. DatabaseHelper is a low-level adapter only.')
  Future<String> insertLoan(Loan loan) {
    return LoanRepo().insertLoan(loan);
  }

  @Deprecated('Use LendingRepo. DatabaseHelper is a low-level adapter only.')
  Future<String> insertLending(Lending lending) {
    return LendingRepo().insert(lending);
  }

  @Deprecated(
    'Use TransactionRepo via notifiers. DatabaseHelper is a low-level adapter only.',
  )
  Future<String> insertTransaction(spx.Transaction transaction) {
    return TransactionRepo().insert(transaction);
  }

  @Deprecated('Use EmiPlanRepo. DatabaseHelper is a low-level adapter only.')
  Future<void> insertEmiPlan(EmiPlan plan) async {
    final db = await database;
    await db.insert(
      tableEmiPlans,
      plan.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @Deprecated('Use EmiPlanRepo. DatabaseHelper is a low-level adapter only.')
  Future<int> updateEmiPlan(EmiPlan plan) async {
    final db = await database;
    return db.update(
      tableEmiPlans,
      plan.toMap(),
      where: 'id = ?',
      whereArgs: [plan.id],
    );
  }

  @Deprecated(
    'Use TransactionRepo. DatabaseHelper is a low-level adapter only.',
  )
  Future<List<spx.Transaction>> getAllTransactions({int? limit, int? offset}) {
    return TransactionRepo().getAll(limit: limit, offset: offset);
  }

  @Deprecated('Use AccountRepo. DatabaseHelper is a low-level adapter only.')
  Future<int> deleteBankAccount(String id) async {
    return AccountRepo().deleteAccount(id);
  }

  @Deprecated('Use BudgetRepo. DatabaseHelper is a low-level adapter only.')
  Future<List<Budget>> getAllBudgets() async {
    return BudgetRepo().getAll();
  }

  @Deprecated('Use BudgetRepo. DatabaseHelper is a low-level adapter only.')
  Future<String> insertBudget(Budget budget) async {
    return BudgetRepo().insert(budget);
  }

  @Deprecated('Use BudgetRepo. DatabaseHelper is a low-level adapter only.')
  Future<int> updateBudget(Budget budget) async {
    return BudgetRepo().update(budget);
  }

  @Deprecated('Use BudgetRepo. DatabaseHelper is a low-level adapter only.')
  Future<int> deleteBudget(String id) async {
    return BudgetRepo().delete(id);
  }

  @Deprecated('Use BudgetRepo. DatabaseHelper is a low-level adapter only.')
  Future<double> getSpentThisMonth(String categoryId) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final end = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
    return BudgetRepo().getSpentForCategory(categoryId, start, end);
  }

  /// Returns database metrics for the canonical backup manifest.
  Future<Map<String, dynamic>> getFullSnapshot() async {
    final db = await database;
    return await CanonicalBackupValidator.computeDatabaseMetrics(db);
  }

  /// Deprecated legacy restore entry point.
  /// Direct table-by-table restoration is prohibited in SpendX 2.0.
  @Deprecated('Use BackupService.instance.restoreFromFile()')
  Future<void> restoreFromSnapshot(Map<String, dynamic> data) async {
    throw UnsupportedError(
      'Direct row-by-row table restoration is prohibited. '
      'Use BackupService.instance.restoreFromFile() for atomic, validated .spendx restoration.',
    );
  }
}
