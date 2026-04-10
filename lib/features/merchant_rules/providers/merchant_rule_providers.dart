import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/merchant_extractor.dart';
import '../data/merchant_rule_repo.dart';

final merchantRuleRepoProvider = Provider<MerchantRuleRepo>(
  (ref) => MerchantRuleRepo(),
);

/// All stored merchant rules (for UI display / management).
final merchantRulesProvider = FutureProvider<List<MerchantRule>>((ref) {
  return ref.watch(merchantRuleRepoProvider).getAll();
});

/// Learn a merchant→category+account mapping from user action.
/// Called when:
///   - user manually categorizes a transaction
///   - user approves a review queue item with explicit category/account
final learnMerchantRuleProvider = Provider((ref) {
  return ({
    required String text,
    required String categoryId,
    String? accountId,
  }) async {
    final keyword = MerchantExtractor.extract(text);
    if (keyword.length < 3) return;

    try {
      await ref.read(merchantRuleRepoProvider).upsert(
        keyword,
        categoryId,
        accountId: accountId,
      );
    } catch (e) {
      debugPrint('🧠 Merchant learning failed: $e');
      // Learning should never block the calling operation.
    }
  };
});

/// Delete a single merchant rule.
final deleteMerchantRuleProvider = Provider((ref) {
  return (String id) async {
    await ref.read(merchantRuleRepoProvider).delete(id);
    ref.invalidate(merchantRulesProvider);
  };
});
