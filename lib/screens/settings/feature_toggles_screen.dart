import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/settings_service.dart';
import '../../widgets/spendx_app_bar.dart';

class FeatureTogglesScreen extends StatelessWidget {
  const FeatureTogglesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(title: 'Switchable Modules'),

      body: Consumer<SettingsService>(
        builder: (context, settings, _) {
          return SafeArea(
            child: ListView(
              padding: EdgeInsets.all(24),
              children: [
                const Text(
                  'Customize Your Experience',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Turn off features you don\'t use to keep SpendX clean and simple. You can always turn them back on later.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 32),
  
                _ModuleToggle(
                  icon: Icons.money_off_csred_rounded,
                  color: Colors.orange,
                  title: 'Disable Income Tracking',
                  subtitle:
                      'Hide income actions, charts, filters, and summaries for expense-only use.',
                  value: settings.isIncomeDisabled,
                  onChanged: settings.setIncomeDisabled,
                ),
                const SizedBox(height: 16),
  
                _ModuleToggle(
                  icon: Icons.credit_card,
                  color: Theme.of(context).colorScheme.primary,
                  title: 'Credit Cards & EMIs',
                  subtitle: 'Manage credit limits, billing dates, and EMI plans.',
                  value: settings.enableCreditCards,
                  onChanged: settings.setEnableCreditCards,
                ),
                const SizedBox(height: 16),
  
                _ModuleToggle(
                  icon: Icons.account_balance_wallet_rounded,
                  color: Theme.of(context).colorScheme.tertiary,
                  title: 'Bank Loans & EMIs',
                  subtitle: 'Track your home, car, and personal loans with amortization.',
                  value: settings.enableLoans,
                  onChanged: settings.setEnableLoans,
                ),
                const SizedBox(height: 16),
  
                _ModuleToggle(
                  icon: Icons.summarize_rounded,
                  color: Colors.redAccent,
                  title: 'Liabilities Hub',
                  subtitle: 'Unified view for all your credit and debt obligations.',
                  value: settings.enableLiabilities,
                  onChanged: settings.setEnableLiabilities,
                ),
                const SizedBox(height: 16),
  
                _ModuleToggle(
                  icon: Icons.handshake,
                  color: Theme.of(context).colorScheme.tertiary,
                  title: 'Lending & Borrowing',
                  subtitle: 'Track money you lent to or borrowed from people.',
                  value: settings.enableLending,
                  onChanged: settings.setEnableLending,
                ),
  
                const SizedBox(height: 32),
                const Text(
                  'AI & Privacy',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Control how SpendX uses AI to analyze your finances. All AI processing is contextual and privacy-focused.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 24),
  
                _ModuleToggle(
                  icon: Icons.psychology,
                  color: Theme.of(context).colorScheme.primary,
                  title: 'Enable AI Chat Assistant',
                  subtitle: 'Ask questions about your spending in real-time.',
                  value: settings.enableAiChat,
                  onChanged: settings.setEnableAiChat,
                ),
                const SizedBox(height: 16),
  
                _ModuleToggle(
                  icon: Icons.analytics,
                  color: Theme.of(context).colorScheme.tertiary,
                  title: 'Enable Monthly AI Report',
                  subtitle: 'Generate deep financial insights every month.',
                  value: settings.enableAiReport,
                  onChanged: settings.setEnableAiReport,
                ),
                const SizedBox(height: 24),
  
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.shield,
                        color: Theme.of(context).colorScheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'SpendX uses Gemini AI to analyze your data. Processing is done locally or via secure API calls. No data is used for training.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ModuleToggle extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ModuleToggle({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: value
              ? color.withValues(alpha: 0.5)
              : Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        activeThumbColor: Theme.of(context).colorScheme.onPrimary,
        activeTrackColor: color.withValues(alpha: 0.8),
        inactiveThumbColor: Theme.of(context).colorScheme.onSurfaceVariant,
        inactiveTrackColor: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest,
        secondary: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: value
                ? color.withValues(alpha: 0.15)
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            color: value
                ? color
                : Theme.of(context).colorScheme.onSurfaceVariant,
            size: 22,
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: value ? FontWeight.w600 : FontWeight.normal,
            color: value
                ? Theme.of(context).colorScheme.onSurface
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
            fontSize: 12,
          ),
        ),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
