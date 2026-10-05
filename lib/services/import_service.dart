// ignore_for_file: curly_braces_in_flow_control_structures
import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:io';
import 'package:csv/csv.dart' as csv_pkg;
import 'package:intl/intl.dart';
import 'backup_service.dart';
import 'financial_transaction_service.dart';
import '../data/repositories/category_repo.dart';
import '../data/repositories/review_repo.dart';
import '../data/repositories/transaction_repo.dart';
import '../data/repositories/canonical/canonical_transaction_adapter.dart';
import '../models/transaction.dart' as spx;
import '../models/review_item.dart';
import 'data_change_bus.dart';

/// ImportService — handles restoring SpendX backups and importing data from other apps.
class ImportService {
  ImportService({
    FinancialTransactionService? financialService,
    TransactionRepo? transactionRepo,
    CategoryRepo? categoryRepo,
    ReviewRepo? reviewRepo,
  }) : _financialService = financialService ?? FinancialTransactionService(),
       _transactionRepo = transactionRepo ?? TransactionRepo(),
       _categoryRepo = categoryRepo ?? CategoryRepo(),
       _reviewRepo = reviewRepo ?? ReviewRepo();
  static final ImportService instance = ImportService();

  final FinancialTransactionService _financialService;
  final TransactionRepo _transactionRepo;
  final CategoryRepo _categoryRepo;
  final ReviewRepo _reviewRepo;

  // ─── SpendX Backup Restore ────────────────────────────

  Future<bool> importFromFile(File file) async {
    _log("file selected: ${file.path}");
    try {
      final success = await BackupService.instance.restoreFromFile(file);
      return success;
    } catch (e) {
      _log("restore error: $e");
      return false;
    }
  }

  // ─── Generic CSV Import ──────────────────────────────

  /// Imports transactions from a generic CSV with user-defined mapping.
  /// Enforces canonical ingestion:
  /// - Deterministic SHA-256 deduplication
  /// - Creates canonical Evidence
  /// - When [requireReview] is true, stages as pending [ReviewCandidate] (0 postings)
  /// - When direct, routes through [FinancialTransactionService] (balanced postings)
  /// - ZERO writes to legacy `ledger_transactions`
  Future<int> importGenericCSV({
    required File file,
    required int dateCol,
    required int descCol,
    required int amountCol,
    required String type, // 'expense' or 'income'
    String? categoryId,
    bool requireReview = false,
  }) async {
    try {
      final content = await file.readAsString();
      final rows = csv_pkg.CsvCodec().decode(content);
      if (rows.isEmpty) {
        return 0;
      }

      int importedCount = 0;
      final defaultCat = (await _categoryRepo.getAll())
          .firstWhere((c) => c.type == type)
          .id;

      for (int i = 1; i < rows.length; i++) {
        // Skip header
        final row = rows[i];
        if (row.length <= amountCol) {
          continue;
        }

        try {
          final rawDate = row[dateCol].toString();
          final desc = row[descCol].toString();
          final amount = _parseDouble(row[amountCol]).abs();

          if (amount == 0) {
            continue;
          }

          final date = _parseDate(rawDate);
          final fileName = file.path.split(Platform.pathSeparator).last;
          final fingerprint = CanonicalTransactionAdapter.computeSha256(
            'csv|$fileName|$rawDate|$desc|$amount|$type',
          );

          // Deduplication: skip if already present
          if (await _transactionRepo.existsByExternalRef(fingerprint)) {
            _log("Skipping duplicate CSV row $i (fingerprint: $fingerprint)");
            continue;
          }

          if (requireReview) {
            // Stage as review candidate (0 postings, non-accounting)
            final reviewItem = ReviewItem(
              rawSource: 'csv_import',
              parsed: ParsedTransaction(
                rawText: '$rawDate, $desc, $amount',
                amount: amount,
                isCredit: type == 'income',
                date: date,
                source: 'csv',
                refId: fingerprint,
                merchant: desc,
              ),
              confidence: 0.5,
            );
            await _reviewRepo.insert(reviewItem);
          } else {
            // Canonical double-entry transaction
            final tx = spx.Transaction(
              userId: 'offline_user',
              type: type,
              amount: amount,
              date: date,
              notes: desc,
              categoryId: categoryId ?? defaultCat,
              source: 'import_csv',
              externalRef: fingerprint,
            );

            await _financialService.createTransaction(tx);
          }

          importedCount++;
        } catch (e) {
          _log("row $i error: $e");
        }
      }
      DataChangeBus.instance.notify();
      return importedCount;
    } catch (e) {
      _log("Generic import error: $e");
      return 0;
    }
  }

  // ─── Utils ───────────────────────────────────────────

  DateTime _parseDate(String raw) {
    // Clean string (remove "##" or trailing spaces)
    String cleaned = raw.replaceAll('##', '').trim();
    if (cleaned.isEmpty) {
      return DateTime.now();
    }

    final formats = [
      'yyyy-MM-dd HH:mm:ss',
      'yyyy-MM-dd HH:mm',
      'yyyy-MM-dd',
      'dd/MM/yyyy HH:mm',
      'dd/MM/yyyy',
      'dd-MM-yyyy HH:mm',
      'dd-MM-yyyy',
      'MM/dd/yyyy HH:mm',
      'MM/dd/yyyy',
      'dd.MM.yyyy HH:mm',
      'dd.MM.yyyy',
      'dd/MM/yy HH:mm',
      'dd/MM/yy',
      'MM/dd/yy HH:mm',
      'MM/dd/yy',
      'd/M/yyyy',
      'd-M-yyyy',
    ];

    for (final fmt in formats) {
      try {
        return DateFormat(fmt).parse(cleaned);
      } catch (_) {}
    }
    // Try native DateTime parse
    return DateTime.tryParse(cleaned) ?? DateTime.now();
  }

  double _parseDouble(dynamic value) {
    if (value == null) {
      return 0.0;
    }
    String s = value.toString().trim().replaceAll(' ', '');
    if (s.isEmpty) {
      return 0.0;
    }

    // Handle European decimals (e.g. 1.234,56 -> 1234.56 or 1,23 -> 1.23)
    // If there's a comma and no dots, or comma is after dot, treat comma as decimal
    if (s.contains(',') && !s.contains('.')) {
      s = s.replaceAll(',', '.');
    } else if (s.contains(',') && s.contains('.')) {
      if (s.indexOf(',') > s.indexOf('.')) {
        // Dot is likely thousand separator, comma is decimal
        s = s.replaceAll('.', '').replaceAll(',', '.');
      } else {
        // Comma is likely thousand separator, dot is decimal
        s = s.replaceAll(',', '');
      }
    }

    // Remove any non-numeric chars except dot and minus
    s = s.replaceAll(RegExp(r'[^\d.-]'), '');

    return double.tryParse(s) ?? 0.0;
  }

  void _log(String msg) => debugPrint("[IMPORT] $msg");
}

