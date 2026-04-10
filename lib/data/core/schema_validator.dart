import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/config/app_env.dart';
import 'tables.dart';

class SchemaValidator {
  static Future<void> validate(Database db) async {
    if (!AppEnv.enableDebugTools) {
      return;
    }

    Future<bool> tableExists(String name) async {
      final result = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [name],
      );
      return result.isNotEmpty;
    }

    Future<Set<String>> columnsOf(String table) async {
      final result = await db.rawQuery('PRAGMA table_info($table)');
      return result.map((row) => row['name'] as String).toSet();
    }

    final required = <String, Set<String>>{
      Tables.bankAccounts: {
        'id',
        'name',
        'balance',
        'account_type',
      },
      Tables.appSessions: {
        'id',
        'start_time',
        'end_time',
        'duration_seconds',
        'date',
      },
      Tables.transactions: {
        'id',
        'amount',
        'type',
        'category_id',
        'account_id',
        'date',
      },
      Tables.categories: {
        'id',
        'user_id',
        'name',
        'icon',
        'color',
        'type',
      },
      Tables.salary: {
        'id',
        'net_salary',
        'salary_month',
        'expected_date',
      },
      Tables.loans: {
        'id',
        'total',
        'start_date',
      },
      Tables.loanInstallments: {
        'id',
        'loanId',
        'amount',
        'dueDate',
        'status',
      },
      Tables.lendings: {
        'id',
        'person_name',
        'original_amount',
        'date',
        'is_settled',
      },
      Tables.creditCards: {
        'id',
        'name',
      },
      Tables.creditTransactions: {
        'id',
        'cardId',
        'amount',
        'date',
      },
      Tables.budgets: {
        'id',
        'category_id',
        'limit_amount',
        'period',
      },
      Tables.netWorthHistory: {
        'id',
        'net_worth',
        'assets',
        'liabilities',
        'timestamp',
      },
      Tables.bankBalanceSnapshots: {
        'id',
        'accountId',
        'balance',
        'timestamp',
      },
      Tables.vehicleReminders: {
        'id',
        'vehicle_id',
        'title',
        'type',
        'is_active',
      },
      Tables.emiPlans: {
        'id',
        'name',
        'principal',
        'interest_rate',
        'tenure_months',
      },
    };

    for (final entry in required.entries) {
      final table = entry.key;
      final exists = await tableExists(table);
      if (!exists) {
        throw Exception('Missing table: $table');
      }

      final actualColumns = await columnsOf(table);
      final missing = entry.value.difference(actualColumns);
      if (missing.isNotEmpty) {
        throw Exception('Table $table missing columns: $missing');
      }
    }

    debugPrint('✅ Schema validation passed');
  }
}
