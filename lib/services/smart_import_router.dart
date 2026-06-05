import 'dart:io';

import 'package:flutter/material.dart';

import '../models/review_item.dart';
import '../screens/import/import_preview_screen.dart';
import '../screens/import/import_processing_screen.dart';
import '../screens/smart_import_screen.dart';
import '../shared/widgets/app_page_route.dart';
import 'import_validation_log.dart';
import 'ocr_service.dart';
import 'transaction_text_parser.dart';

/// Result bundle returned by [SmartImportRouter.processImagePayload].
/// Lightweight record so callers (the processing screen) can pattern-
/// match on completion without depending on a class import.
typedef ImageProcessingResult = ({ParsedTransaction parsed, bool isFailed});

/// What kind of input was shared into the app.
enum ShareInputType { text, image, file }

/// A normalized share payload.
///
/// Some payment apps (GPay, PhonePe, Paytm) share BOTH an image and a
/// caption text describing the transaction. When both are present the
/// router merges them before parsing — the caption usually has the cleanest
/// amount and direction signals; the image holds reference IDs / merchant
/// fallbacks. Merging both maximises accuracy.
class SharePayload {
  final ShareInputType type;
  final String? text;
  final File? image;
  final File? file;
  final String? sourceApp;

  const SharePayload._({
    required this.type,
    this.text,
    this.image,
    this.file,
    this.sourceApp,
  });

  factory SharePayload.text(String text, {String? sourceApp}) =>
      SharePayload._(
        type: ShareInputType.text,
        text: text,
        sourceApp: sourceApp,
      );

  /// Image with optional companion [caption] text shared together.
  factory SharePayload.image(
    File image, {
    String? caption,
    String? sourceApp,
  }) =>
      SharePayload._(
        type: ShareInputType.image,
        image: image,
        text: caption,
        sourceApp: sourceApp,
      );

  factory SharePayload.file(File file, {String? sourceApp}) =>
      SharePayload._(
        type: ShareInputType.file,
        file: file,
        sourceApp: sourceApp,
      );
}

/// Routes share/import payloads to the right pipeline:
///   text  → TransactionTextParser → ImportPreviewScreen
///   image → OCR → TransactionTextParser → ImportPreviewScreen
///   file  → SmartImportScreen (existing CSV/JSON/ZIP flow)
///
/// User always confirms before insert. No silent saves.
class SmartImportRouter {
  SmartImportRouter._();
  static final instance = SmartImportRouter._();

  /// Handle a share payload. [navigatorKey] is needed so we can push
  /// from cold-start contexts where the current BuildContext isn't ready.
  Future<void> handle(
    SharePayload payload,
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    // Start latency timer — stopped when ImportPreviewScreen first renders.
    ImportValidationLog.instance.shareReceived();
    switch (payload.type) {
      case ShareInputType.text:
        await _handleText(payload.text!, navigatorKey, payload.sourceApp);
        return;
      case ShareInputType.image:
        // Fire-and-forget — _handleImage navigates immediately and
        // processes in the background, so there's nothing for the
        // caller to await. The processing future is owned by the
        // ImportProcessingScreen.
        _handleImage(
          payload.image!,
          navigatorKey,
          payload.sourceApp,
          caption: payload.text,
        );
        return;
      case ShareInputType.file:
        _handleFile(payload.file!, navigatorKey);
        return;
    }
  }

  Future<void> _handleText(
    String text,
    GlobalKey<NavigatorState> navigatorKey,
    String? sourceApp,
  ) async {
    debugPrint('[Router] text payload: ${text.length} chars');
    final parsed = await TransactionTextParser.parseWithLearning(text, source: 'share:text');
    final isFailed = TransactionTextParser.isFailedPayment(text);
    _logParsed(parsed, isFailed: isFailed, ocrChars: 0, captionChars: text.length);
    _pushPreview(navigatorKey, parsed, isFailed: isFailed);
  }

