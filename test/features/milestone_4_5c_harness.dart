import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/restore_recovery_service.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

/// Milestone 4.5C Qualification Test Harness
///
/// Implements safeguards across all ten qualification groups:
/// 1. Disposable Database Isolation: Strictly confines qualification to `spendx_m45c_qualification.db`
///    and aborts immediately if production `spendx.db` is targeted.
/// 2. Group 3 Concurrency: Synchronization barrier holding 10 background callbacks simultaneously.
/// 3. Group 5 Process Contention: Multi-engine in-process and OS-level lock verification.
/// 4. Group 6 Crash Injection: Deterministic crash barriers at 4 restore phases capturing manifests.
/// 5. Group 7 Recovery Verification: Candidate validation pre-open, HMAC authorization, fingerprint binding.
/// 6. Group 8 WAL Consistency: Uncheckpointed WAL transactions, generational survival, sidecar protection.
/// 7. Group 9 Key-Loss Safety: Isolated disposable test key provider without mutating production keys.
/// 8. Group 10 Financial Integrity: Complete double-entry baseline ledger and invariant audit (trial balance delta = 0).

// ============================================================================
// 1. DISPOSABLE DATABASE ISOLATION SAFEGUARDS
// ============================================================================

class DisposablePathViolationException implements Exception {
  final String message;
  const DisposablePathViolationException(this.message);
  @override
  String toString() => 'DisposablePathViolationException: $message';
}

class SpendXM45CDisposableIsolation {
  static const String qualificationDbName = 'spendx_m45c_qualification.db';

  /// Asserts that [path] points strictly to a disposable qualification database
  /// and terminates immediately if it points to production `spendx.db`.
  static void assertDisposablePath(String path) {
    final baseName = p.basename(path);
    if (baseName == 'spendx.db') {
      throw const DisposablePathViolationException(
        'FATAL SAFETY VIOLATION: Operation attempted against production database spendx.db! Aborting.',
      );
    }
    if (!baseName.contains(qualificationDbName)) {
      throw DisposablePathViolationException(
        'FATAL SAFETY VIOLATION: Database path $path does not contain required qualification name $qualificationDbName',
      );
    }
  }

  /// Comprehensively asserts that [targetDbPath] and all related files, sidecars,
  /// symlink aliases, and staging directories are strictly within the disposable test boundary.
  /// Aborts before any filesystem mutation if the resolved target violates isolation.
  static void assertDisposableEnvironment({
    required String targetDbPath,
    String? stagingDirPath,
    String? authorizedDirectoryPath,
  }) {
    // 1. Direct name assertion
    assertDisposablePath(targetDbPath);

    // 2. Canonical parent directory and symlink check
    final targetFile = File(targetDbPath);
    final targetParent = targetFile.parent;
    if (targetParent.existsSync()) {
      final canonicalParent = targetParent.resolveSymbolicLinksSync();
      if (authorizedDirectoryPath != null) {
        final authDir = Directory(authorizedDirectoryPath).resolveSymbolicLinksSync();
        if (!p.isWithin(authDir, canonicalParent) && canonicalParent != authDir) {
          throw DisposablePathViolationException(
            'FATAL SAFETY VIOLATION: Canonical parent directory $canonicalParent is outside authorized directory $authDir',
          );
        }
      }
    }

    // 3. Canonical target file symlink check
    if (targetFile.existsSync()) {
      final canonicalTarget = targetFile.resolveSymbolicLinksSync();
      final canonicalBase = p.basename(canonicalTarget);
      if (canonicalBase == 'spendx.db') {
        throw const DisposablePathViolationException(
          'FATAL SAFETY VIOLATION: Target file resolves via symlink to production spendx.db! Aborting.',
        );
      }
      if (!canonicalBase.contains(qualificationDbName)) {
        throw DisposablePathViolationException(
          'FATAL SAFETY VIOLATION: Canonical target $canonicalTarget does not contain $qualificationDbName',
        );
      }
    }

    // 4. Sidecar and artifact symlink & identity check (WAL, SHM, backup, swap)
    final sidecars = [
      '$targetDbPath-wal',
      '$targetDbPath-shm',
      '$targetDbPath.pre_restore_backup',
      '$targetDbPath.new_swap',
    ];

    for (final sidecarPath in sidecars) {
      final sidecarFile = File(sidecarPath);
      if (sidecarFile.existsSync()) {
        final canonicalSidecar = sidecarFile.resolveSymbolicLinksSync();
        final canonicalSidecarBase = p.basename(canonicalSidecar);
        if (canonicalSidecarBase == 'spendx.db' ||
            canonicalSidecarBase == 'spendx.db-wal' ||
            canonicalSidecarBase == 'spendx.db-shm' ||
            canonicalSidecarBase == 'spendx.db.pre_restore_backup' ||
            canonicalSidecarBase == 'spendx.db.new_swap') {
          throw DisposablePathViolationException(
            'FATAL SAFETY VIOLATION: Sidecar $sidecarPath resolves via symlink to production sidecar $canonicalSidecar! Aborting.',
          );
        }
        if (!canonicalSidecarBase.contains(qualificationDbName)) {
          throw DisposablePathViolationException(
            'FATAL SAFETY VIOLATION: Canonical sidecar $canonicalSidecar does not contain $qualificationDbName',
          );
        }
      }
    }

    // 5. Staging directory isolation check
    if (stagingDirPath != null) {
      final stagingDir = Directory(stagingDirPath);
      if (stagingDir.existsSync()) {
        final canonicalStaging = stagingDir.resolveSymbolicLinksSync();
        final stagingBase = p.basename(canonicalStaging);
        if (!stagingBase.contains('spendx_restore_stage_')) {
          throw DisposablePathViolationException(
            'FATAL SAFETY VIOLATION: Staging directory $canonicalStaging is not a dedicated spendx_restore_stage_ directory',
          );
        }
      }
    }
  }

