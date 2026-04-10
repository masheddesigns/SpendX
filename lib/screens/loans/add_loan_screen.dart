import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../models/category.dart';
import '../../models/loan.dart';
import '../../data/providers.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/app_text_field.dart';
import '../../shared/widgets/app_amount_field.dart';
import '../../shared/widgets/app_category_picker.dart';
import '../../shared/widgets/app_section_header.dart';
import '../../features/liabilities/providers/liabilities_providers.dart'
    show liabilitiesSummaryProvider;
import '../../utils/text_formatter.dart';
import '../../shared/widgets/custom_snackbar.dart';

class AddLoanScreen extends ConsumerStatefulWidget {
  final Loan? loan;
  const AddLoanScreen({super.key, this.loan});

  @override
  ConsumerState<AddLoanScreen> createState() => _AddLoanScreenState();
}

class _AddLoanScreenState extends ConsumerState<AddLoanScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _bankController = TextEditingController();
  final _amountController = TextEditingController();
  final _interestController = TextEditingController();
  final _tenureController = TextEditingController();
  final _installmentController = TextEditingController();
  final _dueDayController = TextEditingController(text: '10');

  DateTime _startDate = DateTime.now();
  String? _selectedCategoryId;
  List<Category> _categories = [];
  bool _isLoading = false;
  LoanType _selectedType = LoanType.reducing;

  @override
  void initState() {
    super.initState();
    if (widget.loan != null) {
      final loan = widget.loan!;
      _nameController.text = loan.name;
      _bankController.text = loan.bank;
      _amountController.text = loan.principalAmount.toString();
      _interestController.text = loan.interestRate.toString();
      _tenureController.text = loan.tenureMonths.toString();
      _installmentController.text = loan.monthlyInstallment.toString();
      _dueDayController.text = loan.dueDay.toString();
      _startDate = loan.startDate;
      _selectedCategoryId = loan.categoryId;
      _selectedType = loan.type;
    }
    _nameController.addListener(() => setState(() {}));
    _bankController.addListener(() => setState(() {}));
    _amountController.addListener(() => setState(() {}));
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final maps = await ref.read(categoriesProvider.future);
    setState(() {
      _categories = maps.where((m) => m.type == 'expense').toList();
      if (_selectedCategoryId == null && _categories.isNotEmpty) {
        _selectedCategoryId = _categories.first.id;
      }
    });
  }

  void _calculateEMI() {
    final p = double.tryParse(_amountController.text) ?? 0;
    final annualRate = double.tryParse(_interestController.text) ?? 0;
    final r = annualRate / 12 / 100;
    final n = int.tryParse(_tenureController.text) ?? 0;

    if (p <= 0 || n <= 0) return;

    double emi = 0;
    switch (_selectedType) {
      case LoanType.reducing:
        if (r > 0) {
          final factor = math.pow(1 + r, n).toDouble();
          emi = (p * r * factor) / (factor - 1);
        } else {
          emi = p / n;
        }
        break;
      case LoanType.flat:
        final totalInterest = p * (annualRate / 100) * (n / 12);
        emi = (p + totalInterest) / n;
        break;
      case LoanType.interestOnly:
        emi = p * (annualRate / 100) / 12;
        break;
    }
    _installmentController.text = emi.toStringAsFixed(2);
  }

  bool get _isValid {
    if (_nameController.text.trim().isEmpty) return false;
    if (_bankController.text.trim().isEmpty) return false;
    final amount = double.tryParse(_amountController.text) ?? 0.0;
    if (amount <= 0) return false;
    return true;
  }

  Future<void> _saveLoan() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    try {
      final loanId = widget.loan?.id ?? const Uuid().v4();
      final amount = double.parse(_amountController.text);

      final loan = Loan(
        id: loanId,
        name: TextFormatter.normalizeName(_nameController.text),
        bank: TextFormatter.normalizeName(_bankController.text),
        total: amount,
        interestRate: double.parse(_interestController.text),
        tenureMonths: int.parse(_tenureController.text),
        monthlyInstallment: double.parse(_installmentController.text),
        startDate: _startDate,
        paidAmount: widget.loan?.paidAmount ?? 0,
        loanStatus: widget.loan?.loanStatus ?? 'active',
        categoryId: _selectedCategoryId,
        dueDay: int.tryParse(_dueDayController.text) ?? 10,
        type: _selectedType,
      );

      if (widget.loan != null) {
        await ref.read(loansProvider.notifier).replace(loan);
      } else {
        await ref.read(loansProvider.notifier).createDetailedLoan(loan);
      }

      ref.invalidate(liabilitiesSummaryProvider);

      if (mounted) {
        CustomSnackBar.show(
          context,
          message: widget.loan != null
              ? 'Loan updated!'
              : 'Loan added successfully!',
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        CustomSnackBar.show(
          context,
          message: 'Error saving loan: $e',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(
        title: widget.loan != null ? 'Edit Loan' : 'Add Bank Loan',
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppTextField(
                controller: _nameController,
                labelText: 'Loan Name (e.g. Car Loan)',
                prefixIcon: Icons.drive_eta_rounded,
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: AppSpacing.m),
              AppTextField(
                controller: _bankController,
                labelText: 'Bank Name',
                prefixIcon: Icons.account_balance_rounded,
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: AppSpacing.l),
              const AppSectionHeader(title: 'Loan Details'),
              const SizedBox(height: AppSpacing.m),
              AppAmountField(
                controller: _amountController,
                onChanged: (_) => _calculateEMI(),
              ),
              const SizedBox(height: AppSpacing.m),

              const AppSectionHeader(title: 'Loan Type'),
              const SizedBox(height: AppSpacing.xs),
              DropdownButtonFormField<LoanType>(
                initialValue: _selectedType,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.account_tree_rounded),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.m),
                    borderSide: BorderSide.none,
                  ),
                ),
                items: [
                  const DropdownMenuItem(
                    value: LoanType.reducing,
                    child: Text('Reducing Balance'),
                  ),
                  const DropdownMenuItem(
                    value: LoanType.flat,
                    child: Text('Flat Interest'),
                  ),
                  const DropdownMenuItem(
                    value: LoanType.interestOnly,
                    child: Text('Interest Only'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    setState(() {
                      _selectedType = v;
                      _calculateEMI();
                    });
                  }
                },
              ),
              const SizedBox(height: AppSpacing.m),
              _buildLoanTypeInfo(),
              const SizedBox(height: AppSpacing.m),
              Row(
                children: [
                  Expanded(
                    child: AppTextField(
                      controller: _interestController,
                      labelText: 'Interest Rate (%)',
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _calculateEMI(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.m),
                  Expanded(
                    child: AppTextField(
                      controller: _tenureController,
                      labelText: 'Tenure (Months)',
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _calculateEMI(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.m),
              AppTextField(
                controller: _dueDayController,
                labelText: 'EMI Due Day (1-31)',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: AppSpacing.m),
              AppTextField(
                controller: _installmentController,
                labelText: 'Monthly EMI (calculated)',
                keyboardType: TextInputType.number,
                readOnly: false,
              ),
              const SizedBox(height: AppSpacing.m),

              const AppSectionHeader(title: 'Loan Timeline'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today_rounded),
                title: const Text('Start Date'),
                subtitle: Text(DateFormat('MMM dd, yyyy').format(_startDate)),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _startDate,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) {
                    setState(() => _startDate = picked);
                  }
                },
              ),
              const SizedBox(height: AppSpacing.l),
              const AppSectionHeader(title: 'Category'),
              AppCategoryPicker(
                availableCategories: _categories,
                selectedCategoryId: _selectedCategoryId,
                onCategorySelected: (id) =>
                    setState(() => _selectedCategoryId = id),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.m),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.m),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.m),
                    ),
                    foregroundColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                  ),
                  child: Text('Cancel', style: AppTextStyles.titleSmall),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: PrimaryButton(
                  label: 'Save Loan',
                  onPressed: _isValid ? _saveLoan : null,
                  isLoading: _isLoading,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoanTypeInfo() {
    String info = '';
    switch (_selectedType) {
      case LoanType.reducing:
        info =
            'Interest is calculated on the remaining monthly balance. Most common for Home/Car loans.';
        break;
      case LoanType.flat:
        info =
            'Interest is calculated on full principal for the entire tenure. Common for informal loans.';
        break;
      case LoanType.interestOnly:
        info =
            'Pay only interest monthly. Full principal paid at the end. Common for business loans.';
        break;
    }
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.m),
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
      border: BorderSide(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              info,
              style: AppTextStyles.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

extension on double {
}
