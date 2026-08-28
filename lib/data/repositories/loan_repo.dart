import '../../models/loan.dart';
import '../../models/loan_installment.dart';
import '../core/app_database.dart';
import '../core/tables.dart';
import 'package:sqflite/sqflite.dart' show Database;

class LoanRepo {
  final Database? database;

  LoanRepo({this.database});

  Future<Database> get _db async =>
      database ?? await AppDatabase.instance.database;

  Future<List<Loan>> getLoans() async {
    final database = await _db;
    final res = await database.query(Tables.loans);

    return res.map((e) => Loan.fromMap(e)).toList();
  }

  Future<Loan?> getLoanById(String id) async {
    final database = await _db;
    final res = await database.query(
      Tables.loans,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return res.isEmpty ? null : Loan.fromMap(res.first);
  }

  Future<String> insertLoan(Loan loan) async {
    final database = await _db;
    await database.insert(Tables.loans, loan.toMap());
    return loan.id;
  }

  Future<int> updateLoan(Loan loan) async {
    final database = await _db;
    return await database.update(
      Tables.loans,
      loan.toMap(),
      where: 'id = ?',
      whereArgs: [loan.id],
    );
  }

  Future<int> deleteLoan(String id) async {
    final database = await _db;
    return await database.delete(
      Tables.loans,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<LoanInstallment>> getInstallments(String loanId) async {
    final database = await _db;
    final res = await database.query(
      Tables.loanInstallments,
      where: 'loanId = ?',
      whereArgs: [loanId],
      orderBy: 'dueDate ASC',
    );
    return res.map((e) => LoanInstallment.fromMap(e)).toList();
  }

  Future<LoanInstallment?> getInstallmentById(String id) async {
    final database = await _db;
    final res = await database.query(
      Tables.loanInstallments,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return res.isEmpty ? null : LoanInstallment.fromMap(res.first);
  }

  Future<String> insertInstallment(LoanInstallment installment) async {
    final database = await _db;
    await database.insert(Tables.loanInstallments, installment.toMap());
    return installment.id;
  }

  Future<int> updateInstallment(LoanInstallment installment) async {
    final database = await _db;
    return database.update(
      Tables.loanInstallments,
      installment.toMap(),
      where: 'id = ?',
      whereArgs: [installment.id],
    );
  }

  Future<int> updateInstallmentStatus(
    String installmentId,
    String status,
    DateTime? paidDate,
  ) async {
    final existing = await getInstallmentById(installmentId);
    if (existing == null) return 0;
    return updateInstallment(
      existing.copyWith(status: status, paidDate: paidDate),
    );
  }

  Future<LoanInstallment?> getNextPendingInstallment(String loanId) async {
    final database = await _db;
    final res = await database.query(
      Tables.loanInstallments,
      where: 'loanId = ? AND status = ?',
      whereArgs: [loanId, 'pending'],
      orderBy: 'dueDate ASC',
      limit: 1,
    );
    return res.isEmpty ? null : LoanInstallment.fromMap(res.first);
  }

  Future<int> updateLoanProgress(
    String loanId,
    double paidAmount,
    String loanStatus,
  ) async {
    final loan = await getLoanById(loanId);
    if (loan == null) return 0;

    final nextInstallment = await getNextPendingInstallment(loanId);
    return updateLoan(
      loan.copyWith(
        paidAmount: paidAmount,
        loanStatus: loanStatus,
        nextDueDate: nextInstallment?.dueDate,
      ),
    );
  }
}
