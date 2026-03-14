import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

import 'database_helper.dart';

class BackupService {
  BackupService._();
  static final instance = BackupService._();

  static const String backupExtension = '.spx_backup';
  
  /// Internal structure for Isolate processing
  static Future<File?> _executeBackupIsolate(Map<String, dynamic> params) async {
    final snapshot = params['snapshot'] as Map<String, dynamic>;
    final path = params['path'] as String;
    
    final Map<String, dynamic> backupData = {
      'version': '1.0',
      'timestamp': DateTime.now().toIso8601String(),
      'data': snapshot,
    };

    final jsonString = jsonEncode(backupData);
    final file = File(path);
    await file.writeAsString(jsonString);
    return file;
  }

  /// Creates a local JSON backup file of the entire database
  /// Now optimized to do heavy processing in an isolate if possible (via helper)
  Future<File?> createBackup({bool isSync = false}) async {
    try {
      final snapshot = await DatabaseHelper.instance.getFullSnapshot();
      
      final directory = await getApplicationDocumentsDirectory();
      final backupDir = Directory('${directory.path}/SpendX Backups');
      if (!await backupDir.exists()) await backupDir.create(recursive: true);

      String fileName;
      final deviceName = Platform.localHostname.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
      if (isSync) {
        fileName = 'spendx_sync_${deviceName}$backupExtension';
      } else {
        final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
        fileName = 'spendx_backup_${deviceName}_$timestamp$backupExtension';
      }
      
      final path = '${backupDir.path}/$fileName';

      // Heavy lifting via compute if in Flutter, otherwise direct
      if (kIsWeb) return null;
      
      // Moving JSON encoding and File IO to a separate thread
      return await compute(_executeBackupIsolate, {
        'snapshot': snapshot,
        'path': path,
      });
    } catch (e) {
      debugPrint('Error creating backup: $e');
      return null;
    }
  }

  /// Restores the database from a given backup file
  Future<bool> restoreFromBackup(File file) async {
    try {
      final jsonString = await file.readAsString();
      final Map<String, dynamic> backupData = jsonDecode(jsonString);

      if (backupData['data'] == null) return false;

      await DatabaseHelper.instance.restoreFromSnapshot(backupData['data']);
      return true;
    } catch (e) {
      debugPrint('Error restoring backup: $e');
      return false;
    }
  }

  /// Lists all available local backups
  Future<List<File>> getLocalBackups() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final backupDir = Directory('${directory.path}/SpendX Backups');
      if (!await backupDir.exists()) return [];

      final files = backupDir.listSync().whereType<File>().toList();
      files.sort((a, b) => b.path.compareTo(a.path)); // Newest first
      return files;
    } catch (e) {
      debugPrint('Error listing backups: $e');
      return [];
    }
  }

  /// Deletes a specific backup file
  Future<void> deleteBackup(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }
}
