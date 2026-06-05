import 'dart:io';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../models/company.dart';
import '../../../utils/app_format.dart';
import '../../salary_ledger/salary_ledger_models.dart';
import '../../salary_ledger/salary_ledger_notifier.dart';
import '../services/salary_pdf_export.dart';
import '../../../shared/widgets/skeleton_loader.dart';
import '../../../shared/widgets/error_state_widget.dart';
import '../widgets/salary_analytics_card.dart';
import 'month_detail_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../shared/widgets/app_tap_scale.dart';

// ═══════════════════════════════════════════════════════════════════════════
// ENTRY POINT
// ═══════════════════════════════════════════════════════════════════════════

class SalaryScreen extends ConsumerWidget {
  const SalaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(salaryLedgerProvider);

    return async.when(
      loading: () => const Scaffold(body: SkeletonLoader.summary()),
      error: (e, _) => Scaffold(
        body: ErrorStateWidget(
          error: e,
          onRetry: () => ref.invalidate(salaryLedgerProvider),
        ),
      ),
      data: (state) {
        if (!state.hasCompanies) return const _EmptyState();
        return _CompanyDashboard(state: state);
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// EMPTY STATE
// ═══════════════════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      
      appBar: AppBar(
          title: Text('Salary'), backgroundColor: Colors.transparent),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.business_rounded,
                  size: 64,
                  color: Colors.blueAccent.withValues(alpha: 0.4)),
              const SizedBox(height: 16),
              Text('No income source added',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface)),
              const SizedBox(height: 8),
              Text('Add your employer, freelance client, or income source to start tracking',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
              const SizedBox(height: 24),
              Consumer(
                builder: (context, ref, _) => FilledButton.icon(
                  onPressed: () => _showSetupSheet(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('Add Company'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    minimumSize: const Size(200, 48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// COMPANY DASHBOARD
// ═══════════════════════════════════════════════════════════════════════════

class _CompanyDashboard extends ConsumerWidget {
  final SalaryLedgerState state;
  const _CompanyDashboard({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final company = state.selectedCompany;
    final health = ref.watch(companyHealthProvider);
    final filteredMonths = ref.watch(filteredSalaryMonthsProvider);
    final report = ref.watch(salaryReportProvider);

    return Scaffold(
      
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── App Bar ──────────────────────────────────────
          SliverAppBar(
            floating: true,
            backgroundColor: Colors.transparent,
            title: const Text('Salary'),
            actions: [
              if (state.hasMonths)
                IconButton(
                  icon: const Icon(Icons.ios_share_rounded, size: 20),
                  tooltip: 'Export',
                  onPressed: () => _showExportSheet(
                      context, ref, state, filteredMonths),
                ),
              IconButton(
                icon: const Icon(Icons.add_business_rounded),
                tooltip: 'Add Company',
                onPressed: () => _showSetupSheet(context, ref),
              ),
            ],
          ),

          // ── Company Chips ────────────────────────────────
          if (state.companies.length > 1)
            SliverToBoxAdapter(
                child: _CompanyChips(
                    companies: state.companies,
                    selectedId: state.selectedCompanyId)),

          // ── Company Header ───────────────────────────────
          if (company != null)
            SliverToBoxAdapter(child: _CompanyHeader(company: company)),

          // ── Smart Alerts ─────────────────────────────────
          const SliverToBoxAdapter(child: _SmartAlerts()),

          // ── KPI Row ──────────────────────────────────────
          SliverToBoxAdapter(child: _KpiRow(report: report)),

          // ── Reliability Score ────────────────────────────
          if (state.hasMonths)
            SliverToBoxAdapter(child: _ReliabilityCard(health: health)),

          // ── Filter Chips ─────────────────────────────────
          if (state.hasMonths)
            SliverToBoxAdapter(child: _FilterChips()),

          // ── Analytics Chart ──────────────────────────────
          if (filteredMonths.length > 1)
            const SliverToBoxAdapter(child: SalaryAnalyticsCard()),

          // ── Month List ───────────────────────────────────
          if (filteredMonths.isNotEmpty)
            _MonthList(months: filteredMonths)
          else if (state.hasMonths)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                    child: Text('No months match this filter',
                        style: TextStyle(color: Colors.grey))),
              ),
            )
          else
            const SliverFillRemaining(
              child: Center(
                  child: Text('No salary months yet',
                      style: TextStyle(color: Colors.grey))),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// COMPANY CHIPS
// ═══════════════════════════════════════════════════════════════════════════

class _CompanyChips extends ConsumerWidget {
  final List<Company> companies;
  final String? selectedId;
  const _CompanyChips({required this.companies, required this.selectedId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: companies
            .map((c) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(c.name),
                    selected: c.id == selectedId,
                    onSelected: (_) => ref
                        .read(salaryLedgerProvider.notifier)
                        .selectCompany(c.id),
                  ),
                ))
            .toList(),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// COMPANY HEADER
// ═══════════════════════════════════════════════════════════════════════════

class _CompanyHeader extends StatelessWidget {
  final Company company;
  const _CompanyHeader({required this.company});

  Color _empColor(EmploymentType type) {
    switch (type) {
      case EmploymentType.fullTime:
        return Colors.blueAccent;
      case EmploymentType.partTime:
        return Colors.tealAccent;
      case EmploymentType.freelance:
        return Colors.purpleAccent;
      case EmploymentType.contract:
        return Colors.orangeAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final empColor = _empColor(company.employmentType);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(company.name,
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: empColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: empColor.withValues(alpha: 0.4)),
                ),
                child: Text(
                  company.payCycle == PayCycle.monthly
                      ? company.employmentLabel
                      : '${company.employmentLabel} \u00b7 ${company.payCycleLabel}',
                  style: TextStyle(
                    color: empColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
              company.employmentType == EmploymentType.freelance
                  ? 'Since ${DateFormat('MMM yyyy').format(company.createdAt)}'
                  : 'Joined ${DateFormat('MMM yyyy').format(company.createdAt)} \u00b7 Pay Day ${company.salaryCreditDay}',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// KPI ROW
// ═══════════════════════════════════════════════════════════════════════════

class _KpiRow extends StatelessWidget {
  final SalaryReport report;
  const _KpiRow({required this.report});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
              child: _KpiTile('Total Earned',
                  AppFormat.currency(report.totalPaid), Colors.greenAccent)),
          const SizedBox(width: 8),
          Expanded(
              child: _KpiTile('Pending',
                  AppFormat.currency(report.pending), Colors.orangeAccent)),
        ],
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  final String title;
  final String value;
  final Color color;
  const _KpiTile(this.title, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// RELIABILITY CARD
// ═══════════════════════════════════════════════════════════════════════════

class _ReliabilityCard extends StatelessWidget {
  final CompanyHealth health;
  const _ReliabilityCard({required this.health});

  @override
  Widget build(BuildContext context) {
    if (health.totalMonths == 0) return const SizedBox.shrink();

    final scoreColor = health.reliabilityScore >= 80
        ? Colors.greenAccent
        : health.reliabilityScore >= 50
            ? Colors.orangeAccent
            : Colors.redAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Employer Reliability',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(_reliabilityLabel(health.reliabilityScore),
                        style: TextStyle(
                            color: scoreColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
                const Spacer(),
                Text('${health.reliabilityScore.toStringAsFixed(0)}%',
                    style: TextStyle(
                        color: scoreColor,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: health.reliabilityScore / 100,
                backgroundColor: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation(scoreColor),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _miniStat(context, 'On Time', '${health.onTimePercent.toStringAsFixed(0)}%'),
                _miniStat(context, 'Avg Delay', '${health.avgDelayDays}d'),
                _miniStat(context, 'Late', '${health.lateMonths}'),
                _miniStat(context, 'Streak', '${health.longestDelayStreak}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _reliabilityLabel(double score) {
    if (score >= 90) return 'Excellent';
    if (score >= 70) return 'Stable';
    if (score >= 50) return 'Risky';
    return 'Unreliable';
  }

  Widget _miniStat(BuildContext context, String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 10)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// FILTER CHIPS
// ═══════════════════════════════════════════════════════════════════════════

class _FilterChips extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(salaryFilterProvider);
    final now = DateTime.now();

    // Period presets
    final last3Start = DateTime(now.year, now.month - 2, 1);
    final last6Start = DateTime(now.year, now.month - 5, 1);
    final isLast3 = filter.customRange != null &&
        filter.customRange!.start.isAtSameMomentAs(last3Start);
    final isLast6 = filter.customRange != null &&
        filter.customRange!.start.isAtSameMomentAs(last6Start);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          // Status filters
          _filterChip(context, ref, 'All', filter.status == null,
              () => ref.read(salaryFilterProvider.notifier).state =
                  filter.copyWith(clearStatus: true)),
          _filterChip(context, ref, 'Paid', filter.status == SalaryStatus.paid,
              () => ref.read(salaryFilterProvider.notifier).state =
                  filter.copyWith(status: SalaryStatus.paid)),
          _filterChip(context, ref, 'Partial',
              filter.status == SalaryStatus.partial,
              () => ref.read(salaryFilterProvider.notifier).state =
                  filter.copyWith(status: SalaryStatus.partial)),
          _filterChip(context, ref, 'Pending',
              filter.status == SalaryStatus.pending,
              () => ref.read(salaryFilterProvider.notifier).state =
                  filter.copyWith(status: SalaryStatus.pending)),

          const SizedBox(width: 8),
          Container(width: 1, height: 20, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 8),

          // Period filters
          _filterChip(context, ref, 'Last 3m', isLast3, () {
            if (isLast3) {
              ref.read(salaryFilterProvider.notifier).state =
                  filter.copyWith(clearRange: true);
            } else {
              ref.read(salaryFilterProvider.notifier).state = filter.copyWith(
                  customRange: DateTimeRange(start: last3Start, end: now),
                  clearFY: true);
            }
          }),
          _filterChip(context, ref, 'Last 6m', isLast6, () {
            if (isLast6) {
              ref.read(salaryFilterProvider.notifier).state =
                  filter.copyWith(clearRange: true);
            } else {
              ref.read(salaryFilterProvider.notifier).state = filter.copyWith(
                  customRange: DateTimeRange(start: last6Start, end: now),
                  clearFY: true);
            }
          }),

          // FY filter
          _filterChip(
              context,
              ref,
              FinancialYear.current().label,
              filter.fy == FinancialYear.current(),
              () => ref.read(salaryFilterProvider.notifier).state =
                  filter.fy == FinancialYear.current()
                      ? filter.copyWith(clearFY: true)
                      : filter.copyWith(
                          fy: FinancialYear.current(), clearRange: true)),

          // Custom range picker
          _filterChip(
              context,
              ref,
              filter.customRange != null && !isLast3 && !isLast6
                  ? '${DateFormat('MMM').format(filter.customRange!.start)}\u2013${DateFormat('MMM yy').format(filter.customRange!.end)}'
                  : 'Custom',
              filter.customRange != null && !isLast3 && !isLast6, () async {
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2015),
              lastDate: DateTime.now().add(const Duration(days: 365)),
              initialDateRange: filter.customRange ??
                  DateTimeRange(
                    start: DateTime(now.year, now.month - 5, 1),
                    end: now,
                  ),
            );
            if (picked != null) {
              ref.read(salaryFilterProvider.notifier).state = filter.copyWith(
                  customRange: picked, clearFY: true);
            }
          }),
        ],
      ),
    );
  }

  Widget _filterChip(BuildContext context, WidgetRef ref, String label,
      bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label,
            style: TextStyle(
                color: selected ? Colors.black : Colors.grey.shade300,
                fontSize: 12)),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: Colors.blueAccent,
        backgroundColor: const Color(0xFF2A2A2A),
        checkmarkColor: Colors.black,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
                color: selected
                    ? Colors.blueAccent
                    : Theme.of(context).colorScheme.outline)),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SMART ALERTS
// ═══════════════════════════════════════════════════════════════════════════

class _SmartAlerts extends ConsumerWidget {
  const _SmartAlerts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final months = ref.watch(
      salaryLedgerProvider.select((s) => s.valueOrNull?.months ?? []),
    );
    final health = ref.watch(companyHealthProvider);

    final now = DateTime.now();
    final alerts = <String>[];

    // Check for overdue payments
    final overdue = months
        .where((m) => m.status != SalaryStatus.paid && now.isAfter(m.month.dueDate))
        .toList();
    if (overdue.isNotEmpty) {
      final maxDelay = overdue.map((m) => m.delayDays).reduce(max);
      if (maxDelay >= 5) {
        final count = overdue.length;
        alerts.add(count == 1
            ? 'Salary delayed by $maxDelay days'
            : '$count salaries overdue (longest: ${maxDelay}d)');
      }
    }

    // Reliability warning — only meaningful after 6+ months
    if (health.totalMonths >= 6 && health.reliabilityScore < 60) {
      alerts.add(
          'Employer reliability: ${health.reliabilityScore.toStringAsFixed(0)}% — frequent late payments');
    }

    if (alerts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.orange.shade900.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: alerts
              .map((a) => Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Colors.orangeAccent, size: 14),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(a,
                              style: const TextStyle(
                                  color: Colors.orangeAccent, fontSize: 13)),
                        ),
                      ],
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MONTH LIST — Grouped by year, taps navigate to MonthDetailScreen
// ═══════════════════════════════════════════════════════════════════════════

class _MonthList extends StatelessWidget {
  final List<SalaryMonthView> months;
  const _MonthList({required this.months});

  List<Widget> _buildItems() {
    final items = <Widget>[];
    int? currentYear;
    for (final m in months) {
      final year = m.month.dueDate.year;
      if (year != currentYear) {
        currentYear = year;
        items.add(_YearHeader(year: year));
      }
      items.add(_MonthCard(month: m));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return SliverList(
      delegate: SliverChildListDelegate(_buildItems()),
    );
  }
}

class _YearHeader extends StatelessWidget {
  final int year;
  const _YearHeader({required this.year});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Text('$year',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5)),
          const SizedBox(width: 10),
          Expanded(child: Divider(color: Theme.of(context).colorScheme.outline, height: 1)),
        ],
      ),
    );
  }
}

class _MonthCard extends StatelessWidget {
  final SalaryMonthView month;
  const _MonthCard({required this.month});

  @override
  Widget build(BuildContext context) {
    final m = month;
    final monthDate = DateTime.tryParse('${m.month.month}-01');
    final monthName = monthDate != null
        ? DateFormat('MMMM yyyy').format(monthDate)
        : m.month.month;
    final dueLabel = DateFormat('dd MMM').format(m.month.dueDate);
    // Paid-but-late gets amber treatment
    final isLate = m.status == SalaryStatus.paid && m.delayDays > 0;

    return AppTapScale(
      onTap: () => Navigator.push(
          context,
          AppPageRoute(
              builder: (_) => MonthDetailScreen(monthId: m.month.id))),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isLate
              ? Colors.orange.shade900.withValues(alpha: 0.15)
              : _bgColor(m.status),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            _StatusDot(status: m.status, isLate: isLate),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(monthName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: Theme.of(context).colorScheme.onSurface)),
                  const SizedBox(height: 2),
                  Text(
                      m.month.expectedAmount <= 0
                          ? (m.totalPaid > 0
                              ? '${m.payments.length} payment${m.payments.length == 1 ? '' : 's'} received'
                              : 'No payments yet')
                          : isLate
                              ? 'Paid late \u00b7 due $dueLabel'
                              : '${m.status.label} \u00b7 due $dueLabel',
                      style: TextStyle(
                          color: m.month.expectedAmount <= 0
                              ? (m.totalPaid > 0 ? Colors.greenAccent : Colors.grey.shade500)
                              : isLate
                                  ? Colors.orangeAccent
                                  : _dotColor(m.status),
                          fontSize: 11)),
                ],
              ),
            ),
            if (m.bonusTotal > 0) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.purple.shade900.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('Bonus',
                    style: TextStyle(
                        color: Colors.purpleAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
            ],
            if (m.delayDays > 0) ...[
              Text('${m.delayDays}d late',
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 10)),
              const SizedBox(width: 8),
            ],
            Text(AppFormat.currency(m.totalPaid),
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.onSurface)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                color: Theme.of(context).colorScheme.outline, size: 18),
          ],
        ),
      ),
    );
  }

  Color _bgColor(SalaryStatus s) => switch (s) {
        SalaryStatus.pending =>
          Colors.red.shade900.withValues(alpha: 0.15),
        SalaryStatus.partial =>
          Colors.orange.shade900.withValues(alpha: 0.25),
        SalaryStatus.paid =>
          Colors.green.shade900.withValues(alpha: 0.25),
        SalaryStatus.onHold =>
          Colors.amber.shade900.withValues(alpha: 0.2),
        SalaryStatus.overdue =>
          Colors.red.shade900.withValues(alpha: 0.25),
      };

  Color _dotColor(SalaryStatus s) => switch (s) {
        SalaryStatus.pending => Colors.redAccent,
        SalaryStatus.partial => Colors.orangeAccent,
        SalaryStatus.paid => Colors.greenAccent,
        SalaryStatus.onHold => Colors.amber,
        SalaryStatus.overdue => Colors.red,
      };
}

