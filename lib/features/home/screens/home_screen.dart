import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../screens/bank/account_list_screen.dart';
import '../../../screens/expense/add_expense_screen.dart';
import '../../../screens/home/transactions_screen.dart';
import '../../../screens/more/more_screen.dart';
import '../../../screens/plan/plan_tab.dart';
import '../../../services/haptic_service.dart';
import '../../../services/notification_service_v2.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../shared/widgets/spendx_glass.dart';
import '../../../theme/app_theme.dart';
import '../../streak/streak_provider.dart';
import 'home_dashboard.dart';

/// SpendX 2.0 Primary Navigation Shell with Liquid Glass Navigation Bar.
///
/// Primary Workflows (LOCKED):
/// 1. Home — Decision Center
/// 2. Activity — Transaction Ledger
/// 3. Accounts — Financial Position
/// 4. Planning — Budgets, Goals, Recurring
/// 5. More — Intelligence & System
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _currentIndex = 0;

  static const _titles = <String>[
    'SpendX',
    'Activity',
    'Accounts',
    'Planning',
    'More',
  ];

  static const _tabs = <Widget>[
    HomeDashboard(),
    TransactionListScreen(isFullScreen: false),
    AccountListScreen(isEmbedded: true),
    PlanTab(embedded: true),
    MoreScreen(),
  ];

  static const _navItems = <SpendXNavItem>[
    SpendXNavItem(
      icon: Icons.dashboard_outlined,
      activeIcon: Icons.dashboard_rounded,
      label: 'Home',
    ),
    SpendXNavItem(
      icon: Icons.receipt_long_outlined,
      activeIcon: Icons.receipt_long_rounded,
      label: 'Activity',
    ),
    SpendXNavItem(
      icon: Icons.account_balance_wallet_outlined,
      activeIcon: Icons.account_balance_wallet_rounded,
      label: 'Accounts',
    ),
    SpendXNavItem(
      icon: Icons.calendar_today_outlined,
      activeIcon: Icons.calendar_today_rounded,
      label: 'Planning',
    ),
    SpendXNavItem(
      icon: Icons.tune_outlined,
      activeIcon: Icons.tune_rounded,
      label: 'More',
    ),
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(evaluateStreakProvider.future);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationServiceV2().checkAndRoutePendingLaunchNotification();
    });
  }

  void _onTabSelected(int index) {
    if (_currentIndex != index) {
      HapticService.instance.selection();
      setState(() => _currentIndex = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Android-correct back navigation:
    // If not on Home tab (0), navigating back returns to Home first.
    return PopScope(
      canPop: _currentIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _currentIndex != 0) {
          setState(() => _currentIndex = 0);
        }
      },
      child: SpendXScaffold(
        extendBody: true,
        extendBodyBehindAppBar: false,
        appBar: _currentIndex == 0
            ? null
            : AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                title: Text(
                  _titles[_currentIndex],
                  style: AppTextStyles.heading.copyWith(
                    color: context.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                actions: [
                  if (_currentIndex == 1)
                    IconButton(
                      icon: const Icon(Icons.search_rounded),
                      tooltip: 'Search Transactions',
                      onPressed: () => Navigator.push(
                        context,
                        AppPageRoute(
                          builder: (_) =>
                              const TransactionListScreen(isFullScreen: true),
                        ),
                      ),
                    ),
                ],
              ),
        body: IndexedStack(index: _currentIndex, children: _tabs),
        floatingActionButton: Semantics(
          button: true,
          label: 'Add Transaction',
          child: FloatingActionButton(
            heroTag: 'spendx_primary_fab',
            elevation: 4,
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
            tooltip: 'Add Transaction',
            onPressed: () {
              HapticService.instance.medium();
              Navigator.push(
                context,
                AppPageRoute(
                  builder: (_) =>
                      const AddExpenseScreen(initialType: 'expense'),
                ),
              );
            },
            child: const Icon(Icons.add_rounded, size: 28),
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        bottomNavigationBar: SpendXGlassNavigation(
          selectedIndex: _currentIndex,
          onItemSelected: _onTabSelected,
          items: _navItems,
        ),
      ),
    );
  }
}
