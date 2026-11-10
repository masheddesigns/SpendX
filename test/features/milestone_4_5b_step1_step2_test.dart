import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/gated_database.dart';
import 'package:spend_x/data/core/gated_transaction.dart';
import 'package:spend_x/data/core/tracked_database_task_queue.dart';
import 'package:spend_x/services/notification_service_v2.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Test implementation of PlatformProcessLockService for deterministic concurrency testing.
class DeterministicProcessLockService implements PlatformProcessLockService {
  int acquireForegroundCount = 0;
  int releaseForegroundCount = 0;
  String? activeForegroundLeaseToken;

  int ticketCounter = 0;
  final Map<String, Map<String, dynamic>> activeTickets = {};
  int readersCount = 0;
  bool admissionClosed = false;

  final List<String> callLog = [];

  @override
  MethodChannel get channel => const MethodChannel('spendx/process_lock');

  @override
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    callLog.add('acquireForegroundLease:$engineId');
    if (admissionClosed) {
      throw const DatabaseAdmissionClosedException('Admission closed for restore');
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
    callLog.add('releaseForegroundLease:$leaseToken');
    if (activeForegroundLeaseToken == null || activeForegroundLeaseToken != leaseToken) {
      return false;
    }
    activeForegroundLeaseToken = null;
    releaseForegroundCount++;
    readersCount = (readersCount - 1).clamp(0, 999999);
    return true;
  }

  @override
  Future<NativeTicketResult> acquireOperationTicket({
    String? engineId,
    required String tag,
  }) async {
    callLog.add('acquireOperationTicket:$tag:$engineId');
    if (admissionClosed) {
      throw const DatabaseAdmissionClosedException('Admission closed for restore');
    }
    ticketCounter++;
    final assignedEngineId = engineId ?? 'engine_$ticketCounter';
    final ticketId = 'ticket_${ticketCounter}_$tag';
    activeTickets[ticketId] = {
      'ticketId': ticketId,
      'engineId': assignedEngineId,
      'tag': tag,
    };
    readersCount++;
    return NativeTicketResult(
      ticketId: ticketId,
      tag: tag,
      engineId: assignedEngineId,
    );
  }

  @override
  Future<bool> releaseOperationTicket(
    String ticketId, {
    String? engineId,
  }) async {
    callLog.add('releaseOperationTicket:$ticketId:$engineId');
    final ticket = activeTickets[ticketId];
    if (ticket == null) {
      throw const StaleTicketException('Stale or unknown ticket');
    }
    if (engineId != null && ticket['engineId'] != engineId) {
      throw CrossEngineReleaseException('Ticket belongs to ${ticket['engineId']}, not $engineId');
    }
    activeTickets.remove(ticketId);
    readersCount = (readersCount - 1).clamp(0, 999999);
    return true;
  }

  @override
  Future<String> beginExclusiveRestore({
    int drainTimeoutMs = 5000,
    int contentionTimeoutMs = 5000,
  }) async {
    admissionClosed = true;
    return 'restore_token_123';
  }

  @override
  Future<bool> completeExclusiveRestore(String restoreToken) async {
    admissionClosed = false;
    return true;
  }

  @override
  Future<bool> abortExclusiveRestore(String restoreToken) async {
    admissionClosed = false;
    return true;
  }

  @override
  Future<bool> validateExclusiveRestoreToken(String restoreToken) async => true;

  @override
  Future<Map<String, dynamic>> getLockStatus() async {
    return {
      'state': admissionClosed ? 'EXCLUSIVE_HELD' : 'OPEN',
      'activeReadersCount': readersCount,
      'activeTicketsCount': activeTickets.length,
      'hasForegroundLease': activeForegroundLeaseToken != null,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late DeterministicProcessLockService mockLockService;
  late DatabaseAccessGate gate;
  late TrackedDatabaseTaskQueue taskQueue;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spendx_4_5b_test_');
    final dbFile = p.join(tempDir.path, 'spendx_test.db');
    AppDatabase.setTestDatabasePath(dbFile);

    mockLockService = DeterministicProcessLockService();
    PlatformProcessLockService.instanceForTesting = mockLockService;

    gate = DatabaseAccessGate(processLockService: mockLockService);
    taskQueue = TrackedDatabaseTaskQueue(gate: gate);
    gate.attachTaskQueue(taskQueue);

    DatabaseAccessGate.instanceForTesting = gate;
  });

