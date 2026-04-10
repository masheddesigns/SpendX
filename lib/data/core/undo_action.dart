import 'dart:async';

class UndoAction<T> {
  final String label;
  final T payload;
  final Future<void> Function(T) undo;

  UndoAction({
    required this.label,
    required this.payload,
    required this.undo,
  });
}
