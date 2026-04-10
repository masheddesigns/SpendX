import 'package:sqflite/sqflite.dart';

class Tables {
  static const transactions = 'transactions';
  static const categories = 'categories';
  static const bankAccounts = 'bank_accounts';
  static const appSessions = 'app_sessions';
  static const creditCards = 'credit_cards';
  static const loans = 'loans';
  static const lendings = 'lendings';
  static const vehicles = 'vehicles';
  static const fuelLogs = 'fuel_logs';
  static const budgets = 'budgets';
  static const recurring = 'recurring';
  static const tags = 'tags';
  static const companies = 'companies';
  static const salaryContracts = 'salary_contracts';
  static const salaryPayments = 'salary_payments';
  static const salaryIncrements = 'salary_increments';
  static const salary = 'salary';
  // ignore: constant_identifier_names
  static const salary_increments = 'salary_increments';
  // ignore: constant_identifier_names
  static const recurring_templates = 'recurring_templates';
  static const challenges = 'challenges';
  static const achievements = 'achievements';
  // ignore: constant_identifier_names
  static const insight_compliance = 'insight_compliance';
  // ignore: constant_identifier_names
  static const health_score_history = 'health_score_history';
  static const reminders = 'reminders';
  static const ledgerTransactions = 'ledger_transactions';
  static const creditTransactions = 'credit_transactions';
  static const creditEmis = 'credit_emis';
  static const emiInstallments = 'emi_installments';
  static const emiPlans = 'emi_plans';
  static const cardStatements = 'card_statements';
  static const loanInstallments = 'loan_installments';
  static const netWorthHistory = 'net_worth_history';
  static const bankBalanceSnapshots = 'bank_balance_snapshots';
  static const vehicleReminders = 'vehicle_reminders';
  static const merchantRules = 'merchant_rules';
  static const reviewQueue = 'review_queue';
  static const goals = 'goals';
  static const goalLogs = 'goal_logs';
  static const streaks = 'streaks';
  static const salaryMonths = 'salary_months';
  static const salaryLedger = 'salary_ledger';

  static const createTransactions =
      '''
    CREATE TABLE IF NOT EXISTS $transactions (
      id TEXT PRIMARY KEY,
      user_id TEXT,
      amount REAL NOT NULL,
      type TEXT NOT NULL,
      category_id TEXT,
      account_id TEXT,
      date TEXT NOT NULL,
      note TEXT,
      notes TEXT,
      tags TEXT,
      source TEXT,
      related_entity_id TEXT,
      external_ref TEXT,
      vehicle_id TEXT,
      is_vehicle_expense INTEGER DEFAULT 0,
      fuel_log_id TEXT,
      location TEXT,
      is_deleted INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''';

  static const createTransactionsExternalRefIndex =
      '''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_tx_external_ref
    ON $transactions(external_ref)
  ''';

  static const createCategories =
      '''
    CREATE TABLE IF NOT EXISTS $categories (
      id TEXT PRIMARY KEY,
      user_id TEXT,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      icon TEXT,
      color TEXT,
      is_preset INTEGER DEFAULT 0
    )
  ''';

  static const createBankAccounts =
      '''
    CREATE TABLE IF NOT EXISTS $bankAccounts (
      id TEXT PRIMARY KEY,
      user_id TEXT,
      name TEXT NOT NULL,
      bank TEXT,
      account_type TEXT,
      balance REAL DEFAULT 0.0,
      color TEXT,
      icon TEXT,
      is_asset INTEGER DEFAULT 1,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''';

  static const createAppSessions =
      '''
    CREATE TABLE IF NOT EXISTS $appSessions (
      id TEXT PRIMARY KEY,
      start_time TEXT,
      end_time TEXT,
      duration_seconds INTEGER,
      date TEXT
    )
  ''';

