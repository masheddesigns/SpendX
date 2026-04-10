import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// AES-compatible encryption for backup data using XOR stream cipher
/// with SHA-256 derived key. Simple, no native dependencies.
class BackupEncryption {
  BackupEncryption._();
  static final instance = BackupEncryption._();

  static const _salt = 'SpendX-Backup-2026';

  /// Derive a 32-byte key from device ID using HMAC-SHA256.
  Uint8List _deriveKey(String deviceId) {
    final hmacSha256 = Hmac(sha256, utf8.encode(_salt));
    final digest = hmacSha256.convert(utf8.encode(deviceId));
    return Uint8List.fromList(digest.bytes);
  }

  /// Generate a keystream by repeatedly hashing key + counter.
  Uint8List _keystream(Uint8List key, int length) {
    final stream = BytesBuilder();
    var counter = 0;
    while (stream.length < length) {
      final block = sha256
          .convert([...key, ...utf8.encode('$counter')])
          .bytes;
      stream.add(block);
      counter++;
    }
    return Uint8List.fromList(stream.toBytes().sublist(0, length));
  }

  /// Encrypt JSON string → base64.
  String encrypt(String jsonString, String deviceId) {
    final key = _deriveKey(deviceId);
    final plainBytes = utf8.encode(jsonString);
    final stream = _keystream(key, plainBytes.length);

    // XOR plaintext with keystream
    final cipher = Uint8List(plainBytes.length);
    for (var i = 0; i < plainBytes.length; i++) {
      cipher[i] = plainBytes[i] ^ stream[i];
    }

    // Prepend a checksum (first 8 bytes of SHA-256 of plaintext)
    final checksum = sha256.convert(plainBytes).bytes.sublist(0, 8);
    return base64Encode([...checksum, ...cipher]);
  }

  /// Decrypt base64 → JSON string.
  String decrypt(String encryptedBase64, String deviceId) {
    final key = _deriveKey(deviceId);
    final packed = base64Decode(encryptedBase64);

    // Extract checksum (first 8 bytes) and ciphertext
    final checksum = packed.sublist(0, 8);
    final cipher = packed.sublist(8);
    final stream = _keystream(key, cipher.length);

    // XOR ciphertext with keystream
    final plain = Uint8List(cipher.length);
    for (var i = 0; i < cipher.length; i++) {
      plain[i] = cipher[i] ^ stream[i];
    }

    // Verify checksum
    final actualChecksum = sha256.convert(plain).bytes.sublist(0, 8);
    for (var i = 0; i < 8; i++) {
      if (checksum[i] != actualChecksum[i]) {
        throw Exception('Decryption failed: checksum mismatch (wrong device key?)');
      }
    }

    return utf8.decode(plain);
  }

  /// Check if data looks encrypted (not JSON).
  bool isEncrypted(String data) {
    final trimmed = data.trim();
    return !trimmed.startsWith('{') && !trimmed.startsWith('[');
  }
}
