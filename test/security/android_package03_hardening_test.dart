import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Package 03 regression guards.
///
/// These tests read the Android configuration and Kotlin sources directly so a
/// future manifest edit cannot silently re-enable OS backups, re-export the
/// Dynamic Island receiver, or re-broaden notification collection.
void main() {
  final manifestFile = File('android/app/src/main/AndroidManifest.xml');
  final extractionRulesFile = File(
    'android/app/src/main/res/xml/data_extraction_rules.xml',
  );
  final listenerFile = File(
    'android/app/src/main/kotlin/com/mashingdesigns/spend_x/'
    'BankNotificationListener.kt',
  );
  final overlayFile = File(
    'android/app/src/main/kotlin/com/mashingdesigns/spend_x/'
    'DynamicIslandOverlayService.kt',
  );

  late String manifest;
  late String extractionRules;
  late String listener;
  late String overlay;

  setUpAll(() {
    expect(
      manifestFile.existsSync(),
      isTrue,
      reason: 'AndroidManifest.xml must exist',
    );
    expect(
      extractionRulesFile.existsSync(),
      isTrue,
      reason: 'data_extraction_rules.xml must exist',
    );
    expect(
      listenerFile.existsSync(),
      isTrue,
      reason: 'BankNotificationListener.kt must exist',
    );
    expect(
      overlayFile.existsSync(),
      isTrue,
      reason: 'DynamicIslandOverlayService.kt must exist',
    );

    manifest = manifestFile.readAsStringSync();
    extractionRules = extractionRulesFile.readAsStringSync();
    listener = listenerFile.readAsStringSync();
    overlay = overlayFile.readAsStringSync();
  });

  group('Package 03 - Android backup policy', () {
    test('application disables Auto Backup and device transfer', () {
      final application = _openingTag(manifest, 'application');

      expect(
        application,
        contains('android:allowBackup="false"'),
        reason: 'OS backup must stay disabled',
      );
      expect(
        application,
        contains('android:fullBackupContent="false"'),
        reason: 'Legacy Android backup must stay disabled',
      );
      expect(
        application,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
        reason: 'Android 12+ extraction rules must stay wired up',
      );
    });

    test('cloud backup excludes every app data domain', () {
      final cloudBackup = _elementBlock(extractionRules, 'cloud-backup');

      for (final domain in const [
        'root',
        'file',
        'database',
        'sharedpref',
        'external',
      ]) {
        expect(
          _excludesDomain(cloudBackup, domain),
          isTrue,
          reason: 'cloud backup must exclude domain "$domain"',
        );
      }
    });

    test('device transfer excludes every app data domain', () {
      final deviceTransfer = _elementBlock(extractionRules, 'device-transfer');

      for (final domain in const [
        'root',
        'file',
        'database',
        'sharedpref',
        'external',
      ]) {
        expect(
          _excludesDomain(deviceTransfer, domain),
          isTrue,
          reason: 'device transfer must exclude domain "$domain"',
        );
      }
    });

    test('extraction rules contain no include exceptions', () {
      expect(
        RegExp(r'<include\b').hasMatch(extractionRules),
        isFalse,
        reason: 'An include rule would re-admit data excluded above',
      );
    });
  });

  group('Package 03 - component exposure', () {
    test('DynamicIslandReceiver is not exported', () {
      final receiver = _openingTag(
        manifest,
        'receiver',
        attributeContains: 'android:name=".DynamicIslandReceiver"',
      );

      expect(
        receiver,
        contains('android:exported="false"'),
        reason: 'No cross-app sender is supported',
      );
    });

    test('SmsReceiver keeps its system-only broadcast permission', () {
      final receiver = _openingTag(
        manifest,
        'receiver',
        attributeContains: 'android:name=".SmsReceiver"',
      );

      expect(
        receiver,
        contains('android:permission="android.permission.BROADCAST_SMS"'),
      );
      expect(receiver, contains('android:exported="true"'));
    });

    test('notification listener keeps the system binding permission', () {
      final service = _openingTag(
        manifest,
        'service',
        attributeContains: 'android:name=".BankNotificationListener"',
      );

      expect(
        service,
        contains(
          'android:permission="android.permission.'
          'BIND_NOTIFICATION_LISTENER_SERVICE"',
        ),
      );
    });
  });

  group('Package 03 - notification privacy', () {
    test('listener gates on an explicit package allowlist', () {
      expect(
        listener,
        contains('if (!isPayment && !isWA && !isGM) continue'),
        reason: 'Only explicit allowlisted packages may be inspected',
      );
      expect(
        listener,
        isNot(contains('lowerPkg.contains(')),
        reason: 'Substring package heuristics would collect unrelated apps',
      );
    });

    test('email and general messaging apps are gated by user toggles', () {
      expect(
        listener,
        contains('gmEnabled && EMAIL_PACKAGES.contains(pkg)'),
        reason: 'Gmail monitoring requires explicit user opt-in',
      );
      expect(
        listener,
        contains('waEnabled && WHATSAPP_PACKAGES.contains(pkg)'),
        reason: 'WhatsApp monitoring requires explicit user opt-in',
      );
    });

    test('notification bodies are never written to logcat', () {
      expect(
        listener,
        isNot(contains('body=\$fullBody')),
        reason: 'Full notification text must not be logged',
      );
      expect(
        listener,
        isNot(contains('body=\${fullBody}')),
        reason: 'Full notification text must not be logged',
      );
      expect(
        listener,
        isNot(contains('Log.i("SpendX_Notif", "onNotificationPosted')),
        reason: 'Use the redacted evaluation log line only',
      );
    });

    test(
      'accepted notification logging contains package and amount state only',
      () {
        expect(
          listener,
          contains(
            'Financial notification accepted: pkg=\$pkg, '
            'amountPresent=\${amount.isNotBlank()}, isExpense=\$isExpense',
          ),
        );
      },
    );
  });

  group('Package 03 - overlay permission justification', () {
    test('SYSTEM_ALERT_WINDOW is retained for the WindowManager overlay', () {
      expect(
        manifest,
        contains('android.permission.SYSTEM_ALERT_WINDOW'),
        reason: 'Non-Vivo devices render through TYPE_APPLICATION_OVERLAY',
      );

      expect(
        overlay,
        contains('Settings.canDrawOverlays(context)'),
        reason: 'The overlay must verify the user-granted permission',
      );
      expect(
        overlay,
        contains('TYPE_APPLICATION_OVERLAY'),
        reason: 'The overlay window type requires SYSTEM_ALERT_WINDOW',
      );
    });

    test(
      'Vivo/iQOO uses the native notification path instead of the overlay',
      () {
        expect(
          overlay,
          contains('showVivoOriginIslandNotification'),
          reason: 'Vivo devices do not need the floating overlay',
        );
      },
    );
  });
}

String _openingTag(String xml, String tagName, {String? attributeContains}) {
  final pattern = RegExp('<$tagName\\b[^>]*>');
  for (final match in pattern.allMatches(xml)) {
    final tag = match.group(0)!;
    if (attributeContains == null || tag.contains(attributeContains)) {
      return tag;
    }
  }
  fail(
    'No <$tagName> tag found'
    '${attributeContains == null ? '' : ' containing $attributeContains'}',
  );
}

String _elementBlock(String xml, String tagName) {
  final start = RegExp('<$tagName\\b[^>]*>').firstMatch(xml);
  if (start == null) {
    fail('No <$tagName> element found');
  }
  final endToken = '</$tagName>';
  final end = xml.indexOf(endToken, start.end);
  if (end < 0) {
    fail('No closing $endToken found');
  }
  return xml.substring(start.start, end + endToken.length);
}

bool _excludesDomain(String block, String domain) {
  return RegExp(
    '<exclude\\b[^>]*domain="$domain"[^>]*path="\\."[^>]*/>',
  ).hasMatch(block);
}