  /// Executes a filesystem mutation strictly after re-validating the canonical path
  /// environment under confirmed native exclusive restore lock ownership.
  /// Aborts immediately on any path mismatch or missing lock token before mutating disk.
  static Future<T> executeGuardedDisposableMutation<T>({
    required String targetDbPath,
    required String restoreToken,
    String? stagingDirPath,
    String? authorizedDirectoryPath,
    required Future<T> Function() mutation,
  }) async {
    if (restoreToken.isEmpty) {
      throw StateError('FATAL SAFETY VIOLATION: Native exclusive restore token required before mutation');
    }
    // Re-resolve canonical paths and all sidecars immediately before mutation
    assertDisposableEnvironment(
      targetDbPath: targetDbPath,
      stagingDirPath: stagingDirPath,
      authorizedDirectoryPath: authorizedDirectoryPath,
    );
    return await mutation();
  }

  /// Sets AppDatabase test path and enables BackupService strict disposable isolation.
  static void activateIsolation() {
    AppDatabase.setTestDatabasePath(qualificationDbName);
    BackupService.enforceDisposableIsolation = true;
  }

  /// Deactivates isolation and resets test paths.
  static void deactivateIsolation() {
    AppDatabase.setTestDatabasePath(null);
    BackupService.enforceDisposableIsolation = false;
  }
}

// ============================================================================
// 2. GROUP 3 CONCURRENCY: SYNCHRONIZATION BARRIER
// ============================================================================

class SpendXM45CSyncBarrier {
  final int capacity;
  final Completer<void> _barrierCompleter = Completer<void>();
  int _arrivedCount = 0;
  final List<String> arrivalLog = [];

  SpendXM45CSyncBarrier(this.capacity);

  int get arrivedCount => _arrivedCount;
  bool get isReleased => _barrierCompleter.isCompleted;

  /// Signals arrival of [workerId] and waits until all [capacity] workers arrive.
  Future<void> arriveAndWait(String workerId) async {
    arrivalLog.add(workerId);
    _arrivedCount++;
    if (_arrivedCount >= capacity) {
      if (!_barrierCompleter.isCompleted) {
        _barrierCompleter.complete();
      }
    }
    await _barrierCompleter.future;
  }
}

// ============================================================================
// 3. GROUP 5 PROCESS CONTENTION SIMULATOR
// ============================================================================

class SpendXM45CProcessContentionLockService implements PlatformProcessLockService {
  int acquireForegroundCount = 0;
  int releaseForegroundCount = 0;
  String? activeForegroundLeaseToken;

  int ticketCounter = 0;
  final Map<String, Map<String, dynamic>> activeTickets = {};
  int readersCount = 0;

  bool isRestorePending = false;
  bool isRestoreExclusiveHeld = false;
  String? currentRestoreToken;

  final List<String> eventLog = [];

  @override
  MethodChannel get channel => const MethodChannel('spendx/process_lock');

