import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/core/app_database.dart';
import '../../data/providers.dart' as app_data;
import '../../services/reminder_service.dart';
import '../../domain/credit/credit_card_service.dart';
import '../../domain/loans/loan_service.dart';
import '../database/database_service.dart';
import '../../services/settings_service.dart';

final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => AppDatabase.instance,
);

final databaseServiceProvider = Provider<DatabaseService>(
  (ref) => DatabaseService(),
);

final reminderServiceProvider = Provider<ReminderService>(
  (ref) => ReminderService.instance,
);

final salaryServiceProvider = app_data.salaryServiceProvider;

final settingsProvider = ChangeNotifierProvider<SettingsService>(
  (ref) => SettingsService.instance,
);

final creditCardServiceProvider = Provider<CreditCardService>(
  (ref) => CreditCardService(creditRepo: ref.watch(app_data.creditRepoProvider)),
);

final loanServiceProvider = Provider<LoanService>(
  (ref) => LoanService(loanRepo: ref.watch(app_data.loanRepoProvider)),
);
