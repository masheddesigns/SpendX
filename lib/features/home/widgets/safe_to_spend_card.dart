import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/core/app_database.dart';
import '../../../data/core/tables.dart';
import '../../../data/providers.dart'
    show
        safeToSpendProvider,
        cardsProvider,
        accountsProvider,
        remindersProvider;
import '../../../data/repositories/credit_repo.dart';
import '../../../data/repositories/recurring_repo.dart';
import '../../../data/repositories/reminder_repo.dart';
import '../../../domain/finance/safe_to_spend.dart';
import '../../../screens/credit_card/pay_credit_card_screen.dart';
import '../../../screens/expense/add_expense_screen.dart';
import '../../../services/data_change_bus.dart';
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
  bool _motionConfigured = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );

    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOutSine,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionConfigured) return;
    _motionConfigured = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulseController.value = 0.5;
    } else {
      _pulseController.repeat(reverse: true);
    }
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
            color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final timelineHeight = 100.0 + ((textScale - 1).clamp(0.0, 1.0) * 32.0);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final monthName = DateFormat('MMMM').format(now).toUpperCase();
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final hasShortfall = calc.hasShortfall;
    final safeAmount = calc.safeToSpend.toRupees;
    final shortfallAmount = calc.cashflowShortfall.toRupees;

    // ── Strict Chronological Partitioning of Obligations ──
    final overdueItems = calc.commitmentItems.where((c) {
      final due = DateTime(c.dueDate.year, c.dueDate.month, c.dueDate.day);
      return c.isOverdue || due.isBefore(today);
    }).toList();

    final dueTodayItems = calc.commitmentItems.where((c) {
      final due = DateTime(c.dueDate.year, c.dueDate.month, c.dueDate.day);
      return !c.isOverdue && due.isAtSameMomentAs(today);
    }).toList();

    final futureItems = calc.commitmentItems.where((c) {
      final due = DateTime(c.dueDate.year, c.dueDate.month, c.dueDate.day);
      return !c.isOverdue && due.isAfter(today);
    }).toList()..sort((a, b) => a.dueDate.compareTo(b.dueDate));

    // The forward journey nodes strictly track FUTURE milestones
    final CommitmentItem? nextBill = futureItems.firstOrNull;
    final CommitmentItem? secondBill = futureItems.length > 1
        ? futureItems[1]
        : null;

    final hasOverdue = overdueItems.isNotEmpty;
    final hasDueToday = dueTodayItems.isNotEmpty;

    // Human copy — calm, accurate, prioritized
    final String statusLine;
    final double displayAmount;
    final String amountCaption;

    if (hasOverdue) {
      final primary = overdueItems.first;
      final itemDay = DateTime(
        primary.dueDate.year,
        primary.dueDate.month,
        primary.dueDate.day,
      );
      final overdueDays = today.difference(itemDay).inDays;
      final remainingCount = calc.commitmentItems.length - 1;
      final suffix = remainingCount > 0 ? " (+$remainingCount more)" : "";
      statusLine =
          "${primary.title} is $overdueDays ${overdueDays == 1 ? 'day' : 'days'} overdue$suffix";
      final overdueTotal = overdueItems.fold<double>(
        0.0,
        (sum, i) => sum + i.amount.toRupees,
      );
      displayAmount = overdueTotal > 0 ? overdueTotal : primary.amount.toRupees;
      amountCaption = "unpaid obligations need coverage";
    } else if (hasDueToday) {
      final primary = dueTodayItems.first;
      final remainingCount = calc.commitmentItems.length - 1;
      final suffix = remainingCount > 0 ? " (+$remainingCount more)" : "";
      statusLine = "${primary.title} is due today$suffix";
      displayAmount = hasShortfall ? shortfallAmount.abs() : safeAmount;
      amountCaption = hasShortfall
          ? "to cover before end of day"
          : "comfortable to spend after today's bills";
    } else if (nextBill != null) {
      final itemDay = DateTime(
        nextBill.dueDate.year,
        nextBill.dueDate.month,
        nextBill.dueDate.day,
      );
      final daysUntilBill = itemDay.difference(today).inDays;
      final remainingCount = futureItems.length - 1;
      final suffix = remainingCount > 0 ? " (+$remainingCount more)" : "";
      if (daysUntilBill == 1) {
        statusLine = "Tomorrow: ${nextBill.title}$suffix";
      } else {
        statusLine = "$daysUntilBill days until ${nextBill.title}$suffix";
      }
      displayAmount = hasShortfall ? shortfallAmount.abs() : safeAmount;
      amountCaption = hasShortfall
          ? "to cover before then"
          : "comfortable to spend until your next bill";
    } else {
      statusLine = "Clear sailing through the week";
      displayAmount = safeAmount;
      amountCaption = safeAmount > 0
          ? "comfortable to spend"
          : "breathing room ready";
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
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: 12),

          // ── Organic Curved Journey Trail (Custom Painter, no card boundary) ──
          AnimatedBuilder(
            animation: _pulseAnimation,
            child: _buildInteractiveOverlay(
              context: context,
              now: now,
              daysInMonth: daysInMonth,
              nextBill: nextBill,
              secondBill: secondBill,
              hasDueToday: hasDueToday,
              allCommitments: calc.commitmentItems,
              isDark: isDark,
            ),
            builder: (context, staticOverlay) {
              return SizedBox(
                height: timelineHeight,
                width: double.infinity,
                child: CustomPaint(
                  painter: _OrganicPathPainter(
                    now: now,
                    daysInMonth: daysInMonth,
                    nextBill: nextBill,
                    secondBill: secondBill,
                    hasShortfall: hasShortfall,
                    hasOverdue: hasOverdue,
                    hasDueToday: hasDueToday,
                    pulse: _pulseAnimation.value,
                    colorScheme: Theme.of(context).colorScheme,
                  ),
                  child: staticOverlay,
                ),
              );
            },
          ),

          const SizedBox(height: 16),

          // ── Status Headline (Tappable for Milestone Details) ──
          Semantics(
            button: true,
            label: '$statusLine. Tap for details.',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: calc.commitmentItems.isNotEmpty
                  ? () => _showCommitmentDetails(
                      context,
                      calc.commitmentItems,
                      isDark,
                    )
                  : () => _showBreakdownSheet(context, calc, isDark),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(minHeight: 48),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        statusLine,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          letterSpacing: -0.2,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 15,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 8),

          // ── Positive, Dignified Amount (No scary negative sign) ──
          Semantics(
            button: true,
            label: 'Safe to spend: ${AppFormat.currency(displayAmount)}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: calc.commitmentItems.any((c) => c.isOverdue)
                    ? () => _showCommitmentDetails(
                        context,
                        calc.commitmentItems,
                        isDark,
                      )
                    : () => _showBreakdownSheet(context, calc, isDark),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
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
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.9)
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        AppFormat.currency(
                          displayAmount,
                        ).replaceAll('₹', '').trim(),
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.0,
                          color: isDark
                              ? Colors.white
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 4),

          // ── Amount Purpose Caption ──
          Text(
            amountCaption,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),

          // ── Overdue Obligations Alert Banner ──
          if (hasOverdue)
            Semantics(
              button: true,
              label: 'Overdue obligations. Tap to view.',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      _showCommitmentDetails(context, calc.commitmentItems, isDark),
                  child: Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).colorScheme.error.withValues(alpha: 0.4),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 13,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${overdueItems.length} overdue obligation${overdueItems.length > 1 ? 's require' : ' requires'} coverage',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
          else if (hasShortfall)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.error.withValues(alpha: 0.35),
                  width: 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.pause_circle_outline_rounded,
                    size: 13,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Discretionary spending on pause',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onErrorContainer,
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
    required bool hasDueToday,
    required List<CommitmentItem> allCommitments,
    required bool isDark,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final inflowLabelHeight =
            60.0 + ((textScale - 1).clamp(0.0, 1.0) * 24.0);
        // Node X coordinates
        final x0 = w * 0.12;
        final x1 = w * 0.40;
        final x2 = w * 0.68;
        final x3 = math.min(w * 0.90, w - 36);

        return Stack(
          fit: StackFit.expand,
          children: [
            // Node 1: Today
            Positioned(
              left: x0 - 45,
              top: 50,
              child: SizedBox(
                width: 90,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Today",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: hasDueToday
                            ? Theme.of(context).colorScheme.tertiary
                            : (Theme.of(context).colorScheme.primary),
                      ),
                    ),
                    Text(
                      hasDueToday
                          ? '${now.day} ${DateFormat('MMM').format(now)} • Due'
                          : '${now.day} ${DateFormat('MMM').format(now)}',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: hasDueToday
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: hasDueToday
                            ? (Theme.of(context).colorScheme.tertiary)
                            : (Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),

            // Node 2: Primary Milestone (Next Future Bill or Mid-cycle)
            Positioned(
              left: x1 - 50,
              top: 0,
              child: Semantics(
                button: nextBill != null,
                enabled: nextBill != null,
                label: nextBill != null
                    ? 'Next bill: ${DateFormat('d MMM').format(nextBill.dueDate)}'
                    : 'Milestone',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: nextBill != null
                      ? () => _showCommitmentDetails(
                          context,
                          allCommitments,
                          isDark,
                        )
                      : null,
                  child: Container(
                    width: 100,
                    height: 95,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          height: 36,
                        ), // Clearance below diamond node
                        Text(
                          nextBill != null ? 'Next bill' : 'Milestone',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Theme.of(context).colorScheme.tertiary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        Text(
                          nextBill != null
                              ? DateFormat('d MMM').format(nextBill.dueDate)
                              : '${now.add(const Duration(days: 7)).day} ${DateFormat('MMM').format(now.add(const Duration(days: 7)))}',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Node 3: Second Milestone / Inflow
            Positioned(
              left: x2 - 45,
              top: 35,
              child: Semantics(
                button: secondBill != null,
                enabled: secondBill != null,
                label: secondBill != null
                    ? 'Upcoming: ${DateFormat('d MMM').format(secondBill.dueDate)}'
                    : 'Inflow',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: secondBill != null
                      ? () => _showCommitmentDetails(
                          context,
                          allCommitments,
                          isDark,
                        )
                      : null,
                  child: SizedBox(
                    width: 90,
                    height: inflowLabelHeight,
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
                                ? (Theme.of(context).colorScheme.primary)
                                : (Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        Text(
                          secondBill != null
                              ? DateFormat('d MMM').format(secondBill.dueDate)
                              : '${now.add(const Duration(days: 14)).day} ${DateFormat('MMM').format(now.add(const Duration(days: 14)))}',
                          style: TextStyle(
                            fontSize: 9,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
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
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    Text(
                      '$daysInMonth ${DateFormat('MMM').format(now)}',
                      style: TextStyle(
                        fontSize: 9,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final overdue = commitments.where((c) {
      final due = DateTime(c.dueDate.year, c.dueDate.month, c.dueDate.day);
      return c.isOverdue || due.isBefore(today);
    }).toList();
    final dueToday = commitments.where((c) {
      final due = DateTime(c.dueDate.year, c.dueDate.month, c.dueDate.day);
      return !c.isOverdue && due.isAtSameMomentAs(today);
    }).toList();
    final upcoming = commitments.where((c) {
      final due = DateTime(c.dueDate.year, c.dueDate.month, c.dueDate.day);
      return !c.isOverdue && due.isAfter(today);
    }).toList()..sort((a, b) => a.dueDate.compareTo(b.dueDate));

    SpendXGlassSheet.show(
      context: context,
      title: 'Scheduled Obligations (${commitments.length})',
      builder: (sheetContext) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (overdue.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'OVERDUE OBLIGATIONS (${overdue.length})',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
              ...overdue.map(
                (c) => _buildCommitmentTile(
                  context,
                  sheetContext,
                  c,
                  isDark,
                  isOverdue: true,
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (dueToday.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.tertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'DUE TODAY (${dueToday.length})',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                  ],
                ),
              ),
              ...dueToday.map(
                (c) => _buildCommitmentTile(
                  context,
                  sheetContext,
                  c,
                  isDark,
                  isOverdue: false,
                ),
              ),
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ...upcoming.map(
                (c) => _buildCommitmentTile(
                  context,
                  sheetContext,
                  c,
                  isDark,
                  isOverdue: false,
                ),
              ),
            ],
          ],
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
            ? (Theme.of(context).colorScheme.errorContainer)
            : (Theme.of(context).colorScheme.surfaceContainer),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isOverdue
              ? Theme.of(context).colorScheme.error.withValues(alpha: 0.32)
              : (isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Theme.of(context).colorScheme.outline),
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
                      ? Theme.of(
                          context,
                        ).colorScheme.error.withValues(alpha: 0.15)
                      : Theme.of(
                          context,
                        ).colorScheme.tertiary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  c.type == 'credit_card'
                      ? Icons.credit_card_rounded
                      : Icons.calendar_today_rounded,
                  size: 16,
                  color: isOverdue
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.tertiary,
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
                        color: isDark
                            ? Colors.white
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      dueLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isOverdue
                            ? (Theme.of(context).colorScheme.error)
                            : (Theme.of(context).colorScheme.onSurfaceVariant),
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
                      ? Theme.of(context).colorScheme.error
                      : (Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 4,
            children: [
              if (c.id != null || c.type == 'credit_card') ...[
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                  icon: const Icon(Icons.cancel_outlined, size: 14),
                  label: const Text(
                    'Cancelled',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  onPressed: () async {
                    HapticService.instance.tap();
                    Navigator.of(sheetContext).pop();
                    final db = await AppDatabase.instance.database;
                    final prefs = await SharedPreferences.getInstance();

                    if (c.type == 'credit_card') {
                      String targetCardId = c.id ?? '';
                      try {
                        final allCards = await CreditRepo().getAll();
                        final match = allCards
                            .where(
                              (card) =>
                                  card.id == targetCardId ||
                                  card.name.toLowerCase() ==
                                      c.title.toLowerCase() ||
                                  ReminderRepo.areMerchantsEquivalent(
                                    card.name,
                                    c.title,
                                  ) ||
                                  (card.bank.isNotEmpty &&
                                      c.title.toLowerCase().contains(
                                        card.bank.toLowerCase(),
                                      )),
                            )
                            .firstOrNull;
                        if (match != null) targetCardId = match.id;
                      } catch (_) {}

                      if (targetCardId.isNotEmpty) {
                        await db.rawUpdate(
                          'UPDATE ${Tables.creditCards} SET last_statement_balance = 0 WHERE id = ?',
                          [targetCardId],
                        );
                        final cycleKey =
                            'card_settled_${targetCardId}_${c.dueDate.year}_${c.dueDate.month}';
                        await prefs.setBool(cycleKey, true);

                        await db.rawUpdate(
                          '''
                          UPDATE ${Tables.reminders}
                          SET is_completed = 1, record_status = 'done'
                          WHERE linked_entity_id = ? OR id = ? OR id = ?
                        ''',
                          [targetCardId, c.id, 'credit_due_$targetCardId'],
                        );
                      }
                      if (c.id != null) {
                        try {
                          await ReminderRepo().deleteGlobalReminder(c.id!);
                        } catch (_) {}
                      }
                    } else if (c.type == 'recurring') {
                      try {
                        final recRepo = RecurringRepo();
                        final allRec = await recRepo.getAll();
                        for (final rec in allRec) {
                          if (rec.id == c.id ||
                              rec.name.toLowerCase() == c.title.toLowerCase() ||
                              ReminderRepo.areMerchantsEquivalent(
                                rec.name,
                                c.title,
                              )) {
                            await recRepo.update(rec.copyWith(isActive: false));
                          }
                        }
                      } catch (_) {}
                      if (c.id != null) {
                        final cycleKey =
                            'recurring_settled_${c.id}_${c.dueDate.year}_${c.dueDate.month}';
                        await prefs.setBool(cycleKey, true);
                      }
                    } else {
                      if (c.id != null) {
                        await ReminderRepo().deleteGlobalReminder(c.id!);
                      }
                      try {
                        final recRepo = RecurringRepo();
                        final allRec = await recRepo.getAll();
                        for (final rec in allRec) {
                          if (rec.name.toLowerCase().contains(
                                c.title.toLowerCase(),
                              ) ||
                              c.title.toLowerCase().contains(
                                rec.name.toLowerCase(),
                              )) {
                            await recRepo.update(rec.copyWith(isActive: false));
                          }
                        }
                      } catch (_) {}
                    }
                    ref.invalidate(safeToSpendProvider);
                    ref.invalidate(cardsProvider);
                    ref.invalidate(remindersProvider);
                    DataChangeBus.instance.notify();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '${c.title} obligation cancelled & removed ✓',
                          ),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Theme.of(context).colorScheme.secondary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                  ),
                  icon: const Icon(
                    Icons.check_circle_outline_rounded,
                    size: 14,
                  ),
                  label: const Text(
                    'Mark Paid',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  onPressed: () async {
                    HapticService.instance.tap();
                    Navigator.of(sheetContext).pop();
                    final db = await AppDatabase.instance.database;
                    final prefs = await SharedPreferences.getInstance();

                    if (c.type == 'credit_card') {
                      String targetCardId = c.id ?? '';
                      try {
                        final allCards = await CreditRepo().getAll();
                        final match = allCards
                            .where(
                              (card) =>
                                  card.id == targetCardId ||
                                  card.name.toLowerCase() ==
                                      c.title.toLowerCase() ||
                                  ReminderRepo.areMerchantsEquivalent(
                                    card.name,
                                    c.title,
                                  ) ||
                                  (card.bank.isNotEmpty &&
                                      c.title.toLowerCase().contains(
                                        card.bank.toLowerCase(),
                                      )),
                            )
                            .firstOrNull;
                        if (match != null) targetCardId = match.id;
                      } catch (_) {}

                      if (targetCardId.isNotEmpty) {
                        await db.rawUpdate(
                          'UPDATE ${Tables.creditCards} SET last_statement_balance = 0 WHERE id = ?',
                          [targetCardId],
                        );
                        final cycleKey =
                            'card_settled_${targetCardId}_${c.dueDate.year}_${c.dueDate.month}';
                        await prefs.setBool(cycleKey, true);

                        await db.rawUpdate(
                          '''
                          UPDATE ${Tables.reminders}
                          SET is_completed = 1, record_status = 'done', last_triggered_at = ?
                          WHERE linked_entity_id = ? OR id = ? OR id = ?
                        ''',
                          [
                            DateTime.now().toIso8601String(),
                            targetCardId,
                            c.id,
                            'credit_due_$targetCardId',
                          ],
                        );
                      }
                      if (c.id != null) {
                        try {
                          await ReminderRepo().markReminderPaid(c.id!);
                        } catch (_) {}
                      }
                    } else if (c.type == 'recurring') {
                      if (c.id != null) {
                        final cycleKey =
                            'recurring_settled_${c.id}_${c.dueDate.year}_${c.dueDate.month}';
                        await prefs.setBool(cycleKey, true);
                      }
                    } else {
                      if (c.id != null) {
                        await ReminderRepo().markReminderPaid(c.id!);
                      }
                      try {
                        final allCards = await CreditRepo().getAll();
                        final matchedCard = allCards
                            .where(
                              (card) =>
                                  card.name.toLowerCase() ==
                                      c.title.toLowerCase() ||
                                  ReminderRepo.areMerchantsEquivalent(
                                    card.name,
                                    c.title,
                                  ),
                            )
                            .firstOrNull;
                        if (matchedCard != null) {
                          await db.rawUpdate(
                            'UPDATE ${Tables.creditCards} SET last_statement_balance = 0 WHERE id = ?',
                            [matchedCard.id],
                          );
                          await prefs.setBool(
                            'card_settled_${matchedCard.id}_${c.dueDate.year}_${c.dueDate.month}',
                            true,
                          );
                        }
                      } catch (_) {}
                    }

                    ref.invalidate(safeToSpendProvider);
                    ref.invalidate(cardsProvider);
                    ref.invalidate(accountsProvider);
                    ref.invalidate(remindersProvider);
                    DataChangeBus.instance.notify();

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
              ],
              const SizedBox(width: 6),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  side: BorderSide(
                    color: isDark
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.primary,
                    width: 1.0,
                  ),
                  foregroundColor: Theme.of(context).colorScheme.primary,
                ),
                icon: const Icon(Icons.payment_rounded, size: 14),
                label: const Text(
                  'Pay / Log',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                onPressed: () async {
                  HapticService.instance.tap();
                  Navigator.of(sheetContext).pop();

                  if (c.type == 'credit_card') {
                    try {
                      final allCards = await CreditRepo().getAll();
                      final matchedCard = allCards
                          .where(
                            (card) =>
                                card.id == c.id ||
                                card.name.toLowerCase() ==
                                    c.title.toLowerCase() ||
                                ReminderRepo.areMerchantsEquivalent(
                                  card.name,
                                  c.title,
                                ) ||
                                (card.bank.isNotEmpty &&
                                    c.title.toLowerCase().contains(
                                      card.bank.toLowerCase(),
                                    )),
                          )
                          .firstOrNull;

                      if (matchedCard != null && rootContext.mounted) {
                        final paid = await Navigator.push<bool>(
                          rootContext,
                          AppPageRoute(
                            builder: (_) => PayCreditCardScreen(
                              card: matchedCard,
                              outstanding: c.amount.toRupees,
                            ),
                          ),
                        );
                        if (paid == true) {
                          ref.invalidate(safeToSpendProvider);
                          ref.invalidate(cardsProvider);
                          ref.invalidate(accountsProvider);
                          ref.invalidate(remindersProvider);
                          DataChangeBus.instance.notify();
                        }
                        return;
                      }
                    } catch (_) {}
                  }

                  if (!rootContext.mounted) return;
                  final logged = await Navigator.push<bool>(
                    rootContext,
                    AppPageRoute(
                      builder: (_) => AddExpenseScreen(
                        initialType: 'expense',
                        prefillData: {
                          'amount': c.amount.toRupees.toStringAsFixed(2),
                          'notes': 'Payment towards ${c.title}',
                        },
                      ),
                    ),
                  );
                  if (logged == true) {
                    if (c.id != null) {
                      await ReminderRepo().markReminderPaid(c.id!);
                    }
                    ref.invalidate(safeToSpendProvider);
                    ref.invalidate(remindersProvider);
                    DataChangeBus.instance.notify();
                  }
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
                  color: isDark
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              _buildBreakdownRow(
                'Total Liquid Assets',
                calc.liquidAssets.toRupees,
                isDark,
                isPositive: true,
              ),
              _buildBreakdownRow(
                '14-Day Commitments',
                calc.knownCommitments14d.toRupees,
                isDark,
                isNegative: true,
              ),
              if (calc.commitmentItems.any((c) => c.isOverdue)) ...[
                Builder(
                  builder: (_) {
                    final overdueSum = calc.commitmentItems
                        .where((c) => c.isOverdue)
                        .fold<double>(0.0, (sum, i) => sum + i.amount.toRupees);
                    return Padding(
                      padding: const EdgeInsets.only(
                        left: 4,
                        top: 2,
                        bottom: 4,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 13,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'Includes ${AppFormat.currency(overdueSum)} in overdue obligations',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
              if (calc.commitmentItems.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  child: Column(
                    children: [
                      ...calc.commitmentItems.map((item) {
                        final today = DateTime(
                          DateTime.now().year,
                          DateTime.now().month,
                          DateTime.now().day,
                        );
                        final itemDay = DateTime(
                          item.dueDate.year,
                          item.dueDate.month,
                          item.dueDate.day,
                        );
                        final diff = itemDay.difference(today).inDays;
                        final dueStr = diff == 0
                            ? 'Due today'
                            : diff < 0
                            ? '${diff.abs()}d overdue'
                            : 'Due in ${diff}d';
                        final isOverdue = diff < 0;
                        return Semantics(
                          button: true,
                          label: '${item.title}, $dueStr, ${AppFormat.currency(item.amount.toRupees.abs())}',
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                            child: InkWell(
                              onTap: () {
                                Navigator.of(ctx).pop();
                                _showCommitmentDetails(
                                  context,
                                  calc.commitmentItems,
                                  isDark,
                                );
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                  horizontal: 4,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      item.type == 'credit_card'
                                          ? Icons.credit_card_rounded
                                          : Icons.payment_rounded,
                                      size: 14,
                                      color: isOverdue
                                          ? Theme.of(context).colorScheme.error
                                          : (Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${item.title} ($dueStr)',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w500,
                                          color: isOverdue
                                              ? (Theme.of(
                                                  context,
                                                ).colorScheme.error)
                                              : (Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant),
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '-${AppFormat.currency(item.amount.toRupees.abs())}',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                        color: Theme.of(context).colorScheme.error,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Icon(
                                      Icons.chevron_right_rounded,
                                      size: 14,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 6),
                      Semantics(
                        button: true,
                        label: 'Manage obligations',
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                          child: GestureDetector(
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _showCommitmentDetails(
                                context,
                                calc.commitmentItems,
                                isDark,
                              );
                            },
                            child: Center(
                              child: Text(
                                'Tap any obligation above to cancel or mark as paid →',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              _buildBreakdownRow(
                'Active Goal Earmarks',
                calc.activeEarmarks.toRupees,
                isDark,
                isNegative: true,
              ),
              Divider(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Theme.of(context).colorScheme.outline,
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
      amountColor = Theme.of(context).colorScheme.error;
    } else if (isSafeToSpend) {
      amountColor = Theme.of(context).colorScheme.secondary;
    } else {
      amountColor = Theme.of(context).colorScheme.onSurface;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isSafeToSpend || isDeficit ? 14 : 13,
                fontWeight: isSafeToSpend || isDeficit
                    ? FontWeight.w700
                    : FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                '${isNegative && amount > 0 ? "- " : ""}${AppFormat.currency(amount)}',
                style: TextStyle(
                  fontSize: isSafeToSpend || isDeficit ? 16 : 13.5,
                  fontWeight: isSafeToSpend || isDeficit
                      ? FontWeight.w800
                      : FontWeight.w600,
                  color: amountColor,
                ),
              ),
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
  final bool hasOverdue;
  final bool hasDueToday;
  final double pulse;
  final ColorScheme colorScheme;

  _OrganicPathPainter({
    required this.now,
    required this.daysInMonth,
    required this.nextBill,
    this.secondBill,
    required this.hasShortfall,
    this.hasOverdue = false,
    this.hasDueToday = false,
    required this.pulse,
    required this.colorScheme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;

    // Key trail anchor coordinates
    final p0 = Offset(w * 0.12, 38); // Today
    final p1 = Offset(w * 0.40, 22); // Next Future Bill
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

    final activePaint = Paint()
      ..shader = LinearGradient(
        colors: [
          hasDueToday ? colorScheme.tertiary : colorScheme.primary,
          hasOverdue
              ? colorScheme.error
              : hasShortfall
              ? colorScheme.tertiary
              : colorScheme.secondary,
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
      ..color = colorScheme.outline.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(futurePath, futurePaint);

    // ── 3. Draw Node 1: Today (Glowing Concentric Pulsing Halo) ──
    final Color todayBaseColor = hasDueToday
        ? colorScheme.tertiary
        : (hasOverdue ? colorScheme.error : colorScheme.primary);
    final Color todayBorderColor = hasDueToday
        ? colorScheme.tertiary
        : (hasOverdue ? colorScheme.error : colorScheme.primary);

    final haloRadius = 13.0 + (pulse * 3.5);
    final haloPaint = Paint()
      ..color = todayBaseColor.withValues(alpha: 0.15 + (pulse * 0.10))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(p0, haloRadius, haloPaint);

    final todayBorderPaint = Paint()
      ..color = todayBorderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(p0, 7.5, todayBorderPaint);

    final todayCenterPaint = Paint()
      ..color = todayBaseColor
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

    final diamondHaloColor = colorScheme.tertiary.withValues(alpha: 0.20);
    final diamondStrokeColor = colorScheme.tertiary;

    final diamondHalo = Paint()
      ..color = diamondHaloColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(p1, 12, diamondHalo);

    final diamondFill = Paint()
      ..color = colorScheme.surfaceContainer
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
        ..color = colorScheme.primary.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(p2, 10, smHalo);

      final smFill = Paint()
        ..color = colorScheme.surfaceContainer
        ..style = PaintingStyle.fill;
      canvas.drawPath(smPath, smFill);

      final smStroke = Paint()
        ..color = colorScheme.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawPath(smPath, smStroke);

      final smDot = Paint()
        ..color = colorScheme.primary
        ..style = PaintingStyle.fill;
      canvas.drawCircle(p2, 2.0, smDot);
    } else {
      final inflowFill = Paint()
        ..color = colorScheme.surfaceContainer
        ..style = PaintingStyle.fill;
      canvas.drawCircle(p2, 5.5, inflowFill);

      final inflowBorder = Paint()
        ..color = colorScheme.onSurfaceVariant
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8;
      canvas.drawCircle(p2, 5.5, inflowBorder);
    }

    // ── 6. Draw Node 4: Month End Open Ring ○ ──
    final monthEndFill = Paint()
      ..color = colorScheme.surface
      ..style = PaintingStyle.fill;
    canvas.drawCircle(p3, 6.0, monthEndFill);

    final monthEndBorder = Paint()
      ..color = colorScheme.outline
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
        oldDelegate.colorScheme != colorScheme;
  }
}