  static const createCreditCards =
      '''
    CREATE TABLE IF NOT EXISTS $creditCards (
      id TEXT PRIMARY KEY,
      user_id TEXT,
      name TEXT NOT NULL,
      bank TEXT,
      last4 TEXT,
      credit_limit REAL DEFAULT 0.0,
      limit_amount REAL DEFAULT 0.0,
      used_amount REAL DEFAULT 0.0,
      billing_day INTEGER,
      due_day INTEGER,
      card_type TEXT,
      color TEXT,
      outstanding REAL DEFAULT 0.0,
      last_statement_balance REAL DEFAULT 0.0,
      created_at TEXT NOT NULL
    )
  ''';

  static const createLoans =
      '''
    CREATE TABLE IF NOT EXISTS $loans (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      bank TEXT,
      principal_amount REAL DEFAULT 0.0,
      total REAL DEFAULT 0.0,
      interest_rate REAL,
      tenure_months INTEGER,
      monthly_installment REAL,
      start_date TEXT,
      paid_amount REAL DEFAULT 0.0,
      loan_status TEXT,
      next_due_date TEXT,
      category_id TEXT,
      due_day INTEGER,
      loan_type TEXT
    )
  ''';

  static const createLoanInstallments =
      '''
    CREATE TABLE IF NOT EXISTS $loanInstallments (
      id TEXT PRIMARY KEY,
      loanId TEXT NOT NULL,
      dueDate TEXT NOT NULL,
      amount REAL NOT NULL,
      principalComponent REAL DEFAULT 0.0,
      interestComponent REAL DEFAULT 0.0,
      status TEXT DEFAULT 'pending',
      paidDate TEXT
    )
  ''';

  static const createLendings =
      '''
    CREATE TABLE IF NOT EXISTS $lendings (
      id TEXT PRIMARY KEY,
      user_id TEXT,
      person_name TEXT NOT NULL,
      type TEXT NOT NULL,
      original_amount REAL DEFAULT 0.0,
      paid_amount REAL DEFAULT 0.0,
      date TEXT NOT NULL,
      due_date TEXT,
      notes TEXT,
      is_settled INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      categoryId TEXT
    )
  ''';

  static const createVehicles =
      '''
    CREATE TABLE IF NOT EXISTS $vehicles (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      make TEXT,
      model TEXT,
      year INTEGER,
      license_plate TEXT,
      fuel_type TEXT,
      odometer REAL DEFAULT 0.0,
      image_path TEXT,
      created_at TEXT NOT NULL
    )
  ''';

  static const createFuelLogs =
      '''
    CREATE TABLE IF NOT EXISTS $fuelLogs (
      id TEXT PRIMARY KEY,
      vehicle_id TEXT NOT NULL,
      date TEXT NOT NULL,
      odometer REAL,
      quantity REAL,
      price_per_unit REAL,
      total_cost REAL,
      is_full_tank INTEGER DEFAULT 1,
      notes TEXT,
      created_at TEXT NOT NULL
    )
  ''';

  static const createVehicleReminders =
      '''
    CREATE TABLE IF NOT EXISTS $vehicleReminders (
      id TEXT PRIMARY KEY,
      vehicle_id TEXT NOT NULL,
      title TEXT NOT NULL,
      type TEXT NOT NULL,
      due_date TEXT,
      recurrence_period TEXT,
      due_odometer REAL,
      interval_km REAL,
      last_triggered_odometer REAL,
      is_active INTEGER DEFAULT 1,
      notes TEXT,
      created_at TEXT NOT NULL
    )
  ''';

  static const createBudgets =
      '''
    CREATE TABLE IF NOT EXISTS $budgets (
      id TEXT PRIMARY KEY,
      category_id TEXT NOT NULL,
      limit_amount REAL NOT NULL,
      period TEXT DEFAULT 'monthly',
      created_at TEXT NOT NULL
    )
  ''';

  static const createNetWorthHistory =
      '''
    CREATE TABLE IF NOT EXISTS $netWorthHistory (
      id TEXT PRIMARY KEY,
      net_worth REAL NOT NULL,
      assets REAL NOT NULL,
      liabilities REAL NOT NULL,
      timestamp TEXT NOT NULL
    )
  ''';

