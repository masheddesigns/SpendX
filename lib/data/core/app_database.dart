import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'tables.dart';
import '../migrations/ledger_backfill_service.dart';

class AppDatabase {
  static final AppDatabase instance = AppDatabase._init();
  static Database? _database;

  /// Test-only override for the on-disk database file name. Lets tests run the
  /// guarded reconciliation against an isolated database without colliding
  /// with the production `spendx.db` singleton. Passing `null` restores the
  /// default. Setting it also drops any cached connection.
  static String? _testDbPath;
  static void setTestDatabasePath(String? path) {
    _testDbPath = path;
    _database = null;
  }

  AppDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('spendx.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _testDbPath ?? filePath);

    return await openDatabase(
      path,
      version: 21,
      onCreate: _onCreate,
      onUpgrade: (db, oldVersion, newVersion) async {
        await _applyUpgrades(db, oldVersion);
      },
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await _executeCreateQueries(db);
    await _migrateToV21(db);
  }

  Future<void> _executeCreateQueries(Database db) async {
    for (final query in Tables.allCreateQueries) {
      await db.execute(query);
    }
  }

  /// Applies the migration chain for [oldVersion] up to the current schema.
  ///
  /// The v21 step is SCHEMA ONLY: it creates the `ledger_backfill_log` table
  /// and performs NO financial backfill. Financial data mutation is delegated
  /// to the explicit [runLedgerBackfill] entry point, never to the upgrade
  /// path — opening or upgrading a database must not mutate financial data.
  Future<void> _applyUpgrades(Database db, int oldVersion) async {
    if (oldVersion < 3) await _migrateToV3(db);
    if (oldVersion < 5) await _migrateToV5(db);
    if (oldVersion < 6) await _migrateToV6(db);
    if (oldVersion < 7) await _migrateToV7(db);
    if (oldVersion < 8) await _migrateToV8(db);
    if (oldVersion < 9) await _migrateToV9(db);
    if (oldVersion < 10) await _migrateToV10(db);
    if (oldVersion < 11) await _migrateToV11(db);
    if (oldVersion < 12) await _migrateToV12(db);
    if (oldVersion < 13) await _migrateToV13(db);
    if (oldVersion < 14) await _migrateToV14(db);
    if (oldVersion < 15) await _migrateToV15(db);
    if (oldVersion < 16) await _migrateToV16(db);
    if (oldVersion < 17) await _migrateToV17(db);
    if (oldVersion < 18) await _migrateToV18(db);
    if (oldVersion < 19) await _migrateToV19(db);
    if (oldVersion < 20) await _migrateToV20(db);
    if (oldVersion < 21) {
      await _migrateToV21(db);
    }
    await _executeCreateQueries(db);
  }

  /// Applies all schema migrations to an already-open database WITHOUT running
  /// the backfill. Intended for the dry-run harness: it opens a raw exported
  /// copy (which may be at any `user_version`) and then runs
  /// [LedgerBackfillService] itself. [oldVersion] is the DB's current
  /// `user_version` (read it via `PRAGMA user_version`).
  Future<void> migrateSchemaOnly(Database db, int oldVersion) async {
    await _applyUpgrades(db, oldVersion);
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
    await _database?.close();
    _database = null;
  }

  /// V20: ensure ledger_transactions.category_id is TEXT (V17 created it as
  /// INTEGER, but categories use UUID text ids). Preserves all existing rows.
  Future<void> _migrateToV20(Database db) async {
    try {
      final columns = await db.rawQuery(
        'PRAGMA table_info(ledger_transactions)',
      );
      final hasCategoryId = columns.any((c) => c['name'] == 'category_id');
      final isText = columns.any(
        (c) =>
            c['name'] == 'category_id' &&
            (c['type'] as String? ?? '').toUpperCase() == 'TEXT',
      );
      if (isText) return;

      if (!hasCategoryId) {
        // V17 never added the column on this DB (e.g. a real exported v19
        // database). Simply add it as TEXT rather than rebuilding, which would
        // otherwise fail trying to SELECT a non-existent column.
        await db.execute(
          'ALTER TABLE ledger_transactions ADD COLUMN category_id TEXT',
        );
        return;
      }

      await db.execute('''
        CREATE TABLE ledger_transactions_new (
          id TEXT PRIMARY KEY,
          user_id TEXT,
          amount REAL NOT NULL,
          type TEXT NOT NULL,
          date TEXT NOT NULL,
          note TEXT,
          account_id TEXT,
          credit_card_id TEXT,
          loan_id TEXT,
          category_id TEXT,
          reference_id TEXT,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        INSERT INTO ledger_transactions_new
          (id, user_id, amount, type, date, note, account_id,
           credit_card_id, loan_id, category_id, reference_id, created_at)
        SELECT id, user_id, amount, type, date, note, account_id,
               credit_card_id, loan_id, category_id, reference_id, created_at
        FROM ledger_transactions
      ''');
      await db.execute('DROP TABLE ledger_transactions');
      await db.execute(
        'ALTER TABLE ledger_transactions_new RENAME TO ledger_transactions',
      );
    } catch (_) {
      // Defensive: if rebuild fails, leave the table as-is.
    }
  }

  /// V21: Phase 1B ledger backfill + reconciliation.
  ///
  /// Creates the `ledger_backfill_log` (reconciliation audit trail) and the
  /// `ledger_backfill_flags` (local feature-flag / kill-switch store). No
  /// financial data mutation happens here.
  Future<void> _ensureV21Schema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ledger_backfill_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        status TEXT NOT NULL,
        ran_at TEXT NOT NULL,
        report TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ledger_backfill_flags (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  // ---------------------------------------------------------------------------
  // Phase 1D — local feature flag + kill switch (no remote config).
  // `ledgerBackfillEnabled` means the reconciliation feature is *permitted*
  // to run; it does NOT by itself authorize a mutation. The explicit
  // `authorized` signal on [runLedgerBackfill] is required for any write.
  // ---------------------------------------------------------------------------
  static const String _flagEnabled = 'enabled';
  static const String _flagKill = 'kill_switch';

  Future<void> _ensureFlagsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ledger_backfill_flags (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Future<bool> isBackfillEnabled() async {
    final db = await instance.database;
    await _ensureFlagsTable(db);
    final row = await db.query(
      'ledger_backfill_flags',
      where: 'key = ?',
      whereArgs: [_flagEnabled],
    );
    return row.isNotEmpty && row.first['value'] == 'true';
  }

  Future<void> setBackfillEnabled(bool v) async {
    final db = await instance.database;
    await _ensureFlagsTable(db);
    await db.insert(
      'ledger_backfill_flags',
      {'key': _flagEnabled, 'value': v ? 'true' : 'false'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> isKillSwitchActive() async {
    final db = await instance.database;
    await _ensureFlagsTable(db);
    final row = await db.query(
      'ledger_backfill_flags',
      where: 'key = ?',
      whereArgs: [_flagKill],
    );
    return row.isNotEmpty && row.first['value'] == 'true';
  }

  Future<void> setKillSwitch(bool v) async {
    final db = await instance.database;
    await _ensureFlagsTable(db);
    await db.insert(
      'ledger_backfill_flags',
      {'key': _flagKill, 'value': v ? 'true' : 'false'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Read-only preflight: analyzes the current data and returns the verdict
  /// WITHOUT mutating anything. Safe to call any time.
  Future<BackfillReport> preflightReconciliation() async {
    final db = await instance.database;
    await _ensureV21Schema(db);
    if (await isKillSwitchActive()) {
      final report = BackfillReport();
      report.hardFailures.add('Kill switch active: reconciliation disabled.');
      return report;
    }
    return LedgerBackfillService.reconcile(db, authorized: false);
  }

  /// v21 migration — SCHEMA ONLY.
  ///
  /// Creates the `ledger_backfill_log` table and performs no financial data
  /// mutation. The Phase 1B backfill is deliberately NOT run here; it is the
  /// responsibility of the explicit [runLedgerBackfill] entry point.
  Future<void> _migrateToV21(Database db) async {
    await _ensureV21Schema(db);
  }

  /// Explicitly (re)run the guarded Phase 1D reconciliation.
  ///
  /// Three independent gates must ALL pass before any write occurs:
  ///   1. Kill switch inactive.
  ///   2. Feature flag [isBackfillEnabled] true.
  ///   3. Explicit [authorized] signal true.
  ///
  /// Without [authorized] this is a read-only preflight (no mutation). Returns
  /// the resulting report, which is also recorded in `ledger_backfill_log`.
  Future<BackfillReport> runLedgerBackfill({
    bool force = false,
    bool authorized = false,
  }) async {
    final db = await instance.database;
    await _ensureV21Schema(db);

    // Gate 1: kill switch — hard no-op, no mutation, no log write of success.
    if (await isKillSwitchActive()) {
      final report = BackfillReport();
      report.hardFailures.add('Kill switch active: reconciliation disabled.');
      return report;
    }

    // Gate 2: feature flag — permitted to run, but still no mutation here.
    if (!await isBackfillEnabled()) {
      final report = BackfillReport();
      report.exceptions.add(
        'Reconciliation feature is disabled (ledgerBackfillEnabled=false). '
        'Enable it explicitly before authorizing a run.',
      );
      return report;
    }

    // Gate 3: explicit authorization — without it, this is a preflight only.
    if (!authorized) {
      return LedgerBackfillService.reconcile(db, authorized: false);
    }

    // Skip if a prior successful reconcile already recorded (unless forced).
    if (!force) {
      final prior = await db.query(
        'ledger_backfill_log',
        where: 'status IN (?, ?)',
        whereArgs: ['PASS', 'EXECUTABLE_WITH_EXCEPTIONS'],
        limit: 1,
      );
      if (prior.isNotEmpty) {
        final report = BackfillReport();
        report.exceptions.add(
          'Prior successful reconciliation recorded; not re-run '
          '(use force to re-run).',
        );
        return report;
      }
    }

    final report = await LedgerBackfillService.reconcile(db, authorized: true);
    await db.insert('ledger_backfill_log', {
      'status': report.verdict,
      'ran_at': DateTime.now().toIso8601String(),
      'report': report.toSummary().toString(),
    });
    return report;
  }
}
