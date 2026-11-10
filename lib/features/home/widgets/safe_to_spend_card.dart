import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../data/providers.dart' show safeToSpendProvider;
import '../../../data/repositories/reminder_repo.dart';
import '../../../domain/finance/safe_to_spend.dart';
import '../../../screens/expense/add_expense_screen.dart';
import '../../../services/haptic_service.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../shared/widgets/glass/spendx_glass_sheet.dart';
import '../../../utils/app_format.dart';

/// The Organic Money Journey Scene.
///
/// Embodies the core SpendX visual metaphor: "Your money moving through the month as a journey."
///
/// Features:
/// 1. An open, cardless canvas that blends seamlessly into the warm background.
/// 2. An organic, gently curved trail connecting Today -> Next Bill -> Inflow -> Month End.
/// 3. Calm, human financial copy that separates status from positive amounts (no alarming red).
class SafeToSpendCard extends ConsumerStatefulWidget {
  const SafeToSpendCard({super.key});

  @override
  ConsumerState<SafeToSpendCard> createState() => _SafeToSpendCardState();
}

class _SafeToSpendCardState extends ConsumerState<SafeToSpendCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat(reverse: true);

    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOutSine,
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stsAsync = ref.watch(safeToSpendProvider);

    return stsAsync.when(
      data: (calc) => _buildOrganicJourneyScene(context, calc, isDark),
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: SizedBox(
          height: 220,
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Text(
          'Taking a gentle pause. Your records are safe.',
          style: TextStyle(
            fontSize: 13,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildOrganicJourneyScene(
    BuildContext context,
    SafeToSpendCalculation calc,
    bool isDark,
  ) {
    final now = DateTime.now();
    final monthName = DateFormat('MMMM').format(now).toUpperCase();
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final hasShortfall = calc.hasShortfall;
    final safeAmount = calc.safeToSpend.toRupees;
    final shortfallAmount = calc.cashflowShortfall.toRupees;

    // Upcoming commitment milestones (the branches)
    CommitmentItem? nextBill;
    CommitmentItem? secondBill;
    int daysUntilBill = 0;
    if (calc.commitmentItems.isNotEmpty) {
      nextBill = calc.commitmentItems.first;
      if (calc.commitmentItems.length > 1) {
        secondBill = calc.commitmentItems[1];
      }
      final today = DateTime(now.year, now.month, now.day);
      final itemDay = DateTime(
        nextBill.dueDate.year,
        nextBill.dueDate.month,
        nextBill.dueDate.day,
      );
      daysUntilBill = itemDay.difference(today).inDays;
    }

    final isOverdue = nextBill != null && (nextBill.isOverdue || daysUntilBill < 0);
    final overdueDays = daysUntilBill.abs();
    final otherBillsCount = calc.commitmentItems.length - 1;
    final otherSuffix = otherBillsCount > 0 ? " (+$otherBillsCount more)" : "";

    // Human copy — calm, accurate, encouraging (no negative days)
    final String statusLine;
    final double displayAmount;
    final String amountCaption;

    if (hasShortfall) {
      if (nextBill != null) {
        if (isOverdue) {
          statusLine = overdueDays == 0
              ? "${nextBill.title} is due today$otherSuffix"
              : "${nextBill.title} is $overdueDays ${overdueDays == 1 ? 'day' : 'days'} overdue$otherSuffix";
        } else if (daysUntilBill == 0) {
          statusLine = "${nextBill.title} is due today$otherSuffix";
        } else if (daysUntilBill == 1) {
          statusLine = "Next bill is tomorrow: ${nextBill.title}$otherSuffix";
        } else {
          statusLine = "$daysUntilBill days until ${nextBill.title}$otherSuffix";
        }
      } else {
        statusLine = "Keeping spending steady this week";
      }
      displayAmount = shortfallAmount.abs();
      amountCaption = isOverdue
          ? "unpaid obligations need coverage"
          : "to cover before then";
    } else if (safeAmount > 0) {
      if (nextBill != null) {
        if (isOverdue) {
          statusLine = overdueDays == 0
              ? "${nextBill.title} is due today$otherSuffix"
              : "${nextBill.title} is $overdueDays ${overdueDays == 1 ? 'day' : 'days'} overdue$otherSuffix";
        } else if (daysUntilBill == 0) {
          statusLine = "${nextBill.title} is due today$otherSuffix";
        } else if (daysUntilBill == 1) {
          statusLine = "Tomorrow: ${nextBill.title}$otherSuffix";
        } else {
          statusLine = "$daysUntilBill days until ${nextBill.title}$otherSuffix";
        }
      } else {
        statusLine = "Clear sailing through the week";
      }
      displayAmount = safeAmount;
      amountCaption = isOverdue
          ? "comfortable to spend after settling overdue bills"
          : "comfortable to spend until your next bill";
    } else {
      statusLine = "Fresh cycle starting";
      displayAmount = 0.0;
      amountCaption = "breathing room ready";
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Month Label ──
          Text(
            monthName,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.2,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
            ),
          ),

          const SizedBox(height: 12),

          // ── Organic Curved Journey Trail (Custom Painter, no card boundary) ──
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, _) {
              return SizedBox(
                height: 100,
                width: double.infinity,
                child: CustomPaint(
                  painter: _OrganicPathPainter(
                    now: now,
                    daysInMonth: daysInMonth,
                    nextBill: nextBill,
                    secondBill: secondBill,
                    hasShortfall: hasShortfall,
                    pulse: _pulseAnimation.value,
                    isDark: isDark,
                  ),
                  child: _buildInteractiveOverlay(
                    context: context,
                    now: now,
                    daysInMonth: daysInMonth,
                    nextBill: nextBill,
                    secondBill: secondBill,
                    allCommitments: calc.commitmentItems,
                    isDark: isDark,
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 16),

          // ── Status Headline (Tappable for Milestone Details) ──
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: calc.commitmentItems.isNotEmpty
                ? () => _showCommitmentDetails(context, calc.commitmentItems, isDark)
                : () => _showBreakdownSheet(context, calc, isDark),
            child: Container(
              width: double.infinity,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    statusLine,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF44403C),
                      letterSpacing: -0.2,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 15,
                    color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          // ── Positive, Dignified Amount (No scary negative sign) ──
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showBreakdownSheet(context, calc, isDark),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '₹',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white.withValues(alpha: 0.9) : const Color(0xFF1C1917),
                  ),
                ),
                const SizedBox(width: 2),
                Text(
                  AppFormat.currency(displayAmount).replaceAll('₹', '').trim(),
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.0,
                    color: isDark ? Colors.white : const Color(0xFF1C1917),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 4),

          // ── Amount Purpose Caption ──
          Text(
            amountCaption,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
            ),
          ),

          // ── Unambiguous Safe-to-Spend Status Indicator ──
          if (hasShortfall)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF22161A) : const Color(0xFFFBF1EE),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? const Color(0x40E05260) : const Color(0x35F87171),
                  width: 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.pause_circle_outline_rounded,
                    size: 13,
                    color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFE11D48),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Discretionary spending on pause',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFBE123C),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// Interactive touch targets positioned over the visual nodes
  Widget _buildInteractiveOverlay({
    required BuildContext context,
    required DateTime now,
    required int daysInMonth,
    required CommitmentItem? nextBill,
    required CommitmentItem? secondBill,
    required List<CommitmentItem> allCommitments,
    required bool isDark,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        // Node X coordinates
        final x0 = w * 0.12;
        final x1 = w * 0.40;
        final x2 = w * 0.68;
        final x3 = w * 0.90;

        final isNextOverdue = nextBill != null && (nextBill.isOverdue || nextBill.daysUntil < 0);
        final nextDaysUntil = nextBill?.daysUntil ?? 0;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Node 1: Today
            Positioned(
              left: x0 - 32,
              top: 52,
              child: SizedBox(
                width: 64,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Today",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                      ),
                    ),
                    Text(
                      '${now.day} ${DateFormat('MMM').format(now)}',
                      style: TextStyle(
                        fontSize: 9,
                        color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Node 2: Primary Milestone (Next / Overdue Bill)
            Positioned(
              left: x1 - 50,
              top: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: nextBill != null
                    ? () => _showCommitmentDetails(context, allCommitments, isDark)
                    : null,
                child: Container(
                  width: 100,
                  height: 95,
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 36), // Clearance below diamond node
                      Text(
                        nextBill != null
                            ? (isNextOverdue
                                ? 'OVERDUE'
                                : nextDaysUntil == 0
                                    ? 'DUE TODAY'
                                    : 'Next bill')
                            : 'Milestone',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: isNextOverdue
                              ? const Color(0xFFE11D48)
                              : nextDaysUntil == 0
                                  ? const Color(0xFFD97706)
                                  : (isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706)),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      Text(
                        nextBill != null
                            ? (isNextOverdue
                                ? '${nextDaysUntil.abs()}d ago'
                                : DateFormat('d MMM').format(nextBill.dueDate))
                            : '14d',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: isNextOverdue
                              ? (isDark ? const Color(0xFFFCA5A5) : const Color(0xFFBE123C))
                              : (isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Node 3: Second Milestone / Inflow
            Positioned(
              left: x2 - 45,
              top: 35,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: secondBill != null
                    ? () => _showCommitmentDetails(context, allCommitments, isDark)
                    : null,
                child: SizedBox(
                  width: 90,
                  height: 60,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 25),
                      Text(
                        secondBill != null ? "Upcoming" : "Inflow",
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: secondBill != null
                              ? (isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5))
                              : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      Text(
                        secondBill != null
                            ? DateFormat('d MMM').format(secondBill.dueDate)
                            : '${now.add(const Duration(days: 14)).day} ${DateFormat('MMM').format(now.add(const Duration(days: 14)))}',
                        style: TextStyle(
                          fontSize: 9,
                          color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Node 4: Month End
            Positioned(
              left: x3 - 36,
              top: 48,
              child: SizedBox(
                width: 72,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Month end",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    Text(
                      '$daysInMonth ${DateFormat('MMM').format(now)}',
                      style: TextStyle(
                        fontSize: 9,
                        color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showCommitmentDetails(
    BuildContext context,
    List<CommitmentItem> commitments,
    bool isDark,
  ) {
    HapticService.instance.tap();
    final overdue = commitments.where((c) => c.isOverdue || c.daysUntil < 0).toList();
    final upcoming = commitments.where((c) => !c.isOverdue && c.daysUntil >= 0).toList();

    SpendXGlassSheet.show(
      context: context,
      title: 'Scheduled Obligations (${commitments.length})',
      builder: (sheetContext) {
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (overdue.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFFE11D48),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'OVERDUE OBLIGATIONS (${overdue.length})',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                          color: Color(0xFFE11D48),
                        ),
                      ),
                    ],
                  ),
                ),
                ...overdue.map((c) => _buildCommitmentTile(context, sheetContext, c, isDark, isOverdue: true)),
                const SizedBox(height: 12),
              ],
              if (upcoming.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Text(
                    'UPCOMING IN 14 DAYS (${upcoming.length})',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                    ),
                  ),
                ),
                ...upcoming.map((c) => _buildCommitmentTile(context, sheetContext, c, isDark, isOverdue: false)),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildCommitmentTile(
    BuildContext rootContext,
    BuildContext sheetContext,
    CommitmentItem c,
    bool isDark, {
    required bool isOverdue,
  }) {
    final daysUntil = c.daysUntil;
    final String dueLabel = isOverdue
        ? '${daysUntil.abs()}d overdue • ${DateFormat('d MMM').format(c.dueDate)}'
        : daysUntil == 0
            ? 'Due today'
            : daysUntil == 1
                ? 'Due tomorrow'
                : 'Due in ${daysUntil}d • ${DateFormat('d MMM').format(c.dueDate)}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isOverdue
            ? (isDark ? const Color(0xFF2A151A) : const Color(0xFFFFF1F2))
            : (isDark ? const Color(0xFF1A1F2C) : const Color(0xFFFAF7F2)),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isOverdue
              ? (isDark ? const Color(0x60E11D48) : const Color(0x50FCA5A5))
              : (isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFEBE5D8)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isOverdue
                      ? const Color(0xFFE11D48).withValues(alpha: 0.15)
                      : const Color(0xFFD97706).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  c.type == 'credit_card'
                      ? Icons.credit_card_rounded
                      : Icons.calendar_today_rounded,
                  size: 16,
                  color: isOverdue ? const Color(0xFFE11D48) : const Color(0xFFD97706),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : const Color(0xFF1C1917),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      dueLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isOverdue
                            ? (isDark ? const Color(0xFFFCA5A5) : const Color(0xFFE11D48))
                            : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                AppFormat.currency(c.amount.toRupees),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: isOverdue
                      ? const Color(0xFFE11D48)
                      : (isDark ? const Color(0xFFFCA5A5) : const Color(0xFFE11D48)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (c.id != null)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: const Color(0xFF16A34A),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                  icon: const Icon(Icons.check_circle_outline_rounded, size: 14),
                  label: const Text('Mark Paid', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  onPressed: () async {
                    HapticService.instance.tap();
                    Navigator.of(sheetContext).pop();
                    await ReminderRepo().markReminderPaid(c.id!);
                    ref.invalidate(safeToSpendProvider);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${c.title} marked as paid ✓'),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  side: BorderSide(
                    color: isDark ? const Color(0xFF4F46E5) : const Color(0xFF6366F1),
                    width: 1.0,
                  ),
                  foregroundColor: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                ),
                icon: const Icon(Icons.payment_rounded, size: 14),
                label: const Text('Pay / Log', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                onPressed: () {
                  HapticService.instance.tap();
                  Navigator.of(sheetContext).pop();
                  final initialType = c.type == 'credit_card' ? 'credit_payment' : 'expense';
                  Navigator.push(
                    rootContext,
                    AppPageRoute(
                      builder: (_) => AddExpenseScreen(
                        initialType: initialType,
                        prefillData: {
                          'amount': c.amount.toRupees.toStringAsFixed(2),
                          'notes': 'Payment towards ${c.title}',
                        },
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showBreakdownSheet(
    BuildContext context,
    SafeToSpendCalculation calc,
    bool isDark,
  ) {
    HapticService.instance.tap();
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
                'Safe-to-Spend protects you by shielding your non-negotiable upcoming 14-day commitments and active goal earmarks from your liquid cash to determine your true discretionary runway.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF57534E),
                ),
              ),
              const SizedBox(height: 20),
              _buildBreakdownRow('Total Liquid Assets', calc.liquidAssets.toRupees, isDark, isPositive: true),
              _buildBreakdownRow('14-Day Commitments', calc.knownCommitments14d.toRupees, isDark, isNegative: true),
              if (calc.commitmentItems.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1A1F2C) : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: Column(
                    children: calc.commitmentItems.map((item) {
                      final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
                      final itemDay = DateTime(item.dueDate.year, item.dueDate.month, item.dueDate.day);
                      final diff = itemDay.difference(today).inDays;
                      final dueStr = diff == 0 ? 'Due today' : diff < 0 ? '${diff.abs()}d overdue' : 'Due in ${diff}d';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.payment_rounded,
                              size: 14,
                              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${item.title} ($dueStr)',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                  color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
                                ),
                              ),
                            ),
                            Text(
                              '-${AppFormat.currency(item.amount.toRupees.abs())}',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFE11D48),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
              _buildBreakdownRow('Active Goal Earmarks', calc.activeEarmarks.toRupees, isDark, isNegative: true),
              Divider(
                color: isDark ? Colors.white.withValues(alpha: 0.10) : const Color(0xFFE2E8F0),
                height: 24,
              ),
              if (calc.hasShortfall)
                _buildBreakdownRow(
                  'Liquidity Shortfall',
                  calc.cashflowShortfall.toRupees,
                  isDark,
                  isDeficit: true,
                )
              else
                _buildBreakdownRow(
                  'Discretionary Cash',
                  calc.safeToSpend.toRupees,
                  isDark,
                  isSafeToSpend: true,
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
    bool isSafeToSpend = false,
    bool isDeficit = false,
  }) {
    Color amountColor;
    if (isDeficit) {
      amountColor = isDark ? const Color(0xFFF87171) : const Color(0xFFE11D48);
    } else if (isSafeToSpend) {
      amountColor = isDark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A);
    } else {
      amountColor = isDark ? Colors.white : const Color(0xFF0F172A);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: isSafeToSpend || isDeficit ? 14 : 13,
              fontWeight: isSafeToSpend || isDeficit ? FontWeight.w700 : FontWeight.w500,
              color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155),
            ),
          ),
          Text(
            '${isNegative && amount > 0 ? "- " : ""}${AppFormat.currency(amount)}',
            style: TextStyle(
              fontSize: isSafeToSpend || isDeficit ? 16 : 13.5,
              fontWeight: isSafeToSpend || isDeficit ? FontWeight.w800 : FontWeight.w600,
              color: amountColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter for the organic curved journey trail
class _OrganicPathPainter extends CustomPainter {
  final DateTime now;
  final int daysInMonth;
  final CommitmentItem? nextBill;
  final CommitmentItem? secondBill;
  final bool hasShortfall;
  final double pulse;
  final bool isDark;

  _OrganicPathPainter({
    required this.now,
    required this.daysInMonth,
    required this.nextBill,
    this.secondBill,
    required this.hasShortfall,
    required this.pulse,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;

    // Key trail anchor coordinates
    final p0 = Offset(w * 0.12, 38); // Today
    final p1 = Offset(w * 0.40, 22); // Next Bill / Overdue
    final p2 = Offset(w * 0.68, 54); // Second Bill or Inflow
    final p3 = Offset(w * 0.90, 34); // Month end

    // ── 1. Draw Active Path (p0 -> p1) with Smooth Spline ──
    final activePath = Path()..moveTo(p0.dx, p0.dy);
    activePath.cubicTo(
      p0.dx + (p1.dx - p0.dx) * 0.45,
      p0.dy - 8,
      p1.dx - (p1.dx - p0.dx) * 0.45,
      p1.dy + 4,
      p1.dx,
      p1.dy,
    );

    final isOverdue = nextBill != null && (nextBill!.isOverdue || nextBill!.daysUntil < 0);

    final activePaint = Paint()
      ..shader = LinearGradient(
        colors: [
          const Color(0xFF4F46E5),
          isOverdue
              ? const Color(0xFFE11D48)
              : hasShortfall
                  ? (isDark ? const Color(0xFFF59E0B) : const Color(0xFFD97706))
                  : (isDark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A)),
        ],
      ).createShader(Rect.fromPoints(p0, p1))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(activePath, activePaint);

    // ── 2. Draw Future Tranquil Path (p1 -> p2 -> p3) ──
    final futurePath = Path()..moveTo(p1.dx, p1.dy);
    futurePath.cubicTo(
      p1.dx + (p2.dx - p1.dx) * 0.45,
      p1.dy + 8,
      p2.dx - (p2.dx - p1.dx) * 0.45,
      p2.dy - 6,
      p2.dx,
      p2.dy,
    );
    futurePath.cubicTo(
      p2.dx + (p3.dx - p2.dx) * 0.45,
      p2.dy - 4,
      p3.dx - (p3.dx - p2.dx) * 0.45,
      p3.dy + 4,
      p3.dx,
      p3.dy,
    );

    final futurePaint = Paint()
      ..color = isDark
          ? Colors.white.withValues(alpha: 0.15)
          : const Color(0xFFDDD6C9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(futurePath, futurePaint);

    // ── 3. Draw Node 1: Today (Glowing Concentric Pulsing Halo) ──
    final haloRadius = 13.0 + (pulse * 3.5);
    final haloPaint = Paint()
      ..color = const Color(0xFF4F46E5).withValues(alpha: 0.15 + (pulse * 0.10))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(p0, haloRadius, haloPaint);

    final todayBorderPaint = Paint()
      ..color = const Color(0xFF818CF8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(p0, 7.5, todayBorderPaint);

    final todayCenterPaint = Paint()
      ..color = const Color(0xFF4F46E5)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(p0, 5.0, todayCenterPaint);

    // ── 4. Draw Node 2: Milestone Shape (Faceted Diamond ◇) ──
    final diamondRadius = 7.5;
    final diamondPath = Path()
      ..moveTo(p1.dx, p1.dy - diamondRadius)
      ..lineTo(p1.dx + diamondRadius, p1.dy)
      ..lineTo(p1.dx, p1.dy + diamondRadius)
      ..lineTo(p1.dx - diamondRadius, p1.dy)
      ..close();

    final diamondHaloColor = isOverdue
        ? const Color(0xFFE11D48).withValues(alpha: 0.25 + (pulse * 0.15))
        : (isDark ? const Color(0xFFF59E0B) : const Color(0xFFD97706))
            .withValues(alpha: 0.20);

    final diamondStrokeColor = isOverdue
        ? const Color(0xFFE11D48)
        : (isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706));

    final diamondHalo = Paint()
      ..color = diamondHaloColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(p1, 12, diamondHalo);

    final diamondFill = Paint()
      ..color = isDark ? const Color(0xFF1E2330) : Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawPath(diamondPath, diamondFill);

    final diamondStroke = Paint()
      ..color = diamondStrokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    canvas.drawPath(diamondPath, diamondStroke);

    // Inner diamond dot
    final innerDot = Paint()
      ..color = diamondStrokeColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(p1, 2.5, innerDot);

    // ── 5. Draw Node 3: Second Milestone or Inflow Node ──
    if (secondBill != null) {
      final smRadius = 6.0;
      final smPath = Path()
        ..moveTo(p2.dx, p2.dy - smRadius)
        ..lineTo(p2.dx + smRadius, p2.dy)
        ..lineTo(p2.dx, p2.dy + smRadius)
        ..lineTo(p2.dx - smRadius, p2.dy)
        ..close();

      final smHalo = Paint()
        ..color = const Color(0xFF4F46E5).withValues(alpha: 0.18)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(p2, 10, smHalo);

      final smFill = Paint()
        ..color = isDark ? const Color(0xFF1E2330) : Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawPath(smPath, smFill);

      final smStroke = Paint()
        ..color = isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawPath(smPath, smStroke);

      final smDot = Paint()
        ..color = isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(p2, 2.0, smDot);
    } else {
      final inflowFill = Paint()
        ..color = isDark ? const Color(0xFF1E2330) : Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(p2, 5.5, inflowFill);

      final inflowBorder = Paint()
        ..color = isDark ? const Color(0xFF64748B) : const Color(0xFFA8A29E)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8;
      canvas.drawCircle(p2, 5.5, inflowBorder);
    }

    // ── 6. Draw Node 4: Month End Open Ring ○ ──
    final monthEndFill = Paint()
      ..color = isDark ? const Color(0xFF161922) : const Color(0xFFFAF7F2)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(p3, 6.0, monthEndFill);

    final monthEndBorder = Paint()
      ..color = isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawCircle(p3, 6.0, monthEndBorder);
  }

  @override
  bool shouldRepaint(covariant _OrganicPathPainter oldDelegate) {
    return oldDelegate.pulse != pulse ||
        oldDelegate.now != now ||
        oldDelegate.nextBill != nextBill ||
        oldDelegate.secondBill != secondBill ||
        oldDelegate.hasShortfall != hasShortfall ||
        oldDelegate.isDark != isDark;
  }
}
