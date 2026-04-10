import 'package:shared_preferences/shared_preferences.dart';

import '../models/company.dart';
import '../models/increment.dart';
import '../models/salary_contract.dart';
import '../models/salary_model.dart';
import '../models/salary_payment.dart';
import '../models/transaction.dart' as spx;
import '../utils/text_formatter.dart';
import '../data/repositories/salary_repo.dart';
import '../data/repositories/transaction_repo.dart';
import '../data/repositories/reminder_repo.dart';
import '../data/repositories/category_repo.dart';
import 'notification_service.dart';
import 'data_change_bus.dart';

class SalarySummary {
  const SalarySummary({
    required this.totalReceived,
    required this.totalPending,
    required this.totalDelayed,
    required this.averageDelayDays,
    required this.reliabilityScore,
  });

  final double totalReceived;
  final double totalPending;
  final int totalDelayed;
  final double averageDelayDays;
  final double reliabilityScore;
}

class SalaryDashboardData {
  const SalaryDashboardData({
    required this.companies,
    required this.activeCompany,
    required this.activeContract,
    required this.upcomingPayment,
    required this.currentMonthPayment,
    required this.pendingPayments,
    required this.receivedPayments,
    required this.timeline,
    required this.summary,
  });

  final List<Company> companies;
  final Company? activeCompany;
  final SalaryContract? activeContract;
  final SalaryPayment? upcomingPayment;
  final SalaryPayment? currentMonthPayment;
  final List<SalaryPayment> pendingPayments;
  final List<SalaryPayment> receivedPayments;
  final List<SalaryPayment> timeline;
  final SalarySummary summary;
}

class SalaryService {
  final SalaryRepo salaryRepo;
  final TransactionRepo transactionRepo;
  final ReminderRepo reminderRepo;

  SalaryService({
    required this.salaryRepo,
    required this.transactionRepo,
    required this.reminderRepo,
  });

  static final instance = SalaryService(
    salaryRepo: SalaryRepo(),
    transactionRepo: TransactionRepo(),
    reminderRepo: ReminderRepo(),
  );

  static const _activeCompanyPrefKey = 'salary_active_company_id';
  static const Duration _dashboardCacheTtl = Duration(seconds: 30);
  bool _didInitialize = false;
  bool _isWatchingDatabaseChanges = false;
  final Map<String, _CachedSalaryDashboardData> _dashboardCache = {};

  Future<void> _ensureInitialized() async {
    if (_didInitialize) return;
    await _migrateLegacySalariesIfNeeded();
    await _ensureActiveCompanySelection();
    _ensureCacheInvalidationListener();
    _didInitialize = true;
  }

  void _ensureCacheInvalidationListener() {
    if (_isWatchingDatabaseChanges) return;
    _isWatchingDatabaseChanges = true;
    DataChangeBus.instance.addListener(_invalidateDashboardCache);
  }

  Future<void> _ensureActiveCompanySelection() async {
    final prefs = await SharedPreferences.getInstance();
    final companies = await salaryRepo.getCompanies();
    final currentId = prefs.getString(_activeCompanyPrefKey);
    if (companies.isEmpty) {
      await prefs.remove(_activeCompanyPrefKey);
      return;
    }

    final activeExists = companies.any((company) => company['id'] == currentId);
    if (!activeExists) {
      await prefs.setString(
        _activeCompanyPrefKey,
        (companies.first['id'] as String),
      );
    }
  }

  Future<void> _migrateLegacySalariesIfNeeded() async {
    final companies = await salaryRepo.getCompanies();
    if (companies.isNotEmpty) return;

    final legacy = await salaryRepo.getLegacySalaries();
    if (legacy.isEmpty) return;

    final rows = [...legacy]
      ..sort(
        (a, b) => (a['salary_month'] as String).compareTo(
          b['salary_month'] as String,
        ),
      );
    final latest = rows.last;
    final companyId = await salaryRepo.insertCompany({
      'name': 'Default Company',
      'salary_credit_day': DateTime.parse(
        latest['expected_date'] as String,
      ).day,
      'created_at': DateTime.now().toIso8601String(),
    });

    final contractId = DateTime.now().millisecondsSinceEpoch.toString();
    await salaryRepo.insertContract({
      'id': contractId,
      'company_id': companyId,
      'base_salary': latest['net_salary'],
      'start_date': latest['salary_month'],
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });

    for (final salary in rows) {
      await salaryRepo.insertPayment({
        'id': salary['id'],
        'contract_id': contractId,
        'month': salary['salary_month'],
        'expected_date': salary['expected_date'],
        'received_date': salary['received_date'],
        'total_amount': salary['net_salary'],
        'amount_received': salary['amount_received'] ?? 0.0,
        'manual_status': salary['manual_status'],
        'notes': [
          if ((salary['company_name'] as String).trim().isNotEmpty)
            'Imported from ${salary['company_name']}',
          if ((salary['notes'] as String? ?? '').trim().isNotEmpty)
            salary['notes'].trim(),
        ].join(' • '),
        'created_at': DateTime.now().toIso8601String(),
      });
    }
  }

