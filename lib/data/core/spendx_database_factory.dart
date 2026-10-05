import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as ffi;

import '../../core/logging/app_logger.dart';

/// Exception thrown when opening or verifying a SQLCipher database fails.
class SqlCipherException implements Exception {
  final String message;
  final dynamic cause;
  const SqlCipherException(this.message, [this.cause]);

  @override
  String toString() => 'SqlCipherException: $message${cause != null ? " (Cause: $cause)" : ""}';
}

class InvalidDatabaseKeyException extends SqlCipherException {
  const InvalidDatabaseKeyException([super.message = 'Invalid or incorrect SQLCipher encryption key.', super.cause]);
}

/// SpendXDatabaseFactory — Centralized, unified database engine abstraction for SpendX.
///
/// Wraps SQLite / SQLCipher initialization across all supported platforms:
/// - Android / iOS: Native SQLCipher pager via bundled library
/// - macOS / Linux / Tests: FFI SQLCipher pager via `package:sqlite3` and `sqflite_common_ffi`
///
/// Phase 1 Scope:
/// - Centralizes engine initialization and FFI hooks
/// - Exposes executable runtime detection (`PRAGMA cipher_version`)
/// - Supports isolated encrypted test databases without altering production spendx.db
class SpendXDatabaseFactory {
  SpendXDatabaseFactory._();
  static final SpendXDatabaseFactory instance = SpendXDatabaseFactory._();

  bool _initialized = false;
  String? _detectedCipherVersion;

  /// Returns true if the factory has been initialized.
  bool get isInitialized => _initialized;

  /// Returns the detected SQLCipher version string (e.g. '4.18.0 community'),
  /// or null if SQLCipher is not active.
  String? get detectedCipherVersion => _detectedCipherVersion;

  /// Initializes the underlying SQLite / SQLCipher database engine.
  ///
  /// Idempotent: subsequent calls return immediately without duplicate overhead.
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // 1. Initialize FFI for desktop and headless test environments
      if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }

      // 2. Runtime verification: verify sqlite3 is backed by SQLCipher
      _detectedCipherVersion = _detectSqlCipherVersion();
      if (_detectedCipherVersion != null) {
        AppLogger.i('[DB_FACTORY] SQLCipher engine verified: $_detectedCipherVersion');
      } else {
        AppLogger.w('[DB_FACTORY] Standard SQLite detected (SQLCipher not active)');
      }

      _initialized = true;
    } catch (e) {
      AppLogger.e('[DB_FACTORY] Engine initialization failed: $e');
      rethrow;
    }
  }

  /// Probes the SQLite engine via an ephemeral in-memory database to detect SQLCipher.
  String? _detectSqlCipherVersion() {
    try {
      final db = ffi.sqlite3.openInMemory();
      try {
        final rows = db.select('PRAGMA cipher_version;');
        if (rows.isNotEmpty) {
          final firstRow = rows.first;
          if (firstRow.isNotEmpty) {
            return firstRow.values.first?.toString();
          }
        }
      } finally {
        db.close();
      }
    } catch (_) {}
    return null;
  }

  /// Returns true if the running SQLite engine genuinely supports SQLCipher.
  bool isSqlCipherAvailable() {
    return _detectSqlCipherVersion() != null;
  }

  /// Opens an encrypted SQLCipher database at [path] using [password].
  ///
  /// Applies `PRAGMA key = '...'` and immediately asserts accessibility.
  /// Throws [InvalidDatabaseKeyException] if [password] is rejected by the cipher pager.
  Future<Database> openEncryptedDatabase(
    String path, {
    required String password,
    int? version,
    OnDatabaseConfigureFn? onConfigure,
    OnDatabaseCreateFn? onCreate,
    OnDatabaseVersionChangeFn? onUpgrade,
    OnDatabaseVersionChangeFn? onDowngrade,
    OnDatabaseOpenFn? onOpen,
    bool readOnly = false,
    bool singleInstance = true,
  }) async {
    await initialize();

    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        readOnly: readOnly,
        singleInstance: singleInstance,
        onConfigure: (db) async {
          // 1. Set SQLCipher key
          await db.execute("PRAGMA key = '${password.replaceAll("'", "''")}';");
          await db.execute('PRAGMA cipher_page_size = 4096;');

          // 2. Validate key immediately by accessing sqlite_master
          try {
            await db.rawQuery('SELECT count(*) FROM sqlite_master;');
          } catch (e) {
            throw InvalidDatabaseKeyException(
              'Failed to authenticate database with supplied key: SQLITE_NOTADB or corrupted header.',
              e,
            );
          }

          // 3. Apply standard pragma configuration
          await db.execute('PRAGMA foreign_keys = ON;');
          await db.rawQuery('PRAGMA busy_timeout = 5000;');

          if (onConfigure != null) {
            await onConfigure(db);
          }
        },
        onCreate: onCreate,
        onUpgrade: onUpgrade,
        onDowngrade: onDowngrade,
        onOpen: onOpen,
      ),
    );
  }

  /// Opens an unencrypted standard SQLite database at [path].
  /// Preserves full compatibility with existing user databases during Phase 1.
  Future<Database> openPlaintextDatabase(
    String path, {
    int? version,
    OnDatabaseConfigureFn? onConfigure,
    OnDatabaseCreateFn? onCreate,
    OnDatabaseVersionChangeFn? onUpgrade,
    OnDatabaseVersionChangeFn? onDowngrade,
    OnDatabaseOpenFn? onOpen,
    bool readOnly = false,
    bool singleInstance = true,
  }) async {
    await initialize();

    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        readOnly: readOnly,
        singleInstance: singleInstance,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
          await db.rawQuery('PRAGMA busy_timeout = 5000;');
          if (onConfigure != null) {
            await onConfigure(db);
          }
        },
        onCreate: onCreate,
        onUpgrade: onUpgrade,
        onDowngrade: onDowngrade,
        onOpen: onOpen,
      ),
    );
  }
}
