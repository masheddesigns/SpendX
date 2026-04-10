import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../../data/core/app_database.dart';
import '../../data/core/tables.dart';
import 'salary_ledger_models.dart';

class SalaryLedgerRepo {
  final db = AppDatabase.instance;

  // ── Companies ─────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getCompanies() async {
    final database = await db.database;
    return database.query(Tables.companies, orderBy: 'name ASC');
  }

  Future<String> insertCompany(Map<String, dynamic> companyMap) async {
    final database = await db.database;
    await database.insert(Tables.companies, companyMap);
    return companyMap['id'] as String;
  }

  Future<void> updateCompany(Map<String, dynamic> companyMap) async {
    final database = await db.database;
    await database.update(
      Tables.companies,
      companyMap,
      where: 'id = ?',
      whereArgs: [companyMap['id']],
    );
  }

  Future<void> deleteCompany(String id) async {
    final database = await db.database;
    // Cascade: delete all months → payments for this company
    final months = await database.query(
      Tables.salaryMonths,
      columns: ['id'],
      where: 'company_id = ?',
      whereArgs: [id],
    );
    for (final m in months) {
      await database.delete(Tables.salaryLedger,
          where: 'month_id = ?', whereArgs: [m['id']]);
    }
    await database.delete(Tables.salaryMonths,
        where: 'company_id = ?', whereArgs: [id]);
    await database.delete(Tables.companies,
        where: 'id = ?', whereArgs: [id]);
  }

  // ── Contracts (salary structure history) ────────────────────────────

  /// Get all contracts for a company, sorted by start_date ascending.
  Future<List<SalaryContract>> getContracts(String companyId) async {
    final database = await db.database;
    final res = await database.query(
      Tables.salaryContracts,
      where: 'company_id = ?',
      whereArgs: [companyId],
      orderBy: 'start_date ASC',
    );
    return res.map(SalaryContract.fromMap).toList();
  }

  Future<void> insertContract(SalaryContract contract) async {
    if (contract.baseSalary <= 0) {
      throw ArgumentError('Salary must be positive');
    }
    final database = await db.database;
    await database.insert(Tables.salaryContracts, contract.toMap());
  }

  Future<void> deleteContract(String id) async {
    final database = await db.database;
    await database.delete(Tables.salaryContracts,
        where: 'id = ?', whereArgs: [id]);
  }

  // ── Months (always company-scoped) ────────────────────────────────

  /// Get all months for a company, ordered newest first.
  Future<List<SalaryMonth>> getByCompany(String companyId) async {
    final database = await db.database;
    final res = await database.query(
      Tables.salaryMonths,
      where: 'company_id = ?',
      whereArgs: [companyId],
      orderBy: 'month DESC',
    );
    return res.map(SalaryMonth.fromMap).toList();
  }

  Future<SalaryMonth?> getMonth(String id) async {
    final database = await db.database;
    final res = await database.query(Tables.salaryMonths,
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (res.isEmpty) return null;
    return SalaryMonth.fromMap(res.first);
  }

  Future<SalaryMonth?> getMonthByKey(String monthKey,
      {required String companyId}) async {
    final database = await db.database;
    final res = await database.query(
      Tables.salaryMonths,
      where: 'month = ? AND company_id = ?',
      whereArgs: [monthKey, companyId],
      limit: 1,
    );
    if (res.isEmpty) return null;
    return SalaryMonth.fromMap(res.first);
  }

  Future<void> insertMonth(SalaryMonth month) async {
    if (month.companyId.isEmpty) {
      throw ArgumentError('companyId must not be empty');
    }
    final database = await db.database;
    await database.insert(Tables.salaryMonths, month.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> deleteMonth(String id) async {
    final database = await db.database;
    await database.delete(Tables.salaryLedger,
        where: 'month_id = ?', whereArgs: [id]);
    await database.delete(Tables.salaryMonths,
        where: 'id = ?', whereArgs: [id]);
  }

  // ── Payments ───────────────────────────────────────────────────────

  Future<List<SalaryLedgerEntry>> getPayments(String monthId) async {
    final database = await db.database;
    final res = await database.query(Tables.salaryLedger,
        where: 'month_id = ?',
        whereArgs: [monthId],
        orderBy: 'paid_date DESC');
    return res.map(SalaryLedgerEntry.fromMap).toList();
  }

  Future<void> insertPayment(SalaryLedgerEntry entry) async {
    if (entry.amount <= 0) {
      throw ArgumentError('Payment amount must be positive');
    }
    // Overflow guard: salary-type payments cannot exceed 3× expected amount
    if (entry.type != PaymentType.bonus) {
      final month = await getMonth(entry.monthId);
      if (month != null && month.expectedAmount > 0) {
        final existing = await getPayments(entry.monthId);
        final salarySoFar = existing
            .where((p) => p.type != PaymentType.bonus)
            .fold(0.0, (a, b) => a + b.amount);
        if (salarySoFar + entry.amount > month.expectedAmount * 3) {
          throw ArgumentError(
              'Payment would exceed 3× expected salary — possible data entry error');
        }
      }
    }
    final database = await db.database;
    await database.insert(Tables.salaryLedger, entry.toMap());
  }

  Future<void> updateMonthExpectedAmount(String monthId, double amount) async {
    if (amount <= 0) throw ArgumentError('Expected amount must be positive');
    final database = await db.database;
    await database.update(
      Tables.salaryMonths,
      {'expected_amount': amount},
      where: 'id = ?',
      whereArgs: [monthId],
    );
  }

  Future<void> setMonthHoldStatus(String monthId, bool isOnHold) async {
    final database = await db.database;
    await database.update(
      Tables.salaryMonths,
      {'is_on_hold': isOnHold ? 1 : 0},
      where: 'id = ?',
      whereArgs: [monthId],
    );
  }

  Future<void> deletePayment(String id) async {
    final database = await db.database;
    await database.delete(Tables.salaryLedger,
        where: 'id = ?', whereArgs: [id]);
  }
}
