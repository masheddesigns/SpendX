import 'package:flutter/material.dart';

import '../../core/config/app_env.dart';
import '../../services/dev_tools_service.dart';
import '../../widgets/custom_snackbar.dart';
import 'retention_metrics_screen.dart';

class DebugHubScreen extends StatefulWidget {
  const DebugHubScreen({super.key});

  @override
  State<DebugHubScreen> createState() => _DebugHubScreenState();
}

class _DebugHubScreenState extends State<DebugHubScreen> {
  bool _isWorking = false;
  final _devTools = DevToolsService.instance;

  Future<void> _run(
    Future<void> Function() action, {
    required String successMessage,
    required String failureLabel,
  }) async {
    if (_isWorking) return;
    setState(() => _isWorking = true);
    try {
      await action();
      if (!mounted) return;
      CustomSnackBar.show(context, message: successMessage);
    } catch (e) {
      if (!mounted) return;
      CustomSnackBar.show(
        context,
        message: '$failureLabel failed: $e',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _isWorking = false);
      }
    }
  }

  Future<void> _seedScenario(String scenario) async {
    await _run(
      () => _devTools.seedDummyData(scenario: scenario),
      successMessage: 'Dummy data generated',
      failureLabel: 'Seed',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AppEnv.isDebug) {
      return const Scaffold(
        body: Center(child: Text('Debug not available')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Debug Hub')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _sectionTitle('Data'),
          ListTile(
            title: const Text('Seed Dummy Data'),
            subtitle: const Text('Generate the mixed baseline scenario'),
            enabled: !_isWorking,
            onTap: () => _seedScenario('mixed'),
          ),
          ListTile(
            title: const Text('Seed Stress Scenario'),
            subtitle: const Text('Generate 2 years of heavy test data'),
            enabled: !_isWorking,
            onTap: () => _seedScenario('stress'),
          ),
          ListTile(
            title: const Text('Clear All Data'),
            enabled: !_isWorking,
            onTap: () => _run(
              _devTools.clearAll,
              successMessage: 'All data cleared',
              failureLabel: 'Clear all',
            ),
          ),
          _sectionTitle('Stress Tests'),
          ListTile(
            title: const Text('Stress Test: Expenses'),
            enabled: !_isWorking,
            onTap: () => _run(
              () => _devTools.stressTestExpenses(count: 500),
              successMessage: 'Expense stress test complete',
              failureLabel: 'Expense stress test',
            ),
          ),
          ListTile(
            title: const Text('Stress Test: Credit'),
            enabled: !_isWorking,
            onTap: () => _run(
              () => _devTools.stressTestCredit(count: 200),
              successMessage: 'Credit stress test complete',
              failureLabel: 'Credit stress test',
            ),
          ),
          ListTile(
            title: const Text('Stress Test: Loans'),
            enabled: !_isWorking,
            onTap: () => _run(
              () => _devTools.stressTestLoans(count: 10),
              successMessage: 'Loan stress test complete',
              failureLabel: 'Loan stress test',
            ),
          ),
          ListTile(
            title: const Text('Stress Test: Lending'),
            enabled: !_isWorking,
            onTap: () => _run(
              () => _devTools.stressTestLending(count: 50),
              successMessage: 'Lending stress test complete',
              failureLabel: 'Lending stress test',
            ),
          ),
          _sectionTitle('Observation'),
          ListTile(
            leading: const Icon(Icons.show_chart),
            title: const Text('Retention Metrics'),
            subtitle: const Text('Today + last 7 days · CTA / completion / open rates'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const RetentionMetricsScreen()),
              );
            },
          ),
          _sectionTitle('System'),
          ListTile(
            title: const Text('Print DB State'),
            subtitle: const Text('Reserved for follow-up diagnostics'),
            enabled: false,
          ),
          ListTile(
            title: const Text('Force Sync'),
            subtitle: const Text('Reserved for follow-up diagnostics'),
            enabled: false,
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
    );
  }
}
