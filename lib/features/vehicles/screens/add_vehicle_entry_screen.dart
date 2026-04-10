import 'package:flutter/material.dart';
import '../../../models/vehicle.dart';
import 'add_fuel_screen.dart';
import 'add_vehicle_expense_screen.dart';
import 'add_reminder_screen.dart';

class AddVehicleEntryScreen extends StatefulWidget {
  final String? initialVehicleId;
  final int initialTabIndex;
  final FuelLog? existingFuelLog;
  final Map<String, String?>? prefillData;
  final double? currentOdometer;

  const AddVehicleEntryScreen({
    super.key,
    this.initialVehicleId,
    this.initialTabIndex = 0,
    this.existingFuelLog,
    this.prefillData,
    this.currentOdometer,
  });

  @override
  State<AddVehicleEntryScreen> createState() => _AddVehicleEntryScreenState();
}

class _AddVehicleEntryScreenState extends State<AddVehicleEntryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTabIndex,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Vehicle Entry'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          labelColor: Theme.of(context).colorScheme.primary,
          unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
          indicatorColor: Theme.of(context).colorScheme.primary,
          indicatorSize: TabBarIndicatorSize.tab,
          tabs: const [
            Tab(text: 'Fuel'),
            Tab(text: 'Expense'),
            Tab(text: 'Reminder'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        physics:
            const NeverScrollableScrollPhysics(), // Disable swipe to prevent accidental form loss
        children: [
          AddFuelScreen(
            initialVehicleId: widget.initialVehicleId,
            existingLog: widget.existingFuelLog,
            prefillData: widget.prefillData,
            isEmbedded: true,
          ),
          AddVehicleExpenseScreen(
            vehicleId: widget.initialVehicleId ?? '', // Requires selection
            isEmbedded: true,
          ),
          AddReminderScreen(
            vehicleId: widget.initialVehicleId ?? '',
            currentOdometer: widget.currentOdometer ?? 0.0,
            isEmbedded: true,
          ),
        ],
      ),
    );
  }
}
