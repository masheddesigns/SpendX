import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'cloud_backup_service.dart';
import 'settings_service.dart';

class GoogleDriveProvider implements CloudProvider {
  // Singleton Pattern
  GoogleDriveProvider._();
  static final GoogleDriveProvider instance = GoogleDriveProvider._();

  @override
  String get name => 'Google Drive';

  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  bool _initializedService = false;
  GoogleSignInAccount? _currentUser;
  bool _isCancelled = false; // Session-level flag to stop popup loops

  Future<void> _ensureInitialized() async {
    if (_initializedService) return;
    final serverClientId = dotenv.get('GOOGLE_DRIVE_CLIENT_ID', fallback: '');
    await _googleSignIn.initialize(
      serverClientId: serverClientId.isEmpty ? null : serverClientId,
    );
    _initializedService = true;
  }

  @override
  Future<bool> signIn() async {
    try {
      await _ensureInitialized();
      _currentUser = await _googleSignIn.authenticate();
      if (_currentUser != null) {
        // In 7.x, scopes are requested via the authorizationClient
        await _currentUser!.authorizationClient.authorizeScopes([
          drive.DriveApi.driveFileScope,
          drive.DriveApi.driveAppdataScope,
        ]);
      } else {
      debugPrint('Google Drive: Sign-in cancelled by user');
      }
      if (_currentUser != null) {
        SettingsService.instance.setLastCloudProvider('google');
        _isCancelled = false; // Reset abandonment flag on manual success
      }
      return _currentUser != null;
    } catch (e) {
      debugPrint('Google Drive Sign-In Error: $e');
      if (e.toString().contains('7')) {
        debugPrint('Tip: Error 7 usually means network issue or incorrect SHA-1 in Google Console');
      } else if (e.toString().contains('10')) {
        debugPrint('Tip: Error 10 usually means configuration issue (Client ID, names, etc.)');
      }
      return false;
    }
  }

  @override
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    _currentUser = null;
    SettingsService.instance.setLastCloudProvider(null);
  }

  @override
  Future<bool> isSignedIn() async {
    return _currentUser != null;
  }

  /// Explicitly attempt to recover a session silently.
  /// Called when entering the Backup screen or manually syncing.
  Future<bool> recoverSession() async {
    if (_currentUser != null) return true;
    if (SettingsService.instance.lastCloudProvider != 'google') return false;

    await _ensureInitialized();
    try {
      // In google_sign_in 7.x, attemptLightweightAuthentication is used for silent recovery
      _currentUser = await _googleSignIn.attemptLightweightAuthentication();
      if (_currentUser == null) {
        _isCancelled = true;
      } else {
        _isCancelled = false;
      }
    } catch (e) {
      debugPrint('Google Drive recovery error: $e');
      _isCancelled = true;
    }
    return _currentUser != null;
  }

  @override
  Future<bool> deleteFile(String fileId) async {
    try {
      final driveApi = await _getDriveApi();
      if (driveApi == null) return false;
      await driveApi.files.delete(fileId);
      return true;
    } catch (e) {
      debugPrint('Google Drive Deletion Error: $e');
      return false;
    }
  }

  Future<drive.DriveApi?> _getDriveApi() async {
    await _ensureInitialized();
    if (_currentUser == null) {
      await isSignedIn();
    }
    if (_currentUser == null) return null;
    
    // In google_sign_in 7.x + extension 3.x, use authorizationClient and authClient()
    final scopes = [
      drive.DriveApi.driveFileScope,
      drive.DriveApi.driveAppdataScope,
    ];
    final authz = await _currentUser!.authorizationClient.authorizeScopes(scopes);
    final client = authz.authClient(scopes: scopes);
    return drive.DriveApi(client);
  }

  @override
  Future<bool> wipeAllData() async {
    try {
      final driveApi = await _getDriveApi();
      if (driveApi == null) return false;

      // Find all files matching our patterns
      final list = await driveApi.files.list(
        q: "(name contains 'spendx_backup_' or name contains 'spendx_active_sync') and trashed = false",
        spaces: 'drive',
      );

      if (list.files == null || list.files!.isEmpty) return true;

      for (final f in list.files!) {
        await driveApi.files.delete(f.id!);
      }
      return true;
    } catch (e) {
      debugPrint('Google Drive Wipe Error: $e');
      return false;
    }
  }

  @override
  Future<String?> uploadFile({
    required File file,
    required String remoteName,
    String? folderId,
  }) async {
    try {
      final driveApi = await _getDriveApi();
      if (driveApi == null) return null;

      final driveFile = drive.File();
      driveFile.name = remoteName;
      if (folderId != null) {
        driveFile.parents = [folderId];
      }

      final media = drive.Media(file.openRead(), file.lengthSync());
      
      // Check if file exists to update instead of duplicate
      final list = await driveApi.files.list(
        q: "name = '$remoteName' and trashed = false",
        spaces: 'drive',
      );

      if (list.files != null && list.files!.isNotEmpty) {
        final existingFileId = list.files!.first.id!;
        final result = await driveApi.files.update(
          driveFile,
          existingFileId,
          uploadMedia: media,
        );
        return result.id;
      } else {
        final result = await driveApi.files.create(
          driveFile,
          uploadMedia: media,
          // Removed duplicate fields list which matched the created file anyway
        );
        return result.id;
      }
    } catch (e) {
      debugPrint('Google Drive Upload Error: $e');
      return null;
    }
  }

  @override
  Future<File?> downloadFile({
    required String fileId,
    required String localPath,
  }) async {
    try {
      final driveApi = await _getDriveApi();
      if (driveApi == null) return null;

      final media = await driveApi.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      final file = File(localPath);
      final IOSink sink = file.openWrite();
      await media.stream.pipe(sink);
      await sink.close();
      return file;
    } catch (e) {
      debugPrint('Google Drive Download Error: $e');
      return null;
    }
  }

  @override
  Future<List<CloudFile>> listFiles() async {
    try {
      final driveApi = await _getDriveApi();
      if (driveApi == null) return [];

      final list = await driveApi.files.list(
        q: "(name contains 'spendx_backup_' or name contains 'spendx_active_sync') and trashed = false",
        spaces: 'drive',
        $fields: 'files(id, name, modifiedTime, size)',
      );

      if (list.files == null) return [];

      return list.files!.map((f) => CloudFile(
        id: f.id!,
        name: f.name!,
        modifiedAt: f.modifiedTime ?? DateTime.now(),
        size: int.tryParse(f.size ?? '0') ?? 0,
      )).toList();
    } catch (e) {
      debugPrint('Google Drive listFiles Error: $e');
      return [];
    }
  }
}
