import 'package:flutter/material.dart';
import 'dart:convert';
import '../models/transaction.dart';
import '../services/transaction_service.dart';
import '../services/gemini_service.dart';
import '../services/database_helper.dart';
import '../theme/app_theme.dart';
import '../utils/app_format.dart';

class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_ChatMsg> _messages = [];
  bool _isLoading = false;
  bool _initialized = false;

  final List<String> _suggestions = [
    'How much did I spend this month?',
    'What is my biggest expense category?',
    'Am I over budget?',
    'How can I save more money?',
    'Summarize my spending habits',
  ];

  @override
  void initState() {
    super.initState();
    _initChat();
  }

  Future<void> _initChat({bool silent = false}) async {
    try {
      final db = DatabaseHelper.instance;
      final txns = await db.getAllTransactions();
      final accounts = await db.getAllBankAccounts();
      final cards = await db.getAllCreditCards();

      final recent = txns.take(20).toList();

      double totalBalance = 0;
      for (var a in accounts) { if (a.isAsset) totalBalance += a.balance; }
      
      final now = DateTime.now();
      final thisMonthTxns = txns.where((t) => t.date.year == now.year && t.date.month == now.month).toList();
      double monthlyIncome = thisMonthTxns.where((t) => t.type == 'income').fold<double>(0.0, (sum, t) => sum + t.amount);
      double monthlyExpense = thisMonthTxns.where((t) => t.type == 'expense').fold<double>(0.0, (sum, t) => sum + t.amount);

      final sb = StringBuffer();
      sb.writeln('CURRENT FINANCIAL CONTEXT:');
      sb.writeln('Total Asset Balance: ${AppFormat.currency(totalBalance)}');
      sb.writeln('This Month Income: ${AppFormat.currency(monthlyIncome)}');
      sb.writeln('This Month Expenses: ${AppFormat.currency(monthlyExpense)}');
      
      sb.writeln('\nBank Accounts:');
      for (var a in accounts) { sb.writeln('- ${a.name}: ${AppFormat.currency(a.balance)}'); }
      
      sb.writeln('\nCredit Cards:');
      for (var c in cards) { sb.writeln('- ${c.bank}: Outstanding ${AppFormat.currency(c.outstanding)}'); }

      sb.writeln('\nRecent Transactions (last ${recent.length}):');
      for (final t in recent) {
        sb.writeln('- ${t.date.toIso8601String().substring(0, 10)} | ${t.type} | ${AppFormat.currency(t.amount)} | ${t.notes}');
      }
      
      GeminiService.instance.init();
      GeminiService.instance.startChat(contextData: sb.toString());
      
      if (!silent) {
        setState(() {
          _initialized = true;
          _messages.add(_ChatMsg(
            text: 'Hi! I\'m SpendX AI 🤖\nI\'ve loaded your recent transactions. Ask me anything about your finances!',
            isUser: false,
          ));
        });
      }
    } catch (e) {
      if (!silent) {
        setState(() {
          _initialized = true;
          _messages.add(_ChatMsg(text: 'Hi! I\'m SpendX AI. How can I help you today?', isUser: false));
        });
      }
    }
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty || _isLoading) return;
    _textCtrl.clear();

    setState(() {
      _messages.add(_ChatMsg(text: text, isUser: true));
      _isLoading = true;
    });
    _scrollToBottom();

    final response = await GeminiService.instance.sendMessage(text);

    String botReplyText = response;

    // Intercept JSON commands from the AI
    if (response.contains('{') && response.contains('}')) {
      try {
        final jStart = response.indexOf('{');
        final jEnd = response.lastIndexOf('}') + 1;
        final jsonStr = response.substring(jStart, jEnd);
        final data = jsonDecode(jsonStr);
        
        if (data['action'] == 'add_transaction') {
            final double amount = (data['amount'] as num).toDouble();
            final String type = data['type'] ?? 'expense';
            final String catName = data['category'] ?? 'Other';
            
            // Try to find a matching category
            final categories = await DatabaseHelper.instance.database.then((db) => db.query('categories'));
            String? categoryId;
            try {
              final match = categories.firstWhere((c) => (c['name'] as String).toLowerCase().contains(catName.toLowerCase()));
              categoryId = match['id'] as String;
            } catch (_) {}
            
            // Insert it
            final txn = Transaction(
              userId: 'offline_user',
              type: type,
              amount: amount,
              date: DateTime.now(),
              notes: data['notes'] ?? 'Added via AI',
              categoryId: categoryId,
            );
            
            await TransactionService.instance.addTransaction(txn);
            
            botReplyText = '✅ Successfully logged $type of ${AppFormat.currency(amount)} for $catName.';
            
            // Reload context silently below
            _initChat(silent: true);
        }
      } catch (e) {
        debugPrint('JSON parse error from AI: $e');
        // fallback to just showing the response text
      }
    }

    setState(() {
      _messages.add(_ChatMsg(text: botReplyText, isUser: false));
      _isLoading = false;
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                Theme.of(context).colorScheme.primary,
                Theme.of(context).colorScheme.secondary,
              ]),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.auto_awesome, color: Theme.of(context).colorScheme.onPrimary, size: 18),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('SpendX AI', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
            Text('Powered by Google Gemini', style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ]),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: !_initialized
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    itemCount: _messages.length + (_isLoading ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i == _messages.length) return _buildTypingIndicator();
                      return _buildBubble(_messages[i]);
                    },
                  ),
          ),

          // Suggestion chips (only when few messages)
          if (_messages.length <= 2 && _initialized)
            SizedBox(
              height: 44,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                children: _suggestions.map((s) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => _sendMessage(s),
                    child: Chip(
                      label: Text(s, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSecondaryContainer)),
                      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                      side: BorderSide(color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
                )).toList(),
              ),
            ),

          // Input bar
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
            ),
            child: SafeArea(
              top: false,
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    maxLines: null,
                    decoration: InputDecoration(
                      hintText: 'Ask about your finances...',
                      hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onSubmitted: _sendMessage,
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _sendMessage(_textCtrl.text),
                  child: Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        Theme.of(context).colorScheme.primary,
                        Theme.of(context).colorScheme.secondary,
                      ]),
                      shape: BoxShape.circle,
                    ),
                    child: _isLoading
                        ? Padding(padding: const EdgeInsets.all(10), child: CircularProgressIndicator(color: Theme.of(context).colorScheme.onPrimary, strokeWidth: 2))
                        : Icon(Icons.send, color: Theme.of(context).colorScheme.onPrimary, size: 20),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBubble(_ChatMsg msg) {
    return Align(
      alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: msg.isUser ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(msg.isUser ? 20 : 4),
            bottomRight: Radius.circular(msg.isUser ? 4 : 20),
          ),
          border: msg.isUser ? null : Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Text(msg.text, style: TextStyle(color: msg.isUser ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurface, fontSize: 14, height: 1.4)),
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (int i = 0; i < 3; i++) ...[
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 6, height: 6,
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurfaceVariant, shape: BoxShape.circle),
            ),
            if (i < 2) const SizedBox(width: 4),
          ],
        ]),
      ),
    );
  }
}

class _ChatMsg {
  final String text;
  final bool isUser;
  _ChatMsg({required this.text, required this.isUser});
}
