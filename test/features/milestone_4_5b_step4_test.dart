import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/tracked_database_task_queue.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/domain/finance/economic_event.dart';
import 'package:spend_x/domain/finance/money.dart';
import 'package:spend_x/domain/finance/review_candidate.dart';
import 'package:spend_x/services/notification_service_v2.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

/// Milestone 4.5B Step 4: Background Callbacks During Pending or Exclusive Restore
///
/// ============================================================================
/// ARCHITECTURAL DISTINCTION: FAKE-BASED TESTS VS REAL ANDROID ENGINE TESTS
/// ============================================================================
/// 1. Dart Integration Test Environment (this suite):
///    - Executes real SQLite database transactions and schemas via [AppDatabase],
///      [SpendXDatabaseFactory], and [CanonicalReviewRepository].
///    - Exercises real Dart gate admission logic ([DatabaseAccessGate]) and the
///      background task queue ([TrackedDatabaseTaskQueue]).
///    - Invokes the production background notification entry point [notificationTapBackground].
///    - Uses [Step4MockProcessLockService] to deterministically emulate the
///      Android native process-lock plugin responses (MethodChannel IPC) and simulate
///      cross-process race conditions without flakiness or JVM child-process spawning.
///
/// 2. Real Android JVM Test Environment (`android/src/test/.../SpendXProcessLockLeaseManagerTest.kt`):
///    - Validates real OS file-descriptor locks via java.nio.channels.FileChannel.tryLock().
///    - Validates real multi-threaded ticket tracking with ConcurrentHashMap.
///    - Validates engine detachment reclamation and cross-engine ticket release prohibitions.
/// ============================================================================
///
/// Test mock of [PlatformProcessLockService] for Milestone 4.5B Step 4.
///
/// Deterministically models:
/// 1. OPEN state: permits foreground leases and background tickets.
/// 2. PENDING state (restore drain in flight): rejects new tickets and foreground leases
///    with [DatabaseAdmissionClosedException] (simulating native ADMISSION_CLOSED).
/// 3. EXCLUSIVE state (restore active): rejects new tickets and leases with
///    [DatabaseAdmissionClosedException].
/// 4. Reader/ticket tracking and strict ticket isolation.
class Step4MockProcessLockService implements PlatformProcessLockService {
  int acquireForegroundCount = 0;
  int releaseForegroundCount = 0;
  String? activeForegroundLeaseToken;

  int ticketCounter = 0;
  final Map<String, Map<String, dynamic>> activeTickets = {};
  int readersCount = 0;

  bool isRestorePending = false;
  bool isRestoreExclusiveHeld = false;

  final List<String> eventLog = [];

  @override
  MethodChannel get channel => const MethodChannel('spendx/process_lock');

