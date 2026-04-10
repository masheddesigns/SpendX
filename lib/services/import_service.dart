// ignore_for_file: curly_braces_in_flow_control_structures
import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:io';
import 'package:csv/csv.dart' as csv_pkg;
import 'package:intl/intl.dart';
import 'backup_service.dart';
import '../data/repositories/category_repo.dart';
import '../data/repositories/ledger_repo.dart';
import '../data/repositories/transaction_repo.dart';
import '../data/repositories/vehicle_repo.dart';
import '../models/vehicle.dart';
import '../models/transaction.dart' as spx;
import '../models/ledger_transaction.dart';
import 'data_change_bus.dart';

/// ImportService — handles restoring SpendX backups and importing data from other apps.
class ImportService {
  ImportService._({
    LedgerRepo? ledgerRepo,
    VehicleRepo? vehicleRepo,
    TransactionRepo? transactionRepo,
    CategoryRepo? categoryRepo,
  }) : _ledgerRepo = ledgerRepo ?? LedgerRepo(),
       _vehicleRepo = vehicleRepo ?? VehicleRepo(),
       _transactionRepo = transactionRepo ?? TransactionRepo(),
       _categoryRepo = categoryRepo ?? CategoryRepo();
  static final ImportService instance = ImportService._();

  final LedgerRepo _ledgerRepo;
  final VehicleRepo _vehicleRepo;
  final TransactionRepo _transactionRepo;
  final CategoryRepo _categoryRepo;

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

  double _cleanDouble(double value) {
    return double.parse(value.toStringAsFixed(2));
  }

