import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../data/providers.dart';
import '../../models/credit_card.dart';
import '../../models/emi_plan.dart';
import '../../widgets/custom_snackbar.dart';
import '../../widgets/custom_dialog.dart';
import '../../utils/app_format.dart';

class EmiDetailScreen extends ConsumerStatefulWidget {
  final EmiPlan plan;
  const EmiDetailScreen({super.key, required this.plan});

  @override
  ConsumerState<EmiDetailScreen> createState() => _EmiDetailScreenState();
}

class _EmiDetailScreenState extends ConsumerState<EmiDetailScreen> {
  late EmiPlan _plan;

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
  }

  Future<void> _markAsPaid(int instalmentIndex) async {
    // Instalment index is 0-based, meaning they tapped on row i.
    // Ensure they can only mark the *next* unpaid instalment to avoid skipping.
    if (instalmentIndex != _plan.paidInstalments) return;

    final confirm = await CustomDialog.show(
      context,
      type: DialogType.info,
      title: 'Mark as Paid?',
      message:
          'Are you sure you want to mark instalment #${instalmentIndex + 1} as paid?',
      primaryButtonText: 'Confirm',
      secondaryButtonText: 'Cancel',
    );

    if (confirm != true) return;

    final updatedPlan = _plan.copyWith(
      paidInstalments: _plan.paidInstalments + 1,
    );

    setState(() => _plan = updatedPlan);
    await ref.read(emiPlanMutationProvider.notifier).updatePlan(updatedPlan);

    // Also deduct outstanding from credit card if linked
    if (_plan.cardId != null) {
      final cards = await ref.read(cardsProvider.future);
      CreditCard? linkedCard;
      for (final card in cards) {
        if (card.id == _plan.cardId) {
          linkedCard = card;
          break;
        }
      }
      if (linkedCard != null) {
        // deduct the principal part of the EMI from outstanding
        final principalPaid =
            updatedPlan.amortizationSchedule[instalmentIndex].principal;
        final newOutstanding = (linkedCard.outstanding - principalPaid).clamp(
          0.0,
          double.infinity,
        );
        await ref
            .read(cardsProvider.notifier)
            .replace(linkedCard.copyWith(outstanding: newOutstanding));
      }
    }

    if (mounted) {
      CustomSnackBar.show(
        context,
        message: 'Instalment #${instalmentIndex + 1} marked as paid ✓',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final schedule = _plan.amortizationSchedule;
    final current = _plan.currentInstalment;

    return Scaffold(
      appBar: AppBar(
        title: Text(_plan.name),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Summary card
              _buildSummaryCard(current),
              const SizedBox(height: 20),

              // Amortization table header
              Text(
                'AMORTIZATION SCHEDULE',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),

              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    // Table header
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.15),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 32,
                            child: Text(
                              '#',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 80,
                            child: Text(
                              'Date',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'EMI',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'Principal',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'Balance',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Rows
                    ...schedule.asMap().entries.map((entry) {
                      final i = entry.key;
                      final row = entry.value;
                      final isPaid = row.isPaid;
                      final isCurrent = row.month == current;

                      return InkWell(
                        onTap: (!isPaid && i == _plan.paidInstalments)
                            ? () => _markAsPaid(i)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1)
                                : null,
                            border: i < schedule.length - 1
                                ? Border(
                                    bottom: BorderSide(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outlineVariant,
                                    ),
                                  )
                                : null,
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 32,
                                child: isPaid
                                    ? Icon(
                                        Icons.check_circle,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        size: 14,
                                      )
                                    : (i == _plan.paidInstalments)
                                    ? Icon(
                                        Icons.radio_button_unchecked,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        size: 14,
                                      )
                                    : Text(
                                        '${row.month}',
                                        style: TextStyle(
                                          color: isCurrent
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.primary
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                          fontSize: 12,
                                          fontWeight: isCurrent
                                              ? FontWeight.w600
                                              : FontWeight.normal,
                                        ),
                                      ),
                              ),
                              SizedBox(
                                width: 80,
                                child: Text(
                                  DateFormat('d MMM yy').format(row.dueDate),
                                  style: TextStyle(
                                    color: isPaid
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  AppFormat.currency(row.emiAmount),
                                  style: TextStyle(
                                    color: isPaid
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  AppFormat.currency(row.principal),
                                  style: TextStyle(
                                    color: isPaid
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant
                                        : Theme.of(context).colorScheme.primary,
                                    fontSize: 12,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  AppFormat.currency(row.balance),
                                  style: TextStyle(
                                    color: isPaid
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                    fontSize: 12,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCard(int current) {
    final progress = _plan.tenureMonths > 0
        ? current / _plan.tenureMonths
        : 0.0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            Theme.of(context).colorScheme.secondary.withValues(alpha: 0.15),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'MONTHLY EMI',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                      letterSpacing: 1,
                    ),
                  ),
                  Text(
                    AppFormat.currency(_plan.emiAmount),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${_plan.remainingInstalments} months left',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    '${AppFormat.currency(_plan.totalPayable - (_plan.paidInstalments * _plan.emiAmount))} remaining',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.secondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(
                progress >= 1
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.primary,
              ),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$current / ${_plan.tenureMonths} paid',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              Text(
                '${(progress * 100).toStringAsFixed(0)}% complete',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _chip(
                'Principal',
                AppFormat.currency(_plan.principal),
                Theme.of(context).colorScheme.primary,
              ),
              _chip(
                'Interest',
                AppFormat.currency(_plan.totalInterest),
                _plan.totalInterest > 0
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              _chip(
                'Total',
                AppFormat.currency(_plan.totalPayable),
                Theme.of(context).colorScheme.secondary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String value, Color color) => Column(
    children: [
      Text(
        value,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
      Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
    ],
  );
}
