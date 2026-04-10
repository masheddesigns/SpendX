import '../../../services/haptic_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../models/company.dart';
import '../../salary_ledger/salary_ledger_notifier.dart';

class ManageCompanyScreen extends ConsumerWidget {
  const ManageCompanyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(salaryLedgerProvider);

    return Scaffold(
      
      appBar: AppBar(
          title: Text('Manage Companies'),
          backgroundColor: Colors.transparent),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context, ref),
        backgroundColor: Colors.blueAccent,
        icon: const Icon(Icons.add),
        label: Text('Add Company'),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
            child: Text('Error: $e',
                style: const TextStyle(color: Colors.redAccent))),
        data: (state) {
          final companies = state.companies;
          final selectedId = state.selectedCompanyId;

          if (companies.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.apartment_outlined,
                      size: 56,
                      color: Colors.grey.shade600),
                  const SizedBox(height: 12),
                  Text('No companies yet',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('Add your employer to start salary tracking',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: companies.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final company = companies[i];
              final isSelected = company.id == selectedId;

              return Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isSelected
                        ? Colors.blueAccent.withValues(alpha: 0.5)
                        : Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
                  ),
                ),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  onTap: () => ref
                      .read(salaryLedgerProvider.notifier)
                      .selectCompany(company.id),
                  leading: CircleAvatar(
                    radius: 20,
                    backgroundColor: isSelected
                        ? Colors.blueAccent.withValues(alpha: 0.15)
                        : const Color(0xFF2A2A2A),
                    child: Icon(Icons.apartment_rounded,
                        color: isSelected
                            ? Colors.blueAccent
                            : Colors.grey.shade400,
                        size: 20),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(company.name,
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.onSurface)),
                      ),
                      if (isSelected)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blueAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('Active',
                              style: TextStyle(
                                  color: Colors.blueAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ),
                    ],
                  ),
                  subtitle: Text(
                      'Pay day: ${company.salaryCreditDay} \u00b7 Joined ${_formatDate(company.createdAt)}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                  trailing: PopupMenuButton<String>(
                    iconColor: Colors.grey.shade400,
                    onSelected: (action) {
                      if (action == 'edit') {
                        _openEditor(context, ref, existing: company);
                      }
                      if (action == 'update_salary') {
                        _showUpdateSalarySheet(context, ref, company);
                      }
                      if (action == 'delete') {
                        _confirmDelete(context, ref, company);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(
                          value: 'update_salary',
                          child: Text('Update Salary')),
                      PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete',
                              style: TextStyle(color: Colors.red))),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _formatDate(DateTime d) =>
      '${d.day}/${d.month}/${d.year}';

  Future<void> _openEditor(BuildContext context, WidgetRef ref,
      {Company? existing}) async {
    final notifier = ref.read(salaryLedgerProvider.notifier);
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => _CompanyEditorScreen(existing: existing)),
    );
    if (result == true) {
      notifier.refresh();
    }
  }

  void _confirmDelete(
      BuildContext context, WidgetRef ref, Company company) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        title: Text('Delete Company',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
        content: Text(
            'Delete ${company.name}? All salary months and payments will be removed.',
            style: TextStyle(color: Colors.grey.shade300)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel')),
          TextButton(
            onPressed: () {
              final notifier = ref.read(salaryLedgerProvider.notifier);
              Navigator.pop(ctx);
              HapticService.instance.critical();
              Future.microtask(() => notifier.deleteCompany(company.id));
            },
            child:
                Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showUpdateSalarySheet(
      BuildContext context, WidgetRef ref, Company company) {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _UpdateSalarySheet(company: company),
    );
  }
}

// ── Update Salary Sheet (salary hike) ───────────────────────────────────

class _UpdateSalarySheet extends ConsumerStatefulWidget {
  final Company company;
  const _UpdateSalarySheet({required this.company});

  @override
  ConsumerState<_UpdateSalarySheet> createState() =>
      _UpdateSalarySheetState();
}

class _UpdateSalarySheetState extends ConsumerState<_UpdateSalarySheet> {
  late final TextEditingController _salaryCtrl;
  late DateTime _effectiveFrom;

  @override
  void initState() {
    super.initState();
    _salaryCtrl = TextEditingController();
    _effectiveFrom = DateTime(DateTime.now().year, DateTime.now().month, 1);
  }

  @override
  void dispose() {
    _salaryCtrl.dispose();
    super.dispose();
  }

  double get _parsed => double.tryParse(_salaryCtrl.text) ?? 0;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _effectiveFrom,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'Effective from which month?',
    );
    if (picked != null && mounted) {
      setState(
          () => _effectiveFrom = DateTime(picked.year, picked.month, 1));
    }
  }

  void _submit() {
    if (_parsed <= 0) return;
    final notifier = ref.read(salaryLedgerProvider.notifier);
    final companyId = widget.company.id;
    final salary = _parsed;
    final from = _effectiveFrom;
    // Pop first, then update
    Navigator.pop(context);
    Future.microtask(() => notifier.updateSalary(
          companyId: companyId,
          newSalary: salary,
          effectiveFrom: from,
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
          Text('Update Salary',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 4),
          Text('${widget.company.name} \u2014 salary hike',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 20),
          TextField(
            controller: _salaryCtrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 20),
            decoration: InputDecoration(
              labelText: 'New Monthly Salary',
              labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              prefixText: '\u20b9 ',
              prefixStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 20),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 14),
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
                  Text('Effective From',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
                  const Spacer(),
                  Text(DateFormat('MMM yyyy').format(_effectiveFrom),
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
          const SizedBox(height: 8),
          Text(
              'Old months keep their original salary. Only unpaid future months will update.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 11)),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: _parsed > 0 ? _submit : null,
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
              child: Text('Apply Salary Change',
                  style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Company Editor (full screen — proper controller lifecycle) ───────────

class _CompanyEditorScreen extends ConsumerStatefulWidget {
  final Company? existing;
  const _CompanyEditorScreen({this.existing});

  @override
  ConsumerState<_CompanyEditorScreen> createState() =>
      _CompanyEditorScreenState();
}

class _CompanyEditorScreenState extends ConsumerState<_CompanyEditorScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _dayCtrl;
  late DateTime _joinedDate;
  late EmploymentType _empType;
  late PayCycle _payCycle;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    _dayCtrl = TextEditingController(
        text: (widget.existing?.salaryCreditDay ?? 5).toString());
    _joinedDate = widget.existing?.createdAt ?? DateTime.now();
    _empType = widget.existing?.employmentType ?? EmploymentType.fullTime;
    _payCycle = widget.existing?.payCycle ?? PayCycle.monthly;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _dayCtrl.dispose();
    super.dispose();
  }

  bool get _isValid => _nameCtrl.text.trim().isNotEmpty;

  Future<void> _pickJoinedDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _joinedDate,
      firstDate: DateTime(2010),
      lastDate: DateTime.now(),
      helpText: 'When did you join this company?',
    );
    if (picked != null) setState(() => _joinedDate = picked);
  }

  Future<void> _save() async {
    if (!_isValid) return;

    final safeDay = (int.tryParse(_dayCtrl.text.trim()) ?? 5).clamp(1, 28);
    final company = Company(
      id: widget.existing?.id,
      name: _nameCtrl.text.trim(),
      salaryCreditDay: safeDay,
      currency: widget.existing?.currency ?? 'INR',
      employmentType: _empType,
      payCycle: _payCycle,
      createdAt: _joinedDate,
    );

    try {
      final notifier = ref.read(salaryLedgerProvider.notifier);
      if (widget.existing == null) {
        await notifier.addCompany(company);
      } else {
        await notifier.updateCompany(company);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
      return;
    }

    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;

    return Scaffold(
      
      appBar: AppBar(
          title: Text(isEditing ? 'Edit Company' : 'Add Company'),
          backgroundColor: Colors.transparent),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Employment Type ───────────────────────
              Text('Employment Type',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: EmploymentType.values.map((t) {
                    final sel = _empType == t;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(Company(name: '', salaryCreditDay: 1, employmentType: t).employmentLabel),
                        selected: sel,
                        onSelected: (_) => setState(() => _empType = t),
                        selectedColor: Colors.blueAccent,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        labelStyle: TextStyle(
                            color: sel ? Colors.white : Colors.grey.shade400,
                            fontSize: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        side: BorderSide(
                            color: sel
                                ? Colors.blueAccent
                                : Colors.white.withValues(alpha: 0.1)),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),

              // ── Pay Cycle ─────────────────────────────
              Text('Pay Cycle',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    PayCycle.monthly,
                    PayCycle.weekly,
                    PayCycle.biWeekly,
                    PayCycle.daily,
                    if (_empType == EmploymentType.freelance) PayCycle.perProject,
                  ].map((c) {
                    final sel = _payCycle == c;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(Company(name: '', salaryCreditDay: 1, payCycle: c).payCycleLabel),
                        selected: sel,
                        onSelected: (_) => setState(() => _payCycle = c),
                        selectedColor: Colors.tealAccent.withValues(alpha: 0.3),
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        labelStyle: TextStyle(
                            color: sel ? Colors.tealAccent : Colors.grey.shade400,
                            fontSize: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        side: BorderSide(
                            color: sel
                                ? Colors.tealAccent.withValues(alpha: 0.5)
                                : Colors.white.withValues(alpha: 0.1)),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),

              // ── Name ──────────────────────────────────
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: _empType == EmploymentType.freelance
                      ? 'Client / Business Name'
                      : 'Company Name',
                  hintText: _empType == EmploymentType.freelance
                      ? 'e.g. Acme Design Co'
                      : 'e.g. Infosys, TCS',
                  hintStyle: TextStyle(color: Colors.grey.shade600),
                  labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),

              // ── Pay Day (hidden for daily/perProject) ─
              if (_payCycle != PayCycle.daily && _payCycle != PayCycle.perProject)
                TextField(
                  controller: _dayCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Salary Credit Day (1-28)',
                    hintText: '5',
                    hintStyle: TextStyle(color: Colors.grey.shade600),
                    labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                  ),
                ),
              const SizedBox(height: 16),
              // Joined date picker
              GestureDetector(
                onTap: _pickJoinedDate,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 16),
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
                      Text(DateFormat('dd MMM yyyy').format(_joinedDate),
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
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _isValid ? _save : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(isEditing ? 'Save Changes' : 'Add Company',
                      style: const TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
