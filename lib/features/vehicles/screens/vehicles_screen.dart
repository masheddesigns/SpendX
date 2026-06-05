import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/vehicle.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_bar.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/empty_state_widget.dart';
import '../../../shared/widgets/error_state_widget.dart';
import '../../../shared/widgets/skeleton_loader.dart';
import '../../../widgets/common/spendx_fab.dart';
import '../providers/vehicle_providers.dart';
import 'add_vehicle_entry_screen.dart';
import 'vehicle_detail_screen.dart';
import 'vehicle_management_screen.dart';
import '../../../shared/widgets/app_page_route.dart';

class VehiclesScreen extends ConsumerWidget {
  const VehiclesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehiclesAsync = ref.watch(vehiclesProvider);
    final selectedVehicleId = ref.watch(selectedVehicleIdProvider);

    return Scaffold(
      appBar: const SpendXAppBar(
        title: 'Vehicles',
      ),
      body: vehiclesAsync.when(
        loading: () => const SkeletonLoader.transactions(),
        error: (error, _) => ErrorStateWidget(error: error, onRetry: () => ref.invalidate(vehiclesProvider)),
        data: (vehicles) {
          if (vehicles.isEmpty) {
            return EmptyStateWidget(
              icon: Icons.directions_car_outlined,
              title: 'No vehicles yet',
              description:
                  'Add a vehicle to start tracking fuel, reminders, and costs.',
              ctaLabel: 'Manage Vehicles',
              onCtaTap: () {
                Navigator.push(
                  context,
                  AppPageRoute(
                    builder: (_) => const VehicleManagementScreen(),
                  ),
                );
              },
            );
          }

          final selectedVehicle = _pickSelectedVehicle(
            vehicles,
            selectedVehicleId,
          );

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(vehiclesProvider);
              ref.invalidate(selectedVehicleLogsProvider);
              ref.invalidate(vehicleDetailProvider);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.standard,
                AppSpacing.standard,
                AppSpacing.standard,
                104,
              ),
              children: [
                _VehiclePickerRow(
                  vehicles: vehicles,
                  selectedVehicleId: selectedVehicle.id,
                  onChanged: (value) {
                    ref.read(selectedVehicleIdProvider.notifier).state = value;
                  },
                  onManage: () {
                    Navigator.push(
                      context,
                      AppPageRoute(
                        builder: (_) => const VehicleManagementScreen(),
                      ),
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.standard),
                _VehicleHeroCard(vehicle: selectedVehicle),
                const SizedBox(height: AppSpacing.standard),
                _VehicleQuickActions(
                  onAddEntry: () => _openAddEntry(context, selectedVehicle.id),
                  onViewDetails: () {
                    Navigator.push(
                      context,
                      AppPageRoute(
                        builder: (_) =>
                            VehicleDetailScreen(vehicle: selectedVehicle),
                      ),
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.standard),
                Consumer(
                  builder: (context, ref, _) {
                    final detailAsync = ref.watch(
                      vehicleDetailProvider(selectedVehicle),
                    );

                    return detailAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.all(AppSpacing.standard),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (error, _) => AppCard(
                        child: Text('Unable to load vehicle data: $error'),
                      ),
                      data: (detail) => Column(
                        children: [
                          _VehicleStatsGrid(detail: detail),
                          const SizedBox(height: AppSpacing.standard),
                          _RecentFuelLogsCard(logs: detail.logs),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: SpendXFAB(
        icon: Icons.add_rounded,
        label: 'Add Entry',
        onPressed: () => _openAddEntry(context, selectedVehicleId),
      ),
    );
  }

  Vehicle _pickSelectedVehicle(List<Vehicle> vehicles, String? selectedVehicleId) {
    for (final vehicle in vehicles) {
      if (vehicle.id == selectedVehicleId) {
        return vehicle;
      }
    }
    return vehicles.first;
  }

  Future<void> _openAddEntry(BuildContext context, String? selectedVehicleId) async {
    final result = await Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => AddVehicleEntryScreen(
          initialVehicleId: selectedVehicleId,
          initialTabIndex: 0,
        ),
      ),
    );

    if (context.mounted && result == true) {
      // refresh happens via provider invalidation on rebuild
    }
  }
}

class _VehiclePickerRow extends StatelessWidget {
  const _VehiclePickerRow({
    required this.vehicles,
    required this.selectedVehicleId,
    required this.onChanged,
    required this.onManage,
  });

  final List<Vehicle> vehicles;
  final String selectedVehicleId;
  final ValueChanged<String?> onChanged;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: AppCard(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.standard,
              vertical: AppSpacing.tight,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedVehicleId,
                isExpanded: true,
                items: vehicles
                    .map(
                      (vehicle) => DropdownMenuItem<String>(
                        value: vehicle.id,
                        child: Text(vehicle.name),
                      ),
                    )
                    .toList(),
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.standard),
        OutlinedButton.icon(
          onPressed: onManage,
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Manage'),
        ),
      ],
    );
  }
}

class _VehicleHeroCard extends StatelessWidget {
  const _VehicleHeroCard({required this.vehicle});

  final Vehicle vehicle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: cs.primary.withValues(alpha: 0.12),
            child: Icon(
              vehicle.type == 'car'
                  ? Icons.directions_car_filled_rounded
                  : Icons.two_wheeler_rounded,
              color: cs.primary,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  vehicle.name,
                  style: AppTextStyles.titleLarge.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${vehicle.fuelType.toUpperCase()}${vehicle.regNumber == null ? '' : ' • ${vehicle.regNumber}'}',
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VehicleQuickActions extends StatelessWidget {
  const _VehicleQuickActions({
    required this.onAddEntry,
    required this.onViewDetails,
  });

  final VoidCallback onAddEntry;
  final VoidCallback onViewDetails;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: onAddEntry,
            icon: const Icon(Icons.local_gas_station_outlined),
            label: const Text('Add Fuel'),
          ),
        ),
        const SizedBox(width: AppSpacing.standard),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onViewDetails,
            icon: const Icon(Icons.analytics_outlined),
            label: const Text('Details'),
          ),
        ),
      ],
    );
  }
}

