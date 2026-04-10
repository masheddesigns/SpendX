import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../providers/salary_providers.dart';
import '../../../models/company.dart';
import '../../../models/salary_contract.dart';
import '../../../widgets/spendx_app_bar.dart';
import '../../../screens/bank/add_bank_account_screen.dart';
import 'manage_company_screen.dart';

class SetupSalaryScreen extends ConsumerStatefulWidget {
  const SetupSalaryScreen({super.key, this.existingContract});

  final SalaryContract? existingContract;

  @override
  ConsumerState<SetupSalaryScreen> createState() => _SetupSalaryScreenState();
}

class _SetupSalaryScreenState extends ConsumerState<SetupSalaryScreen> {
  String? _selectedCompanyId;
  String? _selectedAccountId;
  late final TextEditingController _baseCtrl;
  late final TextEditingController _dateCtrl;
  late DateTime _startDate;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _baseCtrl = TextEditingController(
      text: widget.existingContract?.baseSalary.toStringAsFixed(0) ?? '',
    );
    _startDate = widget.existingContract?.startDate ?? DateTime.now();
    _dateCtrl = TextEditingController(
      text: DateFormat('dd MMM yyyy').format(_startDate),
    );
    _selectedAccountId = widget.existingContract?.defaultAccountId;
  }

  void _initializeState(List<Company> companies, Company? activeCompany) {
    if (_initialized) return;
    _initialized = true;
    _selectedCompanyId =
        widget.existingContract?.companyId ??
        activeCompany?.id ??
        (companies.isNotEmpty ? companies.first.id : null);
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _dateCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _startDate = picked;
        _dateCtrl.text = DateFormat('dd MMM yyyy').format(_startDate);
      });
    }
  }

  Future<void> _save() async {
    final companyId = _selectedCompanyId;
    if (companyId == null) return;

    final baseSalary = double.tryParse(_baseCtrl.text.trim()) ?? 0;
    final notifier = ref.read(salaryNotifierProvider.notifier);

    if (widget.existingContract == null) {
      await notifier.setupSalary(
        companyId: companyId,
        baseSalary: baseSalary,
        startDate: _startDate,
        defaultAccountId: _selectedAccountId,
      );
    } else {
      await notifier.updateContract(
        widget.existingContract!.copyWith(
          companyId: companyId,
          baseSalary: baseSalary,
          startDate: _startDate,
          defaultAccountId: _selectedAccountId,
          isActive: true,
        ),
      );
    }

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final companiesAsync = ref.watch(salaryCompaniesProvider);
    final activeCompanyAsync = ref.watch(activeSalaryCompanyProvider);
    final accountsAsync = ref.watch(bankAccountsProvider);

    return Scaffold(
      appBar: SpendXAppBar(
        title: widget.existingContract == null
            ? 'Set Up Salary'
            : 'Edit Salary Contract',
      ),
      body: companiesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (companies) {
          if (companies.isEmpty) {
            return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.apartment_outlined, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    Text('Add a company first', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32.0),
                      child: Text('Salary contracts are attached to companies, so create one employer before continuing.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ManageCompanyScreen(),
                          ),
                        );
                        ref.invalidate(salaryCompaniesProvider);
                      },
                      child: const Text('Manage Companies'),
                    ),
                  ],
                ),
              );
          }

          final activeCompany = activeCompanyAsync.valueOrNull;
          _initializeState(companies, activeCompany);

          return accountsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (accounts) {
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _selectedCompanyId,
                    decoration: const InputDecoration(labelText: 'Company', border: OutlineInputBorder()),
                    items: companies
                        .map(
                          (company) => DropdownMenuItem(
                            value: company.id,
                            child: Text(company.name),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _selectedCompanyId = value),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _baseCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Base Salary',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String?>(
                    initialValue: _selectedAccountId,
                    decoration: const InputDecoration(
                      labelText: 'Select Account',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      ...accounts.map(
                        (account) => DropdownMenuItem<String?>(
                          value: account.id,
                          child: Text(account.name),
                        ),
                      ),
                      const DropdownMenuItem<String?>(
                        value: '__add_new__',
                        child: Text('Add New Account'),
                      ),
                    ],
                    onChanged: (value) async {
                      if (value == '__add_new__') {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const AddBankAccountScreen(),
                          ),
                        );
                        ref.invalidate(bankAccountsProvider);
                        return;
                      }
                      setState(() => _selectedAccountId = value);
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _dateCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Start Date',
                      border: OutlineInputBorder(),
                    ),
                    onTap: _pickStartDate,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _pickStartDate,
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: const Text('Pick start date'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                    ),
                    onPressed: _save,
                    child: Text(widget.existingContract == null
                        ? 'Create Salary Contract'
                        : 'Save Contract'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
