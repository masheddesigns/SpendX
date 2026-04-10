import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/account_repo.dart';
import '../../../models/bank_account.dart';

final accountRepoProvider = Provider<AccountRepo>((ref) => AccountRepo());

final accountsProvider =
    AsyncNotifierProvider<AccountsNotifier, List<BankAccount>>(
      AccountsNotifier.new,
    );

class AccountsNotifier extends AsyncNotifier<List<BankAccount>> {
  @override
  Future<List<BankAccount>> build() async {
    final data = await ref.watch(accountRepoProvider).getAll();
    debugPrint('🏦 Accounts fetched: ${data.length}');
    return data;
  }

  Future<void> add(BankAccount account) async {
    await ref.read(accountRepoProvider).create(account);
    ref.invalidateSelf();
  }

  Future<void> replace(BankAccount account) async {
    await ref.read(accountRepoProvider).updateAccount(account);
    ref.invalidateSelf();
  }

  Future<void> remove(String accountId) async {
    await ref.read(accountRepoProvider).deleteAccount(accountId);
    ref.invalidateSelf();
  }
}

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
