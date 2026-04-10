import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// WriteQueue — a simple FIFO Task Queue for serializing database mutations.
/// Prevents SQLite contention when multiple optimistic updates are triggered.
class WriteQueue {
  final _queue = <Future<void> Function()>[];
  bool _isProcessing = false;

  /// Enqueue a task (e.g., a repository insert/update/delete).
  /// Tasks are executed sequentially on a first-come, first-served basis.
  Future<void> enqueue(Future<void> Function() task) async {
    _queue.add(task);
    _process();
  }

  Future<void> _process() async {
    if (_isProcessing || _queue.isEmpty) return;

    _isProcessing = true;
    while (_queue.isNotEmpty) {
      final currentTask = _queue.removeAt(0);
      try {
        await currentTask();
      } catch (e) {
        // Log or handle error if needed, but continue the queue
        // Notifier catch blocks will handle specific logic errors.
      }
    }
    _isProcessing = false;
  }
}

/// Provider for the write queue.
final writeQueueProvider = Provider((ref) => WriteQueue());
