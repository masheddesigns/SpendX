import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/app_spacing.dart';
import '../credit_card_screen.dart';
import '../loans/loans_screen.dart';
import '../../utils/app_format.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';

class LiabilitiesHubScreen extends ConsumerStatefulWidget {
  const LiabilitiesHubScreen({super.key});

  @override
  ConsumerState<LiabilitiesHubScreen> createState() =>
      _LiabilitiesHubScreenState();
}

class _LiabilitiesHubScreenState extends ConsumerState<LiabilitiesHubScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(liabilitiesSummaryProvider);

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(
          240,
        ), // Enough height for summary card + tab bar
        child: Column(
          children: [
            summaryAsync.when(
              loading: () => const SizedBox(
                height: 100,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (err, _) => SizedBox(
                height: 100,
                child: Center(child: Text('Error: $err')),
              ),
              data: (summary) => _buildSummaryCard(summary),
            ),
            SafeArea(
              child: TabBar(
                controller: _tabController,
                indicatorColor: Theme.of(context).colorScheme.primary,
                indicatorWeight: 3,
                labelColor: Theme.of(context).colorScheme.primary,
                unselectedLabelColor: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
                tabs: const [
                  Tab(text: 'Credit Cards'),
                  Tab(text: 'Bank Loans'),
                ],
              ),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [CreditCardScreen(), LoansScreen()],
      ),
    );
  }

  Widget _buildSummaryCard(LiabilitiesSummary summary) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.error.withValues(alpha: 0.8), cs.error],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: cs.error.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Total Liabilities',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              AppFormat.currency(summary.totalLiabilities),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildMiniStat('Cards', summary.totalCreditOutstanding),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(width: 1, height: 24, child: ColoredBox(color: Colors.white24)),
              ),
              _buildMiniStat('Loans', summary.totalLoanOutstanding),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniStat(String label, double amount) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              AppFormat.currency(amount),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