  /// Prepares a preview of fuel logs from a CSV file.
  Future<List<FuelImportRow>> prepareFuelImportPreview(
    File file,
    String vehicleId,
  ) async {
    try {
      final vehicle = await _vehicleRepo.getVehicleById(vehicleId);
      final tankCapacity = vehicle?.tankCapacity ?? 50.0;

      final content = await file.readAsString();

      // Auto-detect separator
      String separator = ',';
      if (content.contains(';') &&
          (content.split(';').length > content.split(',').length)) {
        separator = ';';
      }
      _log("Detected separator: '$separator'");

      final rows = csv_pkg.CsvCodec(fieldDelimiter: separator).decode(content);
      _log("Rows decoded: ${rows.length}");
      if (rows.isEmpty) {
        return [];
      }

      String snippet = rows[0].toString();
      if (snippet.length > 80) {
        snippet = snippet.substring(0, 80);
      }
      _log("First row snippet: $snippet");

      // 1. Format Detection & Column Mapping
      int dateIdx = -1,
          odoIdx = -1,
          fuelIdx = -1,
          fullIdx = -1,
          pPlIdx = -1,
          totalIdx = -1;
      int startIndex = -1;
      String detectedFormat = "UNKNOWN";

      // Scan up to 30 rows to find the actual fuel logs section (skipping vehicle metadata)
      for (int i = 0; i < (rows.length < 30 ? rows.length : 30); i++) {
        final r = rows[i];
        if (r.isEmpty) {
          continue;
        }
        final rowStr = r.join(' ').toLowerCase();

        // Detection Logic: Must have specific Fuel Log keywords
        bool hasDate =
            rowStr.contains('date') && !rowStr.contains('dateformat');
        bool hasOdo =
            rowStr.contains('odometer') ||
            (rowStr.contains('odo') && !rowStr.contains('model'));
        bool hasFuel =
            rowStr.contains('fuel amount') ||
            rowStr.contains('litres') ||
            rowStr.contains('volume');
        bool hasCost =
            rowStr.contains('total cost') || rowStr.contains('total price');

        // Fuelio logs usually start with a header containing most of these
        if (hasDate && (hasOdo || hasFuel || hasCost)) {
          _log("Real Log Header found at row $i: $rowStr");
          detectedFormat =
              (rowStr.contains('volume') || rowStr.contains('fill-up'))
              ? "FUELIO"
              : "CUSTOM";
          startIndex = i + 1;
          for (int j = 0; j < r.length; j++) {
            final col = r[j].toString().toLowerCase().trim().replaceAll(
              '##',
              '',
            );
            if (col.contains('date') || col.contains('time')) {
              dateIdx = j;
            } else if (col.contains('odometer') ||
                col.contains('odo') ||
                (col.contains('km') && !col.contains('/km')))
              odoIdx = j;
            else if (col.contains('fuel amount') ||
                col.contains('litres') ||
                col.contains('volume') ||
                col.contains('quantity'))
              fuelIdx = j;
            else if (col.contains('full'))
              fullIdx = j;
            else if (col.contains('price/unit') ||
                col.contains('price per unit') ||
                col.contains('price per litre'))
              pPlIdx = j;
            else if (col.contains('total cost') ||
                col.contains('total price') ||
                col.contains('amount') ||
                col == 'cost' ||
                col == 'price')
              totalIdx = j;
          }
          _log(
            "Mapped indices: Date:$dateIdx, Odo:$odoIdx, Fuel:$fuelIdx, PPl:$pPlIdx, Total:$totalIdx",
          );
          break;
        }
      }

      // Fallback if no header found
      if (startIndex == -1) {
        detectedFormat = "LEGACY";
        startIndex =
            (rows[0].isNotEmpty && rows[0][0].toString().contains('##'))
            ? 1
            : 0;
        dateIdx = 0;
        odoIdx = 1;
        fuelIdx = 2;
        fullIdx = 3;
        pPlIdx = 4;
        totalIdx = 5;
        _log("Using LEGACY fallback indexing: 0..5");
      }
      _log("Format: $detectedFormat, startIndex: $startIndex");

      // 2. Parse & Normalize
      List<FuelImportRow> previewRows = [];
      for (int i = startIndex; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) {
          continue;
        }

        try {
          // Date Handling
          DateTime? date;
          FuelImportStatus status = FuelImportStatus.valid;
          String? statusMsg;

          if (dateIdx != -1 && row.length > dateIdx) {
            date = _parseDate(row[dateIdx].toString());
          }

          if (date == null ||
              date.isAfter(DateTime.now().add(const Duration(days: 1)))) {
            date = DateTime.now();
            status = FuelImportStatus.warning;
            statusMsg = "Invalid or missing date";
          }

          double odometer = odoIdx != -1 && row.length > odoIdx
              ? _parseDouble(row[odoIdx])
              : 0.0;
          double litres = fuelIdx != -1 && row.length > fuelIdx
              ? _parseDouble(row[fuelIdx])
              : 0.0;

          // --- STRICT DATA CLEANUP ---
          if (odometer <= 0 || litres <= 0) {
            _log("Skipping invalid row $i (Odo:$odometer, L:$litres)");
            continue;
          }

          double pPl = pPlIdx != -1 && row.length > pPlIdx
              ? _parseDouble(row[pPlIdx])
              : 0.0;
          double total = totalIdx != -1 && row.length > totalIdx
              ? _parseDouble(row[totalIdx])
              : 0.0;

          // --- STRICT COST RESOLUTION ---
          if (total > 0 && pPl > 0) {
            if (total < 150 && pPl > 350 && litres > 1) {
              // total is likely ppl, ppl is likely total
              final temp = total;
              total = pPl;
              pPl = temp;
              status = FuelImportStatus.corrected;
              statusMsg = "Swapped Price and Total Cost";
            } else if (total < 150 && total > 0 && litres > 2.0) {
              pPl = total;
              total = pPl * litres;
              status = FuelImportStatus.corrected;
              statusMsg = "Interpreted Total as Price/Litre";
            }
          } else if (total > 0 && pPl == 0) {
            if (total < 250 && litres > 2.0) {
              pPl = total;
              total = pPl * litres;
              status = FuelImportStatus.corrected;
              statusMsg = "Converted Price/Litre to Total Cost";
            } else {
              pPl = total / litres;
            }
          } else if (pPl > 0 && total == 0) {
            if (pPl > 350) {
              total = pPl;
              pPl = total / litres;
              status = FuelImportStatus.corrected;
              statusMsg = "Interpreted Price as Total Cost";
            } else {
              total = pPl * litres;
            }
          }

          if (total <= 0) {
            _log("Skipping row $i: total cost is zero");
            continue;
          }

          // Rounding Fix
          odometer = _cleanDouble(odometer);
          litres = _cleanDouble(litres);
          total = _cleanDouble(total);
          pPl = _cleanDouble(total / litres);

          // Sanity Checks
          if (pPl < 50 || pPl > 180) {
            if (status != FuelImportStatus.corrected) {
              status = FuelImportStatus.warning;
              statusMsg = "Suspicious PPL: ₹${pPl.toStringAsFixed(1)}";
            }
          }

          if (litres > tankCapacity * 1.5) {
            status = FuelImportStatus.warning;
            statusMsg = "High volume: ${litres}L (Cap:${tankCapacity}L)";
          }

          // Full Tank Inference (90% rule)
          bool isFull =
              fullIdx != -1 &&
              row.length > fullIdx &&
              (row[fullIdx].toString() == '1' ||
                  row[fullIdx].toString().toLowerCase() == 'true');
          if (!isFull && litres >= (tankCapacity * 0.9)) {
            isFull = true;
          }

          previewRows.add(
            FuelImportRow(
              date: date,
              odometer: odometer,
              litres: litres,
              totalCost: total,
              pricePerLitre: pPl,
              isFullTank: isFull,
              notes: row.length > 10
                  ? row[10].toString()
                  : "Imported ($detectedFormat)",
              status: status,
              statusMessage: statusMsg,
            ),
          );
        } catch (e) {
          _log("Row $i error: $e");
        }
      }

      // Sort by Odometer for preview
      previewRows.sort((a, b) => a.odometer.compareTo(b.odometer));
      _log("Returning ${previewRows.length} rows for preview");
      return previewRows;
    } catch (e) {
      _log("General process error: $e");
      return [];
    }
  }

  /// Saves a list of fuel import rows after user confirmation.
  Future<int> saveFuelImportRows(
    List<FuelImportRow> importRows,
    String vehicleId,
  ) async {
    try {
      int importedCount = 0;
      double lastOdo = 0;

      // Ensure chronological order for proper efficiency calculation
      importRows.sort((a, b) => a.odometer.compareTo(b.odometer));

      for (final row in importRows) {
        // Progression check
        if (row.odometer <= lastOdo) {
          _log("Skipping non-progressive at ${row.odometer}");
          continue;
        }

        try {
          final log = row.toFuelLog(vehicleId);
          await _vehicleRepo.insertFuelLog(log);

          final countStr = importedCount.toString().padLeft(3, '0');
          await _transactionRepo.insert(
            spx.Transaction(
              id: 'TXN_FUEL_${DateTime.now().millisecondsSinceEpoch}_$countStr',
              userId: 'offline_user',
              type: 'expense',
              amount: log.totalCost,
              date: log.date,
              notes: 'Imported: ${log.notes ?? "Fuel fill-up"}',
              source: 'vehicle',
              relatedEntityId: log.id,
              vehicleId: vehicleId,
            ),
          );

          await _ledgerRepo.insert(
            LedgerTransaction(
              type: LedgerType.fuel_expense,
              amount: log.totalCost,
              date: log.date,
              note: log.notes ?? 'Imported Fuel Log',
              referenceId: log.id,
            ),
          );

          lastOdo = row.odometer;
          importedCount++;
        } catch (e) {
          _log("Save error row ${row.odometer}: $e");
        }
      }
      DataChangeBus.instance.notify();
      return importedCount;
    } catch (e) {
      _log("Bulk save error: $e");
      return 0;
    }
  }

  // ─── Generic CSV Import ──────────────────────────────

  /// Imports transactions from a generic CSV with user-defined mapping.
  Future<int> importGenericCSV({
    required File file,
    required int dateCol,
    required int descCol,
    required int amountCol,
    required String type, // 'expense' or 'income'
    String? categoryId,
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
          final tx = spx.Transaction(
            userId: 'offline_user',
            type: type,
            amount: amount,
            date: date,
            notes: desc,
            categoryId: categoryId ?? defaultCat,
            source: 'import',
          );

          await _transactionRepo.insert(tx);

          // V19 Ledger
          await _ledgerRepo.insert(
            LedgerTransaction(
              type: type == 'income' ? LedgerType.income : LedgerType.expense,
              amount: amount,
              date: date,
              note: desc,
              categoryId: tx.categoryId,
              referenceId: tx.id,
            ),
          );

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

enum FuelImportStatus { valid, warning, corrected }

class FuelImportRow {
  DateTime date;
  double odometer;
  double litres;
  double totalCost;
  double pricePerLitre;
  bool isFullTank;
  String? notes;
  FuelImportStatus status;
  String? statusMessage;

  FuelImportRow({
    required this.date,
    required this.odometer,
    required this.litres,
    required this.totalCost,
    double? pricePerLitre,
    this.isFullTank = true,
    this.notes,
    this.status = FuelImportStatus.valid,
    this.statusMessage,
  }) : pricePerLitre = pricePerLitre ?? (litres > 0 ? totalCost / litres : 0.0);

  FuelLog toFuelLog(String vehicleId) => FuelLog(
    vehicleId: vehicleId,
    odometer: odometer,
    litres: litres,
    pricePerLitre: pricePerLitre,
    totalCost: totalCost,
    date: date,
    isFullTank: isFullTank,
    notes: notes,
  );
}
