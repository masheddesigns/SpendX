import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_help_screen.dart';
import '../../services/notification_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/custom_snackbar.dart';
import '../../services/settings_service.dart';
import 'package:spend_x/widgets/spendx_app_bar.dart';


class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  bool _enabled = true;
  int _daysBefore = 3;

  // Toggles
  bool _dailySummary = false;
  bool _weeklySummary = true;
  bool _monthlySummary = true;
  bool _ccReminders = true;
  bool _emiReminders = true;
  bool _lendingReminders = true;
  bool _netWorthReminder = true;

  // Times
  TimeOfDay _dailyTime = const TimeOfDay(hour: 20, minute: 0);
  TimeOfDay _weeklyTime = const TimeOfDay(hour: 20, minute: 0);
  TimeOfDay _monthlyTime = const TimeOfDay(hour: 20, minute: 0);
  TimeOfDay _ccTime = const TimeOfDay(hour: 10, minute: 0);
  TimeOfDay _emiTime = const TimeOfDay(hour: 10, minute: 0);
  TimeOfDay _lendingTime = const TimeOfDay(hour: 10, minute: 0);
  TimeOfDay _netWorthTime = const TimeOfDay(hour: 10, minute: 0);

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final enabled = await NotificationService.instance.notificationsEnabled;
    final days = await NotificationService.instance.daysBefore;
    final prefs = await SharedPreferences.getInstance();
    
    TimeOfDay loadTime(String key, int defHour, int defMin) {
      final hm = prefs.getString(key);
      if (hm == null) return TimeOfDay(hour: defHour, minute: defMin);
      final parts = hm.split(':');
      if (parts.length != 2) return TimeOfDay(hour: defHour, minute: defMin);
      return TimeOfDay(hour: int.tryParse(parts[0]) ?? defHour, minute: int.tryParse(parts[1]) ?? defMin);
    }

    if (mounted) {
      setState(() {
        _enabled = enabled;
        _daysBefore = days;
        
        _dailySummary = prefs.getBool('pref_daily') ?? false;
        _weeklySummary = prefs.getBool('pref_weekly') ?? true;
        _monthlySummary = prefs.getBool('pref_monthly') ?? true;
        _ccReminders = prefs.getBool('pref_cc') ?? true;
        _emiReminders = prefs.getBool('pref_emi') ?? true;
        _lendingReminders = prefs.getBool('pref_lending') ?? true;
        _netWorthReminder = prefs.getBool('pref_networth') ?? true;

        _dailyTime = loadTime('time_daily', 20, 0);
        _weeklyTime = loadTime('time_weekly', 20, 0);
        _monthlyTime = loadTime('time_monthly', 20, 0);
        _ccTime = loadTime('time_cc', 10, 0);
        _emiTime = loadTime('time_emi', 10, 0);
        _lendingTime = loadTime('time_lending', 10, 0);
        _netWorthTime = loadTime('time_networth', 10, 0);
      });
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pref_daily', _dailySummary);
    await prefs.setBool('pref_weekly', _weeklySummary);
    await prefs.setBool('pref_monthly', _monthlySummary);
    await prefs.setBool('pref_cc', _ccReminders);
    await prefs.setBool('pref_emi', _emiReminders);
    await prefs.setBool('pref_lending', _lendingReminders);
    await prefs.setBool('pref_networth', _netWorthReminder);

    await prefs.setString('time_daily', '${_dailyTime.hour}:${_dailyTime.minute}');
    await prefs.setString('time_weekly', '${_weeklyTime.hour}:${_weeklyTime.minute}');
    await prefs.setString('time_monthly', '${_monthlyTime.hour}:${_monthlyTime.minute}');
    await prefs.setString('time_cc', '${_ccTime.hour}:${_ccTime.minute}');
    await prefs.setString('time_emi', '${_emiTime.hour}:${_emiTime.minute}');
    await prefs.setString('time_lending', '${_lendingTime.hour}:${_lendingTime.minute}');
    await prefs.setString('time_networth', '${_netWorthTime.hour}:${_netWorthTime.minute}');

    await NotificationService.instance.setNotificationsEnabled(_enabled);
    await NotificationService.instance.setDaysBefore(_daysBefore);

    if (_enabled) {
      await NotificationService.instance.requestPermissions();
      await _scheduleSummaryNotifications();
      
      // Update Net Worth Reminder via Service
      if (_netWorthReminder) {
        await NotificationService.instance.scheduleWeeklyNetWorthReminder(
          hour: _netWorthTime.hour, 
          minute: _netWorthTime.minute
        );
      } else {
        await NotificationService.instance.cancel(1001); // netWorthReminderId
      }
    }

    if (mounted) {
      CustomSnackBar.show(context, message: 'Notification settings saved');
    }
  }

  Future<void> _scheduleSummaryNotifications() async {
    // Note: This schedules basic non-repeating summary notifications based on UI.
    // In a fully featured app these would be repeating zonedSchedules or WorkManager tasks.
    await NotificationService.instance.cancel(100);
    await NotificationService.instance.cancel(101);
    await NotificationService.instance.cancel(102);
    
    final now = DateTime.now();

    if (_dailySummary) {
      final daily = DateTime(now.year, now.month, now.day, _dailyTime.hour, _dailyTime.minute);
      final scheduledDaily = daily.isAfter(now) ? daily : daily.add(const Duration(days: 1));
      await NotificationService.instance.scheduleNotification(
        id: 100, title: '📊 Daily SpendX Summary', body: 'Check your spending & budget progress for today!', scheduledDate: scheduledDaily,
      );
    }
    if (_weeklySummary) {
      final daysUntilMonday = (DateTime.monday - now.weekday + 7) % 7;
      final nextMonday = now.add(Duration(days: daysUntilMonday == 0 ? 7 : daysUntilMonday));
      final weekly = DateTime(nextMonday.year, nextMonday.month, nextMonday.day, _weeklyTime.hour, _weeklyTime.minute);
      await NotificationService.instance.scheduleNotification(
        id: 101, title: '📈 Weekly Finance Summary', body: 'Your weekly spending report is ready in SpendX!', scheduledDate: weekly,
      );
    }
    if (_monthlySummary) {
      final firstNextMonth = DateTime(now.year, now.month + 1, 1, _monthlyTime.hour, _monthlyTime.minute);
      await NotificationService.instance.scheduleNotification(
        id: 102, title: '🗓 Monthly SpendX Report', body: 'See your expenses, savings & net worth!', scheduledDate: firstNextMonth,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Notifications',
        showLogo: false,

        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationHelpScreen()),
            ),
            icon: const Icon(Icons.help_outline),
            tooltip: 'Notification Help',
          ),
          IconButton(
            onPressed: _save,
            icon: const Icon(Icons.check),
            tooltip: 'Save',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _card([
              _toggle('Enable Notifications', 'Allow SpendX to send reminders', _enabled, (v) => setState(() => _enabled = v)),
            ]),
            const SizedBox(height: 20),

            if (_enabled) ...[
              _sectionLabel('SUMMARY REPORTS'),
              _card([
                _toggle(
                  'Daily Summary', 
                  'A daily spending recap', 
                  _dailySummary, 
                  (v) => setState(() => _dailySummary = v),
                  icon: Icons.today,
                  color: Theme.of(context).colorScheme.primary,
                ),
                if (_dailySummary) _timePickerRow('Daily Time', _dailyTime, (t) => setState(() => _dailyTime = t)),
                Divider(color: Theme.of(context).colorScheme.outlineVariant),
                
                _toggle(
                  'Weekly Summary', 
                  'Every Monday week overview', 
                  _weeklySummary, 
                  (v) => setState(() => _weeklySummary = v),
                  icon: Icons.calendar_view_week,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                if (_weeklySummary) _timePickerRow('Weekly Time', _weeklyTime, (t) => setState(() => _weeklyTime = t)),
                Divider(color: Theme.of(context).colorScheme.outlineVariant),
                
                _toggle(
                  'Monthly Summary', 
                  '1st of each month report', 
                  _monthlySummary, 
                  (v) => setState(() => _monthlySummary = v),
                  icon: Icons.assessment,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
                if (_monthlySummary) _timePickerRow('Monthly Time', _monthlyTime, (t) => setState(() => _monthlyTime = t)),
              ]),
              const SizedBox(height: 20),

              _sectionLabel('ALERTS & DUE DATES'),
              _card([
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Alert $_daysBefore days before due', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
                    Slider(
                      value: _daysBefore.toDouble(), min: 1, max: 7, divisions: 6,
                      label: '$_daysBefore days', activeColor: Theme.of(context).colorScheme.primary,
                      onChanged: (v) => setState(() => _daysBefore = v.round()),
                    ),
                  ]),
                ),
                Divider(color: Theme.of(context).colorScheme.outlineVariant),
                _toggle(
                  'Credit Card Alerts', 
                  'Alert before payment due', 
                  _ccReminders, 
                  (v) => setState(() => _ccReminders = v),
                  icon: Icons.credit_card,
                  color: Theme.of(context).colorScheme.primary,
                ),
                if (_ccReminders) _timePickerRow('Reminder Time', _ccTime, (t) => setState(() => _ccTime = t)),
                Divider(color: Theme.of(context).colorScheme.outlineVariant),
                
                _toggle(
                  'EMI Reminders', 
                  'Monthly instalment alerts', 
                  _emiReminders, 
                  (v) => setState(() => _emiReminders = v),
                  icon: Icons.receipt_long,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                if (_emiReminders) _timePickerRow('Reminder Time', _emiTime, (t) => setState(() => _emiTime = t)),
                Divider(color: Theme.of(context).colorScheme.outlineVariant),
                
                _toggle(
                  'Lending Reminders', 
                  'Overdue lend/borrow alerts', 
                  _lendingReminders, 
                  (v) => setState(() => _lendingReminders = v),
                  icon: Icons.handshake,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
                if (_lendingReminders) _timePickerRow('Reminder Time', _lendingTime, (t) => setState(() => _lendingTime = t)),
              ]),
              const SizedBox(height: 20),

              _sectionLabel('GOALS & TRACKING'),
              _card([
                _toggle(
                  'Net Worth Reminder', 
                  'Weekly update reminder (Sundays)', 
                  _netWorthReminder, 
                  (v) => setState(() => _netWorthReminder = v),
                  icon: Icons.account_balance,
                  color: Theme.of(context).colorScheme.primary,
                ),
                if (_netWorthReminder) _timePickerRow('Reminder Time', _netWorthTime, (t) => setState(() => _netWorthTime = t)),
              ]),
              const SizedBox(height: 20),

              _sectionLabel('SOUND SETTINGS'),
              _card([
                _soundPickerTile(context),
              ]),
              const SizedBox(height: 20),

              OutlinedButton.icon(
                onPressed: () async {
                  await NotificationService.instance.requestPermissions();
                  await NotificationService.instance.showInstant(
                    id: 999, title: '🔔 SpendX Test', body: 'Notifications are working! Your settings are saved.',
                  );
                },
                icon: const Icon(Icons.notifications),
                label: const Text('Send Test Notification'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary, 
                  side: BorderSide(color: Theme.of(context).colorScheme.primary),
                  minimumSize: const Size.fromHeight(50),
                ),
              ),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 10, left: 4),
    child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2)),
  );

  Widget _card(List<Widget> children) => Container(
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(children: children),
  );

  Widget _toggle(String title, String subtitle, bool value, ValueChanged<bool> onChanged, {IconData? icon, Color? color}) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    secondary: icon != null ? Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: (color ?? Theme.of(context).colorScheme.primary).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color ?? Theme.of(context).colorScheme.primary, size: 22),
    ) : null,
    title: Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14, fontWeight: FontWeight.w500)),
    subtitle: Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
    value: value,
    onChanged: onChanged,
    activeColor: Theme.of(context).colorScheme.onPrimary,
    activeTrackColor: (color ?? Theme.of(context).colorScheme.primary).withValues(alpha: 0.8),
  );

  Widget _timePickerRow(String title, TimeOfDay time, ValueChanged<TimeOfDay> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0, left: 16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          TextButton(
            onPressed: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: time,
                builder: (context, child) {
                  return Theme(
                    data: Theme.of(context).copyWith(
                      colorScheme: Theme.of(context).colorScheme.copyWith(
                        primary: Theme.of(context).colorScheme.primary,
                        onSurface: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    child: child!,
                  );
                },
              );
              if (picked != null) onChanged(picked);
            },
            style: TextButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(
              time.format(context),
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _soundPickerTile(BuildContext context) {
    final settings = SettingsService.instance;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.music_note, color: Theme.of(context).colorScheme.primary, size: 22),
      ),
      title: const Text('Reminder Sound', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(settings.reminderSound, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => _showSoundPicker(context),
    );
  }

  void _showSoundPicker(BuildContext context) {
    final sounds = ['Default', 'Soft Chime', 'Calendar Ping', 'Bell Reminder'];
    final settings = SettingsService.instance;
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 20),
          const Text('Select Reminder Sound', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          ...sounds.map((s) => RadioListTile<String>(
            title: Text(s),
            value: s,
            groupValue: s == 'Default' ? 'default' : settings.reminderSound, // Fix mapping
            onChanged: (v) async {
              final val = v == 'Default' ? 'default' : v!;
              await settings.setReminderSound(val);
              await NotificationService.instance.updateNotificationSounds();
              if (mounted) {
                setState(() {});
                Navigator.pop(context);
              }
            },
          )),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}
