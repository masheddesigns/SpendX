import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Policy'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSection(
              context,
              'DATA STORAGE',
              'SpendX stores financial data locally on your device. Your data never leaves your phone unless you explicitly choose to back it up.',
            ),
            _buildSection(
              context,
              'CLOUD BACKUP',
              'Optional backups may be stored in your personal Google Drive or Dropbox. These backups are protected by your own cloud account security.',
            ),
            _buildSection(
              context,
              'DATA COLLECTION',
              'SpendX does not collect personal financial data on external servers. We do not track your identity or sell your information.',
            ),
            _buildSection(
              context,
              'AI FEATURES',
              'AI tools analyze your financial data locally to generate insights. When using AI Chat, only relevant transaction context is sent to AI models for analysis.',
            ),
            _buildSection(
              context,
              'USER CONTROL',
              'Users can export, backup, or delete their financial data anytime. You have full ownership of your financial records.',
            ),
            const SizedBox(height: 40),
            Center(
              child: Text(
                'Last Updated: March 2026',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.5),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, String content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            content,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 15,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
