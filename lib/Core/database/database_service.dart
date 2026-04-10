import 'package:flutter/foundation.dart';

import '../../data/repositories/reminder_repo.dart';
import '../../models/reminder_model.dart';
import '../../services/data_change_bus.dart';

class DatabaseService {
  DatabaseService({ReminderRepo? reminderRepo})
    : _reminderRepo = reminderRepo ?? ReminderRepo();

  final ReminderRepo _reminderRepo;
  static const Duration _alertCacheTtl = Duration(seconds: 20);

  List<Reminder>? _alertRecordsCache;
  DateTime? _alertRecordsCachedAt;

  bool get _hasFreshAlertCache =>
      _alertRecordsCache != null &&
      _alertRecordsCachedAt != null &&
      DateTime.now().difference(_alertRecordsCachedAt!) < _alertCacheTtl;

  Future<void> createAlertRecord(Reminder reminder) {
    _invalidateAlertCache();
    return _reminderRepo.insertGlobalReminder(reminder.toMap());
  }

  Future<void> updateAlertRecord(Reminder reminder) {
    _invalidateAlertCache();
    return _reminderRepo.update(reminder);
  }

  Future<List<Reminder>> getAlertRecords({bool forceRefresh = false}) async {
    if (!forceRefresh && _hasFreshAlertCache) {
      return List<Reminder>.from(_alertRecordsCache!);
    }

    final records = await _reminderRepo.getAll();
    _alertRecordsCache = List<Reminder>.from(records);
    _alertRecordsCachedAt = DateTime.now();
    return List<Reminder>.from(records);
  }

  Future<Reminder?> getAlertRecordById(
    String id, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _hasFreshAlertCache) {
      for (final reminder in _alertRecordsCache!) {
        if (reminder.id == id) return reminder;
      }
      return null;
    }
    return _reminderRepo.getById(id);
  }

  void addChangeListener(VoidCallback listener) {
    DataChangeBus.instance.addListener(listener);
  }

  void removeChangeListener(VoidCallback listener) {
    DataChangeBus.instance.removeListener(listener);
  }

  void invalidateAlertCache() {
    _invalidateAlertCache();
  }

  void _invalidateAlertCache() {
    _alertRecordsCache = null;
    _alertRecordsCachedAt = null;
  }
}
