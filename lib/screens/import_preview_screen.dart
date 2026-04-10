import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/import_service.dart'
    show ImportService, FuelImportRow, FuelImportStatus;
import '../theme/app_theme.dart';
import '../shared/widgets/app_card.dart';
import '../shared/widgets/primary_button.dart';

class ImportPreviewScreen extends StatefulWidget {
  final List<FuelImportRow> rows;
  final String vehicleId;

  const ImportPreviewScreen({
    super.key,
    required this.rows,
    required this.vehicleId,
  });

  @override
  State<ImportPreviewScreen> createState() => _ImportPreviewScreenState();
}

class _ImportPreviewScreenState extends State<ImportPreviewScreen> {
  late List<FuelImportRow> _rows;
  final Set<int> _skippedIndices = {};
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _rows = List.from(widget.rows);
  }

  Future<void> _editRow(int index) async {
    final row = _rows[index];
    final dateController = TextEditingController(
      text: DateFormat('yyyy-MM-dd').format(row.date),
    );
    final odoController = TextEditingController(text: row.odometer.toString());
    final fuelController = TextEditingController(text: row.litres.toString());
    final costController = TextEditingController(
      text: row.totalCost.toString(),
    );

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Row'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: dateController,
                decoration: const InputDecoration(
                  labelText: 'Date (yyyy-MM-dd)',
                ),
                keyboardType: TextInputType.datetime,
              ),
              TextField(
                controller: odoController,
                decoration: const InputDecoration(labelText: 'Odometer (km)'),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: fuelController,
                decoration: const InputDecoration(labelText: 'Fuel (Litres)'),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: costController,
                decoration: const InputDecoration(labelText: 'Total Cost'),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                try {
                  _rows[index] = FuelImportRow(
                    date: DateTime.parse(dateController.text),
                    odometer: double.parse(odoController.text),
                    litres: double.parse(fuelController.text),
                    totalCost: double.parse(costController.text),
                    isFullTank: row.isFullTank,
                    notes: row.notes,
                    status: FuelImportStatus
                        .valid, // Marked as valid after manual edit
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invalid input formats')),
                  );
                }
              });
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmImport() async {
    setState(() => _isImporting = true);

    final finalRows = <FuelImportRow>[];
    for (int i = 0; i < _rows.length; i++) {
      if (!_skippedIndices.contains(i)) {
        finalRows.add(_rows[i]);
      }
    }

    if (finalRows.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No rows to import')));
      setState(() => _isImporting = false);
      return;
    }

    final count = await ImportService.instance.saveFuelImportRows(
      finalRows,
      widget.vehicleId,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported $count fuel logs successfully')),
      );
      Navigator.pop(context, count); // Return the actual count
    }
  }

  Color _getStatusColor(FuelImportStatus status) {
    switch (status) {
      case FuelImportStatus.valid:
        return Colors.green;
      case FuelImportStatus.warning:
        return Colors.orange;
      case FuelImportStatus.corrected:
        return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm Import')),
      body: _rows.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.search_off_rounded, size: 48),
                  SizedBox(height: 16),
                  Text(
                    'No Data Found',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'The selected file could not be parsed or contains no valid fuel logs.',
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    final isSkipped = _skippedIndices.contains(index);

                    return Opacity(
                      opacity: isSkipped ? 0.5 : 1.0,
                      child: AppCard(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        padding: EdgeInsets.zero,
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: _getStatusColor(
                              row.status,
                            ).withValues(alpha: 0.2),
                            child: Icon(
                              row.status == FuelImportStatus.warning
                                  ? Icons.warning
                                  : Icons.local_gas_station,
                              color: _getStatusColor(row.status),
                            ),
                          ),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  DateFormat('MMM dd, yyyy').format(row.date),
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.titleSmall,
                                ),
                              ),
                              if (row.status != FuelImportStatus.valid) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _getStatusColor(
                                      row.status,
                                    ).withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    row.status.name.toUpperCase(),
                                    style: AppTextStyles.labelSmall.copyWith(
                                      color: _getStatusColor(row.status),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${row.odometer.toStringAsFixed(0)} km • ${row.litres.toStringAsFixed(2)} L • ₹${row.totalCost.toStringAsFixed(2)}',
                                style: AppTextStyles.bodySmall,
                              ),
                              Row(
                                children: [
                                  Text(
                                    '₹${row.pricePerLitre.toStringAsFixed(2)}/L',
                                    style: AppTextStyles.labelSmall.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    row.isFullTank ? 'Full Tank' : 'Partial',
                                    style: AppTextStyles.labelSmall.copyWith(
                                      color: row.isFullTank
                                          ? Colors.green
                                          : Colors.orange,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit, size: 20),
                                onPressed: isSkipped
                                    ? null
                                    : () => _editRow(index),
                              ),
                              Checkbox(
                                value: !isSkipped,
                                activeColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                onChanged: (val) {
                                  setState(() {
                                    if (val == true) {
                                      _skippedIndices.remove(index);
                                    } else {
                                      _skippedIndices.add(index);
                                    }
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (_isImporting)
                  const Center(child: CircularProgressIndicator()),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.m),
          child: PrimaryButton(
            onPressed: _isImporting ? null : _confirmImport,
            label: _isImporting
                ? 'IMPORTING...'
                : 'IMPORT ${_rows.length - _skippedIndices.length} ENTRIES',
          ),
        ),
      ),
    );
  }
}
