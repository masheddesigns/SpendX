import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../services/notification_settings_service.dart';
import '../../services/live_sms_service.dart';
import '../../services/settings_service.dart';
import '../../services/gmail_integration_service.dart';
import '../../models/notification_settings.dart';
import '../../widgets/spendx_app_bar.dart';
import '../../services/notification_service_v2.dart';
import '../../services/reminder_service.dart';

import '../../widgets/custom_snackbar.dart';
import '../../shared/widgets/app_page_route.dart';
import 'automatic_ingestion_screen.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen>
    with WidgetsBindingObserver {
  final _service = NotificationSettingsService();
  NotificationSettings _settings = NotificationSettings();
  bool _loading = true;
  bool _liveSmsEnabled = true;
  bool _notifListenerEnabled = false;
  bool _whatsappEnabled = false;
  bool _gmailPreviewEnabled = false;
  bool _exactAlarmEnabled = true;
  bool _batteryOptimizationIgnored = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadSettings();
    }
  }

  Future<void> _loadSettings() async {
    final settings = await _service.load();
    final liveSms = await LiveSmsService.instance.enabled;
    final notifListener = await LiveSmsService.instance.isNotificationListenerEnabled();
    final exactAlarm = await NotificationServiceV2().canScheduleExactAlarms();
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    final waEnabled = SettingsService.instance.whatsappIngestionEnabled;
    final gmEnabled = SettingsService.instance.gmailPreviewEnabled;
    await GmailIntegrationService.instance.init();

    if (!mounted) return;
    setState(() {
      _settings = settings;
      _liveSmsEnabled = liveSms;
      _notifListenerEnabled = notifListener;
      _whatsappEnabled = waEnabled;
      _gmailPreviewEnabled = gmEnabled;
      _exactAlarmEnabled = exactAlarm;
      _batteryOptimizationIgnored = battery;
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
        actions: [IconButton(
          tooltip: 'Save',onPressed: _save, icon: const Icon(Icons.check))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF6366F1).withValues(alpha: 0.15),
                  const Color(0xFF6366F1).withValues(alpha: 0.05),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF6366F1).withValues(alpha: 0.35),
              ),
            ),
            child: InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  AppPageRoute(
                    builder: (_) => const AutomaticIngestionScreen(),
                  ),
                ).then((_) => _loadSettings());
              },
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.bolt_rounded,
                      color: Color(0xFF6366F1),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Automatic Ingestion Hub',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Real-time bank SMS, UPI app notifications & ledger sync',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFF6366F1),
                  ),
                ],
              ),
            ),
          ),
          if (!_exactAlarmEnabled) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.error.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Exact Alarms Disabled',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Reminders will be delivered using inexact alarms and may be slightly delayed. Tap to allow exact alarms in system settings.',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.onErrorContainer.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await NotificationServiceV2().requestExactAlarmsPermission();
                      final updated = await NotificationServiceV2().canScheduleExactAlarms();
                      setState(() => _exactAlarmEnabled = updated);
                    },
                    child: const Text('Enable'),
                  ),
                ],
              ),
            ),
          ],
          if (!_batteryOptimizationIgnored) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF8B5CF6).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.battery_alert_rounded,
                    color: Color(0xFF8B5CF6),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Background Battery Restricted',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'OEM battery savers may terminate live UPI listeners when locked. Allow unrestricted background battery for reliable alerts.',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await Permission.ignoreBatteryOptimizations.request();
                      final updated = await Permission.ignoreBatteryOptimizations.isGranted;
                      if (mounted) setState(() => _batteryOptimizationIgnored = updated);
                    },
                    child: const Text('Unrestrict'),
                  ),
                ],
              ),
            ),
          ],

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
            const Divider(),
            SwitchListTile(
              secondary: Icon(
                Icons.sms_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text(
                'Live SMS Detection',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              subtitle: const Text(
                'Detect new bank SMS as they arrive and suggest transactions '
                'or balance updates',
                style: TextStyle(fontSize: 12),
              ),
              value: _liveSmsEnabled,
              onChanged: (v) async {
                setState(() => _liveSmsEnabled = v);
                await LiveSmsService.instance.setEnabled(v);
                if (v) {
                  await LiveSmsService.instance.requestReceivePermission();
                }
              },
            ),
            const Divider(),
            SwitchListTile(
              secondary: Icon(
                Icons.notifications_active_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text(
                'Bank App Notifications',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              subtitle: const Text(
                'Transaction alerts only from allowlisted banking, UPI, and credit card apps. '
                'Processed on-device.',
                style: TextStyle(fontSize: 12),
              ),
              value: _notifListenerEnabled,
              onChanged: (v) async {
                await LiveSmsService.instance.openNotificationListenerSettings();
                final enabled = await LiveSmsService.instance.isNotificationListenerEnabled();
                setState(() => _notifListenerEnabled = enabled);
              },
            ),
            const Divider(),
            SwitchListTile(
              secondary: Icon(
                Icons.chat_bubble_outline_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text(
                'WhatsApp Banking Alerts',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              subtitle: const Text(
                'Extract transactions only from verified bank bots (e.g. HDFC, ICICI, SBI) '
                'and enabled financial contacts. Personal chats are strictly excluded.',
                style: TextStyle(fontSize: 12),
              ),
              value: _whatsappEnabled,
              onChanged: (v) async {
                if (v) {
                  final consent = await _showWhatsAppPrivacyConsentDialog();
                  if (!consent) return;
                }
                setState(() => _whatsappEnabled = v);
                await SettingsService.instance.setWhatsAppIngestionEnabled(v);
              },
            ),
            if (_whatsappEnabled) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.tune_rounded, size: 16),
                      label: const Text('Manage Financial Contacts', style: TextStyle(fontSize: 12)),
                      onPressed: _showWhatsAppContactsSheet,
                    ),
                  ],
                ),
              ),
            ],
            const Divider(),
            SwitchListTile(
              secondary: Icon(
                Icons.mark_email_unread_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text(
                'Gmail Transaction Alerts',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              subtitle: const Text(
                'Preview fallback for official bank e-statements and card alerts. '
                'Personal emails are strictly excluded.',
                style: TextStyle(fontSize: 12),
              ),
              value: _gmailPreviewEnabled,
              onChanged: (v) async {
                setState(() => _gmailPreviewEnabled = v);
                await SettingsService.instance.setGmailPreviewEnabled(v);
              },
            ),
            const Divider(),
            ListTile(
              leading: Icon(
                Icons.email_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text(
                'Connect Read-Only Email',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                GmailIntegrationService.instance.isConnected
                    ? 'Connected: ${GmailIntegrationService.instance.connectedEmail}'
                    : 'Authorize read-only sync for bank statements, card bills, and refunds.',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: TextButton(
                onPressed: () async {
                  if (GmailIntegrationService.instance.isConnected) {
                    await GmailIntegrationService.instance.disconnect();
                  } else {
                    await GmailIntegrationService.instance.connect();
                  }
                  setState(() {});
                },
                child: Text(
                  GmailIntegrationService.instance.isConnected ? 'Disconnect' : 'Connect',
                  style: TextStyle(
                    color: GmailIntegrationService.instance.isConnected
                        ? Colors.red
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 24),
          _sectionLabel('SYSTEM'),
          _card([
            ListTile(
              leading: Icon(
                Icons.alarm,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text(
                'Exact Alarm Permission',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                _exactAlarmEnabled
                    ? 'Granted — precise reminder delivery'
                    : 'Denied/revoked — inexact fallback active',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: _exactAlarmEnabled
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : TextButton(
                      onPressed: () async {
                        await NotificationServiceV2().requestExactAlarmsPermission();
                        final updated = await NotificationServiceV2().canScheduleExactAlarms();
                        setState(() => _exactAlarmEnabled = updated);
                      },
                      child: const Text('Fix'),
                    ),
            ),
            const Divider(),
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

  Future<bool> _showWhatsAppPrivacyConsentDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.security_rounded, color: Colors.green),
            SizedBox(width: 8),
            Text('Privacy Guarantee', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'SpendX strictly protects your privacy:\n\n'
          '• Only incoming messages from official banking bots (e.g. HDFC, ICICI, SBI) '
          'and financial contacts you enable are inspected.\n'
          '• Personal conversations, family chats, and group messages are never inspected, '
          'parsed, or stored.\n'
          '• All parsing occurs 100% on-device.\n\n'
          'Do you want to enable WhatsApp banking alerts?',
          style: TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Agree & Enable'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showWhatsAppContactsSheet() {
    final senders = List<String>.from(SettingsService.instance.whatsappAllowedSenders);
    final textController = TextEditingController();
    final contactFormKey = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            top: 20,
            left: 20,
            right: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.verified_user_outlined, color: Colors.green),
                  const SizedBox(width: 8),
                  const Text(
                    'Allowed Financial Contacts',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Only notifications from contacts matching these names will be inspected for transactions.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Form(
                      key: contactFormKey,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      child: TextFormField(
                        controller: textController,
                        decoration: const InputDecoration(
                          hintText: 'Add bank name or contact (e.g. HDFC)',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final contact = (value ?? '').trim();
                          if (contact.isEmpty) return 'Enter a contact name';
                          if (senders.any(
                            (sender) => sender.toLowerCase() == contact.toLowerCase(),
                          )) {
                            return 'This contact is already allowed';
                          }
                          return null;
                        },
                        onChanged: (_) => setSheetState(() {}),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      if (!(contactFormKey.currentState?.validate() ?? false)) {
                        return;
                      }
                      final text = textController.text.trim();
                      setSheetState(() => senders.add(text));
                      textController.clear();
                      await SettingsService.instance.setWhatsAppAllowedSenders(senders);
                    },
                    child: const Text('Add'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SizedBox(
                  height: 250,
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: senders.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final item = senders[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.account_balance, size: 20),
                        title: Text(item, style: const TextStyle(fontSize: 14)),
                        trailing: IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () async {
                            setSheetState(() => senders.removeAt(index));
                            await SettingsService.instance.setWhatsAppAllowedSenders(senders);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
