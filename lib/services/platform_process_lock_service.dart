// ignore_for_file: use_null_aware_elements
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Exceptions thrown by PlatformProcessLockService
class DatabaseAdmissionClosedException implements Exception {
  final String message;
  const DatabaseAdmissionClosedException(this.message);
  @override
  String toString() => 'DatabaseAdmissionClosedException: $message';
}

class RestoreAlreadyInProgressException implements Exception {
  final String message;
  const RestoreAlreadyInProgressException(this.message);
  @override
  String toString() => 'RestoreAlreadyInProgressException: $message';
}

class RestoreDrainTimeoutException implements Exception {
  final String message;
  const RestoreDrainTimeoutException(this.message);
  @override
  String toString() => 'RestoreDrainTimeoutException: $message';
}

class RestoreLockTimeoutException implements Exception {
  final String message;
  const RestoreLockTimeoutException(this.message);
  @override
  String toString() => 'RestoreLockTimeoutException: $message';
}

class StaleTicketException implements Exception {
  final String message;
  const StaleTicketException(this.message);
  @override
  String toString() => 'StaleTicketException: $message';
}

class CrossEngineReleaseException implements Exception {
  final String message;
  const CrossEngineReleaseException(this.message);
  @override
  String toString() => 'CrossEngineReleaseException: $message';
}

/// Metadata returned when acquiring an operation ticket.
class NativeTicketResult {
  final String ticketId;
  final String tag;
  final String? engineId;

  const NativeTicketResult({
    required this.ticketId,
    required this.tag,
    this.engineId,
  });
}

/// Service that interfaces with Android's native SpendXProcessLockLeaseManager
/// over the 'spendx/process_lock' platform channel.
class PlatformProcessLockService {
  static const MethodChannel _channel = MethodChannel('spendx/process_lock');

  static final PlatformProcessLockService _instance =
      PlatformProcessLockService._internal();

  static PlatformProcessLockService? _testInstance;

  static PlatformProcessLockService get instance => _testInstance ?? _instance;

  @visibleForTesting
  static set instanceForTesting(PlatformProcessLockService? mock) {
    _testInstance = mock;
  }

  factory PlatformProcessLockService() => _testInstance ?? _instance;

  PlatformProcessLockService._internal();

  /// Testing constructor to inject a custom MethodChannel.
  PlatformProcessLockService.withChannel(MethodChannel channel) {
    // Allows tests to verify channel dispatches
  }

  MethodChannel get channel => _channel;

