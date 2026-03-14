import 'package:flutter/material.dart';
import '../../models/vehicle.dart';
import '../../services/database_helper.dart';

class AddVehicleScreen extends StatefulWidget {
  const AddVehicleScreen({super.key});

  @override
  State<AddVehicleScreen> createState() => _AddVehicleScreenState();
}

class _AddVehicleScreenState extends State<AddVehicleScreen> {
  final nameCtrl = TextEditingController();
  final regCtrl = TextEditingController();
  final tankCtrl = TextEditingController();
  String type = 'bike';
  String fuelType = 'petrol';

  @override
  void dispose() {
    nameCtrl.dispose();
    regCtrl.dispose();
    tankCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveVehicle() async {
    if (nameCtrl.text.trim().isEmpty) return;
    
    final vehicle = Vehicle(
      name: nameCtrl.text.trim(),
      type: type,
      regNumber: regCtrl.text.trim().isEmpty ? null : regCtrl.text.trim(),
      fuelType: fuelType,
      tankCapacity: double.tryParse(tankCtrl.text.trim()),
    );
    
    await DatabaseHelper.instance.insertVehicle(vehicle);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Vehicle'),
        actions: [
          IconButton(
            icon: Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
            onPressed: _saveVehicle,
          )
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 24.0),
          child: Column(
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Vehicle Name (e.g. My Bike)'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: regCtrl,
                decoration: const InputDecoration(labelText: 'Registration Number (optional)'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: type,
                decoration: const InputDecoration(labelText: 'Type'),
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
                value: fuelType,
                decoration: const InputDecoration(labelText: 'Fuel Type'),
                items: const [
                  DropdownMenuItem(value: 'petrol', child: Text('⛽ Petrol')),
                  DropdownMenuItem(value: 'diesel', child: Text('🛢 Diesel')),
                  DropdownMenuItem(value: 'electric', child: Text('⚡ Electric')),
                  DropdownMenuItem(value: 'cng', child: Text('💨 CNG')),
                ],
                onChanged: (v) => setState(() => fuelType = v!),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: tankCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Fuel Tank Capacity (litres, optional)',
                  hintText: 'e.g. 12.5',
                  prefixIcon: Icon(Icons.local_gas_station),
                ),
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _saveVehicle,
                  icon: const Icon(Icons.check),
                  label: const Text('Save Vehicle', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