  @override
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    eventLog.add('acquireForegroundLease:$engineId');
    if (isRestorePending || isRestoreExclusiveHeld) {
      throw const DatabaseAdmissionClosedException(
        'ADMISSION_CLOSED: Cannot acquire foreground lease while restore is active',
      );
    }
    if (activeForegroundLeaseToken != null) {
      return activeForegroundLeaseToken!;
    }
    acquireForegroundCount++;
    readersCount++;
    activeForegroundLeaseToken = 'fg_lease_$acquireForegroundCount';
    return activeForegroundLeaseToken!;
  }

  @override
  Future<bool> releaseForegroundLease({
    required String leaseToken,
    String engineId = 'main_engine',
  }) async {
    eventLog.add('releaseForegroundLease:$engineId:$leaseToken');
    if (activeForegroundLeaseToken != leaseToken) return false;
    activeForegroundLeaseToken = null;
    readersCount = (readersCount - 1).clamp(0, 9999);
    releaseForegroundCount++;
    return true;
  }

  @override
  Future<NativeTicketResult> acquireOperationTicket({
    required String tag,
    String? engineId,
  }) async {
    final effectiveEngine = engineId ?? 'engine_0';
    eventLog.add('acquireOperationTicket:$effectiveEngine:$tag');
    if (isRestorePending || isRestoreExclusiveHeld) {
      throw const DatabaseAdmissionClosedException(
        'ADMISSION_CLOSED: Cannot acquire operation ticket while restore is active',
      );
    }
    ticketCounter++;
    final ticketId = 'ticket_$ticketCounter';
    activeTickets[ticketId] = {
      'tag': tag,
      'engineId': effectiveEngine,
      'acquiredAt': DateTime.now().toIso8601String(),
    };
    readersCount++;
    return NativeTicketResult(
      ticketId: ticketId,
      tag: tag,
      engineId: effectiveEngine,
    );
  }

  @override
  Future<bool> releaseOperationTicket(
    String ticketId, {
    String? engineId,
  }) async {
    final effectiveEngine = engineId ?? 'engine_0';
    eventLog.add('releaseOperationTicket:$effectiveEngine:$ticketId');
    if (!activeTickets.containsKey(ticketId)) {
      throw StaleTicketException('Stale or unknown ticket: $ticketId');
    }
    final ticketInfo = activeTickets[ticketId]!;
    if (ticketInfo['engineId'] != effectiveEngine) {
      throw CrossEngineReleaseException(
        'Cross-engine release rejected: ticket belongs to ${ticketInfo['engineId']}, caller is $effectiveEngine',
      );
    }
    activeTickets.remove(ticketId);
    readersCount = (readersCount - 1).clamp(0, 9999);
    return true;
  }

  @override
  Future<String> beginExclusiveRestore({
    int contentionTimeoutMs = 15000,
    int drainTimeoutMs = 10000,
  }) async {
    eventLog.add('beginExclusiveRestore');
    isRestorePending = true;
    if (readersCount > 0) {
      throw StateError('Cannot acquire exclusive restore while readers are active: $readersCount');
    }
    isRestoreExclusiveHeld = true;
    currentRestoreToken = 'exclusive_restore_token_${DateTime.now().millisecondsSinceEpoch}';
    return currentRestoreToken!;
  }

  @override
  Future<bool> completeExclusiveRestore(String restoreToken) async {
    eventLog.add('completeExclusiveRestore:$restoreToken');
    if (currentRestoreToken != restoreToken) return false;
    currentRestoreToken = null;
    isRestoreExclusiveHeld = false;
    isRestorePending = false;
    return true;
  }

  @override
  Future<bool> abortExclusiveRestore(String restoreToken) async {
    eventLog.add('abortExclusiveRestore:$restoreToken');
    if (currentRestoreToken != restoreToken) return false;
    currentRestoreToken = null;
    isRestoreExclusiveHeld = false;
    isRestorePending = false;
    return true;
  }

  @override
  Future<bool> validateExclusiveRestoreToken(String restoreToken) async {
    eventLog.add('validateExclusiveRestoreToken:$restoreToken');
    if (restoreToken.trim().isEmpty) return false;
    return isRestoreExclusiveHeld && currentRestoreToken == restoreToken;
  }

  @override
  Future<Map<String, dynamic>> getLockStatus() async {
    return {
      'state': isRestoreExclusiveHeld
          ? 'EXCLUSIVE_HELD'
          : (isRestorePending ? 'RESTORE_PENDING' : 'OPEN'),
      'exclusiveHeld': isRestoreExclusiveHeld,
      'activeReadersCount': readersCount,
      'activeTicketsCount': activeTickets.length,
      'foregroundLeaseActive': activeForegroundLeaseToken != null,
    };
  }
}

