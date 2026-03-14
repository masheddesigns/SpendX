import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/vehicle.dart';
import '../../services/database_helper.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import 'settings/vehicle_management_screen.dart';
import 'vehicles/add_fuel_screen.dart';
import 'vehicles/fuel_analytics_screen.dart';
import 'vehicles/vehicle_report_screen.dart';

class VehiclesScreen extends StatefulWidget {
  const VehiclesScreen({super.key});

  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends State<VehiclesScreen> {
  List<Vehicle> _vehicles = [];
  String? _selectedVehicleId;
  List<FuelLog> _currentLogs = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  final int _limit = 20;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadData();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
        if (!_isLoading && !_isLoadingMore && _hasMore) _loadMoreLogs();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final v = await DatabaseHelper.instance.getAllVehicles();
      if (mounted) {
        setState(() {
          _vehicles = v;
          if (_vehicles.isNotEmpty) {
            // Keep selection if it still exists, else pick first
            if (_selectedVehicleId == null || !v.any((car) => car.id == _selectedVehicleId)) {
              _selectedVehicleId = v.first.id;
            }
          } else {
            _selectedVehicleId = null;
          }
        });
        if (_selectedVehicleId != null) {
          await _loadLogsForSelected();
        } else {
          setState(() {
            _currentLogs = [];
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadLogsForSelected() async {
    if (_selectedVehicleId == null) return;
    try {
      _offset = 0;
      _hasMore = true;
      final logs = await DatabaseHelper.instance.getFuelLogsForVehicle(_selectedVehicleId!, limit: _limit, offset: 0);
      if (mounted) {
        setState(() {
          _currentLogs = logs;
          _offset = logs.length;
          _hasMore = logs.length >= _limit;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMoreLogs() async {
    if (_selectedVehicleId == null) return;
    setState(() => _isLoadingMore = true);
    try {
      final more = await DatabaseHelper.instance.getFuelLogsForVehicle(_selectedVehicleId!, limit: _limit, offset: _offset);
      if (mounted) {
        setState(() {
          _currentLogs.addAll(more);
          _offset += more.length;
          _hasMore = more.length >= _limit;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  void _showActionMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Add Record', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            ListTile(
              leading: const CircleAvatar(backgroundColor: Colors.orange, child: Icon(Icons.local_gas_station, color: Colors.white)),
              title: const Text('Fuel Log'),
              subtitle: const Text('Log a fill-up, auto-calculate mileage'),
              onTap: () async {
                Navigator.pop(context);
                final res = await Navigator.push(context, MaterialPageRoute(builder: (_) => AddFuelScreen(initialVehicleId: _selectedVehicleId)));
                if (res == true) _loadLogsForSelected();
              },
            ),
            ListTile(
              leading: const CircleAvatar(backgroundColor: Colors.blue, child: Icon(Icons.build, color: Colors.white)),
              title: const Text('Service & Repairs (Coming Soon)'),
              subtitle: const Text('Log maintenance costs and parts'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const CircleAvatar(backgroundColor: Colors.purple, child: Icon(Icons.alarm, color: Colors.white)),
              title: const Text('Reminder (Coming Soon)'),
              subtitle: const Text('Set Odometer or Date reminders'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }




  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    if (_vehicles.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Vehicles Dashboard'), backgroundColor: Colors.transparent, elevation: 0),
        body: Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.directions_car, size: 80, color: Colors.grey[800]),
            const SizedBox(height: 16),
            const Text('No Vehicles Found', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Add a vehicle to start tracking fuel & expenses.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add Vehicle'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const VehicleManagementScreen()));
                _loadData();
              },
            )
          ]),
        ),
      );
    }

    final selectedVehicle = _vehicles.firstWhere((v) => v.id == _selectedVehicleId);
    
    // Calculate simple stats
    final now = DateTime.now();
    double spentThisMonth = 0;
    double spentLastMonth = 0;
    List<double> efficiencies = [];

    for (var log in _currentLogs) {
      if (log.date.year == now.year && log.date.month == now.month) spentThisMonth += log.totalCost;
      if (log.date.year == now.year && log.date.month == now.month - 1) spentLastMonth += log.totalCost; // Simplified last month
      if (log.date.year == now.year - 1 && now.month == 1 && log.date.month == 12) spentLastMonth += log.totalCost; // Rollover handling
      
      if (log.efficiency != null) efficiencies.add(log.efficiency!);
    }

    final avgEff = efficiencies.isEmpty ? 0.0 : efficiencies.reduce((a, b) => a + b) / efficiencies.length;
    
    // Last odometer reading (most recent)
    final lastOdo = _currentLogs.isNotEmpty
        ? _currentLogs.map((l) => l.odometer).reduce((a, b) => a > b ? a : b)
        : null;
    // Total distance covered = highest odo - lowest odo across all logs
    double totalKm = 0;
    if (_currentLogs.length >= 2) {
      final maxOdo = _currentLogs.map((l) => l.odometer).reduce((a, b) => a > b ? a : b);
      final minOdo = _currentLogs.map((l) => l.odometer).reduce((a, b) => a < b ? a : b);
      totalKm = maxOdo - minOdo;
    }

    return Scaffold(
      appBar: AppBar(
        title: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _selectedVehicleId,
            icon: Icon(Icons.arrow_drop_down, color: Theme.of(context).colorScheme.onSurface),
            dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            isDense: true,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface),
            items: [
              ..._vehicles.map((v) => DropdownMenuItem(value: v.id, child: Text(v.name))),
              const DropdownMenuItem(value: 'MANAGE', child: Text('Manage vehicles...', style: TextStyle(color: Colors.blue, fontSize: 14))),
            ],
            onChanged: (val) async {
              if (val == 'MANAGE') {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const VehicleManagementScreen()));
                _loadData();
              } else if (val != null) {
                setState(() { _selectedVehicleId = val; _isLoading = true; });
                _loadLogsForSelected();
              }
            },
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showActionMenu,
        backgroundColor: Colors.orange,
        child: const Icon(Icons.add),
      ),
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // Dashboard Top Section
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.orange.withValues(alpha: 0.2), Theme.of(context).colorScheme.surfaceContainerLow],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  _BigStatBox('Avg Mileage', avgEff > 0 ? '${avgEff.toStringAsFixed(1)} km/l' : '--'),
                  Container(width: 1, height: 40, color: Theme.of(context).colorScheme.outlineVariant),
                  _BigStatBox('This Month', '${AppFormat.currency(spentThisMonth)}'),
                  Container(width: 1, height: 40, color: Theme.of(context).colorScheme.outlineVariant),
                  _BigStatBox('Last Month', '${AppFormat.currency(spentLastMonth)}'),
                ]),
                const SizedBox(height: 12),
                const Divider(color: Colors.white12, height: 1),
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  _BigStatBox('Last ODO', lastOdo != null ? '${lastOdo.toStringAsFixed(0)} km' : '--'),
                  Container(width: 1, height: 40, color: Colors.white24),
                  _BigStatBox('Fill-ups', '${_currentLogs.length}'),
                ]),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${selectedVehicle.type} • ${selectedVehicle.fuelType}', 
                        style: TextStyle(color: Colors.orange[200], fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1.2)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => FuelAnalyticsScreen(
                              vehicleId: selectedVehicle.id,
                              vehicleName: selectedVehicle.name,
                            )),
                          );
                        },
                        icon: const Icon(Icons.analytics_outlined, size: 16),
                        label: const Text('Analytics'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.orange,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: const BorderSide(color: Colors.orange),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => VehicleReportScreen(
                              vehicle: selectedVehicle,
                            )),
                          );
                        },
                        icon: const Icon(Icons.receipt_long_outlined, size: 16),
                        label: const Text('Cost Report'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blue,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: const BorderSide(color: Colors.blue),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ),
              ]),
            ),
          ),
          
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text('Recent fuel logs', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey, letterSpacing: 1.2)),
            ),
          ),

          if (_currentLogs.isEmpty)
            SliverFillRemaining(
              child: Center(child: Text('No fuel logs yet. Tap + to add.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6)))),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  if (i == _currentLogs.length) {
                    return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()));
                  }
                  final log = _currentLogs[i];
                  return Card(
                    elevation: 1,
                    shadowColor: Colors.black.withValues(alpha: 0.1),
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      // ... rest of tile content ...
                      leading: const CircleAvatar(backgroundColor: Colors.orange, child: Icon(Icons.local_gas_station, color: Colors.white, size: 18)),
                      title: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('${log.litres.toStringAsFixed(1)} L', style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text('${AppFormat.currency(log.totalCost)}', style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.orange, fontSize: 16)),
                        ],
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          Text('${DateFormat('dd MMM, HH:mm').format(log.date)} • ${log.odometer.toStringAsFixed(0)} km', style: const TextStyle(fontSize: 12)),
                          if (log.location != null) ...[
                            const SizedBox(height: 2),
                            Row(children: [
                              const Icon(Icons.location_on, size: 12, color: Colors.grey),
                              const SizedBox(width: 2),
                              Text(log.location!, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                            ]),
                          ],
                          if (log.efficiency != null) ...[
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
                              child: Text('${log.efficiency!.toStringAsFixed(1)} km/l', style: const TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600)),
                            )
                          ]
                        ],
                      ),
                      onTap: () {
                        showModalBottomSheet(
                          context: context,
                          builder: (_) => Container(
                            color: Theme.of(context).colorScheme.surfaceContainerHigh,
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.edit, color: Colors.blue),
                                  title: const Text('Edit Log'),
                                  onTap: () async {
                                    Navigator.pop(context);
                                    final res = await Navigator.push(context, MaterialPageRoute(builder: (_) => AddFuelScreen(existingLog: log)));
                                    if (res == true) _loadLogsForSelected();
                                  },
                                ),
                                ListTile(
                                  leading: const Icon(Icons.delete, color: Colors.red),
                                  title: const Text('Delete Log', style: TextStyle(color: Colors.red)),
                                  onTap: () async {
                                    Navigator.pop(context);
                                    await DatabaseHelper.instance.deleteFuelLog(log.id);
                                    _loadLogsForSelected();
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
                childCount: _currentLogs.length + (_hasMore ? 1 : 0),
              ),
            ),
        ],
      ),
    );
  }

  Widget _BigStatBox(String label, String val) {
    return Column(
      children: [
        Text(val, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
