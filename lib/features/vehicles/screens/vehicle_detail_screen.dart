import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/vehicle.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_bar.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/primary_button.dart';
import '../../../utils/app_format.dart';
import '../providers/vehicle_providers.dart';
import '../services/vehicle_reminder_service.dart';
import '../widgets/activity_timeline.dart';
import '../widgets/cost_summary_card.dart';
import '../widgets/fuel_summary_card.dart';
import '../widgets/reminders_section.dart';
import '../../../shared/widgets/error_state_widget.dart';
import '../../../shared/widgets/skeleton_loader.dart';
import '../widgets/vehicle_header.dart';
import 'add_vehicle_entry_screen.dart';
import '../../../shared/widgets/app_page_route.dart';

class VehicleDetailScreen extends ConsumerWidget {
  const VehicleDetailScreen({super.key, required this.vehicle});

  final Vehicle vehicle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(vehicleDetailProvider(vehicle));

    return Scaffold(
      appBar: SpendXAppBar(title: vehicle.name),
      body: detailAsync.when(
        loading: () => const SkeletonLoader.summary(),
        error: (err, _) => ErrorStateWidget(error: err, onRetry: () => ref.invalidate(vehicleDetailProvider(vehicle))),
        data: (data) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(vehicleDetailProvider(vehicle));
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.m,
              AppSpacing.m,
              AppSpacing.m,
              100,
            ),
            children: [
              VehicleHeader(
                name: vehicle.name,
                totalKm: data.totalKm,
                avgEfficiency: data.avgMileage,
                totalSpend: data.totalFuelCost + data.totalOtherCost,
              ),
              const SizedBox(height: AppSpacing.l),
              FuelSummaryCard(
                logs: data.logs,
                avgEfficiency: data.avgMileage,
                costPerKm: data.costPerKm ?? 0,
              ),
              const SizedBox(height: AppSpacing.l),
              CostSummaryCard(
                totalFuelCost: data.totalFuelCost,
                totalMaintenanceCost: data.totalOtherCost,
              ),
              const SizedBox(height: AppSpacing.l),
              _QuickStatsCard(data: data),
              const SizedBox(height: AppSpacing.l),
              RemindersSection(
                activeReminders: data.alerts,
                currentOdometer: data.currentOdo,
                onAcknowledge: (reminder) async {
                  await VehicleReminderService.instance.acknowledge(
                    reminder,
                    data.currentOdo,
                  );
                  ref.invalidate(vehicleDetailProvider(vehicle));
                },
              ),
              const SizedBox(height: AppSpacing.l),
              ActivityTimeline(activities: data.timeline),
            ],
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
        child: PrimaryButton(
          label: 'Add Entry',
          expand: true,
          onPressed: () async {
            final result = await Navigator.of(context).push<bool>(
              AppPageRoute(
                builder: (_) =>
                    AddVehicleEntryScreen(initialVehicleId: vehicle.id),
              ),
            );
            if (result == true) {
              ref.invalidate(vehicleDetailProvider(vehicle));
            }
          },
        ),
      ),
    );
  }
}

class _QuickStatsCard extends StatelessWidget {
  const _QuickStatsCard({required this.data});

  final VehicleDetailData data;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Quick Stats', style: AppTextStyles.titleMedium),
          const SizedBox(height: AppSpacing.m),
          _StatRow(
            label: 'Current Odometer',
            value: '${data.currentOdo.toStringAsFixed(0)} km',
          ),
          _divider(cs),
          _StatRow(
            label: 'Fuel Spend',
            value: AppFormat.currency(data.totalFuelCost),
          ),
          _divider(cs),
          _StatRow(
            label: 'Other Expenses',
            value: AppFormat.currency(data.totalOtherCost),
          ),
          _divider(cs),
          _StatRow(
            label: 'Cost / KM',
            value: data.costPerKm == null
                ? '--'
                : AppFormat.currency(data.costPerKm!),
          ),
          if (data.serviceAlert != null) ...[
            _divider(cs),
            _StatRow(
              label: 'Service Alert',
              value: data.serviceAlert!.message,
              valueColor: data.serviceAlert!.isOverdue
                  ? cs.error
                  : cs.onSurface,
            ),
          ],
          if (data.prediction != null) ...[
            _divider(cs),
            _StatRow(
              label: 'Next Fill Estimate',
              value: AppFormat.currency(data.prediction!.nextFillCost),
            ),
          ],
        ],
      ),
    );
  }

  Widget _divider(ColorScheme cs) {
    return Divider(color: cs.outlineVariant.withValues(alpha: 0.4), height: 20);
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: AppTextStyles.bodyMedium.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.m),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: AppTextStyles.titleSmall.copyWith(
              color: valueColor ?? cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}
