import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/core/app_database.dart';
import '../../services/reminder_service.dart';
import '../../services/salary_service.dart';
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

final salaryServiceProvider = Provider<SalaryService>(
  (ref) => SalaryService.instance,
);

final settingsProvider = ChangeNotifierProvider<SettingsService>(
  (ref) => SettingsService.instance,
);

final creditCardServiceProvider = Provider<CreditCardService>(
  (ref) => CreditCardService(),
);

final loanServiceProvider = Provider<LoanService>((ref) => LoanService());
