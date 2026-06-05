import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'smart_import_router.dart';

/// Listens for shared content from other apps and dispatches via
/// [SmartImportRouter] (text → parser, image → OCR → parser, file →
/// existing CSV/JSON flow).
///
/// User always confirms before insert. No silent saves.
class ShareIntentService {
  ShareIntentService._();
  static final instance = ShareIntentService._();

  StreamSubscription? _streamSub;
  bool _initialized = false;
  bool _isHandling = false;
  // Cold-start guard: prevents the initial-intent payload from being
  // handled twice if the stream also delivers the same items quickly after.
  bool _handledInitial = false;
  String? _lastHandledKey;
  DateTime? _lastHandledTime;

  /// File extensions that the file (CSV/JSON/Notion) pipeline supports.
  static const _fileExtensions = {
    'csv', 'tsv', 'txt', 'md', 'markdown',
    'html', 'htm', 'json', 'zip',
  };

  /// Image extensions that should go through OCR.
  static const _imageExtensions = {
    'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'bmp',
  };

  void init(GlobalKey<NavigatorState> navigatorKey) {
    if (_initialized) return;
    _initialized = true;

    // Cold start: app was launched directly by a share intent. Without
    // explicit handling here, we'd silently drop the initial payload and
    // never trigger Smart Import for this session.
    //
    // Retry with backoff until the navigator is ready (post-splash).
    _drainColdStart(navigatorKey);

    // Warm start: app was already running.
    _streamSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (items) {
        if (items.isNotEmpty) {
          _handleShared(items, navigatorKey);
        }
      },
    );
  }

  /// Drain the cold-start payload, retrying briefly until navigator is ready.
  /// Guards against the stream re-delivering the same items immediately after.
  Future<void> _drainColdStart(
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    if (_handledInitial) return;
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    if (initial.isEmpty) {
      _handledInitial = true;
      ReceiveSharingIntent.instance.reset();
      return;
    }

    // Wait for navigator (max ~5s, polled every 200ms)
    for (var attempt = 0; attempt < 25; attempt++) {
      if (navigatorKey.currentState != null) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (navigatorKey.currentState == null) {
      debugPrint('[ShareIntent] Cold-start: navigator never ready, dropping');
      _handledInitial = true;
      ReceiveSharingIntent.instance.reset();
      return;
    }

    _handledInitial = true;
    _handleShared(initial, navigatorKey);
    ReceiveSharingIntent.instance.reset();
  }

  void _handleShared(
    List<SharedMediaFile> items,
    GlobalKey<NavigatorState> navigatorKey,
  ) {
    if (items.isEmpty || _isHandling) return;

    // Bundle detection: payment apps often share image + caption together.
    // Combine them into one payload so the router can merge before parsing.
    final payload = _coalesce(items);
    if (payload == null) return;

    final key = _payloadKey(payload, items);
    final now = DateTime.now();
    if (_lastHandledKey == key &&
        _lastHandledTime != null &&
        now.difference(_lastHandledTime!).inSeconds < 5) {
      debugPrint('[ShareIntent] Skipping duplicate: $key');
      return;
    }
    _lastHandledKey = key;
    _lastHandledTime = now;
    _isHandling = true;

    debugPrint('[ShareIntent] Dispatching ${payload.type.name}');
    SmartImportRouter.instance.handle(payload, navigatorKey).whenComplete(() {
      _isHandling = false;
      ReceiveSharingIntent.instance.reset();
    });
  }

  /// Merge image + accompanying text into a single payload.
  /// Falls back to the first valid item if no bundle pattern is detected.
  SharePayload? _coalesce(List<SharedMediaFile> items) {
    SharedMediaFile? image;
    SharedMediaFile? text;
    SharedMediaFile? file;

    for (final s in items) {
      switch (s.type) {
        case SharedMediaType.image:
          image ??= s;
          break;
        case SharedMediaType.text:
        case SharedMediaType.url:
          text ??= s;
          break;
        case SharedMediaType.file:
          // Could be image-by-extension or document
          final ext = s.path.split('.').last.toLowerCase();
          if (_imageExtensions.contains(ext) ||
              (s.mimeType?.startsWith('image/') ?? false)) {
            image ??= s;
          } else {
            file ??= s;
          }
          break;
        case SharedMediaType.video:
          break;
      }
    }

    // Image + caption together → merge into image payload with caption.
    if (image != null) {
      return SharePayload.image(
        File(image.path),
        caption: text?.path,
      );
    }
    if (text != null) {
      return SharePayload.text(text.path);
    }
    if (file != null) {
      final ext = file.path.split('.').last.toLowerCase();
      if (_fileExtensions.contains(ext)) {
        return SharePayload.file(File(file.path));
      }
    }
    return null;
  }

  String _payloadKey(SharePayload payload, List<SharedMediaFile> items) {
    final paths = items.map((s) => '${s.type.value}:${s.path}').join('|');
    return '${payload.type.name}|$paths';
  }

  void dispose() {
    _streamSub?.cancel();
    _streamSub = null;
    _initialized = false;
    _isHandling = false;
  }
}
