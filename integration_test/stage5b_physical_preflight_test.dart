import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/services/sms_inbox_watermark.dart';
import 'package:spend_x/services/sms_recovery_paginator.dart';
import 'package:sqflite/sqflite.dart';

import 'helpers/stage5b_preflight_bootstrap.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Stage 5B physical-device isolated preflight and teardown', (tester) async {
    expect(kReleaseMode, isFalse,
        reason: 'Stage 5B physical validation must never run in release mode.');

    await Stage5BTestBootstrap.runPreflightAssertions();

    final packageInfo = await PackageInfo.fromPlatform();
    final database = await AppDatabase.instance.database;
    final databaseList = await database.rawQuery('PRAGMA database_list;');
    final schemaVersion =
        Sqflite.firstIntValue(await database.rawQuery('PRAGMA user_version;'));
    final economicEvents = Sqflite.firstIntValue(
          await database.rawQuery('SELECT COUNT(*) FROM economic_events;'),
        ) ??
        0;
    final postings = Sqflite.firstIntValue(
          await database.rawQuery('SELECT COUNT(*) FROM postings;'),
        ) ??
        0;

    expect(packageInfo.packageName, Stage5BTestBootstrap.testApplicationId);
    expect(AppDatabase.testDatabasePath, Stage5BTestBootstrap.testDatabaseFilename);
    expect(
      SpendXDatabaseKeyManager.instance.keyStorageName,
      Stage5BTestBootstrap.testKeyStorageName,
    );
    expect(
      SmsRecoveryCheckpointStore.activeKey,
      Stage5BTestBootstrap.testRecoveryCheckpointKey,
    );
    expect(
      SmsInboxWatermarkStore.activeKey,
      Stage5BTestBootstrap.testInboxWatermarkKey,
    );
    expect(schemaVersion, 25);
    expect(economicEvents, 0);
    expect(postings, 0);

    debugPrint(
      'STAGE5B_ON_DEVICE_PREFLIGHT_RESULT '
      'package=${packageInfo.packageName} '
      'key_slot=${SpendXDatabaseKeyManager.instance.keyStorageName} '
      'recovery_key=${SmsRecoveryCheckpointStore.activeKey} '
      'watermark_key=${SmsInboxWatermarkStore.activeKey} '
      'database_list=$databaseList '
      'schema_version=$schemaVersion '
      'economic_events=$economicEvents '
      'postings=$postings',
    );

    // Teardown
    await Stage5BTestBootstrap.tearDown();
    expect(Stage5BTestBootstrap.state, Stage5BBootstrapState.tornDown);
    debugPrint(
      'STAGE5B_ON_DEVICE_TEARDOWN_RESULT state=${Stage5BTestBootstrap.state}',
    );
  });
}
