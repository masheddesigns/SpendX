import 'package:flutter/material.dart';
import '../widgets/spendx_app_bar.dart';


class NotificationHelpScreen extends StatelessWidget {
  const NotificationHelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Notification Help',
      ),

      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context, 'Vivo / Oppo / Xiaomi Devices', Icons.phonelink_setup),
            const SizedBox(height: 16),
            const Text(
              'Some devices have aggressive battery optimizations that may block SpendX notifications. Please follow these steps to ensure reliable alerts:',
              style: TextStyle(fontSize: 15, height: 1.5),
            ),
            const SizedBox(height: 24),
            
            _buildStep(context, '1', 'Enable Auto-start', 
              'Go to Settings → App Manager → Autostart → Enable "SpendX".'),
            
            _buildStep(context, '2', 'Disable Battery Optimization', 
              'Go to Settings → Battery → High Background Power Consumption → Enable "SpendX" OR Settings → Apps → SpendX → Battery → Don\'t Optimize.'),
            
            _buildStep(context, '3', 'Lock SpendX in Recents', 
              'Open the Recent Apps screen, find SpendX, and swipe down on the app card to lock it (a lock icon will appear).'),
              
            _buildStep(context, '4', 'Allow Notifications on Lock Screen', 
              'Go to Settings → Status bar & Notification → Manage Notification → SpendX → Allow all notifications.'),

            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'If you still don\'t receive notifications, try restarting your device after making these changes.',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildStep(BuildContext context, String number, String title, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              number,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
