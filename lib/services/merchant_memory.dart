import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// Learned merchant memory — turns user corrections into auto-fills.
///
/// On every save, the preview screen calls [learn] with the raw OCR/share
/// text and the merchant the user actually used. We hash a signature of
/// the raw text (first 12 normalized tokens) and remember the merchant.
///
/// Next time a screenshot with a similar signature comes in, [check]
/// returns the learned merchant before any regex runs — highest priority
/// in the resolver.
///
/// Storage: SharedPreferences (single JSON map). Bounded at 200 entries
/// with FIFO eviction so memory stays small.
class MerchantMemory {
  MerchantMemory._();
  static final instance = MerchantMemory._();

  static const _kKey = 'merchant_memory_v1';
  static const _maxEntries = 200;
  static const _signatureTokenCount = 12;

  /// In-memory cache to avoid re-reading prefs on every parse.
  Map<String, _LearnedEntry>? _cache;

  /// Build a stable signature for [rawText] — first N normalized tokens.
  /// Two screenshots with the same template (same payment app, similar
  /// layout) should produce the same signature even if amounts differ.
  ///
  /// Note: merchant is intentionally NOT included here — at lookup time
  /// the merchant is what we're trying to learn, so it's not available.
  /// Collision protection comes from the token window (12 tokens of ≥3
  /// chars), which captures enough template structure to disambiguate
  /// most real screenshots.
  String buildSignature(String rawText) {
    final normalized = rawText
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z ]'), ' ') // drop digits + punctuation
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return '';
    return normalized
        .split(' ')
        .where((t) => t.isNotEmpty && t.length >= 3)
        .take(_signatureTokenCount)
        .join(' ');
  }

  /// Look up a learned merchant for [rawText]. Returns null if no match.
  Future<String?> check(String rawText) async {
    if (rawText.trim().isEmpty) return null;
    final sig = buildSignature(rawText);
    if (sig.isEmpty) return null;
    final cache = await _load();
    final entry = cache[sig];
    return entry?.merchant;
  }

  /// Record a user-confirmed (text → merchant) mapping. Idempotent.
  /// Increments frequency on repeat. Evicts the oldest entry when over cap.
  Future<void> learn(String rawText, String merchant) async {
    if (rawText.trim().isEmpty || merchant.trim().isEmpty) return;
    final sig = buildSignature(rawText);
    if (sig.isEmpty) return;
    try {
      final cache = await _load();
      final existing = cache[sig];
      if (existing != null && existing.merchant == merchant) {
        cache[sig] = existing.copyWith(
          frequency: existing.frequency + 1,
          updatedAt: DateTime.now(),
        );
      } else {
        cache[sig] = _LearnedEntry(
          signature: sig,
          merchant: merchant,
          frequency: 1,
          updatedAt: DateTime.now(),
        );
      }
      // FIFO eviction by oldest updatedAt
      if (cache.length > _maxEntries) {
        final entries = cache.entries.toList()
          ..sort((a, b) => a.value.updatedAt.compareTo(b.value.updatedAt));
        final toRemove = entries.length - _maxEntries;
        for (var i = 0; i < toRemove; i++) {
          cache.remove(entries[i].key);
        }
      }
      await _persist(cache);
    } catch (e) {
      debugPrint('[MerchantMemory] learn failed: $e');
    }
  }

  /// Reset all learned mappings. Used in tests / data wipe.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
    _cache = null;
  }

  Future<int> count() async => (await _load()).length;

  Future<Map<String, _LearnedEntry>> _load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null) {
      _cache = <String, _LearnedEntry>{};
      return _cache!;
    }
    try {
      final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
      _cache = decoded.map(
        (k, v) => MapEntry(k, _LearnedEntry.fromMap(v as Map<String, dynamic>)),
      );
      return _cache!;
    } catch (e) {
      debugPrint('[MerchantMemory] load failed, resetting: $e');
      _cache = <String, _LearnedEntry>{};
      return _cache!;
    }
  }

  Future<void> _persist(Map<String, _LearnedEntry> cache) async {
    _cache = cache;
    final prefs = await SharedPreferences.getInstance();
    final encoded =
        jsonEncode(cache.map((k, v) => MapEntry(k, v.toMap())));
    await prefs.setString(_kKey, encoded);
  }
}

class _LearnedEntry {
  final String signature;
  final String merchant;
  final int frequency;
  final DateTime updatedAt;

  const _LearnedEntry({
    required this.signature,
    required this.merchant,
    required this.frequency,
    required this.updatedAt,
  });

  _LearnedEntry copyWith({int? frequency, DateTime? updatedAt}) =>
      _LearnedEntry(
        signature: signature,
        merchant: merchant,
        frequency: frequency ?? this.frequency,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'signature': signature,
        'merchant': merchant,
        'frequency': frequency,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory _LearnedEntry.fromMap(Map<String, dynamic> m) => _LearnedEntry(
        signature: m['signature'] as String,
        merchant: m['merchant'] as String,
        frequency: (m['frequency'] as num?)?.toInt() ?? 1,
        updatedAt: DateTime.parse(m['updatedAt'] as String),
      );
}