  /// Image share entry point — **navigates first, then processes**.
  ///
  /// The previous flow (run OCR → parse → push) made the user wait
  /// 300+ms staring at the source app while the main thread chewed
  /// through ML Kit's first-load + parse + provider rebuilds. Worse,
  /// the navigator could be in a transient null state during that
  /// window and the push would silently drop.
  ///
  /// New flow:
  ///   1. Push [ImportProcessingScreen] immediately — gives the user
  ///      instant feedback ("Reading your receipt...") and parks them
  ///      on a route the navigator definitely owns.
  ///   2. Kick off [processImagePayload] in a microtask. The future
  ///      starts running before the screen mounts, but the screen
  ///      will rendezvous with it via `then` regardless of order.
  ///   3. ProcessingScreen `pushReplacement`s to [ImportPreviewScreen]
  ///      on completion — pushReplacement runs on a navigator we
  ///      already own, so there's no race.
  void _handleImage(
    File image,
    GlobalKey<NavigatorState> navigatorKey,
    String? sourceApp, {
    String? caption,
  }) {
    // Start the work IMMEDIATELY (don't wait for the screen to mount).
    // The screen will await this future once it mounts; if processing
    // finishes first, the screen sees a completed future on initState
    // and navigates without delay.
    final processing =
        processImagePayload(image, caption: caption, sourceApp: sourceApp);
    _pushWhenReady(
      navigatorKey,
      routeName: 'ImportProcessing',
      build: () => ImportProcessingScreen(processing: processing),
    );
  }

  /// Public processing pipeline used by [ImportProcessingScreen]. Same
  /// logic as the previous inline `_handleImage` body, lifted into a
  /// pure async function so the UI can drive it instead of the router.
  ///
  /// Returns a `(ParsedTransaction, bool isFailed)` record. Throws on
  /// catastrophic OCR failure — the caller is responsible for
  /// surfacing the error to the user.
  Future<ImageProcessingResult> processImagePayload(
    File image, {
    String? caption,
    String? sourceApp,
  }) async {
    final ocrText = await OcrService.instance.extractText(image);
    final captionTrimmed = caption?.trim() ?? '';

    // Smart merge: which source leads the merged text matters because the
    // first amount/direction signal usually wins.
    //   - Only OCR present → OCR alone
    //   - Only caption present → caption alone
    //   - Caption has amount, OCR doesn't → caption first
    //   - OCR has amount, caption doesn't → OCR first
    //   - BOTH have amount → the longer text wins (more structured context
    //     usually means cleaner merchant/ref extraction)
    final parts = <String>[];
    if (captionTrimmed.isEmpty) {
      if (ocrText.isNotEmpty) parts.add(ocrText);
    } else if (ocrText.isEmpty) {
      parts.add(captionTrimmed);
    } else {
      final captionHasAmount = _hasAmountSignal(captionTrimmed);
      final ocrHasAmount = _hasAmountSignal(ocrText);
      if (captionHasAmount && ocrHasAmount) {
        // Tie-breaker: longer = more structured
        if (ocrText.length > captionTrimmed.length) {
          parts..add(ocrText)..add(captionTrimmed);
        } else {
          parts..add(captionTrimmed)..add(ocrText);
        }
      } else if (captionHasAmount) {
        parts..add(captionTrimmed)..add(ocrText);
      } else {
        parts..add(ocrText)..add(captionTrimmed);
      }
    }

    if (parts.isEmpty) {
      // Empty extraction — synthesize a zero-amount parse so the
      // preview can show its empty-extraction banner with the same
      // shape as a successful path.
      return (
        parsed: ParsedTransaction(
          amount: 0,
          isCredit: false,
          rawText: '',
          date: DateTime.now(),
          source: 'share:image',
          confidence: 0,
        ),
        isFailed: false,
      );
    }

    final merged = parts.join('\n');
    final parsed = await TransactionTextParser.parseWithLearning(merged, source: 'share:image');
    final isFailed = TransactionTextParser.isFailedPayment(merged);
    _logParsed(
      parsed,
      isFailed: isFailed,
      ocrChars: ocrText.length,
      captionChars: captionTrimmed.length,
    );
    return (parsed: parsed, isFailed: isFailed);
  }

