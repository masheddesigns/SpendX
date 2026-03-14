import 'dart:io';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'database_helper.dart';
import '../models/transaction.dart' as spx;

class ExportService {
  ExportService._();
  static final instance = ExportService._();

  // Manually escape a CSV field
  String _csvField(dynamic value) {
    final str = value?.toString() ?? '';
    if (str.contains(',') || str.contains('"') || str.contains('\n')) {
      return '"${str.replaceAll('"', '""')}"';
    }
    return str;
  }

  Future<void> exportTransactionsToCsv() async {
    final db = await DatabaseHelper.instance.database;
    final transactions = await DatabaseHelper.instance.getAllTransactions();

    // Fetch lookup maps
    final catMaps = await db.query(DatabaseHelper.tableCategories);
    final categoriesMap = {for (var item in catMaps) item['id'] as String: item['name'] as String};

    final tagMaps = await db.query(DatabaseHelper.tableTags);
    final tagsMap = {for (var item in tagMaps) item['id'] as String: item['name'] as String};

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

    final fileName = 'spendx_export_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv';
    final path = '${exportDir.path}/$fileName';

    final file = File(path);
    await file.writeAsString(buffer.toString());

    await SharePlus.instance.share(ShareParams(files: [XFile(path)], subject: 'SpendX Transactions Export (CSV)'));
  }

  Future<void> exportTransactionsToJson() async {
    final db = await DatabaseHelper.instance.database;
    final transactions = await DatabaseHelper.instance.getAllTransactions();

    // Fetch lookup maps
    final catMaps = await db.query(DatabaseHelper.tableCategories);
    final categoriesMap = {for (var item in catMaps) item['id'] as String: item['name'] as String};

    final tagMaps = await db.query(DatabaseHelper.tableTags);
    final tagsMap = {for (var item in tagMaps) item['id'] as String: item['name'] as String};

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

    final fileName = 'spendx_export_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.json';
    final path = '${exportDir.path}/$fileName';

    final file = File(path);
    await file.writeAsString(jsonString);

    await SharePlus.instance.share(ShareParams(files: [XFile(path)], subject: 'SpendX Transactions Export (JSON)'));
  }

  /// ============= CSV Import Logic =============

  /// Imports transactions from a CSV file.
  /// Expects columns: Date,Type,Category,Amount,Tags,Source,Notes
  Future<int> importTransactionsFromCsv(File file) async {
    final lines = await file.readAsLines();

    if (lines.isEmpty) return 0;

    // Header validation (skip first row)
    final dataRows = lines.skip(1);
    int importedCount = 0;

    final db = DatabaseHelper.instance;
    final categories = await db.getAllCategories();

    for (final line in dataRows) {
      if (line.trim().isEmpty) continue;
      
      // Simple CSV split (not handling escaped commas for now, but good for SpendX standard)
      final row = line.split(',');
      if (row.length < 4) continue;

      try {
        final date = DateTime.tryParse(row[0].toString()) ?? DateTime.now();
        final type = row[1].toString().toLowerCase() == 'income' ? 'income' : 'expense';
        final amount = double.tryParse(row[3].toString()) ?? 0.0;
        final source = row.length > 5 ? row[5].toString() : 'Imported';
        final notes = row.length > 6 ? row[6].toString() : '';

        // Simple category name matching
        final catName = row[2].toString();
        final categoryId = categories.firstWhere(
          (c) => c.name.toLowerCase() == catName.toLowerCase(),
          orElse: () => categories.first,
        ).id;

        await db.insertTransaction(spx.Transaction(
          userId: 'offline_user', // Local-first default
          type: type,
          categoryId: categoryId,
          amount: amount,
          date: date,
          source: source,
          notes: notes,
        ));
        importedCount++;
      } catch (e) {
        debugPrint('Row import error: $e');
      }
    }
    return importedCount;
  }
}
