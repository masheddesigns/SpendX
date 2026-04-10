import 'package:flutter/material.dart';
import '../../services/notification_settings_service.dart';
import '../../models/notification_settings.dart';
import '../../widgets/spendx_app_bar.dart';
import '../../services/notification_service_v2.dart';
import '../../services/reminder_service.dart';
import '../../widgets/custom_snackbar.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  final _service = NotificationSettingsService();
  NotificationSettings _settings = NotificationSettings();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await _service.load();
    setState(() {
      _settings = settings;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await _service.save(_settings);
    await NotificationServiceV2().refreshAllReminders();
    await ReminderService.instance.refreshDueReminders();
    if (mounted) {
      CustomSnackBar.show(context, message: 'Notification settings saved');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Notifications',
        actions: [IconButton(onPressed: _save, icon: const Icon(Icons.check))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionLabel('GLOBAL'),
          _card([
            ListTile(
              leading: Icon(
                Icons.access_time,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text(
                'Reminder Time',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              subtitle: const Text('All reminders use this by default'),
              trailing: Text(
                _settings.reminderTime,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onTap: _pickTime,
            ),
            const Divider(),
            ListTile(
              leading: Icon(
                Icons.music_note,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text(
                'Reminder Sound',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              trailing: Text(
                _settings.reminderSound[0].toUpperCase() +
                    _settings.reminderSound.substring(1),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onTap: _pickSound,
            ),
          ]),
          const SizedBox(height: 24),
          _sectionLabel('CRITICAL'),
          _card([
            _toggle(
              'Loan Due Reminder',
              'Alert 1 day before EMI',
              _settings.loanDue,
              (v) => setState(() => _settings = _settings.copyWith(loanDue: v)),
              Icons.receipt_long,
            ),
            const Divider(),
            _toggle(
              'Credit Card Reminder',
              'Alert 2 days before due',
              _settings.creditDue,
              (v) =>
                  setState(() => _settings = _settings.copyWith(creditDue: v)),
              Icons.credit_card,
            ),
            const Divider(),
            _toggle(
              'Salary Reminder',
              'Notify when salary is due today',
              _settings.salaryReminder,
              (v) => setState(
                () => _settings = _settings.copyWith(salaryReminder: v),
              ),
              Icons.payments_outlined,
            ),
            const Divider(),
            _toggle(
              'EMI Confirmation',
              'Notify on successful payment',
              _settings.emiPayment,
              (v) =>
                  setState(() => _settings = _settings.copyWith(emiPayment: v)),
              Icons.check_circle_outline,
            ),
          ]),
          const SizedBox(height: 24),
          _sectionLabel('SMART TRACKING'),
          _card([
            _toggle(
              'Expense Reminder',
              'Daily reminder to log expenses',
              _settings.expenseReminder,
              (v) => setState(
                () => _settings = _settings.copyWith(expenseReminder: v),
              ),
              Icons.notifications_active_outlined,
            ),
            const Divider(),
            _toggle(
              'Subscription Alerts',
              'Renewals and recurring charges',
              _settings.subscriptionAlerts,
              (v) => setState(
                () => _settings = _settings.copyWith(subscriptionAlerts: v),
              ),
              Icons.subscriptions_outlined,
            ),
            const Divider(),
            _toggle(
              'Budget Alerts',
              'Warn when you are close to limits',
              _settings.budgetAlerts,
              (v) => setState(
                () => _settings = _settings.copyWith(budgetAlerts: v),
              ),
              Icons.pie_chart_outline,
            ),
          ]),
          const SizedBox(height: 24),
          _sectionLabel('SYSTEM'),
          _card([
            _toggle(
              'Backup Notifications',
              'Status of manual and auto backups',
              _settings.backupStatus,
              (v) => setState(
                () => _settings = _settings.copyWith(backupStatus: v),
              ),
              Icons.cloud_upload_outlined,
            ),
            const Divider(),
            _toggle(
              'Auto Backup',
              'Background daily backup',
              _settings.autoBackup,
              (v) =>
                  setState(() => _settings = _settings.copyWith(autoBackup: v)),
              Icons.sync,
            ),
            const Divider(),
            _toggle(
              'General Updates',
              'Sync and general app status',
              _settings.generalUpdates,
              (v) => setState(
                () => _settings = _settings.copyWith(generalUpdates: v),
              ),
              Icons.info_outline,
            ),
          ]),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => NotificationServiceV2().showInstant(
                title: 'Test Notification 🔔',
                body: 'This is a test notification from SpendX.',
              ),
              icon: const Icon(Icons.send_rounded, size: 18),
              label: const Text('Send Test Notification'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickTime() async {
    final parts = _settings.reminderTime.split(':');
    final initialTime = TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 9,
      minute: int.tryParse(parts[1]) ?? 0,
    );

    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
    );

    if (picked != null) {
      final timeStr =
          '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      setState(() => _settings = _settings.copyWith(reminderTime: timeStr));
      await _service.save(_settings);
      await NotificationServiceV2().refreshAllReminders();
      await ReminderService.instance.refreshDueReminders();
    }
  }

  Future<void> _pickSound() async {
    final sounds = [
      {
        'id': 'default',
        'name': 'System Default',
        'desc': 'Your device\'s default tone',
        'emoji': '🔔',
      },
      {
        'id': 'elegant',
        'name': 'Elegant',
        'desc': 'Soft chime, pleasant & calm',
        'emoji': '🎵',
      },
      {
        'id': 'bright',
        'name': 'Bright',
        'desc': 'Uplifting, energetic ping',
        'emoji': '✨',
      },
      {
        'id': 'nature',
        'name': 'Nature',
        'desc': 'Gentle, relaxing ambient tone',
        'emoji': '🌿',
      },
      {
        'id': 'digital',
        'name': 'Digital',
        'desc': 'Clean, modern notification',
        'emoji': '💡',
      },
    ];

    final cs = Theme.of(context).colorScheme;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'Notification Sound',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        contentPadding: const EdgeInsets.only(top: 12, bottom: 4),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: sounds.map((s) {
              final isSelected = _settings.reminderSound == s['id'];
              return ListTile(
                leading: Text(
                  s['emoji']!,
                  style: const TextStyle(fontSize: 24),
                ),
                title: Text(
                  s['name']!,
                  style: TextStyle(
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isSelected ? cs.primary : null,
                  ),
                ),
                subtitle: Text(
                  s['desc']!,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: isSelected
                    ? Icon(Icons.check_circle, color: cs.primary)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                tileColor: isSelected
                    ? cs.primaryContainer.withValues(alpha: 0.3)
                    : null,
                onTap: () => Navigator.pop(context, s['id']),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (picked != null) {
      setState(() => _settings = _settings.copyWith(reminderSound: picked));
      await _service.save(_settings);
      await NotificationServiceV2().refreshAllReminders();
      await ReminderService.instance.refreshDueReminders();
      if (mounted) {
        CustomSnackBar.show(
          context,
          message:
              '🎵 Sound saved: ${sounds.firstWhere((s) => s['id'] == picked)['name']}',
        );
      }
    }
  }

  Widget _sectionLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Text(
      label,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.1,
      ),
    ),
  );

  Widget _card(List<Widget> children) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(children: children),
  );

  Widget _toggle(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
    IconData icon,
  ) => SwitchListTile(
    secondary: Icon(icon, color: Theme.of(context).colorScheme.primary),
    title: Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
    ),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
    value: value,
    onChanged: onChanged,
  );
}
