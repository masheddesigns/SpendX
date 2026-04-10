import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../data/core/undoable_delete.dart';
import '../../../data/providers.dart' show writeQueueProvider;
import '../../../data/repositories/reminder_repo.dart';
import '../../../data/repositories/vehicle_repo.dart';
import '../../../data/repositories/vehicle_reminder_repo.dart';
import '../../../models/vehicle.dart';
import '../../../models/vehicle_reminder.dart';
import '../../../models/transaction.dart' as spx;
import '../../../services/haptic_service.dart';
import '../../../services/notification_service_v2.dart';
import '../services/vehicle_service.dart';
import '../services/vehicle_reminder_service.dart';
import '../services/fuel_intelligence_service.dart';

final vehicleServiceProvider = Provider((ref) => VehicleService.instance);
final vehicleReminderServiceProvider = Provider(
  (ref) => VehicleReminderService.instance,
);
final fuelIntelligenceServiceProvider = Provider(
  (ref) => FuelIntelligenceService.instance,
);
final vehicleRepoProvider = Provider((ref) => VehicleRepo());
final vehicleReminderRepoProvider = Provider((ref) => VehicleReminderRepo());
final globalReminderRepoProvider = Provider((ref) => ReminderRepo());

class VehiclesNotifier extends AsyncNotifier<List<Vehicle>> {
  String _tempId() => 'temp_${DateTime.now().microsecondsSinceEpoch}';

  @override
  Future<List<Vehicle>> build() async {
    return ref.watch(vehicleRepoProvider).getAllVehicles();
  }

  Future<void> add(Vehicle vehicle, {bool emitHaptic = true}) async {
    final snapshot = List<Vehicle>.from(state.valueOrNull ?? []);
    final tempVehicle = vehicle.copyWith(id: _tempId());
    state = AsyncData([...snapshot, tempVehicle]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        final realId = await ref
            .read(vehicleRepoProvider)
            .insertVehicle(vehicle);
        final current = state.valueOrNull ?? [];
        state = AsyncData(
          current
              .map(
                (item) => item.id == tempVehicle.id
                    ? vehicle.copyWith(id: realId)
                    : item,
              )
              .toList(),
        );
      } catch (e, st) {
        state = AsyncError(e, st);
        state = AsyncData(snapshot);
      }
    });
  }

  Future<void> remove(Vehicle vehicle) async {
    final snapshot = List<Vehicle>.from(state.valueOrNull ?? []);
    if (!snapshot.any((item) => item.id == vehicle.id)) {
      return;
    }

    state = AsyncData(snapshot.where((item) => item.id != vehicle.id).toList());

    try {
      await performUndoableDelete<Vehicle>(
        ref: ref,
        label: 'Vehicle deleted',
        payload: vehicle,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => state = AsyncData(snapshot),
        repositoryDelete: () =>
            ref.read(vehicleRepoProvider).deleteVehicle(vehicle.id),
      );
    } catch (e, st) {
      state = AsyncError(e, st);
      state = AsyncData(snapshot);
      rethrow;
    }
  }

  Future<void> refresh() async {
    state = AsyncData(await ref.read(vehicleRepoProvider).getAllVehicles());
  }
}

final vehiclesProvider = AsyncNotifierProvider<VehiclesNotifier, List<Vehicle>>(
  VehiclesNotifier.new,
);

final selectedVehicleIdProvider = StateProvider<String?>((ref) {
  final vehicles = ref.watch(vehiclesProvider).valueOrNull;
  if (vehicles == null || vehicles.isEmpty) return null;
  return vehicles.first.id;
});

final fuelLogsProvider =
    FutureProvider.family<
      List<FuelLog>,
      ({String vehicleId, int limit, int offset})
    >((ref, arg) async {
      return await ref
          .read(vehicleRepoProvider)
          .getFuelLogsForVehicle(
            arg.vehicleId,
            limit: arg.limit,
            offset: arg.offset,
          );
    });

final selectedVehicleLogsProvider = FutureProvider<List<FuelLog>>((ref) async {
  final vehicleId = ref.watch(selectedVehicleIdProvider);
  if (vehicleId == null) return [];
  return await ref
      .read(vehicleRepoProvider)
      .getFuelLogsForVehicle(vehicleId, limit: 100, offset: 0);
});

class VehicleFuelLogsNotifier extends StateNotifier<AsyncValue<List<FuelLog>>> {
  VehicleFuelLogsNotifier(this._ref, this._vehicleId)
    : super(const AsyncLoading()) {
    refresh();
  }

  final Ref _ref;
  final String _vehicleId;
  String _tempId() => 'temp_${DateTime.now().microsecondsSinceEpoch}';

