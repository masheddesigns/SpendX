import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('spendx/process_lock');
  late PlatformProcessLockService service;

  setUp(() {
    service = PlatformProcessLockService();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('PlatformProcessLockService Tests', () {
    test('acquireForegroundLease returns valid token on success', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'acquireForegroundLease') {
          expect(call.arguments['engineId'], 'main_engine');
          return {'status': 'ok', 'leaseToken': 'test_fg_lease_123'};
        }
        return null;
      });

      final token = await service.acquireForegroundLease();
      expect(token, 'test_fg_lease_123');
    });

    test('acquireForegroundLease maps ADMISSION_CLOSED PlatformException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'acquireForegroundLease') {
          throw PlatformException(
            code: 'ADMISSION_CLOSED',
            message: 'Admission closed for restore',
          );
        }
        return null;
      });

      expect(
        () => service.acquireForegroundLease(),
        throwsA(isA<DatabaseAdmissionClosedException>()),
      );
    });

    test('releaseForegroundLease dispatches token and returns true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'releaseForegroundLease') {
          expect(call.arguments['leaseToken'], 'test_fg_lease_123');
          return {'status': 'ok'};
        }
        return null;
      });

      final ok = await service.releaseForegroundLease(
        leaseToken: 'test_fg_lease_123',
      );
      expect(ok, isTrue);
    });

    test('acquireOperationTicket returns NativeTicketResult', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'acquireOperationTicket') {
          expect(call.arguments['engineId'], 'bg_engine');
          expect(call.arguments['tag'], 'sms_sync');
          return {
            'status': 'ok',
            'ticketId': 'ticket_uuid_456',
            'tag': 'sms_sync',
          };
        }
        return null;
      });

      final result = await service.acquireOperationTicket(
        engineId: 'bg_engine',
        tag: 'sms_sync',
      );
      expect(result.ticketId, 'ticket_uuid_456');
      expect(result.tag, 'sms_sync');
    });

    test('acquireOperationTicket maps ADMISSION_CLOSED exception', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'acquireOperationTicket') {
          throw PlatformException(
            code: 'ADMISSION_CLOSED',
            message: 'Restore in progress',
          );
        }
        return null;
      });

      expect(
        () => service.acquireOperationTicket(engineId: 'bg', tag: 'op'),
        throwsA(isA<DatabaseAdmissionClosedException>()),
      );
    });

    test('releaseOperationTicket throws StaleTicketException when status is stale', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'releaseOperationTicket') {
          return {'status': 'stale'};
        }
        return null;
      });

      expect(
        () => service.releaseOperationTicket('fake_ticket_id'),
        throwsA(isA<StaleTicketException>()),
      );
    });

    test('releaseOperationTicket throws CrossEngineReleaseException on CROSS_ENGINE_RELEASE_PROHIBITED', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'releaseOperationTicket') {
          throw PlatformException(
            code: 'CROSS_ENGINE_RELEASE_PROHIBITED',
            message: 'Ticket belongs to another engine',
          );
        }
        return null;
      });

      expect(
        () => service.releaseOperationTicket('ticket_123', engineId: 'mismatched_engine'),
        throwsA(isA<CrossEngineReleaseException>()),
      );
    });

    test('beginExclusiveRestore returns token and maps exceptions', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'beginExclusiveRestore') {
          return {'status': 'ok', 'restoreToken': 'restore_token_789'};
        }
        return null;
      });

      final token = await service.beginExclusiveRestore(
        drainTimeoutMs: 3000,
        contentionTimeoutMs: 3000,
      );
      expect(token, 'restore_token_789');
    });

    test('beginExclusiveRestore maps ALREADY_ACTIVE and TIMEOUT codes', () async {
      // Test ALREADY_ACTIVE
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(
          code: 'ALREADY_ACTIVE',
          message: 'Restore already in progress',
        );
      });

      expect(
        () => service.beginExclusiveRestore(),
        throwsA(isA<RestoreAlreadyInProgressException>()),
      );

      // Test DRAIN_TIMEOUT
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(
          code: 'TIMEOUT',
          message: 'DRAIN_TIMEOUT: active readers failed to drain',
        );
      });

      expect(
        () => service.beginExclusiveRestore(),
        throwsA(isA<RestoreDrainTimeoutException>()),
      );

      // Test EXCLUSIVE_LOCK_TIMEOUT
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(
          code: 'TIMEOUT',
          message: 'EXCLUSIVE_LOCK_TIMEOUT: contention timeout',
        );
      });

      expect(
        () => service.beginExclusiveRestore(),
        throwsA(isA<RestoreLockTimeoutException>()),
      );
    });

    test('completeExclusiveRestore and abortExclusiveRestore return true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'completeExclusiveRestore' ||
            call.method == 'abortExclusiveRestore') {
          return {'status': 'ok'};
        }
        return null;
      });

      final completeOk = await service.completeExclusiveRestore('token_1');
      expect(completeOk, isTrue);

      final abortOk = await service.abortExclusiveRestore('token_1');
      expect(abortOk, isTrue);
    });

    test('getLockStatus returns diagnostic map', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'getLockStatus') {
          return {
            'state': 'OPEN',
            'activeReadersCount': 2,
            'isRestorePending': false,
            'exclusiveHeld': false,
          };
        }
        return null;
      });

      final status = await service.getLockStatus();
      expect(status['state'], 'OPEN');
      expect(status['activeReadersCount'], 2);
      expect(status['isRestorePending'], isFalse);
    });
  });
}