  static const createBankBalanceSnapshots =
      '''
    CREATE TABLE IF NOT EXISTS $bankBalanceSnapshots (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      accountId TEXT NOT NULL,
      balance REAL NOT NULL,
      timestamp INTEGER NOT NULL
    )
  ''';

  static const createMerchantRules =
      '''
    CREATE TABLE IF NOT EXISTS $merchantRules (
      id TEXT PRIMARY KEY,
      keyword TEXT NOT NULL,
      category_id TEXT NOT NULL,
      account_id TEXT,
      usage_count INTEGER DEFAULT 1,
      last_used TEXT NOT NULL
    )
  ''';

  static const createMerchantRulesIndex =
      '''
    CREATE INDEX IF NOT EXISTS idx_merchant_keyword
    ON $merchantRules(keyword)
  ''';

  static const createCompanies =
      '''
    CREATE TABLE IF NOT EXISTS $companies (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      salary_credit_day INTEGER DEFAULT 1,
      currency TEXT DEFAULT 'INR',
      employment_type TEXT DEFAULT 'fullTime',
      pay_cycle TEXT DEFAULT 'monthly',
      created_at TEXT NOT NULL
    )
  ''';

  static const createSalaryContracts =
      '''
    CREATE TABLE IF NOT EXISTS $salaryContracts (
      id TEXT PRIMARY KEY,
      company_id TEXT NOT NULL,
      base_salary REAL NOT NULL,
      start_date TEXT NOT NULL,
      default_account_id TEXT,
      is_active INTEGER DEFAULT 1,
      created_at TEXT NOT NULL,
      FOREIGN KEY (company_id) REFERENCES $companies (id) ON DELETE CASCADE
    )
  ''';

  static const createSalaryPayments =
      '''
    CREATE TABLE IF NOT EXISTS $salaryPayments (
      id TEXT PRIMARY KEY,
      contract_id TEXT NOT NULL,
      month TEXT NOT NULL,
      expected_date TEXT NOT NULL,
      received_date TEXT,
      total_amount REAL NOT NULL,
      amount_received REAL DEFAULT 0.0,
      bonus_amount REAL DEFAULT 0.0,
      account_id TEXT,
      linked_transaction_id TEXT,
      manual_status TEXT,
      notes TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY (contract_id) REFERENCES $salaryContracts (id) ON DELETE CASCADE
    )
  ''';

  static const createSalaryIncrements =
      '''
    CREATE TABLE IF NOT EXISTS $salaryIncrements (
      id TEXT PRIMARY KEY,
      contract_id TEXT NOT NULL,
      amount_increase REAL NOT NULL,
      effective_from TEXT NOT NULL,
      notes TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY (contract_id) REFERENCES $salaryContracts (id) ON DELETE CASCADE
    )
  ''';

  static const createSalary =
      '''
    CREATE TABLE IF NOT EXISTS $salary (
      id TEXT PRIMARY KEY,
      company_name TEXT NOT NULL,
      salary_month TEXT NOT NULL,
      expected_date TEXT NOT NULL,
      received_date TEXT,
      net_salary REAL DEFAULT 0.0,
      amount_received REAL DEFAULT 0.0,
      account_id TEXT,
      linked_transaction_id TEXT,
      manual_status TEXT,
      notes TEXT,
      created_at TEXT NOT NULL
    )
  ''';

  static const createRecurringTemplates =
      '''
    CREATE TABLE IF NOT EXISTS $recurring_templates (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      amount REAL NOT NULL,
      type TEXT NOT NULL,
      category_id TEXT,
      frequency TEXT NOT NULL,
      interval INTEGER DEFAULT 1,
      day_of_month INTEGER,
      day_of_week INTEGER,
      last_generated TEXT,
      next_generation TEXT,
      is_active INTEGER DEFAULT 1,
      created_at TEXT NOT NULL
    )
  ''';

  static const createChallenges =
      '''
    CREATE TABLE IF NOT EXISTS $challenges (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      description TEXT,
      type TEXT NOT NULL,
      target_value REAL,
      current_value REAL DEFAULT 0.0,
      start_date TEXT NOT NULL,
      end_date TEXT NOT NULL,
      status TEXT DEFAULT 'active',
      created_at TEXT NOT NULL
    )
  ''';

