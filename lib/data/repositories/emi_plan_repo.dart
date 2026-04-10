import '../../models/emi_plan.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class EmiPlanRepo {
  final _db = AppDatabase.instance;

  Future<void> insert(EmiPlan plan) async {
    final database = await _db.database;
    await database.insert(Tables.emiPlans, plan.toMap());
  }

  Future<int> update(EmiPlan plan) async {
    final database = await _db.database;
    return database.update(
      Tables.emiPlans,
      plan.toMap(),
      where: 'id = ?',
      whereArgs: [plan.id],
    );
  }
}
