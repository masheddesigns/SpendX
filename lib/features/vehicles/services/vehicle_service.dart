import '../../../data/repositories/vehicle_repo.dart';

class VehicleActivity {
  final String type; // 'fuel' or 'expense'
  final DateTime date;
  final double amount;
  final String title;
  final String subtitle;
  final dynamic icon;
  final dynamic color;

  VehicleActivity({
    required this.type,
    required this.date,
    required this.amount,
    required this.title,
    required this.subtitle,
    this.icon,
    this.color,
  });
}

class VehicleService {
  static final VehicleService instance = VehicleService._();
  VehicleService._({VehicleRepo? vehicleRepo})
    : _vehicleRepo = vehicleRepo ?? VehicleRepo();
  factory VehicleService() => instance;

  final VehicleRepo _vehicleRepo;

  Future<double?> getLastOdometer(String vehicleId) async {
    final last = await _vehicleRepo.getFuelLogsForVehicle(vehicleId, limit: 1);
    return last.isNotEmpty ? last.first.odometer : null;
  }

  Future<List<VehicleActivity>> getActivityTimeline(String vehicleId) async {
    final fuelLogs = await _vehicleRepo.getFuelLogsForVehicle(vehicleId);
    final expenses = await _vehicleRepo.getTransactionsForVehicle(vehicleId);

    final List<VehicleActivity> timeline = [];

    for (final log in fuelLogs) {
      timeline.add(
        VehicleActivity(
          type: 'fuel',
          date: log.date,
          amount: log.totalCost,
          title: 'Fuel Fill-up',
          subtitle:
              '${log.litres.toStringAsFixed(1)}L • ${log.odometer.toStringAsFixed(0)} km',
        ),
      );
    }

    for (final exp in expenses) {
      timeline.add(
        VehicleActivity(
          type: 'expense',
          date: exp.date,
          amount: exp.amount,
          title:
              exp.categoryId?.replaceAll('cat_', '').toUpperCase() ?? 'Expense',
          subtitle: exp.notes.isNotEmpty ? exp.notes : 'Maintenance',
        ),
      );
    }

    timeline.sort((a, b) => b.date.compareTo(a.date));
    return timeline;
  }
}