  void _logParsed(
    ParsedTransaction p, {
    required bool isFailed,
    required int ocrChars,
    required int captionChars,
  }) {
    debugPrint(
      '[Parser] ${isFailed ? "FAILED " : ""}'
      'amount=${p.amount} '
      'merchant=${p.merchant ?? "<none>"} '
      'merchantSrc=${p.merchantSource ?? "<none>"} '
      'isCredit=${p.isCredit} '
      'hasDir=${p.hasDirectionSignal} '
      'method=${p.method ?? "<none>"} '
      'bank=${p.bankName ?? "<none>"} '
      'last4=${p.last4 ?? "<none>"} '
      'ref=${p.refId ?? "<none>"} '
      'conf=${(p.confidence * 100).toStringAsFixed(0)}% '
      '(ocr=${ocrChars}c caption=${captionChars}c)',
    );
    if (p.amount == 0) {
      debugPrint(
        '[Parser] ⚠️ AMOUNT NOT EXTRACTED. '
        'Raw text starts: "${p.rawText.length > 120 ? p.rawText.substring(0, 120) : p.rawText}"',
      );
    }
  }

  void _handleFile(File file, GlobalKey<NavigatorState> navigatorKey) {
    _pushWhenReady(
      navigatorKey,
      routeName: 'SmartImport',
      build: () => SmartImportScreen(sharedFilePath: file.path),
    );
  }

  /// Lightweight check: does this text contain a currency-style amount?
  /// Used to decide which source to lead with when merging caption + OCR.
  static final _amountHint = RegExp(
    r'(?:₹|Rs\.?|INR)\s?\d',
    caseSensitive: false,
  );

  bool _hasAmountSignal(String text) => _amountHint.hasMatch(text);

  void _pushPreview(
    GlobalKey<NavigatorState> navigatorKey,
    ParsedTransaction parsed, {
    required bool isFailed,
  }) {
    _pushWhenReady(
      navigatorKey,
      routeName: 'ImportPreview',
      build: () => ImportPreviewScreen(parsed: parsed, isFailed: isFailed),
    );
  }

  /// Robust navigation push for share-flow routes.
  ///
  /// Two failure modes the bare `navigator.push` couldn't handle:
  ///
  ///   1. **Navigator not yet ready** — share intent arrives during a
  ///      mid-route transition (warm) or while the splash is still
  ///      tearing down (cold post-handoff). `currentState` is null
  ///      for a moment, the bare push returns silently, and the user
  ///      sees nothing. We poll up to ~3s for the navigator to come
  ///      online before giving up — and log the give-up so the
  ///      condition stops being silent.
  ///
  ///   2. **Layout not yet settled** — the host scaffold may report
  ///      zero width if we push during a frame in which it's still
  ///      laying out (the "Width is zero" warnings in real logs).
  ///      Wrapping the push in [addPostFrameCallback] defers it to
  ///      after the current frame's layout completes.
  ///
  /// The route builder is invoked at push time (not at call time) so
  /// any captured state is fresh.
  Future<void> _pushWhenReady(
    GlobalKey<NavigatorState> navigatorKey, {
    required String routeName,
    required Widget Function() build,
  }) async {
    // Poll for navigator readiness — 30 × 100ms = 3s budget.
    for (var attempt = 0; attempt < 30; attempt++) {
      if (navigatorKey.currentState != null) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      debugPrint('[Router] $routeName: navigator never ready after 3s — dropped');
      return;
    }
    // Defer to the end of the current frame so layout has settled
    // before we mount the new route. Without this, AppPageRoute can
    // try to lay out against a zero-size host on cold start.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigator.push(AppPageRoute(builder: (_) => build()));
      debugPrint('[Router] pushed $routeName');
    });
  }
}
