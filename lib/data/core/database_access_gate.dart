import 'dart:async';
import 'package:sqflite/sqflite.dart';
import '../../services/platform_process_lock_service.dart';
import 'gated_database.dart';
import 'gated_transaction.dart';
import 'tracked_database_task_queue.dart';

/// Conceptual state of the in-isolate DatabaseAccessGate.
enum GateState {
  /// Normal operational state: reads and financial writes admitted.
  open,

  /// Admission closed for backup/restore: in-flight operations draining.
  draining,

  /// Completely quiesced: 0 active operations, native shared lease released.
  closed,
}

/// Thrown when an operation attempts to acquire admission while the gate is closed or draining.
class DatabaseGateClosedException implements Exception {
  final String message;
  const DatabaseGateClosedException(this.message);
  @override
  String toString() => 'DatabaseGateClosedException: $message';
}

/// Thrown when an escaped transaction handle or expired transaction zone is used
/// after its callback has completed.
class DatabaseTransactionClosedException implements Exception {
  final String message;
  const DatabaseTransactionClosedException(this.message);
  @override
  String toString() => 'DatabaseTransactionClosedException: $message';
}

/// Token representing the active lifetime of a transaction admission zone.
///
/// When the transaction callback completes, this token is invalidated. Any
/// asynchronous continuations spawned within the zone that attempt database
/// operations after callback completion are rejected.
class TransactionAdmissionToken {
  bool _isActive = true;
  bool get isActive => _isActive;

  void invalidate() {
    _isActive = false;
  }
}

/// Zone key used to identify executions occurring inside an active admitted transaction.
const Symbol kGatedTransactionToken = #spendx_gated_transaction_token;
const Symbol kGatedTransactionInstance = #spendx_gated_transaction_instance;

/// Central Dart in-isolate database admission gate for SpendX.
///
/// Guarantees:
/// 1. Admission control for every database query and mutation.
/// 2. Seamless integration with native process-shared OS lock leases via [PlatformProcessLockService].
/// 3. In-isolate tracking of active Dart database operations.
/// 4. Re-entrant transaction zones: nested repository calls inside transactions share admission
///    without deadlocking or acquiring conflicting tickets.
/// 5. Atomic admission closure and drain for restore operations.
class DatabaseAccessGate {
  static DatabaseAccessGate _instance = DatabaseAccessGate();
  static DatabaseAccessGate get instance => _instance;
  static set instanceForTesting(DatabaseAccessGate gate) {
    _instance = gate;
  }

  final PlatformProcessLockService _processLockService;
  TrackedDatabaseTaskQueue? _taskQueue;

  GateState _state = GateState.open;
  int _activeOperations = 0;
  Completer<void>? _drainCompleter;
  String? _nativeLeaseToken;
  String _engineId = 'main_engine';
  Future<String>? _leaseAcquisitionFuture;
  Future<void>? _activeDrainFuture;

  DatabaseAccessGate({
    PlatformProcessLockService? processLockService,
    TrackedDatabaseTaskQueue? taskQueue,
  }) : _processLockService = processLockService ?? PlatformProcessLockService(),
       _taskQueue = taskQueue;

  TrackedDatabaseTaskQueue get taskQueue =>
      _taskQueue ??= TrackedDatabaseTaskQueue(gate: this);

  void attachTaskQueue(TrackedDatabaseTaskQueue queue) {
    _taskQueue = queue;
  }

  GateState get state => _state;
  bool get isOpen => _state == GateState.open;
  bool get isDraining => _state == GateState.draining;
  bool get isClosed => _state == GateState.closed;
  int get activeOperations => _activeOperations;
  String? get nativeLeaseToken => _nativeLeaseToken;

  void configureEngineId(String engineId) {
    _engineId = engineId;
  }

  /// Ensures that the native process-shared lease is acquired with the host Android manager.
  ///
  /// Concurrent calls coalesce on the same in-flight acquisition future to prevent
  /// duplicate or conflicting native lease allocations.
  Future<String> ensureNativeLeaseAcquired() async {
    if (_nativeLeaseToken != null) {
      return _nativeLeaseToken!;
    }
    if (_leaseAcquisitionFuture != null) {
      return await _leaseAcquisitionFuture!;
    }

    Future<String> acquire() async {
      final token = await _processLockService.acquireForegroundLease(
        engineId: _engineId,
      );
      _nativeLeaseToken = token;
      return token;
    }

    _leaseAcquisitionFuture = acquire();
    try {
      return await _leaseAcquisitionFuture!;
    } finally {
      _leaseAcquisitionFuture = null;
    }
  }

