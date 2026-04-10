// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../providers/vehicle_providers.dart';
import '../../../models/vehicle_reminder.dart';
import '../services/vehicle_reminder_service.dart';
import '../../../widgets/custom_snackbar.dart';

class AddReminderScreen extends ConsumerStatefulWidget {
  final String vehicleId;
  final double currentOdometer;
  final VehicleReminder? existing;
  final bool isEmbedded;

  const AddReminderScreen({
    super.key,
    required this.vehicleId,
    required this.currentOdometer,
    this.existing,
    this.isEmbedded = false,
  });

  @override
  ConsumerState<AddReminderScreen> createState() => _AddReminderScreenState();
}

class _AddReminderScreenState extends ConsumerState<AddReminderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _dueOdoCtrl = TextEditingController();
  final _intervalCtrl = TextEditingController();
  final _recurrenceCountCtrl = TextEditingController();

  ReminderType _type = ReminderType.dateBased;
  DateTime? _dueDate;
  String? _recurrencePeriod;
  String _recurrenceUnit = 'm';
  bool _useInterval = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final r = widget.existing;
    if (r != null) {
      _titleCtrl.text = r.title;
      _notesCtrl.text = r.notes ?? '';
      _type = r.type;
      _dueDate = r.dueDate;
      _recurrencePeriod = r.recurrencePeriod;
      if (_recurrencePeriod != null) {
        final match = RegExp(r'^(\d+)([dwmy])$').firstMatch(_recurrencePeriod!);
        if (match != null) {
          _recurrenceCountCtrl.text = match.group(1)!;
          _recurrenceUnit = match.group(2)!;
        } else {
          _recurrenceCountCtrl.text = '1';
        }
      } else {
        _recurrenceCountCtrl.text = '1';
      }
      _dueOdoCtrl.text = r.dueOdometer?.toStringAsFixed(0) ?? '';
      _intervalCtrl.text = r.intervalKm?.toStringAsFixed(0) ?? '';
      _useInterval = r.intervalKm != null;
    }

    _titleCtrl.addListener(() => setState(() {}));
  }

  bool get _isValid => _titleCtrl.text.trim().isNotEmpty;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    _dueOdoCtrl.dispose();
    _intervalCtrl.dispose();
    _recurrenceCountCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      String? finalRecurrence;
      if (_recurrencePeriod != null) {
        final countStr = _recurrenceCountCtrl.text.trim();
        finalRecurrence = '${countStr.isEmpty ? '1' : countStr}$_recurrenceUnit';
      }

      final reminder = VehicleReminder(
        id: widget.existing?.id,
        vehicleId: widget.vehicleId,
        title: _titleCtrl.text.trim(),
        type: _type,
        dueDate: _dueDate,
        recurrencePeriod: finalRecurrence,
        dueOdometer: _useInterval ? null : double.tryParse(_dueOdoCtrl.text),
        intervalKm: _useInterval ? double.tryParse(_intervalCtrl.text) : null,
        lastTriggeredOdometer: _useInterval ? widget.currentOdometer : null,
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      );
      await VehicleReminderService.instance.saveReminder(reminder);

      // Invalidate providers
      ref.invalidate(vehiclesProvider);
      ref.invalidate(vehicleDetailProvider);
      
      if (mounted) {
        CustomSnackBar.show(context, message: '✅ Reminder saved');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) CustomSnackBar.show(context, message: 'Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isEdit = widget.existing != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit Reminder' : 'Add Reminder'),
        actions: [
          IconButton(
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            // Title
            Text('Reminder Title', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1, color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 8),
            TextFormField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                hintText: 'e.g. Engine Service, Chain Lube',
                prefixIcon: Icon(Icons.notifications_outlined),
              ),
            ),
            const SizedBox(height: 16),

            // Reminder Type
            Text('REMINDER TYPE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1, color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 8),
            _typeSelector(cs),
            const SizedBox(height: 16),

            // Date picker
            if (_type == ReminderType.dateBased || _type == ReminderType.hybrid) ...[
              Text('DUE DATE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1, color: Theme.of(context).colorScheme.primary)),
              const SizedBox(height: 8),
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.outline),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.calendar_today, color: cs.primary),
                      const SizedBox(width: 12),
                      Text(
                        _dueDate != null
                            ? DateFormat('dd MMM yyyy').format(_dueDate!)
                            : 'Select date',
                        style: TextStyle(
                          color: _dueDate != null ? null : cs.outline,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                title: Text('Repeat automatically', style: Theme.of(context).textTheme.bodyMedium),
                subtitle: Text('Insurance renewal every 1 year', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                value: _recurrencePeriod != null,
                onChanged: (v) {
                  setState(() => _recurrencePeriod = v ? '1y' : null);
                },
                contentPadding: EdgeInsets.zero,
              ),
              if (_recurrencePeriod != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _recurrenceCountCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Every',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            prefixIcon: const Icon(Icons.update),
                          ),
                          validator: (v) {
                            if (_recurrencePeriod != null) {
                              if (v == null || int.tryParse(v) == null || int.parse(v) <= 0) {
                                return 'Invalid num';
                              }
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 3,
                        child: DropdownButtonFormField<String>(
                          initialValue: _recurrenceUnit,
                          decoration: InputDecoration(
                            labelText: 'Time Unit',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          items: const [
                            DropdownMenuItem(value: 'd', child: Text('Days')),
                            DropdownMenuItem(value: 'w', child: Text('Weeks')),
                            DropdownMenuItem(value: 'm', child: Text('Months')),
                            DropdownMenuItem(value: 'y', child: Text('Years')),
                          ],
                          onChanged: (v) => setState(() => _recurrenceUnit = v!),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
            ],

            // Odometer
            if (_type == ReminderType.odoBased || _type == ReminderType.hybrid) ...[
              Text('ODOMETER TRIGGER', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1, color: Theme.of(context).colorScheme.primary)),
              const SizedBox(height: 8),
              Card(
                color: cs.surfaceContainerHigh,
                child: Column(
                  children: [
                    RadioListTile<bool>(
                      title: const Text('Due at specific km', style: TextStyle(fontSize: 14)),
                      subtitle: const Text('Triggers once when odometer reaches target'),
                      value: false,
                      groupValue: _useInterval,
                      onChanged: (v) => setState(() => _useInterval = v!),
                    ),
                    RadioListTile<bool>(
                      title: const Text('Repeat every X km', style: TextStyle(fontSize: 14)),
                      subtitle: const Text('Service every 5,000 km, chain lube every 600 km…'),
                      value: true,
                      groupValue: _useInterval,
                      onChanged: (v) => setState(() => _useInterval = v!),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (!_useInterval)
                TextFormField(
                  controller: _dueOdoCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Due at km',
                    hintText: 'e.g. ${(widget.currentOdometer + 5000).toStringAsFixed(0)}',
                    prefixIcon: const Icon(Icons.speed),
                  ),
                )
              else
                TextFormField(
                  controller: _intervalCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Every X km',
                    hintText: 'e.g. 5000',
                    prefixIcon: Icon(Icons.loop),
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'Current odometer: ${widget.currentOdometer.toStringAsFixed(0)} km',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
            ],

            // Notes
            Text('Notes (optional)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1, color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 8),
            TextFormField(
              controller: _notesCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                hintText: 'Add some details...',
                prefixIcon: Icon(Icons.notes),
              ),
            ),
            const SizedBox(height: 24),

            // Quick presets
            Text('QUICK PRESETS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1, color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _preset('Engine Service', 5000),
                _preset('Oil Change', 3000),
                _preset('Chain Lube', 600),
                _preset('Tyre Check', 2000),
                _preset('Air Filter', 8000),
                _presetDate('Insurance Renewal', '1y'),
                _presetDate('PUC Certificate', '6m'),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  child: const Text('Cancel', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: (!_saving && _isValid) ? _save : null,
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save Reminder', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typeSelector(ColorScheme cs) {
    return SegmentedButton<ReminderType>(
      segments: const [
        ButtonSegment(value: ReminderType.dateBased, label: Text('Date'), icon: Icon(Icons.calendar_month, size: 16)),
        ButtonSegment(value: ReminderType.odoBased, label: Text('Odometer'), icon: Icon(Icons.speed, size: 16)),
        ButtonSegment(value: ReminderType.hybrid, label: Text('Both'), icon: Icon(Icons.merge, size: 16)),
      ],
      selected: {_type},
      onSelectionChanged: (s) => setState(() => _type = s.first),
    );
  }

  Widget _preset(String title, double intervalKm) {
    return ActionChip(
      label: Text('$title (${intervalKm.toStringAsFixed(0)} km)'),
      onPressed: () {
        setState(() {
          _titleCtrl.text = title;
          _type = ReminderType.odoBased;
          _useInterval = true;
          _intervalCtrl.text = intervalKm.toStringAsFixed(0);
        });
      },
    );
  }

  Widget _presetDate(String title, String recurrencePeriod) {
    String pStr = recurrencePeriod;
    final match = RegExp(r'^(\d+)([dwmy])$').firstMatch(recurrencePeriod);
    if (match != null) {
        final count = int.parse(match.group(1)!);
        final unit = match.group(2)!;
        String unitName = '';
        switch (unit) {
          case 'd': unitName = count == 1 ? 'Day' : 'Days'; break;
          case 'w': unitName = count == 1 ? 'Week' : 'Weeks'; break;
          case 'm': unitName = count == 1 ? 'Month' : 'Months'; break;
          case 'y': unitName = count == 1 ? 'Year' : 'Years'; break;
        }
        pStr = '$count $unitName';
    }

    return ActionChip(
      label: Text('$title (Every $pStr)'),
      onPressed: () {
        setState(() {
          _titleCtrl.text = title;
          _type = ReminderType.dateBased;
          _dueDate = DateTime.now().add(const Duration(days: 30)); // Give them 30 days initially to review
          _recurrencePeriod = recurrencePeriod;
          if (match != null) {
            _recurrenceCountCtrl.text = match.group(1)!;
            _recurrenceUnit = match.group(2)!;
          }
        });
      },
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _dueDate = picked);
    }
  }
}
