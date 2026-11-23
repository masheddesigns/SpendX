import 'package:flutter/material.dart';

/// Shared loading treatment for screens that need a centered progress state.
class LoadingStateWidget extends StatelessWidget {
  const LoadingStateWidget({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final label = message;
    return Center(
      child: Semantics(
        liveRegion: true,
        label: label ?? 'Loading',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (MediaQuery.disableAnimationsOf(context))
              Icon(
                Icons.hourglass_empty_rounded,
                color: Theme.of(context).colorScheme.primary,
                size: 28,
              )
            else
              const CircularProgressIndicator(),
            if (label != null) ...[
              const SizedBox(height: 12),
              Text(label, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}
