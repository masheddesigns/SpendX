import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../screens/settings/automatic_ingestion_screen.dart';
import '../../../screens/credit_card_screen.dart';
import '../../../screens/loans/loans_screen.dart';
import '../../../screens/notifications_inbox_screen.dart';
import '../../../services/haptic_service.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../shared/widgets/glass/spendx_glass_button.dart';
import '../../../utils/app_format.dart';
import '../../alerts/data/app_alert.dart';
import '../../ingestion/providers/ingestion_providers.dart';
import '../../ingestion/providers/update_providers.dart';
import '../providers/home_providers.dart';

/// Mindful Alert section rendered prominently on the Home Dashboard.
///
/// Features:
/// 1. Automatic Ingestion Setup / Warning alert (when notification listener or SMS is inactive).
/// 2. Active Financial Alerts (credit card bill due, loan EMI, delayed salary, budgets).
class HomeAlertsSection extends ConsumerStatefulWidget {
  const HomeAlertsSection({super.key});

  @override
  ConsumerState<HomeAlertsSection> createState() => _HomeAlertsSectionState();
}

class _HomeAlertsSectionState extends ConsumerState<HomeAlertsSection> {
  bool _dismissedIngestionBanner = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final updateAsync = ref.watch(appUpdateInfoProvider);
    final updateInfo = updateAsync.valueOrNull;
    final ingestionStatusAsync = ref.watch(ingestionStatusProvider);
    final ingestionStatus =
        ingestionStatusAsync.valueOrNull ?? const AutomaticIngestionStatus();
    final alertsAsync = ref.watch(homeAlertsProvider);
    final activeAlerts = alertsAsync.valueOrNull ?? const <AppAlert>[];

    final isUpdateAvailable = updateInfo?.isUpdateAvailable ?? false;
    final showIngestionAlert =
        ingestionStatus.needsAttention && !_dismissedIngestionBanner;

    if (!isUpdateAvailable && !showIngestionAlert && activeAlerts.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Play Store Update Alert ───────────────────────────
          if (isUpdateAvailable) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isDark
                      ? [
                          const Color(0x336366F1),
                          const Color(0x1A6366F1),
                        ]
                      : [
                          const Color(0xFFEEF2FF),
                          const Color(0xFFE0E7FF),
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFF6366F1)
                      .withValues(alpha: isDark ? 0.45 : 0.6),
                  width: 1.0,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.system_update_rounded,
                      color: Color(0xFF6366F1),
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Update Available on Google Play',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? const Color(0xFFC7D2FE)
                                : const Color(0xFF3730A3),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'A new version with performance improvements and features is ready.',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: isDark
                                ? const Color(0xFFD1D5DB)
                                : const Color(0xFF4338CA),
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SpendXGlassButton.icon(
                    label: 'Update',
                    icon: Icons.download_rounded,
                    height: 32,
                    variant: SpendXGlassButtonVariant.primary,
                    onPressed: () {
                      HapticService.instance.selection();
                      ref.read(appUpdateInfoProvider.notifier).startUpdate();
                    },
                  ),
                ],
              ),
            ),
          ],
          // ── Ingestion Setup Attention Alert ───────────────────
          if (showIngestionAlert) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isDark
                      ? [
                          const Color(0x33F59E0B),
                          const Color(0x1AF59E0B),
                        ]
                      : [
                          const Color(0xFFFEF3C7),
                          const Color(0xFFFFFBEB),
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFFF59E0B)
                      .withValues(alpha: isDark ? 0.45 : 0.6),
                  width: 1.0,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFFF59E0B).withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.bolt_rounded,
                          color: Color(0xFFD97706),
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Enable Automatic Ingestion',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? const Color(0xFFFDE68A)
                                    : const Color(0xFF92400E),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Auto-capture UPI, debit/credit transactions & bank balances in real-time as alerts arrive.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: isDark
                                    ? const Color(0xFFD1D5DB)
                                    : const Color(0xFF78350F),
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF92400E),
                        ),
                        onPressed: () {
                          HapticService.instance.tap();
                          setState(() => _dismissedIngestionBanner = true);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SpendXGlassButton.icon(
                        label: 'Turn On',
                        icon: Icons.check_circle_outline_rounded,
                        height: 32,
                        variant: SpendXGlassButtonVariant.primary,
                        onPressed: () async {
                          HapticService.instance.selection();
                          await Navigator.push(
                            context,
                            AppPageRoute(
                              builder: (_) => const AutomaticIngestionScreen(),
                            ),
                          );
                          ref.read(ingestionStatusProvider.notifier).refresh();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          // ── Active Financial / Commitment Alerts ──────────────
          for (final alert in activeAlerts.take(2)) ...[
            _buildFinancialAlertCard(context, alert, isDark),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildFinancialAlertCard(
      BuildContext context, AppAlert alert, bool isDark) {
    Color alertColor;
    IconData alertIcon;

    switch (alert.severity) {
      case AlertSeverity.critical:
        alertColor = const Color(0xFFEF4444);
        alertIcon = Icons.error_outline_rounded;
        break;
      case AlertSeverity.warning:
        alertColor = const Color(0xFFF59E0B);
        alertIcon = Icons.warning_amber_rounded;
        break;
      case AlertSeverity.normal:
        alertColor = const Color(0xFF3B82F6);
        alertIcon = Icons.info_outline_rounded;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2330) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: alertColor.withValues(alpha: isDark ? 0.35 : 0.35),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: alertColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(alertIcon, size: 16, color: alertColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  alert.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          if (alert.amount != null && alert.amount! > 0) ...[
            const SizedBox(width: 8),
            Text(
              AppFormat.currency(alert.amount!),
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: alertColor,
              ),
            ),
          ],
          const SizedBox(width: 8),
          SpendXGlassButton(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            onPressed: () => _routeAlert(context, alert),
            child: const Text(
              'View',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _routeAlert(BuildContext context, AppAlert alert) {
    HapticService.instance.selection();
    switch (alert.type) {
      case AlertType.creditCardDue:
        Navigator.push(
          context,
          AppPageRoute(builder: (_) => const CreditCardScreen()),
        );
        break;
      case AlertType.loanDue:
        Navigator.push(
          context,
          AppPageRoute(builder: (_) => const LoansScreen()),
        );
        break;
      default:
        Navigator.push(
          context,
          AppPageRoute(builder: (_) => const NotificationsInboxScreen()),
        );
        break;
    }
  }
}
