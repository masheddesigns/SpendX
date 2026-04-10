import 'dart:async';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../screens/smart_import_screen.dart';

/// Listens for files shared from other apps (Notion, Sheets, Files, etc.)
/// and routes them to the Smart Import screen.
class ShareIntentService {
  ShareIntentService._();
  static final instance = ShareIntentService._();

  StreamSubscription? _streamSub;
  bool _initialized = false;
  bool _isNavigating = false;
  String? _lastHandledPath;
  DateTime? _lastHandledTime;

  /// Supported file extensions for smart import.
  static const _supportedExtensions = {
    'csv', 'tsv', 'txt', 'md', 'markdown',
    'html', 'htm', 'json', 'zip',
  };

  /// Initialize the share intent listener.
  /// Call this once after the navigator is ready.
  void init(GlobalKey<NavigatorState> navigatorKey) {
    if (_initialized) return;
    _initialized = true;

    // Handle file shared while app was closed (cold start)
    // Delay to ensure navigation stack is ready after splash
    Future.delayed(const Duration(seconds: 2), () {
      ReceiveSharingIntent.instance.getInitialMedia().then((files) {
        if (files.isNotEmpty) {
          _handleSharedFiles(files, navigatorKey);
        }
        // Reset AFTER handling to prevent re-trigger
        ReceiveSharingIntent.instance.reset();
      });
    });

    // Handle file shared while app is running (warm start)
    _streamSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (files) {
        if (files.isNotEmpty) {
          _handleSharedFiles(files, navigatorKey);
        }
      },
    );
  }

  void _handleSharedFiles(
      List<SharedMediaFile> files, GlobalKey<NavigatorState> navigatorKey) {
    if (files.isEmpty || _isNavigating) return;

    for (final shared in files) {
      final path = shared.path;
      final ext = path.split('.').last.toLowerCase();

      if (_supportedExtensions.contains(ext)) {
        // Deduplicate: skip if same file handled within last 5 seconds
        final now = DateTime.now();
        if (_lastHandledPath == path &&
            _lastHandledTime != null &&
            now.difference(_lastHandledTime!).inSeconds < 5) {
          debugPrint('[ShareIntent] Skipping duplicate: $path');
          return;
        }

        _lastHandledPath = path;
        _lastHandledTime = now;
        _isNavigating = true;

        debugPrint('[ShareIntent] Opening Smart Import for: $path');

        final navigator = navigatorKey.currentState;
        if (navigator != null) {
          navigator.push(
            MaterialPageRoute(
              builder: (_) => SmartImportScreen(sharedFilePath: path),
            ),
          ).then((_) {
            _isNavigating = false;
            // Reset after navigation completes to allow future shares
            ReceiveSharingIntent.instance.reset();
          });
        } else {
          _isNavigating = false;
        }
        return;
      }
    }
  }

  void dispose() {
    _streamSub?.cancel();
    _streamSub = null;
    _initialized = false;
    _isNavigating = false;
  }
}
