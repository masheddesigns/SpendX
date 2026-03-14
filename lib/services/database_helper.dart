import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/transaction.dart' as spx;
import '../models/category.dart';
import '../models/budget.dart';
import '../models/recurring_template.dart';
import '../models/vehicle.dart';
import '../models/lending.dart';
import '../models/credit_card.dart';
import '../models/emi_plan.dart';
import '../models/bank_account.dart';
import '../utils/app_format.dart';

class DatabaseHelper {
  static const _databaseName = "spendx_local.db";
  static const _databaseVersion = 17;  // v17: Add location to transactions

  // Tables
  static const tableTransactions = 'transactions';
  static const tableCategories = 'categories';
  static const tableTags = 'tags';
  static const tableBudgets = 'budgets';
  static const tableRecurringTemplates = 'recurring_templates';
  static const tableVehicles = 'vehicles';
  static const tableFuelLogs = 'fuel_logs';
  static const tableLendings = 'lendings';
  static const tableCreditCards = 'credit_cards';
  static const tableEmiPlans = 'emi_plans';
  static const tableBankAccounts = 'bank_accounts';
  static const tableNetWorthSnapshots = 'net_worth_snapshots';
  static const tableAppSessions = 'app_sessions';

  // Singleton setup
  DatabaseHelper._privateConstructor();
  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();

  // Data change listener
  VoidCallback? _onDataChange;
  void setOnDataChange(VoidCallback callback) => _onDataChange = callback;
  void notifyDataChange() => _onDataChange?.call();

  static Database? _database;