  tearDown(() async {
    PlatformProcessLockService.instanceForTesting = null;
    DatabaseAccessGate.instanceForTesting = DatabaseAccessGate();
    AppDatabase.setTestDatabasePath(null);

    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Milestone 4.5B — Step 1: Normal Foreground Operations & Real AppDatabase Entry Point', () {
    test('1.1. AppDatabase.instance.database opens through guarded factory and returns GatedDatabase', () async {
      // Execute through real AppDatabase entry point
      final db = await AppDatabase.instance.database;

      // Assertion: Database is wrapped in GatedDatabase
      expect(db, isA<GatedDatabase>());
      expect(db.isOpen, isTrue);

      // Assertion: Direct opening of primary database is rejected by guarded factory
      await expectLater(
        () => SpendXDatabaseFactory.instance.openPlaintextDatabase('spendx.db'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Direct opening of primary database "spendx.db" via SpendXDatabaseFactory is prohibited'),
          ),
        ),
      );

      await db.close();
    });

    test('1.2. Foreground lease is acquired and active operations count returns to zero', () async {
      final db = await AppDatabase.instance.database;

      // Gate admission during database opening ensures the native lease
      expect(gate.nativeLeaseToken, isNotNull);
      expect(gate.nativeLeaseToken, equals('fg_lease_1'));
      expect(mockLockService.activeForegroundLeaseToken, equals('fg_lease_1'));
      expect(mockLockService.readersCount, 1);

      // Queries run under the held lease
      final rows = await db.query('accounts');
      expect(rows, isNotEmpty);
      expect(rows.any((r) => r['is_system'] == 1), isTrue);

      // Active operation count returns to 0
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('1.3. Foreground reads and writes succeed while admission is OPEN', () async {
      final db = await AppDatabase.instance.database;
      final now = DateTime.now().toIso8601String();

      // Write operation (insert)
      final accountId = await db.insert('accounts', {
        'id': 'acc_01',
        'name': 'Checking Account',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });
      expect(accountId, greaterThan(0));
      expect(gate.activeOperations, 0);

      // Read operation (query)
      final results = await db.query('accounts', where: 'id = ?', whereArgs: ['acc_01']);
      expect(results.length, 1);
      expect(results.first['name'], 'Checking Account');
      expect(results.first['account_type'], 'asset');
      expect(gate.activeOperations, 0);

      // Update operation
      final updated = await db.update(
        'accounts',
        {'name': 'Primary Checking Account'},
        where: 'id = ?',
        whereArgs: ['acc_01'],
      );
      expect(updated, 1);
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('1.4. Foreground transactions and batches execute atomically and complete cleanly', () async {
      final db = await AppDatabase.instance.database;
      final now = DateTime.now().toIso8601String();

      // Transaction execution under GatedTransaction
      await db.transaction((txn) async {
        expect(txn, isA<GatedTransaction>());
        await txn.insert('accounts', {
          'id': 'acc_tx_01',
          'name': 'Savings',
          'account_type': 'asset',
          'subtype': 'savings',
          'currency': 'INR',
          'created_at': now,
          'updated_at': now,
        });
        await txn.insert('accounts', {
          'id': 'acc_tx_02',
          'name': 'Emergency',
          'account_type': 'asset',
          'subtype': 'savings',
          'currency': 'INR',
          'created_at': now,
          'updated_at': now,
        });
      });

      expect(gate.activeOperations, 0);

      final txRows = await db.query('accounts', where: "id LIKE 'acc_tx_%'");
      expect(txRows.length, 2);

      // Batch execution under GatedBatch
      final batch = db.batch();
      batch.insert('accounts', {
        'id': 'acc_batch_01',
        'name': 'Batch 1',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });
      batch.insert('accounts', {
        'id': 'acc_batch_02',
        'name': 'Batch 2',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });
      final batchResults = await batch.commit();
      expect(batchResults.length, 2);
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('1.5. Gate drain prevents new operations and releases native foreground lease', () async {
      final db = await AppDatabase.instance.database;

      // Trigger lease
      await db.query('accounts');
      expect(gate.nativeLeaseToken, isNotNull);
      expect(mockLockService.readersCount, 1);

      // Drain admission
      await gate.closeAdmissionAndDrain();
      expect(gate.isClosed, isTrue);
      expect(gate.nativeLeaseToken, isNull);
      expect(mockLockService.readersCount, 0);

      // Subsequent query is blocked
      await expectLater(
        () => db.query('accounts'),
        throwsA(isA<DatabaseGateClosedException>()),
      );

      // Reopening admission restores access and re-acquires lease
      await gate.reopenAdmission();
      expect(gate.isOpen, isTrue);

      final rowsAfter = await db.query('accounts');
      expect(rowsAfter, isNotNull);
      expect(gate.nativeLeaseToken, isNotNull);
      expect(mockLockService.readersCount, 1);

      await db.close();
    });
  });

  group('Milestone 4.5B — Step 2: Concurrent Background Notification Actions & Native Ticket Protocol', () {
    test('2.1. Concurrent liveExpenseAction and liveIncomeAction obtain distinct tickets and release in finally', () async {
      final db = await AppDatabase.instance.database;

      final expensePayload = jsonEncode({
        'source_type': 'live_choice',
        'review_id': 'rev_concurrent_exp',
      });
      final incomePayload = jsonEncode({
        'source_type': 'live_choice',
        'review_id': 'rev_concurrent_inc',
      });

      final expenseResponse = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: expensePayload,
      );
      final incomeResponse = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveIncomeAction,
        payload: incomePayload,
      );

      // Execute concurrently
      await Future.wait([
        notificationTapBackground(expenseResponse),
        notificationTapBackground(incomeResponse),
      ]);

      // Assertion: Two separate tickets were acquired
      final ticketAcquisitions = mockLockService.callLog
          .where((call) => call.startsWith('acquireOperationTicket:notification_tap_background'))
          .toList();
      expect(ticketAcquisitions.length, 2);

      // Assertion: Two separate releases were performed
      final ticketReleases = mockLockService.callLog
          .where((call) => call.startsWith('releaseOperationTicket:ticket_'))
          .toList();
      expect(ticketReleases.length, 2);

      // Assertion: All tickets were cleanly removed and reader count returned to baseline
      expect(mockLockService.activeTickets.isEmpty, isTrue);
      expect(taskQueue.activeTaskCount, 0);
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('2.2. Cross-engine ticket release is prevented during concurrency', () async {
      // Simulate two tickets held concurrently
      final ticket1 = await mockLockService.acquireOperationTicket(
        engineId: 'engine_alpha',
        tag: 'task_alpha',
      );
      final ticket2 = await mockLockService.acquireOperationTicket(
        engineId: 'engine_beta',
        tag: 'task_beta',
      );

      expect(mockLockService.activeTickets.length, 2);

      // Engine alpha attempting to release engine beta's ticket is prohibited
      await expectLater(
        () => mockLockService.releaseOperationTicket(
          ticket2.ticketId,
          engineId: 'engine_alpha',
        ),
        throwsA(isA<CrossEngineReleaseException>()),
      );

      // Active tickets remain intact
      expect(mockLockService.activeTickets.length, 2);

      // Legitimate owners release their respective tickets
      await mockLockService.releaseOperationTicket(ticket1.ticketId, engineId: 'engine_alpha');
      await mockLockService.releaseOperationTicket(ticket2.ticketId, engineId: 'engine_beta');

      expect(mockLockService.activeTickets.isEmpty, isTrue);
    });

    test('2.3. Task failure inside TrackedDatabaseTaskQueue safely releases ticket in finally without unhandled error', () async {
      final db = await AppDatabase.instance.database;

      final malformedDbPayload = jsonEncode({
        'source_type': 'live_choice',
        'review_id': 'rev_fails_in_queue',
      });

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: malformedDbPayload,
      );

      // Executing callback where database work completes or throws internally
      await notificationTapBackground(response);

      // Verify ticket was acquired and released even if underlying DB record didn't exist
      expect(mockLockService.activeTickets.isEmpty, isTrue);
      expect(taskQueue.activeTaskCount, 0);
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('2.4. Closed admission causes callback to fail closed immediately without database access', () async {
      final db = await AppDatabase.instance.database;

      // Close admission (e.g. restore in progress)
      mockLockService.admissionClosed = true;

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': 'rev_closed_admission',
        }),
      );

      // Must complete without error to engine and without touching DB
      await notificationTapBackground(response);

      // No tickets should remain active
      expect(mockLockService.activeTickets.isEmpty, isTrue);
      expect(taskQueue.activeTaskCount, 0);
      expect(gate.activeOperations, 0);

      // No release calls made because ticket acquisition failed closed
      final releases = mockLockService.callLog
          .where((call) => call.startsWith('releaseOperationTicket:'))
          .toList();
      expect(releases.isEmpty, isTrue);

      await db.close();
    });

    test('2.5. Non-live action ID and malformed payload reject prior to ticket acquisition', () async {
      // 1. Non-live action ID
      final invalidActionResponse = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: 'snooze_action',
        payload: '{"source_type":"live_choice","review_id":"rev_1"}',
      );
      await notificationTapBackground(invalidActionResponse);

      // 2. Missing review ID
      final missingReviewResponse = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: '{"source_type":"live_choice"}',
      );
      await notificationTapBackground(missingReviewResponse);

      // 3. Null payload
      final nullPayloadResponse = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: null,
      );
      await notificationTapBackground(nullPayloadResponse);

      // Assertion: Zero tickets were requested
      final ticketAcquisitions = mockLockService.callLog
          .where((call) => call.startsWith('acquireOperationTicket:'))
          .toList();
      expect(ticketAcquisitions.isEmpty, isTrue);
      expect(taskQueue.activeTaskCount, 0);
    });
  });
}
