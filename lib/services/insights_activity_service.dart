import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';
import '../data/core/app_database.dart';
import '../data/core/tables.dart';
import '../data/core/tables_v24.dart';

/// Minimal, flat data model for Intelligence Hub activity items.
class ActivitySnippet {
  final String title;
  final String subtitle;

  const ActivitySnippet({required this.title, required this.subtitle});
}

/// Production-safe Intelligence Hub service.
class InsightsActivityService {
  InsightsActivityService._();
  static final InsightsActivityService instance = InsightsActivityService._();

  Future<void> initialize([Database? _]) async {}

  Future<Map<String, dynamic>> getMonthlyForecast() async {
    const empty = {
      "status": "empty",
      "monthlySpend": 0.0,
      "activity": <ActivitySnippet>[],
    };

    try {
      final db = await AppDatabase.instance.database;
      final now = DateTime.now();
      final month = now.month.toString().padLeft(2, '0'); // "03"
      final year = now.year.toString(); // "2026"

      // O(1) SQL aggregation over canonical postings — no Dart-level loops over transactions.
      final result = await db.rawQuery(
        '''
        SELECT COALESCE(SUM(
          CASE
            WHEN p.direction = 'debit' THEN p.amount_minor_units
            WHEN p.direction = 'credit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS total
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
        WHERE e.lifecycle_status = 'posted'
          AND a.account_type = 'expense'
          AND e.event_type != 'opening_balance'
          AND strftime('%m', e.timestamp) = ?
          AND strftime('%Y', e.timestamp) = ?
        ''',
        [month, year],
      );

      final totalRaw = result.isNotEmpty ? result.first['total'] : null;
      final monthly = (totalRaw as num?)?.toDouble() ?? 0.0;

      if (monthly == 0.0) {
        return empty;
      }

      return {
        "status": "data",
        "monthlySpend": monthly,
        "activity": [
          const ActivitySnippet(
            title: "System Online",
            subtitle: "Tracking active",
          ),
        ],
      };
    } catch (e) {
      debugPrint('[INSIGHTS] getMonthlyForecast error: $e');
      return {
        "status": "error",
        "monthlySpend": 0.0,
        "activity": <ActivitySnippet>[],
      };
    }
  }
}
