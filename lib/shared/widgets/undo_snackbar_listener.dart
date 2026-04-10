import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/core/undo_action.dart';
import '../../data/core/undo_manager.dart';
import '../../services/haptic_service.dart';

void listenForUndoSnackbars(
  WidgetRef ref,
  BuildContext context, {
  bool Function(Object? payload)? matches,
  FutureOr<void> Function(UndoAction action)? onUndone,
}) {
  ref.listen<UndoAction?>(undoProvider, (previous, next) {
    if (next == null) {
      return;
    }
    if (matches != null && !matches(next.payload)) {
      return;
    }

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(next.label),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            HapticService.instance.success();
            await ref.read(undoProvider.notifier).undo();
            await onUndone?.call(next);
          },
        ),
      ),
    );
  });
}

class UndoSnackbarListener extends ConsumerStatefulWidget {
  const UndoSnackbarListener({
    super.key,
    required this.child,
    this.matches,
    this.onUndone,
  });

  final Widget child;
  final bool Function(Object? payload)? matches;
  final FutureOr<void> Function(UndoAction action)? onUndone;

  @override
  ConsumerState<UndoSnackbarListener> createState() =>
      _UndoSnackbarListenerState();
}

class _UndoSnackbarListenerState extends ConsumerState<UndoSnackbarListener> {
  late final ProviderSubscription<UndoAction?> _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = ref.listenManual<UndoAction?>(undoProvider, (
      previous,
      next,
    ) {
      if (next == null) {
        return;
      }
      if (widget.matches != null && !widget.matches!(next.payload)) {
        return;
      }

      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(next.label),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'UNDO',
            onPressed: () async {
              HapticService.instance.success();
              await ref.read(undoProvider.notifier).undo();
              await widget.onUndone?.call(next);
            },
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
