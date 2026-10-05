/// Fundamental accounting classification of accounts in SpendX 2.0.
library;

/// The normal balance direction of an account type.
enum NormalBalance {
  /// Debit normal balance: increases with debits, decreases with credits.
  debit,

  /// Credit normal balance: increases with credits, decreases with debits.
  credit;

  bool get isDebit => this == debit;
  bool get isCredit => this == credit;
}

/// The 5 fundamental double-entry account categories.
enum AccountType {
  /// Assets: Resources owned (e.g. Bank accounts, Cash, Investments).
  /// Normal balance: Debit.
  asset(NormalBalance.debit),

  /// Liabilities: Obligations owed (e.g. Credit cards, Loans, Mortgages).
  /// Normal balance: Credit.
  liability(NormalBalance.credit),

  /// Equity: Residual interest / capital / opening balance equity.
  /// Normal balance: Credit.
  equity(NormalBalance.credit),

  /// Income: Inflows / revenue (e.g. Salary, Interest, Dividends).
  /// Normal balance: Credit.
  income(NormalBalance.credit),

  /// Expenses: Outflows / costs consumed (e.g. Food, Transport, Rent).
  /// Normal balance: Debit.
  expense(NormalBalance.debit);

  final NormalBalance normalBalance;

  const AccountType(this.normalBalance);

  /// Whether this account type naturally increases on the debit side.
  bool get increasesOnDebit => normalBalance == NormalBalance.debit;

  /// Whether this account type naturally increases on the credit side.
  bool get increasesOnCredit => normalBalance == NormalBalance.credit;

  /// Computes the signed net balance impact given debits and credits in minor units.
  ///
  /// For debit-normal accounts (Asset, Expense):
  ///   impact = debits - credits
  /// For credit-normal accounts (Liability, Equity, Income):
  ///   impact = credits - debits
  int computeBalanceImpact({
    required int debitsMinorUnits,
    required int creditsMinorUnits,
  }) {
    if (increasesOnDebit) {
      return debitsMinorUnits - creditsMinorUnits;
    } else {
      return creditsMinorUnits - debitsMinorUnits;
    }
  }
}
