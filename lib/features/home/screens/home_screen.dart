import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/haptic_service.dart';
import '../../streak/streak_provider.dart';
import '../../../screens/bank/account_list_screen.dart';
import '../../../screens/expense/add_expense_screen.dart';
import '../../../screens/insights/insights_tab.dart';
import '../../../screens/plan/plan_tab.dart';
import '../../../screens/more/more_screen.dart';
import 'home_dashboard.dart';
import '../../../shared/widgets/app_page_route.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _currentIndex = 0;

  static const _titles = <String>[
    'Home',
    'Accounts',
    'Insights',
    'Plan',
    'More',
  ];

  static const _tabs = <Widget>[
    HomeDashboard(),
    AccountListScreen(isEmbedded: true),
    InsightsTab(),
    PlanTab(),
    MoreScreen(),
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(evaluateStreakProvider.future);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_currentIndex]),
        actions: _buildActions(context),
      ),
      body: _buildBody(),
      floatingActionButton: _buildFab(context),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          HapticService.instance.selection();
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet_rounded),
            label: 'Accounts',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights_rounded),
            label: 'Insights',
          ),
          NavigationDestination(
            icon: Icon(Icons.flag_outlined),
            selectedIcon: Icon(Icons.flag_rounded),
            label: 'Plan',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz_rounded),
            selectedIcon: Icon(Icons.more_horiz),
            label: 'More',
          ),
        ],
      ),
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    // Clean app bar — no SMS buttons (moved to More → SMS Import)
    return const [];
  }

  Widget _buildBody() {
    return IndexedStack(index: _currentIndex, children: _tabs);
  }

  Widget? _buildFab(BuildContext context) {
    switch (_currentIndex) {
      case 0:
        return FloatingActionButton.extended(
          heroTag: 'home_add_transaction_fab',
          onPressed: () async {
            HapticService.instance.tap();
            await Navigator.push(
              context,
              AppPageRoute(
                builder: (_) => const AddExpenseScreen(initialType: 'expense'),
              ),
            );
          },
          icon: const Icon(Icons.add),
          label: const Text('Add Transaction'),
        );
      default:
        return null;
    }
  }
}
