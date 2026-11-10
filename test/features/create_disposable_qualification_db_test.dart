import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'milestone_4_5c_harness.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('Create and verify disposable qualification database with synthetic baseline ledger', () async {
    final outDir = Directory('/Users/sivek/.gemini/antigravity/brain/0b4f624c-ef34-4803-a00a-54c2a352048b/scratch');
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    final dbPath = '${outDir.path}/${SpendXM45CDisposableIsolation.qualificationDbName}';
    final dbFile = File(dbPath);
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }

    // 1. Verify strict disposable path isolation assertion
    SpendXM45CDisposableIsolation.assertDisposablePath(dbPath);
    expect(
      () => SpendXM45CDisposableIsolation.assertDisposablePath('/data/data/com.mashingdesigns.spend_x/databases/spendx.db'),
      throwsA(isA<DisposablePathViolationException>()),
    );

    // 2. Create and open disposable qualification database
    final db = await openDatabase(
      dbPath,
      version: 24,
    );

    // 3. Seed baseline synthetic ledger
    await SpendXM45CFinancialIntegrity.seedBaselineLedger(db);

    // 4. Run comprehensive financial invariant audit
    final audit = await SpendXM45CFinancialIntegrity.auditLedgerInvariants(db);

    expect(audit.isValid, isTrue, reason: 'Audit errors: ${audit.errors}');
    expect(audit.errors, isEmpty);
    expect(audit.deltaMinorUnits, equals(0));
    expect(audit.totalDebitMinorUnits, equals(1960000));
    expect(audit.totalCreditMinorUnits, equals(1960000));
    expect(audit.userVersion, equals(24));
    expect(audit.foreignKeyViolations, isEmpty);
    expect(audit.integrityCheckOutput, contains('ok'));

    print('QUAL_DB_PATH: $dbPath');
    print('QUAL_DB_SIZE: ${dbFile.lengthSync()}');
    print('QUAL_AUDIT_VALID: ${audit.isValid}');
    print('QUAL_DELTA: ${audit.deltaMinorUnits}');
    print('QUAL_TOTAL_DEBIT: ${audit.totalDebitMinorUnits}');
    print('QUAL_TOTAL_CREDIT: ${audit.totalCreditMinorUnits}');
    print('QUAL_INTEGRITY: ${audit.integrityCheckOutput.first}');

    await db.close();
  });
}
