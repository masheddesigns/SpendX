import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/category_repo.dart';
import '../../../models/category.dart';

final categoryRepoProvider = Provider<CategoryRepo>((ref) => CategoryRepo());

final categoriesProvider = FutureProvider<List<Category>>((ref) {
  return ref.watch(categoryRepoProvider).getAll().then((data) {
    debugPrint('📂 Categories fetched: ${data.length}');
    return data;
  });
});

final addCategoryProvider = Provider((ref) {
  return (Category category) async {
    await ref.read(categoryRepoProvider).create(category);
    ref.invalidate(categoriesProvider);
  };
});

final updateCategoryProvider = Provider((ref) {
  return (Category category) async {
    await ref.read(categoryRepoProvider).update(category);
    ref.invalidate(categoriesProvider);
  };
});

final deleteCategoryProvider = Provider((ref) {
  return (Category category) async {
    await ref.read(categoryRepoProvider).delete(category.id);
    ref.invalidate(categoriesProvider);
  };
});
