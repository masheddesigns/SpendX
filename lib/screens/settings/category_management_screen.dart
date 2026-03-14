import 'package:flutter/material.dart';
import '../../models/category.dart';
import '../../services/database_helper.dart';
import '../../theme/app_theme.dart';
import '../../widgets/custom_dialog.dart';
import '../../widgets/category_icon_picker.dart';
import '../../widgets/category_color_picker.dart';
import 'package:uuid/uuid.dart';

class CategoryManagementScreen extends StatefulWidget {
  const CategoryManagementScreen({super.key});

  @override
  State<CategoryManagementScreen> createState() => _CategoryManagementScreenState();
}

class _CategoryManagementScreenState extends State<CategoryManagementScreen> {
  List<Category> _categories = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    setState(() => _isLoading = true);
    final db = await DatabaseHelper.instance.database;
    final maps = await db.query(
      DatabaseHelper.tableCategories,
      orderBy: 'type, name',
    );
    
    if (!mounted) return;
    
    setState(() {
      _categories = maps.map((m) => Category.fromMap(m)).toList();
      _isLoading = false;
    });
  }

  void _showAddCategoryDialog({Category? existingCategory}) {
    final nameController = TextEditingController(text: existingCategory?.name);
    String type = existingCategory?.type ?? 'expense';
    String icon = existingCategory?.icon ?? '🍔';
    String color = existingCategory?.color ?? '#22C55E';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 24, right: 24, bottom: MediaQuery.of(context).viewInsets.bottom + 24, top: 20
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  existingCategory == null ? "New Category" : "Edit Category",
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 24),
                
                // Type Selector
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
                    labelText: "Category Name",
                    hintText: "e.g. Groceries",
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
                  onIconSelected: (newIcon) => setDialogState(() => icon = newIcon),
                ),
                const SizedBox(height: 24),

                CategoryColorPicker(
                  selectedColor: color,
                  onColorSelected: (newColor) => setDialogState(() => color = newColor),
                ),
                const SizedBox(height: 32),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (nameController.text.trim().isEmpty) return;
                      
                      final cat = Category(
                        id: existingCategory?.id ?? const Uuid().v4(),
                        userId: existingCategory?.userId ?? 'offline_user',
                        name: nameController.text.trim(),
                        icon: icon,
                        color: color,
                        type: type,
                      );
                      
                      final db = await DatabaseHelper.instance.database;
                      if (existingCategory == null) {
                        await db.insert(DatabaseHelper.tableCategories, cat.toMap());
                      } else {
                        await db.update(
                          DatabaseHelper.tableCategories, 
                          cat.toMap(),
                          where: 'id = ?',
                          whereArgs: [cat.id],
                        );
                      }
                      
                      if (mounted) {
                        Navigator.pop(context);
                        _loadCategories();
                      }
                    },
                    child: Text(existingCategory == null ? "Create Category" : "Save Changes"),
                  ),
                ),
                if (existingCategory != null && existingCategory.userId != 'default') ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _deleteCategory(existingCategory);
                      },
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                      child: const Text("Delete Category"),
                    ),
                  ),
                ],
              ],
            ),
          );
        }
      ),
    );
  }

  void _deleteCategory(Category category) async {
    final confirm = await CustomDialog.show(
      context,
      type: DialogType.warning,
      title: 'Delete Category?',
      message: "Delete '${category.name}'? Transactions using this category will be uncategorized.",
      primaryButtonText: 'Delete',
      secondaryButtonText: 'Cancel',
    );

    if (confirm == true) {
      final db = await DatabaseHelper.instance.database;
      await db.delete(
        DatabaseHelper.tableCategories,
        where: 'id = ?',
        whereArgs: [category.id],
      );
      _loadCategories();
    }
  }

  Widget _buildIcon(String icon, String colorHex, {double size = 24}) {
    final color = _hexToColor(colorHex);
    // Check if icon is an emoji (simple check)
    if (icon.length <= 2) {
      return Text(icon, style: TextStyle(fontSize: size));
    }
    
    // Default Material Icons
    IconData iconData;
    switch (icon) {
      case 'restaurant': iconData = Icons.restaurant; break;
      case 'directions_car': iconData = Icons.directions_car; break;
      case 'local_gas_station': iconData = Icons.local_gas_station; break;
      case 'shopping_bag': iconData = Icons.shopping_bag; break;
      case 'home': iconData = Icons.home; break;
      case 'bolt': iconData = Icons.bolt; break;
      case 'movie': iconData = Icons.movie; break;
      case 'payments': iconData = Icons.payments; break;
      case 'health_and_safety': iconData = Icons.health_and_safety; break;
      default: iconData = Icons.category;
    }
    return Icon(iconData, color: color, size: size);
  }

  Color _hexToColor(String hex) {
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) {
        hex = 'FF$hex';
      }
      return Color(int.parse(hex, radix: 16));
    } catch (_) {
      return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final incomeCategories = _categories.where((c) => c.type == 'income').toList();
    final expenseCategories = _categories.where((c) => c.type == 'expense').toList();

    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Categories',
        showLogo: false,
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddCategoryDialog(),
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _buildCategorySection('Income', incomeCategories, Theme.of(context).colorScheme.primary),
          const SizedBox(height: 24),
          _buildCategorySection('Expense', expenseCategories, Theme.of(context).colorScheme.error),
        ],
      ),
    );
  }

  Widget _buildCategorySection(String title, List<Category> items, Color headerColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title, 
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: headerColor.withValues(alpha: 0.8), letterSpacing: 1),
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16.0),
            child: Text("No categories found.", style: TextStyle(color: Colors.white54)),
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
              final cat = items[index];
              final color = _hexToColor(cat.color);
              return InkWell(
                onTap: () => _showAddCategoryDialog(existingCategory: cat),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: color.withValues(alpha: 0.1), width: 1),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Center(child: _buildIcon(cat.icon, cat.color)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              cat.name,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              cat.type[0].toUpperCase() + cat.type.substring(1),
                              style: TextStyle(fontSize: 9, color: Colors.grey, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ],
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
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final Color color;

  const _TypeChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.2) : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
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
