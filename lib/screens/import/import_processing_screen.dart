import 'package:flutter/material.dart';

import '../../services/smart_import_router.dart';
import '../../shared/widgets/app_page_route.dart';
import 'import_preview_screen.dart';

/// Lightweight intermediate route for image-share processing.
///
/// Why this exists: OCR + parse takes 300ms+ on a cold ML Kit start.
/// If we wait for that to finish before navigating, the user stares
/// at the source app the whole time and the navigator may transition
/// through a null state (silent push drop / "Width is zero" warnings
/// in the original log). Pushing this screen IMMEDIATELY on share
/// receipt parks the user on a route we own, then we replace it with
/// [ImportPreviewScreen] when the future resolves.
///
/// The future is constructed by the router and started before the
/// screen mounts — we just rendezvous with it here. If it finishes
/// first, the `then` fires during [initState] and we navigate without
/// any added delay.
class ImportProcessingScreen extends StatefulWidget {
  final Future<ImageProcessingResult> processing;

  const ImportProcessingScreen({
    super.key,
    required this.processing,
  });

  @override
  State<ImportProcessingScreen> createState() => _ImportProcessingScreenState();
}

class _ImportProcessingScreenState extends State<ImportProcessingScreen> {
  /// Tracks whether the route has been popped/replaced — once true,
  /// neither success nor failure should attempt navigation.
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    widget.processing.then(_onResult).catchError(_onError);
  }

  void _onResult(ImageProcessingResult result) {
    if (!mounted || _settled) return;
    _settled = true;
    Navigator.of(context).pushReplacement(
      AppPageRoute(
        builder: (_) => ImportPreviewScreen(
          parsed: result.parsed,
          isFailed: result.isFailed,
        ),
      ),
    );
  }

  void _onError(Object error, StackTrace stack) {
    debugPrint('[ImportProcessing] failed: $error');
    if (!mounted || _settled) return;
    _settled = true;
    // Pop the processing screen and surface the failure as a snackbar
    // on whatever route the user came from. Better UX than a dedicated
    // error screen for what's almost always an OCR misread.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    navigator.pop();
    messenger.showSnackBar(
      const SnackBar(content: Text("Couldn't read this receipt — try again")),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      // Transparent appbar so the spinner reads as ephemeral / in-flight
      // rather than a destination route. The user can still back out.
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: cs.onSurface,
      ),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Reading your receipt…',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'This usually takes a moment',
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
