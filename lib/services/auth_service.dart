import '../core/logging/app_logger.dart';
import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart';
import 'settings_service.dart';

// ─── OAuth Client IDs ───────────────────────────────────────────────────────
// Web Client ID — used as serverClientId on Android for token exchange
const _kWebClientId =
    '624697970383-e94m5ts5hlof05kf2lt0h1l24f0r9uka.apps.googleusercontent.com';

// Desktop Client ID — used as clientId on macOS/Windows
const _kDesktopClientId =
    '624697970383-tgka5t17i21af621h6n5nlg4amlhmp7n.apps.googleusercontent.com';
// ────────────────────────────────────────────────────────────────────────────

/// Builds the correctly-configured GoogleSignIn for the current platform.
///
/// Android:
///   • google_sign_in reads the client_id from google-services.json automatically.
///   • We supply the WEB client ID as serverClientId so the server can verify.
///   • Do NOT pass clientId on Android — it causes ApiException: 10.
///
/// Desktop (macOS / Windows / Linux):
///   • Pass the Desktop OAuth client ID as clientId.
///
/// Web:
///   • clientId is supplied; serverClientId not needed.
GoogleSignIn _buildGoogleSignIn() {
  final scopes = ['email', DriveApi.driveFileScope];

  if (kIsWeb) {
    return GoogleSignIn(clientId: _kWebClientId, scopes: scopes);
  }

  if (Platform.isAndroid) {
    // On Android: serverClientId = Web Client ID, NO clientId
    return GoogleSignIn(serverClientId: _kWebClientId, scopes: scopes);
  }

  // macOS / Windows / Linux: use Desktop client ID
  return GoogleSignIn(clientId: _kDesktopClientId, scopes: scopes);
}

// ─── Error code constants ────────────────────────────────────────────────────
const _kApiExceptionNetworkError = 7;
const _kApiExceptionDeveloperError = 10; // SHA-1 / client-id mismatch

/// Human-readable message for a given Google Sign-In error.
String _friendlyAuthError(dynamic e) {
  final str = e.toString();
  if (str.contains('$_kApiExceptionDeveloperError') ||
      str.contains('sign_in_failed')) {
    return 'Google Sign-In configuration issue. Please try again later.';
  }
  if (str.contains('$_kApiExceptionNetworkError') ||
      str.contains('network_error')) {
    return 'Network error. Check your internet connection and try again.';
  }
  if (str.contains('sign_in_canceled') || str.contains('canceled')) {
    return ''; // Silently ignore user cancellations
  }
  return 'Sign-in failed. Please try again.';
}

// ─── AuthService ─────────────────────────────────────────────────────────────

class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  final GoogleSignIn _googleSignIn = _buildGoogleSignIn();

  GoogleSignInAccount? _currentUser;

  /// Last human-readable error (empty = no error).
  String _lastError = '';
  String get lastError => _lastError;

  // ── Init ──────────────────────────────────────────────────────────────────

  /// Silently restores a previous session without showing any UI.
  Future<void> initialize() async {
    try {
      _currentUser = await _googleSignIn.signInSilently();
      await _persistConnectionState();
      notifyListeners();
    } catch (e) {
      AppLogger.d('[AUTH] Silent sign-in failed: $e');
      await _persistConnectionState();
      // Not a user-facing error; silently swallow.
    }
  }

  // ── Login ─────────────────────────────────────────────────────────────────

  /// Triggers the interactive Google Sign-In flow.
  /// Returns true on success, false on failure (check [lastError] for message).
  Future<bool> login() async {
    _lastError = '';
    try {
      _currentUser = await _googleSignIn.signIn();
      await _persistConnectionState();
      notifyListeners();
      return _currentUser != null;
    } catch (e) {
      AppLogger.d('[AUTH] Login failed: $e');
      _lastError = _friendlyAuthError(e);
      await _persistConnectionState();
      notifyListeners();
      return false;
    }
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (e) {
      AppLogger.d('[AUTH] Sign-out error: $e');
    }
    _currentUser = null;
    _lastError = '';
    await _persistConnectionState();
    notifyListeners();
  }

  // ── State Getters ─────────────────────────────────────────────────────────

  bool get isSignedIn => _currentUser != null;
  String? get currentAccountEmail => _currentUser?.email;
  GoogleSignInAccount? get currentUser => _currentUser;

  /// Returns a formatted string for the month/year the user joined (e.g., "Mar 2024").
  String? get memberSinceLabel {
    final date = SettingsService.instance.userJoinDate;
    if (date == null) return null;

    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[date.month - 1]} ${date.year}';
  }

  // ── Drive API ─────────────────────────────────────────────────────────────

  /// Returns a fresh Drive API client, refreshing the access token if needed.
  Future<DriveApi?> getDriveApi() async {
    if (_currentUser == null) return null;
    try {
      // Force a token refresh so we always get a valid access token.
      await _currentUser!.authentication;
      final client = await _googleSignIn.authenticatedClient();
      if (client == null) return null;
      return DriveApi(client);
    } catch (e) {
      AppLogger.d('[AUTH] Drive API error: $e');
      _lastError = _friendlyAuthError(e);
      notifyListeners();
      return null;
    }
  }

  /// Silently refreshes the token. Call this on app resume.
  /// Returns true if the account is valid, false if re-login is needed.
  Future<bool> ensureValidToken() async {
    if (_currentUser == null) return false;
    try {
      final auth = await _currentUser!.authentication;
      final isValid = auth.accessToken != null;
      if (!isValid) {
        // Try silent sign-in to re-acquire tokens
        _currentUser = await _googleSignIn.signInSilently();
        await _persistConnectionState();
        notifyListeners();
      }
      return _currentUser != null;
    } catch (e) {
      AppLogger.d('[AUTH] Token refresh failed: $e');
      // Token is expired AND silent sign-in failed — force full re-login next time
      _currentUser = await _googleSignIn.signInSilently();
      await _persistConnectionState();
      notifyListeners();
      return _currentUser != null;
    }
  }

  Future<void> _persistConnectionState() async {
    await SettingsService.instance.setGoogleDriveConnected(
      _currentUser != null,
    );
    await SettingsService.instance.setGoogleEmail(_currentUser?.email);
    await SettingsService.instance.setDriveConnectedAccount(
      _currentUser?.email,
    );
  }
}
