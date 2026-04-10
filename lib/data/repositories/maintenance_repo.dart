import '../../models/ledger_transaction.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class MaintenanceRepo {
  final db = AppDatabase.instance;

  Future<void> clearSalaryData() async {
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete(Tables.salaryLedger);
      await txn.delete(Tables.salaryMonths);
      await txn.delete(Tables.salaryContracts);
      await txn.delete(Tables.companies);
    });
  }

  Future<void> clearGoals() async {
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete(Tables.goalLogs);
      await txn.delete(Tables.goals);
    });
  }

  Future<void> clearAccounts() async {
    final database = await db.database;
    await database.delete(Tables.bankAccounts);
  }

  Future<void> clearAllData() async {
    final database = await db.database;
    final tables = [
      Tables.transactions,
      Tables.categories,
      Tables.tags,
      Tables.bankAccounts,
      Tables.creditCards,
      Tables.creditTransactions,
      Tables.creditEmis,
      Tables.emiInstallments,
      Tables.cardStatements,
      Tables.loans,
      'loan_installments',
      Tables.lendings,
      Tables.vehicles,
      Tables.fuelLogs,
      Tables.budgets,
      Tables.recurring_templates,
      Tables.reminders,
      Tables.ledgerTransactions,
      'bank_balance_snapshots',
      // Salary module
      Tables.salaryLedger,
      Tables.salaryMonths,
      Tables.salaryContracts,
      Tables.companies,
      // Goals
      Tables.goalLogs,
      Tables.goals,
      // Streaks & gamification
      Tables.streaks,
      Tables.challenges,
      Tables.achievements,
      // Analytics
      Tables.netWorthHistory,
      Tables.merchantRules,
      Tables.reviewQueue,
    ];

    await database.transaction((txn) async {
      for (final table in tables) {
        try { await txn.delete(table); } catch (_) {}
      }
    });
  }

  Future<void> clearExpenses() async {
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete(
        Tables.transactions,
        where: 'type = ?',
        whereArgs: const ['expense'],
      );
      await txn.delete(
        Tables.ledgerTransactions,
        where: 'type = ?',
        whereArgs: [LedgerType.expense.name],
      );
    });
  }

  Future<void> clearIncome() async {
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete(
        Tables.transactions,
        where: 'type = ?',
        whereArgs: const ['income'],
      );
      await txn.delete(
        Tables.ledgerTransactions,
        where: 'type = ?',
        whereArgs: [LedgerType.income.name],
      );
    });
  }

  Future<void> clearLending() async {
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete(Tables.lendings);
      await txn.delete(
        Tables.ledgerTransactions,
        where: 'type IN (?, ?)',
        whereArgs: [
          LedgerType.lending_given.name,
          LedgerType.lending_received.name,
        ],
      );
    });
  }

  Future<void> clearVehicles() async {
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete(Tables.fuelLogs);
      await txn.delete(Tables.vehicles);
      await txn.delete(
        Tables.transactions,
        where: 'vehicle_id IS NOT NULL OR source = ?',
        whereArgs: const ['vehicle'],
      );
      await txn.delete(
        Tables.ledgerTransactions,
        where: 'type = ?',
        whereArgs: [LedgerType.fuel_expense.name],
      );
    });
  }

  Future<void> clearCreditData() async {
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete(Tables.cardStatements);
      await txn.delete(Tables.emiInstallments);
      await txn.delete(Tables.creditEmis);
      await txn.delete(Tables.creditTransactions);
      await txn.delete(Tables.creditCards);
      await txn.delete(
        Tables.ledgerTransactions,
        where: 'type IN (?, ?, ?, ?)',
        whereArgs: [
          LedgerType.credit_purchase.name,
          LedgerType.credit_payment.name,
          LedgerType.emi_installment.name,
          LedgerType.processing_fee.name,
        ],
      );
    });
  }

  Future<void> clearLoans() async {
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete('loan_installments');
      await txn.delete(Tables.loans);
      await txn.delete(
        Tables.ledgerTransactions,
        where: 'type IN (?, ?)',
        whereArgs: [
          LedgerType.loan_disbursement.name,
          LedgerType.loan_payment.name,
        ],
      );
    });
  }
}