  @override
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    eventLog.add('acquireForegroundLease:$engineId');
    if (isRestorePending || isRestoreExclusiveHeld) {
      throw const DatabaseAdmissionClosedException(
        'ADMISSION_CLOSED: Cannot acquire foreground lease while restore is pending or exclusive',
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
    eventLog.add('releaseForegroundLease:$leaseToken');
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
    eventLog.add('acquireOperationTicket:$tag');
    if (isRestorePending || isRestoreExclusiveHeld) {
      throw const DatabaseAdmissionClosedException(
        'ADMISSION_CLOSED: Cannot acquire operation ticket while restore is pending or exclusive',
      );
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
    eventLog.add('releaseOperationTicket:$ticketId');
    final ticket = activeTickets.remove(ticketId);
    if (ticket == null) {
      throw const StaleTicketException('Stale or unknown ticket');
    }
    readersCount = (readersCount - 1).clamp(0, 999999);
    return true;
  }

  @override
  Future<String> beginExclusiveRestore({
    int drainTimeoutMs = 5000,
    int contentionTimeoutMs = 5000,
  }) async {
    eventLog.add('beginExclusiveRestore');
    if (readersCount > 0) {
      throw StateError('Cannot acquire exclusive restore lock while readersCount ($readersCount) > 0');
    }
    isRestorePending = false;
    isRestoreExclusiveHeld = true;
    return 'restore_token_step4';
  }

  @override
  Future<bool> completeExclusiveRestore(String restoreToken) async {
    eventLog.add('completeExclusiveRestore:$restoreToken');
    isRestoreExclusiveHeld = false;
    return true;
  }

  @override
  Future<bool> abortExclusiveRestore(String restoreToken) async {
    eventLog.add('abortExclusiveRestore:$restoreToken');
    isRestoreExclusiveHeld = false;
    return true;
  }

  @override
  Future<bool> validateExclusiveRestoreToken(String restoreToken) async => true;

  @override
  Future<Map<String, dynamic>> getLockStatus() async {
    return {
      'state': isRestoreExclusiveHeld
          ? 'EXCLUSIVE_HELD'
          : (isRestorePending ? 'RESTORE_PENDING' : 'OPEN'),
      'activeReadersCount': readersCount,
      'activeTicketsCount': activeTickets.length,
      'hasForegroundLease': activeForegroundLeaseToken != null,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Step4MockProcessLockService mockLockService;
  late DatabaseAccessGate gate;
  late TrackedDatabaseTaskQueue taskQueue;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_4_5b_step4_test_');
    final dbFile = p.join(tempDir.path, 'spendx_step4.db');
    AppDatabase.setTestDatabasePath(dbFile);

    mockLockService = Step4MockProcessLockService();
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

  /// Helper to insert a candidate proposal directly via canonical repository into SQLite.
  Future<void> seedPendingCandidate(String reviewId, {double amount = 120.0}) async {
    final canonicalRepo = CanonicalReviewRepository();
    await canonicalRepo.createCandidate(
      ReviewCandidate(
        id: reviewId,
        sourceType: 'sms',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(amount),
        rawPayload: jsonEncode({
          'rawSource': 'Rs $amount spent at Test Store',
          'parsed': {
            'amount': amount,
            'isCredit': false,
            'rawText': 'Rs $amount spent at Test Store',
            'date': DateTime.now().toUtc().toIso8601String(),
            'merchant': 'Test Store',
            'confidence': 0.95,
          },
        }),
        confidenceScore: 0.95,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now().toUtc(),
      ),
    );
  }

  group('Milestone 4.5B — Step 4: Background Callbacks During Pending or Exclusive Restore', () {
    test('4.1. Callback before restore begins executes normally, releases ticket, and approves candidate', () async {
      final db = await AppDatabase.instance.database;
      expect(gate.isOpen, isTrue);

      final reviewId = 'rev_pre_restore_01';
      await seedPendingCandidate(reviewId, amount: 200.0);

      final candidateBefore = await CanonicalReviewRepository().getCandidate(reviewId);
      expect(candidateBefore, isNotNull);
      expect(candidateBefore!.status, equals(ReviewCandidateStatus.pending));

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': reviewId,
        }),
      );

      // Execute background callback before restore begins
      await notificationTapBackground(response);

      // Native ticket was acquired and released
      expect(
        mockLockService.eventLog.any((e) => e.startsWith('acquireOperationTicket:notification_tap_background')),
        isTrue,
      );
      expect(
        mockLockService.eventLog.any((e) => e.startsWith('releaseOperationTicket:ticket_')),
        isTrue,
      );
      expect(mockLockService.activeTickets.isEmpty, isTrue);

      // Candidate was approved
      final candidateAfter = await CanonicalReviewRepository().getCandidate(reviewId);
      expect(candidateAfter, isNotNull);
      expect(candidateAfter!.status, equals(ReviewCandidateStatus.approved));

      // No leaked tasks or active gate operations
      expect(taskQueue.activeTaskCount, 0);
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('4.2. Callback while restore is pending fails closed before DB access; valid readers retained', () async {
      final db = await AppDatabase.instance.database;
      expect(gate.isOpen, isTrue);

      final reviewId = 'rev_pending_drain_02';
      await seedPendingCandidate(reviewId, amount: 350.0);

      // Hold an admitted foreground operation so restore drain remains pending
      final admittedCompleter = Completer<void>();
      final admittedOpFuture = gate.admit(() async {
        await admittedCompleter.future;
        return 42;
      });

      expect(gate.activeOperations, 1);
      final initialReadersCount = mockLockService.readersCount;
      expect(initialReadersCount, 1); // Foreground lease active

      // Start restore drain: mock lock manager enters pending restore state
      mockLockService.isRestorePending = true;
      final drainFuture = gate.closeAdmissionAndDrain(timeout: const Duration(seconds: 5));
      expect(gate.isDraining, isTrue);

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': reviewId,
        }),
      );

      // Trigger background notification callback while restore drain is pending
      await notificationTapBackground(response);

      // Verification: Callback failed closed before DB or task queue access
      expect(mockLockService.activeTickets.isEmpty, isTrue);
      expect(taskQueue.activeTaskCount, 0);

      // Verification: Existing valid readers (foreground lease) are NOT incorrectly released
      expect(mockLockService.readersCount, initialReadersCount);

      // Now complete the held admitted operation to let drain finish
      admittedCompleter.complete();
      await admittedOpFuture;
      await drainFuture;

      expect(gate.isClosed, isTrue);
      expect(mockLockService.readersCount, 0); // Foreground lease released on drain complete

      await db.close();
    });

    test('4.3. Callbacks while exclusive restore is held abort before repository/SQLite access', () async {
      final db = await AppDatabase.instance.database;

      final expenseRevId = 'rev_exclusive_exp_03';
      final incomeRevId = 'rev_exclusive_inc_03';
      await seedPendingCandidate(expenseRevId, amount: 150.0);
      await seedPendingCandidate(incomeRevId, amount: 500.0);

      // Drain admission and transition to EXCLUSIVE restore ownership
      await gate.closeAdmissionAndDrain();
      expect(gate.isClosed, isTrue);

      final restoreToken = await mockLockService.beginExclusiveRestore();
      expect(mockLockService.isRestoreExclusiveHeld, isTrue);

      final expenseResponse = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': expenseRevId,
        }),
      );

      final incomeResponse = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveIncomeAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': incomeRevId,
        }),
      );

      // Trigger both callbacks while exclusive restore is held
      await notificationTapBackground(expenseResponse);
      await notificationTapBackground(incomeResponse);

      // Verification: No new tickets admitted
      expect(mockLockService.activeTickets.isEmpty, isTrue);
      expect(taskQueue.activeTaskCount, 0);
      expect(gate.activeOperations, 0);

      // Complete exclusive restore
      await mockLockService.completeExclusiveRestore(restoreToken);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      await db.close();
    });

    test('4.4. Callbacks during restore completion cannot slip through transition or reach partial DB', () async {
      final db = await AppDatabase.instance.database;

      final transitionRevId = 'rev_transition_04';
      await seedPendingCandidate(transitionRevId, amount: 777.0);

      // Quiesce gate and acquire exclusive restore
      await gate.closeAdmissionAndDrain();
      final restoreToken = await mockLockService.beginExclusiveRestore();

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': transitionRevId,
        }),
      );

      // Attempt callback while exclusive restore is being finalized (before completeExclusiveRestore)
      await notificationTapBackground(response);
      expect(mockLockService.activeTickets.isEmpty, isTrue);

      // Complete exclusive restore in native lock service, but gate admission is not yet reopened
      await mockLockService.completeExclusiveRestore(restoreToken);
      expect(gate.isClosed, isTrue);

      // Callback attempted before reopenAdmission() completes is still rejected
      // (defense-in-depth: gate remains closed until explicitly reopened)
      await notificationTapBackground(response);
      expect(mockLockService.activeTickets.isEmpty, isTrue);

      // Reopen gate admission
      await gate.reopenAdmission();
      expect(gate.isOpen, isTrue);

      // Now callback can execute cleanly against the restored database
      await notificationTapBackground(response);
      expect(mockLockService.activeTickets.isEmpty, isTrue);

      final candidate = await CanonicalReviewRepository().getCandidate(transitionRevId);
      expect(candidate, isNotNull);
      expect(candidate!.status, equals(ReviewCandidateStatus.approved));

      await db.close();
    });

    test('4.5. Pending review preservation: rejected callback never mutates or deletes pending review', () async {
      final db = await AppDatabase.instance.database;

      final preservedRevId = 'rev_preserve_candidate_05';
      await seedPendingCandidate(preservedRevId, amount: 888.0);

      // Verify pending status before restore
      final initialCandidate = await CanonicalReviewRepository().getCandidate(preservedRevId);
      expect(initialCandidate, isNotNull);
      expect(initialCandidate!.status, equals(ReviewCandidateStatus.pending));
      expect(initialCandidate.suggestedAmount.toRupees, equals(888.0));

      // Close admission and hold exclusive restore
      await gate.closeAdmissionAndDrain();
      final restoreToken = await mockLockService.beginExclusiveRestore();

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': preservedRevId,
        }),
      );

      // Trigger callback during restore hold (must fail closed)
      await notificationTapBackground(response);

      // Restore completes and gate reopens
      await mockLockService.completeExclusiveRestore(restoreToken);
      await gate.reopenAdmission();
      expect(gate.isOpen, isTrue);

      // Verification: The pending candidate was preserved completely intact
      final preservedCandidate = await CanonicalReviewRepository().getCandidate(preservedRevId);
      expect(preservedCandidate, isNotNull, reason: 'Pending candidate must not be deleted');
      expect(
        preservedCandidate!.status,
        equals(ReviewCandidateStatus.pending),
        reason: 'Pending candidate must remain in pending status',
      );
      expect(preservedCandidate.suggestedAmount.toRupees, equals(888.0));

      // Verification: Candidate can now be processed through normal in-app flow
      await CanonicalReviewRepository().approveCandidate(preservedRevId);
      final finalCandidate = await CanonicalReviewRepository().getCandidate(preservedRevId);
      expect(finalCandidate, isNotNull);
      expect(finalCandidate!.status, equals(ReviewCandidateStatus.approved));

      await db.close();
    });

    test('4.6. Concurrent callbacks during pending/exclusive restore are safely rejected with zero leaks', () async {
      final db = await AppDatabase.instance.database;

      // Close admission and hold exclusive restore
      await gate.closeAdmissionAndDrain();
      final restoreToken = await mockLockService.beginExclusiveRestore();

      // Dispatch 8 concurrent callbacks (4 expense, 4 income)
      final responses = List.generate(
        8,
        (i) => NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction,
          actionId: i.isEven
              ? NotificationServiceV2.liveExpenseAction
              : NotificationServiceV2.liveIncomeAction,
          payload: jsonEncode({
            'source_type': 'live_choice',
            'review_id': 'rev_concurrent_$i',
          }),
        ),
      );

      // Execute all concurrently
      await Future.wait(responses.map(notificationTapBackground));

      // Invariants:
      // 1. Zero leaked tickets
      expect(mockLockService.activeTickets.isEmpty, isTrue);
      // 2. Reader counts remain 0
      expect(mockLockService.readersCount, 0);
      // 3. No active tasks in queue
      expect(taskQueue.activeTaskCount, 0);
      // 4. Gate active operations remain 0
      expect(gate.activeOperations, 0);

      await mockLockService.completeExclusiveRestore(restoreToken);
      await gate.reopenAdmission();
      await db.close();
    });

    test('4.7. Defense-in-depth: Ticket acquired race caught by closed Gate/TaskQueue and ticket safely released', () async {
      final db = await AppDatabase.instance.database;

      final raceRevId = 'rev_race_defense_07';
      await seedPendingCandidate(raceRevId, amount: 444.0);

      // Quiesce gate to CLOSED state
      await gate.closeAdmissionAndDrain();
      expect(gate.isClosed, isTrue);

      // Keep mockLockService accepting tickets (simulating a ticket granted by native right before
      // native was informed of drain), but gate is already CLOSED in Dart
      mockLockService.isRestorePending = false;
      mockLockService.isRestoreExclusiveHeld = false;

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': raceRevId,
        }),
      );

      // Execute callback: ticket is acquired, but TrackedDatabaseTaskQueue.instance.run throws DatabaseGateClosedException
      await notificationTapBackground(response);

      // Verification: The ticket was safely released in finally block
      expect(mockLockService.activeTickets.isEmpty, isTrue);
      expect(mockLockService.eventLog.any((e) => e.startsWith('releaseOperationTicket:ticket_')), isTrue);
      expect(taskQueue.activeTaskCount, 0);

      // Candidate was preserved in pending status
      await gate.reopenAdmission();
      final candidate = await CanonicalReviewRepository().getCandidate(raceRevId);
      expect(candidate, isNotNull);
      expect(candidate!.status, equals(ReviewCandidateStatus.pending));

      await db.close();
    });

    test('4.8. Invalid or malformed notification actions abort without acquiring ticket or touching DB', () async {
      final initialLogCount = mockLockService.eventLog.length;

      // 1. Non-matching actionId
      await notificationTapBackground(
        const NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction,
          actionId: 'arbitrary_action',
          payload: '{"source_type":"live_choice","review_id":"123"}',
        ),
      );

      // 2. Empty payload
      await notificationTapBackground(
        NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction,
          actionId: NotificationServiceV2.liveExpenseAction,
          payload: '',
        ),
      );

      // 3. Non-live_choice source_type
      await notificationTapBackground(
        NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction,
          actionId: NotificationServiceV2.liveExpenseAction,
          payload: jsonEncode({'source_type': 'reminder', 'review_id': '123'}),
        ),
      );

      // 4. Missing review_id
      await notificationTapBackground(
        NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction,
          actionId: NotificationServiceV2.liveExpenseAction,
          payload: jsonEncode({'source_type': 'live_choice'}),
        ),
      );

      // Zero ticket calls made
      expect(
        mockLockService.eventLog.sublist(initialLogCount).where((e) => e.startsWith('acquireOperationTicket')),
        isEmpty,
      );
      expect(mockLockService.activeTickets.isEmpty, isTrue);
      expect(gate.activeOperations, 0);
    });
  });
}
