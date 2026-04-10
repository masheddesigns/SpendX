import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../models/salary_payment.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../../utils/app_format.dart';

class SalaryHeaderCard extends StatelessWidget {
  const SalaryHeaderCard({
    super.key,
    required this.totalEarned,
    required this.totalPending,
    this.currentMonthPayment,
    this.onActionTap,
  });

  final double totalEarned;
  final double totalPending;
  final SalaryPayment? currentMonthPayment;
  final Function(SalaryPayment, String)? onActionTap;

  @override
  Widget build(BuildContext context) {

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _StatItem(
                label: 'Total Earned',
                value: AppFormat.currency(totalEarned),
                color: AppColors.success,
              ),
              _StatItem(
                label: 'Pending',
                value: AppFormat.currency(totalPending),
                color: totalPending > 0 ? AppColors.warning : AppColors.mutedText,
              ),
            ],
          ),
          if (currentMonthPayment != null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.l),
              child: Divider(height: 1, thickness: 0.5),
            ),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        DateFormat('MMMM yyyy').format(currentMonthPayment!.month),
                        style: AppTextStyles.labelMedium.copyWith(color: AppColors.secondaryText),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            AppFormat.currency(currentMonthPayment!.totalAmount),
                            style: AppTextStyles.titleLarge.copyWith(color: AppColors.primaryText),
                          ),
                          const SizedBox(width: AppSpacing.s),
                          _buildStatusChip(currentMonthPayment!.status),
                        ],
                      ),
                    ],
                  ),
                ),
                if (onActionTap != null && _shouldShowAction(currentMonthPayment!.status))
                   _buildActionButton(context, currentMonthPayment!),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusChip(SalaryPaymentStatus status) {
    return StatusChip(
      label: status.name.toUpperCase(),
      type: _getChipType(status),
    );
  }

  StatusChipType _getChipType(SalaryPaymentStatus status) {
    switch (status) {
      case SalaryPaymentStatus.received:
        return StatusChipType.success;
      case SalaryPaymentStatus.partial:
        return StatusChipType.warning;
      case SalaryPaymentStatus.delayed:
        return StatusChipType.danger;
      case SalaryPaymentStatus.onHold:
        return StatusChipType.neutral;
      case SalaryPaymentStatus.pending:
        return StatusChipType.neutral;
    }
  }

  bool _shouldShowAction(SalaryPaymentStatus status) {
    return status != SalaryPaymentStatus.received;
  }

  Widget _buildActionButton(BuildContext context, SalaryPayment payment) {
    return IconButton.filledTonal(
      onPressed: () => onActionTap?.call(payment, 'quick_action'),
      icon: const Icon(Icons.bolt),
      tooltip: 'Quick Actions',
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.labelMedium.copyWith(color: AppColors.secondaryText),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: AppTextStyles.headlineSmall.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
