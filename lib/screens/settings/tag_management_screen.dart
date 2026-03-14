import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../models/tag.dart';
import '../../services/database_helper.dart';
import '../../theme/app_theme.dart';
import '../../widgets/custom_dialog.dart';

class TagManagementScreen extends StatefulWidget {
  const TagManagementScreen({super.key});

  @override
  State<TagManagementScreen> createState() => _TagManagementScreenState();
}

class _TagManagementScreenState extends State<TagManagementScreen> {
  List<Tag> _tags = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  Future<void> _loadTags() async {
    setState(() => _isLoading = true);
    final db = await DatabaseHelper.instance.database;
    final maps = await db.query(DatabaseHelper.tableTags, orderBy: 'name');
    if (!mounted) return;
    setState(() {
      _tags = maps.map((m) => Tag.fromMap(m)).toList();
      _isLoading = false;
    });
  }

  void _showAddTagDialog() {
    final nameController = TextEditingController();
    String color = '#4F46E5';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("New Tag"),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(labelText: "Tag Name", prefixIcon: Icon(Icons.tag)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.trim().isEmpty) return;
              final newTag = Tag(
                id: const Uuid().v4(),
                userId: 'offline_user',
                name: nameController.text.trim().toLowerCase(),
                color: color,
              );
              final db = await DatabaseHelper.instance.database;
              await db.insert(DatabaseHelper.tableTags, newTag.toMap());
              if (mounted) {
                Navigator.pop(context);
                _loadTags();
              }
            },
            child: const Text("Save"),
          )
        ],
      ),
    );
  }

  void _deleteTag(Tag tag) async {
    final confirm = await CustomDialog.show(
      context,
      type: DialogType.warning,
      title: 'Delete Tag?',
      message: "Delete '${tag.name}'? This cannot be undone.",
      primaryButtonText: 'Delete',
      secondaryButtonText: 'Cancel',
    );

    if (confirm == true) {
      final db = await DatabaseHelper.instance.database;
      await db.delete(DatabaseHelper.tableTags, where: 'id = ?', whereArgs: [tag.id]);
      _loadTags();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tags'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddTagDialog,
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: const Icon(Icons.add),
      ),
      body: _tags.isEmpty
          ? const Center(child: Text("No tags found.", style: TextStyle(color: Colors.white54)))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _tags.length,
              itemBuilder: (context, index) {
                final tag = _tags[index];
                return ListTile(
                  leading: Icon(Icons.tag, color: Theme.of(context).colorScheme.primary),
                  title: Text(tag.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.white54),
                    onPressed: () => _deleteTag(tag),
                  ),
                );
              },
            ),
    );
  }
}
