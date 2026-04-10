import '../core/logging/app_logger.dart';
import 'dart:io';
import 'dart:convert';
import 'package:csv/csv.dart' as csv_pkg;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/repositories/category_repo.dart';
import '../data/repositories/tag_repo.dart';
import '../data/repositories/transaction_repo.dart';
import '../models/transaction.dart' as spx;
import '../models/company.dart';
import '../models/salary_contract.dart';
import '../models/salary_payment.dart';
import 'backup_file_service.dart';
import 'reminder_service.dart';
import 'salary_service.dart';

class ExportService {
  ExportService._({
    TransactionRepo? transactionRepo,
    CategoryRepo? categoryRepo,
    TagRepo? tagRepo,
  }) : _transactionRepo = transactionRepo ?? TransactionRepo(),
       _categoryRepo = categoryRepo ?? CategoryRepo(),
       _tagRepo = tagRepo ?? TagRepo();
  static final ExportService instance = ExportService._();

  final TransactionRepo _transactionRepo;
  final CategoryRepo _categoryRepo;
  final TagRepo _tagRepo;

  ({DateTime from, DateTime to, String label}) financialYearRange(
    int startYear,
  ) {
    return (
      from: DateTime(startYear, 4, 1),
      to: DateTime(startYear + 1, 3, 31),
      label: 'FY $startYear-${(startYear + 1).toString().substring(2)}',
    );
  }

  // ─── Full Backup Export ──────────────────────────────────────────────

  /// Generates the canonical spendx_backup.json and opens a save dialog.
  Future<void> exportFullBackup() async {
    try {
      final (json, _) = await BackupFileService.instance.createBackupJson();

      String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Backup',
        fileName: BackupFileService.backupFileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (outputFile == null) {
        AppLogger.d('[EXPORT] Backup export canceled by user');
        return;
      }

      final file = File(outputFile);
      await file.writeAsString(json);
      AppLogger.d('[EXPORT] Backup saved to $outputFile');
    } catch (e) {
      AppLogger.d('[EXPORT] Failed to export backup: $e');
      rethrow;
    }
  }

  // ─── Legacy Exports (CSV/JSON subsets) ──────────────────────────────

  // Manually escape a CSV field
  String _csvField(dynamic value) {
    final str = value?.toString() ?? '';
    if (str.contains(',') || str.contains('"') || str.contains('\n')) {
      return '"${str.replaceAll('"', '""')}"';
    }
    return str;
  }