  Future<List<Company>> getCompanies() async {
    await _ensureInitialized();
    final maps = await salaryRepo.getCompanies();
    return maps.map(Company.fromMap).toList();
  }

  Future<String?> getActiveCompanyId() async {
    await _ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeCompanyPrefKey);
  }

  Future<Company?> getActiveCompany() async {
    await _ensureInitialized();
    final companies = await getCompanies();
    final activeId = await getActiveCompanyId();
    for (final company in companies) {
      if (company.id == activeId) return company;
    }
    return companies.isEmpty ? null : companies.first;
  }

  Future<void> setActiveCompany(String companyId) async {
    await _ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeCompanyPrefKey, companyId);
  }

  Future<void> saveCompany(Company company) async {
    await _ensureInitialized();
    final normalized = company.copyWith(
      name: TextFormatter.normalizeName(company.name),
    );
    await salaryRepo.insertCompany(normalized.toMap());
    await setActiveCompany(normalized.id);
  }

  Future<void> updateCompany(Company updated) async {
    await _ensureInitialized();
    final normalized = updated.copyWith(
      name: TextFormatter.normalizeName(updated.name),
    );
    await salaryRepo.updateCompany(normalized.toMap());
    await _updateFutureExpectedDatesForCompany(normalized);
  }

  Future<void> deleteCompany(String companyId) async {
    await _ensureInitialized();
    await salaryRepo.deleteCompany(companyId);
    await _ensureActiveCompanySelection();
  }

  Future<List<SalaryContract>> getContractsForCompany(String companyId) async {
    await _ensureInitialized();
    final maps = await salaryRepo.getContracts(companyId: companyId);
    return maps.map(SalaryContract.fromMap).toList();
  }

  Future<SalaryContract?> getActiveContractForCompany(String companyId) async {
    final contracts = await getContractsForCompany(companyId);
    for (final contract in contracts) {
      if (contract.isActive) return contract;
    }
    return contracts.isEmpty ? null : contracts.first;
  }

  Future<void> saveContract(SalaryContract contract) async {
    await _ensureInitialized();
    final existing = await getContractsForCompany(contract.companyId);
    for (final item in existing.where((item) => item.isActive)) {
      await salaryRepo.updateContract(
        item
            .copyWith(isActive: item.id == contract.id ? item.isActive : false)
            .toMap(),
      );
    }
    await salaryRepo.insertContract(contract.toMap());
    await generatePaymentsForContract(contract);
  }

  Future<void> setupSalary({
    required String companyId,
    required double baseSalary,
    required DateTime startDate,
    String? defaultAccountId,
  }) async {
    await _ensureInitialized();
    final active = await getActiveContractForCompany(companyId);
    if (active != null && active.isActive) {
      await salaryRepo.updateContract(active.copyWith(isActive: false).toMap());
    }

    final contract = SalaryContract(
      companyId: companyId,
      baseSalary: baseSalary,
      startDate: _monthStart(startDate),
      defaultAccountId: defaultAccountId,
      isActive: true,
    );
    await salaryRepo.insertContract(contract.toMap());
    await setActiveCompany(companyId);
    await generatePaymentsForContract(contract);
  }

  Future<void> updateContract(
    SalaryContract updated, {
    String? moveToCompanyId,
  }) async {
    await _ensureInitialized();
    final target = updated.copyWith(
      companyId: moveToCompanyId ?? updated.companyId,
    );
    await salaryRepo.updateContract(target.toMap());
    await _syncFuturePaymentsForContract(target);
  }

  Future<void> addIncrement(Increment increment) async {
    await _ensureInitialized();
    await salaryRepo.insertIncrement(increment.toMap());
    final contract = await _findContract(increment.contractId);
    if (contract != null) {
      await _syncFuturePaymentsForContract(contract);
    }
  }

  Future<void> generatePaymentsForContract(
    SalaryContract contract, {
    int pastMonths = 3,
    int futureMonths = 12,
  }) async {
    await _ensureInitialized();
    final startMonth = _monthStart(contract.startDate);
    final currentMonth = _monthStart(DateTime.now());
    final firstMonth = _addMonths(
      currentMonth.isAfter(startMonth) ? currentMonth : startMonth,
      -pastMonths,
    );
    final company = await _findCompany(contract.companyId);
    if (company == null) return;

    final existing = await salaryRepo.getPayments(contractId: contract.id);
    final byMonthKey = {
      for (final payment in existing.map(SalaryPayment.fromMap))
        _monthKey(payment.month): payment,
    };

    for (var offset = 0; offset <= futureMonths + pastMonths; offset++) {
      final month = _addMonths(firstMonth, offset);
      if (month.isBefore(startMonth)) continue;

      final total = await _calculatedAmountForMonth(contract, month);
      final expectedDate = _expectedDateForMonth(
        month,
        company.salaryCreditDay,
      );
      final existingPayment = byMonthKey[_monthKey(month)];

      if (existingPayment == null) {
        final newPayment = SalaryPayment(
          contractId: contract.id,
          month: month,
          expectedDate: expectedDate,
          totalAmount: total,
          accountId: contract.defaultAccountId,
        );
        await salaryRepo.insertPayment(newPayment.toMap());
        await _syncReminderForPayment(newPayment);
      } else if (existingPayment.amountReceived <= 0 &&
          existingPayment.receivedDate == null) {
        final updatedPayment = existingPayment.copyWith(
          expectedDate: expectedDate,
          totalAmount: total,
          accountId: existingPayment.accountId ?? contract.defaultAccountId,
        );
        await salaryRepo.updatePayment(updatedPayment.toMap());
        await _syncReminderForPayment(updatedPayment);
      }
    }
  }

  Future<List<SalaryPayment>> getPaymentsForCompany(String companyId) async {
    await _ensureInitialized();
    final contracts = await getContractsForCompany(companyId);
    final paymentsMap = <Map<String, dynamic>>[];
    for (final contract in contracts) {
      paymentsMap.addAll(await salaryRepo.getPayments(contractId: contract.id));
    }
    final payments = paymentsMap.map(SalaryPayment.fromMap).toList();
    payments.sort((a, b) => b.month.compareTo(a.month));
    return payments;
  }

  Future<List<SalaryPayment>> getAllSalaryPayments() async {
    await _ensureInitialized();
    final companies = await getCompanies();
    final all = <SalaryPayment>[];
    for (final company in companies) {
      all.addAll(await getPaymentsForCompany(company.id));
    }
    all.sort((a, b) => b.month.compareTo(a.month));
    return all;
  }

  Future<SalaryPayment?> getUpcomingPaymentForCompany(String companyId) async {
    final payments = await getPaymentsForCompany(companyId);
    final now = DateTime.now();
    for (final payment in payments.reversed) {
      if (payment.status != SalaryPaymentStatus.received &&
          payment.expectedDate.isAfter(now.subtract(const Duration(days: 1)))) {
        return payment;
      }
    }
    for (final payment in payments) {
      if (payment.status != SalaryPaymentStatus.received) {
        return payment;
      }
    }
    return null;
  }

  Future<SalaryPayment?> getCurrentMonthPaymentForCompany(
    String companyId,
  ) async {
    final currentMonth = _monthStart(DateTime.now());
    final payments = await getPaymentsForCompany(companyId);
    for (final payment in payments) {
      if (_monthKey(payment.month) == _monthKey(currentMonth) &&
          payment.status != SalaryPaymentStatus.received) {
        return payment;
      }
    }
    return null;
  }

  Future<SalaryDashboardData> getDashboardData({String? companyId}) async {
    await _ensureInitialized();
    final cacheKey = companyId ?? '__active__';
    final cached = _dashboardCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      return cached.data;
    }

    final companies = await getCompanies();
    final activeCompany = companyId != null
        ? companies.cast<Company?>().firstWhere(
            (company) => company?.id == companyId,
            orElse: () => null,
          )
        : await getActiveCompany();

    if (activeCompany == null) {
      const empty = SalaryDashboardData(
        companies: [],
        activeCompany: null,
        activeContract: null,
        upcomingPayment: null,
        currentMonthPayment: null,
        pendingPayments: [],
        receivedPayments: [],
        timeline: [],
        summary: SalarySummary(
          totalReceived: 0,
          totalPending: 0,
          totalDelayed: 0,
          averageDelayDays: 0,
          reliabilityScore: 100,
        ),
      );
      _dashboardCache[cacheKey] = _CachedSalaryDashboardData(empty);
      return empty;
    }

    final activeContract = await getActiveContractForCompany(activeCompany.id);
    final payments = await getPaymentsForCompany(activeCompany.id);
    final pending = payments
        .where((payment) => payment.status != SalaryPaymentStatus.received)
        .toList();
    final received = payments
        .where((payment) => payment.status == SalaryPaymentStatus.received)
        .toList();

    final data = SalaryDashboardData(
      companies: companies,
      activeCompany: activeCompany,
      activeContract: activeContract,
      upcomingPayment: await getUpcomingPaymentForCompany(activeCompany.id),
      currentMonthPayment: await getCurrentMonthPaymentForCompany(
        activeCompany.id,
      ),
      pendingPayments: pending,
      receivedPayments: received,
      timeline: payments.take(12).toList(),
      summary: await getSummary(companyId: activeCompany.id),
    );
    _dashboardCache[cacheKey] = _CachedSalaryDashboardData(data);
    _dashboardCache[activeCompany.id] = _CachedSalaryDashboardData(data);
    _dashboardCache['__active__'] = _CachedSalaryDashboardData(data);
    return data;
  }

  Future<void> markFullyReceived(SalaryPayment payment) async {
    await _ensureInitialized();
    final updated = payment.copyWith(
      amountReceived: payment.totalAmount,
      receivedDate: payment.receivedDate ?? DateTime.now(),
      manualStatus: SalaryPaymentStatus.received,
    );
    final synced = await _syncPaymentIncomeTransaction(updated);
    await salaryRepo.updatePayment(synced.toMap());
    await _syncReminderForPayment(synced);
  }

  Future<void> addPartialPayment(SalaryPayment payment, double amount) async {
    await _ensureInitialized();
    final nextAmount = payment.amountReceived + amount;
    final isFullyReceived = nextAmount >= payment.totalAmount;

    final updated = payment.copyWith(
      amountReceived: isFullyReceived ? payment.totalAmount : nextAmount,
      receivedDate: DateTime.now(),
      manualStatus: isFullyReceived
          ? SalaryPaymentStatus.received
          : SalaryPaymentStatus.partial,
    );
    final synced = await _syncPaymentIncomeTransaction(updated);
    await salaryRepo.updatePayment(synced.toMap());
    await _syncReminderForPayment(synced);
  }

  Future<void> markDelayed(SalaryPayment payment) async {
    final updated = payment.copyWith(manualStatus: SalaryPaymentStatus.delayed);
    await salaryRepo.updatePayment(
      (await _syncPaymentIncomeTransaction(updated)).toMap(),
    );
    await _syncReminderForPayment(updated);
  }

  Future<void> putOnHold(SalaryPayment payment) async {
    final updated = payment.copyWith(manualStatus: SalaryPaymentStatus.onHold);
    await salaryRepo.updatePayment(
      (await _syncPaymentIncomeTransaction(updated)).toMap(),
    );
    await _syncReminderForPayment(updated);
  }

  Future<void> addBonus(SalaryPayment payment, double bonusAmount) async {
    await _ensureInitialized();
    await salaryRepo.updatePayment(
      (await _syncPaymentIncomeTransaction(
        payment.copyWith(
          bonusAmount: payment.bonusAmount + bonusAmount,
          totalAmount: payment.totalAmount + bonusAmount,
        ),
      )).toMap(),
    );
  }

  Future<void> updatePayment(SalaryPayment payment) async {
    await _ensureInitialized();
    final synced = await _syncPaymentIncomeTransaction(payment);
    await salaryRepo.updatePayment(synced.toMap());
    await _syncReminderForPayment(synced);
  }

  Future<void> saveSalary(Salary salary) async {
    await _ensureInitialized();
    final companies = await getCompanies();
    Company? company;
    for (final item in companies) {
      if (item.name.trim().toLowerCase() ==
          salary.companyName.trim().toLowerCase()) {
        company = item;
        break;
      }
    }

    company ??= Company(
      name: salary.companyName.trim().isEmpty
          ? 'Imported Company'
          : TextFormatter.normalizeName(salary.companyName.trim()),
      salaryCreditDay: salary.expectedDate.day,
    );
    if (!companies.any((item) => item.id == company!.id)) {
      await saveCompany(company);
    }

    var contract = await getActiveContractForCompany(company.id);
    contract ??= SalaryContract(
      companyId: company.id,
      baseSalary: salary.netSalary,
      startDate: _monthStart(salary.salaryMonth),
      defaultAccountId: salary.accountId,
    );
    if ((await getContractsForCompany(
      company.id,
    )).every((item) => item.id != contract!.id)) {
      await salaryRepo.insertContract(contract.toMap());
    }

    final synced = await _syncPaymentIncomeTransaction(
      SalaryPayment(
        id: salary.id,
        contractId: contract.id,
        month: _monthStart(salary.salaryMonth),
        expectedDate: salary.expectedDate,
        receivedDate: salary.receivedDate,
        totalAmount: salary.netSalary,
        amountReceived: salary.amountReceived,
        accountId: salary.accountId ?? contract.defaultAccountId,
        linkedTransactionId: salary.linkedTransactionId,
        manualStatus: _paymentStatusFromLegacy(salary.manualStatus),
        notes: salary.notes,
      ),
    );
    await salaryRepo.insertPayment(synced.toMap());
    await _syncReminderForPayment(synced);
  }

  Future<void> updateSalary(Salary salary) async {
    await _ensureInitialized();
    final allPayments = await getAllSalaryPayments();
    SalaryPayment? existingPayment;
    for (final item in allPayments) {
      if (item.id == salary.id) {
        existingPayment = item;
        break;
      }
    }

    if (existingPayment == null) {
      await saveSalary(salary);
      return;
    }

    final synced = await _syncPaymentIncomeTransaction(
      existingPayment.copyWith(
        expectedDate: salary.expectedDate,
        receivedDate: salary.receivedDate,
        totalAmount: salary.netSalary,
        amountReceived: salary.amountReceived,
        accountId: salary.accountId,
        linkedTransactionId: salary.linkedTransactionId,
        manualStatus: _paymentStatusFromLegacy(salary.manualStatus),
        notes: salary.notes,
      ),
    );
    await salaryRepo.updatePayment(synced.toMap());
    await _syncReminderForPayment(synced);
  }

  Future<void> deleteSalary(String id) async {
    await _ensureInitialized();
    await salaryRepo.deletePayment(id);
  }

  Future<List<Salary>> getAllSalaries() async {
    await _ensureInitialized();
    final companies = await getCompanies();
    final salaries = <Salary>[];
    for (final company in companies) {
      final payments = await getPaymentsForCompany(company.id);
      for (final payment in payments) {
        salaries.add(_legacySalaryFromPayment(company, payment));
      }
    }
    salaries.sort((a, b) => b.salaryMonth.compareTo(a.salaryMonth));
    return salaries;
  }

  Future<Salary?> getCurrentMonthSalary() async {
    await _ensureInitialized();
    final activeCompany = await getActiveCompany();
    if (activeCompany == null) return null;
    final payment = await getCurrentMonthPaymentForCompany(activeCompany.id);
    if (payment == null) return null;
    return _legacySalaryFromPayment(activeCompany, payment);
  }

  Future<SalarySummary> getSummary({String? companyId}) async {
    await _ensureInitialized();
    final payments = companyId == null
        ? await getAllSalaryPayments()
        : await getPaymentsForCompany(companyId);

    var totalReceived = 0.0;
    var totalPending = 0.0;
    var totalDelayed = 0;
    var delayedDaysTotal = 0.0;

    for (final payment in payments) {
      totalReceived += payment.amountReceived;
      totalPending += payment.remainingAmount;
      if (payment.status == SalaryPaymentStatus.delayed) {
        totalDelayed++;
        delayedDaysTotal += payment.delayedByDays;
      }
    }

    final averageDelayDays = totalDelayed == 0
        ? 0.0
        : delayedDaysTotal / totalDelayed;
    final reliabilityScore = payments.isEmpty
        ? 100.0
        : ((payments.length - totalDelayed) / payments.length) * 100;

    return SalarySummary(
      totalReceived: totalReceived,
      totalPending: totalPending,
      totalDelayed: totalDelayed,
      averageDelayDays: averageDelayDays,
      reliabilityScore: reliabilityScore.clamp(0, 100),
    );
  }

  Future<void> _syncFuturePaymentsForContract(SalaryContract contract) async {
    final company = await _findCompany(contract.companyId);
    if (company == null) return;
    final paymentsMap = await salaryRepo.getPayments(contractId: contract.id);
    final currentMonth = _monthStart(DateTime.now());

    for (final map in paymentsMap) {
      final payment = SalaryPayment.fromMap(map);
      if (payment.month.isAfter(currentMonth)) {
        final updated = payment.copyWith(
          expectedDate: _expectedDateForMonth(
            payment.month,
            company.salaryCreditDay,
          ),
          totalAmount: await _calculatedAmountForMonth(contract, payment.month),
          accountId: contract.defaultAccountId,
        );
        await salaryRepo.updatePayment(updated.toMap());
      }
    }

    await generatePaymentsForContract(contract);
  }

  Future<void> _updateFutureExpectedDatesForCompany(Company company) async {
    final contracts = await getContractsForCompany(company.id);
    final currentMonth = _monthStart(DateTime.now());
    for (final contract in contracts) {
      final paymentsMap = await salaryRepo.getPayments(contractId: contract.id);
      for (final map in paymentsMap) {
        final payment = SalaryPayment.fromMap(map);
        if (!payment.month.isBefore(currentMonth)) {
          await salaryRepo.updatePayment(
            payment
                .copyWith(
                  expectedDate: _expectedDateForMonth(
                    payment.month,
                    company.salaryCreditDay,
                  ),
                )
                .toMap(),
          );
        }
      }
    }
  }

  Future<double> _calculatedAmountForMonth(
    SalaryContract contract,
    DateTime month,
  ) async {
    final maps = await salaryRepo.getIncrements(contract.id);
    final increments = maps.map(Increment.fromMap).toList();
    var total = contract.baseSalary;
    for (final increment in increments) {
      if (!_monthStart(month).isBefore(_monthStart(increment.effectiveFrom))) {
        total += increment.amountIncrease;
      }
    }
    return total;
  }

  Salary _legacySalaryFromPayment(Company company, SalaryPayment payment) {
    return Salary(
      id: payment.id,
      companyName: company.name,
      salaryMonth: payment.month,
      expectedDate: payment.expectedDate,
      receivedDate: payment.receivedDate,
      netSalary: payment.totalAmount,
      amountReceived: payment.amountReceived,
      accountId: payment.accountId,
      linkedTransactionId: payment.linkedTransactionId,
      manualStatus: _legacyStatusFromPayment(payment.manualStatus),
      notes: payment.notes,
    );
  }

  Future<void> attachAccount(SalaryPayment payment, String? accountId) async {
    await _ensureInitialized();
    await updatePayment(payment.copyWith(accountId: accountId));
  }

  Future<SalaryPayment> _syncPaymentIncomeTransaction(
    SalaryPayment payment,
  ) async {
    final shouldCreateIncome =
        payment.accountId != null &&
        payment.accountId!.isNotEmpty &&
        payment.amountReceived > 0;

    if (!shouldCreateIncome) {
      if (payment.linkedTransactionId != null &&
          payment.linkedTransactionId!.isNotEmpty) {
        await transactionRepo.delete(payment.linkedTransactionId!);
      }
      return payment.copyWith(linkedTransactionId: '');
    }

    final company = await _companyForPayment(payment);
    final salaryCategory = (await CategoryRepo().getAll()).firstWhere(
      (c) => c.type == 'income' && c.name.trim().toLowerCase() == 'salary',
      orElse: () => throw Exception('Salary category not found'),
    );

    final notes =
        '${company?.name ?? 'Salary'} salary • ${_monthLabel(payment.month)}'
        '${payment.status == SalaryPaymentStatus.partial ? ' (Partial)' : ''}';

    final txn = spx.Transaction(
      id:
          payment.linkedTransactionId == null ||
              payment.linkedTransactionId!.isEmpty
          ? null
          : payment.linkedTransactionId,
      userId: 'offline_user',
      type: 'income',
      categoryId: salaryCategory.id,
      amount: payment.amountReceived,
      date: payment.receivedDate ?? DateTime.now(),
      notes: notes,
      source: 'salary',
      relatedEntityId: payment.accountId,
    );

    String transactionId;
    if (payment.linkedTransactionId != null &&
        payment.linkedTransactionId!.isNotEmpty) {
      await transactionRepo.update(txn);
      transactionId = payment.linkedTransactionId!;
    } else {
      transactionId = await transactionRepo.insert(txn);
    }
    return payment.copyWith(linkedTransactionId: transactionId);
  }

  Future<Company?> _companyForPayment(SalaryPayment payment) async {
    final contract = await _findContract(payment.contractId);
    if (contract == null) return null;
    return _findCompany(contract.companyId);
  }

  SalaryPaymentStatus? _paymentStatusFromLegacy(SalaryStatus? status) {
    switch (status) {
      case SalaryStatus.pending:
        return SalaryPaymentStatus.pending;
      case SalaryStatus.received:
        return SalaryPaymentStatus.received;
      case SalaryStatus.delayed:
        return SalaryPaymentStatus.delayed;
      case SalaryStatus.onHold:
        return SalaryPaymentStatus.onHold;
      case SalaryStatus.partial:
        return SalaryPaymentStatus.partial;
      case null:
        return null;
    }
  }

  SalaryStatus? _legacyStatusFromPayment(SalaryPaymentStatus? status) {
    switch (status) {
      case SalaryPaymentStatus.pending:
        return SalaryStatus.pending;
      case SalaryPaymentStatus.received:
        return SalaryStatus.received;
      case SalaryPaymentStatus.partial:
        return SalaryStatus.partial;
      case SalaryPaymentStatus.delayed:
        return SalaryStatus.delayed;
      case SalaryPaymentStatus.onHold:
        return SalaryStatus.onHold;
      case null:
        return null;
    }
  }

  Future<Company?> _findCompany(String companyId) async {
    final maps = await salaryRepo.getCompanies();
    for (final map in maps) {
      if (map['id'] == companyId) return Company.fromMap(map);
    }
    return null;
  }

  Future<SalaryContract?> _findContract(String contractId) async {
    final maps = await salaryRepo.getContracts();
    for (final map in maps) {
      if (map['id'] == contractId) return SalaryContract.fromMap(map);
    }
    return null;
  }

  static DateTime _monthStart(DateTime value) =>
      DateTime(value.year, value.month);

  static DateTime _addMonths(DateTime month, int delta) =>
      DateTime(month.year, month.month + delta);

  static String _monthKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}';

  static String _monthLabel(DateTime value) =>
      '${value.month.toString().padLeft(2, '0')}/${value.year}';

  static DateTime _expectedDateForMonth(DateTime month, int salaryDay) {
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    final safeDay = salaryDay.clamp(1, lastDay);
    return DateTime(month.year, month.month, safeDay);
  }

  Future<void> _syncReminderForPayment(SalaryPayment payment) async {
    final company = await _companyForPayment(payment);
    final reminderId = 'salary_${payment.id}';

    if (payment.status == SalaryPaymentStatus.received) {
      await reminderRepo.deleteGlobalReminder(reminderId);
      return;
    }

    final reminder = Map<String, dynamic>.from({
      'id': reminderId,
      'title': 'Salary Due',
      'description': 'Incoming salary from ${company?.name ?? 'Company'}',
      'date': payment.expectedDate
          .subtract(const Duration(hours: 1))
          .toIso8601String(),
      'type': 'salary',
      'status': 'upcoming',
      'created_at': DateTime.now().toIso8601String(),
    });
    await reminderRepo.insertGlobalReminder(reminder);

    // Schedule 9 PM notification if not received
    final notificationId = payment.id.hashCode.abs();
    if (payment.status != SalaryPaymentStatus.received) {
      await NotificationService.instance.scheduleSalaryDueReminder(
        paymentId: payment.id,
        companyName: company?.name ?? 'your company',
        expectedDate: payment.expectedDate,
        amount: payment.totalAmount,
      );
    } else {
      await NotificationService.instance.cancel(notificationId);
    }
  }

  void _invalidateDashboardCache() {
    _dashboardCache.clear();
  }
}

class _CachedSalaryDashboardData {
  _CachedSalaryDashboardData(this.data) : cachedAt = DateTime.now();

  final SalaryDashboardData data;
  final DateTime cachedAt;

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > SalaryService._dashboardCacheTtl;
}
