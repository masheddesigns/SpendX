import 'package:flutter/material.dart';
import '../../models/vehicle.dart';
import '../../services/database_helper.dart';
import '../../theme/app_theme.dart';
import '../vehicles/add_vehicle_screen.dart';

class VehicleManagementScreen extends StatefulWidget {
  const VehicleManagementScreen({super.key});

  @override
  State<VehicleManagementScreen> createState() => _VehicleManagementScreenState();
}

class _VehicleManagementScreenState extends State<VehicleManagementScreen> {
  List<Vehicle> _vehicles = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadVehicles();
  }

  Future<void> _loadVehicles() async {
    setState(() => _isLoading = true);
    try {
      final v = await DatabaseHelper.instance.getAllVehicles();
      if (mounted) setState(() { _vehicles = v; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _navigateToAddVehicle() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const AddVehicleScreen(),
      ),
    );
    if (result == true) {
      _loadVehicles();
    }
  }

  IconData _vehicleIcon(String type) {
    switch (type) {
      case 'car': return Icons.directions_car;
      case 'truck': return Icons.local_shipping;
      default: return Icons.two_wheeler;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Vehicles'), backgroundColor: Colors.transparent, elevation: 0),
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToAddVehicle,
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: const Icon(Icons.add),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _vehicles.isEmpty
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.two_wheeler, size: 72, color: Colors.grey[700]),
                  const SizedBox(height: 16),
                  Text('No vehicles added', style: TextStyle(color: Colors.grey[400], fontSize: 18)),
                  const SizedBox(height: 8),
                  Text('Tap + to add your first vehicle', style: TextStyle(color: Colors.grey[600])),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _vehicles.length,
                  itemBuilder: (_, i) {
                    final v = _vehicles[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                          child: Icon(_vehicleIcon(v.type), color: Theme.of(context).colorScheme.primary),
                        ),
                        title: Text(v.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          '${v.fuelType.toUpperCase()}${v.regNumber != null ? ' • ${v.regNumber}' : ''}${v.tankCapacity != null ? ' • Tank: ${v.tankCapacity}L' : ''}',
                          style: TextStyle(color: Colors.grey[500], fontSize: 13),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.white38),
                          onPressed: () async {
                            final conf = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Delete Vehicle?'),
                                content: const Text('This will delete the vehicle and all its fuel logs.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                  TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
                                ],
                              )
                            );
                            if (conf == true) {
                              await DatabaseHelper.instance.deleteVehicle(v.id);
                              _loadVehicles();
                            }
                          },
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
