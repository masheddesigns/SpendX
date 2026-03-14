import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../models/vehicle.dart';
import '../../models/transaction.dart' as spx;
import '../../services/database_helper.dart';
import '../../widgets/custom_snackbar.dart';
import '../../services/gemini_service.dart';
import '../../utils/app_format.dart';
import '../expense/add_expense_screen.dart';

import 'package:image_picker/image_picker.dart';
import 'dart:io' as dart_io;

class AddFuelScreen extends StatefulWidget {
  final String? initialVehicleId;
  final FuelLog? existingLog;
  final Map<String, String?>? prefillData;

  const AddFuelScreen({
    super.key,
    this.initialVehicleId,
    this.existingLog,
    this.prefillData,
  });

  @override
  State<AddFuelScreen> createState() => _AddFuelScreenState();
}

class _AddFuelScreenState extends State<AddFuelScreen> {
  // Data
  List<Vehicle> _vehicles = [];
  String? _selectedVehicleId;
  List<FuelLog> _currentLogs = [];
  
  bool _isLoading = true;

  // Form Controls
  late TextEditingController odoCtrl;
  late TextEditingController litresCtrl;
  late TextEditingController priceCtrl;
  late TextEditingController costCtrl;
  late TextEditingController locCtrl;
  late TextEditingController notesCtrl;

  late DateTime selectedDate;
  late TimeOfDay selectedTime;
  late bool isFullTank;

  double? lastOdo;

  // Focus nodes
  final litresFocus = FocusNode();
  final priceFocus = FocusNode();
  final costFocus = FocusNode();
  bool isCalculating = false;

  String _activeField = '';
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

    litresFocus.addListener(() { if (litresFocus.hasFocus) _setFocused('litres'); });
    priceFocus.addListener(() { if (priceFocus.hasFocus) _setFocused('price'); });
    costFocus.addListener(() { if (costFocus.hasFocus) _setFocused('cost'); });

    // AI Prefill
    if (widget.prefillData != null) {
      if (widget.prefillData!['amount'] != null) {
        final cleanAmt = widget.prefillData!['amount']!.replaceAll(RegExp(r'[^0-9.]'), '');
        costCtrl.text = cleanAmt;
      }
      if (widget.prefillData!['merchant'] != null) {
        locCtrl.text = widget.prefillData!['merchant']!;
      }
    }

    litresCtrl.addListener(_updateCalculation);
    priceCtrl.addListener(_updateCalculation);
    costCtrl.addListener(_updateCalculation);

