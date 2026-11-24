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
import '../../shared/widgets/app_form_error_summary.dart';
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
  final _scrollController = ScrollController();
  final _nameController = TextEditingController();
  final _bankController = TextEditingController();
  final _amountController = TextEditingController();
  final _interestController = TextEditingController();
  final _tenureController = TextEditingController();
  final _installmentController = TextEditingController();
  final _dueDayController = TextEditingController(text: '10');

  List<String> _formErrors = [];
  DateTime _startDate = DateTime.now();
  String? _selectedCategoryId;
  List<Category> _categories = [];
  bool _isLoading = false;
  LoanType _selectedType = LoanType.reducing;

  @override
  void dispose() {
    _scrollController.dispose();
    _nameController.dispose();
    _bankController.dispose();
    _amountController.dispose();
    _interestController.dispose();
    _tenureController.dispose();
    _installmentController.dispose();
    _dueDayController.dispose();
    super.dispose();
  }

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

  Future<void> _saveLoan() async {
    final isValid = _formKey.currentState?.validate() ?? false;
    final errors = <String>[];
    if (_nameController.text.trim().isEmpty) errors.add('Loan name is required');
    if (_bankController.text.trim().isEmpty) errors.add('Bank / Lender is required');
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) errors.add('Valid principal amount is required');
    final rate = double.tryParse(_interestController.text);
    if (rate == null || rate < 0) errors.add('Valid interest rate is required');
    final tenure = int.tryParse(_tenureController.text);
    if (tenure == null || tenure < 1 || tenure > 600) errors.add('Tenure must be between 1 and 600 months');
    final emi = double.tryParse(_installmentController.text);
    if (emi == null || emi <= 0) errors.add('Valid monthly EMI is required');
    final dueDay = int.tryParse(_dueDayController.text);
    if (dueDay == null || dueDay < 1 || dueDay > 31) errors.add('Due day must be between 1 and 31');

    if (!isValid || errors.isNotEmpty) {
      setState(() => _formErrors = errors);
      if (_scrollController.hasClients) {
        if (MediaQuery.disableAnimationsOf(context)) {
          _scrollController.jumpTo(0);
        } else {
          _scrollController.animateTo(
            0,
            duration: AppMotion.normal,
            curve: Curves.easeOutCubic,
          );
        }
      }
      return;
    }

    setState(() {
      _formErrors = [];
      _isLoading = true;
    });
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
        controller: _scrollController,
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppFormErrorSummary(
                errors: _formErrors,
                onDismiss: () => setState(() => _formErrors = []),
              ),
              AppTextField(
                controller: _nameController,
                labelText: 'Loan Name (e.g. Car Loan)',
                prefixIcon: Icons.drive_eta_rounded,
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a loan name'
                    : null,
              ),
              const SizedBox(height: AppSpacing.m),
              AppTextField(
                controller: _bankController,
                labelText: 'Bank Name',
                prefixIcon: Icons.account_balance_rounded,
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter the bank name'
                    : null,
              ),
              const SizedBox(height: AppSpacing.l),
              const AppSectionHeader(title: 'Loan Details'),
              const SizedBox(height: AppSpacing.m),
              AppAmountField(
                controller: _amountController,
                onChanged: (_) {
                  _calculateEMI();
                  setState(() {});
                },
                validator: (value) {
                  final amount = double.tryParse((value ?? '').trim());
                  if (amount == null || !amount.isFinite || amount <= 0) {
                    return 'Enter a loan amount greater than zero';
                  }
                  return null;
                },
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
                      onChanged: (_) {
                        _calculateEMI();
                        setState(() {});
                      },
                      validator: (value) {
                        final rate = double.tryParse((value ?? '').trim());
                        if (rate == null || !rate.isFinite || rate < 0) {
                          return 'Enter a valid annual rate';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.m),
                  Expanded(
                    child: AppTextField(
                      controller: _tenureController,
                      labelText: 'Tenure (Months)',
                      keyboardType: TextInputType.number,
                      onChanged: (_) {
                        _calculateEMI();
                        setState(() {});
                      },
                      validator: (value) {
                        final months = int.tryParse((value ?? '').trim());
                        if (months == null || months < 1 || months > 600) {
                          return 'Enter 1–600 months';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.m),
              AppTextField(
                controller: _dueDayController,
                labelText: 'EMI Due Day (1-31)',
                keyboardType: TextInputType.number,
                validator: (value) {
                  final day = int.tryParse((value ?? '').trim());
                  if (day == null || day < 1 || day > 31) {
                    return 'Enter a day from 1 to 31';
                  }
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.m),
              AppTextField(
                controller: _installmentController,
                labelText: 'Monthly EMI (calculated)',
                keyboardType: TextInputType.number,
                readOnly: false,
                validator: (value) {
                  final installment = double.tryParse((value ?? '').trim());
                  if (installment == null ||
                      !installment.isFinite ||
                      installment <= 0) {
                    return 'Enter a monthly EMI greater than zero';
                  }
                  return null;
                },
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
                  onPressed: _isLoading ? null : _saveLoan,
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

extension on double {}