  static const createAchievements =
      '''
    CREATE TABLE IF NOT EXISTS $achievements (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      description TEXT,
      icon TEXT,
      unlocked_at TEXT,
      created_at TEXT NOT NULL
    )
  ''';

  static const createInsightCompliance =
      '''
    CREATE TABLE IF NOT EXISTS $insight_compliance (
      id TEXT PRIMARY KEY,
      insight_id TEXT NOT NULL,
      date TEXT NOT NULL,
      status TEXT NOT NULL,
      notes TEXT,
      created_at TEXT NOT NULL
    )
  ''';

  static const createHealthScoreHistory =
      '''
    CREATE TABLE IF NOT EXISTS $health_score_history (
      id TEXT PRIMARY KEY,
      timestamp TEXT NOT NULL,
      total_score REAL NOT NULL,
      savings_rate REAL NOT NULL,
      debt_ratio REAL NOT NULL,
      discipline REAL NOT NULL,
      consistency REAL NOT NULL,
      asset_growth REAL NOT NULL
    )
  ''';

  static const createReminders =
      '''
    CREATE TABLE IF NOT EXISTS $reminders (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      description TEXT,
      type TEXT NOT NULL,
      date TEXT NOT NULL,
      repeat_type TEXT DEFAULT 'once',
      is_completed INTEGER DEFAULT 0,
      created_at TEXT NOT NULL
    )
  ''';

  static const createTags =
      '''
    CREATE TABLE IF NOT EXISTS $tags (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      color TEXT,
      created_at TEXT NOT NULL
    )
  ''';

  static const createLedgerTransactions =
      '''
    CREATE TABLE IF NOT EXISTS $ledgerTransactions (
      id TEXT PRIMARY KEY,
      user_id TEXT,
      amount REAL NOT NULL,
      type TEXT NOT NULL,
      date TEXT NOT NULL,
      note TEXT,
      account_id TEXT,
      credit_card_id TEXT,
      loan_id TEXT,
      reference_id TEXT,
      created_at TEXT NOT NULL
    )
  ''';

  static const createCreditTransactions =
      '''
    CREATE TABLE IF NOT EXISTS $creditTransactions (
      id TEXT PRIMARY KEY,
      cardId TEXT NOT NULL,
      amount REAL NOT NULL,
      date TEXT NOT NULL,
      category TEXT NOT NULL,
      note TEXT,
      type TEXT NOT NULL,
      status TEXT NOT NULL,
      statementId TEXT,
      categoryId TEXT
    )
  ''';

  static const createCreditEmis =
      '''
    CREATE TABLE IF NOT EXISTS $creditEmis (
      id TEXT PRIMARY KEY,
      cardId TEXT NOT NULL,
      transactionId TEXT NOT NULL,
      principalAmount REAL NOT NULL,
      interestRate REAL NOT NULL,
      interestAmount REAL NOT NULL,
      processingFee REAL NOT NULL,
      tenureMonths INTEGER NOT NULL,
      monthlyInstallment REAL NOT NULL,
      startDate TEXT NOT NULL,
      paidMonths INTEGER DEFAULT 0,
      remainingMonths INTEGER NOT NULL,
      createdAt TEXT NOT NULL,
      categoryId TEXT
    )
  ''';

  static const createEmiInstallments =
      '''
    CREATE TABLE IF NOT EXISTS $emiInstallments (
      id TEXT PRIMARY KEY,
      emiId TEXT NOT NULL,
      dueDate TEXT NOT NULL,
      amount REAL NOT NULL,
      status TEXT NOT NULL
    )
  ''';

  static const createEmiPlans =
      '''
    CREATE TABLE IF NOT EXISTS $emiPlans (
      id TEXT PRIMARY KEY,
      user_id TEXT,
      card_id TEXT,
      name TEXT NOT NULL,
      principal REAL NOT NULL,
      interest_rate REAL NOT NULL,
      tenure_months INTEGER NOT NULL,
      emi_amount REAL NOT NULL,
      start_date TEXT NOT NULL,
      category_id TEXT,
      notes TEXT,
      is_active INTEGER DEFAULT 1,
      paid_instalments INTEGER DEFAULT 0,
      created_at TEXT NOT NULL
    )
  ''';

