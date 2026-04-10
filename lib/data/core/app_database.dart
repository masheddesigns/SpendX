import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'tables.dart';

class AppDatabase {
  static final AppDatabase instance = AppDatabase._init();
  static Database? _database;

  AppDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('spendx.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 19,
      onCreate: _onCreate,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 3) {
          await _migrateToV3(db);
        }
        if (oldVersion < 5) {
          await _migrateToV5(db);
        }
        if (oldVersion < 6) {
          await _migrateToV6(db);
        }
        if (oldVersion < 7) {
          await _migrateToV7(db);
        }
        if (oldVersion < 8) {
          await _migrateToV8(db);
        }
        if (oldVersion < 9) {
          await _migrateToV9(db);
        }
        if (oldVersion < 10) {
          await _migrateToV10(db);
        }
        if (oldVersion < 11) {
          await _migrateToV11(db);
        }
        if (oldVersion < 12) {
          await _migrateToV12(db);
        }
        if (oldVersion < 13) {
          await _migrateToV13(db);
        }
        if (oldVersion < 14) {
          await _migrateToV14(db);
        }
        if (oldVersion < 15) {
          await _migrateToV15(db);
        }
        if (oldVersion < 16) {
          await _migrateToV16(db);
        }
        if (oldVersion < 17) {
          await _migrateToV17(db);
        }
        if (oldVersion < 18) {
          await _migrateToV18(db);
        }
        if (oldVersion < 19) {
          await _migrateToV19(db);
        }
        await _executeCreateQueries(db);
      },
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await _executeCreateQueries(db);
  }

  Future<void> _executeCreateQueries(Database db) async {
    for (final query in Tables.allCreateQueries) {
      await db.execute(query);
    }
  }

  Future<void> _migrateToV3(Database db) async {
    // Add missing columns to credit_cards safely
    try {
      await db.execute(
        'ALTER TABLE credit_cards ADD COLUMN limit_amount REAL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE credit_cards ADD COLUMN used_amount REAL DEFAULT 0',
      );
    } catch (_) {}

    // Add missing columns to loans safely
    try {
      await db.execute('ALTER TABLE loans ADD COLUMN total REAL DEFAULT 0');
    } catch (_) {}

    // Ensure category_id is present in budgets if missing
    try {
      await db.execute('ALTER TABLE budgets ADD COLUMN category_id TEXT');
    } catch (_) {}
  }

  Future<void> _migrateToV5(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE lendings ADD COLUMN user_id TEXT DEFAULT "offline_user"',
      );
    } catch (_) {}
    try {
      await db.execute(
        'ALTER TABLE lendings ADD COLUMN person_name TEXT DEFAULT ""',
      );
    } catch (_) {}
    try {
      await db.execute(
        'ALTER TABLE lendings ADD COLUMN type TEXT DEFAULT "lent"',
      );
    } catch (_) {}
    try {
      await db.execute(
        'ALTER TABLE lendings ADD COLUMN original_amount REAL DEFAULT 0.0',
      );
    } catch (_) {}
    try {
      await db.execute(
        'ALTER TABLE lendings ADD COLUMN paid_amount REAL DEFAULT 0.0',
      );
    } catch (_) {}
    try {
      await db.execute('ALTER TABLE lendings ADD COLUMN date TEXT DEFAULT ""');
    } catch (_) {}
    try {
      await db.execute('ALTER TABLE lendings ADD COLUMN due_date TEXT');
    } catch (_) {}
    try {
      await db.execute('ALTER TABLE lendings ADD COLUMN notes TEXT');
    } catch (_) {}
    try {
      await db.execute(
        'ALTER TABLE lendings ADD COLUMN is_settled INTEGER DEFAULT 0',
      );
    } catch (_) {}
    try {
      await db.execute(
        'ALTER TABLE lendings ADD COLUMN created_at TEXT DEFAULT ""',
      );
    } catch (_) {}
    try {
      await db.execute(
        'ALTER TABLE lendings ADD COLUMN updated_at TEXT DEFAULT ""',
      );
    } catch (_) {}
    try {
      await db.execute('ALTER TABLE lendings ADD COLUMN categoryId TEXT');
    } catch (_) {}
  }

  Future<void> _migrateToV6(Database db) async {
    try {
      await db.execute('ALTER TABLE categories ADD COLUMN user_id TEXT');
    } catch (_) {}
  }

  Future<void> _migrateToV7(Database db) async {
    try {
      await db.execute('ALTER TABLE transactions ADD COLUMN account_id TEXT');
    } catch (_) {}
  }

  Future<void> _migrateToV8(Database db) async {
    try {
      await db.execute(Tables.createMerchantRules);
    } catch (_) {}
    try {
      await db.execute(Tables.createMerchantRulesIndex);
    } catch (_) {}
  }

  Future<void> _migrateToV9(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE transactions ADD COLUMN external_ref TEXT',
      );
    } catch (_) {}
    try {
      await db.execute(Tables.createTransactionsExternalRefIndex);
    } catch (_) {}
  }

  Future<void> _migrateToV16(Database db) async {
    // Backfill company_id on salary_months if any companies exist
    try {
      final companies = await db.query('companies', limit: 1);
      if (companies.isNotEmpty) {
        final defaultId = companies.first['id'];
        await db.rawUpdate(
          'UPDATE ${Tables.salaryMonths} SET company_id = ? WHERE company_id IS NULL',
          [defaultId],
        );
      }
    } catch (_) {}
  }

  Future<void> _migrateToV17(Database db) async {
    final columns = await db.rawQuery("PRAGMA table_info(ledger_transactions)");
    final exists = columns.any((c) => c['name'] == 'category_id');

    if (!exists) {
      await db.execute('''
        ALTER TABLE ledger_transactions 
        ADD COLUMN category_id INTEGER
      ''');
    }
  }

  Future<void> _migrateToV15(Database db) async {
    try { await db.execute(Tables.createSalaryMonths); } catch (_) {}
    try { await db.execute(Tables.createSalaryLedger); } catch (_) {}
  }

  Future<void> _migrateToV14(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE ${Tables.companies} ADD COLUMN currency TEXT DEFAULT \'INR\'',
      );
    } catch (_) {}
  }

  Future<void> _migrateToV13(Database db) async {
    try { await db.execute(Tables.createStreaks); } catch (_) {}
    try { await db.execute(Tables.createGoalLogs); } catch (_) {}
  }

  Future<void> _migrateToV12(Database db) async {
    try {
      await db.execute(Tables.createGoals);
    } catch (_) {}
  }

  Future<void> _migrateToV11(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE ${Tables.merchantRules} ADD COLUMN account_id TEXT',
      );
    } catch (_) {}
  }

  Future<void> _migrateToV10(Database db) async {
    try {
      await db.execute(Tables.createReviewQueue);
    } catch (_) {}
  }

  Future<void> _migrateToV18(Database db) async {
    try {
      await db.execute(
        "ALTER TABLE ${Tables.companies} ADD COLUMN employment_type TEXT DEFAULT 'fullTime'",
      );
    } catch (_) {}
  }

  Future<void> _migrateToV19(Database db) async {
    try {
      await db.execute(
        "ALTER TABLE ${Tables.companies} ADD COLUMN pay_cycle TEXT DEFAULT 'monthly'",
      );
    } catch (_) {}
    try {
      await db.execute(
        'ALTER TABLE ${Tables.salaryMonths} ADD COLUMN is_on_hold INTEGER DEFAULT 0',
      );
    } catch (_) {}
  }

  Future<void> close() async {
    final db = await instance.database;
    db.close();
  }
}