    _loadData();
  }

  Future<void> _loadData() async {
    final v = await DatabaseHelper.instance.getAllVehicles();
    
    if (_selectedVehicleId == null && v.isNotEmpty) {
      _selectedVehicleId = v.first.id;
    }

    if (_selectedVehicleId != null) {
      _currentLogs = await DatabaseHelper.instance.getFuelLogsForVehicle(_selectedVehicleId!);
      
      // Find last Odo
      lastOdo = null;
      if (widget.existingLog == null && _currentLogs.isNotEmpty) {
        lastOdo = _currentLogs.first.odometer;
      } else if (widget.existingLog != null) {
        for (final log in _currentLogs) {
          if (log.id != widget.existingLog!.id && log.date.isBefore(widget.existingLog!.date)) {
            lastOdo = log.odometer;
            break;
          }
        }
      }
    }

    if (mounted) {
      setState(() {
        _vehicles = v;
        _isLoading = false;
      });
    }
  }

  void _updateCalculation() {
    if (isCalculating) return;
    isCalculating = true;

    final lText = litresCtrl.text.trim();
    final pText = priceCtrl.text.trim();
    final cText = costCtrl.text.trim();

    final l = double.tryParse(lText);
    final p = double.tryParse(pText);
    final c = double.tryParse(cText);

    String target = '';
    if (_activeField.isEmpty) {
      // Not focused yet, maybe initial load. Do nothing.
    } else if (_previousField.isEmpty) {
      // First field focused.
      if (_activeField == 'litres') target = 'cost';
      else if (_activeField == 'price') target = 'cost';
      else if (_activeField == 'cost') target = 'price';
    } else {
      const all = ['litres', 'price', 'cost'];
      target = all.firstWhere((f) => f != _activeField && f != _previousField, orElse: () => '');
    }

    if (target == 'cost' && l != null && p != null) {
      final val = (l * p).toStringAsFixed(2);
      if (costCtrl.text != val) costCtrl.text = val;
    } else if (target == 'price' && c != null && l != null && l > 0) {
      final val = (c / l).toStringAsFixed(2);
      if (priceCtrl.text != val) priceCtrl.text = val;
    } else if (target == 'litres' && c != null && p != null && p > 0) {
      final val = (c / p).toStringAsFixed(2);
      if (litresCtrl.text != val) litresCtrl.text = val;
    }
    
    isCalculating = false;
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

  Future<void> _save() async {
    if (_selectedVehicleId == null) {
       CustomSnackBar.show(context, message: 'Please select a vehicle', isError: true);
       return;
    }
    
    final odo = double.tryParse(odoCtrl.text.trim());
    final litres = double.tryParse(litresCtrl.text.trim());
    final cost = double.tryParse(costCtrl.text.trim());
    final price = double.tryParse(priceCtrl.text.trim()) ?? (cost != null && litres != null ? cost/litres : 0.0);
    
    if (odo == null || litres == null || cost == null || litres == 0) return;

    if (lastOdo != null && odo <= lastOdo!) {
      CustomSnackBar.show(context, message: 'Odometer must be > ${lastOdo!.toStringAsFixed(0)} km', isError: true);
      return;
    }

    // Validate against tank capacity if known
    // (Soft warning only - manufacturers leave reserve space, so we allow up to 1.25x capacity)
    final selectedVehicle = _vehicles.firstWhere((v) => v.id == _selectedVehicleId, orElse: () => _vehicles.first);
    if (selectedVehicle.tankCapacity != null && litres > selectedVehicle.tankCapacity! * 1.25) {
      CustomSnackBar.show(context, message: 'Warning: ${litres.toStringAsFixed(1)}L seems very high for a ${selectedVehicle.tankCapacity}L tank.', isError: true);
      // Don't block saving - just warn
    }

    // Calculate efficiency from the PREVIOUS log (any fill-up, not just full tank)
    // km driven since last log / litres used this fill-up
    double? efficiency;
    if (_currentLogs.isNotEmpty) {
      final finalDateTime = DateTime(selectedDate.year, selectedDate.month, selectedDate.day, selectedTime.hour, selectedTime.minute);
      for (final prev in _currentLogs) {
        if (widget.existingLog != null && prev.id == widget.existingLog!.id) continue;
        if (prev.date.isBefore(finalDateTime)) {
          final km = odo - prev.odometer;
          if (km > 0 && litres > 0) efficiency = km / litres;
          break;
        }
      }
    }

    final finalDateTime = DateTime(selectedDate.year, selectedDate.month, selectedDate.day, selectedTime.hour, selectedTime.minute);

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
      notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
    );

    if (widget.existingLog == null) {
      await DatabaseHelper.instance.insertFuelLog(newLog);
    } else {
      await DatabaseHelper.instance.updateFuelLog(newLog);
    }
    
    if (mounted) Navigator.pop(context, true);
  }

  Widget _buildTypeToggle() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AddExpenseScreen(initialType: 'expense')));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(color: Colors.transparent, borderRadius: BorderRadius.circular(16)),
                alignment: Alignment.center,
                child: Text('Expense', style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AddExpenseScreen(initialType: 'income')));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(color: Colors.transparent, borderRadius: BorderRadius.circular(16)),
                alignment: Alignment.center,
                child: Text('Income', style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondary, borderRadius: BorderRadius.circular(16)),
              alignment: Alignment.center,
              child: Text('Fuel', style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSecondary)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existingLog == null ? 'Log Fuel' : 'Edit Fuel Log'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.receipt_long, color: Theme.of(context).colorScheme.onSurfaceVariant),
            tooltip: 'Scan Receipt',
            onPressed: _scanReceipt,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_vehicles.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                color: Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
                child: Text('Add a vehicle in Settings before logging fuel.', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              )
            else ...[
              if (widget.existingLog == null) ...[
                _buildTypeToggle(),
                const SizedBox(height: 16),
              ],
              
              DropdownButtonFormField<String>(
                value: _selectedVehicleId,
                dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16),
                decoration: InputDecoration(
                  labelText: 'Selected Vehicle',
                  labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  border: InputBorder.none,
                  prefixIcon: Icon(Icons.directions_car, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  prefixIconConstraints: const BoxConstraints(minWidth: 40),
                ),
                items: _vehicles.map((v) => DropdownMenuItem(value: v.id, child: Text(v.name))).toList(),
                onChanged: widget.existingLog != null ? null : (v) {
                  setState(() { _selectedVehicleId = v; _loadData(); });
                },
              ),
              const Divider(color: Colors.white12, height: 16),
              const SizedBox(height: 8),
              
              // ODOMETER — mandatory, second position
              Builder(builder: (context) {
                final selectedVehicle = _vehicles.firstWhere(
                  (v) => v.id == _selectedVehicleId,
                  orElse: () => _vehicles.first,
                );
                return TextField(
                  controller: odoCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 22, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    labelText: 'Odometer Reading (km) *',
                    labelStyle: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
                    border: InputBorder.none,
                    prefixIcon: Icon(Icons.speed, color: Theme.of(context).colorScheme.primary),
                    prefixIconConstraints: const BoxConstraints(minWidth: 40),
                    helperText: lastOdo != null
                        ? 'Last reading: ${lastOdo!.toStringAsFixed(0)} km  •  Required to track mileage'
                        : 'Enter your current odometer reading  •  Required',
                    helperStyle: TextStyle(color: Theme.of(context).colorScheme.primary),
                  ),
                );
              }),
              const Divider(color: Colors.white12, height: 24),
              const SizedBox(height: 8),
              
              // Total Cost Input
              Text('Total Cost', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
              const SizedBox(height: 8),
              TextField(
                controller: costCtrl,
                focusNode: costFocus,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(fontSize: 48, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary),
                decoration: InputDecoration(
                  prefixText: '${AppFormat.currencySymbol} ',
                  prefixStyle: TextStyle(fontSize: 48, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
                  border: InputBorder.none,
                  hintText: '0.00',
                  hintStyle: TextStyle(color: Theme.of(context).colorScheme.outlineVariant),
                ),
              ),
              
              const Divider(color: Colors.white12, height: 40),
              
              // Litres & Price/L — with optional fill % badge
              Builder(builder: (context) {
                final selectedVehicle = _vehicles.firstWhere(
                  (v) => v.id == _selectedVehicleId,
                  orElse: () => _vehicles.first,
                );
                final tankCap = selectedVehicle.tankCapacity;
                final filledLitres = double.tryParse(litresCtrl.text.trim());
                final fillRaw = (tankCap != null && filledLitres != null && tankCap > 0)
                    ? filledLitres / tankCap * 100
                    : null;
                final fillPct = fillRaw;
                final isOverfill = fillRaw != null && fillRaw > 100;
                return Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text('Litres', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
                            if (fillPct != null) ...[
                              const SizedBox(width: 6),
                              Flexible(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isOverfill
                                        ? Theme.of(context).colorScheme.error.withValues(alpha: 0.2)
                                        : fillPct >= 90
                                            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                                            : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: isOverfill ? Theme.of(context).colorScheme.error : fillPct >= 90 ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.secondary,
                                      width: 0.5,
                                    ),
                                  ),
                                  child: Text(
                                    isOverfill
                                        ? '${fillPct!.toStringAsFixed(0)}% over!'
                                        : '${fillPct!.toStringAsFixed(0)}% full',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: isOverfill ? Theme.of(context).colorScheme.error : fillPct >= 90 ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.secondary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ]),
                          const SizedBox(height: 8),
                          TextField(
                            controller: litresCtrl,
                            focusNode: litresFocus,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface),
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText: tankCap != null ? 'Max ${tankCap}L' : '0.0',
                              hintStyle: TextStyle(color: Theme.of(context).colorScheme.outlineVariant),
                              suffixText: 'L',
                              suffixStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 16),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(width: 1, height: 40, color: Colors.white12),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Price/L', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
                          const SizedBox(height: 8),
                          TextField(
                            controller: priceCtrl,
                            focusNode: priceFocus,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText: '0.00',
                              hintStyle: TextStyle(color: Theme.of(context).colorScheme.outlineVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }),
              const Divider(color: Colors.white12, height: 16),
              
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Date & Time', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16)),
                subtitle: Text('${DateFormat('EEEE, MMMM d, yyyy').format(selectedDate)} • ${selectedTime.format(context)}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                trailing: Icon(Icons.calendar_today, color: Theme.of(context).colorScheme.primary),
                onTap: () async {
                  final pickedDate = await showDatePicker(context: context, initialDate: selectedDate, firstDate: DateTime(2000), lastDate: DateTime.now());
                  if (pickedDate != null) {
                    setState(() => selectedDate = pickedDate);
                    if (mounted) {
                      final pickedTime = await showTimePicker(context: context, initialTime: selectedTime);
                      if (pickedTime != null) setState(() => selectedTime = pickedTime);
                    }
                  }
                },
              ),
              const Divider(color: Colors.white12, height: 16),
              
              TextField(
                controller: locCtrl, 
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16),
                decoration: InputDecoration(
                  labelText: 'Location / Station', 
                  labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  border: InputBorder.none, 
                  prefixIcon: Icon(Icons.location_on, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  prefixIconConstraints: const BoxConstraints(minWidth: 40),
                )
              ),
              const Divider(color: Colors.white12, height: 16),
              
              TextField(
                controller: notesCtrl, 
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16),
                decoration: InputDecoration(
                  labelText: 'Notes (Optional)', 
                  labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  border: InputBorder.none,
                  prefixIcon: Icon(Icons.notes, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  prefixIconConstraints: const BoxConstraints(minWidth: 40),
                )
              ),
              const Divider(color: Colors.white12, height: 16),
              
              SwitchListTile(
                title: Text('Full Tank?', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16)),
                subtitle: Text('Needed for accurate mileage', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                value: isFullTank,
                onChanged: (v) => setState(() => isFullTank = v),
                contentPadding: EdgeInsets.zero,
                activeColor: Theme.of(context).colorScheme.primary,
              ),
              
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    _save();
                  },
                  child: const Text('Save Fuel Log', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Future<void> _scanReceipt() async {
    final picker = ImagePicker();
    final choice = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 16),
        Text('Scan Fuel Receipt', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 8),
        ListTile(
          leading: Icon(Icons.camera_alt, color: Theme.of(context).colorScheme.primary),
          title: const Text('Take Photo'),
          onTap: () => Navigator.pop(context, ImageSource.camera),
        ),
        ListTile(
          leading: Icon(Icons.photo_library, color: Theme.of(context).colorScheme.secondary),
          title: const Text('Choose from Gallery'),
          onTap: () => Navigator.pop(context, ImageSource.gallery),
        ),
        const SizedBox(height: 16),
      ]),
    );

    if (choice == null) return;

    final picked = await picker.pickImage(source: choice, imageQuality: 80);
    if (picked == null) return;

    CustomSnackBar.show(context, message: 'Reading fuel receipt with AI...');

    GeminiService.instance.init();
    final result = await GeminiService.instance.scanReceipt(dart_io.File(picked.path));

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (result.containsKey('error')) {
      CustomSnackBar.show(context, message: 'Could not read receipt: ${result['error']}', isError: true);
      return;
    }

    // Auto-fill form
    setState(() {
      if (result['amount'] != null) {
        final cleanAmt = result['amount']!.replaceAll(RegExp(r'[^0-9.]'), '');
        costCtrl.text = cleanAmt;
      }
      if (result['merchant'] != null) {
        locCtrl.text = result['merchant']!;
      }
      if (result['date'] != null) {
        try {
          selectedDate = DateTime.parse(result['date']!);
        } catch (_) {}
      }
    });

    CustomSnackBar.show(context, message: '✓ Receipt scanned! Please verify the details.');
  }
}
