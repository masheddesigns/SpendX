import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../widgets/spendx_app_bar.dart';
import 'privacy_policy_screen.dart';


class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SpendXAppBar(
        title: 'About SpendX',
      ),

      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 20),
            // Themed Brand Mark
            Center(
                  child: Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
                          blurRadius: 30,
                        )
                      ]
                    ),
                    child: const Icon(Icons.account_balance_wallet, size: 80, color: Colors.white),

                  ),
                ),
// ... (text remains same)
            const SizedBox(height: 32),
            Text(
              'SpendX',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                    letterSpacing: 1.2,
                  ),
            ),
// ... (version remains same)
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                final version = snapshot.data?.version ?? '1.3.20';
                return Text(
                  'Version $version',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                );
              },
            ),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
                ),
              ),
              child: Column(
                children: [
                   _AboutRow(
                    icon: Icons.code, 
                    label: 'Developed by', 
                    value: 'Sivek',
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const Divider(height: 32, color: Colors.white12),
                  _AboutRow(
                    icon: Icons.bolt, 
                    label: 'Tech Stack', 
                    value: 'Flutter, SQLite, Gemini AI, ChatGPT, Codex, Figma',
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                  const Divider(height: 32, color: Colors.white12),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen())),
                      child: _AboutRow(
                        icon: Icons.shield_outlined, 
                        label: 'Privacy', 
                        value: 'Read Privacy Policy',
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'SpendX is a minimalist, offline-first personal finance tracker built with care to help you track smarter and save better without compromising your data privacy.',
              style: TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 14,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 48),
            Text(
              '© 2026 Mashing Designs',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _AboutRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
}
