// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vehicle_providers.dart';
import '../../../models/vehicle.dart';
import '../../../services/haptic_service.dart';
import '../../../screens/expense/add_expense_screen.dart';

class AddFuelScreen extends ConsumerStatefulWidget {
  final String? initialVehicleId;
  final FuelLog? existingLog;
  final Map<String, String?>? prefillData;
  final bool isEmbedded;

  const AddFuelScreen({
    super.key,
    this.initialVehicleId,
    this.existingLog,
    this.prefillData,
    this.isEmbedded = false,
  });

  @override
  ConsumerState<AddFuelScreen> createState() => _AddFuelScreenState();
}

class _AddFuelScreenState extends ConsumerState<AddFuelScreen> {
  String? _selectedVehicleId;

  late TextEditingController odoCtrl;
  late TextEditingController litresCtrl;
  late TextEditingController priceCtrl;
  late TextEditingController costCtrl;
  late TextEditingController locCtrl;
  late TextEditingController notesCtrl;

  late DateTime selectedDate;
  late TimeOfDay selectedTime;
  late bool isFullTank;
  String _selectedFuelType = 'Petrol';

  final litresFocus = FocusNode();
  final priceFocus = FocusNode();
  final costFocus = FocusNode();
  bool isCalculating = false;

  String _activeField = '';
  // ignore: unused_field
  String _previousField = '';

  void _setFocused(String field) {
    if (_activeField != field) {
      _previousField = _activeField;
      _activeField = field;
    }
  }

  @override
  void initState() {
    super.initState();
    final e = widget.existingLog;
    odoCtrl = TextEditingController(text: e?.odometer.toString() ?? '');
    litresCtrl = TextEditingController(text: e?.litres.toString() ?? '');
    priceCtrl = TextEditingController(text: e?.pricePerLitre.toString() ?? '');
    costCtrl = TextEditingController(text: e?.totalCost.toString() ?? '');
    locCtrl = TextEditingController(text: e?.location ?? '');
    notesCtrl = TextEditingController(text: e?.notes ?? '');

    selectedDate = e?.date ?? DateTime.now();
    selectedTime = e != null ? TimeOfDay.fromDateTime(e.date) : TimeOfDay.now();
    isFullTank = e?.isFullTank ?? true;

    _selectedVehicleId = widget.initialVehicleId ?? e?.vehicleId;

    litresFocus.addListener(() {
      if (litresFocus.hasFocus) _setFocused('litres');
    });
    priceFocus.addListener(() {
      if (priceFocus.hasFocus) _setFocused('price');
    });
    costFocus.addListener(() {
      if (costFocus.hasFocus) _setFocused('cost');
    });

    if (widget.prefillData != null) {
      if (widget.prefillData!['amount'] != null) {
        final cleanAmt = widget.prefillData!['amount']!.replaceAll(
          RegExp(r'[^0-9.]'),
          '',
        );
        costCtrl.text = cleanAmt;
      }
      if (widget.prefillData!['merchant'] != null) {
        locCtrl.text = widget.prefillData!['merchant']!;
      }
    }

    litresCtrl.addListener(_updateCalculation);
    priceCtrl.addListener(_updateCalculation);
    costCtrl.addListener(_updateCalculation);

    odoCtrl.addListener(() => setState(() {}));
    litresCtrl.addListener(() => setState(() {}));
    costCtrl.addListener(() => setState(() {}));
  }

  bool get _isValid {
    if (_selectedVehicleId == null) return false;
    final odo = double.tryParse(odoCtrl.text.trim()) ?? 0;
    final litres = double.tryParse(litresCtrl.text.trim()) ?? 0;
    final cost = double.tryParse(costCtrl.text.trim()) ?? 0;

    if (odo <= 0 || litres <= 0 || cost <= 0) return false;
    return true;
  }

  void _updateCalculation() {
    if (isCalculating) return;

    final l = double.tryParse(litresCtrl.text.trim());
    final p = double.tryParse(priceCtrl.text.trim());
    final c = double.tryParse(costCtrl.text.trim());

    if (l == null || l <= 0) return;

    isCalculating = true;
    try {
      if (_activeField == 'litres') {
        if (p != null && p > 0) {
          costCtrl.text = (l * p).toStringAsFixed(2);
        } else if (c != null && c > 0) {
          priceCtrl.text = (c / l).toStringAsFixed(2);
        }
      } else if (_activeField == 'price') {
        if (l > 0) {
          costCtrl.text = (l * p!).toStringAsFixed(2);
        }
      } else if (_activeField == 'cost') {
        if (l > 0) {
          priceCtrl.text = (c! / l).toStringAsFixed(2);
        }
      }
    } finally {
      isCalculating = false;
    }
  }

