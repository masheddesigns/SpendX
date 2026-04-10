import '../core/app_database.dart';
import '../core/tables.dart';

class SalaryRepo {
  final db = AppDatabase.instance;

  Future<List<Map<String, dynamic>>> getAll() async {
    return await getLegacySalaries();
  }


  // --- Companies ---
  Future<List<Map<String, dynamic>>> getCompanies() async {
    final database = await db.database;
    return await database.query(Tables.companies, orderBy: 'name ASC');
  }

  Future<String> insertCompany(Map<String, dynamic> company) async {
    final database = await db.database;
    final id = company['id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    final data = Map<String, dynamic>.from(company)..['id'] = id;
    await database.insert(Tables.companies, data);
    return id;
  }

  Future<int> updateCompany(Map<String, dynamic> company) async {
    final database = await db.database;
    return await database.update(Tables.companies, company, where: 'id = ?', whereArgs: [company['id']]);
  }

  Future<int> deleteCompany(String id) async {
    final database = await db.database;
    return await database.delete(Tables.companies, where: 'id = ?', whereArgs: [id]);
  }

  // --- Contracts ---
  Future<List<Map<String, dynamic>>> getContracts({String? companyId}) async {
    final database = await db.database;
    return await database.query(
      Tables.salaryContracts,
      where: companyId != null ? 'company_id = ?' : null,
      whereArgs: companyId != null ? [companyId] : null,
      orderBy: 'start_date DESC',
    );
  }

  Future<String> insertContract(Map<String, dynamic> contract) async {
    final database = await db.database;
    final id = contract['id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    final data = Map<String, dynamic>.from(contract)..['id'] = id;
    await database.insert(Tables.salaryContracts, data);
    return id;
  }

  Future<int> updateContract(Map<String, dynamic> contract) async {
    final database = await db.database;
    return await database.update(Tables.salaryContracts, contract, where: 'id = ?', whereArgs: [contract['id']]);
  }

  // --- Payments ---
  Future<List<Map<String, dynamic>>> getPayments({String? contractId}) async {
    final database = await db.database;
    return await database.query(
      Tables.salaryPayments,
      where: contractId != null ? 'contract_id = ?' : null,
      whereArgs: contractId != null ? [contractId] : null,
      orderBy: 'month DESC',
    );
  }

  Future<Map<String, dynamic>?> getPaymentById(String id) async {
    final database = await db.database;
    final result = await database.query(
      Tables.salaryPayments,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return result.isEmpty ? null : result.first;
  }

  Future<String> insertPayment(Map<String, dynamic> payment) async {
    final database = await db.database;
    final id = payment['id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    final data = Map<String, dynamic>.from(payment)..['id'] = id;
    await database.insert(Tables.salaryPayments, data);
    return id;
  }

  Future<int> updatePayment(Map<String, dynamic> payment) async {
    final database = await db.database;
    return await database.update(Tables.salaryPayments, payment, where: 'id = ?', whereArgs: [payment['id']]);
  }

  Future<int> deletePayment(String id) async {
    final database = await db.database;
    return await database.delete(Tables.salaryPayments, where: 'id = ?', whereArgs: [id]);
  }

  // --- Increments ---
  Future<List<Map<String, dynamic>>> getIncrements(String contractId) async {
    final database = await db.database;
    return await database.query(
      Tables.salaryIncrements,
      where: 'contract_id = ?',
      whereArgs: [contractId],
      orderBy: 'effective_from DESC',
    );
  }

  Future<String> insertIncrement(Map<String, dynamic> increment) async {
    final database = await db.database;
    final id = increment['id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    final data = Map<String, dynamic>.from(increment)..['id'] = id;
    await database.insert(Tables.salaryIncrements, data);
    return id;
  }


  // --- Legacy ---
  Future<List<Map<String, dynamic>>> getLegacySalaries() async {
    final database = await db.database;
    try {
      return await database.query(Tables.salary);
    } catch (_) {
      return [];
    }
  }
}
