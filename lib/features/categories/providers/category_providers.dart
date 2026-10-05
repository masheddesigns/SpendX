import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart' as app_data;
import '../../../models/category.dart';

/// Single source of truth for CategoryRepo provider — re-exported from data/providers.dart.
final categoryRepoProvider = app_data.categoryRepoProvider;

/// Single source of truth for categoriesProvider — re-exported from data/providers.dart.
/// All invalidations and watches across the entire application converge on this one provider.
final categoriesProvider = app_data.categoriesProvider;

final addCategoryProvider = Provider((ref) {
  return (Category category) async {
    await ref.read(categoriesProvider.notifier).add(category);
  };
});

final updateCategoryProvider = Provider((ref) {
  return (Category category) async {
    await ref.read(categoriesProvider.notifier).replace(category);
  };
});

final deleteCategoryProvider = Provider((ref) {
  return (Category category) async {
    await ref.read(categoriesProvider.notifier).remove(category);
  };
});
