import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Manages multi-select state for bulk transaction editing.
class BulkSelectionNotifier extends StateNotifier<Set<String>> {
  BulkSelectionNotifier() : super({});

  bool get isActive => state.isNotEmpty;
  int get count => state.length;

  void toggle(String id) {
    if (state.contains(id)) {
      state = {...state}..remove(id);
    } else {
      state = {...state, id};
    }
  }

  void selectAll(List<String> ids) {
    state = {...ids};
  }

  void clear() {
    state = {};
  }

  bool isSelected(String id) => state.contains(id);
}

final bulkSelectionProvider =
    StateNotifierProvider<BulkSelectionNotifier, Set<String>>(
  (ref) => BulkSelectionNotifier(),
);
