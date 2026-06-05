import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../theme/app_theme.dart';
import '../../services/settings_service.dart';
import '../../widgets/spendx_app_bar.dart';

import 'category_management_screen.dart';
import 'currency_selection_screen.dart';
import 'data_management_screen.dart';
import 'database_tools_screen.dart';
import 'notification_settings_screen.dart';
import '../about_screen.dart';
import '../help_screen.dart';
import '../../shared/widgets/app_page_route.dart';

class ProfileSettingsScreen extends StatelessWidget {
  const ProfileSettingsScreen({super.key});

  String _getThemeName(BuildContext context) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final theme = AppTheme.availableThemes.firstWhere(
      (t) => t['id'] == settings.themeVariant,
      orElse: () => AppTheme.availableThemes.first,
    );
    return theme['name'] as String;
  }

  void _showThemePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Consumer<SettingsService>(
        builder: (ctx, settings, _) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('Choose Theme',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
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
                  title: Text(theme['name'] as String,
                      style: TextStyle(
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal)),
                  trailing: isSelected
                      ? Icon(Icons.check_circle,
                          color: Theme.of(context).colorScheme.primary)
                      : null,
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

  void _showThemeModePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Consumer<SettingsService>(
        builder: (ctx, settings, _) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('App Theme',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 16),
              ...[(ThemeMode.light, 'Light'), (ThemeMode.dark, 'Dark'),
                  (ThemeMode.system, 'System')]
                  .map((entry) {
                return ListTile(
                  leading: Icon(
                    entry.$1 == ThemeMode.light
                        ? Icons.light_mode_rounded
                        : entry.$1 == ThemeMode.dark
                            ? Icons.dark_mode_rounded
                            : Icons.auto_mode_rounded,
                  ),
                  title: Text(entry.$2),
                  trailing: settings.themeMode == entry.$1
                      ? Icon(Icons.check_circle,
                          color: Theme.of(context).colorScheme.primary)
                      : null,
                  onTap: () async {
                    await settings.setThemeMode(entry.$1);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(title: 'Settings'),
      body: SafeArea(
        child: ListView(
          children: [
            // ── Appearance ─────────────────────────────────────
            const _SectionHeader('Appearance'),
            Consumer<SettingsService>(
              builder: (ctx, settings, _) => _SettingsTile(
                icon: Icons.currency_exchange_rounded,
                iconColor: Theme.of(context).colorScheme.primary,
                title: 'Currency',
                subtitle:
                    '${settings.primaryCurrency} (${settings.currencySymbol})',
                onTap: () => Navigator.push(context,
                    AppPageRoute(builder: (_) => const CurrencySelectionScreen())),
              ),
            ),
            _SettingsTile(
              icon: Icons.brightness_6_outlined,
              iconColor: Theme.of(context).colorScheme.primary,
              title: 'App Theme',
              subtitle: Provider.of<SettingsService>(context, listen: false)
                      .themeMode
                      .name[0]
                      .toUpperCase() +
                  Provider.of<SettingsService>(context, listen: false)
                      .themeMode
                      .name
                      .substring(1),
              onTap: () => _showThemeModePicker(context),
            ),
            _SettingsTile(
              icon: Icons.palette_outlined,
              iconColor: Theme.of(context).colorScheme.tertiary,
              title: 'Theme Color',
              subtitle: _getThemeName(context),
              onTap: () => _showThemePicker(context),
            ),

            const Divider(height: 32),

            // ── Categories ────────────────────────────────────
            const _SectionHeader('Data'),
            _SettingsTile(
              icon: Icons.category_outlined,
              iconColor: Theme.of(context).colorScheme.primary,
              title: 'Categories',
              subtitle: 'Manage income & expense types',
              onTap: () => Navigator.push(context,
                  AppPageRoute(builder: (_) => const CategoryManagementScreen())),
            ),
            _SettingsTile(
              icon: Icons.storage_outlined,
              iconColor: Theme.of(context).colorScheme.secondary,
              title: 'Database Tools',
              subtitle: 'Import, export, backup',
              onTap: () => Navigator.push(context,
                  AppPageRoute(builder: (_) => const DatabaseToolsScreen())),
            ),
            _SettingsTile(
              icon: Icons.delete_outline_rounded,
              iconColor: Theme.of(context).colorScheme.error,
              title: 'Clear Data',
              subtitle: 'Erase transactions, accounts, salary',
              onTap: () => Navigator.push(context,
                  AppPageRoute(builder: (_) => const DataManagementScreen())),
            ),

            const Divider(height: 32),

            // ── Notifications ─────────────────────────────────
            const _SectionHeader('Notifications'),
            _SettingsTile(
              icon: Icons.notifications_none,
              iconColor: Theme.of(context).colorScheme.secondary,
              title: 'Notifications',
              subtitle: 'Reminders, alerts, quiet hours',
              onTap: () => Navigator.push(context,
                  AppPageRoute(builder: (_) => NotificationSettingsScreen())),
            ),

            const Divider(height: 32),

            // ── Support ───────────────────────────────────────
            const _SectionHeader('Support'),
            _SettingsTile(
              icon: Icons.help_outline_rounded,
              iconColor: Theme.of(context).colorScheme.primary,
              title: 'Help & Guide',
              subtitle: 'How to use SpendX',
              onTap: () => Navigator.push(context,
                  AppPageRoute(builder: (_) => const HelpScreen())),
            ),
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                final version = snapshot.data?.version ?? '1.5.0';
                return _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
                  title: 'About SpendX',
                  subtitle: 'Version $version',
                  onTap: () => Navigator.push(context,
                      AppPageRoute(builder: (_) => const AboutScreen())),
                );
              },
            ),
            const SizedBox(height: 40),
          ],
        ),
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
      title: Text(title,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15)),
      subtitle: Text(subtitle,
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 13)),
      trailing: Icon(Icons.chevron_right,
          color: Theme.of(context).colorScheme.outlineVariant),
      onTap: onTap,
    );
  }
}
