import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart' as app_data;
import '../../../models/bank_account.dart';

/// Single source of truth for AccountRepo provider.
final accountRepoProvider = app_data.accountRepoProvider;

/// Single source of truth for accountsProvider — re-exported from data/providers.dart.
/// All invalidations and watches across the entire application converge on this one provider.
final accountsProvider = app_data.accountsProvider;

final addAccountProvider = Provider((ref) {
  return (BankAccount account) async {
    await ref.read(accountsProvider.notifier).add(account);
  };
});

final updateAccountProvider = Provider((ref) {
  return (BankAccount account) async {
    await ref.read(accountsProvider.notifier).replace(account);
  };
});

final deleteAccountProvider = Provider((ref) {
  return (String accountId) async {
    await ref.read(accountsProvider.notifier).remove(accountId);
  };
});
