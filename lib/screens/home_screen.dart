import 'package:flutter/material.dart';
import '../widgets/custom_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';
import '../widgets/custom_snackbar.dart';
import 'package:image_picker/image_picker.dart'; // Added
import '../services/transaction_service.dart';
import '../models/transaction.dart' as spx; // Modified to use alias
import '../models/category.dart';
import '../services/database_helper.dart';
import '../theme/app_theme.dart';
import '../widgets/balance_card.dart';
import '../widgets/net_worth_card.dart';
import '../widgets/transaction_tile.dart';
import '../widgets/dashboard_analytics_section.dart';
import '../widgets/streak_card.dart';
import '../services/export_service.dart';
import 'expense/add_expense_screen.dart';
import 'home/transactions_screen.dart';
import 'vehicles/add_fuel_screen.dart';
import 'home/search_filter_screen.dart';
import 'settings/profile_settings_screen.dart';
import 'vehicles_screen.dart';
import 'lending/lending_screen.dart';
import 'credit_card_screen.dart';
import '../services/gemini_service.dart';
import 'profile_hub_screen.dart';
import '../services/recurring_engine.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import 'notifications_inbox_screen.dart';
import 'reports_screen.dart';
import 'import_screen.dart';
import '../main.dart';
import '../widgets/app_button.dart';
import '../widgets/spendx_app_bar.dart';

