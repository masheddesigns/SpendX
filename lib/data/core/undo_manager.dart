import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'undo_action.dart';

class UndoManager extends StateNotifier<UndoAction?> {
  UndoManager() : super(null);

  void setAction(UndoAction action) {
    state = action;
  }

  Future<void> undo() async {
    if (state != null) {
      final action = state!;
      state = null; // Clear immediately to prevent double-tap issues
      await action.undo(action.payload);
    }
  }

  void clear() => state = null;
}

final undoProvider = StateNotifierProvider<UndoManager, UndoAction?>((ref) {
  return UndoManager();
});
