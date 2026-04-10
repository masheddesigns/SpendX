import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/accounts/providers/account_providers.dart';
import '../../features/categories/providers/category_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart';

class AppDataSyncManager {
  final Ref ref;
  DateTime? _lastSync;
  final _throttle = const Duration(seconds: 10);

  AppDataSyncManager(this.ref);

  Future<void> syncAll() async {
    final now = DateTime.now();

    if (_lastSync != null && now.difference(_lastSync!) < _throttle) {
      // Throttled: Skip redundant sync
      return;
    }

    _lastSync = now;

    ref.invalidate(transactionsProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(categoriesProvider);
  }
}

final appDataSyncManagerProvider = Provider((ref) => AppDataSyncManager(ref));
