class NotificationSettings {
  final bool loanDue;
  final bool creditDue;
  final bool salaryReminder;
  final bool emiPayment;
  final bool subscriptionAlerts;
  final bool budgetAlerts;
  final bool backupStatus;
  final bool autoBackup;
  final bool expenseReminder;
  final bool generalUpdates;
  final String reminderTime;
  final String reminderSound;

  NotificationSettings({
    this.loanDue = true,
    this.creditDue = true,
    this.salaryReminder = true,
    this.emiPayment = true,
    this.subscriptionAlerts = true,
    this.budgetAlerts = true,
    this.backupStatus = true,
    this.autoBackup = true,
    this.expenseReminder = false,
    this.generalUpdates = true,
    this.reminderTime = '09:00',
    this.reminderSound = 'default',
  });

  Map<String, dynamic> toMap() => {
    'loanDue': loanDue,
    'creditDue': creditDue,
    'salaryReminder': salaryReminder,
    'emiPayment': emiPayment,
    'subscriptionAlerts': subscriptionAlerts,
    'budgetAlerts': budgetAlerts,
    'backupStatus': backupStatus,
    'autoBackup': autoBackup,
    'expenseReminder': expenseReminder,
    'generalUpdates': generalUpdates,
    'reminderTime': reminderTime,
    'reminderSound': reminderSound,
  };

  factory NotificationSettings.fromMap(Map<String, dynamic> map) =>
      NotificationSettings(
        loanDue: map['loanDue'] ?? true,
        creditDue: map['creditDue'] ?? true,
        salaryReminder: map['salaryReminder'] ?? true,
        emiPayment: map['emiPayment'] ?? true,
        subscriptionAlerts: map['subscriptionAlerts'] ?? true,
        budgetAlerts: map['budgetAlerts'] ?? true,
        backupStatus: map['backupStatus'] ?? true,
        autoBackup: map['autoBackup'] ?? true,
        expenseReminder: map['expenseReminder'] ?? false,
        generalUpdates: map['generalUpdates'] ?? true,
        reminderTime: map['reminderTime'] ?? '09:00',
        reminderSound: map['reminderSound'] ?? 'default',
      );

  NotificationSettings copyWith({
    bool? loanDue,
    bool? creditDue,
    bool? salaryReminder,
    bool? emiPayment,
    bool? subscriptionAlerts,
    bool? budgetAlerts,
    bool? backupStatus,
    bool? autoBackup,
    bool? expenseReminder,
    bool? generalUpdates,
    String? reminderTime,
    String? reminderSound,
  }) {
    return NotificationSettings(
      loanDue: loanDue ?? this.loanDue,
      creditDue: creditDue ?? this.creditDue,
      salaryReminder: salaryReminder ?? this.salaryReminder,
      emiPayment: emiPayment ?? this.emiPayment,
      subscriptionAlerts: subscriptionAlerts ?? this.subscriptionAlerts,
      budgetAlerts: budgetAlerts ?? this.budgetAlerts,
      backupStatus: backupStatus ?? this.backupStatus,
      autoBackup: autoBackup ?? this.autoBackup,
      expenseReminder: expenseReminder ?? this.expenseReminder,
      generalUpdates: generalUpdates ?? this.generalUpdates,
      reminderTime: reminderTime ?? this.reminderTime,
      reminderSound: reminderSound ?? this.reminderSound,
    );
  }
}
