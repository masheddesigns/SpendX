import 'package:flutter/foundation.dart' show debugPrint;

import '../../merchant_rules/data/merchant_rule_repo.dart';

/// Learns from user corrections to improve future parsing.
///
/// When a user edits a transaction's merchant or category in the review queue
/// (or any transaction edit), the system records the mapping:
///   raw_merchant → corrected_merchant + categoryId
///
/// Next time the same raw merchant appears, the system suggests the
/// learned correction automatically.
///
/// This is how apps like CRED feel "magically accurate" — they remember.
class MerchantLearningService {
  MerchantLearningService._();
  static final instance = MerchantLearningService._();

  final _repo = MerchantRuleRepo();

  /// Record a user correction.
  /// Call this when user approves a review item or edits a transaction.
  Future<void> learn({
    required String rawMerchant,
    String? categoryId,
    String? accountId,
  }) async {
    if (rawMerchant.trim().length < 3) return;

    final keyword = rawMerchant.trim().toLowerCase();

    try {
      await _repo.upsert(
        keyword,
        categoryId ?? '',
        accountId: accountId,
      );
      debugPrint(
          '\u{1F9E0} Learned: "$keyword" → category=$categoryId');
    } catch (e) {
      debugPrint('\u26A0\uFE0F Learning failed: $e');
    }
  }

  /// Lookup a learned category for a merchant.
  /// Returns categoryId if a rule exists, null otherwise.
  Future<String?> suggestCategory(String merchant) async {
    if (merchant.trim().length < 3) return null;

    try {
      final keyword = merchant.trim().toLowerCase();
      final rule = await _repo.resolve(keyword: keyword, fullText: keyword);
      return rule?.categoryId;
    } catch (_) {
      return null;
    }
  }

  /// Lookup a learned account for a merchant.
  Future<String?> suggestAccount(String merchant) async {
    if (merchant.trim().length < 3) return null;

    try {
      final keyword = merchant.trim().toLowerCase();
      final rule = await _repo.resolve(keyword: keyword, fullText: keyword);
      return rule?.accountId;
    } catch (_) {
      return null;
    }
  }

  /// Get all learned rules (for debug/export).
  Future<List<Map<String, dynamic>>> getAllRules() async {
    try {
      final rules = await _repo.getAll();
      return rules
          .map((r) => {
                'keyword': r.keyword,
                'categoryId': r.categoryId,
                'accountId': r.accountId,
                'usageCount': r.usageCount,
              })
          .toList();
    } catch (_) {
      return [];
    }
  }
}
