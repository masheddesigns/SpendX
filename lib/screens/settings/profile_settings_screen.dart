import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../services/settings_service.dart';

// AppTheme import removed

import '../../services/export_service.dart';
import 'budget_management_screen.dart';
import 'category_management_screen.dart';
import 'data_management_screen.dart';
import 'notification_settings_screen.dart';
import 'tag_management_screen.dart';
import 'vehicle_management_screen.dart';
import '../recurring/recurring_payments_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../widgets/spendx_app_bar.dart';


class ProfileSettingsScreen extends StatelessWidget {
  const ProfileSettingsScreen({super.key});

  String _getThemeName(BuildContext context) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final theme = AppTheme.availableThemes.firstWhere((t) => t['id'] == settings.themeVariant, orElse: () => AppTheme.availableThemes.first);
    return theme['name'] as String;
  }

  void _showThemePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Consumer<SettingsService>(
        builder: (ctx, settings, _) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('Choose Theme', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 16),
              ...AppTheme.availableThemes.map((theme) {
                final isSelected = settings.themeVariant == theme['id'];
                return ListTile(
                  leading: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: theme['color'] as Color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  title: Text(theme['name'] as String, style: TextStyle(fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
                  trailing: isSelected ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary) : null,
                  onTap: () {
                    settings.setThemeVariant(theme['id'] as String);
                    Navigator.pop(ctx);
                  },
                );
              }),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SpendXAppBar(),

      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Text(
                'Profile & Settings',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(
            child: _ProfileHeader(),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              const _SectionHeader('Finance Setup'),
              _SettingsTile(
                icon: Icons.repeat,
                iconColor: Theme.of(context).colorScheme.tertiary,
                title: 'Recurring Payments',
                subtitle: 'Rent, subscriptions, salary templates',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RecurringPaymentsScreen()),
                ),
              ),
              _SettingsTile(
                icon: Icons.data_usage_outlined,
                iconColor: Theme.of(context).colorScheme.primary, // Placeholder color
                title: 'Data Management',
                subtitle: 'CSV imports, Cleanup',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DataManagementScreen())),
              ),
              _SettingsTile(
                icon: Icons.notifications_none,
                iconColor: Theme.of(context).colorScheme.secondary, // Placeholder color
                title: 'Notifications',
                subtitle: 'Daily reminders, Alerts',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NotificationSettingsScreen())),
              ),
              _SettingsTile(
                icon: Icons.two_wheeler,
                iconColor: Theme.of(context).colorScheme.primary,
                title: 'Manage Vehicles',
                subtitle: 'Add or remove vehicles',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const VehicleManagementScreen()),
                ),
              ),
              _SettingsTile(
                icon: Icons.account_balance_wallet_rounded,
                iconColor: Theme.of(context).colorScheme.secondary,
                title: 'Budgets',
                subtitle: 'Set monthly spending limits per category',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BudgetManagementScreen()),
                ),
              ),
              _SettingsTile(
                icon: Icons.category_outlined,
                iconColor: Theme.of(context).colorScheme.primary,
                title: 'Categories',
                subtitle: 'Manage income & expense categories',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CategoryManagementScreen()),
                ),
              ),
              _SettingsTile(
                icon: Icons.label_outline,
                iconColor: Theme.of(context).colorScheme.secondary,
                title: 'Tags',
                subtitle: 'Manage transaction tags',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const TagManagementScreen()),
                ),
              ),
              const Divider(height: 32),
              const _SectionHeader('Data Management'),
              _SettingsTile(
                icon: Icons.table_view_outlined,
                iconColor: Theme.of(context).colorScheme.primary,
                title: 'Export as CSV',
                subtitle: 'Share your transactions as a spreadsheet',
                onTap: () => ExportService.instance.exportTransactionsToCsv(),
              ),
              _SettingsTile(
                icon: Icons.data_object_outlined,
                iconColor: Theme.of(context).colorScheme.secondary,
                title: 'Export as JSON',
                subtitle: 'Share your transactions as JSON data',
                onTap: () => ExportService.instance.exportTransactionsToJson(),
              ),
              const Divider(height: 32),
              const _SectionHeader('Appearance'),
              _SettingsTile(
                icon: Icons.palette_outlined,
                iconColor: Theme.of(context).colorScheme.tertiary,
                title: 'Theme',
                subtitle: _getThemeName(context),
                onTap: () => _showThemePicker(context),
              ),
              const SizedBox(height: 24),
              const _SectionHeader('Support'),
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snapshot) {
                  final version = snapshot.data?.version ?? '1.0.1';
                  return _SettingsTile(
                    icon: Icons.info_outline,
                    iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
                    title: 'SpendX',
                    subtitle: 'Version $version — Built with Flutter ❤️',
                    onTap: () {},
                  );
                },
              ),
              const SizedBox(height: 40),
            ]),
          ),
        ],
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.bottomLeft,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Theme.of(context).colorScheme.primary.withValues(alpha: 0.8), Theme.of(context).colorScheme.surfaceContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: Theme.of(context).colorScheme.primary,
            child: Icon(Icons.person, size: 36, color: Theme.of(context).colorScheme.onPrimary),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Guest User', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
              const SizedBox(height: 4),
              Text('Offline Mode', style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15)),
      subtitle: Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
      trailing: Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outlineVariant),
      onTap: onTap,
    );
  }
}
