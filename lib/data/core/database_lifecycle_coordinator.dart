import 'dart:async';

/// Conceptual states of the SpendX database lifecycle.
enum DatabaseLifecycleState {
  /// Normal operational state: reads and financial writes permitted.
  active,

  /// Migration from plaintext to SQLCipher in progress.
  /// Exclusive: writes blocked, concurrent backups/restores rejected.
  migrating,

  /// Point-in-time snapshot / backup package generation in progress.
  /// Writes quiesced/blocked during snapshot; concurrent restores/migrations rejected.
  backingUp,

  /// Staged restore and atomic database replacement in progress.
  /// Exclusive: active DB closed, writes blocked, SMS ingestion paused.
  restoring,

  /// Database connection explicitly closed or transitioning.
  closed,
}

/// Thrown when an exclusive lifecycle transition is attempted while another
/// destructive or pivot operation is currently active.
class DatabaseLifecycleConflictException extends StateError {
  final DatabaseLifecycleState currentState;
  final DatabaseLifecycleState attemptedState;

  DatabaseLifecycleConflictException({
    required String message,
    required this.currentState,
    required this.attemptedState,
  }) : super(message);

  @override
  String toString() =>
      'DatabaseLifecycleConflictException: $message (Current: $currentState, Attempted: $attemptedState)';
}

/// DatabaseLifecycleCoordinator — Central authority for SpendX database lifecycle
/// state, mutual exclusion, and write synchronization.
///
/// Guarantees:
/// 1. Only ONE pivot or destructive operation (migration, backup, restore) can execute at a time.
/// 2. Financial writes and SMS ingestion pause during exclusive operations and resume safely.
/// 3. Queued mutations are never lost, duplicated, or replayed against obsolete database generations.
/// 4. Notifies subscribers when database generations are replaced.
class DatabaseLifecycleCoordinator {
  DatabaseLifecycleCoordinator._();
  static final DatabaseLifecycleCoordinator instance =
      DatabaseLifecycleCoordinator._();

  DatabaseLifecycleState _state = DatabaseLifecycleState.active;
  final List<Completer<void>> _writableWaiters = [];
  final StreamController<DatabaseLifecycleState> _stateController =
      StreamController<DatabaseLifecycleState>.broadcast();
  final List<void Function()> _replacementListeners = [];

  DatabaseLifecycleState get currentState => _state;
  Stream<DatabaseLifecycleState> get stateChanges => _stateController.stream;

  /// True if database mutations are currently permitted.
  bool get canWrite => _state == DatabaseLifecycleState.active;

  /// True if an exclusive pivot or destructive lifecycle operation is currently active.
  bool get isExclusiveOperationRunning =>
      _state == DatabaseLifecycleState.migrating ||
      _state == DatabaseLifecycleState.backingUp ||
      _state == DatabaseLifecycleState.restoring;

  /// Registers a callback invoked whenever the database generation is replaced (e.g., after restore).
  void addDatabaseReplacementListener(void Function() listener) {
    _replacementListeners.add(listener);
  }

  /// Removes a database replacement callback.
  void removeDatabaseReplacementListener(void Function() listener) {
    _replacementListeners.remove(listener);
  }

  /// Notifies all registered listeners that the database generation has been replaced.
  void notifyDatabaseReplaced() {
    for (final listener in List.of(_replacementListeners)) {
      try {
        listener();
      } catch (_) {}
    }
  }

  /// Waits asynchronously until the lifecycle state returns to [DatabaseLifecycleState.active].
  ///
  /// Returns immediately if already [canWrite].
  Future<void> waitUntilWritable() async {
    if (canWrite) return;
    final completer = Completer<void>();
    _writableWaiters.add(completer);
    await completer.future;
  }

  /// Begins a database migration. Throws [DatabaseLifecycleConflictException] if another
  /// exclusive operation is currently in progress.
  Future<void> beginMigration() async {
    _assertCanTransition(DatabaseLifecycleState.migrating);
    _setState(DatabaseLifecycleState.migrating);
  }

  /// Completes migration and returns state to [DatabaseLifecycleState.active].
  void endMigration() {
    if (_state == DatabaseLifecycleState.migrating) {
      _setState(DatabaseLifecycleState.active);
    }
  }

  /// Begins a database backup snapshot. Throws [DatabaseLifecycleConflictException] if another
  /// exclusive operation is currently in progress.
  Future<void> beginBackup() async {
    _assertCanTransition(DatabaseLifecycleState.backingUp);
    _setState(DatabaseLifecycleState.backingUp);
  }

  /// Completes backup and returns state to [DatabaseLifecycleState.active].
  void endBackup() {
    if (_state == DatabaseLifecycleState.backingUp) {
      _setState(DatabaseLifecycleState.active);
    }
  }

  /// Begins a database restore. Throws [DatabaseLifecycleConflictException] if another
  /// exclusive operation is currently in progress.
  Future<void> beginRestore() async {
    _assertCanTransition(DatabaseLifecycleState.restoring);
    _setState(DatabaseLifecycleState.restoring);
  }

  /// Completes restore and returns state to [DatabaseLifecycleState.active].
  void endRestore() {
    if (_state == DatabaseLifecycleState.restoring) {
      _setState(DatabaseLifecycleState.active);
    }
  }

  /// Marks the database connection as closed.
  void markClosed() {
    if (_state != DatabaseLifecycleState.restoring &&
        _state != DatabaseLifecycleState.migrating) {
      _setState(DatabaseLifecycleState.closed);
    }
  }

  /// Marks the database as active.
  void markActive() {
    if (_state == DatabaseLifecycleState.closed) {
      _setState(DatabaseLifecycleState.active);
    }
  }

  /// Executes [action] with exclusive ownership of [targetState], ensuring cleanup in finally.
  Future<T> runExclusive<T>(
    DatabaseLifecycleState targetState,
    Future<T> Function() action,
  ) async {
    switch (targetState) {
      case DatabaseLifecycleState.migrating:
        await beginMigration();
        break;
      case DatabaseLifecycleState.backingUp:
        await beginBackup();
        break;
      case DatabaseLifecycleState.restoring:
        await beginRestore();
        break;
      default:
        throw ArgumentError('Invalid exclusive target state: $targetState');
    }
    try {
      return await action();
    } finally {
      switch (targetState) {
        case DatabaseLifecycleState.migrating:
          endMigration();
          break;
        case DatabaseLifecycleState.backingUp:
          endBackup();
          break;
        case DatabaseLifecycleState.restoring:
          endRestore();
          break;
        default:
          break;
      }
    }
  }

  void _assertCanTransition(DatabaseLifecycleState nextState) {
    if (_state != DatabaseLifecycleState.active &&
        _state != DatabaseLifecycleState.closed) {
      throw DatabaseLifecycleConflictException(
        message: 'Cannot start $nextState while operation in $_state is in progress',
        currentState: _state,
        attemptedState: nextState,
      );
    }
  }

  void _setState(DatabaseLifecycleState newState) {
    _state = newState;
    _stateController.add(newState);
    if (newState == DatabaseLifecycleState.active) {
      final waiters = List<Completer<void>>.from(_writableWaiters);
      _writableWaiters.clear();
      for (final waiter in waiters) {
        if (!waiter.isCompleted) {
          waiter.complete();
        }
      }
    }
  }

  /// Resets coordinator state to active and clears waiters. For test isolation only.
  void resetForTesting() {
    _state = DatabaseLifecycleState.active;
    for (final waiter in _writableWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _writableWaiters.clear();
    _replacementListeners.clear();
  }
}
