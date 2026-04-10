import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vehicle_providers.dart';
import '../../../models/vehicle.dart';

class AddVehicleScreen extends ConsumerStatefulWidget {
  const AddVehicleScreen({super.key});

  @override
  ConsumerState<AddVehicleScreen> createState() => _AddVehicleScreenState();
}

class _AddVehicleScreenState extends ConsumerState<AddVehicleScreen> {
  final nameCtrl = TextEditingController();
  final regCtrl = TextEditingController();
  final tankCtrl = TextEditingController();
  final serviceIntervalCtrl = TextEditingController();
  final lastServiceOdoCtrl = TextEditingController();
  String type = 'bike';
  String fuelType = 'petrol';

  @override
  void dispose() {
    nameCtrl.dispose();
    regCtrl.dispose();
    tankCtrl.dispose();
    serviceIntervalCtrl.dispose();
    lastServiceOdoCtrl.dispose();
    super.dispose();
  }

  void _saveVehicle() {
    if (nameCtrl.text.trim().isEmpty) return;

    final vehicle = Vehicle(
      id: 'veh_${DateTime.now().millisecondsSinceEpoch}',
      name: nameCtrl.text.trim(),
      type: type,
      regNumber: regCtrl.text.trim().isEmpty ? null : regCtrl.text.trim(),
      fuelType: fuelType,
      tankCapacity: double.tryParse(tankCtrl.text.trim()),
      serviceIntervalKm: double.tryParse(serviceIntervalCtrl.text.trim()),
      lastServiceOdometer: double.tryParse(lastServiceOdoCtrl.text.trim()),
    );

    ref.read(vehiclesProvider.notifier).add(vehicle);

    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Vehicle')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Vehicle Name',
                  hintText: 'e.g. My Bike',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: regCtrl,
                decoration: const InputDecoration(
                  labelText: 'Registration Number',
                  hintText: 'optional',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(
                  labelText: 'Type',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'bike', child: Text('🏍 Bike')),
                  DropdownMenuItem(value: 'car', child: Text('🚗 Car')),
                  DropdownMenuItem(value: 'truck', child: Text('🚛 Truck')),
                  DropdownMenuItem(value: 'other', child: Text('🚌 Other')),
                ],
                onChanged: (v) => setState(() => type = v!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: fuelType,
                decoration: const InputDecoration(
                  labelText: 'Fuel Type',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'petrol', child: Text('⛽ Petrol')),
                  DropdownMenuItem(value: 'diesel', child: Text('🛢 Diesel')),
                  DropdownMenuItem(
                    value: 'electric',
                    child: Text('⚡ Electric'),
                  ),
                  DropdownMenuItem(value: 'cng', child: Text('💨 CNG')),
                ],
                onChanged: (v) => setState(() => fuelType = v!),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: tankCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Fuel Tank Capacity (litres)',
                  hintText: 'e.g. 12.5',
                  prefixIcon: Icon(Icons.local_gas_station),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: serviceIntervalCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Service Interval (km)',
                  hintText: 'e.g. 5000',
                  prefixIcon: Icon(Icons.build_circle_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: lastServiceOdoCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Last Service Odometer (km)',
                  hintText: 'e.g. 12500',
                  prefixIcon: Icon(Icons.settings_backup_restore),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _saveVehicle,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                ),
                child: const Text('Save Vehicle'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