  Future<void> refresh() async {
    try {
      final logs = await _ref
          .read(vehicleRepoProvider)
          .getFuelLogsForVehicle(_vehicleId);
      state = AsyncData(logs);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> add(FuelLog log) async {
    final snapshot = List<FuelLog>.from(state.valueOrNull ?? const []);
    final tempLog = log.copyWith(id: _tempId());
    final optimistic = [...snapshot, tempLog]
      ..sort((a, b) => b.date.compareTo(a.date));
    state = AsyncData(optimistic);

    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref.read(vehicleRepoProvider).insertFuelLog(log);
        final current = List<FuelLog>.from(state.valueOrNull ?? const []);
        final reconciled =
            current.map((item) => item.id == tempLog.id ? log : item).toList()
              ..sort((a, b) => b.date.compareTo(a.date));
        state = AsyncData(reconciled);
        await _postSaveRefresh();
      } catch (e, st) {
        state = AsyncError(e, st);
        state = AsyncData(snapshot);
      }
    });
  }

  Future<void> replace(FuelLog log) async {
    final snapshot = List<FuelLog>.from(state.valueOrNull ?? const []);
    final optimistic =
        snapshot.map((item) => item.id == log.id ? log : item).toList()
          ..sort((a, b) => b.date.compareTo(a.date));
    state = AsyncData(optimistic);

    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref.read(vehicleRepoProvider).insertFuelLog(log);
        await _postSaveRefresh();
      } catch (e, st) {
        state = AsyncError(e, st);
        state = AsyncData(snapshot);
      }
    });
  }

  Future<void> remove(FuelLog log) async {
    final snapshot = List<FuelLog>.from(state.valueOrNull ?? const []);
    state = AsyncData(snapshot.where((item) => item.id != log.id).toList());

    try {
      await performUndoableDelete<FuelLog>(
        ref: _ref,
        label: 'Fuel log deleted',
        payload: log,
        undo: (item) => add(item),
        rollback: () => state = AsyncData(snapshot),
        repositoryDelete: () =>
            _ref.read(vehicleRepoProvider).deleteFuelLog(log.id),
      );
    } catch (e, st) {
      state = AsyncError(e, st);
      state = AsyncData(snapshot);
      rethrow;
    }
  }

  Future<void> _postSaveRefresh() async {
    _ref.invalidate(fuelLogsProvider);
    _ref.invalidate(selectedVehicleLogsProvider);
    _ref.invalidate(vehicleDetailProvider);

    final allLogs = await _ref
        .read(vehicleRepoProvider)
        .getFuelLogsForVehicle(_vehicleId);
    await _ref.read(fuelIntelligenceServiceProvider).detectMileageDrop(allLogs);
  }
}

final vehicleFuelLogsProvider =
    StateNotifierProvider.family<
      VehicleFuelLogsNotifier,
      AsyncValue<List<FuelLog>>,
      String
    >((ref, vehicleId) {
      return VehicleFuelLogsNotifier(ref, vehicleId);
    });

