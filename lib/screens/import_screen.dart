import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../services/database_helper.dart';
import '../utils/app_format.dart';
import '../theme/app_theme.dart';
import '../services/gemini_service.dart';
import '../widgets/custom_snackbar.dart';
import '../services/export_service.dart';

class ImportScreen extends StatefulWidget {
  final String? initialMethod; // 'ai' or 'csv'
  const ImportScreen({super.key, this.initialMethod});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  List<_PreviewRow> _rows = [];
  List<List<dynamic>> _rawRows = [];
  bool _loading = false;
  int _importedCount = 0;
  int _skippedCount = 0;
  bool _done = false;
  bool _hasTriggeredInitial = false;

  int _dateCol = 0;
  int _descCol = 1;
  int _amountCol = 2;

  Future<void> _importCsv() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result != null && result.files.single.path != null) {
        setState(() => _loading = true);
        final file = File(result.files.single.path!);
        final count = await ExportService.instance.importTransactionsFromCsv(file);
        
        if (!mounted) return;
        setState(() => _loading = false);
        if (mounted) {
          CustomSnackBar.show(context, message: '✅ Imported $count transactions successfully!');
        }
      }
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        CustomSnackBar.show(context, message: 'Error importing CSV: $e', isError: true);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hasTriggeredInitial) {
        if (widget.initialMethod == 'ai') {
          _pickFile();
        } else if (widget.initialMethod == 'csv') {
          _importCsv();
        }
        _hasTriggeredInitial = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Bank Statement'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _done
              ? _buildResultView()
              : _rows.isEmpty && _rawRows.isEmpty
                  ? _buildPickFileView()
                  : _buildPreviewView(),
    );
  }

  Widget _buildPickFileView() => SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Choose Import Method', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
        const SizedBox(height: 20),
        
        _importCard(
          context,
          title: 'AI / Standard Import',
          subtitle: 'Scan PDF/Images or map a standard bank CSV',
          icon: Icons.auto_awesome,
          color: Colors.teal,
          onTap: _pickFile,
        ),
        const SizedBox(height: 16),
        
        _importCard(
          context,
          title: 'Bulk CSV Backup',
          subtitle: 'Import a previously exported SpendX CSV file',
          icon: Icons.upload_file,
          color: Colors.orange,
          onTap: _importCsv,
        ),
        const SizedBox(height: 16),
        
        _importCard(
          context,
          title: 'Cloud Restore',
          subtitle: 'Google Drive / Dropbox (Coming Soon)',
          icon: Icons.cloud_download,
          color: Colors.blue,
          onTap: () => CustomSnackBar.show(context, message: 'Cloud integration is currently in development!'),
        ),
      ],
    ),
  );

  Widget _importCard(BuildContext context, {required String title, required String subtitle, required IconData icon, required Color color, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outline),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewView() {
    final newCount = _rows.where((r) => !r.isDuplicate).length;
    final dupCount = _rows.where((r) => r.isDuplicate).length;
    return Column(children: [
      Container(
        padding: const EdgeInsets.all(14),
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _colPicker('Date', _dateCol, (v) { setState(() => _dateCol = v); _reparse(); }),
            const SizedBox(width: 16),
            _colPicker('Description', _descCol, (v) { setState(() => _descCol = v); _reparse(); }),
            const SizedBox(width: 16),
            _colPicker('Amount', _amountCol, (v) { setState(() => _amountCol = v); _reparse(); }),
          ]),
        ),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: _rows.length.clamp(0, 30),
          itemBuilder: (_, i) {
            final row = _rows[i];
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: row.isDuplicate ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.08) : Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
                border: row.isDuplicate ? Border.all(color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.3)) : null,
              ),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(row.description, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(row.formattedDate, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
                ])),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${AppFormat.currency(row.rawAmount)}', style: TextStyle(color: row.type == 'expense' ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 13)),
                  if (row.isDuplicate) Text('duplicate', style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontSize: 10)),
                ]),
              ]),
            );
          },
        ),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(children: [
          Text('$newCount new · $dupCount duplicates', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: newCount > 0 ? _import : null,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, padding: const EdgeInsets.symmetric(vertical: 14)),
              child: Text('Import $newCount Transactions'),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _buildResultView() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.check_circle, color: Colors.green, size: 80),
      const SizedBox(height: 20),
      const Text('Import Complete!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text('$_importedCount imported · $_skippedCount skipped', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 24),
      ElevatedButton(onPressed: () => Navigator.pop(context), style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Theme.of(context).colorScheme.onPrimary), child: const Text('Done')),
    ]),
  );

  Widget _colPicker(String label, int val, ValueChanged<int> onChanged) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
      const SizedBox(height: 4),
      DropdownButton<int>(
        value: val,
        dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13),
        items: List.generate(10, (i) => DropdownMenuItem(value: i, child: Text('Col ${i + 1}'))),
        onChanged: (v) => onChanged(v!),
      ),
    ],
  );

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv', 'txt', 'pdf', 'png', 'jpg', 'jpeg']);
    if (result == null || result.files.isEmpty) return;
    setState(() => _loading = true);
    
    final path = result.files.first.path!;
    final ext = path.split('.').last.toLowerCase();

    if (['pdf', 'png', 'jpg', 'jpeg'].contains(ext)) {
      CustomSnackBar.show(context, message: 'AI is analyzing the document...');
      GeminiService.instance.init();
      final aiResults = await GeminiService.instance.scanStatement(File(path));
      
      if (!mounted) return;
      if (aiResults.isNotEmpty && aiResults.first.containsKey('error')) {
        CustomSnackBar.show(context, message: 'AI Parsing failed: ${aiResults.first['error']}', isError: true);
        setState(() => _loading = false);
        return;
      }
      
      final existingTxns = await DatabaseHelper.instance.getAllTransactions();
      final rows = <_PreviewRow>[];
      for (final tx in aiResults) {
        final desc = tx['merchant'] ?? 'Unknown AI Row';
        final rawAmt = tx['amount']?.replaceAll(RegExp(r'[₹,\s]'), '') ?? '0';
        final amount = double.tryParse(rawAmt) ?? 0.0;
        if (amount == 0.0) continue;

        final type = (tx['type']?.toLowerCase().contains('income') ?? false) ? 'income' : 'expense';
        final parsedDate = _parseDate(tx['date'] ?? '');
        
        final isDup = existingTxns.any((t) => t.amount == amount && t.date.difference(parsedDate).inDays.abs() <= 1);
        rows.add(_PreviewRow(
          formattedDate: tx['date'] ?? '', 
          description: desc, 
          amount: amount.toStringAsFixed(0), 
          type: type, 
          isDuplicate: isDup, 
          parsedDate: parsedDate, 
          rawAmount: amount
        ));
      }
      if (mounted) {
        setState(() { _rows = rows; _loading = false; });
        CustomSnackBar.show(context, message: 'AI successfully analyzed ${rows.length} transactions!');
      }
      return;
    }

    final content = await File(path).readAsString();
    _rawRows = CsvCodec(fieldDelimiter: ',').decode(content);
    if (_rawRows.length > 1) _rawRows = _rawRows.sublist(1);
    await _reparse();
    setState(() => _loading = false);
  }

  Future<void> _reparse() async {
    final existingTxns = await DatabaseHelper.instance.getAllTransactions();
    final rows = <_PreviewRow>[];
    for (final row in _rawRows) {
      if (row.length <= _amountCol) continue;
      final rawDate = row.length > _dateCol ? row[_dateCol].toString().trim() : '';
      final desc = row.length > _descCol ? row[_descCol].toString().trim() : '';
      final rawAmt = row.length > _amountCol ? row[_amountCol].toString().trim().replaceAll(RegExp(r'[₹,\s]'), '') : '';
      final amount = double.tryParse(rawAmt) ?? 0;
      if (amount == 0 || desc.isEmpty) continue;
      final isExpense = amount < 0 || desc.toLowerCase().contains('dr') || desc.toLowerCase().contains('debit');
      final absAmount = amount.abs();
      final parsedDate = _parseDate(rawDate);
      final isDup = existingTxns.any((t) => t.amount == absAmount && t.date.difference(parsedDate).inDays.abs() <= 1);
      rows.add(_PreviewRow(formattedDate: rawDate, description: desc, amount: absAmount.toStringAsFixed(0), type: isExpense ? 'expense' : 'income', isDuplicate: isDup, parsedDate: parsedDate, rawAmount: absAmount));
    }
    if (mounted) setState(() => _rows = rows);
  }

  DateTime _parseDate(String raw) {
    final formats = ['dd/MM/yyyy', 'dd-MM-yyyy', 'MM/dd/yyyy', 'yyyy-MM-dd', 'dd MMM yyyy', 'dd MMM yy'];
    for (final fmt in formats) {
      try { return DateFormat(fmt).parse(raw); } catch (_) {}
    }
    return DateTime.now();
  }

  Future<void> _import() async {
    setState(() => _loading = true);
    int imported = 0, skipped = 0;
    for (final row in _rows) {
      if (row.isDuplicate) { skipped++; continue; }
      await DatabaseHelper.instance.insertTransaction(Transaction(userId: 'offline_user', type: row.type, amount: row.rawAmount, date: row.parsedDate, notes: row.description, source: 'import'));
      imported++;
    }
    if (mounted) {
      setState(() { _importedCount = imported; _skippedCount = skipped; _loading = false; _done = true; });
    }
  }
}

class _PreviewRow {
  final String formattedDate, description, amount, type;
  final bool isDuplicate;
  final DateTime parsedDate;
  final double rawAmount;
  _PreviewRow({required this.formattedDate, required this.description, required this.amount, required this.type, required this.isDuplicate, required this.parsedDate, required this.rawAmount});
}