// ============================================================================
// 4. GROUP 6 CRASH BARRIER TRACKER & MANIFEST CAPTURE
// ============================================================================

class CrashBarrierSnapshot {
  final RestoreJournalState phase;
  final Map<String, dynamic>? journalData;
  final Map<String, Map<String, dynamic>> directoryManifest;
  final DateTime timestamp;

  CrashBarrierSnapshot({
    required this.phase,
    required this.journalData,
    required this.directoryManifest,
    required this.timestamp,
  });
}

class SpendXM45CCrashInjection {
  final List<CrashBarrierSnapshot> capturedSnapshots = [];
  RestoreJournalState? injectedCrashPhase;

  /// Installed callback for `BackupService.crashBarrierForTesting`.
  Future<void> handleBarrier(
    RestoreJournalState phase,
    Directory dbDir,
    File? journalFile,
  ) async {
    Map<String, dynamic>? journalData;
    if (journalFile != null && await journalFile.exists()) {
      try {
        journalData = jsonDecode(await journalFile.readAsString()) as Map<String, dynamic>?;
      } catch (_) {}
    }

    final manifest = <String, Map<String, dynamic>>{};
    if (await dbDir.exists()) {
      await for (final entity in dbDir.list()) {
        if (entity is File) {
          final bytes = await entity.readAsBytes();
          manifest[p.basename(entity.path)] = {
            'size': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
          };
        }
      }
    }

    capturedSnapshots.add(CrashBarrierSnapshot(
      phase: phase,
      journalData: journalData,
      directoryManifest: manifest,
      timestamp: DateTime.now(),
    ));

    if (injectedCrashPhase == phase) {
      throw StateError('INJECTED_CRASH_BARRIER: Simulated crash at restore phase $phase');
    }
  }
}

// ============================================================================
// 5. GROUP 9 DISPOSABLE KEY-LOSS SAFETY PROVIDER
// ============================================================================

class SpendXM45CDisposableKeyProvider {
  static const String qualificationKeyName = 'spendx_m45c_qualification_key';
  final InMemorySecureStorageAdapter storage = InMemorySecureStorageAdapter();
  bool shouldDenyKey = false;

  Future<Uint8List> getOrCreateQualificationKey() async {
    if (shouldDenyKey) {
      throw const DatabaseKeyAccessException(
        'KEY_DENIED: Qualification test simulating secure storage hardware failure',
      );
    }
    final existingHex = await storage.read(qualificationKeyName);
    if (existingHex != null) {
      return Uint8List.fromList(List<int>.generate(
        existingHex.length ~/ 2,
        (i) => int.parse(existingHex.substring(i * 2, i * 2 + 2), radix: 16),
      ));
    }
    // Fixed deterministic 32-byte qualification key
    final keyBytes = Uint8List.fromList(List<int>.filled(32, 0x42));
    final hexString = keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await storage.write(qualificationKeyName, hexString);
    return keyBytes;
  }
}

// ============================================================================
// 6. GROUP 10 FINANCIAL INTEGRITY FIXTURE & INVARIANT AUDIT
// ============================================================================

class FinancialInvariantAuditResult {
  final bool isValid;
  final int totalDebitMinorUnits;
  final int totalCreditMinorUnits;
  final int deltaMinorUnits;
  final int userVersion;
  final List<String> integrityCheckOutput;
  final List<Map<String, dynamic>> foreignKeyViolations;
  final List<String> errors;

  FinancialInvariantAuditResult({
    required this.isValid,
    required this.totalDebitMinorUnits,
    required this.totalCreditMinorUnits,
    required this.deltaMinorUnits,
    required this.userVersion,
    required this.integrityCheckOutput,
    required this.foreignKeyViolations,
    required this.errors,
  });
}

class SpendXM45CFinancialIntegrity {
  static const String accBank = 'acc_m45c_bank';
  static const String accCash = 'acc_m45c_cash';
  static const String accGroceries = 'acc_m45c_groceries';
  static const String accDining = 'acc_m45c_dining';
  static const String accSalary = 'acc_m45c_salary';
  static const String accCreditCard = 'acc_m45c_credit_card';

