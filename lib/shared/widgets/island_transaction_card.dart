import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../main.dart';
import '../../services/dynamic_island_service.dart';
import '../../services/notification_service_v2.dart';

class IslandTransactionCard extends StatelessWidget {
  final DynamicIslandEvent event;

  const IslandTransactionCard({super.key, required this.event});

  static bool _isShowing = false;

  static Future<void> show(BuildContext? context, DynamicIslandEvent event) async {
    final targetContext = MyApp.navigatorKey.currentContext ?? context;
    if (targetContext == null || _isShowing) return;
    _isShowing = true;
    try {
      await showModalBottomSheet(
        context: targetContext,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.65),
        builder: (ctx) => IslandTransactionCard(event: event),
      );
    } finally {
      _isShowing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isExpense = event.isExpense;
    final accentColor = isExpense ? const Color(0xFFF43F5E) : const Color(0xFF10B981);
    final darkAccent = isExpense ? const Color(0xFF881337) : const Color(0xFF064E3B);
    final lightColor = isExpense ? const Color(0xFFFCA5A5) : const Color(0xFF6EE7B7);

    final rawAmount = event.amount;
    final cleanAmount = rawAmount.startsWith('₹') ? rawAmount.substring(1) : rawAmount;
    final displayFormatted = '${isExpense ? "- " : "+ "}₹$cleanAmount';

    final merchant = event.subtitle.isNotEmpty && event.subtitle != 'SpendX'
        ? event.subtitle
        : (isExpense ? 'Expense Recorded' : 'Income Recorded');

    final formattedDate = DateFormat('EEE, d MMM yyyy • hh:mm a').format(event.timestamp);

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF12141C).withValues(alpha: 0.94),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.28),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(alpha: 0.15),
                blurRadius: 40,
                spreadRadius: 2,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top drag pill
                  Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Glowing Icon Gem
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [accentColor, darkAccent],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withValues(alpha: 0.45),
                          blurRadius: 24,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Icon(
                      isExpense ? Icons.arrow_outward_rounded : Icons.south_west_rounded,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Direction Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: accentColor.withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      isExpense ? 'EXPENSE' : 'INCOME',
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Amount with scale-down fit
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      displayFormatted,
                      maxLines: 1,
                      style: TextStyle(
                        color: lightColor,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),

                  // Merchant / Subtitle with wrap/overflow protection
                  Text(
                    merchant,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFE5E7EB),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Metadata card container
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _buildRow(
                          icon: Icons.access_time_rounded,
                          label: 'Date & Time',
                          value: formattedDate,
                        ),
                        Divider(color: Colors.white.withValues(alpha: 0.06), height: 20),
                        _buildRow(
                          icon: Icons.account_balance_wallet_rounded,
                          label: 'Logged By',
                          value: 'SpendX Origin Island',
                        ),
                        Divider(color: Colors.white.withValues(alpha: 0.06), height: 20),
                        _buildRow(
                          icon: Icons.check_circle_rounded,
                          label: 'Status',
                          value: 'Recorded',
                          valueColor: const Color(0xFF10B981),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Dismiss', style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accentColor,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          onPressed: () {
                            Navigator.of(context).pop();
                            NotificationServiceV2().handleNotificationNavigation('activity', '');
                          },
                          child: const Text(
                            'View in Transactions',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF9CA3AF)),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF9CA3AF),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
