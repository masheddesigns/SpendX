import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:csv/csv.dart' as csv_pkg;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../core/utils/category_classifier.dart';
import '../data/repositories/category_repo.dart';
import '../data/repositories/transaction_repo.dart';
import '../models/category.dart';
import '../models/transaction.dart';

/// Supported import formats.
enum ImportFormat { csv, markdown, html, json, zip, unknown }

/// Smart importer that auto-detects columns from ANY tabular format.
/// Supports CSV, TSV, Markdown tables, HTML tables, JSON arrays, and ZIP archives (Notion exports).
class SmartImporter {
  SmartImporter._();
  static final instance = SmartImporter._();

  /// Detect format from file extension.
  ImportFormat detectFormatFromPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'csv':
      case 'tsv':
      case 'txt':
        return ImportFormat.csv;
      case 'md':
      case 'markdown':
        return ImportFormat.markdown;
      case 'html':
      case 'htm':
        return ImportFormat.html;
      case 'json':
        return ImportFormat.json;
      case 'zip':
        return ImportFormat.zip;
      default:
        return ImportFormat.unknown;
    }
  }

  /// Detect format from file extension + content sniffing.
  ImportFormat detectFormat(String path, String content) {
    final byExt = detectFormatFromPath(path);
    if (byExt != ImportFormat.unknown) return byExt;

    // Sniff content
    final trimmed = content.trimLeft();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      return ImportFormat.json;
    }
    if (trimmed.startsWith('<') && content.contains('<table')) {
      return ImportFormat.html;
    }
    if (_looksLikeMarkdownTable(content)) return ImportFormat.markdown;

    return ImportFormat.csv;
  }

  /// Parse a file (auto-detects format) and return structured preview rows.
  Future<SmartImportResult> parseFile(File file) async {
    final ext = file.path.split('.').last.toLowerCase();

    // ZIP: extract and find parseable files inside
    if (ext == 'zip') {
      return _parseZip(file);
    }

    final content = await file.readAsString();
    final format = detectFormat(file.path, content);

    if (format == ImportFormat.json) {
      return _parseJsonContent(content);
    }

    List<List<String>> rawRows;
    switch (format) {
      case ImportFormat.csv:
        rawRows = _parseCsv(content);
      case ImportFormat.markdown:
        rawRows = _parseMarkdown(content);
      case ImportFormat.html:
        rawRows = _parseHtml(content);
      default:
        rawRows = _parseCsv(content);
    }

    return _buildResult(rawRows, format);
  }

  /// Smart import — routes data based on detected table type.
  ///
  /// Expenses → transactions
  /// Bills → transactions (expense) with credit card notes
  /// Net Worth → transactions are skipped; returns summary for manual account update
  /// Unknown → treats as expenses (fallback)
  Future<SmartImportSummary> importSmart(SmartImportResult result,
      {String defaultType = 'expense'}) async {
    switch (result.notionType) {
      case NotionTableType.netWorth:
        return _importNetWorth(result.rows);
      case NotionTableType.bills:
        return _importBills(result.rows);
      case NotionTableType.expenses:
      case NotionTableType.unknown:
        return _importExpenses(result.rows, defaultType: defaultType);
    }
  }

  /// Legacy: import all rows as transactions.
  Future<int> importRows(List<SmartImportRow> rows,
      {String defaultType = 'expense'}) async {
    final summary = await _importExpenses(rows, defaultType: defaultType);
    return summary.transactionsAdded;
  }

  // ── EXPENSE IMPORT ──────────────────────────────────────────

  Future<SmartImportSummary> _importExpenses(List<SmartImportRow> rows,
      {String defaultType = 'expense'}) async {
    final txRepo = TransactionRepo();
    final catRepo = CategoryRepo();
    final categories = await catRepo.getAll();
    int imported = 0;
    int skipped = 0;

    for (final row in rows) {
      if (row.skip) { skipped++; continue; }

      String? categoryId;
      // Priority 1: match by explicit category column
      if (row.category != null && row.category!.isNotEmpty) {
        categoryId = _matchCategory(row.category!, categories);
      }
      // Priority 2: keyword classify from description/notes
      if (categoryId == null) {
        final searchText = '${row.category ?? ''} ${row.description ?? ''}';
        final type = row.type ?? defaultType;
        final catName = CategoryClassifier.detect(text: searchText, type: type);
        if (catName != null) {
          final match = categories.where(
              (c) => c.name.toLowerCase() == catName.toLowerCase());
          if (match.isNotEmpty) categoryId = match.first.id;
        }
      }

      String type = row.type ?? defaultType;
      double amount = row.amount.abs();
      if (row.type == null && row.amount < 0) {
        type = 'expense';
      }

      // Dedup: check if same amount + date already exists
      final existing = await txRepo.findByAmountAndDateRange(
        amount: amount,
        from: (row.date ?? DateTime.now()).subtract(const Duration(hours: 12)),
        to: (row.date ?? DateTime.now()).add(const Duration(hours: 12)),
      );
      if (existing.isNotEmpty) {
        debugPrint('[SmartImport] Skipping duplicate: $amount on ${row.date}');
        skipped++;
        continue;
      }

      final txn = Transaction(
        id: const Uuid().v4(),
        userId: 'offline_user',
        type: type,
        amount: amount,
        date: row.date ?? DateTime.now(),
        notes: row.category ?? row.description ?? '',
        categoryId: categoryId,
        source: 'smart_import',
        tags: const [],
      );

      try {
        await txRepo.create(txn);
        imported++;
      } catch (e) {
        debugPrint('[SmartImport] Row failed: $e');
      }
    }

    debugPrint('[SmartImport] Expenses: $imported imported, $skipped skipped');
    return SmartImportSummary(
      transactionsAdded: imported,
      skipped: skipped,
      type: NotionTableType.expenses,
    );
  }

  // ── BILLS IMPORT (credit card payments) ─────────────────────

  Future<SmartImportSummary> _importBills(List<SmartImportRow> rows) async {
    final txRepo = TransactionRepo();
    final catRepo = CategoryRepo();
    final categories = await catRepo.getAll();
    int imported = 0;
    int skipped = 0;

    for (final row in rows) {
      if (row.skip) { skipped++; continue; }

      final amount = (row.paidAmount ?? row.amount).abs();
      if (amount == 0) { skipped++; continue; }

      // Bills are credit card payments → expense type
      String? categoryId;
      // Try to match "Bills" category
      categoryId = _matchCategory('Bills', categories) ??
          _matchCategory(row.category ?? '', categories);

      // Notes: "One Card bill ₹1,678 — Paid"
      final note = '${row.category ?? "Bill"} payment'
          '${row.status != null ? " — ${row.status}" : ""}';

      final txn = Transaction(
        id: const Uuid().v4(),
        userId: 'offline_user',
        type: 'expense',
        amount: amount,
        date: row.date ?? DateTime.now(),
        notes: note,
        categoryId: categoryId,
        source: 'smart_import_bill',
        tags: const [],
      );

      try {
        await txRepo.create(txn);
        imported++;
      } catch (e) {
        debugPrint('[SmartImport] Bill row failed: $e');
      }
    }

    debugPrint('[SmartImport] Bills: $imported imported, $skipped skipped');
    return SmartImportSummary(
      transactionsAdded: imported,
      skipped: skipped,
      type: NotionTableType.bills,
    );
  }

  // ── NET WORTH IMPORT (account balances) ─────────────────────

  Future<SmartImportSummary> _importNetWorth(List<SmartImportRow> rows) async {
    // Net worth rows are balance snapshots, not transactions.
    // We return them as a summary for the UI to display / let user update accounts.
    final accounts = <NetWorthEntry>[];

    for (final row in rows) {
      if (row.skip) continue;

      final name = row.category ?? row.description ?? 'Unknown';
      final balance = row.bankBalance ?? row.amount;
      final invested = row.invested ?? 0;
      final isInvestment = invested > 0 && (row.bankBalance == null || row.bankBalance == 0);

      accounts.add(NetWorthEntry(
        name: name,
        balance: balance,
        invested: invested,
        isInvestment: isInvestment,
        date: row.date,
        status: row.status,
      ));
    }

    debugPrint('[SmartImport] Net Worth: ${accounts.length} entries');
    return SmartImportSummary(
      transactionsAdded: 0,
      skipped: 0,
      type: NotionTableType.netWorth,
      netWorthEntries: accounts,
    );
  }

  // ── Build Result from raw rows ───────────────────────────

  SmartImportResult _buildResult(List<List<String>> rawRows, ImportFormat format) {
    if (rawRows.isEmpty) {
      return SmartImportResult(
        headers: [],
        rows: [],
        mapping: SmartColumnMapping(),
        format: format,
      );
    }

    final headers = rawRows.first.map((e) => e.trim()).toList();
    final dataRows = rawRows.length > 1 ? rawRows.sublist(1) : <List<String>>[];

    final mapping = _autoDetectColumns(headers, dataRows);

    final parsed = <SmartImportRow>[];
    for (final row in dataRows) {
      final r = _parseRow(row, mapping, headers.length);
      if (r != null) parsed.add(r);
    }

    final notionType = _detectNotionTableType(mapping);
    debugPrint('[SmartImporter] Detected Notion type: ${notionType.name}, '
        '${parsed.length} rows');

    return SmartImportResult(
      headers: headers,
      rows: parsed,
      mapping: mapping,
      format: format,
      notionType: notionType,
    );
  }

  // ── ZIP Parsing (Notion exports — handles nested ZIPs) ───

  Future<SmartImportResult> _parseZip(File file) async {
    final bytes = await file.readAsBytes();
    return _parseZipBytes(bytes, depth: 0);
  }

  Future<SmartImportResult> _parseZipBytes(List<int> bytes,
      {required int depth}) async {
    // Prevent infinite recursion
    if (depth > 3) {
      debugPrint('[SmartImporter] Max ZIP nesting depth reached');
      return SmartImportResult(
        headers: [],
        rows: [],
        mapping: SmartColumnMapping(),
        format: ImportFormat.zip,
      );
    }

    final archive = ZipDecoder().decodeBytes(bytes);
    debugPrint('[SmartImporter] ZIP (depth=$depth) has ${archive.length} entries');

    // Collect all parseable files with priority: CSV > Markdown > HTML > JSON
    const priority = {
      ImportFormat.csv: 4,
      ImportFormat.markdown: 3,
      ImportFormat.html: 2,
      ImportFormat.json: 1,
    };

    ArchiveFile? bestFile;
    ImportFormat bestFormat = ImportFormat.unknown;
    int bestSize = 0;

    // Also track nested ZIPs
    ArchiveFile? nestedZip;

    for (final entry in archive) {
      debugPrint('[SmartImporter]   Entry: ${entry.name} '
          '(isFile=${entry.isFile}, size=${entry.size})');

      if (!entry.isFile || entry.size == 0) continue;

      final fmt = detectFormatFromPath(entry.name);

      // Track nested ZIP for recursive extraction
      if (fmt == ImportFormat.zip) {
        if (nestedZip == null || entry.size > nestedZip.size) {
          nestedZip = entry;
        }
        continue;
      }

      final currentPriority = priority[fmt] ?? 0;
      final bestPriority = priority[bestFormat] ?? 0;

      if (currentPriority > bestPriority ||
          (currentPriority == bestPriority && entry.size > bestSize)) {
        bestFile = entry;
        bestFormat = fmt;
        bestSize = entry.size;
      }
    }

    // If no parseable file found but there's a nested ZIP, recurse into it
    if (bestFile == null && nestedZip != null) {
      debugPrint('[SmartImporter] No direct files, extracting nested ZIP: '
          '${nestedZip.name}');
      final nestedBytes = nestedZip.readBytes();
      if (nestedBytes != null && nestedBytes.isNotEmpty) {
        return _parseZipBytes(nestedBytes, depth: depth + 1);
      }
    }

    // Even if we found a file, prefer nested ZIP if it likely has better content
    // (Notion pattern: outer ZIP has only inner ZIP, inner ZIP has CSV files)
    if (bestFile == null) {
      debugPrint('[SmartImporter] No parseable files found in ZIP');
      return SmartImportResult(
        headers: [],
        rows: [],
        mapping: SmartColumnMapping(),
        format: ImportFormat.zip,
      );
    }

    debugPrint('[SmartImporter] Best file: ${bestFile.name} '
        '(format=$bestFormat, size=${bestFile.size})');

    final contentBytes = bestFile.readBytes();
    if (contentBytes == null || contentBytes.isEmpty) {
      debugPrint('[SmartImporter] File content is empty/null');
      return SmartImportResult(
        headers: [],
        rows: [],
        mapping: SmartColumnMapping(),
        format: ImportFormat.zip,
      );
    }

    final content = utf8.decode(contentBytes, allowMalformed: true);
    debugPrint('[SmartImporter] Decoded ${content.length} chars, '
        'first 200: ${content.substring(0, content.length.clamp(0, 200))}');

    final fileName = bestFile.name.split('/').last;

    if (bestFormat == ImportFormat.json) {
      final result = _parseJsonContent(content);
      return SmartImportResult(
        headers: result.headers,
        rows: result.rows,
        mapping: result.mapping,
        format: ImportFormat.zip,
        sourceFileName: fileName,
      );
    }

    List<List<String>> rawRows;
    switch (bestFormat) {
      case ImportFormat.csv:
        rawRows = _parseCsv(content);
      case ImportFormat.markdown:
        rawRows = _parseMarkdown(content);
      case ImportFormat.html:
        rawRows = _parseHtml(content);
      default:
        rawRows = _parseCsv(content);
    }

    debugPrint('[SmartImporter] Parsed ${rawRows.length} raw rows');

    final result = _buildResult(rawRows, ImportFormat.zip);
    return SmartImportResult(
      headers: result.headers,
      rows: result.rows,
      mapping: result.mapping,
      format: ImportFormat.zip,
      sourceFileName: fileName,
    );
  }

  // ── JSON Parsing ─────────────────────────────────────────

  SmartImportResult _parseJsonContent(String content) {
    try {
      final decoded = jsonDecode(content);

      List<Map<String, dynamic>> items;
      if (decoded is List) {
        items = decoded.whereType<Map<String, dynamic>>().toList();
      } else if (decoded is Map<String, dynamic>) {
        // Try common wrapper keys
        for (final key in ['data', 'transactions', 'items', 'records', 'rows', 'results']) {
          if (decoded[key] is List) {
            items = (decoded[key] as List).whereType<Map<String, dynamic>>().toList();
            break;
          }
        }
        items = [decoded];
      } else {
        return SmartImportResult(
          headers: [],
          rows: [],
          mapping: SmartColumnMapping(),
          format: ImportFormat.json,
        );
      }

      if (items.isEmpty) {
        return SmartImportResult(
          headers: [],
          rows: [],
          mapping: SmartColumnMapping(),
          format: ImportFormat.json,
        );
      }

      // Convert JSON objects to tabular rows
      // Collect all keys from all objects for headers
      final allKeys = <String>{};
      for (final item in items) {
        allKeys.addAll(item.keys);
      }
      final headers = allKeys.toList();

      final dataRows = items.map((item) {
        return headers.map((key) => (item[key] ?? '').toString()).toList();
      }).toList();

      final rawRows = [headers, ...dataRows];
      return _buildResult(rawRows, ImportFormat.json);
    } catch (e) {
      debugPrint('JSON parse error: $e');
      return SmartImportResult(
        headers: [],
        rows: [],
        mapping: SmartColumnMapping(),
        format: ImportFormat.json,
      );
    }
  }

  // ── CSV Parsing ──────────────────────────────────────────

  List<List<String>> _parseCsv(String content) {
    final separator = _detectSeparator(content);
    final decoded = csv_pkg.CsvCodec(fieldDelimiter: separator).decode(content);
    return decoded.map((row) => row.map((e) => e.toString()).toList()).toList();
  }

  String _detectSeparator(String content) {
    final semicolons = content.split(';').length;
    final commas = content.split(',').length;
    final tabs = content.split('\t').length;
    if (tabs > commas && tabs > semicolons) return '\t';
    if (semicolons > commas) return ';';
    return ',';
  }

  // ── Markdown Table Parsing ───────────────────────────────

  bool _looksLikeMarkdownTable(String content) {
    final lines = content.split('\n');
    int pipeLines = 0;
    for (final line in lines) {
      if (line.trim().contains('|')) pipeLines++;
      if (pipeLines >= 3) return true;
    }
    return false;
  }

  List<List<String>> _parseMarkdown(String content) {
    final lines = content.split('\n');
    final tableLines = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (RegExp(r'^[\s|:\-]+$').hasMatch(trimmed)) continue;
      if (trimmed.contains('|')) {
        tableLines.add(trimmed);
      }
    }

    if (tableLines.isEmpty) return [];

    return tableLines.map((line) {
      var cleaned = line;
      if (cleaned.startsWith('|')) cleaned = cleaned.substring(1);
      if (cleaned.endsWith('|')) {
        cleaned = cleaned.substring(0, cleaned.length - 1);
      }
      return cleaned.split('|').map((cell) => cell.trim()).toList();
    }).toList();
  }

  // ── HTML Table Parsing ───────────────────────────────────

  List<List<String>> _parseHtml(String content) {
    final rows = <List<String>>[];

    final tableMatch =
        RegExp(r'<table[^>]*>([\s\S]*?)</table>', caseSensitive: false)
            .firstMatch(content);
    if (tableMatch == null) return [];

    final tableContent = tableMatch.group(1)!;

    final trMatches =
        RegExp(r'<tr[^>]*>([\s\S]*?)</tr>', caseSensitive: false)
            .allMatches(tableContent);

    for (final trMatch in trMatches) {
      final trContent = trMatch.group(1)!;
      final cellMatches =
          RegExp(r'<(?:td|th)[^>]*>([\s\S]*?)</(?:td|th)>', caseSensitive: false)
              .allMatches(trContent);

      final cells = cellMatches.map((m) {
        var text = m.group(1)!;
        text = text.replaceAll(RegExp(r'<[^>]*>'), '');
        text = text
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&#8377;', '₹')
            .replaceAll('&#x20B9;', '₹');
        return text.trim();
      }).toList();

      if (cells.isNotEmpty) rows.add(cells);
    }

    return rows;
  }

  // ── Column Auto-Detection ────────────────────────────────

  SmartColumnMapping _autoDetectColumns(
      List<String> headers, List<List<String>> dataRows) {
    final mapping = SmartColumnMapping();

    for (int i = 0; i < headers.length; i++) {
      final h = headers[i].toLowerCase().trim();

      if (mapping.amountCol == null &&
          _matchesAny(h, [
            'amount', 'amt', 'total', 'price', 'cost', 'value', 'sum',
            'debit', 'credit', 'expense', 'money', 'rupee', 'inr',
            'payment', 'charge', 'fee', 'balance', 'paid', 'spent',
            'withdrawal', 'deposit', 'net', 'gross', 'subtotal',
            'transaction amount', 'txn amount', 'bill amount',
            'emi', 'installment', 'premium', 'salary', 'income amount',
          ])) {
        if (_columnHasNumbers(dataRows, i)) {
          mapping.amountCol = i;
          continue;
        }
      }

      if (mapping.dateCol == null &&
          _matchesAny(h, [
            'date', 'due', 'time', 'when', 'day', 'created', 'timestamp',
            'transaction date', 'txn date', 'payment date', 'bill date',
            'purchase date', 'order date', 'booking date', 'value date',
            'posted', 'settled', 'effective date', 'entry date',
            'created at', 'updated at', 'modified', 'period',
          ])) {
        mapping.dateCol = i;
        continue;
      }

      if (mapping.categoryCol == null &&
          _matchesAny(h, [
            'category', 'type', 'expense category', 'group', 'tag',
            'label', 'class', 'head', 'classification', 'segment',
            'budget category', 'spending category', 'expense type',
            'income category', 'income type', 'account head',
            'department', 'project', 'cost center', 'purpose',
          ])) {
        mapping.categoryCol = i;
        continue;
      }

      if (mapping.descCol == null &&
          _matchesAny(h, [
            'description', 'desc', 'note', 'notes', 'memo', 'remark',
            'remarks', 'details', 'narration', 'particular', 'name',
            'item', 'merchant', 'payee', 'vendor', 'beneficiary',
            'reference', 'ref', 'comment', 'reason', 'title',
            'transaction details', 'payment to', 'paid to', 'from',
            'sender', 'receiver', 'store', 'shop', 'company',
            'upi', 'utr', 'order id', 'invoice',
          ])) {
        mapping.descCol = i;
        continue;
      }

      if (mapping.typeCol == null &&
          _matchesAny(h, [
            'transaction type', 'txn type', 'income/expense',
            'credit/debit', 'dr/cr', 'direction', 'flow',
            'entry type', 'mode', 'in/out', 'inflow/outflow',
            'receipt/payment', 'nature', 'side',
          ])) {
        mapping.typeCol = i;
        continue;
      }

      if (mapping.statusCol == null &&
          _matchesAny(h, ['status', 'state', 'paid', 'completed'])) {
        mapping.statusCol = i;
        continue;
      }

      // Notion-specific columns
      if (mapping.paidAmountCol == null &&
          _matchesAny(h, ['paid amount', 'paid amt', 'paid'])) {
        if (_columnHasNumbers(dataRows, i)) {
          mapping.paidAmountCol = i;
          continue;
        }
      }
      if (mapping.remainingCol == null &&
          _matchesAny(h, ['remaining', 'remaining amount', 'balance due'])) {
        mapping.remainingCol = i;
        continue;
      }
      if (mapping.bankBalanceCol == null &&
          _matchesAny(h, ['bank balance', 'bank bal', 'account balance'])) {
        mapping.bankBalanceCol = i;
        continue;
      }
      if (mapping.investedCol == null &&
          _matchesAny(h, ['invested', 'invested balance', 'investment'])) {
        mapping.investedCol = i;
        continue;
      }
    }

    if (mapping.amountCol == null && dataRows.isNotEmpty) {
      for (int i = 0; i < headers.length; i++) {
        if (_columnHasNumbers(dataRows, i)) {
          mapping.amountCol = i;
          break;
        }
      }
    }

    if (mapping.dateCol == null && dataRows.isNotEmpty) {
      for (int i = 0; i < headers.length; i++) {
        if (_columnHasDates(dataRows, i)) {
          mapping.dateCol = i;
          break;
        }
      }
    }

    mapping.descCol ??= mapping.categoryCol;

    return mapping;
  }

  /// Detect Notion table type from column mapping.
  NotionTableType _detectNotionTableType(SmartColumnMapping mapping) {
    if (mapping.hasBankBalance || mapping.hasInvested) {
      return NotionTableType.netWorth;
    }
    if (mapping.hasPaidAmount || mapping.hasRemaining) {
      return NotionTableType.bills;
    }
    return NotionTableType.expenses;
  }

  SmartImportRow? _parseRow(
      List<dynamic> row, SmartColumnMapping mapping, int headerLen) {
    if (row.isEmpty) return null;

    String? getString(int? col) {
      if (col == null || col >= row.length) return null;
      final v = row[col].toString().trim();
      return v.isEmpty ? null : v;
    }

    final amountStr = getString(mapping.amountCol);
    if (amountStr == null) return null;

    final amount = _parseAmount(amountStr);
    if (amount == 0) return null;

    // Parse optional Notion-specific columns
    double? paidAmount;
    if (mapping.paidAmountCol != null) {
      final s = getString(mapping.paidAmountCol);
      if (s != null) paidAmount = _parseAmount(s);
    }
    double? remaining;
    if (mapping.remainingCol != null) {
      final s = getString(mapping.remainingCol);
      if (s != null) remaining = _parseAmount(s);
    }
    double? bankBalance;
    if (mapping.bankBalanceCol != null) {
      final s = getString(mapping.bankBalanceCol);
      if (s != null) bankBalance = _parseAmount(s);
    }
    double? invested;
    if (mapping.investedCol != null) {
      final s = getString(mapping.investedCol);
      if (s != null) invested = _parseAmount(s);
    }

    return SmartImportRow(
      date: _parseDate(getString(mapping.dateCol)),
      description: getString(mapping.descCol),
      amount: amount,
      category: getString(mapping.categoryCol),
      type: _inferType(getString(mapping.typeCol), amount),
      status: getString(mapping.statusCol),
      paidAmount: paidAmount,
      remaining: remaining,
      bankBalance: bankBalance,
      invested: invested,
      rawRow: row.map((e) => e.toString()).toList(),
    );
  }

  // ── Matching Helpers ─────────────────────────────────────

  bool _matchesAny(String header, List<String> keywords) {
    for (final kw in keywords) {
      if (header == kw || header.contains(kw)) return true;
    }
    return false;
  }

  bool _columnHasNumbers(List<List<dynamic>> rows, int col) {
    int numCount = 0;
    for (int i = 0; i < rows.length.clamp(0, 5); i++) {
      if (col < rows[i].length) {
        final s = rows[i][col]
            .toString()
            .replaceAll(RegExp(r'[₹\$€£,\s]'), '');
        if (double.tryParse(s) != null) numCount++;
      }
    }
    return numCount >= 2;
  }

  bool _columnHasDates(List<List<dynamic>> rows, int col) {
    int dateCount = 0;
    for (int i = 0; i < rows.length.clamp(0, 5); i++) {
      if (col < rows[i].length) {
        final d = _parseDate(rows[i][col].toString());
        if (d != null && d.year > 2000 && d.year < 2100) dateCount++;
      }
    }
    return dateCount >= 2;
  }

  String? _matchCategory(String name, List<Category> categories) {
    final lower = name.toLowerCase().trim();

    for (final c in categories) {
      if (c.name.toLowerCase() == lower) return c.id;
    }

    for (final c in categories) {
      if (c.name.toLowerCase().contains(lower) ||
          lower.contains(c.name.toLowerCase())) {
        return c.id;
      }
    }

    const aliases = {
      'food': ['food', 'meal', 'lunch', 'dinner', 'breakfast', 'restaurant', 'cafe', 'snack', 'zomato', 'swiggy', 'biryani', 'pizza', 'burger', 'tea', 'coffee', 'canteen', 'mess', 'tiffin', 'bakery', 'juice', 'ice cream', 'cake', 'dine', 'eat'],
      'transport': ['transport', 'fuel', 'petrol', 'diesel', 'cab', 'uber', 'ola', 'rapido', 'metro', 'bus', 'bike fuel', 'car fuel', 'auto', 'rickshaw', 'parking', 'toll', 'fastag', 'train ticket', 'commute'],
      'groceries': ['grocery', 'groceries', 'supermarket', 'kirana', 'provision', 'vegetables', 'fruits', 'dmart', 'bigbasket', 'blinkit', 'zepto', 'instamart', 'milk', 'egg'],
      'bills': ['bill', 'bills', 'electricity', 'water', 'gas', 'internet', 'wifi', 'broadband', 'recharge', 'bsnl', 'jio', 'airtel', 'vi', 'postpaid', 'prepaid', 'dth', 'phone bill', 'mobile', 'landline', 'maintenance'],
      'rent': ['rent', 'home rent', 'house rent', 'room rent', 'pg', 'hostel', 'flat rent', 'lease'],
      'shopping': ['shopping', 'amazon', 'flipkart', 'myntra', 'meesho', 'ajio', 'clothes', 'apparel', 'shoes', 'gadget', 'electronics', 'furniture', 'decor', 'gift', 'accessories'],
      'health': ['health', 'medical', 'medicine', 'doctor', 'hospital', 'pharmacy', 'lab', 'test', 'dental', 'eye', 'gym', 'yoga', 'fitness', 'insurance', 'apollo', 'practo', 'pharmeasy', '1mg'],
      'entertainment': ['entertainment', 'movie', 'netflix', 'spotify', 'hotstar', 'prime', 'youtube', 'subscription', 'game', 'gaming', 'concert', 'event', 'party', 'outing', 'pub', 'bar', 'club'],
      'education': ['education', 'course', 'book', 'tuition', 'school', 'college', 'university', 'exam', 'coaching', 'udemy', 'coursera', 'stationery', 'fees', 'library'],
      'travel': ['travel', 'trip', 'hotel', 'flight', 'train', 'booking', 'irctc', 'makemytrip', 'goibibo', 'airbnb', 'oyo', 'vacation', 'holiday', 'tour', 'visa', 'passport'],
      'subscriptions': ['subscription', 'subscriptions', 'premium', 'membership', 'annual', 'monthly plan', 'saas'],
      'salary': ['salary', 'income', 'wages', 'pay', 'stipend', 'earning', 'bonus', 'freelance', 'consulting'],
      'investment': ['investment', 'mutual fund', 'sip', 'stock', 'share', 'fd', 'ppf', 'nps', 'gold', 'crypto', 'trading', 'dividend'],
      'others': ['other', 'others', 'misc', 'miscellaneous', 'general', 'unknown', 'uncategorized'],
    };

    for (final entry in aliases.entries) {
      for (final alias in entry.value) {
        if (lower.contains(alias) || alias.contains(lower)) {
          for (final c in categories) {
            if (c.name.toLowerCase() == entry.key) return c.id;
          }
        }
      }
    }

    return null;
  }

  String? _inferType(String? typeStr, double amount) {
    if (typeStr == null) return null;
    final lower = typeStr.toLowerCase().trim();
    if (lower.contains('income') || lower.contains('credit') || lower == 'cr' ||
        lower.contains('deposit') || lower.contains('receipt') ||
        lower.contains('inflow') || lower.contains('received') ||
        lower == 'in' || lower == 'salary' || lower == 'refund') {
      return 'income';
    }
    if (lower.contains('expense') || lower.contains('debit') || lower == 'dr' ||
        lower.contains('withdrawal') || lower.contains('payment') ||
        lower.contains('outflow') || lower.contains('spent') ||
        lower == 'out' || lower == 'paid' || lower == 'purchase') {
      return 'expense';
    }
    return null;
  }

  // ── Parsing ──────────────────────────────────────────────

  double _parseAmount(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'[₹$€£¥]'), '').trim();
    s = s.replaceAll(',', '');
    s = s.replaceAll(RegExp(r'[^\d.\-]'), '');
    return double.tryParse(s) ?? 0;
  }

  DateTime? _parseDate(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final cleaned = raw.trim();

    final formats = [
      'MMMM d, yyyy',
      'MMMM dd, yyyy',
      'MMM d, yyyy',
      'MMM dd, yyyy',
      'yyyy-MM-dd HH:mm:ss',
      'yyyy-MM-dd',
      'dd/MM/yyyy',
      'MM/dd/yyyy',
      'dd-MM-yyyy',
      'dd.MM.yyyy',
      'd/M/yyyy',
      'd-M-yyyy',
      'dd/MM/yy',
      'MM/dd/yy',
    ];

    for (final fmt in formats) {
      try {
        return DateFormat(fmt).parse(cleaned);
      } catch (_) {}
    }

    return DateTime.tryParse(cleaned);
  }
}

