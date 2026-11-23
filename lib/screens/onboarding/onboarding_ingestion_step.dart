part of '../onboarding_screen.dart';

extension _OnboardingIngestionStep on _OnboardingScreenState {
  Widget _buildAutomaticIngestionScreen(bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Autonomous Ingestion',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'SpendX can capture your transactions instantly using local Android events. Configure your ingestion streams below:',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
            ),
          ),
          const SizedBox(height: 20),

          // 1. Payment App Notification Listener (UPI Push Capture)
          SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.notifications_active_rounded, color: AppTheme.primaryBlue, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'Payment App Notifications',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _statusPill(_notificationListenerEnabled, isDark),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Instantly captures UPI payments from Google Pay, PhonePe, Paytm, and Cred push notifications in real-time before SMS arrives.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (!_notificationListenerEnabled)
                  SpendXGlassButton(
                    variant: SpendXGlassButtonVariant.tonal,
                    onPressed: () async {
                      await LiveSmsService.instance.openNotificationListenerSettings();
                      await _checkPermissions();
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.tune_rounded, size: 16, color: AppTheme.primaryBlue),
                        SizedBox(width: 6),
                        Text('Enable Notification Listener', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.semanticIncome.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.semanticIncome),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Active: Capturing payments from GPay, PhonePe & Paytm',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.semanticIncome),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 2. Bank & Card SMS Ingestion
          SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.sms_rounded, color: Color(0xFF10B981), size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'Bank & Card Transaction SMS',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _statusPill(_smsPermissionGranted, isDark),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Parses official banking SMS from HDFCBK, ICICIB, SBIINB, etc. to attribute debits, credits, and refunds. Personal contacts and OTPs are completely ignored.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (!_smsPermissionGranted)
                  SpendXGlassButton(
                    variant: SpendXGlassButtonVariant.tonal,
                    onPressed: () async {
                      await Permission.sms.request();
                      await _checkPermissions();
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.lock_open_rounded, size: 16, color: Color(0xFF10B981)),
                        SizedBox(width: 6),
                        Text('Grant SMS Permission', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.semanticIncome.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.semanticIncome),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Active: Monitoring official bank and card SMS',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.semanticIncome),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 3. Alerts & Due Date System Notifications
          SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.alarm_rounded, color: Color(0xFFF59E0B), size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'Bill Reminders & Runway Alerts',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _statusPill(_systemNotificationsEnabled, isDark),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Receive proactive warnings for upcoming credit card bill due dates, loan EMI installments, and safe-to-spend runway thresholds.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (!_systemNotificationsEnabled)
                  SpendXGlassButton(
                    variant: SpendXGlassButtonVariant.tonal,
                    onPressed: () async {
                      await NotificationServiceV2().requestPermissions();
                      await _checkPermissions();
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.notifications_active_rounded, size: 16, color: Color(0xFFF59E0B)),
                        SizedBox(width: 6),
                        Text('Allow System Notifications', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.semanticIncome.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.semanticIncome),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Active: Bill reminders and runway alerts enabled',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.semanticIncome),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 4. Unrestricted Battery Execution (FuntouchOS / OriginOS / MIUI / HyperOS)
          SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF8B5CF6).withValues(alpha: isDark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.battery_charging_full_rounded, color: Color(0xFF8B5CF6), size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'Unrestricted Background Battery',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _statusPill(_batteryOptimizationIgnored, isDark),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Prevents OEM aggressive battery managers (Vivo FuntouchOS, OriginOS, MIUI) from terminating live notification listeners and SMS parsers when the screen is locked.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (!_batteryOptimizationIgnored)
                  SpendXGlassButton(
                    variant: SpendXGlassButtonVariant.tonal,
                    onPressed: () async {
                      await Permission.ignoreBatteryOptimizations.request();
                      await _checkPermissions();
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.bolt_rounded, size: 16, color: Color(0xFF8B5CF6)),
                        SizedBox(width: 6),
                        Text('Unrestrict Battery Usage', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.semanticIncome.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.semanticIncome),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Active: Unrestricted background execution enabled',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.semanticIncome),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(bool isEnabled, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isEnabled
            ? const Color(0x1F10B981)
            : (isDark ? const Color(0x22FFFFFF) : const Color(0x18000000)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isEnabled ? 'Active ✓' : 'Setup',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: isEnabled
              ? AppTheme.semanticIncome
              : (isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted),
        ),
      ),
    );
  }

  // ── 4. Encrypted Google Drive Backup ───────────────────────

}