  /// Admits a database operation.
  ///
  /// - If the caller is executing inside a [GatedTransaction] zone:
  ///   Verifies that the transaction zone is still active. If expired/escaped,
  ///   immediately throws [DatabaseTransactionClosedException].
  ///   If active, admission is inherited without incrementing operations.
  /// - If standalone:
  ///   1. Verifies the gate is [GateState.open].
  ///   2. Ensures the native process-shared lease is held (acquiring on first admission).
  ///      If acquisition fails, operation count is never incremented.
  ///   3. Re-verifies [GateState.open] after any asynchronous lease acquisition.
  ///   4. Increments active operations, executes [action], and decrements in finally.
  /// - Signals drain completion if the gate is draining and active operations hit 0.
  Future<T> admit<T>(Future<T> Function() action) async {
    // 1. Inherit admission if inside an active transaction zone; reject if zone expired
    final token = Zone.current[kGatedTransactionToken];
    if (token is TransactionAdmissionToken) {
      if (!token.isActive) {
        throw const DatabaseTransactionClosedException(
          'Cannot execute database operations within an expired or escaped transaction zone',
        );
      }
      return await action();
    }

    final txnInstance = Zone.current[kGatedTransactionInstance];
    if (txnInstance is GatedTransaction) {
      if (txnInstance.isClosed) {
        throw const DatabaseTransactionClosedException(
          'Cannot execute database operations within an expired or escaped transaction zone',
        );
      }
      return await action();
    }

    // 2. Reject immediately if gate is closed or draining
    if (_state != GateState.open) {
      throw DatabaseGateClosedException(
        'Database admission closed: gate state is $_state',
      );
    }

    // 3. Ensure native aggregate shared lease is held by this engine.
    // Must be done before incrementing active operations so failure never leaks count.
    if (_nativeLeaseToken == null) {
      await ensureNativeLeaseAcquired();
      if (_state != GateState.open) {
        throw DatabaseGateClosedException(
          'Database admission closed during lease acquisition: gate state is $_state',
        );
      }
    }

    _activeOperations++;
    try {
      return await action();
    } finally {
      _activeOperations--;
      if (_state == GateState.draining && _activeOperations == 0) {
        if (_drainCompleter != null && !_drainCompleter!.isCompleted) {
          _drainCompleter!.complete();
        }
      }
    }
  }

  /// Closes admission to new database operations and drains all in-flight operations.
  ///
  /// Once operations reach 0, releases the native aggregate process-shared lease
  /// back to the JVM host manager and transitions state to [GateState.closed].
  ///
  /// Concurrent calls coalesce onto the same in-flight drain future.
  /// Failed native release prevents the gate from being marked closed.
  Future<void> closeAdmissionAndDrain({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_state == GateState.closed) return;
    if (_activeDrainFuture != null) {
      return await _activeDrainFuture!;
    }

    Future<void> drain() async {
      _state = GateState.draining;

      // 1. Drain active background database tasks first
      if (_taskQueue != null && _taskQueue!.activeTaskCount > 0) {
        await _taskQueue!.drain(timeout: timeout);
      }

      // 2. Drain in-flight SQLite operations
      if (_activeOperations > 0) {
        final drainComp = Completer<void>();
        _drainCompleter = drainComp;

        if (_activeOperations == 0) {
          if (!drainComp.isCompleted) drainComp.complete();
        } else {
          try {
            await drainComp.future.timeout(timeout);
          } on TimeoutException {
            throw TimeoutException(
              'Timed out waiting for $_activeOperations active Dart database operations to drain',
            );
          } finally {
            _drainCompleter = null;
          }
        }
      }

      // Release native aggregate foreground lease back to JVM manager
      if (_nativeLeaseToken != null) {
        final tokenToRelease = _nativeLeaseToken!;
        final released = await _processLockService.releaseForegroundLease(
          engineId: _engineId,
          leaseToken: tokenToRelease,
        );
        if (!released) {
          throw StateError(
            'Failed to release native foreground lease ($tokenToRelease). Gate cannot be safely closed.',
          );
        }
        _nativeLeaseToken = null;
      }

      _state = GateState.closed;
    }

    _activeDrainFuture = drain();
    try {
      await _activeDrainFuture!;
    } finally {
      _activeDrainFuture = null;
    }
  }

  /// Reopens admission after restore completes or rolls back.
  ///
  /// Re-acquires the native process-shared lease and transitions state to [GateState.open].
  Future<void> reopenAdmission() async {
    if (_state == GateState.draining || _activeDrainFuture != null) {
      throw StateError('Cannot reopen admission while drain is in progress');
    }
    await ensureNativeLeaseAcquired();
    _state = GateState.open;
    _drainCompleter = null;
  }

  /// Wraps a raw [Database] into a protected [GatedDatabase].
  GatedDatabase wrapDatabase(Database db) {
    if (db is GatedDatabase) {
      return db;
    }
    return GatedDatabase(db, this);
  }

  /// Wraps any [DatabaseExecutor] into a gated executor.
  DatabaseExecutor wrapExecutor(DatabaseExecutor executor) {
    if (executor is GatedDatabase || executor is GatedTransaction) {
      return executor;
    }
    if (executor is Database) {
      return wrapDatabase(executor);
    }
    if (executor is Transaction) {
      return GatedTransaction(executor, this);
    }
    return executor;
  }

  /// Reset internal state for unit testing.
  void resetForTesting() {
    _state = GateState.open;
    _activeOperations = 0;
    _drainCompleter = null;
    _nativeLeaseToken = null;
    _leaseAcquisitionFuture = null;
    _activeDrainFuture = null;
    _taskQueue?.resetForTesting();
  }
}
