import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/providers.dart';
import '../../../shared/widgets/empty_state_widget.dart';
import '../../../widgets/insight_card.dart';

class InsightsSection extends ConsumerWidget {
  const InsightsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insights = ref.watch(insightsProvider);

    if (insights.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: EmptyStateWidget(
            icon: Icons.auto_awesome_outlined,
            title: 'No insights yet',
            description: 'Start tracking to see insights and spending patterns.',
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: InsightCard(insight: insights[index]),
          ),
          childCount: insights.length,
        ),
      ),
    );
  }
}