class _StatusDot extends StatelessWidget {
  final SalaryStatus status;
  final bool isLate;
  const _StatusDot({required this.status, this.isLate = false});

  @override
  Widget build(BuildContext context) {
    final color = isLate
        ? Colors.orangeAccent
        : switch (status) {
            SalaryStatus.paid => Colors.greenAccent,
            SalaryStatus.partial => Colors.orangeAccent,
            SalaryStatus.pending => Colors.redAccent,
            SalaryStatus.onHold => Colors.amber,
            SalaryStatus.overdue => Colors.red,
          };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: (status == SalaryStatus.paid && !isLate)
            ? [
                BoxShadow(
                    color: Colors.green.withValues(alpha: 0.5),
                    blurRadius: 4,
                    spreadRadius: 1)
              ]
            : null,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// EXPORT
// ═══════════════════════════════════════════════════════════════════════════

Future<void> _exportCSV(BuildContext context, SalaryLedgerState state,
    List<SalaryMonthView> filteredMonths) async {
  try {
    final companyName = state.selectedCompany?.name ?? 'salary';
    final csv =
        generateSalaryCSV(filteredMonths, companyName: companyName);
    final dir = await getTemporaryDirectory();
    final safeName =
        companyName.replaceAll(RegExp(r'[^\w]'), '_').toLowerCase();
    final file = File('${dir.path}/${safeName}_salary_report.csv');
    await file.writeAsString(csv);

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: '$companyName Salary Report',
      ),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// EXPORT FILTER SHEET
// ═══════════════════════════════════════════════════════════════════════════

Future<void> _showExportSheet(BuildContext context, WidgetRef ref,
    SalaryLedgerState state, List<SalaryMonthView> filteredMonths) async {
  final result = await showModalBottomSheet<String>(
    context: context,
    
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) {
      final filter = ref.read(salaryFilterProvider);
      final hasFilter = filter.isActive;
      final currentCount = filteredMonths.length;
      final allCount = state.months.length;

      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
                child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outline,
                        borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            Text('Export Salary Report',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface)),
            const SizedBox(height: 16),

            // Scope selection
            if (hasFilter) ...[
              _ExportOption(
                label: 'Current View ($currentCount months)',
                subtitle: 'Filtered data only',
                icon: Icons.filter_alt_rounded,
                onTap: () => Navigator.pop(ctx, 'filtered_csv'),
              ),
              const SizedBox(height: 8),
            ],
            _ExportOption(
              label: 'All Data ($allCount months)',
              subtitle: 'Complete salary history',
              icon: Icons.table_chart_rounded,
              onTap: () => Navigator.pop(ctx, 'all_csv'),
            ),
            const SizedBox(height: 8),
            _ExportOption(
              label: 'PDF Report${hasFilter ? " (current view)" : ""}',
              subtitle: 'Professional document with charts',
              icon: Icons.picture_as_pdf_rounded,
              onTap: () => Navigator.pop(ctx, 'pdf'),
            ),
          ],
        ),
      );
    },
  );

  if (result == null || !context.mounted) return;

  try {
    switch (result) {
      case 'filtered_csv':
        await _exportCSV(context, state, filteredMonths);
      case 'all_csv':
        await _exportCSV(context, state, state.months);
      case 'pdf':
        await exportSalaryPDF(state, filteredMonths: filteredMonths);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }
}