class _VehicleStatsGrid extends StatelessWidget {
  const _VehicleStatsGrid({required this.detail});

  final VehicleDetailData detail;

  @override
  Widget build(BuildContext context) {
    final items = <({String label, String value})>[
      (label: 'Fuel Cost', value: detail.totalFuelCost.toStringAsFixed(0)),
      (label: 'Other Cost', value: detail.totalOtherCost.toStringAsFixed(0)),
      (label: 'Avg Mileage', value: detail.avgMileage.toStringAsFixed(1)),
      (label: 'Logs', value: '${detail.logs.length}'),
    ];

    return GridView.builder(
      itemCount: items.length,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: AppSpacing.standard,
        mainAxisSpacing: AppSpacing.standard,
        childAspectRatio: 1.6,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        return AppCard(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                item.value,
                style: AppTextStyles.titleLarge.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item.label,
                style: AppTextStyles.bodySmall.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RecentFuelLogsCard extends StatelessWidget {
  const _RecentFuelLogsCard({required this.logs});

  final List<FuelLog> logs;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent Fuel Logs',
            style: AppTextStyles.titleMedium.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.standard),
          if (logs.isEmpty)
            Text(
              'No fuel entries yet.',
              style: AppTextStyles.bodyMedium.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...logs.take(5).map(
              (log) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.local_gas_station_outlined),
                title: Text('${log.litres.toStringAsFixed(1)} L'),
                subtitle: Text(log.date.toIso8601String().split('T').first),
                trailing: Text(log.totalCost.toStringAsFixed(0)),
              ),
            ),
        ],
      ),
    );
  }
}
