import 'package:flutter/material.dart';
import '../services/insights_activity_service.dart';

class InsightsActivityScreen extends StatefulWidget {
  const InsightsActivityScreen({super.key});

  @override
  State<InsightsActivityScreen> createState() => _InsightsActivityScreenState();
}

class _InsightsActivityScreenState extends State<InsightsActivityScreen> {
  // Single source of truth — drives the entire UI. No boolean flags.
  String _status = 'loading';
  double _monthlySpend = 0.0;
  List<ActivitySnippet> _activity = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _status = 'loading');

    try {
      final data = await InsightsActivityService.instance.getMonthlyForecast();

      if (!mounted) return;
      setState(() {
        _status = data['status'] as String? ?? 'error';
        _monthlySpend = (data['monthlySpend'] as num?)?.toDouble() ?? 0.0;
        _activity = List<ActivitySnippet>.from(data['activity'] as List? ?? []);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Intelligence Hub'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _loadData,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_status) {
      case 'loading':
        return const Center(child: CircularProgressIndicator());

      case 'error':
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              const Text('Unable to load data', style: TextStyle(fontSize: 16)),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _loadData,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        );

      case 'empty':
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.analytics_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              const Text(
                'No data yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text(
                'Start adding transactions to activate the hub',
                style: TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );

      case 'data':
      default:
        return _buildDataView();
    }
  }

  Widget _buildDataView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildMetricCard(
          title: 'Monthly Spend',
          value: _monthlySpend,
          icon: Icons.trending_up_rounded,
          color: Colors.deepOrange,
        ),
        const SizedBox(height: 24),
        if (_activity.isNotEmpty) ...[
          const Text(
            'Activity',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          ..._activity.map(_buildActivityItem),
        ],
        const SizedBox(height: 24),
        _buildSystemFidelityBadge(),
      ],
    );
  }

  /// Safe: uses double.infinity only at top-level container (not inside Row).
  Widget _buildMetricCard({
    required String title,
    required double value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '₹${value.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityItem(ActivitySnippet snippet) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.circle, size: 8, color: Colors.green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snippet.title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  snippet.subtitle,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemFidelityBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: const [
          Icon(Icons.shield_outlined, size: 16, color: Colors.green),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'SYSTEM FIDELITY',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          Text(
            'STABLE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.green,
            ),
          ),
        ],
      ),
    );
  }
}
