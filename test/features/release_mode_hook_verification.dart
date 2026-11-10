import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Milestone 4.5C — Release Mode Hook & Path Safety Verification', () {
    test('Release environment: All test hooks are permanently locked out and spendx.db is enforced', () async {
      final isRelease = const bool.fromEnvironment('dart.vm.product');
      expect(isRelease, isTrue, reason: 'Test must run with --dart-define=dart.vm.product=true');

      // Check 1: AppDatabase.setTestDatabasePath must throw UnsupportedError in release
      expect(
        () => AppDatabase.setTestDatabasePath('spendx_m45c_qualification.db'),
        throwsA(isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('setTestDatabasePath is strictly prohibited in release builds'),
        )),
      );

      // Check 2: AppDatabase.getDatabasePath() must unconditionally resolve to spendx.db in release
      final dbPath = await AppDatabase.instance.getDatabasePath();
      expect(dbPath.endsWith('spendx.db'), isTrue, reason: 'Database path must resolve strictly to spendx.db');

      // Check 3: BackupService.crashBarrierForTesting cannot be set in release
      expect(
        () => BackupService.crashBarrierForTesting = (phase, dir, journal) async {},
        throwsA(isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('crashBarrierForTesting cannot be set in release builds'),
        )),
      );

      // Check 4: BackupService.crashBarrierForTesting getter returns null in release
      expect(BackupService.crashBarrierForTesting, isNull);

      // Check 5: BackupService.enforceDisposableIsolation cannot be set in release
      expect(
        () => BackupService.enforceDisposableIsolation = true,
        throwsA(isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('enforceDisposableIsolation cannot be set in release builds'),
        )),
      );

      // Check 6: BackupService.enforceDisposableIsolation getter returns false in release
      expect(BackupService.enforceDisposableIsolation, isFalse);

      // Check 7: resetTestingFlags in release is a harmless no-op that cannot activate test flags
      BackupService.resetTestingFlags();
      expect(BackupService.crashBarrierForTesting, isNull);
      expect(BackupService.enforceDisposableIsolation, isFalse);
    });
  });
}
