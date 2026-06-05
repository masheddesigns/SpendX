import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../shared/widgets/skeleton_loader.dart';
import '../shared/widgets/empty_state_widget.dart';
import '../utils/app_format.dart';

class NotificationsInboxScreen extends ConsumerStatefulWidget {
  const NotificationsInboxScreen({super.key});

  @override
  ConsumerState<NotificationsInboxScreen> createState() =>
      _NotificationsInboxScreenState();
}

class _NotificationsInboxScreenState
    extends ConsumerState<NotificationsInboxScreen> {
  bool _isLoading = true;
  List<_NotificationItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final cards = await ref.read(cardsProvider.future);
    final items = cards
        .map(
          (card) => _NotificationItem(
            title: '${card.bank} card due',
            subtitle:
                '${card.daysUntilDue} days left • ${AppFormat.currency(card.outstanding)} outstanding',
          ),
        )
        .toList();
    if (!mounted) return;
    setState(() {
      _items = items;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _isLoading
          ? const SkeletonLoader.transactions()
          : _items.isEmpty
          ? const EmptyStateWidget(
              icon: Icons.notifications_off_outlined,
              title: 'No alerts right now',
              description: 'You\'re all caught up. Alerts will appear here when actions are needed.',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemBuilder: (context, index) {
                final item = _items[index];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.notifications_none_rounded),
                    title: Text(item.title),
                    subtitle: Text(item.subtitle),
                  ),
                );
              },
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemCount: _items.length,
            ),
    );
  }
}

class _NotificationItem {
  const _NotificationItem({required this.title, required this.subtitle});

  final String title;
  final String subtitle;
}
