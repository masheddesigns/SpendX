import 'dart:async';
import '../../core/logging/app_logger.dart';
import 'database_access_gate.dart';

/// Metadata for a tracked background database task.
class TrackedDatabaseTask {
  final String id;
  final String tag;
  final DateTime startedAt;
  bool _isCompleted = false;

  TrackedDatabaseTask({
    required this.id,
    required this.tag,
  }) : startedAt = DateTime.now();

  bool get isCompleted => _isCompleted;
}

/// Central registry and coordinator for background asynchronous database tasks.
///
/// Guarantees:
/// 1. Prior Registration: Tasks are registered before any asynchronous execution begins.
/// 2. Deterministic Quiescence: During restore drain, the queue drains all active background
///    tasks before the database connection is closed or OS locks are upgraded.
/// 3. Fail-Safe Rejection: New tasks are rejected immediately when the gate is draining or closed.
/// 4. Leak & Duplicate Protection: Completion handles idempotently remove tasks and prevent
///    counter corruption.
/// 5. Safe Error Containment: Task failures are logged or forwarded to custom handlers,
///    never becoming unhandled asynchronous errors.
class TrackedDatabaseTaskQueue {
  static final TrackedDatabaseTaskQueue instance = TrackedDatabaseTaskQueue();

  final DatabaseAccessGate _gate;
  final Map<String, TrackedDatabaseTask> _activeTasks = {};
  Completer<void>? _drainCompleter;
  int _nextSeq = 0;

  TrackedDatabaseTaskQueue({DatabaseAccessGate? gate})
      : _gate = gate ?? DatabaseAccessGate.instance;

  /// Number of currently executing background database tasks.
  int get activeTaskCount => _activeTasks.length;

  /// Unmodifiable view of currently active tasks.
  List<TrackedDatabaseTask> get activeTasks => _activeTasks.values.toList();

  /// Enqueues and executes a fire-and-forget background database task.
  ///
  /// - Verifies gate admission is open. If closed or draining, rejects the task immediately.
  /// - Tracks lifecycle until completion or exception.
  /// - Catches unhandled errors and dispatches to [onError] (or logs via [AppLogger]).
  void runTracked(
    String tag,
    Future<void> Function() action, {
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    if (!_gate.isOpen) {
      AppLogger.w(
        '[TrackedTaskQueue] Rejected background task "$tag": gate is ${_gate.state}',
      );
      return;
    }

    final taskId = '${tag}_${DateTime.now().microsecondsSinceEpoch}_${_nextSeq++}';
    final task = TrackedDatabaseTask(id: taskId, tag: tag);
    _activeTasks[taskId] = task;

    unawaited(
      action().then((_) {
        _removeTask(taskId);
      }).catchError((e, st) {
        _removeTask(taskId);
        if (onError != null) {
          onError(e, st);
        } else {
          AppLogger.e('[TrackedTaskQueue] Task "$tag" ($taskId) failed', e, st);
        }
      }),
    );
  }

  /// Runs an asynchronous background database task and returns its result.
  ///
  /// Throws [DatabaseGateClosedException] if the gate is closed or draining.
  Future<T> run<T>(
    String tag,
    Future<T> Function() action, {
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    if (!_gate.isOpen) {
      throw DatabaseGateClosedException(
        'Cannot start background task "$tag": gate state is ${_gate.state}',
      );
    }

    final taskId = '${tag}_${DateTime.now().microsecondsSinceEpoch}_${_nextSeq++}';
    final task = TrackedDatabaseTask(id: taskId, tag: tag);
    _activeTasks[taskId] = task;

    try {
      return await action();
    } catch (e, st) {
      if (onError != null) {
        onError(e, st);
      } else {
        AppLogger.e('[TrackedTaskQueue] Task "$tag" ($taskId) failed', e, st);
      }
      rethrow;
    } finally {
      _removeTask(taskId);
    }
  }

  /// Removes a task upon completion or failure.
  void _removeTask(String taskId) {
    final task = _activeTasks.remove(taskId);
    if (task != null && !task._isCompleted) {
      task._isCompleted = true;
      if (_activeTasks.isEmpty && _drainCompleter != null && !_drainCompleter!.isCompleted) {
        _drainCompleter!.complete();
      }
    }
  }

  /// Drains all active background database tasks with bounded timeout.
  Future<void> drain({Duration timeout = const Duration(seconds: 5)}) async {
    if (_activeTasks.isEmpty) return;

    final completer = Completer<void>();
    _drainCompleter = completer;

    if (_activeTasks.isEmpty) {
      if (!completer.isCompleted) completer.complete();
      return;
    }

    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      final lingeringTags = _activeTasks.values.map((t) => t.tag).join(', ');
      throw TimeoutException(
        'Timed out waiting for ${_activeTasks.length} background tasks to drain: [$lingeringTags]',
      );
    } finally {
      _drainCompleter = null;
    }
  }

  /// Testing helper to reset internal queue state.
  void resetForTesting() {
    _activeTasks.clear();
    _drainCompleter = null;
    _nextSeq = 0;
  }
}
