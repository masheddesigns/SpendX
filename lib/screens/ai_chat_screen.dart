import '../core/logging/app_logger.dart';
import '../core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import '../features/ai/ai_action.dart';
import '../features/ai/ai_data_bridge.dart';
import '../data/providers.dart';
import '../services/gemini_service.dart';
import '../utils/app_format.dart';
import '../services/salary_service.dart';

class AiChatScreen extends ConsumerStatefulWidget {
  const AiChatScreen({super.key});

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_ChatMsg> _messages = [];
  bool _isLoading = false;
  bool _initialized = false;

  final List<String> _suggestions = [
    'How much did I spend this month?',
    'Do I have any dues today?',
    'Is my salary received?',
    'Show pending payments',
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
      final txns = await ref.read(transactionsProvider.future);
      final accounts = await ref.read(accountsProvider.future);
      final cards = await ref.read(cardsProvider.future);
      final reminders = await DatabaseService().getAlertRecords();
      final salaries = await SalaryService.instance.getAllSalaries();

      final recent = txns.take(20).toList();

      double totalBalance = 0;
      for (var a in accounts) {
        if (a.isAsset) totalBalance += a.balance;
      }

      final now = DateTime.now();
      final thisMonthTxns = txns
          .where((t) => t.date.year == now.year && t.date.month == now.month)
          .toList();
      double monthlyIncome = thisMonthTxns
          .where((t) => t.type == 'income')
          .fold<double>(0.0, (sum, t) => sum + t.amount);
      double monthlyExpense = thisMonthTxns
          .where((t) => t.type == 'expense')
          .fold<double>(0.0, (sum, t) => sum + t.amount);

      final sb = StringBuffer();
      sb.writeln('CURRENT FINANCIAL CONTEXT:');
      sb.writeln('Total Asset Balance: ${AppFormat.currency(totalBalance)}');
      sb.writeln('This Month Income: ${AppFormat.currency(monthlyIncome)}');
      sb.writeln('This Month Expenses: ${AppFormat.currency(monthlyExpense)}');

      sb.writeln('\nBank Accounts:');
      for (var a in accounts) {
        sb.writeln('- ${a.name}: ${AppFormat.currency(a.balance)}');
      }

      sb.writeln('\nCredit Cards:');
      for (var c in cards) {
        sb.writeln(
          '- ${c.bank}: Outstanding ${AppFormat.currency(c.outstanding)}',
        );
      }

      sb.writeln('\nDue Reminders:');
      for (final reminder in reminders.take(10)) {
        sb.writeln(
          '- ${reminder.type.name} | ${reminder.title} | ${reminder.status.name}',
        );
      }

      sb.writeln('\nSalary Status:');
      for (final salary in salaries.take(6)) {
        sb.writeln(
          '- ${salary.companyName} ${salary.salaryMonth.month}/${salary.salaryMonth.year}: ${salary.status.name}',
        );
      }

      sb.writeln('\nRecent Transactions (last ${recent.length}):');
      for (final t in recent) {
        sb.writeln(
          '- ${t.date.toIso8601String().substring(0, 10)} | ${t.type} | ${AppFormat.currency(t.amount)} | ${t.notes}',
        );
      }

      GeminiService.instance.init();
      GeminiService.instance.startChat(contextData: sb.toString());

      if (!silent && mounted) {
        setState(() {
          _initialized = true;
          _messages.add(
            _ChatMsg(
              text:
                  'Hi! I\'m SpendX AI 🤖\nI\'ve loaded your recent transactions. Ask me anything about your finances!',
              isUser: false,
            ),
          );
        });
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(() {
          _initialized = true;
          _messages.add(
            _ChatMsg(
              text: 'Hi! I\'m SpendX AI. How can I help you today?',
              isUser: false,
            ),
          );
        });
      }
    }
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty || _isLoading) return;
    _textCtrl.clear();

    if (mounted) {
      setState(() {
        _messages.add(_ChatMsg(text: text, isUser: true));
        _isLoading = true;
      });
    }
    _scrollToBottom();

    // ── LAYER 0: Action parsing (add expense, add income) ──────────────
    // Try to parse as an action command first. If successful, show
    // confirmation card instead of executing immediately.
    final action = ref.read(parseAIActionProvider)(text);
    if (action != null) {
      if (mounted) {
        setState(() {
          _messages.add(_ChatMsg(
            text: action.confirmationText,
            isUser: false,
            pendingAction: action,
          ));
          _isLoading = false;
        });
      }
      _scrollToBottom();
      return;
    }

    String botReplyText;

    // ── LAYER 1: Local intent resolution (instant, deterministic) ──────
    final localResponse = await ref.read(aiDataBridgeProvider).handle(text);

    if (localResponse != null) {
      botReplyText = localResponse;
    } else {
      // ── LAYER 2: Hardcoded domain queries ────────────────────────────
      final lower = text.toLowerCase().trim();
      String? domainResponse;

      if (lower.contains('dues today') || lower.contains('due today')) {
        final reminders = await DatabaseService().getAlertRecords();
        final dueToday = reminders
            .where((item) => item.status.name == 'dueToday')
            .toList();
        domainResponse = dueToday.isEmpty
            ? 'You have no dues today.'
            : dueToday.map((item) => '\u2022 ${item.title}').join('\n');
      } else if (lower.contains('salary received')) {
        final salary = await SalaryService.instance.getCurrentMonthSalary();
        if (salary == null) {
          domainResponse = 'No salary record found for the current month.';
        } else {
          domainResponse =
              'Current salary status: ${salary.status.name}. Received ${AppFormat.currency(salary.amountReceived)} out of ${AppFormat.currency(salary.netSalary)}.';
        }
      } else if (lower.contains('pending payments')) {
        final reminders = await DatabaseService().getAlertRecords();
        final pending = reminders
            .where((item) => item.status.name != 'inactive')
            .map((item) => '\u2022 ${item.title}')
            .join('\n');
        domainResponse = pending.isEmpty ? 'No pending payments found.' : pending;
      }

      if (domainResponse != null) {
        botReplyText = domainResponse;
      } else {
        // ── LAYER 3: Gemini fallback (creative / open-ended) ────────────
        final response = await GeminiService.instance.sendMessage(text);
        botReplyText = response;

        // Intercept JSON commands from Gemini (handles single AND multiple)
        if (response.contains('{') && response.contains('}')) {
          try {
            // Extract ALL JSON objects from the response
            final jsonPattern = RegExp(r'\{[^{}]*\}');
            final matches = jsonPattern.allMatches(response);
            final actions = <AIAction>[];

            final categories = ref.read(categoriesProvider).value ?? const [];

            for (final match in matches) {
              try {
                final data = jsonDecode(match.group(0)!) as Map<String, dynamic>;
                if (data['action'] == 'add_transaction') {
                  final double amount = (data['amount'] as num).toDouble();
                  final String type = data['type'] ?? 'expense';
                  final String catName = data['category'] ?? 'Other';

                  String? categoryId;
                  try {
                    final catMatch = categories.firstWhere(
                      (c) => c.name.toLowerCase().contains(catName.toLowerCase()),
                    );
                    categoryId = catMatch.id;
                  } catch (_) {}

                  actions.add(AIAction(
                    type: type == 'income'
                        ? AIActionType.addIncome
                        : AIActionType.addExpense,
                    amount: amount,
                    categoryName: catName,
                    categoryId: categoryId,
                    note: data['notes'] as String?,
                  ));
                }
              } catch (_) {}
            }

            if (actions.isNotEmpty && mounted) {
              setState(() {
                for (final action in actions) {
                  _messages.add(_ChatMsg(
                    text: action.confirmationText,
                    isUser: false,
                    pendingAction: action,
                  ));
                }
                _isLoading = false;
              });
              _scrollToBottom();
              return;
            }
          } catch (e) {
            AppLogger.d('JSON parse error from AI: $e');
          }
        }
      }
    }

    if (mounted) {
      setState(() {
        _messages.add(_ChatMsg(text: botReplyText, isUser: false));
        _isLoading = false;
      });
    }
    _scrollToBottom();
  }

  Future<void> _confirmAction(_ChatMsg msg) async {
    final action = msg.pendingAction;
    if (action == null || msg.actionResolved) return;

    setState(() {
      msg.actionResolved = true;
      _isLoading = true;
    });

    final result = await executeAction(action, ref);
    _initChat(silent: true);

    if (mounted) {
      setState(() {
        _messages.add(_ChatMsg(text: result, isUser: false));
        _isLoading = false;
      });
    }
    _scrollToBottom();
  }

  void _cancelAction(_ChatMsg msg) {
    if (msg.actionResolved) return;
    setState(() {
      msg.actionResolved = true;
      _messages.add(_ChatMsg(text: 'Action cancelled.', isUser: false));
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
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Theme.of(context).colorScheme.primary,
                    Theme.of(context).colorScheme.secondary,
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.auto_awesome,
                color: Theme.of(context).colorScheme.onPrimary,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SpendX AI',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                Text(
                  'Powered by Google Gemini',
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
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
                        if (i == _messages.length) {
                          return _buildTypingIndicator();
                        }
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
                  children: _suggestions
                      .map(
                        (s) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () => _sendMessage(s),
                            child: Chip(
                              label: Text(
                                s,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSecondaryContainer,
                                ),
                              ),
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.secondaryContainer,
                              side: BorderSide(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),

            // Input bar
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textCtrl,
                        maxLines: null,
                        decoration: InputDecoration(
                          hintText: 'Ask about your finances...',
                          hintStyle: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHigh,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                        ),
                        onSubmitted: _sendMessage,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _sendMessage(_textCtrl.text),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Theme.of(context).colorScheme.primary,
                              Theme.of(context).colorScheme.secondary,
                            ],
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: _isLoading
                            ? Padding(
                                padding: const EdgeInsets.all(10),
                                child: CircularProgressIndicator(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimary,
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                Icons.send,
                                color: Theme.of(context).colorScheme.onPrimary,
                                size: 20,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(_ChatMsg msg) {
    // Action confirmation card
    if (msg.pendingAction != null && !msg.isUser) {
      return _buildActionCard(msg);
    }

    return Align(
      alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: msg.isUser
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(msg.isUser ? 20 : 4),
            bottomRight: Radius.circular(msg.isUser ? 4 : 20),
          ),
          border: msg.isUser
              ? null
              : Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Text(
          msg.text,
          style: TextStyle(
            color: msg.isUser
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
            fontSize: 14,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildActionCard(_ChatMsg msg) {
    final action = msg.pendingAction!;
    final cs = Theme.of(context).colorScheme;
    final isExpense = action.type == AIActionType.addExpense;
    final typeColor = isExpense ? cs.error : const Color(0xFF22C55E);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(20),
          ),
          border: Border.all(color: typeColor.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Row(
                children: [
                  Icon(
                    isExpense
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_downward_rounded,
                    color: typeColor,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isExpense ? 'Add Expense' : 'Add Income',
                    style: TextStyle(
                      color: typeColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                AppFormat.currency(action.amount),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (action.categoryName != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  'Category: ${action.categoryName}',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            if (action.accountName != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                child: Text(
                  'Account: ${action.accountName}',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (!msg.actionResolved)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _cancelAction(msg),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: cs.onSurfaceVariant,
                          side: BorderSide(color: cs.outlineVariant),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: () => _confirmAction(msg),
                        style: FilledButton.styleFrom(
                          backgroundColor: typeColor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Confirm'),
                      ),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  msg.actionResolved ? 'Resolved' : '',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
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
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < 3; i++) ...[
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  shape: BoxShape.circle,
                ),
              ),
              if (i < 2) const SizedBox(width: 4),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChatMsg {
  final String text;
  final bool isUser;

  /// If non-null, this message is an action confirmation card.
  final AIAction? pendingAction;

  /// Whether this action has been resolved (confirmed or cancelled).
  bool actionResolved = false;

  _ChatMsg({
    required this.text,
    required this.isUser,
    this.pendingAction,
  });
}