  Future<Database> get database async {
    if (kIsWeb) throw UnsupportedError('sqflite is not supported on Web.');
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = p.join(await getDatabasesPath(), _databaseName);
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tableBudgets (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          category_id TEXT NOT NULL,
          limit_amount REAL NOT NULL,
          period TEXT NOT NULL DEFAULT 'monthly',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) {
      await _createPhase5Tables(db);
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE $tableFuelLogs ADD COLUMN location TEXT');
      await db.execute('ALTER TABLE $tableFuelLogs ADD COLUMN is_full_tank INTEGER NOT NULL DEFAULT 1');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE $tableVehicles ADD COLUMN tank_capacity REAL');
    }
    if (oldVersion < 6) {
      await _createCreditCardTables(db);
    }
    if (oldVersion < 7) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${DatabaseHelper.tableBankAccounts} (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          name TEXT NOT NULL,
          bank TEXT NOT NULL,
          account_type TEXT NOT NULL DEFAULT 'savings',
          balance REAL NOT NULL DEFAULT 0,
          color TEXT NOT NULL DEFAULT '#10B981',
          icon TEXT NOT NULL DEFAULT 'account_balance',
          is_asset INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 8) {
      await db.execute('ALTER TABLE $tableEmiPlans ADD COLUMN paid_instalments INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 9) {
      // Force creation if missed during dev
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${DatabaseHelper.tableBankAccounts} (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          name TEXT NOT NULL,
          bank TEXT NOT NULL,
          account_type TEXT NOT NULL DEFAULT 'savings',
          balance REAL NOT NULL DEFAULT 0,
          color TEXT NOT NULL DEFAULT '#10B981',
          icon TEXT NOT NULL DEFAULT 'account_balance',
          is_asset INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 11) {
      await _createIndexes(db);
    }
    if (oldVersion < 12) {
      await _migrateToV12(db);
    }
    if (oldVersion < 13) {
      await _createIndexes(db);
    }
    if (oldVersion < 14) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tableNetWorthSnapshots (
          id TEXT PRIMARY KEY,
          net_worth REAL NOT NULL,
          assets REAL NOT NULL,
          liabilities REAL NOT NULL,
          timestamp TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 15) {
      await db.execute('ALTER TABLE $tableTransactions ADD COLUMN vehicle_id TEXT');
    }
    if (oldVersion < 16) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tableAppSessions (
          id TEXT PRIMARY KEY,
          start_time TEXT NOT NULL,
          end_time TEXT,
          duration_seconds INTEGER DEFAULT 0,
          date TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 17) {
      await db.execute('ALTER TABLE $tableTransactions ADD COLUMN location TEXT');
    }
  }

  Future<void> _migrateToV12(Database db) async {
    // 1. Create a temporary table for deduplicated budgets
    await db.execute('''
      CREATE TABLE budgets_new (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        category_id TEXT NOT NULL UNIQUE,
        limit_amount REAL NOT NULL,
        period TEXT NOT NULL DEFAULT 'monthly',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE CASCADE
      )
    ''');

    // 2. Insert deduplicated data: keep the one with the highest limit
    await db.execute('''
      INSERT INTO budgets_new (id, user_id, category_id, limit_amount, period, created_at, updated_at)
      SELECT id, user_id, category_id, MAX(limit_amount), period, created_at, updated_at
      FROM budgets
      GROUP BY category_id
    ''');

    // 3. Drop old table and rename new one
    await db.execute('DROP TABLE budgets');
    await db.execute('ALTER TABLE budgets_new RENAME TO budgets');
    
    // Re-create index if any (budgets didn't have specific manual indexes but UNIQUE is one)
  }

  Future<void> _createIndexes(Database db) async {
    await db.execute('CREATE INDEX IF NOT EXISTS idx_transaction_date ON $tableTransactions(date)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_transaction_category ON $tableTransactions(category_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_transaction_type ON $tableTransactions(type)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_transaction_source ON $tableTransactions(source)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_transaction_related_entity ON $tableTransactions(related_entity_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_budget_category ON $tableBudgets(category_id)');
    // Update stats for query planner
    await db.execute('ANALYZE');
  }

  Future<void> _createPhase5Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableRecurringTemplates (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        name TEXT NOT NULL,
        amount REAL NOT NULL,
        type TEXT NOT NULL,
        category_id TEXT,
        frequency TEXT NOT NULL,
        start_date TEXT NOT NULL,
        end_date TEXT,
        last_generated_date TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        notes TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableVehicles (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        reg_number TEXT,
        fuel_type TEXT NOT NULL,
        tank_capacity REAL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableFuelLogs (
        id TEXT PRIMARY KEY,
        vehicle_id TEXT NOT NULL,
        odometer REAL NOT NULL,
        litres REAL NOT NULL,
        price_per_litre REAL NOT NULL,
        total_cost REAL NOT NULL,
        efficiency REAL,
        date TEXT NOT NULL,
        location TEXT,
        is_full_tank INTEGER NOT NULL DEFAULT 1,
        notes TEXT,
        FOREIGN KEY (vehicle_id) REFERENCES $tableVehicles (id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableLendings (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        person_name TEXT NOT NULL,
        type TEXT NOT NULL,
        original_amount REAL NOT NULL,
        paid_amount REAL NOT NULL DEFAULT 0,
        date TEXT NOT NULL,
        due_date TEXT,
        notes TEXT,
        is_settled INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  Future _onCreate(Database db, int version) async {
    // 1. Categories Table
    await db.execute('''
      CREATE TABLE $tableCategories (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        name TEXT NOT NULL,
        icon TEXT NOT NULL,
        color TEXT NOT NULL,
        type TEXT NOT NULL
      )
    ''');

    // 2. Tags Table
    await db.execute('''
      CREATE TABLE $tableTags (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        name TEXT NOT NULL,
        color TEXT NOT NULL
      )
    ''');

    // 3. Transactions Table
    await db.execute('''
      CREATE TABLE $tableTransactions (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        type TEXT NOT NULL,
        category_id TEXT,
        amount REAL NOT NULL,
        date TEXT NOT NULL,
        notes TEXT,
        tags TEXT, 
        source TEXT NOT NULL,
        related_entity_id TEXT,
        vehicle_id TEXT,
        location TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (category_id) REFERENCES $tableCategories (id) ON DELETE SET NULL
      )
    ''');
    
    // 4. Budgets Table
    await db.execute('''
      CREATE TABLE $tableBudgets (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        category_id TEXT NOT NULL UNIQUE,
        limit_amount REAL NOT NULL,
        period TEXT NOT NULL DEFAULT 'monthly',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (category_id) REFERENCES $tableCategories (id) ON DELETE CASCADE
      )
    ''');

    // Seed default categories
    await _seedDefaultCategories(db);
    // 5. Phase 5 tables
    await _createPhase5Tables(db);
    // 6. Credit tables
    await _createCreditCardTables(db);
    // 7. Bank Accounts table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableBankAccounts (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        name TEXT NOT NULL,
        bank TEXT NOT NULL,
        account_type TEXT NOT NULL DEFAULT 'savings',
        balance REAL NOT NULL DEFAULT 0,
        color TEXT NOT NULL DEFAULT '#10B981',
        icon TEXT NOT NULL DEFAULT 'account_balance',
        is_asset INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // 8. Net Worth Snapshots table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableNetWorthSnapshots (
        id TEXT PRIMARY KEY,
        net_worth REAL NOT NULL,
        assets REAL NOT NULL,
        liabilities REAL NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');

    // 9. App Sessions table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableAppSessions (
        id TEXT PRIMARY KEY,
        start_time TEXT NOT NULL,
        end_time TEXT,
        duration_seconds INTEGER DEFAULT 0,
        date TEXT NOT NULL
      )
    ''');

    // 10. Create Indexes
    await _createIndexes(db);
  }

  Future<void> _seedDefaultCategories(Database db) async {
    final defaultCategories = [
      Category(userId: 'default', name: 'Food', icon: '🍔', color: '#EF4444', type: 'expense'),
      Category(userId: 'default', name: 'Transport', icon: '🚗', color: '#3B82F6', type: 'expense'),
      Category(userId: 'default', name: 'Fuel', icon: '⛽', color: '#F97316', type: 'expense'),
      Category(userId: 'default', name: 'Groceries', icon: '🛒', color: '#22C55E', type: 'expense'),
      Category(userId: 'default', name: 'Shopping', icon: '🛍️', color: '#EC4899', type: 'expense'),
      Category(userId: 'default', name: 'Bills', icon: '💡', color: '#EAB308', type: 'expense'),
      Category(userId: 'default', name: 'Entertainment', icon: '🎬', color: '#A855F7', type: 'expense'),
      Category(userId: 'default', name: 'Subscriptions', icon: '📺', color: '#6366F1', type: 'expense'),
      Category(userId: 'default', name: 'Health', icon: '🏥', color: '#F43F5E', type: 'expense'),
      Category(userId: 'default', name: 'Travel', icon: '✈️', color: '#06B6D4', type: 'expense'),
      Category(userId: 'default', name: 'Education', icon: '📚', color: '#8B5CF6', type: 'expense'),
      Category(userId: 'default', name: 'Salary', icon: '💰', color: '#10B981', type: 'income'),
      Category(userId: 'default', name: 'Investment', icon: '📈', color: '#3B82F6', type: 'income'),
      Category(userId: 'default', name: 'Other', icon: '📦', color: '#64748B', type: 'expense'),
    ];

    for (var cat in defaultCategories) {
      await db.insert(tableCategories, cat.toMap());
    }
  }

  // ================= Categories CRUD =================

  Future<void> insertCategory(Category cat) async {
    if (kIsWeb) return;
    Database db = await instance.database;
    await db.insert(
      tableCategories,
      cat.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyDataChange();
  }

  Future<List<Category>> getAllCategories() async {
    if (kIsWeb) return [];
    Database db = await instance.database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableCategories,
      orderBy: 'name ASC',
    );
    return maps.map((m) => Category.fromMap(m)).toList();
  }

  // ================= Transactions CRUD =================

  Future<void> insertTransaction(spx.Transaction txn) async {
    if (kIsWeb) return;
    Database db = await instance.database;
    await db.insert(
      tableTransactions,
      txn.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyDataChange();
  }

  Future<void> batchInsertTransactions(List<spx.Transaction> transactions) async {
    if (kIsWeb) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var t in transactions) {
        batch.insert(
          tableTransactions,
          t.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    notifyDataChange();
  }

  Future<List<spx.Transaction>> getAllTransactions({int? limit, int? offset}) async {
    if (kIsWeb) return [];
    Database db = await instance.database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableTransactions,
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => spx.Transaction.fromMap(maps[i]));
  }

  Future<int> deleteImportedTransactions() async {
    if (kIsWeb) return 0;
    Database db = await instance.database;
    final count = await db.delete(
      tableTransactions,
      where: 'source = ?',
      whereArgs: ['import'],
    );
    notifyDataChange();
    return count;
  }

  Future<spx.Transaction?> getTransactionById(String id) async {
    if (kIsWeb) return null;
    Database db = await instance.database;
    final maps = await db.query(tableTransactions, where: 'id = ?', whereArgs: [id], limit: 1);
    if (maps.isNotEmpty) return spx.Transaction.fromMap(maps.first);
    return null;
  }

  Future<void> updateTransaction(spx.Transaction txn) async {
    if (kIsWeb) return;
    Database db = await instance.database;
    await db.update(
      tableTransactions,
      txn.toMap(),
      where: 'id = ?',
      whereArgs: [txn.id],
    );
    notifyDataChange();
  }

  Future<void> deleteTransaction(String id) async {
    if (kIsWeb) return;
    Database db = await instance.database;
    await db.delete(
      tableTransactions,
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyDataChange();
  }

  // ================= Advanced Queries =================

  Future<List<spx.Transaction>> searchTransactions({
    String? query,
    String? type,
    String? categoryId,
    String? startDate,
    String? endDate,
  }) async {
    if (kIsWeb) return [];
    Database db = await instance.database;
    
    List<String> whereClauses = [];
    List<dynamic> whereArgs = [];

    if (query != null && query.isNotEmpty) {
      whereClauses.add('(notes LIKE ? OR tags LIKE ?)');
      whereArgs.add('%$query%');
      whereArgs.add('%$query%');
    }

    if (type != null && type.isNotEmpty) {
      whereClauses.add('type = ?');
      whereArgs.add(type);
    }

    if (categoryId != null && categoryId.isNotEmpty) {
      whereClauses.add('category_id = ?');
      whereArgs.add(categoryId);
    }

    if (startDate != null && endDate != null) {
      whereClauses.add('date BETWEEN ? AND ?');
      whereArgs.add(startDate);
      whereArgs.add(endDate);
    } else if (startDate != null) {
      whereClauses.add('date >= ?');
      whereArgs.add(startDate);
    } else if (endDate != null) {
      whereClauses.add('date <= ?');
      whereArgs.add(endDate);
    }

    String whereString = whereClauses.isNotEmpty ? whereClauses.join(' AND ') : '';

    final List<Map<String, dynamic>> maps = await db.query(
      tableTransactions,
      where: whereString.isEmpty ? null : whereString,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'date DESC',
    );

    return List.generate(maps.length, (i) => spx.Transaction.fromMap(maps[i]));
  }
  // ================= Budgets CRUD =================

  Future<void> insertBudget(Budget budget) async {
    if (kIsWeb) return;
    Database db = await instance.database;
    await db.insert(tableBudgets, budget.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    notifyDataChange();
  }

  Future<List<Budget>> getAllBudgets() async {
    if (kIsWeb) return [];
    Database db = await instance.database;
    final maps = await db.query(tableBudgets);
    return maps.map((m) => Budget.fromMap(m)).toList();
  }

  Future<void> updateBudget(Budget budget) async {
    if (kIsWeb) return;
    Database db = await instance.database;
    await db.update(tableBudgets, budget.toMap(), where: 'id = ?', whereArgs: [budget.id]);
    notifyDataChange();
  }

  Future<void> deleteBudget(String id) async {
    if (kIsWeb) return;
    Database db = await instance.database;
    await db.delete(tableBudgets, where: 'id = ?', whereArgs: [id]);
    notifyDataChange();
  }

  /// Get total spent for a category in the current month
  Future<double> getSpentThisMonth(String categoryId) async {
    if (kIsWeb) return 0.0;
    Database db = await instance.database;
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1).toIso8601String();
    final endOfMonth = DateTime(now.year, now.month + 1, 0, 23, 59, 59).toIso8601String();
    final result = await db.rawQuery(
      '''SELECT COALESCE(SUM(amount), 0) as total FROM $tableTransactions
         WHERE category_id = ? AND type = 'expense' AND date BETWEEN ? AND ?''',
      [categoryId, startOfMonth, endOfMonth],
    );
    return (result.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  /// High-performance aggregation for totals
  Future<Map<String, double>> getBalanceSummary(String? startDate, String? endDate) async {
    if (kIsWeb) return {'income': 0, 'expense': 0, 'balance': 0};
    Database db = await instance.database;
    
    String whereString = '';
    List<dynamic> whereArgs = [];
    if (startDate != null && endDate != null) {
      whereString = 'WHERE date BETWEEN ? AND ?';
      whereArgs = [startDate, endDate];
    } else if (startDate != null) {
      whereString = 'WHERE date >= ?';
      whereArgs = [startDate];
    } else if (endDate != null) {
      whereString = 'WHERE date <= ?';
      whereArgs = [endDate];
    }

    final result = await db.rawQuery('''
      SELECT 
        SUM(CASE WHEN type = 'income' THEN amount ELSE 0 END) as income,
        SUM(CASE WHEN type = 'expense' THEN amount ELSE 0 END) as expense
      FROM $tableTransactions
      $whereString
    ''', whereArgs);

    double income = (result.first['income'] as num?)?.toDouble() ?? 0.0;
    double expense = (result.first['expense'] as num?)?.toDouble() ?? 0.0;
    
    return {
      'income': income,
      'expense': expense,
      'balance': income - expense,
    };
  }

  /// High-performance monthly stats for Reports
  Future<List<Map<String, dynamic>>> getMonthlyStats(int months) async {
    if (kIsWeb) return [];
    Database db = await instance.database;
    
    final now = DateTime.now();
    final cutoff = DateTime(now.year, now.month - months + 1, 1).toIso8601String();

    return await db.rawQuery('''
      SELECT 
        strftime('%Y-%m', date) as month,
        SUM(CASE WHEN type = 'income' THEN amount ELSE 0 END) as income,
        SUM(CASE WHEN type = 'expense' THEN amount ELSE 0 END) as expense
      FROM $tableTransactions
      WHERE date >= ?
      GROUP BY month
      ORDER BY month DESC
    ''', [cutoff]);
  }

  /// Optimized category spending for analytics
  Future<Map<String, double>> getCategorySpending({required DateTime start, required DateTime end}) async {
    if (kIsWeb) return {};
    Database db = await instance.database;
    
    final result = await db.rawQuery('''
      SELECT 
        CASE WHEN source = 'vehicle' THEN 'vehicle' ELSE category_id END as category_key,
        SUM(amount) as total
      FROM $tableTransactions
      WHERE type = 'expense' AND date BETWEEN ? AND ?
      GROUP BY category_key
    ''', [start.toIso8601String(), end.toIso8601String()]);

    Map<String, double> spendMap = {};
    for (var row in result) {
      final key = row['category_key'] as String?;
      if (key != null) {
        spendMap[key] = (row['total'] as num).toDouble();
      }
    }
    return spendMap;
  }

  Future<List<spx.Transaction>> getTransactionsForVehicle(String vehicleId, {int? limit, int? offset}) async {
    if (kIsWeb) return [];
    Database db = await instance.database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableTransactions,
      where: 'vehicle_id = ?',
      whereArgs: [vehicleId],
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => spx.Transaction.fromMap(maps[i]));
  }
}

extension Phase5Crud on DatabaseHelper {
  // ============= Recurring Templates =============
  Future<void> insertRecurringTemplate(RecurringTemplate t) async {
    if (kIsWeb) return;
    final db = await database;
    await db.insert(DatabaseHelper.tableRecurringTemplates, t.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    notifyDataChange();
  }

  Future<List<RecurringTemplate>> getAllRecurringTemplates() async {
    if (kIsWeb) return [];
    final db = await database;
    final maps = await db.query(DatabaseHelper.tableRecurringTemplates, orderBy: 'name ASC');
    return maps.map((m) => RecurringTemplate.fromMap(m)).toList();
  }

  Future<void> updateRecurringTemplate(RecurringTemplate t) async {
    if (kIsWeb) return;
    final db = await database;
    await db.update(DatabaseHelper.tableRecurringTemplates, t.toMap(), where: 'id = ?', whereArgs: [t.id]);
  }

  Future<void> deleteRecurringTemplate(String id) async {
    if (kIsWeb) return;
    final db = await database;
    await db.delete(DatabaseHelper.tableRecurringTemplates, where: 'id = ?', whereArgs: [id]);
  }

  // ============= Vehicles =============
  Future<void> insertVehicle(Vehicle v) async {
    if (kIsWeb) return;
    final db = await database;
    await db.insert(DatabaseHelper.tableVehicles, v.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    notifyDataChange();
  }

  Future<List<Vehicle>> getAllVehicles() async {
    if (kIsWeb) return [];
    final db = await database;
    final maps = await db.query(DatabaseHelper.tableVehicles, orderBy: 'name ASC');
    return maps.map((m) => Vehicle.fromMap(m)).toList();
  }

  Future<void> deleteVehicle(String id) async {
    if (kIsWeb) return;
    final db = await database;
    await db.delete(DatabaseHelper.tableVehicles, where: 'id = ?', whereArgs: [id]);
    notifyDataChange();
  }

  // ============= Fuel Logs =============
  Future<void> insertFuelLog(FuelLog log) async {
    if (kIsWeb) return;
    final db = await database;
    await db.insert(DatabaseHelper.tableFuelLogs, log.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);

    // Sync to Transactions
    final txn = spx.Transaction(
      userId: 'offline_user', 
      type: 'expense',
      amount: log.totalCost,
      date: log.date,
      notes: 'Fuel: ${log.litres.toStringAsFixed(1)}L @ ${AppFormat.currency(log.pricePerLitre)}${log.location != null ? ' in ${log.location}' : ''}',
      source: 'vehicle',
      relatedEntityId: log.id,
    );
    await insertTransaction(txn);
  }

  Future<void> updateFuelLog(FuelLog log) async {
    if (kIsWeb) return;
    final db = await database;
    await db.update(DatabaseHelper.tableFuelLogs, log.toMap(), where: 'id = ?', whereArgs: [log.id]);

    // Sync to Transactions
    final existingTxns = await db.query(DatabaseHelper.tableTransactions, where: 'related_entity_id = ? AND source = ?', whereArgs: [log.id, 'vehicle']);
    if (existingTxns.isNotEmpty) {
      final existingTxn = spx.Transaction.fromMap(existingTxns.first);
      final updatedTxn = spx.Transaction(
        id: existingTxn.id,
        userId: existingTxn.userId,
        type: existingTxn.type,
        categoryId: existingTxn.categoryId,
        amount: log.totalCost,
        date: log.date,
        notes: 'Fuel: ${log.litres.toStringAsFixed(1)}L @ ${AppFormat.currency(log.pricePerLitre)}${log.location != null ? ' in ${log.location}' : ''}',
        tags: existingTxn.tags,
        source: existingTxn.source,
        relatedEntityId: existingTxn.relatedEntityId,
        createdAt: existingTxn.createdAt,
      );
      await updateTransaction(updatedTxn);
    }
  }

  Future<List<FuelLog>> getFuelLogsForVehicle(String vehicleId, {int? limit, int? offset}) async {
    if (kIsWeb) return [];
    final db = await database;
    final maps = await db.query(DatabaseHelper.tableFuelLogs,
        where: 'vehicle_id = ?', whereArgs: [vehicleId], orderBy: 'date DESC', limit: limit, offset: offset);
    return maps.map((m) => FuelLog.fromMap(m)).toList();
  }

  Future<FuelLog?> getFuelLogById(String id) async {
    if (kIsWeb) return null;
    final db = await database;
    final maps = await db.query(DatabaseHelper.tableFuelLogs, where: 'id = ?', whereArgs: [id]);
    if (maps.isNotEmpty) {
      return FuelLog.fromMap(maps.first);
    }
    return null;
  }

  Future<void> deleteFuelLog(String id) async {
    if (kIsWeb) return;
    final db = await database;
    await db.delete(DatabaseHelper.tableFuelLogs, where: 'id = ?', whereArgs: [id]);

    // Sync to Transactions
    final existingTxns = await db.query(DatabaseHelper.tableTransactions, where: 'related_entity_id = ? AND source = ?', whereArgs: [id, 'vehicle']);
    for (var m in existingTxns) {
      await deleteTransaction(m['id'] as String);
    }
  }

  // ============= Lendings =============
  Future<void> insertLending(Lending l) async {
    if (kIsWeb) return;
    final db = await database;
    await db.insert(DatabaseHelper.tableLendings, l.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    notifyDataChange();
  }

  Future<List<Lending>> getAllLendings({bool? settledFilter, int? limit, int? offset}) async {
    if (kIsWeb) return [];
    final db = await database;
    final maps = await db.query(
      DatabaseHelper.tableLendings,
      where: settledFilter != null ? 'is_settled = ?' : null,
      whereArgs: settledFilter != null ? [settledFilter ? 1 : 0] : null,
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((m) => Lending.fromMap(m)).toList();
  }

  Future<List<String>> getDistinctLendingPersons() async {
    if (kIsWeb) return [];
    final db = await database;
    final maps = await db.rawQuery('SELECT DISTINCT person_name FROM ${DatabaseHelper.tableLendings} ORDER BY person_name ASC');
    return maps.map((m) => m['person_name'] as String).toList();
  }

  Future<void> updateLending(Lending l) async {
    if (kIsWeb) return;
    final db = await database;
    await db.update(DatabaseHelper.tableLendings, l.toMap(), where: 'id = ?', whereArgs: [l.id]);
  }

  Future<void> deleteLending(String id) async {
    if (kIsWeb) return;
    final db = await database;
    await db.delete(DatabaseHelper.tableLendings, where: 'id = ?', whereArgs: [id]);
  }

  // ============= Credit Cards =============
  Future<void> _createCreditCardTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${DatabaseHelper.tableCreditCards} (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        name TEXT NOT NULL,
        bank TEXT NOT NULL,
        last4 TEXT NOT NULL,
        credit_limit REAL NOT NULL,
        billing_day INTEGER NOT NULL DEFAULT 1,
        due_day INTEGER NOT NULL DEFAULT 20,
        card_type TEXT NOT NULL DEFAULT 'visa',
        color TEXT NOT NULL DEFAULT '#6366F1',
        outstanding REAL NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${DatabaseHelper.tableEmiPlans} (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        card_id TEXT,
        name TEXT NOT NULL,
        principal REAL NOT NULL,
        interest_rate REAL NOT NULL DEFAULT 0,
        tenure_months INTEGER NOT NULL,
        emi_amount REAL NOT NULL,
        start_date TEXT NOT NULL,
        category_id TEXT,
        notes TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        paid_instalments INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        FOREIGN KEY (card_id) REFERENCES ${DatabaseHelper.tableCreditCards} (id) ON DELETE SET NULL
      )
    ''');
  }

  Future<void> insertCreditCard(CreditCard card) async {
    if (kIsWeb) return;
    final db = await database;
    await db.insert(DatabaseHelper.tableCreditCards, card.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<CreditCard>> getAllCreditCards({int? limit, int? offset}) async {
    if (kIsWeb) return [];
    final db = await database;
    final maps = await db.query(DatabaseHelper.tableCreditCards, orderBy: 'created_at DESC', limit: limit, offset: offset);
    return maps.map((m) => CreditCard.fromMap(m)).toList();
  }

  Future<void> updateCreditCard(CreditCard card) async {
    if (kIsWeb) return;
    final db = await database;
    await db.update(DatabaseHelper.tableCreditCards, card.toMap(), where: 'id = ?', whereArgs: [card.id]);
  }

  Future<void> deleteCreditCard(String id) async {
    if (kIsWeb) return;
    final db = await database;
    await db.delete(DatabaseHelper.tableCreditCards, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateCreditCardOutstanding(String cardId, double outstanding) async {
    if (kIsWeb) return;
    final db = await database;
    await db.update(DatabaseHelper.tableCreditCards, {'outstanding': outstanding}, where: 'id = ?', whereArgs: [cardId]);
  }

  // ============= EMI Plans =============
  Future<void> insertEmiPlan(EmiPlan plan) async {
    if (kIsWeb) return;
    final db = await database;
    await db.insert(DatabaseHelper.tableEmiPlans, plan.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);

    // Add to card outstanding if linked to a card
    if (plan.cardId != null) {
      final cards = await db.query(DatabaseHelper.tableCreditCards, where: 'id = ?', whereArgs: [plan.cardId]);
      if (cards.isNotEmpty) {
        final card = CreditCard.fromMap(cards.first);
        await updateCreditCardOutstanding(plan.cardId!, card.outstanding + plan.principal);
      }
    }
  }

  Future<List<EmiPlan>> getEmiPlansForCard(String cardId) async {
    if (kIsWeb) return [];
    final db = await database;
    final maps = await db.query(DatabaseHelper.tableEmiPlans,
        where: 'card_id = ?', whereArgs: [cardId], orderBy: 'created_at DESC');
    return maps.map((m) => EmiPlan.fromMap(m)).toList();
  }

  Future<List<EmiPlan>> getAllEmiPlans({bool? activeOnly, int? limit, int? offset}) async {
    if (kIsWeb) return [];
    final db = await database;
    final maps = await db.query(
      DatabaseHelper.tableEmiPlans,
      where: activeOnly == true ? 'is_active = 1' : null,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((m) => EmiPlan.fromMap(m)).toList();
  }

  Future<void> updateEmiPlan(EmiPlan plan) async {
    if (kIsWeb) return;
    final db = await database;
    await db.update(DatabaseHelper.tableEmiPlans, plan.toMap(), where: 'id = ?', whereArgs: [plan.id]);
  }

  Future<void> deleteEmiPlan(String id) async {
    if (kIsWeb) return;
    final db = await database;
    await db.delete(DatabaseHelper.tableEmiPlans, where: 'id = ?', whereArgs: [id]);
    // Also delete associated transactions
    await db.delete(DatabaseHelper.tableTransactions, where: 'related_entity_id = ? AND source = ?', whereArgs: [id, 'emi']);
  }

  // ============= Bank Accounts =============
  Future<void> insertBankAccount(BankAccount account) async {
    if (kIsWeb) return;
    final db = await database;
    await db.insert(DatabaseHelper.tableBankAccounts, account.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    notifyDataChange();
  }

  Future<List<BankAccount>> getAllBankAccounts({int? limit, int? offset}) async {
    if (kIsWeb) return [];
    final db = await database;
    final maps = await db.query(DatabaseHelper.tableBankAccounts, orderBy: 'created_at ASC', limit: limit, offset: offset);
    return maps.map((m) => BankAccount.fromMap(m)).toList();
  }

  Future<BankAccount?> getBankAccountById(String id) async {
    if (kIsWeb) return null;
    final db = await database;
    final maps = await db.query(DatabaseHelper.tableBankAccounts, where: 'id = ?', whereArgs: [id], limit: 1);
    if (maps.isNotEmpty) return BankAccount.fromMap(maps.first);
    return null;
  }

  Future<void> updateBankAccount(BankAccount account) async {
    if (kIsWeb) return;
    final db = await database;
    await db.update(DatabaseHelper.tableBankAccounts, account.toMap(), where: 'id = ?', whereArgs: [account.id]);
    notifyDataChange();
  }

  Future<void> deleteBankAccount(String id) async {
    if (kIsWeb) return;
    final db = await database;
    await db.delete(DatabaseHelper.tableBankAccounts, where: 'id = ?', whereArgs: [id]);
  }

  Future<double> getTotalBankBalance() async {
    if (kIsWeb) return 0.0;
    final accounts = await getAllBankAccounts();
    double total = 0;
    for (final a in accounts) {
      if (a.isAsset) total += a.balance;
    }
    return total;
  }

  /// ============= Security: User Data Isolation =============
  /// Clears all user-specific data from local DB.
  /// Called on logout to prevent data leaks between accounts.
  Future<void> clearAllUserData() async {
    if (kIsWeb) return;
    final db = await database;
    await db.delete(DatabaseHelper.tableTransactions);
    await db.delete(DatabaseHelper.tableBankAccounts);
    await db.delete(DatabaseHelper.tableCreditCards);
    await db.delete(DatabaseHelper.tableEmiPlans);
    await db.delete(DatabaseHelper.tableLendings);
    await db.delete(DatabaseHelper.tableBudgets);
    await db.delete(DatabaseHelper.tableRecurringTemplates);
    await db.delete(DatabaseHelper.tableFuelLogs);
    await db.delete(DatabaseHelper.tableVehicles);
    // Keep categories and tags as they are device-level defaults
    notifyDataChange();
  }

  Future<int> deleteExpenseData() async {
    if (kIsWeb) return 0;
    Database db = await database;
    final count = await db.delete(DatabaseHelper.tableTransactions, where: 'type = ?', whereArgs: ['expense']);
    notifyDataChange();
    return count;
  }

  Future<int> deleteIncomeData() async {
    if (kIsWeb) return 0;
    Database db = await database;
    final count = await db.delete(DatabaseHelper.tableTransactions, where: 'type = ?', whereArgs: ['income']);
    notifyDataChange();
    return count;
  }

  Future<int> deleteLendingData() async {
    if (kIsWeb) return 0;
    Database db = await database;
    final count = await db.delete(DatabaseHelper.tableLendings);
    await db.delete(DatabaseHelper.tableTransactions, where: 'source = ?', whereArgs: ['lending']);
    notifyDataChange();
    return count;
  }

  Future<int> deleteVehicleData() async {
    if (kIsWeb) return 0;
    Database db = await database;
    final count = await db.delete(DatabaseHelper.tableVehicles);
    await db.delete(DatabaseHelper.tableFuelLogs);
    await db.delete(DatabaseHelper.tableTransactions, where: 'source = ?', whereArgs: ['vehicle']);
    notifyDataChange();
    return count;
  }

  Future<int> deleteCreditData() async {
    if (kIsWeb) return 0;
    Database db = await database;
    final count = await db.delete(DatabaseHelper.tableCreditCards);
    await db.delete(DatabaseHelper.tableEmiPlans);
    await db.delete(DatabaseHelper.tableTransactions, where: 'source = ? OR source = ?', whereArgs: ['credit_card', 'emi']);
    notifyDataChange();
    return count;
  }

  /// Full database reset — closes connection and deletes the file.
  Future<void> resetDatabase() async {
    if (kIsWeb) return;
    if (DatabaseHelper._database != null) {
      await DatabaseHelper._database!.close();
      DatabaseHelper._database = null;
    }
    final dbPath = p.join(await getDatabasesPath(), DatabaseHelper._databaseName);
    await deleteDatabase(dbPath);
  }

  /// ============= Backup & Restore Snapshot =============

  // ================= Net Worth Snapshots =================

  Future<void> insertNetWorthSnapshot({
    required String id,
    required double netWorth,
    required double assets,
    required double liabilities,
    required DateTime timestamp,
  }) async {
    if (kIsWeb) return;
    final db = await database;
    await db.insert(
      DatabaseHelper.tableNetWorthSnapshots,
      {
        'id': id,
        'net_worth': netWorth,
        'assets': assets,
        'liabilities': liabilities,
        'timestamp': timestamp.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getNetWorthHistory({int? limit, int? offset}) async {
    if (kIsWeb) return [];
    final db = await database;
    return await db.query(
      DatabaseHelper.tableNetWorthSnapshots,
      orderBy: 'timestamp DESC', // Changed to DESC for history lists
      limit: limit,
      offset: offset,
    );
  }

  Future<void> deleteNetWorthSnapshot(String id) async {
    if (kIsWeb) return;
    final db = await database;
    await db.delete(
      DatabaseHelper.tableNetWorthSnapshots,
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyDataChange();
  }

  /// Returns a Map containing list of maps for every data table
  Future<Map<String, List<Map<String, dynamic>>>> getFullSnapshot() async {
    if (kIsWeb) return {};
    final db = await database;
    final Map<String, List<Map<String, dynamic>>> snapshot = {};

    final tables = [
      DatabaseHelper.tableCategories,
      DatabaseHelper.tableTags,
      DatabaseHelper.tableTransactions,
      DatabaseHelper.tableBudgets,
      DatabaseHelper.tableRecurringTemplates,
      DatabaseHelper.tableVehicles,
      DatabaseHelper.tableFuelLogs,
      DatabaseHelper.tableLendings,
      DatabaseHelper.tableCreditCards,
      DatabaseHelper.tableEmiPlans,
      DatabaseHelper.tableBankAccounts,
      DatabaseHelper.tableNetWorthSnapshots,
    ];

    for (final t in tables) {
      snapshot[t] = await db.query(t);
    }

    return snapshot;
  }

  /// Wipes all existing data and replaces it with the provided snapshot
  Future<void> restoreFromSnapshot(Map<String, dynamic> snapshot) async {
    if (kIsWeb) return;
    final db = await database;

    await db.transaction((txn) async {
      // 1. Wipe all tables in reverse dependency order (if possible)
      final tables = [
        DatabaseHelper.tableTransactions, DatabaseHelper.tableFuelLogs, DatabaseHelper.tableEmiPlans, 
        DatabaseHelper.tableBudgets, DatabaseHelper.tableRecurringTemplates, DatabaseHelper.tableLendings, 
        DatabaseHelper.tableVehicles, DatabaseHelper.tableCreditCards, DatabaseHelper.tableBankAccounts, 
        DatabaseHelper.tableNetWorthSnapshots, DatabaseHelper.tableTags, DatabaseHelper.tableCategories
      ];

      for (final t in tables) {
        await txn.delete(t);
      }

      // 2. Restore data
      for (final entry in snapshot.entries) {
        final tableName = entry.key;
        final rows = entry.value as List;
        for (final row in rows) {
          await txn.insert(tableName, row as Map<String, dynamic>, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });

    notifyDataChange();
  }

}