  @override
  void dispose() {
    odoCtrl.dispose();
    litresCtrl.dispose();
    priceCtrl.dispose();
    costCtrl.dispose();
    locCtrl.dispose();
    notesCtrl.dispose();
    litresFocus.dispose();
    priceFocus.dispose();
    costFocus.dispose();
    super.dispose();
  }

  void _save(
    List<Vehicle> vehicles,
    List<FuelLog> currentLogs,
    double? lastOdo,
  ) {
    if (_selectedVehicleId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a vehicle')));
      return;
    }

    final odo = double.tryParse(odoCtrl.text.trim());
    final litres = double.tryParse(litresCtrl.text.trim());
    final cost = double.tryParse(costCtrl.text.trim());
    final price =
        double.tryParse(priceCtrl.text.trim()) ??
        (cost != null && litres != null ? cost / litres : 0.0);

    if (odo == null || litres == null || cost == null || litres == 0) return;

    if (lastOdo != null && odo <= lastOdo) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Odometer must be > ${lastOdo.toStringAsFixed(0)} km'),
        ),
      );
      return;
    }

    final selectedVehicle = vehicles.firstWhere(
      (v) => v.id == _selectedVehicleId,
      orElse: () => vehicles.first,
    );
    if (selectedVehicle.tankCapacity != null &&
        litres > selectedVehicle.tankCapacity! * 1.25) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Warning: ${litres.toStringAsFixed(1)}L seems very high for a ${selectedVehicle.tankCapacity}L tank.',
          ),
        ),
      );
    }

    double? efficiency;
    if (currentLogs.isNotEmpty) {
      final finalDateTime = DateTime(
        selectedDate.year,
        selectedDate.month,
        selectedDate.day,
        selectedTime.hour,
        selectedTime.minute,
      );
      for (final prev in currentLogs) {
        if (widget.existingLog != null && prev.id == widget.existingLog!.id) {
          continue;
        }
        if (prev.date.isBefore(finalDateTime)) {
          final km = odo - prev.odometer;
          if (km > 0 && litres > 0) {
            efficiency = km / litres;
          }
          break;
        }
      }
    }

    final finalDateTime = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );

    final newLog = FuelLog(
      id: widget.existingLog?.id,
      vehicleId: _selectedVehicleId!,
      odometer: odo,
      litres: litres,
      pricePerLitre: price,
      totalCost: cost,
      efficiency: efficiency,
      date: finalDateTime,
      location: locCtrl.text.trim().isEmpty ? null : locCtrl.text.trim(),
      isFullTank: isFullTank,
      fuelType: _selectedFuelType,
      notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
    );

    final notifier = ref.read(
      vehicleFuelLogsProvider(newLog.vehicleId).notifier,
    );
    if (widget.existingLog == null) {
      notifier.add(newLog);
    } else {
      notifier.replace(newLog);
    }

    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  Widget _buildTypeToggle() {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () {
                HapticService.instance.selection();
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const AddExpenseScreen(initialType: 'expense'),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.center,
                child: Text(
                  'Expense',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () {
                HapticService.instance.selection();
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const AddExpenseScreen(initialType: 'income'),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.center,
                child: Text(
                  'Income',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondary,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(
                'Fuel',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vehiclesAsync = ref.watch(vehiclesProvider);

    return vehiclesAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
      data: (vehicles) {
        if (_selectedVehicleId == null && vehicles.isNotEmpty) {
          _selectedVehicleId = vehicles.first.id;
        }

        final logsAsync = _selectedVehicleId != null
            ? ref.watch(
                fuelLogsProvider((
                  vehicleId: _selectedVehicleId!,
                  limit: 100,
                  offset: 0,
                )),
              )
            : const AsyncData<List<FuelLog>>([]);

        return logsAsync.when(
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
          data: (currentLogs) {
            double? lastOdo;
            if (widget.existingLog == null && currentLogs.isNotEmpty) {
              lastOdo = currentLogs.first.odometer;
            } else if (widget.existingLog != null) {
              for (final log in currentLogs) {
                if (log.id != widget.existingLog!.id &&
                    log.date.isBefore(widget.existingLog!.date)) {
                  lastOdo = log.odometer;
                  break;
                }
              }
            }

            final selectedVehicle = vehicles.isNotEmpty
                ? vehicles.firstWhere(
                    (v) => v.id == _selectedVehicleId,
                    orElse: () => vehicles.first,
                  )
                : null;

            return Scaffold(
              backgroundColor: widget.isEmbedded ? Colors.transparent : null,
              appBar: widget.isEmbedded
                  ? null
                  : AppBar(title: const Text('Fuel Log')),
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (vehicles.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(16.0),
                          color: Theme.of(
                            context,
                          ).colorScheme.error.withValues(alpha: 0.1),
                          child: Text(
                            'Add a vehicle in Settings before logging fuel.',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        )
                      else ...[
                        if (widget.existingLog == null &&
                            !widget.isEmbedded) ...[
                          _buildTypeToggle(),
                          const SizedBox(height: 16),
                        ],
                        DropdownButtonFormField<String>(
                          initialValue: _selectedVehicleId,
                          decoration: const InputDecoration(
                            labelText: 'Selected Vehicle',
                            prefixIcon: Icon(Icons.directions_car_rounded),
                            border: OutlineInputBorder(),
                          ),
                          items: vehicles
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v.id,
                                  child: Text(v.name),
                                ),
                              )
                              .toList(),
                          onChanged: widget.existingLog != null
                              ? null
                              : (v) {
                                  if (v != null) {
                                    setState(() {
                                      _selectedVehicleId = v;
                                    });
                                  }
                                },
                        ),
                        const SizedBox(height: 16),

                        Text(
                          'Odometer Reading (km) *',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: odoCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: lastOdo != null
                                ? 'Last reading: ${lastOdo.toStringAsFixed(0)} km'
                                : 'Current reading',
                            prefixIcon: const Icon(Icons.speed_rounded),
                            border: const OutlineInputBorder(),
                          ),
                        ),

                        const SizedBox(height: 16),
                        Text(
                          'Total Cost',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: costCtrl,
                          focusNode: costFocus,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Total Cost',
                            prefixIcon: Icon(Icons.attach_money),
                            border: OutlineInputBorder(),
                          ),
                        ),

                        const Divider(height: 40),

                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Litres',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelLarge,
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: litresCtrl,
                                    focusNode: litresFocus,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: InputDecoration(
                                      labelText:
                                          selectedVehicle?.tankCapacity != null
                                          ? 'Max ${selectedVehicle!.tankCapacity}L'
                                          : 'Litres',
                                      border: const OutlineInputBorder(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Price/L',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelLarge,
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: priceCtrl,
                                    focusNode: priceFocus,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: 'Price/L',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 16),

                        Text(
                          'Fuel Type',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          initialValue: _selectedFuelType,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                          ),
                          items:
                              ['Petrol', 'Diesel', 'CNG', 'Electric', 'Other']
                                  .map(
                                    (t) => DropdownMenuItem(
                                      value: t,
                                      child: Text(t),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (v) {
                            HapticService.instance.selection();
                            setState(() => _selectedFuelType = v ?? 'Petrol');
                          },
                        ),

                        const SizedBox(height: 16),

                        SwitchListTile(
                          title: const Text('Full Tank?'),
                          subtitle: const Text('Needed for accurate mileage'),
                          value: isFullTank,
                          onChanged: (v) {
                            HapticService.instance.selection();
                            setState(() => isFullTank = v);
                          },
                          contentPadding: EdgeInsets.zero,
                          activeThumbColor: Theme.of(context).colorScheme.primary,
                        ),

                        const SizedBox(height: 16),

                        Text(
                          'Date & Time',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Date & Time'),
                          subtitle: Text(
                            '${selectedDate.day}/${selectedDate.month}/${selectedDate.year} ${selectedTime.format(context)}',
                          ),
                          trailing: const Icon(Icons.calendar_today),
                          onTap: () async {
                            final pickedDate = await showDatePicker(
                              context: context,
                              initialDate: selectedDate,
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (pickedDate != null && mounted) {
                              setState(() => selectedDate = pickedDate);
                              final pickedTime = await showTimePicker(
                                context: context,
                                initialTime: selectedTime,
                              );
                              if (pickedTime != null) {
                                setState(() => selectedTime = pickedTime);
                              }
                            }
                          },
                        ),

                        const SizedBox(height: 16),

                        TextField(
                          controller: locCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Location / Station',
                            prefixIcon: Icon(Icons.location_on_rounded),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: notesCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Notes (Optional)',
                            prefixIcon: Icon(Icons.notes_rounded),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ],
                  ),
                ),
              ),
              bottomNavigationBar: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: _isValid
                              ? () => _save(vehicles, currentLogs, lastOdo)
                              : null,
                          child: const Text('Save Fuel Log'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

}
