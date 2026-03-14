import 'package:uuid/uuid.dart';

class DeviceLinkingService {
  DeviceLinkingService._();
  static final instance = DeviceLinkingService._();

  /// Generates a payload for the QR code.
  /// Format: spendx:link:{provider_name}:{session_id}:{timestamp}
  String generateLinkingPayload(String providerName) {
    final sessionId = const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'spendx:link:$providerName:$sessionId:$timestamp';
  }

  /// Parses and validates a scanned payload.
  Map<String, String>? parsePayload(String payload) {
    if (!payload.startsWith('spendx:link:')) return null;
    
    final parts = payload.split(':');
    if (parts.length != 5) return null;

    final provider = parts[2];
    final sessionId = parts[3];
    final timestamp = int.tryParse(parts[4]) ?? 0;

    // Optional: Expire codes older than 10 minutes
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - timestamp > 600000) return null;

    return {
      'provider': provider,
      'sessionId': sessionId,
    };
  }
}
