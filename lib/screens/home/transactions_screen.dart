import 'package:flutter/material.dart';
import '../../widgets/custom_dialog.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../models/transaction.dart' as spx;
import '../../models/category.dart';
import '../../services/database_helper.dart';
import '../../services/transaction_service.dart';
import '../../widgets/transaction_tile.dart';
import '../expense/add_expense_screen.dart';
import '../vehicles/add_fuel_screen.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/spendx_app_bar.dart';

class TransactionListScreen extends StatefulWidget {
  final bool isFullScreen;
  const TransactionListScreen({super.key, this.isFullScreen = false});

  @override
  State<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends State<TransactionListScreen> {

  List<spx.Transaction> transactions = [];
  Map<String, Category> categoriesMap = {};
  bool isLoading = true;
  bool isLoadMore = false;
  bool hasMore = true;
  int offset = 0;
  final int limit = 30;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200 &&
        !isLoadMore &&
        hasMore) {
      _loadMoreTransactions();
    }
  }

  Future<void> _loadInitialData() async {
    setState(() => isLoading = true);
    offset = 0;
    hasMore = true;
    
    try {
      final fetchedTransactions = await TransactionService.instance.getTransactions(limit: limit, offset: offset);
      
      Map<String, Category> fetchedCategories = {};
      if (!kIsWeb) {
        final db = await DatabaseHelper.instance.database;
        final catMaps = await db.query(DatabaseHelper.tableCategories);
        fetchedCategories = { for (var item in catMaps) item['id'] as String : Category.fromMap(item) };
      }

      if (!mounted) return;
      setState(() {
        transactions = fetchedTransactions;
        categoriesMap = fetchedCategories;
        isLoading = false;
        hasMore = fetchedTransactions.length == limit;
        offset += limit;
      });
    } catch (e) {
      debugPrint('TransactionListScreen load error: $e');
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _loadMoreTransactions() async {
    setState(() => isLoadMore = true);
    
    try {
      final fetched = await TransactionService.instance.getTransactions(limit: limit, offset: offset);
      
      if (!mounted) return;
      setState(() {
        transactions.addAll(fetched);
        isLoadMore = false;
        hasMore = fetched.length == limit;
        offset += limit;
      });
    } catch (e) {
      debugPrint('Load more error: $e');
      if (mounted) setState(() => isLoadMore = false);
    }
  }

  Future<void> _loadTransactions() async {
    await _loadInitialData();
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
      _loadInitialData();
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
                  if (result == true) _loadInitialData();
                },
              ),
            if (t.source == 'manual')
              ListTile(
                leading: Icon(Icons.delete, color: AppTheme.errorColor),
                title: Text('Delete', style: TextStyle(color: AppTheme.errorColor)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteTransaction(t.id);
                },
              ),
            if (t.source == 'vehicle')
              ListTile(
                leading: Icon(Icons.edit, color: AppTheme.warningColor),
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
                      if (result == true) _loadInitialData();
                    }
                  }
                },
              ),
            if (t.source != 'manual' && t.source != 'vehicle')
              ListTile(
                leading: Icon(Icons.info_outline, color: AppTheme.warningColor),
                title: Text('Managed by ${t.source}'),
                subtitle: const Text('Please edit or delete this entry from its respective module.'),
                onTap: () => Navigator.pop(context),
              )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (transactions.isEmpty) {
      return EmptyState(
        icon: Icons.account_balance_wallet_outlined,
        title: "No transactions yet",
        description: "Start adding transactions to track your spending.",
        buttonText: "+ Add Transaction",
        onButtonPressed: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const AddExpenseScreen(initialType: 'expense'),
            ),
          );
          if (result == true) _loadInitialData();
        },
      );
    }

    final content = RefreshIndicator(
      onRefresh: _loadTransactions,
      color: Theme.of(context).colorScheme.secondary,
      backgroundColor: Theme.of(context).colorScheme.surface,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 24),
        itemCount: transactions.length + (hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == transactions.length) {
            return const Center(child: Padding(
              padding: EdgeInsets.all(16.0),
              child: CircularProgressIndicator(),
            ));
          }
          final t = transactions[index];
          final isEven = index % 2 == 0;
          
          return Container(
            color: isEven ? Colors.transparent : Theme.of(context).colorScheme.surfaceContainer.withValues(alpha: 0.3),
            child: TransactionTile(
              transaction: t,
              category: categoriesMap[t.categoryId],
              onTap: () => _handleTransactionTap(t),
            ),
          );
        },
      ),
    );

    if (widget.isFullScreen) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('All Transactions'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: content,
      );
    }
    return content;
  }
}