class _ExportOption extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _ExportOption({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppTapScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.blueAccent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w500,
                          fontSize: 14)),
                  Text(subtitle,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Theme.of(context).colorScheme.outline, size: 20),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SETUP SHEET
// ═══════════════════════════════════════════════════════════════════════════

Future<void> _showSetupSheet(BuildContext context, WidgetRef ref) async {
  final result = await showModalBottomSheet<SetupSalaryInput>(
    context: context,
    isScrollControlled: true,
    
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => const _SetupCompanySheet(),
  );

  if (result != null && context.mounted) {
    await ref
        .read(salaryLedgerProvider.notifier)
        .setupCompanyAndSalary(result);
  }
}

/// Proper StatefulWidget — controllers created in initState, disposed in dispose.
/// No closure/rebuild issues.
class _SetupCompanySheet extends ConsumerStatefulWidget {
  const _SetupCompanySheet();

  @override
  ConsumerState<_SetupCompanySheet> createState() =>
      _SetupCompanySheetState();
}

class _SetupCompanySheetState extends ConsumerState<_SetupCompanySheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _salaryCtrl;
  late final TextEditingController _dayCtrl;
  DateTime _startDate = DateTime(DateTime.now().year, 1, 1);
  EmploymentType _empType = EmploymentType.fullTime;
  PayCycle _payCycle = PayCycle.monthly;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _salaryCtrl = TextEditingController();
    _dayCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _salaryCtrl.dispose();
    _dayCtrl.dispose();
    super.dispose();
  }

  double get _parsed => double.tryParse(_salaryCtrl.text) ?? 0;
  bool get _isFreelance =>
      _empType == EmploymentType.freelance;
  bool get _isValid {
    if (_nameCtrl.text.trim().isEmpty) return false;
    // Freelance: salary is optional (can be 0 = no fixed target)
    if (_isFreelance) return true;
    return _parsed > 0;
  }

  String get _salaryLabel {
    switch (_payCycle) {
      case PayCycle.monthly:
        return _empType == EmploymentType.partTime
            ? 'Monthly Salary (Part-time)'
            : 'Monthly Salary';
      case PayCycle.weekly:
        return 'Weekly Rate';
      case PayCycle.biWeekly:
        return 'Bi-Weekly Rate';
      case PayCycle.daily:
        return 'Daily Rate';
      case PayCycle.perProject:
        return 'Monthly Target (optional)';
    }
  }

  /// Available pay cycles based on employment type.
  /// Full-time/Part-time/Contract: monthly, weekly, biWeekly, daily
  /// Freelance: all including perProject
  List<PayCycle> get _availableCycles {
    if (_empType == EmploymentType.freelance) {
      return PayCycle.values; // all options
    }
    // Full-time, part-time, contract — no "per project"
    return [PayCycle.monthly, PayCycle.weekly, PayCycle.biWeekly, PayCycle.daily];
  }

  bool get _showPayDay =>
      _payCycle != PayCycle.daily && _payCycle != PayCycle.perProject;

  String get _dayLabel {
    if (_isFreelance && _payCycle == PayCycle.perProject) {
      return 'Typical Pay Day (1-28)';
    }
    return 'Pay Day (1-28)';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'When did you join?',
    );
    if (picked != null && mounted) {
      setState(
          () => _startDate = DateTime(picked.year, picked.month, 1));
    }
  }

  void _submit() {
    if (!_isValid) return;
    Navigator.pop(
        context,
        SetupSalaryInput(
          companyName: _nameCtrl.text.trim(),
          salary: _parsed,
          payDay: (int.tryParse(_dayCtrl.text) ?? 5).clamp(1, 28),
          startMonth:
              '${_startDate.year}-${_startDate.month.toString().padLeft(2, '0')}',
          employmentType: _empType,
          payCycle: _payCycle,
        ));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
              child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outline,
                      borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          Text('Add Income Source',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 20),

          // ── Employment Type ────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: EmploymentType.values.map((type) {
                final selected = _empType == type;
                final label = Company(name: '', salaryCreditDay: 1, employmentType: type).employmentLabel;
                final icons = {
                  EmploymentType.fullTime: Icons.business_rounded,
                  EmploymentType.partTime: Icons.schedule_rounded,
                  EmploymentType.freelance: Icons.laptop_mac_rounded,
                  EmploymentType.contract: Icons.assignment_rounded,
                };
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icons[type], size: 16,
                            color: selected
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Text(label),
                      ],
                    ),
                    selected: selected,
                    onSelected: (_) => setState(() => _empType = type),
                    selectedColor: Theme.of(context).colorScheme.primary,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    labelStyle: TextStyle(
                        color: selected
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    side: BorderSide(
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
                  ),
                );
              }).toList(),
            ),
          ),


          // ── Pay Cycle ─────────────────────────────────
          const SizedBox(height: 12),
          Text('Pay Cycle',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _availableCycles.map((cycle) {
                final selected = _payCycle == cycle;
                final labels = {
                  PayCycle.monthly: 'Monthly',
                  PayCycle.weekly: 'Weekly',
                  PayCycle.biWeekly: 'Bi-weekly',
                  PayCycle.daily: 'Daily',
                  PayCycle.perProject: 'Per Project',
                };
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(labels[cycle]!),
                    selected: selected,
                    onSelected: (_) => setState(() => _payCycle = cycle),
                    selectedColor: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.2),
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    labelStyle: TextStyle(
                        color: selected
                            ? Theme.of(context).colorScheme.tertiary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    side: BorderSide(
                        color: selected
                            ? Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.5)
                            : Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 14),

          // ── Name ───────────────────────────────────────
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: _isFreelance ? 'Client / Business Name' : 'Company Name',
              labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 14),

          // ── Salary / Rate ──────────────────────────────
          TextField(
            controller: _salaryCtrl,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: _salaryLabel,
              hintText: _isFreelance ? '0 = no target' : null,
              hintStyle: TextStyle(color: Colors.grey.shade600),
              labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 14),

          // ── Pay Day (hidden for daily/perProject) ─────
          if (_showPayDay)
            TextField(
              controller: _dayCtrl,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: _dayLabel,
                hintText: _isFreelance ? 'Optional' : '5',
                hintStyle: TextStyle(color: Colors.grey.shade600),
                labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
          const SizedBox(height: 14),

          // Joined date picker
          GestureDetector(
            onTap: _pickDate,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Text('Joined Date',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
                  const Spacer(),
                  Text(DateFormat('MMM yyyy').format(_startDate),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 15,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(width: 6),
                  Icon(Icons.calendar_month_rounded,
                      color: Theme.of(context).colorScheme.onSurfaceVariant, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: _isValid ? _submit : null,
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
              child: Text(
                  _isFreelance ? 'Create Income Source' : 'Create & Generate Months',
                  style: const TextStyle(fontSize: 16)),
            ),
          ),
        ],
        ),
      ),
    );
  }
}
