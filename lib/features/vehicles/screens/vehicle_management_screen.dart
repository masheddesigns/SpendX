import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/vehicle.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_bar.dart';
import '../../../shared/widgets/undo_snackbar_listener.dart';
import '../../../widgets/common/spendx_fab.dart';
import '../../../utils/text_formatter.dart';
import '../providers/vehicle_providers.dart';
import 'add_vehicle_screen.dart';

class VehicleManagementScreen extends ConsumerStatefulWidget {
  const VehicleManagementScreen({super.key});

  @override
  ConsumerState<VehicleManagementScreen> createState() =>
      _VehicleManagementScreenState();
}

class _VehicleManagementScreenState
    extends ConsumerState<VehicleManagementScreen> {
  void _navigateToAddVehicle() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const AddVehicleScreen(),
      ),
    );
    if (result == true) {
      await ref.read(vehiclesProvider.notifier).refresh();
    }
  }

  IconData _vehicleIcon(String type) {
    switch (type) {
      case 'car':
        return Icons.directions_car;
      case 'truck':
        return Icons.local_shipping;
      default:
        return Icons.two_wheeler;
    }
  }

  @override
  Widget build(BuildContext context) {
    final vehiclesAsync = ref.watch(vehiclesProvider);

    listenForUndoSnackbars(
      ref,
      context,
      matches: (payload) => payload is Vehicle,
    );

    return Scaffold(
      appBar: const SpendXAppBar(title: 'Manage Vehicles'),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: SpendXFAB(
        icon: Icons.add_rounded,
        label: 'Add Vehicle',
        onPressed: _navigateToAddVehicle,
      ),
      body: SafeArea(
        child: vehiclesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('Error: $error')),
          data: (vehicles) => vehicles.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.two_wheeler,
                        size: 72,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No vehicles added',
                        style: AppTextStyles.titleMedium.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap + to add your first vehicle',
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: vehicles.length,
                  itemBuilder: (_, i) {
                    final v = vehicles[i];
                    return AppCard(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.2),
                          child: Icon(
                            _vehicleIcon(v.type),
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        title: Text(v.name, style: AppTextStyles.titleSmall),
                        subtitle: Text(
                          '${TextFormatter.toSmartTitleCase(v.fuelType)}${v.regNumber != null ? ' • ${v.regNumber}' : ''}${v.tankCapacity != null ? ' • Tank: ${v.tankCapacity}L' : ''}',
                          style: AppTextStyles.bodySmall.copyWith(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.delete_outline,
                            color: Theme.of(
                              context,
                            ).colorScheme.error.withValues(alpha: 0.7),
                          ),
                          onPressed: () async {
                            // ... existing delete logic ...
                            final conf = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Delete Vehicle?'),
                                content: const Text(
                                  'This will delete the vehicle and all its fuel logs.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text(
                                      'Delete',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  ),
                                ],
                              ),
                            );
                            if (conf == true) {
                              await ref
                                  .read(vehiclesProvider.notifier)
                                  .remove(v);
                            }
                          },
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
