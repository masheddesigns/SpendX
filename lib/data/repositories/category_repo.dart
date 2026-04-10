import '../../core/constants/default_categories.dart';
import '../../core/constants/category_meta.dart';
import '../../models/category.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class CategoryRepo {
  final db = AppDatabase.instance;

  Future<void> create(Category category) async {
    await insert(category);
  }

  Future<List<Category>> getAll() async {
    final database = await db.database;
    final res = await database.query(Tables.categories);
    return res.map((e) => Category.fromMap(e)).toList();
  }

  Future<void> ensureDefaults() async {
    final existing = await getAll();
    final existingKeys = existing
        .map((item) => '${item.type.toLowerCase()}::${item.name.toLowerCase()}')
        .toSet();

    final missingExpense = DefaultCategories.expense
        .where(
          (name) => !existingKeys.contains('expense::${name.toLowerCase()}'),
        )
        .toList();
    final missingIncome = DefaultCategories.income
        .where(
          (name) => !existingKeys.contains('income::${name.toLowerCase()}'),
        )
        .toList();

    if (missingExpense.isEmpty && missingIncome.isEmpty) {
      // ignore: avoid_print
      print('📂 Categories already exist, skipping seed');
      return;
    }

    // ignore: avoid_print
    print('🌱 Seeding default categories');

    final database = await db.database;
    final batch = database.batch();
    for (final name in missingExpense) {
      batch.insert(
        Tables.categories,
        _buildDefaultCategory(name: name, type: 'expense').toMap(),
      );
    }
    for (final name in missingIncome) {
      batch.insert(
        Tables.categories,
        _buildDefaultCategory(name: name, type: 'income').toMap(),
      );
    }
    await batch.commit(noResult: true);
    // ignore: avoid_print
    print(
      '🌱 Inserted default categories: '
      '${missingExpense.length + missingIncome.length}',
    );
    // ignore: avoid_print
    print('✅ Default categories seeded');
  }

  Category _buildDefaultCategory({required String name, required String type}) {
    return Category(
      userId: 'default',
      name: name,
      icon: CategoryMetaMap.iconKey(name, type),
      color: CategoryMetaMap.colorHex(name, type),
      type: type,
    );
  }

  Future<String> insert(Category category) async {
    final database = await db.database;
    await database.insert(Tables.categories, category.toMap());
    return category.id;
  }

  Future<int> update(Category category) async {
    final database = await db.database;
    return await database.update(
      Tables.categories,
      category.toMap(),
      where: 'id = ?',
      whereArgs: [category.id],
    );
  }

  Future<int> delete(String id) async {
    final database = await db.database;
    return await database.delete(
      Tables.categories,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Category?> getByName(String name, {String? type}) async {
    final database = await db.database;
    final res = await database.query(
      Tables.categories,
      where: type != null ? 'name = ? AND type = ?' : 'name = ?',
      whereArgs: type != null ? [name, type] : [name],
      limit: 1,
    );
    if (res.isEmpty) return null;
    return Category.fromMap(res.first);
  }

  Future<List<Category>> getByType(String type) async {
    final database = await db.database;
    final res = await database.query(
      Tables.categories,
      where: 'type = ?',
      whereArgs: [type],
    );
    return res.map((e) => Category.fromMap(e)).toList();
  }
}
