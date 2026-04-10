import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

class DriveService {
  DriveService._();
  static final DriveService instance = DriveService._();

  final _googleSignIn = GoogleSignIn.standard(
    scopes: [drive.DriveApi.driveAppdataScope],
  );

  drive.DriveApi? _driveApi;
  bool _isInit = false;
  bool _backupInProgress = false;

  bool get isInitialized => _isInit;
  bool get backupInProgress => _backupInProgress;

  Future<void> init() async {
    await initialize();
  }

  Future<void> initialize() async {
    final account = await _googleSignIn.signInSilently() ?? await _googleSignIn.signIn();
    if (account == null) return;

    final authHeaders = await account.authHeaders;
    final client = GoogleAuthClient(authHeaders);
    _driveApi = drive.DriveApi(client);
    _isInit = true;
  }

  /// Disconnect from Google Drive.
  void disconnect() {
    _driveApi = null;
    _isInit = false;
  }

  drive.DriveApi get api {
    if (_driveApi == null) throw Exception('DriveService not initialized');
    return _driveApi!;
  }

  // ── Upload ──────────────────────────────────────────────

  Future<int> uploadJson(List<int> jsonBytes) async {
    _backupInProgress = true;
    try {
      // Delete old backup first (single-file strategy)
      try {
        final existing = await api.files.list(
          spaces: 'appDataFolder',
          q: "name='spendx_backup.json'",
        );
        if (existing.files != null && existing.files!.isNotEmpty) {
          for (final f in existing.files!) {
            await api.files.delete(f.id!);
          }
        }
      } catch (_) {}

      final file = drive.File()
        ..name = 'spendx_backup.json'
        ..parents = ['appDataFolder'];

      final media = drive.Media(Stream.value(jsonBytes), jsonBytes.length);
      await api.files.create(file, uploadMedia: media);
      return 1;
    } finally {
      _backupInProgress = false;
    }
  }

  Future<void> uploadMetadata(Map<String, dynamic> metadata) async {
    final encoded = jsonEncode(metadata);
    final data = utf8.encode(encoded);

    // Delete old metadata
    try {
      final existing = await api.files.list(
        spaces: 'appDataFolder',
        q: "name='spendx_metadata.json'",
      );
      if (existing.files != null && existing.files!.isNotEmpty) {
        for (final f in existing.files!) {
          await api.files.delete(f.id!);
        }
      }
    } catch (_) {}

    final file = drive.File()
      ..name = 'spendx_metadata.json'
      ..parents = ['appDataFolder'];

    final media = drive.Media(Stream.value(data), data.length);
    await api.files.create(file, uploadMedia: media);
  }

  // ── Download ────────────────────────────────────────────

  Future<String?> downloadJson() async {
    final files = await api.files.list(
      spaces: 'appDataFolder',
      q: "name='spendx_backup.json'",
    );
    if (files.files == null || files.files!.isEmpty) return null;

    final fileId = files.files!.first.id!;
    final media = await api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final chunks = <int>[];
    await for (final chunk in media.stream) {
      chunks.addAll(chunk);
    }
    return utf8.decode(chunks);
  }

  Future<Map<String, dynamic>?> downloadMetadata() async {
    final files = await api.files.list(
      spaces: 'appDataFolder',
      q: "name='spendx_metadata.json'",
    );
    if (files.files == null || files.files!.isEmpty) return null;

    final fileId = files.files!.first.id!;
    final media = await api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final chunks = <int>[];
    await for (final chunk in media.stream) {
      chunks.addAll(chunk);
    }
    return jsonDecode(utf8.decode(chunks));
  }

  Future<List<drive.File>> listBackups() async {
    final files = await api.files.list(spaces: 'appDataFolder');
    return files.files ?? [];
  }
}

/// Riverpod provider wrapping the singleton.
final driveServiceProvider = Provider((ref) => DriveService.instance);
