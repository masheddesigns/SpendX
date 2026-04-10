/// Supported AI assistant intents.
/// Each maps to a deterministic data query — no LLM guessing.
enum AIIntent {
  balance,         // "What's my balance?"
  spending,        // "How much did I spend this month?"
  income,          // "How much did I earn?"
  categories,      // "Where did I spend most?"
  netWorth,        // "What is my net worth?"
  trend,           // "Am I spending more than last month?"
  savingsRate,     // "What's my savings rate?"
  creditCards,     // "How much do I owe on cards?"
  creditHealth,    // "How much should I pay on my card?"
  emiLoad,         // "What is my EMI burden?"
  upcomingDues,    // "Any card dues this week?"
  debtPressure,    // "Am I in financial trouble?"
  healthScore,     // "How is my financial health?"
  anomalyCheck,    // "Anything unusual?" / "Why is my score low?"
  streakStatus,    // "How am I doing?" / "My streak?"
  budgetStatus,    // "Am I over budget?"
  runwayStatus,    // "How long will my money last?"
  financialAdvice, // "What should I do?" / "Any suggestions?"
  forecast,        // "Next month?" / "Prediction?"
  progressStatus,  // "My level?" / "XP?"
  canIAfford,      // "Can I buy X?" / "Can I afford?"
  incomeStability, // "Is my income stable?"
  salaryPrediction,// "When will I get salary?"
  unknown,         // Falls through to Gemini
}

/// Parse user input into an [AIIntent] using keyword matching.
/// Returns [AIIntent.unknown] if no keywords match.
///
/// This is intentionally rule-based (not ML) for:
///   - zero latency
///   - deterministic behavior
///   - no API cost
AIIntent parseIntent(String input) {
  final lower = input.toLowerCase().trim();

  // Order matters: more specific patterns first

  // Net worth (before "balance" to avoid collision)
  if (_matchesAny(lower, ['net worth', 'networth', 'total worth'])) {
    return AIIntent.netWorth;
  }

  // Savings rate
  if (_matchesAny(lower, ['savings rate', 'saving rate', 'save rate',
      'how much am i saving', 'how much did i save'])) {
    return AIIntent.savingsRate;
  }

  // Trends (month-over-month)
  if (_matchesAny(lower, ['trend', 'compared to last month', 'vs last month',
      'more than last month', 'less than last month', 'increased', 'decreased',
      'spending change', 'month over month'])) {
    return AIIntent.trend;
  }

  // Upcoming dues
  if (_matchesAny(lower, ['dues this week', 'upcoming due', 'any dues',
      'payment due soon', 'due this week', 'card due date'])) {
    return AIIntent.upcomingDues;
  }

  // Credit health (how much to pay)
  if (_matchesAny(lower, ['how much should i pay', 'minimum due', 'interest risk',
      'card payment', 'pay on my card', 'card health', 'credit health'])) {
    return AIIntent.creditHealth;
  }

  // EMI load
  if (_matchesAny(lower, ['emi', 'installment', 'monthly emi', 'emi burden',
      'emi load', 'loan emi', 'how much emi'])) {
    return AIIntent.emiLoad;
  }

  // Income stability
  if (_matchesAny(lower, ['income stable', 'income stability', 'stable income',
      'reliable income', 'consistent income'])) {
    return AIIntent.incomeStability;
  }

  // Salary prediction
  if (_matchesAny(lower, ['when will i get salary', 'when salary', 'next salary',
      'salary date', 'when will salary come', 'salary prediction'])) {
    return AIIntent.salaryPrediction;
  }

  // Can I afford / scenario
  if (_matchesAny(lower, ['can i afford', 'can i buy', 'should i buy',
      'can i spend', 'if i buy', 'if i spend', 'worth it'])) {
    return AIIntent.canIAfford;
  }

  // Forecast
  if (_matchesAny(lower, ['forecast', 'prediction', 'next month',
      'predict', 'projected', 'will i spend'])) {
    return AIIntent.forecast;
  }

  // Progress / gamification
  if (_matchesAny(lower, ['my level', 'xp', 'experience', 'achievements',
      'rewards', 'gamification', 'progress status'])) {
    return AIIntent.progressStatus;
  }

  // Financial advice (catch-all for "what should I do")
  if (_matchesAny(lower, ['what should i do', 'any suggestions', 'advice',
      'recommend', 'what can i do', 'help me', 'improve'])) {
    return AIIntent.financialAdvice;
  }

  // Runway / cashflow
  if (_matchesAny(lower, ['runway', 'how long will my money last', 'run out',
      'cashflow', 'cash flow', 'days left', 'survive', 'money last'])) {
    return AIIntent.runwayStatus;
  }

  // Budget status
  if (_matchesAny(lower, ['budget', 'over budget', 'am i overspending',
      'spending limit', 'within budget'])) {
    return AIIntent.budgetStatus;
  }

  // Streak status
  if (_matchesAny(lower, ['streak', 'how am i doing', 'my progress',
      'discipline', 'habit', 'consistency', 'how have i been'])) {
    return AIIntent.streakStatus;
  }

  // Anomaly check
  if (_matchesAny(lower, ['anything unusual', 'anomaly', 'unusual spending',
      'why is my score low', 'what went wrong', 'any alerts', 'any warnings',
      'red flags', 'problems'])) {
    return AIIntent.anomalyCheck;
  }

  // Health score (before debt pressure to catch "financial health" specifically)
  if (_matchesAny(lower, ['health score', 'financial score', 'my score',
      'improve my score', 'how is my financial health', 'financial health score'])) {
    return AIIntent.healthScore;
  }

  // Debt pressure
  if (_matchesAny(lower, ['financial trouble', 'debt pressure', 'debt ratio',
      'obligation', 'can i afford', 'financial health'])) {
    return AIIntent.debtPressure;
  }

  // Credit cards (general)
  if (_matchesAny(lower, ['credit card', 'card outstanding', 'card due',
      'owe on card', 'card balance', 'credit due'])) {
    return AIIntent.creditCards;
  }

  // Categories (before spending to catch "where did I spend")
  if (_matchesAny(lower, ['category', 'categories', 'where did i spend',
      'where do i spend', 'top expense', 'most spent', 'biggest expense',
      'highest expense', 'highest spending'])) {
    return AIIntent.categories;
  }

  // Spending
  if (_matchesAny(lower, ['spent', 'spend', 'expense', 'expenses',
      'expenditure', 'how much did i spend'])) {
    return AIIntent.spending;
  }

  // Income
  if (_matchesAny(lower, ['income', 'earned', 'earn', 'salary', 'received',
      'how much did i earn', 'credited'])) {
    return AIIntent.income;
  }

  // Balance (general — last to avoid false matches)
  if (_matchesAny(lower, ['balance', 'money', 'account', 'bank balance',
      'how much do i have', 'available'])) {
    return AIIntent.balance;
  }

  return AIIntent.unknown;
}

bool _matchesAny(String input, List<String> keywords) {
  return keywords.any((k) => input.contains(k));
}
