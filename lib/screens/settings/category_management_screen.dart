import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/category_meta.dart';
import '../../features/categories/providers/category_providers.dart';
import '../../models/category.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/undo_snackbar_listener.dart';
import '../../utils/text_formatter.dart';
import '../../widgets/category_color_picker.dart';
import '../../shared/widgets/error_state_widget.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../../widgets/category_icon_picker.dart';

class CategoryManagementScreen extends ConsumerStatefulWidget {
  const CategoryManagementScreen({super.key});

  @override
  ConsumerState<CategoryManagementScreen> createState() =>
      _CategoryManagementScreenState();
}

class _CategoryManagementScreenState
    extends ConsumerState<CategoryManagementScreen> {
  void _showAddCategoryDialog({Category? existingCategory}) {
    final nameController = TextEditingController(text: existingCategory?.name);
    String type = existingCategory?.type ?? 'expense';
    String icon =
        existingCategory?.icon ?? CategoryMetaMap.iconKey('Food', 'expense');
    String color =
        existingCategory?.color ?? CategoryMetaMap.colorHex('Food', 'expense');

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setDialogState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
              top: 20,
            ),
            child: SingleChildScrollView(
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  existingCategory == null ? 'New Category' : 'Edit Category',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _TypeChip(
                        label: 'Expense',
                        isSelected: type == 'expense',
                        onTap: () => setDialogState(() => type = 'expense'),
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _TypeChip(
                        label: 'Income',
                        isSelected: type == 'income',
                        onTap: () => setDialogState(() => type = 'income'),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: nameController,
                  autofocus: existingCategory == null,
                  decoration: InputDecoration(
                    labelText: 'Category Name',
                    hintText: 'e.g. Groceries',
                    prefixIcon: Container(
                      margin: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _hexToColor(color).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        widthFactor: 1,
                        child: _buildIcon(icon, color, size: 20),
                      ),
                    ),
                  ),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 24),
                CategoryIconPicker(
                  selectedIcon: icon,
                  onIconSelected: (newIcon) =>
                      setDialogState(() => icon = newIcon),
                ),
                const SizedBox(height: 24),
                CategoryColorPicker(
                  selectedColor: color,
                  onColorSelected: (newColor) =>
                      setDialogState(() => color = newColor),
                ),
                const SizedBox(height: 32),
                PrimaryButton(
                  onPressed: () async {
                    if (nameController.text.trim().isEmpty) {
                      return;
                    }

                    final category = Category(
                      id: existingCategory?.id ?? const Uuid().v4(),
                      userId: existingCategory?.userId ?? 'offline_user',
                      name: nameController.text.trim(),
                      icon: icon,
                      color: color,
                      type: type,
                    );

                    if (existingCategory == null) {
                      await ref.read(addCategoryProvider)(category);
                    } else {
                      await ref.read(updateCategoryProvider)(category);
                    }

                    if (sheetContext.mounted) {
                      Navigator.pop(sheetContext);
                    }
                  },
                  label: existingCategory == null
                      ? 'Create Category'
                      : 'Save Changes',
                ),
                if (existingCategory != null &&
                    existingCategory.userId != 'default') ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        _deleteCategory(existingCategory);
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      child: const Text('Delete Category'),
                    ),
                  ),
                ],
              ],
            ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _deleteCategory(Category category) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Category?'),
        content: Text(
          "Delete '${category.name}'? Transactions using this category will be uncategorized.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ref.read(deleteCategoryProvider)(category);
    }
  }

  Widget _buildIcon(String icon, String colorHex, {double size = 24}) {
    final color = _hexToColor(colorHex);
    if (icon.length <= 2) {
      return Text(icon, style: TextStyle(fontSize: size));
    }

    final iconData = switch (icon) {
      'lunch_dining' => Icons.lunch_dining_rounded,
      'restaurant' => Icons.restaurant,
      'receipt_long' => Icons.receipt_long_rounded,
      'directions_car' => Icons.directions_car,
      'local_grocery_store' => Icons.local_grocery_store_rounded,
      'local_gas_station' => Icons.local_gas_station,
      'apartment' => Icons.apartment_rounded,
      'shopping_bag' => Icons.shopping_bag,
      'shopping_cart' => Icons.shopping_cart_rounded,
      'home' => Icons.home,
      'bolt' => Icons.bolt,
      'theaters' => Icons.theaters_rounded,
      'movie' => Icons.movie,
      'school' => Icons.school_rounded,
      'flight_takeoff' => Icons.flight_takeoff_rounded,
      'subscriptions' => Icons.subscriptions_rounded,
      'account_balance_wallet' => Icons.account_balance_wallet_rounded,
      'work' => Icons.work_rounded,
      'business_center' => Icons.business_center_rounded,
      'trending_up' => Icons.trending_up_rounded,
      'card_giftcard' => Icons.card_giftcard_rounded,
      'replay' => Icons.replay_rounded,
      'savings' => Icons.savings_rounded,
      'account_balance' => Icons.account_balance_rounded,
      'local_cafe' => Icons.local_cafe_rounded,
      'medical_services' => Icons.medical_services_rounded,
      'sports_esports' => Icons.sports_esports_rounded,
      'phone_iphone' => Icons.phone_iphone_rounded,
      'wifi' => Icons.wifi_rounded,
      'home_repair_service' => Icons.home_repair_service_rounded,
      'pets' => Icons.pets_rounded,
      'celebration' => Icons.celebration_rounded,
      'payments' => Icons.payments,
      'health_and_safety' => Icons.health_and_safety,
      _ => Icons.category_rounded,
    };
    return Icon(iconData, color: color, size: size);
  }

  Color _hexToColor(String hex) {
    try {
      var normalized = hex.replaceAll('#', '');
      if (normalized.length == 6) {
        normalized = 'FF$normalized';
      }
      return Color(int.parse(normalized, radix: 16));
    } catch (_) {
      return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);

    listenForUndoSnackbars(
      ref,
      context,
      matches: (payload) => payload is Category,
    );

    return categoriesAsync.when(
      loading: () =>
          const Scaffold(body: SkeletonLoader.transactions()),
      error: (error, _) => Scaffold(body: ErrorStateWidget(error: error, onRetry: () => ref.invalidate(categoriesProvider))),
      data: (categories) {
        final sorted = [...categories]
          ..sort((a, b) {
            final typeCompare = a.type.compareTo(b.type);
            if (typeCompare != 0) {
              return typeCompare;
            }
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });

        final List<Category> incomeCategories = sorted
            .where((category) => category.type == 'income')
            .toList();
        final List<Category> expenseCategories = sorted
            .where((category) => category.type == 'expense')
            .toList();

        return Scaffold(
          appBar: AppBar(title: const Text('Categories')),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerFloat,
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add Category'),
            onPressed: () => _showAddCategoryDialog(),
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                _buildCategorySection(
                  'Income',
                  incomeCategories,
                  Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 24),
                _buildCategorySection(
                  'Expense',
                  expenseCategories,
                  Theme.of(context).colorScheme.error,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCategorySection(
    String title,
    List<Category> items,
    Color headerColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: headerColor.withValues(alpha: 0.8),
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No categories found.',
              style: TextStyle(color: Colors.white54),
            ),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 72,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final category = items[index];
              final meta = CategoryMetaMap.resolve(
                category.name,
                category.type,
              );
              final color = meta.color;
              return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () =>
                      _showAddCategoryDialog(existingCategory: category),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Icon(meta.icon, color: color, size: 22),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                category.name,
                                style: Theme.of(context).textTheme.titleSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                TextFormatter.toSmartTitleCase(category.type),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.color,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.2)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? color
                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
            width: 1.5,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? color : Colors.grey,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
