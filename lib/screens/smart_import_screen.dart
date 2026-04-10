import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/smart_importer.dart';
import '../theme/app_theme.dart';
import '../utils/app_format.dart';

/// Smart import screen — auto-detects columns from CSV, Markdown, HTML, JSON, ZIP.
/// Accepts an optional [sharedFilePath] for files shared from other apps.
class SmartImportScreen extends StatefulWidget {
  final String? sharedFilePath;
  const SmartImportScreen({super.key, this.sharedFilePath});

  @override
  State<SmartImportScreen> createState() => _SmartImportScreenState();
}

class _SmartImportScreenState extends State<SmartImportScreen> {
  SmartImportResult? _result;
  bool _isLoading = false;
  bool _isImporting = false;
  String _defaultType = 'expense';

  @override
  void initState() {
    super.initState();
    if (widget.sharedFilePath != null) {
      // Auto-parse the shared file
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _parseSharedFile(widget.sharedFilePath!);
      });
    }
  }

  Future<void> _parseSharedFile(String path) async {
    setState(() => _isLoading = true);
    try {
      final file = File(path);
      final result = await SmartImporter.instance.parseFile(file);
      setState(() => _result = result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Parse error: $e')));
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'csv', 'tsv', 'txt',
        'md', 'markdown',
        'html', 'htm',
        'json',
        'zip',
      ],
    );
    if (picked == null || picked.files.single.path == null) return;

    setState(() => _isLoading = true);
    try {
      final file = File(picked.files.single.path!);
      final result = await SmartImporter.instance.parseFile(file);
      setState(() => _result = result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Parse error: $e')));
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _import() async {
    if (_result == null) return;
    setState(() => _isImporting = true);

    final summary = await SmartImporter.instance
        .importSmart(_result!, defaultType: _defaultType);

    if (mounted) {
      String msg;
      switch (summary.type) {
        case NotionTableType.netWorth:
          msg = '${summary.netWorthEntries.length} account balances detected';
        case NotionTableType.bills:
          msg = '${summary.transactionsAdded} bill payments imported';
        case NotionTableType.expenses:
        case NotionTableType.unknown:
          msg = '${summary.transactionsAdded} transactions imported'
              '${summary.skipped > 0 ? ', ${summary.skipped} skipped' : ''}';
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      Navigator.pop(context, true);
    }
  }

  String _notionTypeLabel(NotionTableType type) {
    switch (type) {
      case NotionTableType.expenses: return 'Expenses';
      case NotionTableType.bills: return 'Bills/SIPs';
      case NotionTableType.netWorth: return 'Net Worth';
      case NotionTableType.unknown: return '';
    }
  }

  Color _notionTypeColor(NotionTableType type) {
    switch (type) {
      case NotionTableType.expenses: return Colors.green;
      case NotionTableType.bills: return Colors.orange;
      case NotionTableType.netWorth: return Colors.blue;
      case NotionTableType.unknown: return Colors.grey;
    }
  }

  String _formatLabel(ImportFormat format) {
    switch (format) {
      case ImportFormat.csv:
        return 'CSV';
      case ImportFormat.markdown:
        return 'Markdown';
      case ImportFormat.html:
        return 'HTML';
      case ImportFormat.json:
        return 'JSON';
      case ImportFormat.zip:
        return 'ZIP Archive';
      case ImportFormat.unknown:
        return 'File';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mapping = _result?.mapping;
    final rows = _result?.rows ?? [];
    final validRows = rows.where((r) => !r.skip).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Import'),
        actions: [
          if (_result != null)
            TextButton(
              onPressed: _isImporting ? null : _import,
              child: _isImporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('Import $validRows',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: _result == null
          ? _buildPickerState(cs)
          : _buildPreviewState(cs, mapping!, rows),
    );
  }

  Widget _buildPickerState(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.upload_file_rounded, size: 64,
                color: cs.primary.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            const Text('Smart Import',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Import from CSV, Markdown, HTML, JSON, or ZIP archives '
              '(Notion exports). Columns are auto-detected.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                _formatChip('CSV', Icons.table_chart, Colors.teal),
                _formatChip('JSON', Icons.data_object, Colors.amber.shade700),
                _formatChip('Markdown', Icons.article, Colors.deepPurple),
                _formatChip('HTML', Icons.code, Colors.orange),
                _formatChip('ZIP', Icons.folder_zip, Colors.indigo),
              ],
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _isLoading ? null : _pickFile,
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.folder_open_rounded),
              label: const Text('Choose File'),
              style: FilledButton.styleFrom(minimumSize: const Size(200, 52)),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.lightbulb_outline, size: 18,
                      color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Notion users: Export your database as CSV or ZIP and import directly.',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _formatChip(String label, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildPreviewState(
      ColorScheme cs, SmartColumnMapping mapping, List<SmartImportRow> rows) {
    return Column(
      children: [
        // ── Detection summary ──────────────────────────────
        Container(
          padding: AppSpacing.cardPadding,
          color: cs.surfaceContainerHigh,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome, color: cs.primary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${_formatLabel(_result!.format)} · ${rows.length} rows',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            if (_result!.notionType != NotionTableType.unknown) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _notionTypeColor(_result!.notionType).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  _notionTypeLabel(_result!.notionType),
                                  style: TextStyle(
                                    color: _notionTypeColor(_result!.notionType),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (_result!.sourceFileName != null)
                          Text(
                            'From: ${_result!.sourceFileName}',
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _pickFile,
                    child: const Text('Change File'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (mapping.hasAmount)
                    _chip('Amount', cs.primary),
                  if (mapping.hasDate)
                    _chip('Date', Colors.teal),
                  if (mapping.categoryCol != null)
                    _chip('Category', Colors.orange),
                  if (mapping.descCol != null)
                    _chip('Description', Colors.purple),
                  if (mapping.typeCol != null)
                    _chip('Type', Colors.blue),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Default type: ', style: TextStyle(
                      color: cs.onSurfaceVariant, fontSize: 13)),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'expense', label: Text('Expense')),
                      ButtonSegment(value: 'income', label: Text('Income')),
                    ],
                    selected: {_defaultType},
                    onSelectionChanged: (v) =>
                        setState(() => _defaultType = v.first),
                    style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        textStyle: WidgetStatePropertyAll(
                            TextStyle(fontSize: 12))),
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── Preview list ───────────────────────────────────
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final row = rows[index];
              return _buildRow(cs, row, index);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRow(ColorScheme cs, SmartImportRow row, int index) {
    final isExpense = (row.type ?? _defaultType) == 'expense';

    return Card(
      margin: EdgeInsets.zero,
      color: row.skip ? cs.surfaceContainerHighest : null,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: AppSpacing.cardPadding,
        leading: Checkbox(
          value: !row.skip,
          onChanged: (v) => setState(() => row.skip = !(v ?? true)),
        ),
        title: Text(
          row.category ?? row.description ?? 'Row ${index + 1}',
          style: TextStyle(
            fontWeight: FontWeight.w500,
            decoration: row.skip ? TextDecoration.lineThrough : null,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          row.date != null
              ? '${row.date!.day}/${row.date!.month}/${row.date!.year}'
              : 'No date',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
        ),
        trailing: Text(
          '${isExpense ? "-" : "+"} ${AppFormat.currency(row.amount)}',
          style: TextStyle(
            color: isExpense ? cs.error : Colors.green,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}
