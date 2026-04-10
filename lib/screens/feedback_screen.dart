import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/spendx_app_bar.dart';
import '../widgets/settings_tile.dart';
import '../widgets/custom_snackbar.dart';

class FeedbackScreen extends StatelessWidget {
  const FeedbackScreen({super.key});

  static const _supportEmail = 'support@mashingdesigns.com';
  static const _playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.mashingdesigns.spend_x';

  Future<void> _rateApp(BuildContext context) async {
    try {
      final inAppReview = InAppReview.instance;
      if (await inAppReview.isAvailable()) {
        await inAppReview.requestReview();
      } else {
        // Fallback: open Play Store
        await launchUrl(Uri.parse(_playStoreUrl),
            mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (context.mounted) {
        CustomSnackBar.show(context,
            message: 'Could not open review. Try the Play Store directly.',
            isError: true);
      }
    }
  }

  Future<void> _shareApp() async {
    await SharePlus.instance.share(
      ShareParams(
        text: 'Check out SpendX — a privacy-first personal finance tracker!\n\n'
            '$_playStoreUrl',
        subject: 'SpendX — Finance, Simplified',
      ),
    );
  }

  Future<void> _sendFeedback(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    final body = Uri.encodeComponent(
      '\n\n---\n'
      'App: ${info.appName} v${info.version} (${info.buildNumber})\n'
      'Platform: Android\n',
    );
    final uri = Uri.parse(
        'mailto:$_supportEmail?subject=SpendX%20Feedback&body=$body');
    try {
      await launchUrl(uri);
    } catch (e) {
      if (context.mounted) {
        // Copy email to clipboard as fallback
        await Clipboard.setData(const ClipboardData(text: _supportEmail));
        if (context.mounted) {
          CustomSnackBar.show(context,
              message: 'Email copied to clipboard: $_supportEmail');
        }
      }
    }
  }

  Future<void> _reportBug(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    final body = Uri.encodeComponent(
      '\n\nDescribe the bug:\n'
      '1. What happened?\n'
      '2. What did you expect?\n'
      '3. Steps to reproduce:\n\n'
      '---\n'
      'App: ${info.appName} v${info.version} (${info.buildNumber})\n'
      'Platform: Android\n',
    );
    final uri = Uri.parse(
        'mailto:$_supportEmail?subject=SpendX%20Bug%20Report&body=$body');
    try {
      await launchUrl(uri);
    } catch (e) {
      if (context.mounted) {
        await Clipboard.setData(const ClipboardData(text: _supportEmail));
        if (context.mounted) {
          CustomSnackBar.show(context,
              message: 'Email copied to clipboard: $_supportEmail');
        }
      }
    }
  }

  Future<void> _requestFeature(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    final body = Uri.encodeComponent(
      '\n\nFeature request:\n\n'
      'What would you like SpendX to do?\n\n'
      '---\n'
      'App: ${info.appName} v${info.version} (${info.buildNumber})\n',
    );
    final uri = Uri.parse(
        'mailto:$_supportEmail?subject=SpendX%20Feature%20Request&body=$body');
    try {
      await launchUrl(uri);
    } catch (e) {
      if (context.mounted) {
        await Clipboard.setData(const ClipboardData(text: _supportEmail));
        if (context.mounted) {
          CustomSnackBar.show(context,
              message: 'Email copied to clipboard: $_supportEmail');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: const SpendXAppBar(title: 'Feedback & Support'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      cs.primary.withValues(alpha: 0.15),
                      cs.tertiary.withValues(alpha: 0.1),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(Icons.chat_bubble_outline_rounded,
                          color: cs.primary, size: 28),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('We\'d love to hear from you',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Text(
                            'Your feedback helps us improve SpendX for everyone.',
                            style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 13,
                                height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ── Rate & Share ────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text('SPREAD THE WORD',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                        color: cs.primary)),
              ),
              SettingsTile(
                icon: Icons.star_rounded,
                color: Colors.amber,
                title: 'Rate SpendX',
                subtitle: 'Love it? Give us 5 stars on Play Store',
                onTap: () => _rateApp(context),
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.share_rounded,
                color: cs.primary,
                title: 'Share SpendX',
                subtitle: 'Tell your friends about SpendX',
                onTap: _shareApp,
              ),

              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),

              // ── Feedback ───────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text('GET IN TOUCH',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                        color: cs.primary)),
              ),
              SettingsTile(
                icon: Icons.feedback_outlined,
                color: Colors.teal,
                title: 'Send Feedback',
                subtitle: 'Share thoughts, suggestions, or compliments',
                onTap: () => _sendFeedback(context),
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.bug_report_outlined,
                color: Colors.red,
                title: 'Report a Bug',
                subtitle: 'Found something broken? Let us know',
                onTap: () => _reportBug(context),
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.lightbulb_outline,
                color: Colors.purple,
                title: 'Request a Feature',
                subtitle: 'Tell us what you\'d like SpendX to do',
                onTap: () => _requestFeature(context),
              ),

              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),

              // ── Contact Info ────────────────────────
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(Icons.email_outlined,
                        color: cs.onSurfaceVariant, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Contact Email',
                              style: TextStyle(
                                  color: cs.onSurfaceVariant, fontSize: 12)),
                          const SizedBox(height: 2),
                          Text(_supportEmail,
                              style: TextStyle(
                                  color: cs.primary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () async {
                        await Clipboard.setData(
                            const ClipboardData(text: _supportEmail));
                        if (context.mounted) {
                          CustomSnackBar.show(context,
                              message: 'Email copied to clipboard');
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
