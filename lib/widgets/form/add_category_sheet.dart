import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/category_meta.dart';
import '../../features/categories/providers/category_providers.dart';
import '../../models/category.dart';
import '../../utils/text_formatter.dart';

class AddCategorySheet extends ConsumerStatefulWidget {
  const AddCategorySheet({super.key, required this.initialType});

  final String initialType;

  @override
  ConsumerState<AddCategorySheet> createState() => _AddCategorySheetState();
}

class _AddCategorySheetState extends ConsumerState<AddCategorySheet> {
  final TextEditingController _nameController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = TextFormatter.normalizeName(_nameController.text.trim());
    if (name.isEmpty) return;


    setState(() => _saving = true);
    final category = Category(
      userId: 'offline_user',
      name: name,
      icon: CategoryMetaMap.iconKey(name, widget.initialType),
      color: CategoryMetaMap.colorHex(name, widget.initialType),
      type: widget.initialType,
    );
    await ref.read(addCategoryProvider)(category);
    if (!mounted) return;
    Navigator.pop(context, category);
  }

  @override
  Widget build(BuildContext context) {
    final typedName = TextFormatter.normalizeName(_nameController.text.trim());
    final meta = typedName.isEmpty
        ? CategoryMetaMap.defaultForType(widget.initialType)
        : CategoryMetaMap.resolve(typedName, widget.initialType);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Add Category',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _nameController,
                    onChanged: (_) => setState(() {}),
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: 'Category Name',
                      prefixIcon: Container(
                        margin: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: meta.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(meta.icon, color: meta.color, size: 20),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'Saving...' : 'Save'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
