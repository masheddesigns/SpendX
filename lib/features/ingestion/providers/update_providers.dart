import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/app_update_service.dart';

/// Provider exposing real-time Play Store update availability.
final appUpdateInfoProvider =
    AsyncNotifierProvider<AppUpdateNotifier, SpendXUpdateInfo>(
  AppUpdateNotifier.new,
);

class AppUpdateNotifier extends AsyncNotifier<SpendXUpdateInfo> {
  @override
  Future<SpendXUpdateInfo> build() async {
    return AppUpdateService.instance.checkForUpdate();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => AppUpdateService.instance.checkForUpdate(),
    );
  }

  Future<bool> startUpdate() async {
    return AppUpdateService.instance.startUpdateFlow();
  }
}