class VehicleRemindersNotifier
    extends StateNotifier<AsyncValue<List<VehicleReminder>>> {
  VehicleRemindersNotifier(this._ref, this._vehicleId)
    : super(const AsyncLoading()) {
    refresh();
  }

  final Ref _ref;
  final String _vehicleId;

  Future<void> refresh() async {
    try {
      final reminders = await _ref
          .read(vehicleReminderServiceProvider)
          .getReminders(_vehicleId);
      state = AsyncData(reminders);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> add(VehicleReminder reminder) async {
    final snapshot = List<VehicleReminder>.from(state.valueOrNull ?? const []);
    state = AsyncData([...snapshot, reminder]);

    try {
      await _ref.read(vehicleReminderServiceProvider).saveReminder(reminder);
    } catch (e, st) {
      state = AsyncError(e, st);
      state = AsyncData(snapshot);
      rethrow;
    }
  }

  Future<void> remove(VehicleReminder reminder) async {
    final snapshot = List<VehicleReminder>.from(state.valueOrNull ?? const []);
    state = AsyncData(
      snapshot.where((item) => item.id != reminder.id).toList(),
    );

    try {
      await performUndoableDelete<VehicleReminder>(
        ref: _ref,
        label: 'Reminder deleted',
        payload: reminder,
        undo: (item) => add(item),
        rollback: () => state = AsyncData(snapshot),
        repositoryDelete: () => _ref.read(writeQueueProvider).enqueue(() async {
          await _ref.read(vehicleReminderRepoProvider).delete(reminder.id);
          await _ref
              .read(globalReminderRepoProvider)
              .deleteGlobalReminder('vehicle_${reminder.id}');
          await NotificationServiceV2().cancelNotification(reminder.id);
        }),
      );
    } catch (e, st) {
      state = AsyncError(e, st);
      state = AsyncData(snapshot);
      rethrow;
    }
  }
}

final vehicleRemindersProvider =
    StateNotifierProvider.family<
      VehicleRemindersNotifier,
      AsyncValue<List<VehicleReminder>>,
      String
    >((ref, vehicleId) {
      return VehicleRemindersNotifier(ref, vehicleId);
    });

class MonthData {
  final String label;
  final double cost;
  final double km;
  final double? avgMileage;
  MonthData(this.label, this.cost, this.km, this.avgMileage);
}

class VehicleDetailData {
  final List<FuelLog> logs;
  final List<spx.Transaction> otherExpenses;
  final List<VehicleReminder> reminders;
  final List<VehicleReminder> alerts;
  final double totalKm;
  final double totalFuelCost;
  final double totalOtherCost;
  final double avgMileage;
  final double? costPerKm;
  final FuelLog? bestLog;
  final FuelLog? worstLog;
  final ServiceAlert? serviceAlert;
  final FuelPrediction? prediction;
  final List<FuelInsight> insights;
  final double currentOdo;
  final List<MonthData> monthlyBreakdown;
  final List<VehicleActivity> timeline;

  VehicleDetailData({
    required this.logs,
    required this.otherExpenses,
    required this.reminders,
    required this.alerts,
    required this.totalKm,
    required this.totalFuelCost,
    required this.totalOtherCost,
    required this.avgMileage,
    this.costPerKm,
    this.bestLog,
    this.worstLog,
    this.serviceAlert,
    this.prediction,
    required this.insights,
    required this.currentOdo,
    required this.monthlyBreakdown,
    required this.timeline,
  });
}

final vehicleDetailProvider = FutureProvider.family<VehicleDetailData, Vehicle>(
  (ref, vehicle) async {
    final intel = ref.watch(fuelIntelligenceServiceProvider);
    final reminderService = ref.watch(vehicleReminderServiceProvider);
    final vehicleService = ref.watch(vehicleServiceProvider);
    final vehicleRepo = ref.watch(vehicleRepoProvider);

    final logs = await vehicleRepo.getFuelLogsForVehicle(vehicle.id);
    final other = await vehicleRepo.getTransactionsForVehicle(vehicle.id);
    final timeline = await vehicleService.getActivityTimeline(vehicle.id);

    final processedLogs = intel.recomputeEfficiencies(logs);
    final withEff = processedLogs.where((l) => l.efficiency != null).toList();
    final avgM = intel.getAvgMileage(processedLogs);
    final totalKm = intel.getTotalKm(processedLogs);

    final fuelCostSum = processedLogs.fold(0.0, (s, l) => s + l.totalCost);
    final otherCostSum = other.fold(0.0, (s, t) => s + t.amount);
    final totalCostOverall = fuelCostSum + otherCostSum;

    final cpk = totalKm > 0 ? totalCostOverall / totalKm : null;

    FuelLog? best, worst;
    if (withEff.isNotEmpty) {
      best = withEff.reduce((a, b) => a.efficiency! > b.efficiency! ? a : b);
      worst = withEff.reduce((a, b) => a.efficiency! < b.efficiency! ? a : b);
    }

    final currentOdo = processedLogs.isNotEmpty
        ? processedLogs.map((l) => l.odometer).reduce((a, b) => a > b ? a : b)
        : 0.0;

    final reminders = await reminderService.getReminders(vehicle.id);
    final alerts = await reminderService.getAlerts(vehicle.id, currentOdo);

    // Compute Monthly Breakdown
    final Map<String, List<dynamic>> monthlyMap = {};
    for (final log in processedLogs) {
      final key = DateFormat('MMM yyyy').format(log.date);
      monthlyMap.putIfAbsent(key, () => []).add(log);
    }
    for (final t in other) {
      final key = DateFormat('MMM yyyy').format(t.date);
      monthlyMap.putIfAbsent(key, () => []).add(t);
    }

    final monthlyList = monthlyMap.entries.map((e) {
      final mItems = e.value;
      final mFuelLogs = mItems.whereType<FuelLog>().toList();
      final mOtherTrans = mItems.whereType<spx.Transaction>().toList();

      final mFuelCost = mFuelLogs.fold(0.0, (s, l) => s + l.totalCost);
      final mOtherCost = mOtherTrans.fold(0.0, (s, t) => s + t.amount);
      final mTotalCost = mFuelCost + mOtherCost;

      double mKm = 0;
      if (mFuelLogs.length >= 2) {
        mKm =
            mFuelLogs.map((l) => l.odometer).reduce((a, b) => a > b ? a : b) -
            mFuelLogs.map((l) => l.odometer).reduce((a, b) => a < b ? a : b);
      }

      final mWithEff = mFuelLogs.where((l) => l.efficiency != null).toList();
      final mAvgEff = mWithEff.isEmpty
          ? null
          : mWithEff.fold(0.0, (s, l) => s + l.efficiency!) / mWithEff.length;

      return MonthData(e.key, mTotalCost, mKm, mAvgEff);
    }).toList();

    // Sort months descending
    monthlyList.sort((a, b) {
      final dateA = DateFormat('MMM yyyy').parse(a.label);
      final dateB = DateFormat('MMM yyyy').parse(b.label);
      return dateB.compareTo(dateA);
    });

    return VehicleDetailData(
      logs: processedLogs,
      otherExpenses: other,
      reminders: reminders,
      alerts: alerts,
      totalKm: totalKm,
      totalFuelCost: fuelCostSum,
      totalOtherCost: otherCostSum,
      avgMileage: avgM,
      costPerKm: cpk,
      bestLog: best,
      worstLog: worst,
      serviceAlert: intel.getServiceAlert(vehicle, currentOdo),
      prediction: intel.predictNextFill(processedLogs),
      insights: intel.generateFuelInsights(processedLogs),
      currentOdo: currentOdo,
      monthlyBreakdown: monthlyList,
      timeline: timeline,
    );
  },
);

class VehicleNotifier extends StateNotifier<AsyncValue<void>> {
  final Ref _ref;
  VehicleNotifier(this._ref) : super(const AsyncData(null));

  Future<void> deleteFuelLog(String logId, String vehicleId) async {
    state = const AsyncLoading();
    try {
      final logs =
          _ref.read(vehicleFuelLogsProvider(vehicleId)).valueOrNull ??
          await _ref.read(vehicleRepoProvider).getFuelLogsForVehicle(vehicleId);
      FuelLog? log;
      for (final item in logs) {
        if (item.id == logId) {
          log = item;
          break;
        }
      }
      if (log == null) {
        throw StateError('Fuel log not found');
      }
      await _ref.read(vehicleFuelLogsProvider(vehicleId).notifier).remove(log);
      state = const AsyncData(null);
      _invalidateVehicleData(vehicleId);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> deleteReminder(String reminderId, String vehicleId) async {
    state = const AsyncLoading();
    try {
      final reminders =
          _ref.read(vehicleRemindersProvider(vehicleId)).valueOrNull ??
          await _ref
              .read(vehicleReminderServiceProvider)
              .getReminders(vehicleId);
      VehicleReminder? reminder;
      for (final item in reminders) {
        if (item.id == reminderId) {
          reminder = item;
          break;
        }
      }
      if (reminder == null) {
        throw StateError('Reminder not found');
      }
      await _ref
          .read(vehicleRemindersProvider(vehicleId).notifier)
          .remove(reminder);
      state = const AsyncData(null);
      _invalidateVehicleData(vehicleId);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> acknowledgeReminder(
    VehicleReminder reminder,
    double currentOdo,
    String vehicleId,
  ) async {
    state = const AsyncLoading();
    try {
      await _ref
          .read(vehicleReminderServiceProvider)
          .acknowledge(reminder, currentOdo);
      state = const AsyncData(null);
      _invalidateVehicleData(vehicleId);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> remove(String vehicleId) async {
    state = const AsyncLoading();
    try {
      final vehicles =
          _ref.read(vehiclesProvider).valueOrNull ??
          await _ref.read(vehicleRepoProvider).getAllVehicles();
      Vehicle? vehicle;
      for (final item in vehicles) {
        if (item.id == vehicleId) {
          vehicle = item;
          break;
        }
      }
      if (vehicle == null) {
        throw StateError('Vehicle not found');
      }
      await _ref.read(vehiclesProvider.notifier).remove(vehicle);
      state = const AsyncData(null);
      _ref.invalidate(vehiclesProvider);
      _ref.invalidate(selectedVehicleIdProvider);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> deleteVehicle(String vehicleId) => remove(vehicleId);

  void _invalidateVehicleData(String vehicleId) {
    _ref.invalidate(vehiclesProvider);
    _ref.invalidate(fuelLogsProvider);
    _ref.invalidate(vehicleFuelLogsProvider(vehicleId));
    _ref.invalidate(vehicleRemindersProvider(vehicleId));
    _ref.invalidate(vehicleDetailProvider);
  }
}

final vehicleNotifierProvider =
    StateNotifierProvider<VehicleNotifier, AsyncValue<void>>((ref) {
      return VehicleNotifier(ref);
    });
