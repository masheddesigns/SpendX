// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';


import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/migrations/ledger_backfill_dry_run.dart';

/// Phase 1C — real-data validation entry point.
///
/// Copy your real SpendX database first, then run (works under `flutter test`,
/// which compiles cleanly even where a bare `dart run` of a Flutter-package
/// file is blocked by an SDK skew):
///
///   LEDGER_BACKFILL_DB=/path/to/real-copy.db flutter test test/ledger_backfill_real_test.dart
///
/// The source is copied to a temp file so it is NEVER mutated. By default the
/// backfill runs as a dry-run (rolled back) and the full report is printed.
/// Set LEDGER_BACKFILL_COMMIT=1 to persist the result to the *copy* instead.
void main() {
  setUpAll(() => sqfliteFfiInit());

  test('real-data backfill dry-run', () async {
    final source = Platform.environment['LEDGER_BACKFILL_DB'];
    if (source == null || source.isEmpty) {
      print('SKIP: set LEDGER_BACKFILL_DB to a real DB *copy* to run.');
      return;
    }
    final srcFile = File(source);
    if (!srcFile.existsSync()) {
      fail('LEDGER_BACKFILL_DB not found: $source');
    }

    // Always operate on a copy so the original is never touched.
    final tempDir =
        Directory.systemTemp.createTempSync('ledger_backfill_real_');
    final copyPath = p.join(tempDir.path, 'copy.db');
    await srcFile.copy(copyPath);

    final db = await databaseFactoryFfi.openDatabase(copyPath);
    try {
      // Bring the schema current WITHOUT running the backfill (mirrors what
      // AppDatabase does on open before production backfills). A raw exported
      // DB may be at any user_version.
      final versionRow = await db.rawQuery('PRAGMA user_version');
      final oldVersion = (versionRow.first['user_version'] as int?) ?? 0;
      await AppDatabase.instance.migrateSchemaOnly(db, oldVersion);

      final commit = Platform.environment['LEDGER_BACKFILL_COMMIT'] == '1';
      final report = commit ? await execute(db) : await dryRun(db);
      print(const JsonEncoder.withIndent('  ').convert(report.toSummary()));
      if (!report.passed) {
        print('RESULT: migration did NOT pass (rolled back).');
      }
    } finally {
      await db.close();
      await tempDir.delete(recursive: true);
    }
  });
}
