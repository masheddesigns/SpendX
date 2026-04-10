import 'dart:async';

import '../../../core/database/database_service.dart';
import '../../../data/repositories/credit_repo.dart';
import '../../../data/repositories/lending_repo.dart';
import '../../../data/repositories/loan_repo.dart';
import '../../../data/repositories/salary_repo.dart';
import '../../../models/reminder_model.dart';
import '../../../models/salary_payment.dart';
import '../../../services/salary_service.dart';
import 'app_alert.dart';

class AlertService {
  AlertService({
    required this.databaseService,
    SalaryRepo? salaryRepo,
    LoanRepo? loanRepo,
    CreditRepo? creditRepo,
    LendingRepo? lendingRepo,
    SalaryService? salaryService,
  }) : _salaryRepo = salaryRepo ?? SalaryRepo(),
       _loanRepo = loanRepo ?? LoanRepo(),
       _creditRepo = creditRepo ?? CreditRepo(),
       _lendingRepo = lendingRepo ?? LendingRepo(),
       _salaryService = salaryService ?? SalaryService.instance;

  final DatabaseService databaseService;
  final SalaryRepo _salaryRepo;
  final LoanRepo _loanRepo;
  final CreditRepo _creditRepo;
  final LendingRepo _lendingRepo;
  final SalaryService _salaryService;
  // ignore: unused_field
  static const Duration _activeAlertCacheTtl = Duration(seconds: 10);

  final StreamController<List<AppAlert>> _controller =
      StreamController<List<AppAlert>>.broadcast();

  bool _listening = false;
  // ignore: unused_field
  List<AppAlert>? _activeAlertsCache;
  // ignore: unused_field
  DateTime? _activeAlertsCachedAt;

  Stream<List<AppAlert>> watchActiveAlerts() {
    _ensureListening();
    unawaited(refresh());
    return _controller.stream;
  }

  Future<List<AppAlert>> getActiveAlerts({bool forceRefresh = false}) async {
    final reminders = await databaseService.getAlertRecords(
      forceRefresh: forceRefresh,
    );
    return reminders
        .where(
          (r) =>
              r.recordStatus == ReminderRecordStatus.pending &&
              (r.dueDate == null || r.dueDate!.isBefore(DateTime.now())),
        )
        .map(_mapReminderToAlert)
        .toList()
      ..sort((a, b) {
        final aDate = a.triggerDate ?? a.nextTriggerDate ?? DateTime(2100);
        final bDate = b.triggerDate ?? b.nextTriggerDate ?? DateTime(2100);
        return aDate.compareTo(bDate);
      });
  }

  Future<void> refreshAlerts() async {
    await refresh();
  }

  Future<void> refresh() async {
    _invalidateCache();
    final alerts = await getActiveAlerts(forceRefresh: true);
    _activeAlertsCache = alerts;
    if (!_controller.isClosed) {
      _controller.add(alerts);
    }
  }

  Future<void> markDone(String reminderId) async {
    final reminder = await databaseService.getAlertRecordById(reminderId);
    if (reminder == null) return;

    // 1. Update Source Module
    await _updateSourceEntity(reminder);

    // 2. Update Reminder Record
    if (reminder.recurrencePeriod != ReminderRecurrence.none &&
        reminder.dueDate != null) {
      // Roll forward for recurring
      final nextDate = _rollForward(
        reminder.dueDate!,
        reminder.recurrencePeriod,
      );
      await databaseService.updateAlertRecord(
        reminder.copyWith(
          dueDate: nextDate,
          lastTriggeredAt: DateTime.now(),
          snoozedUntil: null,
          recordStatus: ReminderRecordStatus.pending,
          nextTriggerAt: nextDate, // Initial trigger for next cycle
        ),
      );
    } else {
      await databaseService.updateAlertRecord(
        reminder.copyWith(
          recordStatus: ReminderRecordStatus.done,
          isActive: false,
          lastTriggeredAt: DateTime.now(),
          snoozedUntil: null,
        ),
      );
    }

    await refresh();
  }