  Future<void> exportTransactionsToCsv() async {
    final transactions = await _transactionRepo.getAll();

    // Fetch lookup maps
    final catMaps = await _categoryRepo.getAll();
    final categoriesMap = {for (var item in catMaps) item.id: item.name};

    final tagMaps = await _tagRepo.getAll();
    final tagsMap = {for (var item in tagMaps) item.id: item.name};

    final buffer = StringBuffer();

    // Header row
    buffer.writeln('Date,Type,Category,Amount,Tags,Source,Notes');

    for (var t in transactions) {
      final categoryName = categoriesMap[t.categoryId] ?? 'General';
      final tagNames = t.tags.map((id) => tagsMap[id] ?? 'Unknown').join('|');

      final row = [
        DateFormat('yyyy-MM-dd HH:mm').format(t.date),
        t.type,
        categoryName,
        t.amount,
        tagNames,
        t.source,
        t.notes,
      ].map(_csvField).join(',');

      buffer.writeln(row);
    }

    final directory = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${directory.path}/SpendX Exports');
    if (!await exportDir.exists()) await exportDir.create(recursive: true);

    final fileName =
        'spendx_export_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv';
    final path = '${exportDir.path}/$fileName';

    final file = File(path);
    await file.writeAsString(buffer.toString());

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path)],
        subject: 'SpendX Transactions Export (CSV)',
      ),
    );
  }

  Future<void> exportTransactionsToJson() async {
    final transactions = await _transactionRepo.getAll();

    // Fetch lookup maps
    final catMaps = await _categoryRepo.getAll();
    final categoriesMap = {for (var item in catMaps) item.id: item.name};

    final tagMaps = await _tagRepo.getAll();
    final tagsMap = {for (var item in tagMaps) item.id: item.name};

    final jsonList = transactions.map((t) {
      final categoryName = categoriesMap[t.categoryId] ?? 'General';
      final tagNames = t.tags.map((id) => tagsMap[id] ?? 'Unknown').toList();

      return {
        'id': t.id,
        'date': t.date.toIso8601String(),
        'type': t.type,
        'category': categoryName,
        'amount': t.amount,
        'tags': tagNames,
        'source': t.source,
        'notes': t.notes,
        'created_at': t.createdAt.toIso8601String(),
        'updated_at': t.updatedAt.toIso8601String(),
      };
    }).toList();

    final jsonString = jsonEncode(jsonList);

    final directory = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${directory.path}/SpendX Exports');
    if (!await exportDir.exists()) await exportDir.create(recursive: true);

    final fileName =
        'spendx_export_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.json';
    final path = '${exportDir.path}/$fileName';

    final file = File(path);
    await file.writeAsString(jsonString);

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path)],
        subject: 'SpendX Transactions Export (JSON)',
      ),
    );
  }

  Future<void> exportSalaryReportToCsv({
    DateTime? from,
    DateTime? to,
    String? companyId,
    SalaryPaymentStatus? status,
  }) async {
    final rowsData = await _loadSalaryExportRows(
      from: from,
      to: to,
      companyId: companyId,
      status: status,
    );
    final rows = <List<dynamic>>[
      [
        'Company',
        'Employment Type',
        'Pay Cycle',
        'Month',
        'Expected Date',
        'Received Date',
        'Amount',
        'Amount Received',
        'Pending Amount',
        'Bonus',
        'Status',
        'Notes',
      ],
      ...rowsData.map(
        (row) => [
          row.company.name,
          row.company.employmentLabel,
          row.company.payCycleLabel,
          DateFormat('yyyy-MM').format(row.payment.month),
          row.payment.expectedDate.toIso8601String(),
          row.payment.receivedDate?.toIso8601String() ?? '',
          row.payment.totalAmount,
          row.payment.amountReceived,
          row.payment.remainingAmount,
          row.payment.bonusAmount,
          row.payment.status.name,
          row.payment.notes ?? '',
        ],
      ),
    ];
    await _shareCsv(
      fileName:
          'salary_report_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv',
      rows: rows,
      subject: 'SpendX Salary Report',
    );
  }

  Future<void> exportPendingSalaryReportToCsv({
    DateTime? from,
    DateTime? to,
    String? companyId,
  }) async {
    final pending =
        (await _loadSalaryExportRows(from: from, to: to, companyId: companyId))
            .where((row) => row.payment.status != SalaryPaymentStatus.received)
            .toList();
    final rows = <List<dynamic>>[
      [
        'Company',
        'Month',
        'Expected Date',
        'Status',
        'Pending Amount',
        'Bonus',
        'Notes',
      ],
      ...pending.map(
        (row) => [
          row.company.name,
          DateFormat('yyyy-MM').format(row.payment.month),
          row.payment.expectedDate.toIso8601String(),
          row.payment.status.name,
          row.payment.remainingAmount,
          row.payment.bonusAmount,
          row.payment.notes ?? '',
        ],
      ),
    ];
    await _shareCsv(
      fileName:
          'pending_salary_report_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv',
      rows: rows,
      subject: 'SpendX Pending Salary Report',
    );
  }

  Future<void> exportPartialSalaryReportToCsv({
    DateTime? from,
    DateTime? to,
    String? companyId,
  }) async {
    final partial = (await _loadSalaryExportRows(
      from: from,
      to: to,
      companyId: companyId,
      status: SalaryPaymentStatus.partial,
    ));
    final rows = <List<dynamic>>[
      [
        'Company',
        'Month',
        'Expected Date',
        'Amount',
        'Received Amount',
        'Pending Amount',
        'Bonus',
        'Status',
      ],
      ...partial.map(
        (row) => [
          row.company.name,
          DateFormat('yyyy-MM').format(row.payment.month),
          row.payment.expectedDate.toIso8601String(),
          row.payment.totalAmount,
          row.payment.amountReceived,
          row.payment.remainingAmount,
          row.payment.bonusAmount,
          _salaryStatusLabel(row.payment.status),
        ],
      ),
    ];
    await _shareCsv(
      fileName:
          'partial_salary_report_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv',
      rows: rows,
      subject: 'SpendX Partial Salary Report',
    );
  }

  Future<void> exportDelayAnalysisReportToCsv({
    DateTime? from,
    DateTime? to,
    String? companyId,
  }) async {
    final delayed =
        (await _loadSalaryExportRows(from: from, to: to, companyId: companyId))
            .where((row) => row.payment.status == SalaryPaymentStatus.delayed)
            .toList();
    final rows = <List<dynamic>>[
      [
        'Company',
        'Month',
        'Expected Date',
        'Delay Days',
        'Pending Amount',
        'Status',
      ],
      ...delayed.map(
        (row) => [
          row.company.name,
          DateFormat('yyyy-MM').format(row.payment.month),
          row.payment.expectedDate.toIso8601String(),
          row.payment.delayedByDays,
          row.payment.remainingAmount,
          _salaryStatusLabel(row.payment.status),
        ],
      ),
    ];
    await _shareCsv(
      fileName:
          'delay_analysis_report_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv',
      rows: rows,
      subject: 'SpendX Delay Analysis Report',
    );
  }

  Future<void> exportReminderReportToCsv() async {
    final reminders = await ReminderService.instance.getAllDueReminders();
    final rows = <List<dynamic>>[
      ['Type', 'Title', 'Due Date', 'Status', 'Amount', 'Notes'],
      ...reminders.map(
        (reminder) => [
          reminder.type.name,
          reminder.title,
          reminder.dueDate?.toIso8601String() ?? '',
          reminder.status.name,
          reminder.amount ?? '',
          reminder.notes ?? '',
        ],
      ),
    ];
    await _shareCsv(
      fileName:
          'reminder_report_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv',
      rows: rows,
      subject: 'SpendX Reminder Report',
    );
  }

  Future<void> exportSalaryReportToPdf({
    DateTime? from,
    DateTime? to,
    String? companyId,
    SalaryPaymentStatus? status,
  }) async {
    final rowsData = await _loadSalaryExportRows(
      from: from,
      to: to,
      companyId: companyId,
      status: status,
    );

    String dateRange = 'All Time';
    if (from != null && to != null) {
      dateRange =
          '${DateFormat('MMM yyyy').format(from)} - ${DateFormat('MMM yyyy').format(to)}';
    }

    await _sharePdf(
      fileName:
          'salary_report_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
      title: 'Salary Intelligence Report',
      subtitle: 'Period: $dateRange',
      headers: const [
        'Company',
        'Type',
        'Month',
        'Status',
        'Total',
        'Received',
        'Pending',
      ],
      rows: rowsData
          .map(
            (row) => [
              row.company.name,
              '${row.company.employmentLabel} (${row.company.payCycleLabel})',
              DateFormat('MMM yyyy').format(row.payment.month),
              _salaryStatusLabel(row.payment.status),
              row.payment.totalAmount.toStringAsFixed(2),
              row.payment.amountReceived.toStringAsFixed(2),
              row.payment.remainingAmount.toStringAsFixed(2),
            ],
          )
          .toList(),
    );
  }

  Future<void> exportCompanyWiseSalaryReportToCsv({
    DateTime? from,
    DateTime? to,
    String? companyId,
    SalaryPaymentStatus? status,
  }) async {
    final rowsData = await _loadSalaryExportRows(
      from: from,
      to: to,
      companyId: companyId,
      status: status,
    );
    final rows = <List<dynamic>>[
      ['Company', 'Total Payments', 'Total Received', 'Avg Delay (Days)'],
      ..._aggregateByCompany(rowsData).map(
        (agg) => [
          agg.companyName,
          agg.count,
          agg.totalReceived,
          agg.avgDelay.toStringAsFixed(1),
        ],
      ),
    ];
    await _shareCsv(
      fileName: 'company_wise_salary_summary.csv',
      rows: rows,
      subject: 'SpendX Company-wise Salary Summary',
    );
  }

  Future<void> exportReminderReportToPdf() async {
    final reminders = await ReminderService.instance.getAllDueReminders();
    await _sharePdf(
      fileName:
          'reminder_report_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.pdf',
      title: 'SpendX Reminder Report',
      headers: const ['Type', 'Title', 'Due Date', 'Status', 'Amount'],
      rows: reminders
          .map(
            (reminder) => [
              reminder.type.name,
              reminder.title,
              reminder.dueDate != null
                  ? DateFormat('dd MMM yyyy').format(reminder.dueDate!)
                  : '-',
              reminder.status.name,
              reminder.amount?.toStringAsFixed(2) ?? '-',
            ],
          )
          .toList(),
    );
  }

  Future<List<_SalaryExportRow>> _loadSalaryExportRows({
    DateTime? from,
    DateTime? to,
    String? companyId,
    SalaryPaymentStatus? status,
  }) async {
    final companies = await SalaryService.instance.getCompanies();
    final rows = <_SalaryExportRow>[];

    for (final company in companies) {
      if (companyId != null && company.id != companyId) continue;
      final contracts = await SalaryService.instance.getContractsForCompany(
        company.id,
      );
      final contractById = {
        for (final contract in contracts) contract.id: contract,
      };
      final payments = await SalaryService.instance.getPaymentsForCompany(
        company.id,
      );
      for (final payment in payments) {
        if (status != null && payment.status != status) continue;
        if (from != null &&
            payment.month.isBefore(DateTime(from.year, from.month))) {
          continue;
        }
        if (to != null &&
            payment.month.isAfter(DateTime(to.year, to.month + 1, 0))) {
          continue;
        }
        final contract = contractById[payment.contractId];
        if (contract != null) {
          rows.add(
            _SalaryExportRow(
              company: company,
              contract: contract,
              payment: payment,
            ),
          );
        }
      }
    }

    rows.sort((a, b) {
      final companyCompare = a.company.name.compareTo(b.company.name);
      if (companyCompare != 0) return companyCompare;
      return b.payment.month.compareTo(a.payment.month);
    });
    return rows;
  }

  /// ============= CSV Import Logic =============

  /// Imports transactions from a CSV file.
  /// Expects columns: Date,Type,Category,Amount,Tags,Source,Notes
  Future<int> importTransactionsFromCsv(File file) async {
    final content = await file.readAsString();
    final allRows = csv_pkg.CsvCodec().decode(content);

    if (allRows.length < 2) return 0;

    final dataRows = allRows.skip(1); // skip header
    int importedCount = 0;

    final categories = await _categoryRepo.getAll();

    for (final row in dataRows) {
      if (row.isEmpty) continue;
      if (row.length < 4) continue;

      try {
        final date = DateTime.tryParse(row[0].toString()) ?? DateTime.now();
        final type = row[1].toString().toLowerCase() == 'income'
            ? 'income'
            : 'expense';
        final amount = double.tryParse(row[3].toString()) ?? 0.0;
        final source = row.length > 5 ? row[5].toString() : 'Imported';
        final notes = row.length > 6 ? row[6].toString() : '';

        // Simple category name matching
        final catName = row[2].toString();
        final categoryId = categories
            .firstWhere(
              (c) => c.name.toLowerCase() == catName.toLowerCase(),
              orElse: () => categories.first,
            )
            .id;

        await _transactionRepo.insert(
          spx.Transaction(
            userId: 'offline_user', // Local-first default
            type: type,
            categoryId: categoryId,
            amount: amount,
            date: date,
            source: source,
            notes: notes,
          ),
        );
        importedCount++;
      } catch (e) {
        AppLogger.d('Row import error: $e');
      }
    }
    return importedCount;
  }

  List<_CompanySalarySummary> _aggregateByCompany(List<_SalaryExportRow> rows) {
    final map = <String, _CompanySalarySummary>{};
    for (final row in rows) {
      final name = row.company.name;
      final current = map[name] ?? _CompanySalarySummary(companyName: name);
      map[name] = current.copyWith(
        count: current.count + 1,
        totalReceived: current.totalReceived + row.payment.amountReceived,
        totalDelay: current.totalDelay + row.payment.delayedByDays,
      );
    }
    return map.values.toList();
  }

  String _salaryStatusLabel(SalaryPaymentStatus status) {
    switch (status) {
      case SalaryPaymentStatus.received:
        return 'Received';
      case SalaryPaymentStatus.partial:
        return 'Partial';
      case SalaryPaymentStatus.delayed:
        return 'Delayed';
      case SalaryPaymentStatus.onHold:
        return 'On Hold';
      case SalaryPaymentStatus.pending:
        return 'Pending';
    }
  }

  Future<void> _shareCsv({
    required String fileName,
    required List<List<dynamic>> rows,
    required String subject,
  }) async {
    final csv = rows
        .map((row) => row.map((cell) => _csvField(cell)).join(','))
        .join('\n');
    final file = await _writeExportFile(fileName, csv);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: subject),
    );
  }

  Future<void> _sharePdf({
    required String fileName,
    required String title,
    String? subtitle,
    required List<String> headers,
    required List<List<String>> rows,
  }) async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        build: (context) => [
          pw.Text(
            title,
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          if (subtitle != null) ...[
            pw.SizedBox(height: 8),
            pw.Text(subtitle, style: const pw.TextStyle(fontSize: 11)),
          ],
          pw.SizedBox(height: 16),
          pw.TableHelper.fromTextArray(headers: headers, data: rows),
          pw.SizedBox(height: 16),
          pw.Text(
            'Generated on ${DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.now())}',
            style: const pw.TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
    final bytes = await doc.save();
    await _writeExportFile(fileName, bytes, binary: true);
    await Printing.sharePdf(bytes: bytes, filename: fileName);
  }


  Future<File> _writeExportFile(
    String fileName,
    dynamic content, {
    bool binary = false,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${directory.path}/SpendX Exports');
    if (!await exportDir.exists()) await exportDir.create(recursive: true);

    final path = '${exportDir.path}/$fileName';
    final file = File(path);
    if (binary) {
      await file.writeAsBytes(content as List<int>);
    } else {
      await file.writeAsString(content as String);
    }
    return file;
  }
}


class _SalaryExportRow {
  const _SalaryExportRow({
    required this.company,
    required this.contract,
    required this.payment,
  });

  final Company company;
  final SalaryContract contract;
  final SalaryPayment payment;
}

class _CompanySalarySummary {
  const _CompanySalarySummary({
    required this.companyName,
    this.count = 0,
    this.totalReceived = 0,
    this.totalDelay = 0,
  });

  final String companyName;
  final int count;
  final double totalReceived;
  final int totalDelay;

  double get avgDelay => count == 0 ? 0 : totalDelay / count;

  _CompanySalarySummary copyWith({
    int? count,
    double? totalReceived,
    int? totalDelay,
  }) {
    return _CompanySalarySummary(
      companyName: companyName,
      count: count ?? this.count,
      totalReceived: totalReceived ?? this.totalReceived,
      totalDelay: totalDelay ?? this.totalDelay,
    );
  }
}
