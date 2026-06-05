import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Thin wrapper around Google ML Kit on-device text recognition.
///
/// On-device, offline. No images leave the phone.
class OcrService {
  OcrService._();
  static final instance = OcrService._();

  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  /// Extract text from an image file. Returns the full recognized text
  /// concatenated with newlines, or empty string on failure.
  Future<String> extractText(File imageFile) async {
    final sw = Stopwatch()..start();
    try {
      final inputImage = InputImage.fromFile(imageFile);
      final result = await _recognizer.processImage(inputImage);
      final text = result.text.trim();
      sw.stop();
      // Diagnostic — without this we have no idea why parsing fails on share
      debugPrint('[OcrService] OCR ${sw.elapsedMilliseconds}ms · '
          '${text.length} chars · ${result.blocks.length} blocks');
      if (text.isEmpty) {
        debugPrint('[OcrService] ⚠️ OCR returned EMPTY for ${imageFile.path}');
      } else {
        final preview = text.length > 200 ? text.substring(0, 200) : text;
        debugPrint('[OcrService] First 200: ${preview.replaceAll('\n', ' ⏎ ')}');
      }
      return text;
    } catch (e) {
      debugPrint('[OcrService] extractText failed: $e');
      return '';
    }
  }

  /// Call when shutting down (rarely needed).
  Future<void> close() async {
    try {
      await _recognizer.close();
    } catch (_) {}
  }
}
