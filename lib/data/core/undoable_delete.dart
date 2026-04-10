import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/haptic_service.dart';
import 'undo_action.dart';
import 'undo_manager.dart';

Future<void> performUndoableDelete<T>({
  required Ref ref,
  required String label,
  required T payload,
  required Future<void> Function(T) undo,
  required Future<void> Function() repositoryDelete,
  required void Function() rollback,
}) async {
  final previousAction = ref.read(undoProvider);
  final action = UndoAction<T>(label: label, payload: payload, undo: undo);

  HapticService.instance.medium();
  ref.read(undoProvider.notifier).setAction(action);

  try {
    await repositoryDelete();
  } catch (_) {
    rollback();
    final undoManager = ref.read(undoProvider.notifier);
    if (identical(ref.read(undoProvider), action)) {
      if (previousAction != null) {
        undoManager.setAction(previousAction);
      } else {
        undoManager.clear();
      }
    }
    rethrow;
  }
}