// ── Data Models ──────────────────────────────────────────────

/// Detected Notion table type for smart routing.
enum NotionTableType {
  expenses,   // Food, Netflix, Fuel — regular expenses
  bills,      // Credit card bills, SIPs — with "Paid Amount", "Remaining"
  netWorth,   // Bank balances, investments — with "Bank Balance", "Invested"
  unknown,    // Generic table
}

class SmartColumnMapping {
  int? dateCol;
  int? descCol;
  int? amountCol;
  int? categoryCol;
  int? typeCol;
  int? statusCol;
  int? paidAmountCol;
  int? remainingCol;
  int? bankBalanceCol;
  int? investedCol;

  bool get hasAmount => amountCol != null;
  bool get hasDate => dateCol != null;
  bool get hasPaidAmount => paidAmountCol != null;
  bool get hasRemaining => remainingCol != null;
  bool get hasBankBalance => bankBalanceCol != null;
  bool get hasInvested => investedCol != null;
}

class SmartImportRow {
  final DateTime? date;
  final String? description;
  final double amount;
  final String? category;
  final String? type;
  final String? status;
  final double? paidAmount;
  final double? remaining;
  final double? bankBalance;
  final double? invested;
  final List<String> rawRow;
  bool skip;

  SmartImportRow({
    this.date,
    this.description,
    required this.amount,
    this.category,
    this.type,
    this.status,
    this.paidAmount,
    this.remaining,
    this.bankBalance,
    this.invested,
    this.rawRow = const [],
    this.skip = false,
  });
}

class SmartImportResult {
  final List<String> headers;
  final List<SmartImportRow> rows;
  final SmartColumnMapping mapping;
  final ImportFormat format;
  final String? sourceFileName;
  final NotionTableType notionType;

  const SmartImportResult({
    required this.headers,
    required this.rows,
    required this.mapping,
    required this.format,
    this.sourceFileName,
    this.notionType = NotionTableType.unknown,
  });
}

/// Summary of a smart import operation.
class SmartImportSummary {
  final int transactionsAdded;
  final int skipped;
  final NotionTableType type;
  final List<NetWorthEntry> netWorthEntries;
  final String? message;

  const SmartImportSummary({
    this.transactionsAdded = 0,
    this.skipped = 0,
    this.type = NotionTableType.unknown,
    this.netWorthEntries = const [],
    this.message,
  });
}

/// A net worth balance entry from Notion import.
class NetWorthEntry {
  final String name;
  final double balance;
  final double invested;
  final bool isInvestment;
  final DateTime? date;
  final String? status;

  const NetWorthEntry({
    required this.name,
    required this.balance,
    this.invested = 0,
    this.isInvestment = false,
    this.date,
    this.status,
  });

  double get totalValue => isInvestment ? invested : balance;
}
