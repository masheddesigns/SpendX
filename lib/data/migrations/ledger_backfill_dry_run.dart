import 'package:sqflite/sqflite.dart' hide Transaction;

import 'ledger_backfill_service.dart';

/// Phase 1C dry-run harness for the ledger backfill.
///
/// These helpers operate on a *database copy* (never the live file). [dryRun]
/// always rolls back — it runs the backfill inside an outer transaction and
/// aborts it, so the database is left byte-for-byte unchanged while still
/// producing the full [BackfillReport]. [execute] persists the result and
/// should only be used after a dry-run reports a clean PASS (or an accepted
/// PASS WITH EXCEPTIONS).
class _DryRunRollback implements Exception {
  final BackfillReport report;
  _DryRunRollback(this.report);
}

Future<BackfillReport> dryRun(Database db) async {
  try {
    await db.transaction((txn) async {
      // run() executes inline because `txn` is already a transaction.
      final report = await LedgerBackfillService.run(txn);
      // Abort the outer transaction so nothing is persisted.
      throw _DryRunRollback(report);
    });
  } on _DryRunRollback catch (e) {
    return e.report;
  }   on BackfillFailedException catch (e) {
    // Hard failure: the backfill already rolled back its own writes.
    return e.report;
  }
}

Future<BackfillReport> execute(Database db) async {
  try {
    return await LedgerBackfillService.run(db);
  } on BackfillFailedException catch (e) {
    return e.report;
  }
}
