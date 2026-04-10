import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../lib/data/core/tables.dart';

void main() async {
  sqfliteFfiInit();
  final dbPath = 'assets/spendx.db'; // Adjust if needed
  if (!File(dbPath).existsSync()) {
    print('DB not found at $dbPath');
    return;
  }
  
  final db = await databaseFactoryFfi.openDatabase(dbPath);
  final tables = ['transactions', 'bank_accounts', 'credit_cards', 'loans'];
  
  for (var table in tables) {
    print('\n--- Table: $table ---');
    final info = await db.rawQuery('PRAGMA table_info($table)');
    for (var col in info) {
      print('${col['name']} (${col['type']})');
    }
  }
  await db.close();
}
