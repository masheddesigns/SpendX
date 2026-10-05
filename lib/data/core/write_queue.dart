import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_lifecycle_coordinator.dart';

/// WriteQueue — a FIFO Task Queue for serializing database mutations.
///
/// Lifecycle Invariant:
/// When an exclusive database pivot occurs (restore, migration, backup snapshot),
/// queued financial mutations are automatically paused in memory, never lost or
/// duplicated, and resume execution only after the target database is verified and active.
class WriteQueue {
  WriteQueue._internal();
  static final WriteQueue instance = WriteQueue._internal();
  factory WriteQueue() => instance;

  final _queue = <Future<void> Function()>[];
  bool _isProcessing = false;
  int _inFlightCount = 0;
  Completer<void>? _quiesceCompleter;

  /// Returns the number of tasks currently queued and waiting to run.
  int get queueLength => _queue.length;

  /// Returns true if a task is actively being executed right now.
  bool get hasInFlightTasks => _inFlightCount > 0;

  /// Enqueue a task (e.g., a repository insert/update/delete).
  /// Tasks are executed sequentially on a first-come, first-served basis.
  /// Returns a Future that completes when the task finishes execution.
  Future<void> enqueue(Future<void> Function() task) {
    final completer = Completer<void>();
    _queue.add(() async {
      try {
        await task();
        if (!completer.isCompleted) completer.complete();
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    _process();
    return completer.future;
  }

  /// Waits until any currently executing in-flight task completes,
  /// without dequeuing subsequent pending tasks.
  Future<void> quiesce() async {
    if (_inFlightCount == 0) return;
    _quiesceCompleter = Completer<void>();
    await _quiesceCompleter!.future;
    _quiesceCompleter = null;
  }

  Future<void> _process() async {
    if (_isProcessing || _queue.isEmpty) return;

    _isProcessing = true;
    while (_queue.isNotEmpty) {
      // Pause processing if the database lifecycle is not active (e.g. restoring or migrating)
      await DatabaseLifecycleCoordinator.instance.waitUntilWritable();

      if (_queue.isEmpty) break;
      final currentTask = _queue.removeAt(0);
      _inFlightCount++;
      try {
        await currentTask();
      } catch (e) {
        // Notifier catch blocks will handle specific logic errors.
      } finally {
        _inFlightCount--;
        if (_inFlightCount == 0 &&
            _quiesceCompleter != null &&
            !_quiesceCompleter!.isCompleted) {
          _quiesceCompleter!.complete();
        }
      }
    }
    _isProcessing = false;
  }

  /// Clears queued tasks for test cleanup.
  void resetForTesting() {
    _queue.clear();
    _isProcessing = false;
    _inFlightCount = 0;
    if (_quiesceCompleter != null && !_quiesceCompleter!.isCompleted) {
      _quiesceCompleter!.complete();
    }
    _quiesceCompleter = null;
  }
}

/// Provider for the write queue.
final writeQueueProvider = Provider((ref) => WriteQueue.instance);
