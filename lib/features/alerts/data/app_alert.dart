import '../../../models/reminder_model.dart';

enum AlertType {
  salaryDue,
  salaryDelayed,
  partialSalary,
  loanDue,
  creditCardDue,
  vehicleService,
  subscriptionDue,
  custom,
}

enum AlertStatus { active, done, snoozed }

enum AlertSeverity { normal, warning, critical }

class AppAlert {
  const AppAlert({
    required this.id,
    required this.type,
    required this.title,
    required this.description,
    required this.status,
    required this.triggerDate,
    required this.nextTriggerDate,
    required this.linkedEntityId,
    required this.severity,
    this.amount,
  });

  final String id;
  final AlertType type;
  final String title;
  final String description;
  final AlertStatus status;
  final DateTime? triggerDate;
  final DateTime? nextTriggerDate;
  final String? linkedEntityId;
  final AlertSeverity severity;
  final double? amount;
}

AlertType alertTypeFromReminder(Reminder reminder) {
  switch (reminder.type) {
    case ReminderType.salary:
      if (reminder.status == ReminderStatus.overdue) {
        return AlertType.salaryDelayed;
      }
      if ((reminder.metadata['salary_status'] ?? '') == 'partial') {
        return AlertType.partialSalary;
      }
      return AlertType.salaryDue;
    case ReminderType.loan:
    case ReminderType.emi:
      return AlertType.loanDue;
    case ReminderType.credit:
      return AlertType.creditCardDue;
    case ReminderType.service:
    case ReminderType.insurance:
      return AlertType.vehicleService;
    case ReminderType.custom:
      return AlertType.subscriptionDue;
    case ReminderType.lending:
      return AlertType.custom;
  }
}

AlertSeverity alertSeverityFromReminder(Reminder reminder) {
  switch (reminder.status) {
    case ReminderStatus.overdue:
      return AlertSeverity.critical;
    case ReminderStatus.dueToday:
      return AlertSeverity.warning;
    case ReminderStatus.upcoming:
    case ReminderStatus.inactive:
      return AlertSeverity.normal;
  }
}
