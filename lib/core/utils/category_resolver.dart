import 'package:sqflite/sqflite.dart' show DatabaseExecutor;
import '../../data/repositories/category_repo.dart';
import '../../features/merchant_rules/data/merchant_rule_repo.dart';
import '../../models/category.dart';
import '../../services/smart_category_classifier.dart';
import '../constants/category_meta.dart';
import 'category_classifier.dart';

/// Resolves the category for a detected transaction. Prefers learned merchant
/// memory (so the same merchant always gets the same category), then static
/// rule-based detection. Returns both the category id and name so callers can
/// both assign and re-learn.
class CategoryResolution {
  final String? id;
  final String? name;
  const CategoryResolution({this.id, this.name});
}

Future<CategoryResolution> resolveCategoryForText({
  required String rawText,
  String? merchant,
  required String type,
  DatabaseExecutor? executor,
}) async {
  final catRepo = CategoryRepo(executor: executor);
  final ruleRepo = MerchantRuleRepo(executor: executor);

  // 1. Merchant memory — learned merchant rule first
  try {
    // 1a. SmartCategoryClassifier memory
    final learned = await SmartCategoryClassifier.instance.checkLearned(
      rawText: rawText,
      merchant: merchant,
    );
    if (learned != null) {
      final cat = await catRepo.getByName(learned, type: type);
      if (cat != null) return CategoryResolution(id: cat.id, name: cat.name);
    }

    // 1b. MerchantRuleRepo keyword match
    final queryText = (merchant ?? '').trim().isNotEmpty ? merchant! : rawText;
    final rule = await ruleRepo.findBestMatch(queryText);
    if (rule != null) {
      final allCats = await catRepo.getAll();
      final cat = allCats.where((c) => c.id == rule.categoryId).firstOrNull;
      if (cat != null) return CategoryResolution(id: cat.id, name: cat.name);
    }
  } catch (_) {}

  // 2. Deterministic merchant / category keyword matching second
  final name = CategoryClassifier.detect(text: merchant ?? rawText, type: type);
  if (name != null) {
    final cat = await catRepo.getByName(name, type: type);
    if (cat != null) return CategoryResolution(id: cat.id, name: cat.name);
  }

  // 3. Fallback: Miscellaneous category
  try {
    var misc = await catRepo.getByName('Miscellaneous', type: type);
    if (misc != null) {
      return CategoryResolution(id: misc.id, name: misc.name);
    }
    // Auto-create Miscellaneous if not present yet
    final newMisc = Category(
      userId: 'default',
      name: 'Miscellaneous',
      icon: CategoryMetaMap.iconKey('Miscellaneous', type),
      color: CategoryMetaMap.colorHex('Miscellaneous', type),
      type: type,
    );
    final id = await catRepo.insert(newMisc);
    return CategoryResolution(id: id, name: 'Miscellaneous');
  } catch (_) {}

  return const CategoryResolution();
}