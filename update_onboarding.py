import os
import re

filepath = '/Users/sivek/Documents/SpendX/lib/screens/onboarding_screen.dart'

with open(filepath, 'r') as f:
    content = f.read()

# 1. Imports
if "import 'package:provider/provider.dart';" not in content:
    content = content.replace(
        "import '../theme/app_theme.dart';",
        "import '../theme/app_theme.dart';\nimport 'package:provider/provider.dart';"
    )

# 2. Total pages & State
content = content.replace("final int _totalPages = 7;", "final int _totalPages = 8;")
content = content.replace(
    "Set<String> _selectedFeatures = {'Budgeting'};",
    "bool _enableVehicles = true;\n  bool _enableCreditCards = true;\n  bool _enableLending = true;"
)

# 3. Finish Onboarding
old_finish = """  Future<void> _finishOnboarding() async {
    await SettingsService.instance.setOnboardingComplete(true);
    await SettingsService.instance.setPrimaryCurrency(_selectedCurrency);"""

new_finish = """  Future<void> _finishOnboarding() async {
    await SettingsService.instance.setOnboardingComplete(true);
    await SettingsService.instance.setPrimaryCurrency(_selectedCurrency);
    await SettingsService.instance.setEnableVehicles(_enableVehicles);
    await SettingsService.instance.setEnableCreditCards(_enableCreditCards);
    await SettingsService.instance.setEnableLending(_enableLending);"""

content = content.replace(old_finish, new_finish)

# 4. PageView
old_pv = """                  _buildDataImportScreen(),
                  _buildFinishSetupScreen(),"""

new_pv = """                  _buildDataImportScreen(),
                  _buildThemeSetupScreen(),
                  _buildFinishSetupScreen(),"""

content = content.replace(old_pv, new_pv)

# 5. App Overview
old_overview = """          _buildFeatureCard(Icons.pie_chart, 'Track Expenses', 'Log your spending easily in seconds.'),
          const SizedBox(height: 16),
          _buildFeatureCard(Icons.account_balance, 'Set Budgets', 'Stay within limits with smart budgets.'),
          const SizedBox(height: 16),
          _buildFeatureCard(Icons.insights, 'See Insights', 'Understand your habits with rich charts.'),"""

new_overview = """          _buildFeatureCard(Icons.document_scanner, 'AI Vision Scanner', 'Scan bills and PDFs automatically.'),
          const SizedBox(height: 16),
          _buildFeatureCard(Icons.account_balance_wallet, 'Net Worth Tracking', 'Track assets boundaries beautifully.'),
          const SizedBox(height: 16),
          _buildFeatureCard(Icons.credit_card, 'Credit & EMI', 'Manage credit cards, loans, and bills.'),"""

content = content.replace(old_overview, new_overview)

# 6. Feature Selection
old_feat_sel = """  Widget _buildFeatureSelectionScreen() {
    final features = {
      'Budgeting': 'Track category limits',
      'Attachments': 'Save receipts & photos',
      'Goals': 'Save for big purchases',
      'Shared Ledgers': 'Track with partners'
    };

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 32),
          Text(
            'Customize modules',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 8),
          Text('Turn on the features you plan to use.', style: TextStyle(color: Colors.grey[400])),
          const SizedBox(height: 32),
          ...features.entries.map((entry) => Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: SwitchListTile(
                  title: Text(entry.key, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text(entry.value, style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                  value: _selectedFeatures.contains(entry.key),
                  onChanged: (bool value) {
                    setState(() {
                      if (value) {
                        _selectedFeatures.add(entry.key);
                      } else {
                        _selectedFeatures.remove(entry.key);
                      }
                    });
                  },
                  activeColor: Theme.of(context).primaryColor,
                  tileColor: AppTheme.surfaceColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                ),
              )),
        ],
      ),
    );
  }"""

new_feat_sel = """  Widget _buildFeatureSelectionScreen() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 32),
          Text(
            'Customize modules',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 8),
          Text('Turn on the extra features you plan to use.', style: TextStyle(color: Colors.grey[400])),
          const SizedBox(height: 32),
          _buildToggleTile('Vehicle Tracking', 'Fuel logs and maintenance', _enableVehicles, (v) => setState(() => _enableVehicles = v)),
          const SizedBox(height: 16),
          _buildToggleTile('Credit Cards', 'Track limits and bills', _enableCreditCards, (v) => setState(() => _enableCreditCards = v)),
          const SizedBox(height: 16),
          _buildToggleTile('Lending', 'Manage loans and EMIs', _enableLending, (v) => setState(() => _enableLending = v)),
        ],
      ),
    );
  }

  Widget _buildToggleTile(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle, style: TextStyle(color: Colors.grey[400], fontSize: 13)),
      value: value,
      onChanged: onChanged,
      activeColor: Theme.of(context).primaryColor,
      tileColor: AppTheme.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    );
  }"""

content = content.replace(old_feat_sel, new_feat_sel)

# 7. Currency readability
old_curr_txt = "Text(currency, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, color: Colors.white, fontSize: 16))"
new_curr_txt = "Text(currency, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.w500, color: Colors.white, fontSize: 16))"
content = content.replace(old_curr_txt, new_curr_txt)

# 8. Category readability
old_cat_txt = "color: isSelected ? Theme.of(context).primaryColor : Colors.white,"
new_cat_txt = "color: Colors.white,"
content = content.replace(old_cat_txt, new_cat_txt)

# 9. Theme screen
new_theme_screen = """
  Widget _buildThemeSetupScreen() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 32),
          Text(
            'App Color Theme',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 8),
          Text('Select your preferred organic color palette.', style: TextStyle(color: Colors.grey[400])),
          const SizedBox(height: 48),
          Consumer<AppTheme>(
            builder: (context, themeNotifier, _) {
              return Wrap(
                spacing: 20,
                runSpacing: 20,
                alignment: WrapAlignment.center,
                children: AppTheme.availableColors.map((color) {
                  final isSelected = color == themeNotifier.primaryColor;
                  return GestureDetector(
                    onTap: () {
                      themeNotifier.setPrimaryColor(color);
                    },
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: isSelected ? Border.all(color: Colors.white, width: 4) : null,
                        boxShadow: [
                          if (isSelected) BoxShadow(color: color.withOpacity(0.5), blurRadius: 12, spreadRadius: 4),
                        ],
                      ),
                      child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 32) : null,
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
"""

content = content.replace("  Widget _buildFinishSetupScreen() {", new_theme_screen + "  Widget _buildFinishSetupScreen() {")

with open(filepath, 'w') as f:
    f.write(content)

print("Updates applied directly")
