import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../accounts/providers/account_providers.dart';
import '../transactions/providers/transaction_providers.dart';
import 'runway_engine.dart';

/// Predicted cashflow runway.
final runwayProvider = FutureProvider<Runway>((ref) async {
  final accounts = await ref.watch(accountsProvider.future);
  final txns = await ref.watch(transactionsProvider.future);

  return RunwayEngine().calculate(
    accounts: accounts,
    transactions: txns,
  );
});