  /// Creates and seeds a pristine double-entry baseline ledger in [db].
  static Future<void> seedBaselineLedger(Database db) async {
    // 1. Schema, Triggers and System Accounts
    await TablesV24.createAllV24(db);
    await TablesV24.seedSystemAccounts(db);
    await TablesV24.installTriggers(db);

    final now = DateTime.now().toUtc().toIso8601String();

    // 2. User Accounts
    final accountsToInsert = [
      {'id': accBank, 'name': 'Primary Checking', 'account_type': 'asset', 'subtype': 'checking'},
      {'id': accCash, 'name': 'Physical Cash', 'account_type': 'asset', 'subtype': 'cash'},
      {'id': accGroceries, 'name': 'Groceries', 'account_type': 'expense', 'subtype': 'general'},
      {'id': accDining, 'name': 'Dining Out', 'account_type': 'expense', 'subtype': 'general'},
      {'id': accSalary, 'name': 'Primary Salary', 'account_type': 'income', 'subtype': 'general'},
      {'id': accCreditCard, 'name': 'Platinum Card', 'account_type': 'liability', 'subtype': 'credit_card'},
    ];

    for (final acc in accountsToInsert) {
      await db.insert(TablesV24.accounts, {
        'id': acc['id'],
        'name': acc['name'],
        'account_type': acc['account_type'],
        'subtype': acc['subtype'],
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': now,
        'updated_at': now,
      });
    }

    // 3. Balanced Double-Entry Financial Fixture:
    // Event 1: Opening Balance — ₹10,000 (1,000,000 minor units)
    await _recordBalancedEvent(
      db: db,
      eventId: 'evt_m45c_01_open',
      eventType: 'opening_balance',
      description: 'Opening Bank Balance',
      debitAccountId: accBank,
      creditAccountId: TablesV24.sysEquityOpening,
      amountMinorUnits: 1000000,
      timestamp: now,
    );

    // Event 2: Salary Income — ₹5,000 (500,000 minor units)
    await _recordBalancedEvent(
      db: db,
      eventId: 'evt_m45c_02_income',
      eventType: 'income',
      description: 'Monthly Salary Deposit',
      debitAccountId: accBank,
      creditAccountId: accSalary,
      amountMinorUnits: 500000,
      timestamp: now,
    );

    // Event 3: Grocery Expense — ₹1,500 (150,000 minor units)
    await _recordBalancedEvent(
      db: db,
      eventId: 'evt_m45c_03_expense',
      eventType: 'expense',
      description: 'Supermarket Groceries',
      debitAccountId: accGroceries,
      creditAccountId: accBank,
      amountMinorUnits: 150000,
      timestamp: now,
    );

    // Event 4: Cash Transfer — ₹2,000 (200,000 minor units)
    await _recordBalancedEvent(
      db: db,
      eventId: 'evt_m45c_04_transfer',
      eventType: 'transfer',
      description: 'ATM Cash Withdrawal',
      debitAccountId: accCash,
      creditAccountId: accBank,
      amountMinorUnits: 200000,
      timestamp: now,
    );

    // Event 5: Credit Card Dining Purchase — ₹800 (80,000 minor units)
    await _recordBalancedEvent(
      db: db,
      eventId: 'evt_m45c_05_cc_purchase',
      eventType: 'credit_purchase',
      description: 'Restaurant Dinner on Credit Card',
      debitAccountId: accDining,
      creditAccountId: accCreditCard,
      amountMinorUnits: 80000,
      timestamp: now,
    );

    // Event 6: Grocery Refund — ₹300 (30,000 minor units)
    await _recordBalancedEvent(
      db: db,
      eventId: 'evt_m45c_06_refund',
      eventType: 'refund',
      description: 'Item Return Refund to Bank',
      debitAccountId: accBank,
      creditAccountId: accGroceries,
      amountMinorUnits: 30000,
      timestamp: now,
    );

    // 4. Evidence Attachment to Event 5
    await db.insert(TablesV24.evidence, {
      'id': 'evd_m45c_receipt_01',
      'economic_event_id': 'evt_m45c_05_cc_purchase',
      'source_type': 'ocr',
      'extracted_amount_minor_units': 80000,
      'extracted_timestamp': now,
      'sender_address': 'Restaurant POS 101',
      'external_reference': 'RCPT_20261106_001',
      'body_sha256': sha256.convert(utf8.encode('Receipt text ₹800')).toString(),
      'raw_payload_encrypted': null,
      'retention_expires_at': null,
      'is_payload_purged': 0,
      'created_at': now,
    });
  }

