import '../core/logging/app_logger.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'database_helper.dart';
import 'settings_service.dart';

/// BackupFileService — creates and parses the canonical SpendX backup JSON.
///
/// Backup format (spendx_backup.json):
/// {
///   "version": 1,
///   "createdAt": "...",
///   "transactions": [...],
///   "vehicles": [...],
///   "budgets": [...],
///   "lending": [...],
///   "settings": {...}
/// }
class BackupFileService {
  BackupFileService._();
  static final BackupFileService instance = BackupFileService._();

  static const String backupFileName = 'spendx_backup.json';

  // ─── Build ───────────────────────────────────────────

  /// Collect all data and encode as a clean JSON string along with its checksum.
  Future<(String, String)> createBackupJson() async {
    _log("collecting data...");

    final db = DatabaseHelper.instance;

    // Gather every table data from main thread (DB access must be on main)
    final tables = await db.getFullSnapshot();
    final syncedSettings = SettingsService.instance.getSyncedSettings();

    _log("offloading encoding to isolate...");
    
    // Offload heavy payload construction and JSON string encoding to background isolate
    final (json, hash) = await compute(_buildAndEncode, {
      'tables': tables,
      'settings': syncedSettings,
    });
    
    _log("backup JSON created (${json.length} chars)");
    return (json, hash);
  }

  /// Pure helper that runs in a background isolate to prevent UI jank.
  static (String, String) _buildAndEncode(Map<String, dynamic> input) {
    final Map<String, dynamic> tables = input['tables'];
    final Map<String, dynamic> settings = input['settings'];

    // 1. Core tables string for hashing
    final tablesJson = jsonEncode(tables);
    final settingsJson = jsonEncode(settings);
    final hash = sha256.convert(utf8.encode(tablesJson + settingsJson)).toString();

    final payload = <String, dynamic>{
      'version': 1,
      'app': 'SpendX',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'checksum': hash, 
      'tables': tables,
      'settings': settings,
    };

    return (jsonEncode(payload), hash);
  }

  // ─── Parse ───────────────────────────────────────────

  /// Parse and validate a backup JSON string.
  /// Returns the decoded map or null on failure.
  Future<Map<String, dynamic>?> parseBackupJson(String jsonString) async {
    try {
      // Offload heavy JSON string decoding to background isolate
      final dynamic raw = await compute(jsonDecode, jsonString);
      if (raw is! Map<String, dynamic>) {
        _log("invalid format — expected JSON object");
        return null;
      }
      if (raw['app'] != 'SpendX') {
        _log("invalid app signature");
        return null;
      }
      if (raw['version'] != 1) {
        _log("unsupported backup version: ${raw['version']}");
        return null;
      }

      // --- Integrity Check ---
      if (raw.containsKey('checksum')) {
        final tablesJson = jsonEncode(raw['tables'] ?? {});
        final settingsJson = jsonEncode(raw['settings'] ?? {});
        final expectedHash = sha256.convert(utf8.encode(tablesJson + settingsJson)).toString();
        
        if (raw['checksum'] != expectedHash) {
          _log("INTEGRITY ERROR: checksum mismatch! File might be corrupted.");
          return null;
        }
        _log("integrity verified via SHA256");
      }

      _log("backup JSON parsed successfully (version ${raw['version']})");
      return raw;
    } catch (e) {
      _log("parse error: $e");
      return null;
    }
  }

  void _log(String msg) => AppLogger.d("[BACKUP_FILE] $msg");
}
