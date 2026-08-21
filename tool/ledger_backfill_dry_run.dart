import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/migrations/ledger_backfill_dry_run.dart';

/// Phase 1C — run the ledger backfill against a *copy* of a real SpendX DB.
///
/// Usage:
///   dart run tool/ledger_backfill_dry_run.dart --db `<path-to-db-copy>` [--commit]
///
/// The source file is always copied to a temp location first, so the original
/// is never touched. Without --commit the backfill is run as a dry-run
/// (rolled back) and only the report is printed. With --commit the result is
/// persisted to the *copy* (the original is still untouched).
void main(List<String> args) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final dbPathIdx = args.indexOf('--db');
  if (dbPathIdx == -1 || dbPathIdx + 1 >= args.length) {
    stderr.writeln(
      'Usage: dart run tool/ledger_backfill_dry_run.dart '
      '--db <path-to-db-copy> [--commit]',
    );
    exit(1);
  }
  final source = args[dbPathIdx + 1];
  final commit = args.contains('--commit');

  final srcFile = File(source);
  if (!srcFile.existsSync()) {
    stderr.writeln('Source database not found: $source');
    exit(1);
  }

  final tempDir = Directory.systemTemp.createTempSync('ledger_backfill_');
  final copyPath = p.join(tempDir.path, 'copy.db');
  await srcFile.copy(copyPath);

  final db = await databaseFactoryFfi.openDatabase(copyPath);
  try {
    final report = commit ? await execute(db) : await dryRun(db);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toSummary()));
    if (!report.passed) {
      stderr.writeln(
        '\nMigration did NOT pass (rolled back). See report above.',
      );
      exit(2);
    }
  } finally {
    await db.close();
    await tempDir.delete(recursive: true);
  }
}
