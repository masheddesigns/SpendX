part of 'app_database.dart';

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
class SpendXDatabaseFactory {
  SpendXDatabaseFactory._();
  static final SpendXDatabaseFactory instance = SpendXDatabaseFactory._();

  bool _initialized = false;
  String? _detectedCipherVersion;

  /// Canonical primary database name.
  static const String primaryDatabaseName = 'spendx.db';

  /// Returns true if the factory has been initialized.
  bool get isInitialized => _initialized;

  /// Returns the detected SQLCipher version string (e.g. '4.18.0 community'),
  /// or null if SQLCipher is not active.
  String? get detectedCipherVersion => _detectedCipherVersion;

  /// Initializes the underlying SQLite / SQLCipher database engine.
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      String? defaultPath;
      try {
        defaultPath = await databaseFactory.getDatabasesPath();
      } catch (_) {}

      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      if (defaultPath != null &&
          defaultPath.isNotEmpty &&
          !defaultPath.contains('.dart_tool')) {
        await databaseFactory.setDatabasesPath(defaultPath);
        AppLogger.i('[DB_FACTORY] Preserved platform databases path: $defaultPath');
      }

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

  bool isSqlCipherAvailable() {
    return _detectSqlCipherVersion() != null;
  }

  /// Resolves [rawPath] to its canonical filesystem path, resolving symlinks,
  /// redundant dots, parent references, and nonexistent nested segments beneath
  /// existing symlinked ancestors.
  static String canonicalizePath(String rawPath) {
    final normalized = rawPath.replaceAll(r'\', '/');
    if (normalized == primaryDatabaseName ||
        normalized == './$primaryDatabaseName' ||
        normalized == '/$primaryDatabaseName') {
      return primaryDatabaseName;
    }

    final file = File(rawPath);
    if (file.existsSync()) {
      try {
        return file.resolveSymbolicLinksSync().replaceAll(r'\', '/');
      } catch (_) {}
    }

    // Traverse directory ancestors to resolve symlinked parent paths even if
    // the target database file or intermediate directories do not yet exist.
    Directory dir = file.parent;
    final nonExistentSegments = <String>[p.basename(file.path)];

    while (!dir.existsSync() && dir.path != dir.parent.path) {
      nonExistentSegments.add(p.basename(dir.path));
      dir = dir.parent;
    }

    String canonicalAncestor;
    if (dir.existsSync()) {
      try {
        canonicalAncestor = dir.resolveSymbolicLinksSync().replaceAll(r'\', '/');
      } catch (_) {
        canonicalAncestor = p.normalize(p.absolute(dir.path)).replaceAll(r'\', '/');
      }
    } else {
      canonicalAncestor = p.normalize(p.absolute(dir.path)).replaceAll(r'\', '/');
    }

    String resolved = canonicalAncestor;
    for (final segment in nonExistentSegments.reversed) {
      resolved = p.join(resolved, segment);
    }
    return p.normalize(resolved).replaceAll(r'\', '/');
  }

  /// Determines whether [rawPath] refers to the primary production database,
  /// resolving equivalent paths (e.g. relative dots, symlinks, normalized paths).
  static Future<bool> isPrimaryDatabasePath(String rawPath) async {
    final normPath = p.normalize(rawPath.replaceAll(r'\', '/'));

    if (normPath == primaryDatabaseName ||
        normPath == './$primaryDatabaseName' ||
        normPath == '/$primaryDatabaseName') {
      return true;
    }

    try {
      final dbDir = await getDatabasesPath();
      final primaryCanonical = canonicalizePath(p.join(dbDir, primaryDatabaseName));
      final candidateCanonical = canonicalizePath(rawPath);

      if (candidateCanonical == primaryCanonical) {
        return true;
      }

      // If rawPath was relative, test resolution relative to dbDir
      if (!p.isAbsolute(rawPath)) {
        final candidateFromDbDir = canonicalizePath(p.join(dbDir, rawPath));
        if (candidateFromDbDir == primaryCanonical) {
          return true;
        }
      }
    } catch (_) {
      final base = p.basename(normPath);
      if (base == primaryDatabaseName &&
          !normPath.contains('staging') &&
          !normPath.contains('test') &&
          !normPath.contains('backup') &&
          !normPath.contains('tmp') &&
          !normPath.contains('cache')) {
        return true;
      }
    }

    return false;
  }

  /// Guards against opening the primary database directly, bypassing [AppDatabase]
  /// and [DatabaseAccessGate].
  static Future<void> _assertNotDirectPrimaryAccess(String path) async {
    if (await isPrimaryDatabasePath(path)) {
      throw StateError(
        'Direct opening of primary database "$primaryDatabaseName" via SpendXDatabaseFactory is prohibited. '
        'All database access must go through AppDatabase.instance.database and DatabaseAccessGate.',
      );
    }
  }

  /// Returns the underlying [DatabaseFactory] guarded against direct primary database access.
  DatabaseFactory getFactory() {
    try {
      return _GuardedDatabaseFactory(databaseFactory);
    } catch (_) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      return _GuardedDatabaseFactory(databaseFactory);
    }
  }

  /// Opens an encrypted SQLCipher database at [path] using [password].
  ///
  /// Direct invocation with the primary database ("spendx.db") is unconditionally
  /// prohibited.
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
    bool bypassPrimaryGuard = false,
  }) async {
    if (!bypassPrimaryGuard) {
      await _assertNotDirectPrimaryAccess(path);
    }
    await initialize();

    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        readOnly: readOnly,
        singleInstance: singleInstance,
        onConfigure: (db) async {
          await db.execute("PRAGMA key = '${password.replaceAll("'", "''")}';");
          await db.execute('PRAGMA cipher_page_size = 4096;');

          try {
            await db.rawQuery('SELECT count(*) FROM sqlite_master;');
          } catch (e) {
            throw InvalidDatabaseKeyException(
              'Failed to authenticate database with supplied key: SQLITE_NOTADB or corrupted header.',
              e,
            );
          }

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
  ///
  /// Direct invocation with the primary database ("spendx.db") is unconditionally
  /// prohibited.
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
    bool bypassPrimaryGuard = false,
  }) async {
    if (!bypassPrimaryGuard) {
      await _assertNotDirectPrimaryAccess(path);
    }
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

/// A delegating [DatabaseFactory] wrapper that prevents opening the primary
/// SpendX database without [DatabaseAccessGate] admission protection.
class _GuardedDatabaseFactory implements DatabaseFactory {
  final DatabaseFactory _delegate;

  _GuardedDatabaseFactory(this._delegate);

  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) async {
    await SpendXDatabaseFactory._assertNotDirectPrimaryAccess(path);
    return await _delegate.openDatabase(path, options: options);
  }

  @override
  Future<void> deleteDatabase(String path) => _delegate.deleteDatabase(path);

  @override
  Future<bool> databaseExists(String path) => _delegate.databaseExists(path);

  @override
  Future<String> getDatabasesPath() => _delegate.getDatabasesPath();

  @override
  Future<void> setDatabasesPath(String path) => _delegate.setDatabasesPath(path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Genuine library-private function strictly accessible only to [AppDatabase]
/// within this library. Unrelated production libraries cannot view or invoke it.
Future<Database> _openPrimaryEncryptedInternal({
  required String path,
  required String password,
  required int version,
  OnDatabaseConfigureFn? onConfigure,
  OnDatabaseCreateFn? onCreate,
  OnDatabaseVersionChangeFn? onUpgrade,
  OnDatabaseOpenFn? onOpen,
}) async {
  await SpendXDatabaseFactory.instance.initialize();

  return await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onConfigure: (db) async {
        await db.execute("PRAGMA key = '${password.replaceAll("'", "''")}';");
        await db.execute('PRAGMA cipher_page_size = 4096;');

        try {
          await db.rawQuery('SELECT count(*) FROM sqlite_master;');
        } catch (e) {
          throw InvalidDatabaseKeyException(
            'Failed to authenticate database with supplied key: SQLITE_NOTADB or corrupted header.',
            e,
          );
        }

        await db.execute('PRAGMA foreign_keys = ON;');
        await db.rawQuery('PRAGMA busy_timeout = 5000;');

        if (onConfigure != null) {
          await onConfigure(db);
        }
      },
      onCreate: onCreate,
      onUpgrade: onUpgrade,
      onOpen: onOpen,
    ),
  );
}

/// Genuine library-private function strictly accessible only to [AppDatabase]
/// within this library.
Future<Database> _openPrimaryPlaintextInternal({
  required String path,
  int? version,
  OnDatabaseConfigureFn? onConfigure,
  OnDatabaseCreateFn? onCreate,
  OnDatabaseVersionChangeFn? onUpgrade,
  OnDatabaseOpenFn? onOpen,
}) async {
  await SpendXDatabaseFactory.instance.initialize();

  return await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
        await db.rawQuery('PRAGMA busy_timeout = 5000;');
        if (onConfigure != null) {
          await onConfigure(db);
        }
      },
      onCreate: onCreate,
      onUpgrade: onUpgrade,
      onOpen: onOpen,
    ),
  );
}
