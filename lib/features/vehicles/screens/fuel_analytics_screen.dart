import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/vehicle.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/app_format.dart';
import '../providers/vehicle_providers.dart';

class FuelAnalyticsScreen extends ConsumerWidget {
  const FuelAnalyticsScreen({
    super.key,
    required this.vehicle,
  });

  final Vehicle vehicle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(vehicleDetailProvider(vehicle));

    return Scaffold(
      appBar: AppBar(
        title: Text('${vehicle.name} Analytics'),
      ),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (detail) {
          if (detail.logs.isEmpty) {
            return const Center(
              child: Text('No fuel logs yet'),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.standard),
            children: [
              _AnalyticsTile(
                label: 'Total Distance',
                value: '${detail.totalKm.toStringAsFixed(0)} km',
              ),
              _AnalyticsTile(
                label: 'Total Fuel Cost',
                value: AppFormat.currency(detail.totalFuelCost),
              ),
              _AnalyticsTile(
                label: 'Average Mileage',
                value: detail.avgMileage > 0
                    ? '${detail.avgMileage.toStringAsFixed(1)} km/l'
                    : '--',
              ),
              _AnalyticsTile(
                label: 'Cost Per KM',
                value: detail.costPerKm == null
                    ? '--'
                    : AppFormat.currency(detail.costPerKm!),
              ),
              if (detail.bestLog != null)
                _AnalyticsTile(
                  label: 'Best Mileage',
                  value: '${detail.bestLog!.efficiency?.toStringAsFixed(1) ?? '--'} km/l',
                ),
              if (detail.worstLog != null)
                _AnalyticsTile(
                  label: 'Worst Mileage',
                  value: '${detail.worstLog!.efficiency?.toStringAsFixed(1) ?? '--'} km/l',
                ),
            ],
          );
        },
      ),
    );
  }
}

class _AnalyticsTile extends StatelessWidget {
  const _AnalyticsTile({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.standard),
      child: ListTile(
        title: Text(label),
        trailing: Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