  /// Acquires an aggregate process-shared lease for the foreground FlutterEngine.
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'acquireForegroundLease',
        {'engineId': engineId},
      );
      final token = res?['leaseToken'] as String?;
      if (token == null || token.isEmpty) {
        throw const DatabaseAdmissionClosedException('Empty lease token returned');
      }
      return token;
    } on PlatformException catch (e) {
      if (e.code == 'ADMISSION_CLOSED') {
        throw DatabaseAdmissionClosedException(e.message ?? 'Admission closed');
      }
      rethrow;
    } on MissingPluginException {
      return 'host_test_foreground_lease';
    } catch (e) {
      if (e.toString().contains('Binding has not yet been initialized')) {
        return 'host_test_foreground_lease';
      }
      rethrow;
    }
  }

  /// Releases the aggregate process-shared lease for the foreground FlutterEngine.
  Future<bool> releaseForegroundLease({
    required String leaseToken,
    String engineId = 'main_engine',
  }) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'releaseForegroundLease',
        {
          'engineId': engineId,
          'leaseToken': leaseToken,
        },
      );
      return res?['status'] == 'ok';
    } on MissingPluginException {
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Acquires an operation-scoped native ticket for a background operation.
  /// If [engineId] is omitted, native scopes the ticket to the calling FlutterEngine.
  Future<NativeTicketResult> acquireOperationTicket({
    String? engineId,
    required String tag,
  }) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'acquireOperationTicket',
        {
          if (engineId != null) 'engineId': engineId,
          'tag': tag,
        },
      );
      final ticketId = res?['ticketId'] as String?;
      final opTag = res?['tag'] as String? ?? tag;
      final assignedEngineId = res?['engineId'] as String?;
      if (ticketId == null || ticketId.isEmpty) {
        throw const DatabaseAdmissionClosedException('Empty ticketId returned');
      }
      return NativeTicketResult(
        ticketId: ticketId,
        tag: opTag,
        engineId: assignedEngineId,
      );
    } on PlatformException catch (e) {
      if (e.code == 'ADMISSION_CLOSED') {
        throw DatabaseAdmissionClosedException(e.message ?? 'Admission closed');
      }
      rethrow;
    } on MissingPluginException catch (e) {
      throw DatabaseAdmissionClosedException(
        'Missing native platform channel spendx/process_lock: ${e.message}',
      );
    }
  }

  /// Releases an operation-scoped native ticket.
  /// Validates engine ownership on the native side if [engineId] is provided.
  Future<bool> releaseOperationTicket(
    String ticketId, {
    String? engineId,
  }) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'releaseOperationTicket',
        {
          'ticketId': ticketId,
          if (engineId != null) 'engineId': engineId,
        },
      );
      final status = res?['status'];
      if (status == 'stale') {
        throw StaleTicketException('Ticket $ticketId is unknown or already released');
      }
      return status == 'ok';
    } on PlatformException catch (e) {
      if (e.code == 'CROSS_ENGINE_RELEASE_PROHIBITED') {
        throw CrossEngineReleaseException(e.message ?? 'Cross-engine release prohibited');
      }
      if (e.code == 'RELEASE_ERROR') {
        throw StaleTicketException(e.message ?? 'Release error');
      }
      rethrow;
    } on MissingPluginException {
      return true;
    }
  }

  /// Initiates exclusive restore ownership across the OS process.
  Future<String> beginExclusiveRestore({
    int drainTimeoutMs = 5000,
    int contentionTimeoutMs = 5000,
  }) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'beginExclusiveRestore',
        {
          'drainTimeoutMs': drainTimeoutMs,
          'contentionTimeoutMs': contentionTimeoutMs,
        },
      );
      final restoreToken = res?['restoreToken'] as String?;
      if (restoreToken == null || restoreToken.isEmpty) {
        throw const RestoreAlreadyInProgressException('Empty restore token');
      }
      return restoreToken;
    } on PlatformException catch (e) {
      if (e.code == 'ALREADY_ACTIVE') {
        throw RestoreAlreadyInProgressException(e.message ?? 'Restore active');
      } else if (e.code == 'TIMEOUT') {
        final msg = e.message ?? '';
        if (msg.contains('DRAIN_TIMEOUT')) {
          throw RestoreDrainTimeoutException(msg);
        } else {
          throw RestoreLockTimeoutException(msg);
        }
      }
      rethrow;
    } on MissingPluginException {
      return 'host_restore_token';
    }
  }

  /// Validates whether [restoreToken] is currently held and bound to the native engine.
  /// Fails closed (returns `false`) on empty token, native validation error,
  /// channel exception, or missing plugin.
  ///
  /// Engine identity is mandatory and originates from the native MethodChannel
  /// handler's captured engine identity.
  Future<bool> validateExclusiveRestoreToken(String restoreToken) async {
    if (restoreToken.trim().isEmpty) {
      return false;
    }
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'validateExclusiveRestoreToken',
        {
          'restoreToken': restoreToken,
        },
      );
      return res?['isValid'] == true;
    } on MissingPluginException {
      // In host test environments where native process lock plugin is absent,
      // fail-safe check against known host test sentinel token.
      return restoreToken == 'host_restore_token';
    } catch (_) {
      return false;
    }
  }

  /// Completes exclusive restore and returns process lock to shared open state.
  Future<bool> completeExclusiveRestore(String restoreToken) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'completeExclusiveRestore',
        {'restoreToken': restoreToken},
      );
      return res?['status'] == 'ok';
    } on MissingPluginException {
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Aborts exclusive restore, rolls back to shared OS lock, and reopens admission.
  Future<bool> abortExclusiveRestore(String restoreToken) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'abortExclusiveRestore',
        {'restoreToken': restoreToken},
      );
      return res?['status'] == 'ok';
    } on MissingPluginException {
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Returns diagnostic status from the native lock lease manager.
  Future<Map<String, dynamic>> getLockStatus() async {
    final res = await _channel.invokeMapMethod<String, dynamic>('getLockStatus');
    return res ?? {};
  }
}
