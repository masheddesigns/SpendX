import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../models/salary_payment.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../../utils/app_format.dart';

class SalaryCard extends StatelessWidget {
  const SalaryCard({
    super.key,
    required this.payment,
    required this.onTap,
  });

  final SalaryPayment payment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.m),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Row(
          children: [
            _DateIcon(month: payment.month),
            const SizedBox(width: AppSpacing.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    DateFormat('MMMM yyyy').format(payment.month),
                    style: AppTextStyles.titleMedium.copyWith(color: AppColors.primaryText),
                  ),
                  const SizedBox(height: 4),
                  _buildSubInfo(cs),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  AppFormat.currency(payment.totalAmount),
                  style: AppTextStyles.titleMedium.copyWith(
                    color: AppColors.primaryText,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                _buildStatusChip(payment.status),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubInfo(ColorScheme cs) {
    if (payment.status == SalaryPaymentStatus.received) {
      return Text(
        'Received on ${DateFormat('dd MMM').format(payment.receivedDate ?? payment.month)}',
        style: AppTextStyles.bodySmall.copyWith(color: AppColors.secondaryText),
      );
    }
    
    final delay = payment.delayedByDays;
    if (delay > 0) {
      return Text(
        'Delayed by $delay days',
        style: AppTextStyles.bodySmall.copyWith(color: AppColors.danger),
      );
    }

    return Text(
      'Due on ${DateFormat('dd MMM').format(payment.expectedDate)}',
      style: AppTextStyles.bodySmall.copyWith(color: AppColors.secondaryText),
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
}

class _DateIcon extends StatelessWidget {
  const _DateIcon({required this.month});
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.small),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            DateFormat('MMM').format(month).toUpperCase(),
            style: AppTextStyles.labelSmall.copyWith(
              color: AppColors.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            DateFormat('yy').format(month),
            style: AppTextStyles.titleMedium.copyWith(
                color: AppColors.secondaryText,
                fontSize: 12
            ),
          ),
        ],
      ),
    );
  }
}
