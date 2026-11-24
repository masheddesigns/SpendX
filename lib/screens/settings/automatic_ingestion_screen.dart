import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../features/ingestion/providers/ingestion_providers.dart';
import '../../features/review_queue/providers/review_providers.dart';
import '../../services/gmail_integration_service.dart';
import '../../services/inbox_audit_service.dart';
import '../../services/live_sms_service.dart';
import '../../services/settings_service.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/glass/spendx_glass_button.dart';
import '../../shared/widgets/glass/spendx_glass_surface.dart';
import '../../shared/widgets/glass/spendx_scaffold.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../theme/app_theme.dart';
import '../../widgets/custom_snackbar.dart';
import '../data_health_screen.dart';
import '../review/review_queue_screen.dart';

/// Comprehensive Automatic Ingestion Hub.
///
/// Implements full management, status diagnostics, and channel controls
/// for real-time bank SMS, push notification listeners, WhatsApp bank alerts,
/// and email e-statement tracking.
class AutomaticIngestionScreen extends ConsumerStatefulWidget {
  const AutomaticIngestionScreen({super.key});

  @override
  ConsumerState<AutomaticIngestionScreen> createState() =>
      _AutomaticIngestionScreenState();
}

class _AutomaticIngestionScreenState
    extends ConsumerState<AutomaticIngestionScreen>
    with WidgetsBindingObserver {
  bool _isAuditing = false;
  bool _isSyncingGmail = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() {
      ref.read(ingestionStatusProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(ingestionStatusProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusAsync = ref.watch(ingestionStatusProvider);
    final status = statusAsync.valueOrNull ?? const AutomaticIngestionStatus();
    final reviewCount = ref.watch(reviewQueueCountProvider).valueOrNull ?? 0;

    return SpendXScaffold(
      appBar: const SpendXAppBar(title: 'Automatic Ingestion'),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(ingestionStatusProvider.notifier).refresh();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            // ── Hero Status Card ──────────────────────────────────────
            _buildHeroStatusCard(status, isDark),
            const SizedBox(height: 16),

            // ── Primary Ingestion Channels ───────────────────────────
            _buildSectionHeader('PRIMARY INGESTION CHANNELS', isDark),
            SpendXGlassSurface(
              level: SpendXGlassLevel.base,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  // 1. Bank App Notifications
                  _buildChannelTile(
                    icon: Icons.notifications_active_rounded,
                    iconColor: Theme.of(context).colorScheme.primary,
                    title: 'Bank App Notifications',
                    subtitle:
                        'Instant capture from Google Pay, PhonePe, Paytm, CRED, SBI, HDFC, ICICI, etc.',
                    badgeText: status.isNotificationListenerEnabled
                        ? 'Active'
                        : 'Action Needed',
                    badgeColor: status.isNotificationListenerEnabled
                        ? Theme.of(context).colorScheme.secondary
                        : Theme.of(context).colorScheme.tertiary,
                    trailing: Switch.adaptive(
                      value: status.isNotificationListenerEnabled,
                      activeTrackColor: Theme.of(context).colorScheme.primary,
                      onChanged: (v) async {
                        await LiveSmsService.instance
                            .openNotificationListenerSettings();
                        await ref
                            .read(ingestionStatusProvider.notifier)
                            .refresh();
                      },
                    ),
                    onTap: () async {
                      await LiveSmsService.instance
                          .openNotificationListenerSettings();
                      await ref
                          .read(ingestionStatusProvider.notifier)
                          .refresh();
                    },
                    isDark: isDark,
                  ),
                  _buildDivider(isDark),

                  // 2. Live Bank SMS Detection
                  _buildChannelTile(
                    icon: Icons.sms_rounded,
                    iconColor: Theme.of(context).colorScheme.primary,
                    title: 'Live SMS Detection',
                    subtitle:
                        'Captures debit, credit, ATM, and salary SMS as they arrive.',
                    badgeText:
                        (status.isLiveSmsEnabled && status.hasSmsPermission)
                        ? 'Active'
                        : (!status.hasSmsPermission
                              ? 'Permission Needed'
                              : 'Disabled'),
                    badgeColor:
                        (status.isLiveSmsEnabled && status.hasSmsPermission)
                        ? Theme.of(context).colorScheme.secondary
                        : Theme.of(context).colorScheme.tertiary,
                    trailing: Switch.adaptive(
                      value: status.isLiveSmsEnabled,
                      activeTrackColor: Theme.of(context).colorScheme.primary,
                      onChanged: (v) async {
                        await LiveSmsService.instance.setEnabled(v);
                        if (v && !status.hasSmsPermission) {
                          await LiveSmsService.instance
                              .requestReceivePermission();
                        }
                        await ref
                            .read(ingestionStatusProvider.notifier)
                            .refresh();
                      },
                    ),
                    onTap: () async {
                      if (!status.hasSmsPermission) {
                        await LiveSmsService.instance
                            .requestReceivePermission();
                        await ref
                            .read(ingestionStatusProvider.notifier)
                            .refresh();
                      }
                    },
                    isDark: isDark,
                  ),
                  _buildDivider(isDark),

                  // 3. Background Battery Reliability
                  _buildChannelTile(
                    icon: Icons.battery_charging_full_rounded,
                    iconColor: Theme.of(context).colorScheme.secondary,
                    title: 'Background Process Reliability',
                    subtitle:
                        'Prevents OEM battery savers (Vivo, Samsung, Xiaomi) from terminating listeners.',
                    badgeText: status.isBatteryOptimizationIgnored
                        ? 'Unrestricted'
                        : 'Restricted',
                    badgeColor: status.isBatteryOptimizationIgnored
                        ? Theme.of(context).colorScheme.secondary
                        : Theme.of(context).colorScheme.tertiary,
                    trailing: TextButton(
                      onPressed: () async {
                        await Permission.ignoreBatteryOptimizations.request();
                        await ref
                            .read(ingestionStatusProvider.notifier)
                            .refresh();
                      },
                      child: Text(
                        status.isBatteryOptimizationIgnored
                            ? 'Granted'
                            : 'Unrestrict',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: status.isBatteryOptimizationIgnored
                              ? Theme.of(context).colorScheme.secondary
                              : AppTheme.primaryBlue,
                        ),
                      ),
                    ),
                    isDark: isDark,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // ── Supplementary Integrations ───────────────────────────
            _buildSectionHeader('SUPPLEMENTARY CHANNELS', isDark),
            SpendXGlassSurface(
              level: SpendXGlassLevel.base,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  // WhatsApp Banking Alerts
                  _buildChannelTile(
                    icon: Icons.chat_bubble_outline_rounded,
                    iconColor: Theme.of(context).colorScheme.secondary,
                    title: 'WhatsApp Banking Alerts',
                    subtitle:
                        'Capture e-receipts and transactions from verified official bank bots.',
                    badgeText: status.isWhatsAppEnabled ? 'Enabled' : 'Off',
                    badgeColor: status.isWhatsAppEnabled
                        ? Theme.of(context).colorScheme.secondary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    trailing: Switch.adaptive(
                      value: status.isWhatsAppEnabled,
                      activeTrackColor: Theme.of(context).colorScheme.secondary,
                      onChanged: (v) async {
                        await SettingsService.instance
                            .setWhatsAppIngestionEnabled(v);
                        await ref
                            .read(ingestionStatusProvider.notifier)
                            .refresh();
                      },
                    ),
                    isDark: isDark,
                  ),
                  _buildDivider(isDark),

                  // 1. Live Gmail Notifications (On-Device)
                  _buildChannelTile(
                    icon: Icons.mark_email_unread_outlined,
                    iconColor: const Color(0xFFEA4335),
                    title: 'Live Gmail Notifications',
                    subtitle:
                        'Instantly capture bank debit/credit emails from the notification tray (100% on-device).',
                    badgeText: status.isGmailNotificationEnabled
                        ? 'Active'
                        : 'Off',
                    badgeColor: status.isGmailNotificationEnabled
                        ? Theme.of(context).colorScheme.secondary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    trailing: Switch.adaptive(
                      value: status.isGmailNotificationEnabled,
                      activeTrackColor: const Color(0xFFEA4335),
                      onChanged: (v) async {
                        await SettingsService.instance.setGmailPreviewEnabled(
                          v,
                        );
                        await ref
                            .read(ingestionStatusProvider.notifier)
                            .refresh();
                      },
                    ),
                    isDark: isDark,
                  ),
                  _buildDivider(isDark),

                  // 2. Gmail E-Statement Sync (OAuth API)
                  _buildChannelTile(
                    icon: Icons.cloud_sync_outlined,
                    iconColor: const Color(0xFFEA4335),
                    title: 'Gmail Statement & Bill Sync',
                    subtitle: status.isGmailConnected
                        ? 'Connected: ${GmailIntegrationService.instance.connectedEmail}${status.gmailLastSync != null ? '\nLast synced: ${DateFormat('dd MMM, hh:mm a').format(status.gmailLastSync!)}' : ''}'
                        : 'Connect read-only access to auto-scan past statements & card bills.',
                    badgeText: status.isGmailConnected ? 'Connected' : 'Off',
                    badgeColor: status.isGmailConnected
                        ? Theme.of(context).colorScheme.secondary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    trailing: status.isGmailConnected
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: _isSyncingGmail
                                    ? null
                                    : () async {
                                        setState(() => _isSyncingGmail = true);
                                        try {
                                          final res =
                                              await GmailIntegrationService
                                                  .instance
                                                  .syncFinancialEmails();
                                          if (context.mounted) {
                                            if (res.error != null) {
                                              CustomSnackBar.show(
                                                context,
                                                message:
                                                    'Gmail sync: ${res.error}',
                                              );
                                            } else {
                                              CustomSnackBar.show(
                                                context,
                                                message:
                                                    'Gmail sync: ${res.scanned} scanned, ${res.ingested} new transactions ingested.',
                                              );
                                            }
                                          }
                                        } catch (e) {
                                          if (context.mounted) {
                                            CustomSnackBar.show(
                                              context,
                                              message: 'Sync error: $e',
                                            );
                                          }
                                        } finally {
                                          if (context.mounted) {
                                            setState(
                                              () => _isSyncingGmail = false,
                                            );
                                            ref
                                                .read(
                                                  ingestionStatusProvider
                                                      .notifier,
                                                )
                                                .refresh();
                                          }
                                        }
                                      },
                                child: Text(
                                  _isSyncingGmail ? 'Syncing...' : 'Sync Now',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFFEA4335),
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.link_off_rounded,
                                  size: 18,
                                ),
                                tooltip: 'Disconnect Gmail',
                                onPressed: () async {
                                  await GmailIntegrationService.instance
                                      .disconnect();
                                  await ref
                                      .read(ingestionStatusProvider.notifier)
                                      .refresh();
                                },
                              ),
                            ],
                          )
                        : TextButton(
                            onPressed: () async {
                              final connected = await GmailIntegrationService
                                  .instance
                                  .connect();
                              if (connected && context.mounted) {
                                CustomSnackBar.show(
                                  context,
                                  message:
                                      'Connected Gmail for read-only statement sync.',
                                );
                              }
                              await ref
                                  .read(ingestionStatusProvider.notifier)
                                  .refresh();
                            },
                            child: const Text(
                              'Connect',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                    isDark: isDark,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // ── Diagnostics & Actions ─────────────────────────────────
            _buildSectionHeader('DIAGNOSTICS & VERIFICATION', isDark),
            SpendXGlassSurface(
              level: SpendXGlassLevel.base,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Zero-Cloud On-Device Guarantee',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'All SMS and notifications are parsed 100% locally on your phone. Personal messages and OTPs are strictly excluded.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: SpendXGlassButton.icon(
                          label: _isAuditing ? 'Scanning...' : 'Scan Inbox',
                          icon: Icons.refresh_rounded,
                          height: 38,
                          onPressed: _isAuditing
                              ? null
                              : () async {
                                  setState(() => _isAuditing = true);
                                  try {
                                    final audit = await InboxAuditService
                                        .instance
                                        .runAudit();
                                    if (context.mounted) {
                                      CustomSnackBar.show(
                                        context,
                                        message:
                                            'Inbox scan complete: ${audit.capturedCount} captured, ${audit.missedCount} uncaptured.',
                                      );
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      CustomSnackBar.show(
                                        context,
                                        message: 'Scan error: $e',
                                      );
                                    }
                                  } finally {
                                    if (context.mounted) {
                                      setState(() => _isAuditing = false);
                                      ref
                                          .read(
                                            ingestionStatusProvider.notifier,
                                          )
                                          .refresh();
                                    }
                                  }
                                },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SpendXGlassButton.icon(
                          label: 'Health & Audit',
                          icon: Icons.health_and_safety_outlined,
                          height: 38,
                          onPressed: () {
                            Navigator.push(
                              context,
                              AppPageRoute(
                                builder: (_) => const DataHealthScreen(),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  if (reviewCount > 0) ...[
                    const SizedBox(height: 10),
                    SpendXGlassButton.icon(
                      label:
                          'Review Ingestion Queue ($reviewCount item${reviewCount == 1 ? '' : 's'})',
                      icon: Icons.rate_review_rounded,
                      height: 42,
                      variant: SpendXGlassButtonVariant.primary,
                      onPressed: () {
                        Navigator.push(
                          context,
                          AppPageRoute(
                            builder: (_) => const ReviewQueueScreen(),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroStatusCard(AutomaticIngestionStatus status, bool isDark) {
    final active = status.isFullyActive;
    final color = active
        ? Theme.of(context).colorScheme.secondary
        : Theme.of(context).colorScheme.tertiary;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [color.withValues(alpha: 0.18), color.withValues(alpha: 0.06)]
              : [color.withValues(alpha: 0.14), color.withValues(alpha: 0.04)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: color.withValues(alpha: isDark ? 0.35 : 0.5),
          width: 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  active ? Icons.bolt_rounded : Icons.warning_amber_rounded,
                  color: color,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status.statusTitle,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status.statusSubtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!active) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: SpendXGlassButton.icon(
                    label: !status.isNotificationListenerEnabled
                        ? 'Enable Notification Access'
                        : (!status.hasSmsPermission
                              ? 'Grant SMS Permission'
                              : 'Resume Live Detection'),
                    icon: Icons.check_circle_outline_rounded,
                    height: 38,
                    variant: SpendXGlassButtonVariant.primary,
                    onPressed: () async {
                      if (!status.isNotificationListenerEnabled) {
                        await LiveSmsService.instance
                            .openNotificationListenerSettings();
                      } else if (!status.hasSmsPermission) {
                        await LiveSmsService.instance
                            .requestReceivePermission();
                      } else {
                        await LiveSmsService.instance.setEnabled(true);
                      }
                      await ref
                          .read(ingestionStatusProvider.notifier)
                          .refresh();
                    },
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildChannelTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String badgeText,
    required Color badgeColor,
    required Widget trailing,
    required bool isDark,
    VoidCallback? onTap,
  }) {
    return Semantics(
      button: onTap != null,
      enabled: onTap != null,
      label: '$title, $subtitle',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: InkWell(
          onTap: onTap,
          child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          badgeText,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: badgeColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    ),
  ),
);
}

  Widget _buildDivider(bool isDark) {
    return Container(
      margin: const EdgeInsets.only(left: 54, right: 14),
      height: 0.5,
      color: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.06),
    );
  }
}
