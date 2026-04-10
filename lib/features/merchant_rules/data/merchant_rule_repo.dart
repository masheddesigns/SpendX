import 'package:flutter/foundation.dart' show debugPrint;
import 'package:uuid/uuid.dart';

import '../../../data/core/app_database.dart';
import '../../../data/core/tables.dart';

/// A learned mapping: merchant keyword → category + account.
class MerchantRule {
  final String id;
  final String keyword;
  final String categoryId;
  final String? accountId;
  final int usageCount;
  final DateTime lastUsed;

  const MerchantRule({
    required this.id,
    required this.keyword,
    required this.categoryId,
    this.accountId,
    required this.usageCount,
    required this.lastUsed,
  });

  factory MerchantRule.fromMap(Map<String, dynamic> map) {
    return MerchantRule(
      id: map['id'] as String,
      keyword: map['keyword'] as String,
      categoryId: map['category_id'] as String,
      accountId: map['account_id'] as String?,
      usageCount: (map['usage_count'] as num?)?.toInt() ?? 1,
      lastUsed: DateTime.parse(map['last_used'] as String),
    );
  }
}

class MerchantRuleRepo {
  final _db = AppDatabase.instance;

  // ── Lookup ──────────────────────────────────────────────────────────

  /// Exact keyword match (highest priority).
  Future<MerchantRule?> getByKeyword(String keyword) async {
    final normalized = keyword.trim().toLowerCase();
    if (normalized.length < 3) return null;

    final db = await _db.database;
    final res = await db.query(
      Tables.merchantRules,
      where: 'keyword = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (res.isEmpty) return null;
    return MerchantRule.fromMap(res.first);
  }

  /// Contains-based match: returns the highest usage-count rule whose
  /// keyword appears inside [text]. Falls back to null if none found.
  Future<MerchantRule?> findBestMatch(String text) async {
    final lower = text.trim().toLowerCase();
    if (lower.length < 3) return null;

    final db = await _db.database;
    // Use LIKE for contains matching. We limit to top-10 by usage to keep
    // this fast and deterministic — the most-used rule wins.
    final res = await db.rawQuery(
      'SELECT * FROM ${Tables.merchantRules} '
      'WHERE ? LIKE \'%\' || keyword || \'%\' '
      'ORDER BY usage_count DESC LIMIT 1',
      [lower],
    );
    if (res.isEmpty) return null;
    return MerchantRule.fromMap(res.first);
  }

  /// Multi-signal lookup: tries exact keyword first, then contains match
  /// against the full SMS body.
  Future<MerchantRule?> resolve({
    required String keyword,
    required String fullText,
  }) async {
    // Priority 1: exact keyword match
    final exact = await getByKeyword(keyword);
    if (exact != null) return exact;

    // Priority 2: any stored keyword found inside fullText
    final fuzzy = await findBestMatch(fullText);
    return fuzzy;
  }

  // ── Read all ────────────────────────────────────────────────────────

  Future<List<MerchantRule>> getAll() async {
    final db = await _db.database;
    final res = await db.query(
      Tables.merchantRules,
      orderBy: 'usage_count DESC',
    );
    return res.map((e) => MerchantRule.fromMap(e)).toList();
  }

  // ── Write ───────────────────────────────────────────────────────────

  /// Insert or update a merchant rule.
  /// If [accountId] is provided, it is stored alongside the category mapping.
  Future<void> upsert(
    String keyword,
    String categoryId, {
    String? accountId,
  }) async {
    final normalized = keyword.trim().toLowerCase();
    if (normalized.length < 3) return;

    final existing = await getByKeyword(normalized);
    final now = DateTime.now().toIso8601String();
    final db = await _db.database;

    if (existing == null) {
      await db.insert(Tables.merchantRules, {
        'id': const Uuid().v4(),
        'keyword': normalized,
        'category_id': categoryId,
        'account_id': accountId,
        'usage_count': 1,
        'last_used': now,
      });
      debugPrint('🧠 Learned new rule: $normalized → cat:$categoryId acc:$accountId');
      return;
    }

    final updates = <String, dynamic>{
      'category_id': categoryId,
      'usage_count': existing.usageCount + 1,
      'last_used': now,
    };
    // Only overwrite accountId if a new one is explicitly provided
    if (accountId != null) {
      updates['account_id'] = accountId;
    }

    await db.update(
      Tables.merchantRules,
      updates,
      where: 'id = ?',
      whereArgs: [existing.id],
    );
    debugPrint('🧠 Updated rule: $normalized (count: ${existing.usageCount + 1})');
  }

  // ── Delete ──────────────────────────────────────────────────────────

  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.delete(
      Tables.merchantRules,
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