import '../widgets/empty_state.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  List<spx.Transaction> transactions = []; // Changed to spx.Transaction
  Map<String, Category> categoriesMap = {};
  List<dynamic> bankAccounts = []; // Will hold BankAccount objects
  bool isLoading = true;
  String _selectedPeriod = '1m'; // Default to 1 month
  double _periodIncome = 0;
  double _periodExpense = 0;
  double _periodBalance = 0;

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    // Wait for main.dart deferred init if not done
    if (appInitFuture != null) {
      await appInitFuture;
    }
    await _loadTransactions();
    // Run recurring evaluation in background
    RecurringEngine.checkAndGenerate().then((_) => _loadTransactions());
  }

  Future<void> _loadTransactions() async {
    setState(() => isLoading = true);
    
    try {
      // 1. Get Summary Totals (Period based)
      DateTime? startDate;
      final now = DateTime.now();
      if (_selectedPeriod == '1m') startDate = DateTime(now.year, now.month - 1, now.day);
      else if (_selectedPeriod == '3m') startDate = DateTime(now.year, now.month - 3, now.day);
      else if (_selectedPeriod == '6m') startDate = DateTime(now.year, now.month - 6, now.day);
      else if (_selectedPeriod == '1y') startDate = DateTime(now.year - 1, now.month, now.day);
      
      final summary = await DatabaseHelper.instance.getBalanceSummary(
        startDate?.toIso8601String(), 
        null
      );

      // 2. Fetch Recent Transactions (Limit to 10 for performance)
      final fetchedTransactions = await TransactionService.instance.getTransactions(limit: 10);

      Map<String, Category> fetchedCategories = {};
      List<dynamic> fetchedAccounts = [];
      if (!kIsWeb) {
        final db = await DatabaseHelper.instance.database;
        final catMaps = await db.query(DatabaseHelper.tableCategories);
        fetchedCategories = { for (var item in catMaps) item['id'] as String : Category.fromMap(item) };
        fetchedAccounts = await DatabaseHelper.instance.getAllBankAccounts();
      }

      if (!mounted) return;
      setState(() {
        transactions = fetchedTransactions;
        categoriesMap = fetchedCategories;
        bankAccounts = fetchedAccounts;
        _periodIncome = summary['income']!;
        _periodExpense = summary['expense']!;
        _periodBalance = summary['balance']!;
        isLoading = false;
      });
    } catch (e) {
      debugPrint('_loadTransactions error: $e');
      if (mounted) setState(() => isLoading = false);
    }
  }

  // ================= CALCULATIONS =================

  double get totalBalance => _periodBalance;
  double get totalIncome => _periodIncome;
  double get totalExpense => _periodExpense;

  // ================= ACTIONS =================
  
  void _navigateToAddExpense() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const AddExpenseScreen(initialType: 'expense'),
      ),
    );
    if (result == true) {
      _loadTransactions();
    }
  }

  void _navigateToAddIncome() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const AddExpenseScreen(initialType: 'income'),
      ),
    );
    if (result == true) {
      _loadTransactions();
    }
  }

  Future<void> _scanScreenshot() async {
    final picker = ImagePicker();
    
    final choice = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 16),
        Text('Scan Receipt/Bill', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 8),
        ListTile(
          leading: Icon(Icons.camera_alt, color: Theme.of(context).colorScheme.primary),
          title: const Text('Take Photo'),
          onTap: () => Navigator.pop(context, ImageSource.camera),
        ),
        ListTile(
          leading: Icon(Icons.photo_library, color: Theme.of(context).colorScheme.secondary),
          title: const Text('Choose from Gallery'),
          onTap: () => Navigator.pop(context, ImageSource.gallery),
        ),
        const SizedBox(height: 16),
      ]),
    );

    if (choice == null) return;

    final pickedFile = await picker.pickImage(source: choice, imageQuality: 80);
    
    if (pickedFile == null) return;
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('AI scanning receipt...', style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ),
    );

    final file = File(pickedFile.path);
    final extractedData = await GeminiService.instance.scanReceipt(file);
    
    if (!mounted) return;
    Navigator.pop(context); // Dismiss loading dialog

    if (extractedData.containsKey('error')) {
      CustomSnackBar.show(context, message: 'Failed to parse: ${extractedData['error']}', isError: true);
      return;
    }

    final category = extractedData['category']?.toLowerCase() ?? '';
    
    if (category == 'fuel') {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AddFuelScreen(
            prefillData: extractedData,
          ),
        ),
      );
      if (result == true) _loadTransactions();
    } else {
      // pre-fill the add expense screen
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AddExpenseScreen(
            initialType: 'expense',
            prefillData: extractedData,
          ),
        ),
      );
      if (result == true) _loadTransactions();
    }
  }

  void _deleteTransaction(String id) async {
    final confirm = await CustomDialog.show(
      context,
      type: DialogType.warning,
      title: 'Delete Transaction?',
      message: 'This action cannot be undone.',
      primaryButtonText: 'Delete',
      secondaryButtonText: 'Cancel',
    );

    if (confirm == true) {
      await TransactionService.instance.deleteTransaction(id);
      _loadTransactions();
    }
  }

  void _handleTransactionTap(spx.Transaction t) {
    showModalBottomSheet(
      context: context,
      builder: (_) => Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (t.source == 'manual')
              ListTile(
                leading: Icon(Icons.edit, color: Theme.of(context).colorScheme.primary),
                title: const Text('Edit Transaction'),
                onTap: () async {
                  Navigator.pop(context);
                  final result = await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AddExpenseScreen(
                        initialType: t.type,
                        existingTransaction: t,
                      ),
                    ),
                  );
                  if (result == true) _loadTransactions();
                },
              ),
            if (t.source == 'manual')
              ListTile(
                leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
                title: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteTransaction(t.id);
                },
              ),
            if (t.source == 'vehicle')
              ListTile(
                leading: Icon(Icons.edit, color: Theme.of(context).colorScheme.secondary),
                title: const Text('Edit Fuel Log'),
                subtitle: const Text('Managed by Vehicle Module'),
                onTap: () async {
                  Navigator.pop(context);
                  if (t.relatedEntityId != null) {
                    final log = await DatabaseHelper.instance.getFuelLogById(t.relatedEntityId!);
                    if (log != null && mounted) {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => AddFuelScreen(existingLog: log)),
                      );
                      if (result == true) _loadTransactions();
                    }
                  }
                },
              ),
            if (t.source != 'manual' && t.source != 'vehicle')
              ListTile(
                leading: Icon(Icons.info_outline, color: Theme.of(context).colorScheme.secondary),
                title: Text('Managed by ${t.source}'),
                subtitle: const Text('Please edit or delete this entry from its respective module.'),
                onTap: () => Navigator.pop(context),
              )
          ],
        ),
      ),
    );
  }

  // ================= BUILD =================

  Widget _buildQuickAction(String title, IconData icon, VoidCallback onTap, Color color) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboard() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    
    final settings = Provider.of<SettingsService>(context);
    int vehiclesIdx = 1; // 0=Home, 1=Vehicles (if enabled)
    int creditIdx = vehiclesIdx + (settings.enableVehicles ? 1 : 0);

    final recentTransactions = transactions.take(10).toList();

    final cs = Theme.of(context).colorScheme;

    return RefreshIndicator(
      onRefresh: _loadTransactions,
      color: cs.primary,
      backgroundColor: cs.surface,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // Add Streak Gamification
          const StreakCard(),

          // 0. Net Worth Card
          NetWorthCard(key: ValueKey(transactions.length + bankAccounts.length)),

          // 1. Balance Card
          BalanceCard(
            totalBalance: totalBalance,
            totalIncome: totalIncome,
            totalExpense: totalExpense,
            currentPeriod: _selectedPeriod,
            onPeriodChanged: (period) {
              setState(() => _selectedPeriod = period);
              _loadTransactions();
            },
          ),
          const SizedBox(height: 24),

          // 2. Quick Actions
          Text("Quick Actions", style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Expanded(child: _buildQuickAction("Expense", Icons.remove_circle_outline, _navigateToAddExpense, Theme.of(context).colorScheme.error)),
              Expanded(child: _buildQuickAction("Income", Icons.add_circle_outline, _navigateToAddIncome, Theme.of(context).colorScheme.primary)),
              Expanded(child: _buildQuickAction("Scan Bill", Icons.document_scanner, _scanScreenshot, Theme.of(context).colorScheme.tertiary)),
              if (settings.enableVehicles) 
                Expanded(child: _buildQuickAction("Fuel", Icons.local_gas_station, () => setState(() => _currentIndex = vehiclesIdx), Theme.of(context).colorScheme.secondary)),
              if (settings.enableLending) 
                Expanded(child: _buildQuickAction("Lend", Icons.handshake, () {
                  // Calculate the lending tab index dynamically
                  int lendIdx = 1; // 0 is Home
                  if (settings.enableVehicles) lendIdx++;
                  if (settings.enableCreditCards) lendIdx++;
                  // The actual index in the items list
                  setState(() => _currentIndex = lendIdx);
                }, Theme.of(context).colorScheme.primary)),
            ],
          ),
          const SizedBox(height: 24),

          // 3. Analytics: Budgets + Charts
          const DashboardAnalyticsSection(),

          // 4. Recent Transactions
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("Recent Transactions", style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface)),
              GestureDetector(
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const TransactionListScreen(isFullScreen: true)));
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    "See All",
                    style: TextStyle(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          if (recentTransactions.isEmpty)
            EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              title: "No transactions yet",
              description: "Start adding transactions to track your spending.",
              buttonText: "+ Add Transaction",
              onButtonPressed: _navigateToAddExpense,
            )
          else
            ...recentTransactions.map((t) => Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: TransactionTile(
                transaction: t,
                category: categoriesMap[t.categoryId],
                onTap: () => _handleTransactionTap(t),
              ),
            )),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.search), 
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchFilterScreen()));
            }
          ),
          IconButton(
            icon: const Icon(Icons.notifications_none),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsInboxScreen())),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            onSelected: (value) {
              if (value == 'export_csv') {
                ExportService.instance.exportTransactionsToCsv();
              } else if (value == 'export_json') {
                ExportService.instance.exportTransactionsToJson();
              } else if (value == 'reports') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ReportsScreen()));
              } else if (value == 'import') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ImportScreen()));
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'reports',
                child: Row(
                  children: [
                    Icon(Icons.bar_chart, size: 20),
                    SizedBox(width: 8),
                    Text('Financial Reports'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'import',
                child: Row(
                  children: [
                    Icon(Icons.upload_file, size: 20),
                    SizedBox(width: 8),
                    Text('Import Statement'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'export_csv',
                child: Row(
                  children: [
                    Icon(Icons.table_view, size: 20),
                    SizedBox(width: 8),
                    Text('Export as CSV'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'export_json',
                child: Row(
                  children: [
                    Icon(Icons.data_object, size: 20),
                    SizedBox(width: 8),
                    Text('Export as JSON'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      bottomNavigationBar: Consumer<SettingsService>(
        builder: (context, settings, _) {
          final items = <BottomNavigationBarItem>[
            const BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Home'),
          ];
          
          if (settings.enableVehicles) items.add(const BottomNavigationBarItem(icon: Icon(Icons.directions_car), label: 'Vehicles'));
          if (settings.enableCreditCards) items.add(const BottomNavigationBarItem(icon: Icon(Icons.credit_card), label: 'Credit'));
          if (settings.enableLending) items.add(const BottomNavigationBarItem(icon: Icon(Icons.handshake_outlined), label: 'Lending'));
          
          items.add(const BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'));

          // Reset index if toggling removes the active tab
          if (_currentIndex >= items.length) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _currentIndex = 0);
            });
          }

          return BottomNavigationBar(
            currentIndex: _currentIndex >= items.length ? 0 : _currentIndex,
            onTap: (index) {
              HapticFeedback.selectionClick();
              setState(() => _currentIndex = index);
            },
            type: BottomNavigationBarType.fixed,
            items: items,
          );
        },
      ),
      body: Consumer<SettingsService>(
        builder: (context, settings, _) {
          // Reconstruct the mapping of active tabs
          final screens = <Widget>[
            _buildDashboard(),
          ];
          
          if (settings.enableVehicles) screens.add(const VehiclesScreen());
          if (settings.enableCreditCards) screens.add(const CreditCardScreen());
          if (settings.enableLending) screens.add(const LendingScreen());
          
          screens.add(const ProfileHubScreen());

          if (_currentIndex >= screens.length) {
            return screens[0]; // fallback
          }
          return screens[_currentIndex];
        },
      ),
    );
  }
}