  Future<void> snooze(String reminderId, Duration duration) async {
    final reminder = await databaseService.getAlertRecordById(reminderId);
    if (reminder == null) return;

    final snoozeUntil = DateTime.now().add(duration);
    await databaseService.updateAlertRecord(
      reminder.copyWith(
        snoozedUntil: snoozeUntil,
        nextTriggerAt: snoozeUntil,
        recordStatus: ReminderRecordStatus.snoozed,
      ),
    );
    await refresh();
  }

  Future<void> _updateSourceEntity(Reminder reminder) async {
    final sourceId = reminder.sourceId ?? reminder.linkedEntityId;
    if (sourceId == null) return;

    switch (reminder.sourceType) {
      case ReminderSourceType.salary:
        final paymentMap = await _salaryRepo.getPaymentById(sourceId);
        if (paymentMap != null) {
          await _salaryService.markFullyReceived(
            SalaryPayment.fromMap(paymentMap),
          );
        }
        break;
      case ReminderSourceType.loan:
        final installment = await _loanRepo.getInstallmentById(sourceId);
        if (installment != null) {
          await _loanRepo.updateInstallment(
            installment.copyWith(status: 'paid', paidDate: DateTime.now()),
          );
        }
        break;
      case ReminderSourceType.credit:
        final card = await _creditRepo.getCard(sourceId);
        if (card != null) {
          // Marking credit card due as "done" usually means the user acknowledged it.
          // In a more advanced version, we might trigger a payment transaction.
          // For now, we update the reminder status only, as credit cards are non-transactional here.
        }
        break;
      case ReminderSourceType.lending:
        final lending = await _lendingRepo.getById(sourceId);
        if (lending != null) {
          await _lendingRepo.update(
            lending.copyWith(isSettled: true, paidAmount: lending.originalAmount),
          );
        }
        break;
      case ReminderSourceType.vehicle:
        // Already handled via reminder status update if it was a VehicleReminder.
        // We might want to update the last_triggered_odometer if it's odo-based.
        break;
      case ReminderSourceType.manual:
        break;
    }
  }

  DateTime _rollForward(DateTime date, ReminderRecurrence recurrence) {
    switch (recurrence) {
      case ReminderRecurrence.weekly:
        return date.add(const Duration(days: 7));
      case ReminderRecurrence.monthly:
        return DateTime(date.year, date.month + 1, date.day);
      case ReminderRecurrence.yearly:
        return DateTime(date.year + 1, date.month, date.day);
      case ReminderRecurrence.none:
        return date;
    }
  }

  void dispose() {
    if (_listening) {
      databaseService.removeChangeListener(_handleSourceChanged);
      _listening = false;
    }
    _controller.close();
  }

  void _ensureListening() {
    if (_listening) return;
    _listening = true;
    databaseService.addChangeListener(_handleSourceChanged);
  }

  void _handleSourceChanged() {
    _invalidateCache();
    databaseService.invalidateAlertCache();
    unawaited(refresh());
  }

  AppAlert _mapReminderToAlert(Reminder reminder) {
    final status = reminder.isSnoozed
        ? AlertStatus.snoozed
        : reminder.status == ReminderStatus.inactive
        ? AlertStatus.done
        : AlertStatus.active;

    return AppAlert(
      id: reminder.id,
      type: alertTypeFromReminder(reminder),
      title: reminder.title,
      description: reminder.notes ?? 'Review this alert in SpendX.',
      status: status,
      triggerDate: reminder.dueDate,
      nextTriggerDate: reminder.snoozedUntil ?? reminder.dueDate,
      linkedEntityId: reminder.linkedEntityId,
      severity: alertSeverityFromReminder(reminder),
      amount: reminder.amount,
    );
  }



  void _invalidateCache() {
    _activeAlertsCache = null;
    _activeAlertsCachedAt = null;
  }
}
