import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/providers.dart' show safeToSpendProvider;
import '../../../domain/finance/safe_to_spend.dart';
import '../../../shared/widgets/spendx_glass.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/app_format.dart';

/// Primary Decision Hero on the Home Dashboard.
///
/// Implements Section 6 of C15-A-R1:
/// - Floating Hero Glass Material (Material 2 — Elevated Glass)
/// - Environmental background visible through it
/// - Deep blur (sigma 24) with edge specular highlight & ambient depth shadow
/// - Dominant whole-number financial typography (₹24,850)
/// - Subordinate 14-day discretionary runway context
/// - Interactive tap-to-expand glass breakdown bottom sheet
class SafeToSpendCard extends ConsumerWidget {
  const SafeToSpendCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stsAsync = ref.watch(safeToSpendProvider);

    return stsAsync.when(
      data: (calc) => _buildHero(context, calc, isDark),
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SpendXGlassSurface(
          level: SpendXGlassLevel.elevated,
          height: 180,
          child: const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SpendXGlassCard(
          level: SpendXGlassLevel.elevated,
          color: AppTheme.semanticExpense.withValues(alpha: 0.12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SAFE TO SPEND',
                style: AppTextStyles.caption.copyWith(
                  color: AppTheme.semanticExpense,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Unable to compute liquidity safely',
                style: AppTextStyles.body.copyWith(
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHero(BuildContext context, SafeToSpendCalculation calc, bool isDark) {
    final hasShortfall = calc.hasShortfall;
    final safeAmount = calc.safeToSpend.toRupees;
    final shortfallAmount = calc.cashflowShortfall.toRupees;

    // Shortfall gradient vs standard healthy elevated glass gradient
    final Gradient? customGradient = hasShortfall
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [
                    Color(0x4D4A1520), // ~30% danger rose
                    Color(0x2820080E), // ~16%
                  ]
                : const [
                    Color(0x55FFE4E6),
                    Color(0x35FFF1F2),
                  ],
          )
        : null;

    final Border? customBorder = hasShortfall
        ? Border.all(
            color: AppTheme.semanticShortfall.withValues(alpha: isDark ? 0.6 : 0.4),
            width: 0.75,
          )
        : null;

    return SpendXGlassCard(
      level: SpendXGlassLevel.elevated,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      padding: const EdgeInsets.all(20),
      gradient: customGradient,
      border: customBorder,
      onTap: () => _showBreakdownSheet(context, calc, isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: Title & Info Pill ─────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: hasShortfall
                          ? AppTheme.semanticShortfall
                          : AppTheme.semanticIncome,
                      boxShadow: [
                        BoxShadow(
                          color: (hasShortfall
                                  ? AppTheme.semanticShortfall
                                  : AppTheme.semanticIncome)
                              .withValues(alpha: 0.6),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'SAFE TO SPEND',
                    style: AppTextStyles.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                      color: hasShortfall
                          ? AppTheme.semanticShortfall
                          : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569)),
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.black.withValues(alpha: 0.08),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '14 Days',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 13,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Large Financial Typography ────────────────────
          if (hasShortfall) ...[
            SpendXFinancialAmount(
              amount: shortfallAmount,
              semanticType: FinancialSemanticType.shortfall,
              size: FinancialAmountSize.hero,
              prefix: '-₹',
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 14,
                  color: AppTheme.semanticShortfall,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'Shortfall: Known commitments exceed available liquid cash.',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.semanticShortfall,
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            SpendXFinancialAmount(
              amount: safeAmount,
              semanticType: FinancialSemanticType.neutral,
              size: FinancialAmountSize.hero,
            ),
            const SizedBox(height: 5),
            Text(
              'Available discretionary runway after upcoming commitments',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              ),
            ),
          ],

          const SizedBox(height: 18),

          // ── Translucent Hairline Divider ──────────────────
          Container(
            height: 0.5,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  isDark
                      ? Colors.white.withValues(alpha: 0.15)
                      : Colors.black.withValues(alpha: 0.10),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),

          const SizedBox(height: 14),

          // ── Secondary Liquidity Breakdown Strip ───────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMiniMetric(
                label: 'Liquid Cash',
                amount: calc.liquidAssets.toRupees,
                isDark: isDark,
              ),
              Container(
                width: 0.5,
                height: 24,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.black.withValues(alpha: 0.08),
              ),
              _buildMiniMetric(
                label: '14d Bills',
                amount: calc.knownCommitments14d.toRupees,
                isDark: isDark,
                prefix: '-',
              ),
              Container(
                width: 0.5,
                height: 24,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.black.withValues(alpha: 0.08),
              ),
              _buildMiniMetric(
                label: 'Earmarks',
                amount: calc.activeEarmarks.toRupees,
                isDark: isDark,
                prefix: '-',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniMetric({
    required String label,
    required double amount,
    required bool isDark,
    String? prefix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${prefix ?? ''}${AppFormat.currency(amount)}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : const Color(0xFF0F172A),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  void _showBreakdownSheet(BuildContext context, SafeToSpendCalculation calc, bool isDark) {
    SpendXGlassSheet.show(
      context: context,
      title: 'Safe-to-Spend Breakdown',
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Safe-to-Spend deducts non-negotiable 14-day recurring commitments and goal earmarks from your liquid cash to calculate your true discretionary spending runway.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                ),
              ),
              const SizedBox(height: 20),
              _buildBreakdownRow('Total Liquid Cash', calc.liquidAssets.toRupees, isDark, isPositive: true),
              _buildBreakdownRow('14-Day Commitments', calc.knownCommitments14d.toRupees, isDark, isNegative: true),
              _buildBreakdownRow('Active Goal Earmarks', calc.activeEarmarks.toRupees, isDark, isNegative: true),
              const Divider(height: 28),
              _buildBreakdownRow(
                calc.hasShortfall ? 'Liquidity Shortfall' : 'Safe to Spend',
                calc.hasShortfall ? calc.cashflowShortfall.toRupees : calc.safeToSpend.toRupees,
                isDark,
                isBold: true,
                color: calc.hasShortfall ? AppTheme.semanticShortfall : AppTheme.semanticIncome,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBreakdownRow(
    String label,
    double amount,
    bool isDark, {
    bool isPositive = false,
    bool isNegative = false,
    bool isBold = false,
    Color? color,
  }) {
    final prefix = isPositive ? '+ ' : (isNegative ? '- ' : '');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: isBold ? FontWeight.w700 : FontWeight.w500,
              color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
            ),
          ),
          Text(
            '$prefix${AppFormat.currency(amount)}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: isBold ? FontWeight.w700 : FontWeight.w600,
              color: color ?? (isDark ? Colors.white : const Color(0xFF0F172A)),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