  static const createCardStatements =
      '''
    CREATE TABLE IF NOT EXISTS $cardStatements (
      id TEXT PRIMARY KEY,
      cardId TEXT NOT NULL,
      startDate TEXT NOT NULL,
      endDate TEXT NOT NULL,
      statementAmount REAL NOT NULL,
      minimumDue REAL NOT NULL,
      generatedDate TEXT NOT NULL
    )
  ''';

  static const createGoals =
      '''
    CREATE TABLE IF NOT EXISTS $goals (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      type TEXT NOT NULL,
      target_amount REAL NOT NULL,
      current_amount REAL DEFAULT 0.0,
      start_date TEXT NOT NULL,
      end_date TEXT NOT NULL,
      category_id TEXT,
      account_id TEXT,
      is_active INTEGER DEFAULT 1,
      created_at TEXT NOT NULL
    )
  ''';

  static const createSalaryMonths =
      '''
    CREATE TABLE IF NOT EXISTS $salaryMonths (
      id TEXT PRIMARY KEY,
      company_id TEXT,
      month TEXT NOT NULL,
      expected_amount REAL NOT NULL,
      due_date TEXT NOT NULL,
      is_on_hold INTEGER DEFAULT 0,
      created_at TEXT NOT NULL
    )
  ''';

  static const createSalaryLedger =
      '''
    CREATE TABLE IF NOT EXISTS $salaryLedger (
      id TEXT PRIMARY KEY,
      month_id TEXT NOT NULL,
      amount REAL NOT NULL,
      type TEXT NOT NULL,
      paid_date TEXT NOT NULL,
      note TEXT
    )
  ''';

  static const createStreaks =
      '''
    CREATE TABLE IF NOT EXISTS $streaks (
      id TEXT PRIMARY KEY,
      current_streak INTEGER DEFAULT 0,
      best_streak INTEGER DEFAULT 0,
      last_evaluated TEXT
    )
  ''';

  static const createGoalLogs =
      '''
    CREATE TABLE IF NOT EXISTS $goalLogs (
      id TEXT PRIMARY KEY,
      goal_id TEXT NOT NULL,
      amount REAL NOT NULL,
      note TEXT,
      created_at TEXT NOT NULL
    )
  ''';

  static const createReviewQueue =
      '''
    CREATE TABLE IF NOT EXISTS $reviewQueue (
      id TEXT PRIMARY KEY,
      raw_sms TEXT NOT NULL,
      parsed_json TEXT NOT NULL,
      confidence REAL NOT NULL,
      status TEXT DEFAULT 'pending',
      created_at TEXT NOT NULL
    )
  ''';

  static const allCreateQueries = <String>[
    createCategories,
    createBankAccounts,
    createTransactions,
    createTransactionsExternalRefIndex,
    createCreditCards,
    createLoans,
    createLoanInstallments,
    createLendings,
    createVehicles,
    createFuelLogs,
    createVehicleReminders,
    createBudgets,
    createTags,
    createRecurringTemplates,
    createReminders,
    createLedgerTransactions,
    createCreditTransactions,
    createCreditEmis,
    createEmiInstallments,
    createEmiPlans,
    createCardStatements,
    createCompanies,
    createSalaryContracts,
    createSalaryPayments,
    createSalaryIncrements,
    createSalary,
    createNetWorthHistory,
    createBankBalanceSnapshots,
    createMerchantRules,
    createMerchantRulesIndex,
    createReviewQueue,
    createGoals,
    createGoalLogs,
    createSalaryMonths,
    createSalaryLedger,
    createStreaks,
    createHealthScoreHistory,
    createAppSessions,
    createChallenges,
    createAchievements,
    createInsightCompliance,
  ];

  static Future<void> createAll(Database db) async {
    for (final query in allCreateQueries) {
      await db.execute(query);
    }
  }
}
