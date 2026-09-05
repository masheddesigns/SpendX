import '../../data/repositories/category_repo.dart';
import '../../services/smart_category_classifier.dart';
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
}) async {
  try {
    // 1. Merchant memory — consistent category for repeat merchants.
    final learned = await SmartCategoryClassifier.instance.checkLearned(
      rawText: rawText,
      merchant: merchant,
    );
    if (learned != null) {
      final cat = await CategoryRepo().getByName(learned);
      if (cat != null) return CategoryResolution(id: cat.id, name: cat.name);
    }
  } catch (_) {}

  // 2. Static rule-based detection.
  final name = CategoryClassifier.detect(text: merchant ?? rawText, type: type);
  if (name != null) {
    final cat = await CategoryRepo().getByName(name);
    if (cat != null) return CategoryResolution(id: cat.id, name: cat.name);
  }
  return const CategoryResolution();
}