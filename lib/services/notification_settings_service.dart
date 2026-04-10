import 'package:shared_preferences/shared_preferences.dart';
import '../models/notification_settings.dart';

class NotificationSettingsService {
  static const String _keyPrefix = 'notif_';

  Future<void> save(NotificationSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    final map = settings.toMap();
    for (var entry in map.entries) {
      if (entry.value is bool) {
        await prefs.setBool('$_keyPrefix${entry.key}', entry.value);
      } else if (entry.value is String) {
        await prefs.setString('$_keyPrefix${entry.key}', entry.value);
      }
    }
  }

  Future<NotificationSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return NotificationSettings(
      loanDue: prefs.getBool('${_keyPrefix}loanDue') ?? true,
      creditDue: prefs.getBool('${_keyPrefix}creditDue') ?? true,
      salaryReminder: prefs.getBool('${_keyPrefix}salaryReminder') ?? true,
      emiPayment: prefs.getBool('${_keyPrefix}emiPayment') ?? true,
      subscriptionAlerts:
          prefs.getBool('${_keyPrefix}subscriptionAlerts') ?? true,
      budgetAlerts: prefs.getBool('${_keyPrefix}budgetAlerts') ?? true,
      backupStatus: prefs.getBool('${_keyPrefix}backupStatus') ?? true,
      autoBackup: prefs.getBool('${_keyPrefix}autoBackup') ?? true,
      expenseReminder: prefs.getBool('${_keyPrefix}expenseReminder') ?? false,
      generalUpdates: prefs.getBool('${_keyPrefix}generalUpdates') ?? true,
      reminderTime: prefs.getString('${_keyPrefix}reminderTime') ?? '09:00',
      reminderSound: prefs.getString('${_keyPrefix}reminderSound') ?? 'default',
    );
  }
}