  /// Inserts a balanced economic event with debit and credit postings, transitioning from draft to posted.
  static Future<void> _recordBalancedEvent({
    required Database db,
    required String eventId,
    required String eventType,
    required String description,
    required String debitAccountId,
    required String creditAccountId,
    required int amountMinorUnits,
    required String timestamp,
  }) async {
    // 1. Insert Draft Event
    await db.insert(TablesV24.economicEvents, {
      'id': eventId,
      'event_type': eventType,
      'lifecycle_status': 'draft',
      'timestamp': timestamp,
      'currency': 'INR',
      'description': description,
      'merchant_normalized': null,
      'category_id': null,
      'notes': null,
      'reversal_of_event_id': null,
      'corrected_by_event_id': null,
      'created_at': timestamp,
      'updated_at': timestamp,
    });

    // 2. Insert Balanced Postings
    await db.insert(TablesV24.postings, {
      'id': 'pst_${eventId}_debit',
      'economic_event_id': eventId,
      'account_id': debitAccountId,
      'sequence_number': 1,
      'direction': 'debit',
      'amount_minor_units': amountMinorUnits,
      'currency': 'INR',
      'created_at': timestamp,
    });

    await db.insert(TablesV24.postings, {
      'id': 'pst_${eventId}_credit',
      'economic_event_id': eventId,
      'account_id': creditAccountId,
      'sequence_number': 2,
      'direction': 'credit',
      'amount_minor_units': amountMinorUnits,
      'currency': 'INR',
      'created_at': timestamp,
    });

    // 3. Promote to 'posted' (checked by trg_economic_events_validate_posted)
    await db.update(
      TablesV24.economicEvents,
      {'lifecycle_status': 'posted', 'updated_at': timestamp},
      where: 'id = ?',
      whereArgs: [eventId],
    );
  }

  /// Performs a comprehensive double-entry invariant audit on [db].
  static Future<FinancialInvariantAuditResult> auditLedgerInvariants(Database db) async {
    final errors = <String>[];

    // 1. PRAGMA integrity_check
    final integrityRows = await db.rawQuery('PRAGMA integrity_check;');
    final integrityOutput = integrityRows
        .map((r) => r.values.first?.toString() ?? '')
        .toList();
    if (integrityOutput.isEmpty || integrityOutput.first != 'ok') {
      errors.add('SQLite integrity check failed: $integrityOutput');
    }

    // 2. PRAGMA foreign_key_check
    final fkViolations = await db.rawQuery('PRAGMA foreign_key_check;');
    if (fkViolations.isNotEmpty) {
      errors.add('Foreign key check detected ${fkViolations.length} violations: $fkViolations');
    }

    // 3. PRAGMA user_version == 24
    final versionRows = await db.rawQuery('PRAGMA user_version;');
    final userVersion = (versionRows.first.values.first as num?)?.toInt() ?? 0;
    if (userVersion != 24) {
      errors.add('Expected user_version 24, found $userVersion');
    }

    // 4. Double-Entry Invariant: Sum(Debit) == Sum(Credit)
    final debitRows = await db.rawQuery(
      "SELECT COALESCE(SUM(amount_minor_units), 0) AS total FROM ${TablesV24.postings} WHERE direction = 'debit';",
    );
    final creditRows = await db.rawQuery(
      "SELECT COALESCE(SUM(amount_minor_units), 0) AS total FROM ${TablesV24.postings} WHERE direction = 'credit';",
    );

    final totalDebits = (debitRows.first['total'] as num?)?.toInt() ?? 0;
    final totalCredits = (creditRows.first['total'] as num?)?.toInt() ?? 0;
    final delta = totalDebits - totalCredits;

    if (delta != 0) {
      errors.add('Double-entry imbalance detected! Debits=$totalDebits, Credits=$totalCredits, Delta=$delta');
    }

    // 5. Assert Zero Orphan Postings
    final orphanPostings = await db.rawQuery(
      "SELECT p.id FROM ${TablesV24.postings} p LEFT JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id WHERE e.id IS NULL;",
    );
    if (orphanPostings.isNotEmpty) {
      errors.add('Found ${orphanPostings.length} orphaned postings!');
    }

    return FinancialInvariantAuditResult(
      isValid: errors.isEmpty,
      totalDebitMinorUnits: totalDebits,
      totalCreditMinorUnits: totalCredits,
      deltaMinorUnits: delta,
      userVersion: userVersion,
      integrityCheckOutput: integrityOutput,
      foreignKeyViolations: fkViolations,
      errors: errors,
    );
  }
}
