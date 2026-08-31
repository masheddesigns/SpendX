import 'package:flutter/material.dart';

import '../core/database/database_service.dart';
import '../features/alerts/data/alert_service.dart';
import '../features/alerts/data/app_alert.dart';
import '../features/salary/screens/salary_screen.dart';
import '../screens/credit_card_screen.dart';
import '../screens/lending/lending_screen.dart';
import '../screens/loans/loans_screen.dart';
import '../screens/recurring/recurring_payments_screen.dart';
import '../shared/widgets/app_page_route.dart';
import '../shared/widgets/skeleton_loader.dart';
import '../shared/widgets/empty_state_widget.dart';
import '../utils/app_format.dart';

/// In-app notifications inbox: lists active (pending) reminders and routes
/// taps to the relevant screen.
class NotificationsInboxScreen extends StatefulWidget {
  const NotificationsInboxScreen({super.key});

  @override
  State<NotificationsInboxScreen> createState() =>
      _NotificationsInboxScreenState();
}

class _NotificationsInboxScreenState extends State<NotificationsInboxScreen> {
  bool _isLoading = true;
  List<AppAlert> _alerts = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final service = AlertService(databaseService: DatabaseService());
    final alerts = await service.getActiveAlerts(forceRefresh: true);
    if (!mounted) return;
    setState(() {
      _alerts = alerts;
      _isLoading = false;
    });
  }

  void _open(AppAlert alert) {
    final Widget? screen = switch (alert.type) {
      AlertType.salaryDue ||
      AlertType.salaryDelayed ||
      AlertType.partialSalary => const SalaryScreen(),
      AlertType.loanDue => const LoansScreen(),
      AlertType.creditCardDue => const CreditCardScreen(),
      AlertType.subscriptionDue => const RecurringPaymentsScreen(),
      AlertType.custom => const LendingScreen(),
      AlertType.vehicleService => null,
    };

    if (screen == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vehicle reminders are paused for now.')),
      );
      return;
    }

    Navigator.of(
      context,
    ).push(AppPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _isLoading
          ? const SkeletonLoader.transactions()
          : _alerts.isEmpty
          ? const EmptyStateWidget(
              icon: Icons.notifications_off_outlined,
              title: 'No alerts right now',
              description:
                  'You\'re all caught up. Alerts will appear here when actions are needed.',
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemBuilder: (context, index) {
                  final alert = _alerts[index];
                  final icon = switch (alert.type) {
                    AlertType.salaryDue ||
                    AlertType.salaryDelayed ||
                    AlertType.partialSalary => Icons.work_rounded,
                    AlertType.loanDue => Icons.account_balance_rounded,
                    AlertType.creditCardDue => Icons.credit_card_rounded,
                    AlertType.subscriptionDue => Icons.subscriptions_rounded,
                    AlertType.vehicleService => Icons.directions_car_rounded,
                    AlertType.custom => Icons.handshake_rounded,
                  };
                  final color = alert.severity == AlertSeverity.critical
                      ? cs.error
                      : alert.severity == AlertSeverity.warning
                      ? Colors.orange
                      : cs.primary;

                  final dueLabel = alert.triggerDate != null
                      ? '• ${AppFormat.date(alert.triggerDate!)}'
                      : '';

                  return Card(
                    child: ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(icon, color: color, size: 22),
                      ),
                      title: Text(alert.title),
                      subtitle: Text(
                        '${alert.description} $dueLabel',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                      onTap: () => _open(alert),
                    ),
                  );
                },
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemCount: _alerts.length,
              ),
            ),
    );
  }
}