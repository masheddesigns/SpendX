import 'package:flutter/material.dart';
import '../widgets/spendx_app_bar.dart';


/// Help & User Guide screen — collapsible FAQ-style sections for every feature.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Help & User Guide',
      ),

      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _HelpBanner(),
          const SizedBox(height: 16),
          _section(context, '🚀 Getting Started', [
            _HelpItem(
              q: 'How do I add my first expense?',
              a: 'Tap the red ➖ Expense button on the home screen Quick Actions, enter the amount, pick a category, and tap Save.',
            ),
            _HelpItem(
              q: 'How do I log income?',
              a: 'Tap the green ➕ Income button on the Quick Actions bar. Select the category (e.g., Salary) and save.',
            ),
            _HelpItem(
              q: 'What is Guest mode?',
              a: 'Guest mode lets you use SpendX without an account. Data is saved locally. Note: logging out will clear local data — sign in to keep data safe in the cloud.',
            ),
          ]),
          _section(context, '💳 Transactions', [
            _HelpItem(
              q: 'How do I edit or delete a transaction?',
              a: 'Go to the Transact tab → long-press or tap any transaction. An edit/delete menu will appear.',
            ),
            _HelpItem(
              q: 'How do I select the bank account for an expense?',
              a: 'On the Add Expense screen, scroll down past Category. You\'ll see your bank accounts listed — tap one to link this expense to that account. The balance updates automatically.',
            ),
            _HelpItem(
              q: 'What is a Recurring Transaction?',
              a: 'Toggle "Recurring" when adding an expense or income. The app will auto-generate the same transaction at your chosen frequency (daily, weekly, monthly).',
            ),
          ]),
          _section(context, '🤖 AI & Financial Intelligence', [
            _HelpItem(
              q: 'How does AI Receipt Scanning work?',
              a: 'On the Add Expense screen, tap the camera icon. Gemini AI will automatically extract the merchant, amount, and category from your receipt image.',
            ),
            _HelpItem(
              q: 'What can I ask the AI Chat Assistant?',
              a: 'You can ask questions like "How much did I spend on food this month?" or "Give me a summary of my recent budgets." It uses your local data for context.',
            ),
            _HelpItem(
              q: 'What is the Monthly AI Report?',
              a: 'At the end of each month, SpendX generates a deep-dive analysis of your spending habits, saving opportunities, and financial health trends.',
            ),
            _HelpItem(
              q: 'Are my AI interactions private?',
              a: 'Yes. SpendX follows an offline-first privacy approach. AI analysis is performed contextually, and you can disable AI features anytime in Settings > Customize Modules.',
            ),
          ]),
          _section(context, '🏦 Net Worth & Bank Accounts', [
            _HelpItem(
              q: 'How do I add a bank account?',
              a: 'More → Net Worth → tap the ➕ button. Add your bank name, account type, and current balance.',
            ),
            _HelpItem(
              q: 'Why is Net Worth hidden on the home screen?',
              a: 'For privacy — net worth starts hidden. Tap the 👁 eye icon to reveal it.',
            ),
            _HelpItem(
              q: 'How is Net Worth calculated?',
              a: 'Net Worth = Total Bank Assets − Credit Card Outstanding − Borrowed Lending Amounts.',
            ),
          ]),
          _section(context, '💳 Credit Cards & EMI', [
            _HelpItem(
              q: 'How do I add a credit card?',
              a: 'Go to the Credit tab → tap ➕ Add Card. Enter your card name, bank, last 4 digits, and credit limit.',
            ),
            _HelpItem(
              q: 'How do I mark a credit card bill as paid?',
              a: 'Credit tab → select your card → tap the "Mark as Paid" button on the Billing Due panel. Enter the amount paid and confirm. The outstanding balance updates automatically.',
            ),
            _HelpItem(
              q: 'How do I set a payment reminder for a credit card?',
              a: 'Credit tab → select your card → tap "Set Reminder" on the Billing panel. A local notification will fire at 9 AM the day before the due date.',
            ),
            _HelpItem(
              q: 'How do I delete or edit a credit card?',
              a: 'On the Credit screen, long-press any card → a menu appears with Edit and Delete options.',
            ),
            _HelpItem(
              q: 'How do I add an EMI / Bank Loan?',
              a: 'Credit tab → select a card (or use "No Card" for bank loans) → tap Add EMI. Enter the loan amount, interest rate, and tenure.',
            ),
            _HelpItem(
              q: 'How do I track loan payments?',
              a: 'On the EMI card, tap "Mark Instalment Paid" after each monthly payment. The progress bar updates automatically.',
            ),
          ]),
          _section(context, '🤝 Lending & Borrowing', [
            _HelpItem(
              q: 'How do I record money I lent to someone?',
              a: 'Go to the Lending tab → tap ➕. Choose "Lent" type, enter person\'s name, amount, and optional due date.',
            ),
            _HelpItem(
              q: 'How do I mark a lending as settled?',
              a: 'On the Lending screen, tap the lending record → tap "Mark Settled". It moves to the Settled tab.',
            ),
          ]),
          _section(context, '🚗 Vehicles & Fuel', [
            _HelpItem(
              q: 'How do I add a vehicle?',
              a: 'Vehicles tab → tap ➕ → enter vehicle name, type (car/bike), and fuel type.',
            ),
            _HelpItem(
              q: 'How do I log a fuel fill-up?',
              a: 'Tap ⛽ Fuel on Quick Actions, or go to Vehicles → select vehicle → Add Fuel Log. The app calculates mileage (km/l) automatically.',
            ),
          ]),
          _section(context, '🎮 Gamification & Rewards', [
            _HelpItem(
              q: 'How do Streaks work?',
              a: 'Log at least one transaction every day to maintain your streak. If you miss a day, the streak resets to zero. Keep it going to earn badges!',
            ),
            _HelpItem(
              q: 'What are Levels and Achievements?',
              a: 'As you track more, you unlock higher Levels (from Bronze to Diamond). Achievements are earned by hitting milestones like a 30-day streak or saving 20% of your income.',
            ),
          ]),
          _section(context, '💚 Financial Health Score', [
            _HelpItem(
              q: 'What is the Financial Health Score?',
              a: 'It\'s a real-time monitor of your financial wellbeing, calculated based on your saving-to-expense ratio, budget adherence, and consistency.',
            ),
            _HelpItem(
              q: 'How do I improve my score?',
              a: 'Stay within your budgets, maintain a positive net savings each month, and keep your tracking consistent over time.',
            ),
          ]),
          _section(context, '🔐 Privacy & Data Security', [
            _HelpItem(
              q: 'Where is my data stored?',
              a: 'SpendX is offline-first. Your transaction data, bank details, and accounts are stored locally on your device, not on our servers.',
            ),
            _HelpItem(
              q: 'What about Cloud Sync?',
              a: 'Cloud sync (Google Drive/Dropbox) is optional. If enabled, your data is encrypted and saved to your own private cloud storage for backup.',
            ),
          ]),
          _section(context, '🔄 Sync & Cloud Backups', [
            _HelpItem(
              q: 'What is Real-time Auto-Sync?',
              a: 'SpendX automatically detects when you add or change data (transactions, vehicles, accounts) and triggers a cloud backup instantly. No more manual syncing required!',
            ),
            _HelpItem(
              q: 'How do I switch to a different Google/Dropbox account?',
              a: 'Go to More → Backup Hub. Tap the "Unlink" icon next to your active account. You can then sign in with a different account.',
            ),
            _HelpItem(
              q: 'What if the cloud data is different from my local data?',
              a: 'If SpendX detects a newer version in the cloud, it will notify you on the Backup Hub. You can choose to "Keep Local" or "Restore Cloud" to resolve the conflict.',
            ),
          ]),
          _section(context, '\ud83d\udcc8 Financial Reports', [
            _HelpItem(
              q: 'Where do I find the reports?',
              a: 'Tap the \u22ef (three-dot) menu on the home screen \u2192 Financial Reports. Also accessible from More \u2192 Financial Reports.',
            ),
            _HelpItem(
              q: 'What does the Overview tab show?',
              a: 'Income vs Expense bar chart for 6 or 12 months, plus a month-by-month net savings breakdown.',
            ),
            _HelpItem(
              q: 'What does the Credit tab show?',
              a: 'Outstanding amounts across all your credit cards as a bar chart, with per-card utilization & days to due.',
            ),
            _HelpItem(
              q: 'What does the Fuel tab show?',
              a: 'Monthly fuel spend for last 6 months as a bar chart with total summary.',
            ),
          ]),
          _section(context, '\ud83d\udd14 Notifications', [
            _HelpItem(
              q: 'How do I view upcoming payment reminders?',
              a: 'Tap the \ud83d\udd14 bell icon (top-right home screen). The Notifications Inbox shows upcoming credit dues and EMI payments.',
            ),
            _HelpItem(
              q: 'What can I do in the Notifications Inbox?',
              a: 'Directly pay a credit bill, mark an EMI instalment paid, or add a new expense/income — all from the inbox.',
            ),
            _HelpItem(
              q: 'How do I enable push notifications?',
              a: 'More \u2192 Notification Settings \u2192 toggle on "Enable Notifications" and grant permission when prompted.',
            ),
          ]),
          const SizedBox(height: 32),
          Center(
            child: Text(
              'Still have questions? Contact us at mashingdesigns@gmail.com',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 0, 10),
          child: Text(
            title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...items,
        const SizedBox(height: 4),
      ],
    );
  }
}

class _HelpBanner extends StatelessWidget {
  const _HelpBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Theme.of(context).colorScheme.primary.withValues(alpha: 0.2), Theme.of(context).colorScheme.secondary.withValues(alpha: 0.2)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.menu_book_rounded, color: Theme.of(context).colorScheme.primary, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SpendX User Guide', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 4),
                Text('Tap any question to learn how to use each feature.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HelpItem extends StatefulWidget {
  final String q;
  final String a;
  const _HelpItem({required this.q, required this.a});

  @override
  State<_HelpItem> createState() => _HelpItemState();
}

class _HelpItemState extends State<_HelpItem> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _expanded
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)
              : Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.q,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 10),
                Divider(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.2), height: 1),
                const SizedBox(height: 10),
                Text(
                  widget.a,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
