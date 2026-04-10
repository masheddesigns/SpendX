import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final double iconContainerSize;
  final double iconSize;

  const SettingsTile({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
    this.iconContainerSize = 44,
    this.iconSize = 22,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: Container(
        width: iconContainerSize,
        height: iconContainerSize,
        decoration: BoxDecoration(
          color: AppTheme.tinted(color),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          icon,
          color: color,
          size: iconSize,
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 15,
          decoration: TextDecoration.none,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
          decoration: TextDecoration.none,
        ),
      ),
      trailing: trailing ?? Icon(
        Icons.arrow_forward_ios,
        color: Theme.of(context).colorScheme.outlineVariant,
        size: 14,
      ),
    );
  }
}
