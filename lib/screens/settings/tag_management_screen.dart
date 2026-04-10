import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/providers.dart';
import '../../models/tag.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/undo_snackbar_listener.dart';
import '../../widgets/common/spendx_fab.dart';

class TagManagementScreen extends ConsumerStatefulWidget {
  const TagManagementScreen({super.key});

  @override
  ConsumerState<TagManagementScreen> createState() =>
      _TagManagementScreenState();
}

class _TagManagementScreenState extends ConsumerState<TagManagementScreen> {
  Future<void> _showAddTagDialog([Tag? existing]) async {
    final controller = TextEditingController(text: existing?.name ?? '');

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(existing == null ? 'New Tag' : 'Edit Tag'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Tag Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim().toLowerCase();
              if (name.isEmpty) {
                return;
              }

              final tag = Tag(
                id: existing?.id ?? const Uuid().v4(),
                userId: existing?.userId ?? 'offline_user',
                name: name,
                color: existing?.color ?? '#4F46E5',
              );

              if (existing == null) {
                await ref.read(tagsProvider.notifier).add(tag);
              } else {
                await ref.read(tagsProvider.notifier).replace(tag);
              }

              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    controller.dispose();
  }

  Future<void> _deleteTag(Tag tag) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Tag'),
        content: Text("Delete '${tag.name}'?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(tagsProvider.notifier).remove(tag);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tagsAsync = ref.watch(tagsProvider);

    listenForUndoSnackbars(ref, context, matches: (payload) => payload is Tag);

    return tagsAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => Scaffold(body: Center(child: Text('Error: $error'))),
      data: (tags) {
        final sortedTags = [
          ...tags,
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

        return Scaffold(
          appBar: const SpendXAppBar(title: 'Tags'),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerFloat,
          floatingActionButton: SpendXFAB(
            icon: Icons.add_rounded,
            label: 'Add Tag',
            onPressed: _showAddTagDialog,
          ),
          body: SafeArea(
            child: sortedTags.isEmpty
                ? Center(
                    child: Text(
                      'No tags found.',
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.m,
                      AppSpacing.s,
                      AppSpacing.m,
                      AppSpacing.xxl,
                    ),
                    itemCount: sortedTags.length,
                    itemBuilder: (context, index) {
                      final tag = sortedTags[index];
                      return ListTile(
                        leading: Icon(
                          Icons.tag,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(tag.name),
                        onTap: () => _showAddTagDialog(tag),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteTag(tag),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}
