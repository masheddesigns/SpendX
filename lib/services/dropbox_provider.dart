import 'dart:io';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'cloud_backup_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:url_launcher/url_launcher.dart';
import 'settings_service.dart';

class DropboxProvider implements CloudProvider {
  // Singleton Pattern
  DropboxProvider._();
  static final DropboxProvider instance = DropboxProvider._();

  @override
  String get name => 'Dropbox';

  final _storage = const FlutterSecureStorage();
  final String _clientId = dotenv.get('DROPBOX_CLIENT_ID', fallback: '');
  static const String _tokenKey = 'dropbox_token';
  
  String? _accessToken;

  @override
  Future<bool> signIn() async {
    // Attempt to load existing token
    _accessToken = await _storage.read(key: 'dropbox_token');
    if (_accessToken != null) return true;

    if (_clientId.isEmpty) {
      debugPrint('Dropbox: Error - DROPBOX_CLIENT_ID is missing in .env');
      return false;
    }

    // Since we are in a headless environment, we'll prompt the user 
    // to go to the auth URL and paste the token back.
    final authUrl = 'https://www.dropbox.com/oauth2/authorize?client_id=$_clientId&response_type=token&redirect_uri=http://localhost';
    
    if (await canLaunchUrl(Uri.parse(authUrl))) {
      await launchUrl(Uri.parse(authUrl), mode: LaunchMode.externalApplication);
      debugPrint('Dropbox: Opened auth URL. User needs to provide the token.');
      return false; // The hub screen should show a dialog to paste the token
    }

    return false;
  }

  /// Manually set the access token (useful for the "Paste Token" flow)
  Future<void> setAccessToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
    _accessToken = token;
    SettingsService.instance.setLastCloudProvider('dropbox');
  }

  @override
  Future<void> signOut() async {
    await _storage.delete(key: _tokenKey);
    _accessToken = null;
    SettingsService.instance.setLastCloudProvider(null);
  }

  @override
  Future<bool> isSignedIn() async {
    _accessToken ??= await _storage.read(key: _tokenKey);
    if (_accessToken != null) {
      SettingsService.instance.setLastCloudProvider('dropbox');
    }
    return _accessToken != null;
  }

  @override
  Future<String?> uploadFile({
    required File file,
    required String remoteName,
    String? folderId,
  }) async {
    if (_accessToken == null) return null;

    final url = Uri.parse('https://content.dropboxapi.com/2/files/upload');
    final apiArgs = {
      'path': '/$remoteName',
      'mode': 'overwrite',
      'autorename': true,
      'mute': false,
    };

    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Dropbox-API-Arg': jsonEncode(apiArgs),
          'Content-Type': 'application/octet-stream',
        },
        body: await file.readAsBytes(),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['id'];
      }
    } catch (e) {
      debugPrint('Dropbox Upload Error: $e');
    }
    return null;
  }

  @override
  Future<File?> downloadFile({
    required String fileId,
    required String localPath,
  }) async {
    if (_accessToken == null) return null;

    final url = Uri.parse('https://content.dropboxapi.com/2/files/download');
    final apiArgs = {'path': fileId};

    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Dropbox-API-Arg': jsonEncode(apiArgs),
        },
      );

      if (response.statusCode == 200) {
        final file = File(localPath);
        await file.writeAsBytes(response.bodyBytes);
        return file;
      }
    } catch (e) {
      debugPrint('Dropbox Download Error: $e');
    }
    return null;
  }

  @override
  Future<List<CloudFile>> listFiles() async {
    if (_accessToken == null) return [];

    final url = Uri.parse('https://api.dropboxapi.com/2/files/list_folder');
    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'path': '', 'recursive': false}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List entries = data['entries'];
        
        return entries
            .where((e) => e['.tag'] == 'file' && (e['name'].contains('spendx_backup_') || e['name'].contains('spendx_active_sync')))
            .map((e) => CloudFile(
                  id: e['path_lower'],
                  name: e['name'],
                  modifiedAt: DateTime.parse(e['server_modified']),
                  size: e['size'],
                ))
            .toList();
      }
    } catch (e) {
      debugPrint('Dropbox listFiles Error: $e');
    }
    return [];
  }
  @override
  Future<bool> wipeAllData() async {
    if (_accessToken == null) return false;
    
    try {
      final files = await listFiles();
      if (files.isEmpty) return true;

      for (final f in files) {
        await this.deleteFile(f.id);
      }
      return true;
    } catch (e) {
      debugPrint('Dropbox Wipe Error: $e');
      return false;
    }
  }

  @override
  Future<bool> deleteFile(String fileId) async {
    if (_accessToken == null) return false;

    final url = Uri.parse('https://api.dropboxapi.com/2/files/delete_v2');
    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'path': fileId}),
      );

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Dropbox Deletion Error: $e');
      return false;
    }
  }
}
