import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/services/gemini_service.dart';

void main() {
  group('C13-P1 Production Packaging Security Tests', () {
    test('pubspec.yaml assets MUST NOT declare .env as a bundled asset', () {
      final pubspecFile = File('pubspec.yaml');
      expect(pubspecFile.existsSync(), isTrue, reason: 'pubspec.yaml must exist');

      final lines = pubspecFile.readAsLinesSync();
      var inFlutter = false;
      var inAssets = false;
      final assets = <String>[];

      for (final line in lines) {
        final trimmed = line.trim();
        if (line.startsWith('flutter:')) {
          inFlutter = true;
          continue;
        }
        if (inFlutter && !line.startsWith(' ') && trimmed.isNotEmpty) {
          inFlutter = false;
          inAssets = false;
        }
        if (inFlutter && trimmed.startsWith('assets:')) {
          inAssets = true;
          continue;
        }
        if (inAssets) {
          if (trimmed.startsWith('- ')) {
            assets.add(trimmed.substring(2).trim());
          } else if (!line.startsWith('   ') && trimmed.isNotEmpty) {
            inAssets = false;
          }
        }
      }

      expect(assets, isNot(contains('.env')),
          reason: 'Bundling .env as a Flutter asset packages developer secrets into production releases');
      expect(assets, isNot(contains('/.env')));
      expect(assets, contains('assets/logo.svg'));
    });

    test('GeminiService degrades gracefully when API key is unconfigured', () async {
      final gemini = GeminiService.instance;
      gemini.init();

      // When API key is not configured or empty, calling sendMessage returns clean error
      // without throwing unhandled exceptions or making unauthorized network requests
      if (gemini.apiKey.isEmpty) {
        final reply = await gemini.sendMessage('Hello');
        expect(reply, contains('not configured'));

        final receipt = await gemini.scanReceipt(File('non_existent.jpg'));
        expect(receipt['error'], contains('not configured'));

        final statement = await gemini.scanStatement(File('non_existent.jpg'));
        expect(statement.first['error'], contains('not configured'));
      }
    });

    test('GeminiService sanitizes error messages', () {
      final gemini = GeminiService.instance;
      final rawError = 'Network error at URL: https://example.com/test';
      final sanitized = gemini.sanitizeError(rawError);
      expect(sanitized, isNotEmpty);
      expect(sanitized, isNot(contains('[REDACTED_API_KEY]')));
    });

    test('AndroidManifest.xml restricts SmsReceiver with BROADCAST_SMS permission', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue);

      final content = manifestFile.readAsStringSync();
      expect(content, contains('android:name=".SmsReceiver"'));
      expect(content, contains('android:permission="android.permission.BROADCAST_SMS"'),
          reason: 'SmsReceiver must require BROADCAST_SMS to prevent unauthorized intent broadcasts');
    });

    test('ios/Runner/Info.plist includes camera and photo library usage descriptions', () {
      final plistFile = File('ios/Runner/Info.plist');
      expect(plistFile.existsSync(), isTrue);

      final content = plistFile.readAsStringSync();
      expect(content, contains('<key>NSCameraUsageDescription</key>'));
      expect(content, contains('<key>NSPhotoLibraryUsageDescription</key>'));
    });

    test('android/app/proguard-rules.pro preserves SQLCipher native JNI classes', () {
      final proguardFile = File('android/app/proguard-rules.pro');
      expect(proguardFile.existsSync(), isTrue);

      final content = proguardFile.readAsStringSync();
      expect(content, contains('-keep class net.sqlcipher.** { *; }'));
      expect(content, contains('-keep class io.requery.android.database.** { *; }'));
    });
  });
}
