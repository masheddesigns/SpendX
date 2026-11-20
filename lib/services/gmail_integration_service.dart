import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/gmail/v1.dart' as gmail;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/logging/app_logger.dart';
import 'live_sms_service.dart';

class _GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  _GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

/// Dedicated, read-only Gmail email integration service.
///
/// Under explicit user authorization, queries financial banking alerts,
/// statements, card bill dues, and refunds from the user's Gmail mailbox.
/// Every candidate is passed through the standard deduplication, canonical ledger,
/// and Review Queue pipeline under strict privacy controls.
class GmailIntegrationService {
  GmailIntegrationService._();
  static final GmailIntegrationService instance = GmailIntegrationService._();

  static const String gmailReadonlyScope = 'https://www.googleapis.com/auth/gmail.readonly';
  static const String _connectedEmailKey = 'gmail_connected_account_email';
  static const String _lastSyncTimestampKey = 'gmail_last_sync_timestamp';

  final _googleSignIn = GoogleSignIn.standard(
    scopes: [gmailReadonlyScope, 'email'],
  );

  gmail.GmailApi? _gmailApi;
  String? _connectedEmail;

  bool get isConnected => _connectedEmail != null && _connectedEmail!.isNotEmpty;
  String? get connectedEmail => _connectedEmail;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _connectedEmail = prefs.getString(_connectedEmailKey);
    if (_connectedEmail != null && _connectedEmail!.isNotEmpty) {
      try {
        final account = await _googleSignIn.signInSilently();
        if (account != null) {
          final authHeaders = await account.authHeaders;
          _gmailApi = gmail.GmailApi(_GoogleAuthClient(authHeaders));
        }
      } catch (e) {
        AppLogger.w('[GmailIntegrationService] Silent sign-in failed: $e');
      }
    }
  }

  /// Explicit user sign-in to authorize read-only financial email access.
  Future<bool> connect() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) return false;

      final authHeaders = await account.authHeaders;
      _gmailApi = gmail.GmailApi(_GoogleAuthClient(authHeaders));
      _connectedEmail = account.email;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_connectedEmailKey, account.email);
      AppLogger.i('[GmailIntegrationService] Connected read-only Gmail for ${_connectedEmail!}');
      return true;
    } catch (e) {
      AppLogger.e('[GmailIntegrationService] Connect error: $e');
      return false;
    }
  }

  /// Disconnect and revoke read-only email integration.
  Future<void> disconnect() async {
    try {
      await _googleSignIn.disconnect();
    } catch (_) {
      try {
        await _googleSignIn.signOut();
      } catch (_) {}
    }
    _gmailApi = null;
    _connectedEmail = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_connectedEmailKey);
    AppLogger.i('[GmailIntegrationService] Disconnected and revoked Gmail integration');
  }

  /// Syncs financial emails (statements, debits, credits, card bills, refunds).
  ///
  /// Restricts queries exclusively to known financial senders and keywords.
  /// Never queries or reads personal correspondence.
  Future<({int scanned, int ingested, String? error})> syncFinancialEmails({
    DateTime? since,
    int maxResults = 50,
  }) async {
    if (!isConnected || _gmailApi == null) {
      final reconnected = await connect();
      if (!reconnected || _gmailApi == null) {
        return (scanned: 0, ingested: 0, error: 'Gmail not connected');
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final lastSyncMs = prefs.getInt(_lastSyncTimestampKey);
      final effectiveSince = since ??
          (lastSyncMs != null
              ? DateTime.fromMillisecondsSinceEpoch(lastSyncMs)
              : DateTime.now().subtract(const Duration(days: 30)));

      final epochSec = (effectiveSince.millisecondsSinceEpoch / 1000).floor();

      // High-precision financial query targeting official bank alerts and statements
      final query = 'after:$epochSec ('
          'from:hdfcbank.net OR from:icicibank.com OR from:sbi.co.in OR from:axisbank.com OR '
          'from:kotak.com OR from:cred.club OR from:sbicard.com OR from:getonecard.app OR '
          'from:federalbank.co.in OR from:idfcfirstbank.com OR from:alerts OR from:statements'
          ') AND ("debited" OR "credited" OR "spent" OR "statement" OR "bill due" OR "refund")';

      final allMessageRefs = <gmail.Message>[];
      String? pageToken;
      do {
        final listResponse = await _gmailApi!.users.messages.list(
          'me',
          q: query,
          maxResults: (maxResults - allMessageRefs.length).clamp(1, 100),
          pageToken: pageToken,
        );
        final batch = listResponse.messages ?? [];
        allMessageRefs.addAll(batch);
        pageToken = listResponse.nextPageToken;
      } while (pageToken != null && allMessageRefs.length < maxResults);

      int scanned = 0;
      int ingested = 0;

      for (final msgRef in allMessageRefs) {
        final id = msgRef.id;
        if (id == null) continue;

        try {
          final msg = await _gmailApi!.users.messages.get('me', id, format: 'full');
          scanned++;

          final headers = msg.payload?.headers ?? [];
          String sender = '';
          String subject = '';
          DateTime messageDate = DateTime.now();

          for (final h in headers) {
            final name = h.name?.toLowerCase();
            if (name == 'from') sender = h.value ?? '';
            if (name == 'subject') subject = h.value ?? '';
            if (name == 'date') {
              try {
                if (h.value != null) {
                  messageDate = DateTime.parse(h.value!);
                }
              } catch (_) {}
            }
          }

          if (msg.internalDate != null) {
            final epoch = int.tryParse(msg.internalDate!);
            if (epoch != null) {
              messageDate = DateTime.fromMillisecondsSinceEpoch(epoch);
            }
          }

          // Extract plain text snippet or body
          final snippet = msg.snippet ?? '';
          final bodyText = _extractBodyText(msg.payload) ?? snippet;
          final fullContent = subject.isNotEmpty ? '$subject: $bodyText' : bodyText;

          if (fullContent.trim().isEmpty) continue;

          final sourceRecordId = 'SRC:EMAIL:GMAIL:$id';
          final cleanSender = sender.isNotEmpty ? 'APP:com.google.android.gm:$sender' : 'APP:com.google.android.gm:Gmail';

          final outcome = await LiveSmsService.instance.testProcessBody(
            fullContent,
            sender: cleanSender,
            messageDate: messageDate,
            sourceRecordId: sourceRecordId,
          );

          if (outcome.added) {
            ingested++;
          }
        } catch (e) {
          AppLogger.w('[GmailIntegrationService] Failed to process message $id: $e');
        }
      }

      await prefs.setInt(_lastSyncTimestampKey, DateTime.now().millisecondsSinceEpoch);
      return (scanned: scanned, ingested: ingested, error: null);
    } catch (e) {
      AppLogger.e('[GmailIntegrationService] syncFinancialEmails error: $e');
      return (scanned: 0, ingested: 0, error: e.toString());
    }
  }

  String? _extractBodyText(gmail.MessagePart? part) {
    if (part == null) return null;
    if (part.mimeType == 'text/plain' && part.body?.data != null) {
      try {
        return utf8.decode(base64Url.decode(part.body!.data!));
      } catch (_) {}
    }
    if (part.parts != null) {
      for (final subPart in part.parts!) {
        final res = _extractBodyText(subPart);
        if (res != null && res.trim().isNotEmpty) return res;
      }
    }
    return null;
  }
}
